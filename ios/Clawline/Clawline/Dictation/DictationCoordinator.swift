//
//  DictationCoordinator.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation
import Observation
import UIKit

enum DictationState: Equatable {
    case idleMicVisible
    case idleMicHidden
    case dictatingSticky
    case dictatingWalkieTalkie
    case stoppingKeep
    case stoppingDiscard
    case error
}

struct DictationTiming {
    var maxSessionDuration: Duration = .seconds(600)
    var tokenInactivityTimeout: Duration = .seconds(180)
    var stopKeepFinalizeTimeout: Duration = .milliseconds(1_200)
    var sendFinalizeTimeout: Duration = .milliseconds(500)
    var errorAutoDismissTimeout: Duration = .seconds(4)
    var errorAutoDismissVoiceOverTimeout: Duration = .seconds(8)
}

@MainActor
protocol DictationFeedbackProviding {
    var isVoiceOverRunning: Bool { get }
    var isReduceMotionEnabled: Bool { get }

    func announce(_ message: String)
    func impactLight()
    func notifySuccess()
    func notifyError()
}

@MainActor
final class UIKitDictationFeedbackProvider: DictationFeedbackProviding {
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notifications = UINotificationFeedbackGenerator()

    var isVoiceOverRunning: Bool {
        UIAccessibility.isVoiceOverRunning
    }

    var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func impactLight() {
        impact.impactOccurred()
    }

    func notifySuccess() {
        notifications.notificationOccurred(.success)
    }

    func notifyError() {
        notifications.notificationOccurred(.error)
    }
}

@Observable
@MainActor
final class DictationCoordinator {
    private(set) var state: DictationState = .idleMicHidden
    private(set) var errorMessage: String?
    private(set) var waveformDisplacement: CGFloat = 1
    private(set) var reduceMotionEnabled: Bool = UIAccessibility.isReduceMotionEnabled

    var isConfigured: Bool {
        configuredAPIKey() != nil
    }

    var isDictationActive: Bool {
        switch state {
        case .dictatingSticky, .dictatingWalkieTalkie, .stoppingKeep, .stoppingDiscard:
            return true
        case .idleMicVisible, .idleMicHidden, .error:
            return false
        }
    }

    var isStickyDictationActive: Bool {
        state == .dictatingSticky
    }

    var isWalkieTalkieActive: Bool {
        state == .dictatingWalkieTalkie
    }

    var isWaveformVisible: Bool {
        switch state {
        case .dictatingSticky, .dictatingWalkieTalkie, .stoppingKeep, .stoppingDiscard:
            return true
        case .idleMicVisible, .idleMicHidden, .error:
            return false
        }
    }

    var micVisible: Bool {
        isConfigured
            && !isDictationActive
            && !isTextFieldFocused
            && composeIsEmpty
    }

    var swipeActivationEnabled: Bool {
        isConfigured
            && !isDictationActive
            && state == .idleMicHidden
            && selectionLength == 0
    }

    private let bridge: ComposeInputDictationBridge
    private let configuredAPIKey: () -> String?
    private let languageHintProvider: () -> String
    private let audioCaptureFactory: () -> any DictationAudioCapturing
    private let streamingClientFactory: () -> any SonioxStreamingClienting
    private let analytics: any DictationAnalyticsTracking
    private let feedback: any DictationFeedbackProviding
    private let timing: DictationTiming

    private var currentSessionKey: String = ""
    private var composeIsEmpty = true
    private var isTextFieldFocused = false
    private var selectionLength = 0

    private var originSessionKey: String?
    private var preDictationSnapshot: ComposeDraftSnapshot = .empty
    private var transcriptBuffer = DictationTranscriptBuffer()
    private var mode: DictationMode?
    private var sessionStartedAt: Date?
    private var lastTokenAt: Date?
    private var finishedReceived = false

    private var audioCapture: (any DictationAudioCapturing)?
    private var streamingClient: (any SonioxStreamingClienting)?

    private var eventTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var tokenInactivityTask: Task<Void, Never>?
    private var errorDismissTask: Task<Void, Never>?
    private var streamSwitchStopTask: Task<Void, Never>?

    init(
        bridge: ComposeInputDictationBridge,
        configuredAPIKey: @escaping () -> String? = { SonioxConfigurationStore.apiKey },
        languageHintProvider: @escaping () -> String = { DictationLanguageHintResolver.resolve() },
        audioCaptureFactory: @escaping () -> any DictationAudioCapturing = { DictationAudioCapture() },
        streamingClientFactory: @escaping () -> any SonioxStreamingClienting = { SonioxStreamingClient() },
        analytics: any DictationAnalyticsTracking = DictationAnalytics(),
        feedback: (any DictationFeedbackProviding)? = nil,
        timing: DictationTiming = DictationTiming()
    ) {
        self.bridge = bridge
        self.configuredAPIKey = configuredAPIKey
        self.languageHintProvider = languageHintProvider
        self.audioCaptureFactory = audioCaptureFactory
        self.streamingClientFactory = streamingClientFactory
        self.analytics = analytics
        self.feedback = feedback ?? UIKitDictationFeedbackProvider()
        self.timing = timing
        reduceMotionEnabled = self.feedback.isReduceMotionEnabled
    }

    func updateContext(
        sessionKey: String,
        composeIsEmpty: Bool,
        textFieldFocused: Bool,
        selectionLength: Int,
        reduceMotionEnabled: Bool
    ) {
        let previousSession = currentSessionKey
        self.currentSessionKey = sessionKey
        self.composeIsEmpty = composeIsEmpty
        self.isTextFieldFocused = textFieldFocused
        self.selectionLength = selectionLength
        self.reduceMotionEnabled = reduceMotionEnabled

        if isDictationActive,
           let originSessionKey,
           !originSessionKey.isEmpty,
           !sessionKey.isEmpty,
           sessionKey != originSessionKey,
           previousSession != sessionKey {
            guard streamSwitchStopTask == nil else { return }
            streamSwitchStopTask = Task { [weak self] in
                guard let self else { return }
                await self.stopKeep(reason: "stream_switch", timeout: self.timing.stopKeepFinalizeTimeout, announceStop: false)
                await MainActor.run {
                    self.streamSwitchStopTask = nil
                }
            }
        }

        if !isDictationActive, state != .error {
            state = idleStateForCurrentContext()
        }
    }

    func startStickyDictation() {
        start(mode: .sticky)
    }

    func startWalkieTalkieDictation() {
        start(mode: .walkieTalkie)
    }

    func stopDictationFromSwipeRight() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            await self?.stopKeep(reason: "swipe_right", timeout: timing.stopKeepFinalizeTimeout)
        }
    }

    func endWalkieTalkieIfNeeded() {
        guard state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            await self?.stopKeep(reason: "walkie_release", timeout: timing.stopKeepFinalizeTimeout)
        }
    }

    func stopFromEscapeKey() {
        guard state == .dictatingSticky else { return }
        Task { [weak self] in
            await self?.stopKeep(reason: "escape", timeout: timing.stopKeepFinalizeTimeout)
        }
    }

    func discardFromEscapeLongPress() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        stopDiscard(reason: "escape_long_press")
    }

    func stopFromVoiceOverAction() {
        guard state == .dictatingSticky else { return }
        Task { [weak self] in
            await self?.stopKeep(reason: "voiceover_stop", timeout: timing.stopKeepFinalizeTimeout)
        }
    }

    func discardFromVoiceOverAction() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        stopDiscard(reason: "voiceover_discard")
    }

    func handleSendTapped(sendAction: @escaping () -> Void) {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .stoppingKeep else {
            sendAction()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let finalized = await self.stopKeep(reason: "send", timeout: self.timing.sendFinalizeTimeout)
            self.analytics.trackSendWhileActive(finalizedWithinTimeout: finalized)
            sendAction()
        }
    }

    func handleAppBackgrounded() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            await self?.stopKeep(reason: "app_background", timeout: timing.stopKeepFinalizeTimeout)
        }
    }

    private func start(mode: DictationMode) {
        guard !isDictationActive else { return }
        guard let apiKey = configuredAPIKey() else { return }
        guard !currentSessionKey.isEmpty else { return }

        self.mode = mode
        self.originSessionKey = currentSessionKey
        self.preDictationSnapshot = bridge.captureSnapshot(for: currentSessionKey)
        self.transcriptBuffer.reset()
        self.finishedReceived = false
        self.sessionStartedAt = Date()
        self.lastTokenAt = Date()
        self.waveformDisplacement = 1
        self.errorMessage = nil
        self.errorDismissTask?.cancel()
        self.errorDismissTask = nil

        feedback.impactLight()
        feedback.announce("Dictation started")

        switch mode {
        case .sticky:
            state = .dictatingSticky
        case .walkieTalkie:
            state = .dictatingWalkieTalkie
        }

        analytics.trackStart(mode: mode, sessionKey: currentSessionKey)

        let client = streamingClientFactory()
        streamingClient = client

        let capture = audioCaptureFactory()
        audioCapture = capture

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                await self.handleSonioxEvent(event)
            }
        }

        frameTask?.cancel()
        frameTask = Task { [weak self] in
            guard let self else { return }
            for await frame in capture.frameStream {
                guard self.state == .dictatingSticky || self.state == .dictatingWalkieTalkie || self.state == .stoppingKeep else {
                    return
                }
                do {
                    try await client.sendAudioFrame(frame)
                } catch {
                    await self.handleTransportFailure(stage: .send, message: error.localizedDescription)
                    return
                }
            }
        }

        levelTask?.cancel()
        levelTask = Task { [weak self] in
            guard let self else { return }
            for await level in capture.levelStream {
                await MainActor.run {
                    self.waveformDisplacement = self.mapRMS(level)
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.connect(config: SonioxStreamingConfig(apiKey: apiKey, languageHint: languageHintProvider()))
                try capture.start()
                await MainActor.run {
                    self.armSessionDurationTimer()
                    self.resetTokenInactivityTimer()
                }
            } catch {
                await self.handleTransportFailure(stage: .connect, message: error.localizedDescription)
            }
        }
    }

    private func armSessionDurationTimer() {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: timing.maxSessionDuration)
            await self.stopKeep(reason: "max_duration", timeout: timing.stopKeepFinalizeTimeout)
        }
    }

    private func resetTokenInactivityTimer() {
        tokenInactivityTask?.cancel()
        tokenInactivityTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: timing.tokenInactivityTimeout)
            await self.stopKeep(reason: "token_inactivity", timeout: timing.stopKeepFinalizeTimeout)
        }
    }

    private func handleSonioxEvent(_ event: SonioxStreamingEvent) async {
        switch event {
        case .response(let response):
            if let errorCode = response.errorCode, !errorCode.isEmpty {
                handleProtocolError(code: errorCode, message: response.errorMessage ?? "Dictation failed.")
                return
            }

            if let errorMessage = response.errorMessage, !errorMessage.isEmpty {
                handleProtocolError(code: nil, message: errorMessage)
                return
            }

            if !response.tokens.isEmpty || response.finished {
                let snapshot = transcriptBuffer.apply(tokens: response.tokens, finished: response.finished)
                if let originSessionKey {
                    bridge.apply(transcript: snapshot.text, baseSnapshot: preDictationSnapshot, to: originSessionKey)
                }
            }

            if !response.tokens.isEmpty {
                lastTokenAt = Date()
                resetTokenInactivityTimer()
            }

            if response.finished {
                finishedReceived = true
                if state == .stoppingKeep {
                    // stopKeep() polls this flag.
                }
            }
        case .closed:
            if let mode,
               state == .dictatingSticky || state == .dictatingWalkieTalkie {
                let elapsed = elapsedSessionMilliseconds()
                analytics.trackSocketDrop(mode: mode, elapsedMs: elapsed)
                await stopKeep(reason: "socket_drop", timeout: .zero, announceStop: false, gracefulFinalize: false)
            }
        case .failed(let stage, let code, let message):
            analytics.trackError(errorCode: code, stage: stage.rawValue)
            await handleTransportFailure(stage: stage, message: message)
        }
    }

    private func handleProtocolError(code: String?, message: String) {
        analytics.trackError(errorCode: code, stage: "protocol")
        Task { [weak self] in
            guard let self else { return }
            await self.stopKeep(reason: "protocol_error", timeout: .zero, announceStop: false, gracefulFinalize: false)
            self.enterError(message: message)
        }
    }

    private func handleTransportFailure(stage: SonioxStreamingClientStage, message: String) async {
        guard isDictationActive else { return }
        analytics.trackError(errorCode: nil, stage: stage.rawValue)
        await stopKeep(reason: "transport_failure", timeout: .zero, announceStop: false, gracefulFinalize: false)
        enterError(message: "Dictation failed")
    }

    @discardableResult
    private func stopKeep(
        reason: String,
        timeout: Duration,
        announceStop: Bool = true,
        gracefulFinalize: Bool = true
    ) async -> Bool {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .stoppingKeep else {
            return false
        }

        if state != .stoppingKeep {
            state = .stoppingKeep
        }

        maxDurationTask?.cancel()
        tokenInactivityTask?.cancel()

        var finalizedWithinTimeout = false

        if gracefulFinalize {
            do {
                try await streamingClient?.sendFinalize()
            } catch {
                enterError(message: "Failed to finalize dictation")
            }
        }
        audioCapture?.stop()

        if gracefulFinalize {
            do {
                try await streamingClient?.sendAudioFrame(Data())
            } catch {
                // Best effort; closing still proceeds.
            }
        }

        if gracefulFinalize {
            finalizedWithinTimeout = await waitForFinished(timeout: timeout)
        }

        streamingClient?.close(code: .normalClosure, reason: "client_finalize")
        finalizeSessionCleanup(reason: reason, announceStop: announceStop)
        return finalizedWithinTimeout
    }

    private func stopDiscard(reason: String) {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .stoppingKeep else { return }

        state = .stoppingDiscard

        maxDurationTask?.cancel()
        tokenInactivityTask?.cancel()

        audioCapture?.stop()
        streamingClient?.close(code: .normalClosure, reason: "client_cancelled")

        if let originSessionKey {
            bridge.restore(snapshot: preDictationSnapshot, to: originSessionKey)
        }

        finalizeSessionCleanup(reason: reason, announceStop: false)
    }

    private func waitForFinished(timeout: Duration) async -> Bool {
        guard timeout > .zero else { return false }
        if finishedReceived { return true }

        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if finishedReceived {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return finishedReceived
    }

    private func finalizeSessionCleanup(reason: String, announceStop: Bool) {
        let duration = elapsedSessionMilliseconds()
        analytics.trackStop(reason: reason, durationMs: duration)

        if announceStop {
            feedback.notifySuccess()
            feedback.announce("Dictation stopped")
        }

        waveformDisplacement = 1
        finishedReceived = false
        mode = nil
        sessionStartedAt = nil
        lastTokenAt = nil

        eventTask?.cancel()
        frameTask?.cancel()
        levelTask?.cancel()
        maxDurationTask?.cancel()
        tokenInactivityTask?.cancel()
        errorDismissTask?.cancel()
        streamSwitchStopTask?.cancel()

        eventTask = nil
        frameTask = nil
        levelTask = nil
        maxDurationTask = nil
        tokenInactivityTask = nil
        errorDismissTask = nil
        streamSwitchStopTask = nil

        audioCapture = nil
        streamingClient = nil

        originSessionKey = nil
        preDictationSnapshot = .empty

        if state != .error {
            state = idleStateForCurrentContext()
        }
    }

    private func enterError(message: String) {
        errorMessage = message
        state = .error
        feedback.notifyError()
        feedback.announce("Dictation failed")

        errorDismissTask?.cancel()
        let timeout = feedback.isVoiceOverRunning
            ? timing.errorAutoDismissVoiceOverTimeout
            : timing.errorAutoDismissTimeout

        errorDismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: timeout)
            await MainActor.run {
                self.errorMessage = nil
                if !self.isDictationActive {
                    self.state = self.idleStateForCurrentContext()
                }
            }
        }
    }

    private func idleStateForCurrentContext() -> DictationState {
        if isConfigured,
           !isTextFieldFocused,
           composeIsEmpty,
           !isDictationActive {
            return .idleMicVisible
        }
        return .idleMicHidden
    }

    private func mapRMS(_ rms: Float) -> CGFloat {
        let low: Float = 0.01
        let high: Float = 0.20
        let clamped = min(max((rms - low) / (high - low), 0), 1)
        return CGFloat(1 + clamped * 5)
    }

    private func elapsedSessionMilliseconds() -> Int {
        guard let sessionStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
    }
}
