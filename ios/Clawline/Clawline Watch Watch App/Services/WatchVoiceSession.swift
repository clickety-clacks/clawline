import AVFoundation
import Observation
import Foundation
import Network
import OSLog

@MainActor
@Observable
final class WatchVoiceSession {
    enum VoiceMode: Equatable {
        case tap
        case hold
    }

    enum VoiceState: Equatable {
        case idle
        case listening
        case finalizing
        case sending
        case speaking
        case error
    }

    private enum Phase {
        case idle
        case listening(mode: VoiceMode)
        case finalizing
        case sending(transcript: String)
        case speaking(contextId: String)
        case error(message: String, autoRecoverTask: Task<Void, Never>?)
    }

    private enum VoiceFailureKind: String {
        case missingSonioxKey
        case microphoneUnavailable
        case sonioxConnectivity
        case sonioxStart
        case relayConnectivity
        case unexpected

        var userMessage: String {
            switch self {
            case .missingSonioxKey:
                return "Soniox key is not synced to Watch yet. Open Clawline on iPhone and check voice settings."
            case .microphoneUnavailable:
                return "Microphone is unavailable. Check Watch microphone permission and try again."
            case .sonioxConnectivity:
                return "Couldn't connect to Soniox. Check Watch Wi-Fi or cellular and try again."
            case .sonioxStart:
                return "Couldn't start Soniox dictation. Try again."
            case .relayConnectivity:
                return "Watch relay is reconnecting. Try again when iPhone is nearby."
            case .unexpected:
                return "Voice couldn't start. Try again."
            }
        }
    }

    private let credentialStore: WatchCredentialStore
    private let sonioxClient: any WatchVoiceStreaming
    private let cartesiaClient = CartesiaTTSClient()
    private let directInternetMonitor = DirectInternetMonitor()
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "WatchVoice")
    private let audioSessionConfigurator: () throws -> Void

    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let speechSynth = AVSpeechSynthesizer()

    private var inactivityTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?

    private var responseQueue: [String] = []
    private var activeContextId: String?
    private var pendingBuffers = 0
    private var receivedDoneForContext = false
    private var hasConfiguredAudioSession = false

    private var phase: Phase = .idle

    private(set) var voiceState: VoiceState = .idle
    private(set) var audioLevel: Float = 0
    private(set) var transcript: String = ""
    private(set) var errorMessage: String?
    private(set) var mode: VoiceMode?
    private(set) var hasDirectInternet: Bool = true

    var canUseVoice: Bool {
        // A false NWPath on physical Watch must not send mic taps to WatchKit text input.
        credentialStore.sonioxApiKey?.isEmpty == false
    }

    var onTranscriptReady: ((String) -> Void)?

    init(
        credentialStore: WatchCredentialStore,
        sonioxClient: (any WatchVoiceStreaming)? = nil,
        audioSessionConfigurator: @escaping () throws -> Void = WatchVoiceSession.configureSharedAudioSession
    ) {
        self.credentialStore = credentialStore
        self.sonioxClient = sonioxClient ?? SonioxStreamingClient()
        self.audioSessionConfigurator = audioSessionConfigurator

        self.sonioxClient.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        self.sonioxClient.onTranscriptUpdate = { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                self.transcript = update.text
                if self.mode == .tap {
                    self.resetInactivityTimerIfNeeded()
                }
            }
        }

        self.sonioxClient.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.transitionToVoiceError(kind: self.voiceFailureKind(for: error), error: error)
            }
        }

        hasDirectInternet = directInternetMonitor.isDirectInternetAvailable
        directInternetMonitor.onChange = { [weak self] available in
            Task { @MainActor in
                self?.handleDirectInternetChange(available)
            }
        }
    }

    func startTap() {
        if case .speaking = phase {
            bargeIn()
            return
        }
        if case .error = phase {
            cancelError()
        }

        guard canUseVoice else {
            transitionToVoiceError(kind: .missingSonioxKey)
            return
        }

        transitionToListening(mode: .tap)
    }

    func startHold() {
        if case .speaking = phase {
            bargeInHold()
            return
        }
        if case .error = phase {
            cancelError()
        }

        guard canUseVoice else {
            transitionToVoiceError(kind: .missingSonioxKey)
            return
        }

        transitionToListening(mode: .hold)
    }

    func releaseHold() {
        guard case .listening(let currentMode) = phase, currentMode == .hold else { return }
        finalizeAndSend(forceIdleAfterSend: false)
    }

    func stop() {
        switch phase {
        case .listening:
            finalizeAndSend(forceIdleAfterSend: false)
        case .speaking:
            cancelCurrentSpeech(clearQueue: true)
            transitionToIdle()
        case .error:
            cancelError()
        default:
            break
        }
    }

    func bargeIn() {
        guard case .speaking = phase else { return }
        cancelCurrentSpeech(clearQueue: true)
        transitionToListening(mode: .tap)
    }

    func bargeInHold() {
        guard case .speaking = phase else { return }
        cancelCurrentSpeech(clearQueue: true)
        transitionToListening(mode: .hold)
    }

    func handleResponse(text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if case .speaking = phase {
            responseQueue.append(cleaned)
            return
        }

        startSpeaking(text: cleaned)
    }

    func handleSendFailure(error: Error) {
        guard case .sending = phase else { return }
        logger.error("Watch voice send failure diagnostic=\(String(describing: error), privacy: .public)")
        transitionToError(error.localizedDescription)
    }

    func handleTTSComplete() {
        if !responseQueue.isEmpty {
            let next = responseQueue.removeFirst()
            startSpeaking(text: next)
            return
        }
        transitionToIdle()
    }

    func cancelError() {
        guard case .error(_, let task) = phase else { return }
        task?.cancel()
        transitionToIdle()
    }

    private func transitionToListening(mode: VoiceMode) {
        do {
            try configureAudioSessionIfNeeded()
        } catch {
            transitionToVoiceError(kind: .microphoneUnavailable, error: error)
            return
        }

        inactivityTask?.cancel()
        maxDurationTask?.cancel()

        responseQueue.removeAll()
        transcript = ""
        errorMessage = nil
        self.mode = mode
        audioLevel = 0

        phase = .listening(mode: mode)
        voiceState = .listening

        Task { [weak self] in
            guard let self else { return }
            guard let key = self.credentialStore.sonioxApiKey, !key.isEmpty else {
                await MainActor.run {
                    self.transitionToVoiceError(kind: .missingSonioxKey)
                }
                return
            }

            do {
                try await self.sonioxClient.start(apiKey: key)
                await MainActor.run {
                    if mode == .tap {
                        self.startTapTimers()
                    }
                }
            } catch {
                await MainActor.run {
                    self.transitionToVoiceError(kind: self.voiceFailureKind(for: error), error: error)
                }
            }
        }
    }

    private func finalizeAndSend(forceIdleAfterSend: Bool) {
        guard case .listening = phase else { return }
        phase = .finalizing
        voiceState = .finalizing

        inactivityTask?.cancel()
        maxDurationTask?.cancel()

        Task { [weak self] in
            guard let self else { return }
            let finalTranscript = await self.sonioxClient.finalize()

            await MainActor.run {
                guard case .finalizing = self.phase else { return }
                self.transcript = finalTranscript
                let cleaned = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

                if cleaned.isEmpty {
                    self.transitionToIdle()
                    return
                }

                self.phase = .sending(transcript: cleaned)
                self.voiceState = .sending
                self.onTranscriptReady?(cleaned)

                if forceIdleAfterSend {
                    self.transitionToIdle()
                }
            }
        }
    }

    private func startTapTimers() {
        resetInactivityTimerIfNeeded()

        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finalizeAndSend(forceIdleAfterSend: false)
            }
        }
    }

    private func resetInactivityTimerIfNeeded() {
        guard case .listening(let listeningMode) = phase, listeningMode == .tap else { return }
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finalizeAndSend(forceIdleAfterSend: false)
            }
        }
    }

    private func startSpeaking(text: String) {
        do {
            try configureAudioSessionIfNeeded()
        } catch {
            transitionToVoiceError(kind: .microphoneUnavailable, error: error)
            return
        }

        errorMessage = nil
        mode = nil
        audioLevel = 0

        if !hasDirectInternet || credentialStore.cartesiaApiKey?.isEmpty != false {
            phase = .speaking(contextId: "local_speech")
            voiceState = .speaking
            speakWithSystemVoice(text)
            return
        }

        guard let apiKey = credentialStore.cartesiaApiKey,
              let voiceId = credentialStore.cartesiaVoiceId, !voiceId.isEmpty else {
            phase = .speaking(contextId: "local_speech")
            voiceState = .speaking
            speakWithSystemVoice(text)
            return
        }

        phase = .speaking(contextId: "cartesia_pending")
        voiceState = .speaking

        pendingBuffers = 0
        receivedDoneForContext = false

        Task { [weak self] in
            guard let self else { return }
            do {
                let contextId = try await self.cartesiaClient.speak(
                    text: text,
                    apiKey: apiKey,
                    voiceId: voiceId,
                    onChunk: { [weak self] chunk in
                        Task { @MainActor in
                            self?.enqueuePCMChunk(chunk)
                        }
                    },
                    onAudioLevel: { [weak self] level in
                        Task { @MainActor in
                            self?.audioLevel = level
                        }
                    },
                    onDone: { [weak self] in
                        Task { @MainActor in
                            self?.receivedDoneForContext = true
                            self?.checkSpeechCompletion()
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in
                            self?.transitionToVoiceError(kind: .unexpected, error: error)
                        }
                    }
                )

                await MainActor.run {
                    self.activeContextId = contextId
                    self.phase = .speaking(contextId: contextId)
                }
            } catch {
                await MainActor.run {
                    self.transitionToVoiceError(kind: .unexpected, error: error)
                }
            }
        }
    }

    private func enqueuePCMChunk(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        configurePlaybackEngineIfNeeded()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 24000,
                                         channels: 1,
                                         interleaved: true) else {
            return
        }

        let frameCount = UInt32(pcmData.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }

        buffer.frameLength = frameCount

        pcmData.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let destination = buffer.int16ChannelData?.pointee else {
                return
            }
            destination.update(from: source, count: Int(frameCount))
        }

        pendingBuffers += 1
        let session = self
        playerNode.scheduleBuffer(buffer) { [weak session] in
            Task { @MainActor [weak session] in
                guard let session else { return }
                session.pendingBuffers = max(0, session.pendingBuffers - 1)
                session.checkSpeechCompletion()
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        if !playbackEngine.isRunning {
            try? playbackEngine.start()
        }
    }

    private func checkSpeechCompletion() {
        guard receivedDoneForContext, pendingBuffers == 0 else { return }
        playerNode.stop()
        handleTTSComplete()
    }

    private func cancelCurrentSpeech(clearQueue: Bool) {
        if let activeContextId {
            Task { [weak self] in
                await self?.cartesiaClient.cancel(contextId: activeContextId)
            }
        }

        activeContextId = nil
        receivedDoneForContext = false
        pendingBuffers = 0
        playerNode.stop()
        speechSynth.stopSpeaking(at: .immediate)

        if clearQueue {
            responseQueue.removeAll()
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        speechSynth.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        speechSynth.speak(utterance)

        Task { [weak self] in
            let approximateSeconds = max(1.0, Double(text.count) / 18.0)
            try? await Task.sleep(for: .seconds(approximateSeconds))
            await MainActor.run {
                self?.handleTTSComplete()
            }
        }
    }

    private func transitionToVoiceError(
        kind: VoiceFailureKind,
        error: Error? = nil,
        autoRecover: Bool = false
    ) {
        let diagnostic = error.map { String(describing: $0) } ?? "none"
        logger.error("Watch voice failure kind=\(kind.rawValue, privacy: .public) directInternet=\(self.hasDirectInternet, privacy: .public) diagnostic=\(diagnostic, privacy: .public)")
        transitionToError(kind.userMessage, autoRecover: autoRecover)
    }

    private func transitionToError(_ message: String, autoRecover: Bool = false) {
        inactivityTask?.cancel()
        maxDurationTask?.cancel()
        sonioxClient.stop()

        if case .error(_, let existingTask) = phase {
            existingTask?.cancel()
        }

        errorMessage = message
        voiceState = .error

        let recoveryTask: Task<Void, Never>?
        if autoRecover {
            recoveryTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.transitionToIdle()
                }
            }
        } else {
            recoveryTask = nil
        }

        phase = .error(message: message, autoRecoverTask: recoveryTask)
    }

    private func voiceFailureKind(for error: Error) -> VoiceFailureKind {
        if isAudioCaptureError(error) {
            return .microphoneUnavailable
        }
        return isNetworkConnectivityError(error) ? .sonioxConnectivity : .sonioxStart
    }

    private func isAudioCaptureError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return true
        }

        let domain = nsError.domain.lowercased()
        return domain.contains("avaudio") ||
            domain.contains("avfaudio") ||
            domain.contains("coreaudio") ||
            domain.contains("audio")
    }

    private func isNetworkConnectivityError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch URLError.Code(rawValue: nsError.code) {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .timedOut,
             .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private func transitionToIdle() {
        inactivityTask?.cancel()
        maxDurationTask?.cancel()
        inactivityTask = nil
        maxDurationTask = nil

        sonioxClient.stop()
        mode = nil
        audioLevel = 0
        errorMessage = nil

        if case .idle = phase {
            transcript = ""
        } else {
            transcript = ""
        }

        phase = .idle
        voiceState = .idle
    }

    private func configurePlaybackEngineIfNeeded() {
        try? configureAudioSessionIfNeeded()

        if playbackEngine.attachedNodes.contains(playerNode) == false {
            playbackEngine.attach(playerNode)
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 24000,
                                       channels: 1,
                                       interleaved: true)
            playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: format)
        }

        if !playbackEngine.isRunning {
            try? playbackEngine.start()
        }
    }

    private func configureAudioSessionIfNeeded() throws {
        guard !hasConfiguredAudioSession else { return }
        try audioSessionConfigurator()
        hasConfiguredAudioSession = true
    }

    private nonisolated static func configureSharedAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [])
        try audioSession.setActive(true)
    }

    private func handleDirectInternetChange(_ available: Bool) {
        guard hasDirectInternet != available else { return }
        hasDirectInternet = available
    }
}

private final class DirectInternetMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "co.clicketyclacks.clawline.watch.internet")

    private(set) var isDirectInternetAvailable: Bool = true
    var onChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = path.status == .satisfied &&
                (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.cellular))
            guard available != self.isDirectInternetAvailable else { return }
            self.isDirectInternetAvailable = available
            self.onChange?(available)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
