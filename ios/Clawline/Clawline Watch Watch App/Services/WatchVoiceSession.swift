import AVFoundation
import Observation
import Foundation
import Network

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

    private let credentialStore: WatchCredentialStore
    private let sonioxClient = SonioxStreamingClient()
    private let cartesiaClient = CartesiaTTSClient()
    private let directInternetMonitor = DirectInternetMonitor()

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
    private var currentRoute: WatchProviderTransportState = .disconnected

    private(set) var voiceState: VoiceState = .idle
    private(set) var audioLevel: Float = 0
    private(set) var transcript: String = ""
    private(set) var errorMessage: String?
    private(set) var mode: VoiceMode?
    private(set) var hasDirectInternet: Bool = true

    var canUseVoice: Bool {
        hasDirectInternet && credentialStore.sonioxApiKey?.isEmpty == false
    }

    var onTranscriptReady: ((String) -> Void)?

    init(credentialStore: WatchCredentialStore) {
        self.credentialStore = credentialStore

        sonioxClient.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        sonioxClient.onTranscriptUpdate = { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                self.transcript = update.text
                if self.mode == .tap {
                    self.resetInactivityTimerIfNeeded()
                }
            }
        }

        sonioxClient.onError = { [weak self] error in
            Task { @MainActor in
                self?.transitionToError(error.localizedDescription)
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
            transitionToError("Voice unavailable — text only")
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
            transitionToError("Voice unavailable — text only")
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

    func routeChanged(to route: WatchProviderTransportState) {
        currentRoute = route

        guard route == .disconnected else {
            return
        }

        switch phase {
        case .listening:
            finalizeAndSend(forceIdleAfterSend: true)
        case .finalizing:
            // Let current finalization complete naturally, then transition to idle in finalize path.
            break
        case .sending:
            // No-op: pending text response can still arrive via relay/disconnected recovery path.
            break
        case .speaking:
            cancelCurrentSpeech(clearQueue: true)
            transitionToIdle()
        case .idle, .error:
            break
        }
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
            transitionToError(error.localizedDescription)
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
                    self.transitionToError("Missing Soniox key")
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
                    self.transitionToError(error.localizedDescription)
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
            transitionToError(error.localizedDescription)
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
                            self?.transitionToError(error.localizedDescription)
                        }
                    }
                )

                await MainActor.run {
                    self.activeContextId = contextId
                    self.phase = .speaking(contextId: contextId)
                }
            } catch {
                await MainActor.run {
                    self.transitionToError(error.localizedDescription)
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
            destination.assign(from: source, count: Int(frameCount))
        }

        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.checkSpeechCompletion()
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

    private func transitionToError(_ message: String) {
        inactivityTask?.cancel()
        maxDurationTask?.cancel()

        if case .error(_, let existingTask) = phase {
            existingTask?.cancel()
        }

        errorMessage = message
        voiceState = .error

        let recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.transitionToIdle()
            }
        }

        phase = .error(message: message, autoRecoverTask: recoveryTask)
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
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [])
        try audioSession.setActive(true)
        hasConfiguredAudioSession = true
    }

    private func handleDirectInternetChange(_ available: Bool) {
        guard hasDirectInternet != available else { return }
        hasDirectInternet = available

        guard !available else { return }

        switch phase {
        case .listening:
            finalizeAndSend(forceIdleAfterSend: true)
        case .speaking where activeContextId != nil:
            cancelCurrentSpeech(clearQueue: true)
            transitionToIdle()
        case .idle, .finalizing, .sending, .error, .speaking:
            break
        }
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
