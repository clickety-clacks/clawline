//
//  DictationCoordinator.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation
import Observation
import OSLog
import UIKit

enum DictationState: Equatable {
    case idleMicVisible
    case idleMicHidden
    case keyPromptModal
    case keyVerifyingModal
    case dictatingSticky
    case dictatingWalkieTalkie
    case stoppingKeep
    case stoppingDiscard
    case error
}

struct DictationTiming {
    var maxSessionDuration: Duration = .seconds(60)
    var tokenInactivityTimeout: Duration = .seconds(15)
    var stopKeepFinalizeTimeout: Duration = .milliseconds(1_200)
    var sendFinalizeTimeout: Duration = .milliseconds(500)
    var composeUpdateCoalescingInterval: Duration = .milliseconds(75)
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
#if os(visionOS)
#else
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notifications = UINotificationFeedbackGenerator()
#endif

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
#if os(visionOS)
        // Haptics generators are unavailable on visionOS devices.
#else
        impact.impactOccurred()
#endif
    }

    func notifySuccess() {
#if os(visionOS)
#else
        notifications.notificationOccurred(.success)
#endif
    }

    func notifyError() {
#if os(visionOS)
#else
        notifications.notificationOccurred(.error)
#endif
    }
}

@Observable
@MainActor
final class DictationCoordinator {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "DictationCoordinator")
    private(set) var state: DictationState = .idleMicHidden {
        didSet {
            guard oldValue != state else { return }
            let trace = "DICTATION_COORD state \(String(describing: oldValue)) -> \(String(describing: state))"
            logDictation(trace)
        }
    }
    private(set) var errorMessage: String?
    private(set) var waveformDisplacement: CGFloat = 1
    private(set) var reduceMotionEnabled: Bool = UIAccessibility.isReduceMotionEnabled
    private(set) var inlineKeyText: String = SonioxConfigurationStore.editableAPIKey
    private(set) var inlineKeyStatus: SonioxKeyVerificationStatus = SonioxConfigurationStore.keyStatus

    var inlineKeyActionTitle: String {
        inlineKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Get Key" : "Verify"
    }

    var inlineKeyStatusText: String? {
        inlineKeyStatus.inlineStatusText
    }

    var showsComposeKeyPromptModal: Bool {
        state == .keyPromptModal || state == .keyVerifyingModal
    }

    var isDictationActive: Bool {
        switch state {
        case .dictatingSticky, .dictatingWalkieTalkie, .stoppingKeep, .stoppingDiscard:
            return true
        case .idleMicVisible, .idleMicHidden, .keyPromptModal, .keyVerifyingModal, .error:
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
        case .idleMicVisible, .idleMicHidden, .keyPromptModal, .keyVerifyingModal, .error:
            return false
        }
    }

    var micVisible: Bool {
        !isDictationActive
            && !isTextFieldFocused
            && composeIsEmpty
    }

    var swipeActivationEnabled: Bool {
        !isDictationActive
            && state == .idleMicHidden
            && selectionLength == 0
    }

    private let bridge: ComposeInputDictationBridge
    private let configuredAPIKey: () -> String?
    private let editableAPIKeyProvider: () -> String
    private let keyStatusProvider: () -> SonioxKeyVerificationStatus
    private let setConfiguredAPIKey: (String?) -> Void
    private let setKeyStatus: (SonioxKeyVerificationStatus) -> Void
    private let keyVerifier: any SonioxKeyVerifying
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
    private var pendingTranscriptText: String?
    private var lastAppliedTranscriptText: String = ""
    private var pendingActivationMode: DictationMode?
    private var mode: DictationMode?
    private var sessionStartedAt: Date?
    private var lastTokenAt: Date?
    private var finishedReceived = false
    private var pendingStopContext: String?

    private var audioCapture: (any DictationAudioCapturing)?
    private var streamingClient: (any SonioxStreamingClienting)?

    private var eventTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var audioEventTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var tokenInactivityTask: Task<Void, Never>?
    private var tokenInactivityTaskID: UInt64 = 0
    private var activeTokenInactivityTaskID: UInt64?
    private var errorDismissTask: Task<Void, Never>?
    private var streamSwitchStopTask: Task<Void, Never>?
    private var transcriptApplyTask: Task<Void, Never>?

    nonisolated private static func callSite(
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> String {
        "\(fileID):\(line) \(function)"
    }

    init(
        bridge: ComposeInputDictationBridge,
        configuredAPIKey: @escaping () -> String? = { SonioxConfigurationStore.apiKey },
        editableAPIKeyProvider: @escaping () -> String = { SonioxConfigurationStore.editableAPIKey },
        keyStatusProvider: @escaping () -> SonioxKeyVerificationStatus = { SonioxConfigurationStore.keyStatus },
        setConfiguredAPIKey: @escaping (String?) -> Void = { SonioxConfigurationStore.setAPIKey($0) },
        setKeyStatus: @escaping (SonioxKeyVerificationStatus) -> Void = { SonioxConfigurationStore.setKeyStatus($0) },
        keyVerifier: any SonioxKeyVerifying = SonioxKeyVerifier(),
        languageHintProvider: @escaping () -> String = { DictationLanguageHintResolver.resolve() },
        audioCaptureFactory: @escaping () -> any DictationAudioCapturing = { DictationAudioCapture() },
        streamingClientFactory: @escaping () -> any SonioxStreamingClienting = { SonioxStreamingClient() },
        analytics: any DictationAnalyticsTracking = DictationAnalytics(),
        feedback: (any DictationFeedbackProviding)? = nil,
        timing: DictationTiming = DictationTiming()
    ) {
        self.bridge = bridge
        self.configuredAPIKey = configuredAPIKey
        self.editableAPIKeyProvider = editableAPIKeyProvider
        self.keyStatusProvider = keyStatusProvider
        self.setConfiguredAPIKey = setConfiguredAPIKey
        self.setKeyStatus = setKeyStatus
        self.keyVerifier = keyVerifier
        self.languageHintProvider = languageHintProvider
        self.audioCaptureFactory = audioCaptureFactory
        self.streamingClientFactory = streamingClientFactory
        self.analytics = analytics
        self.feedback = feedback ?? UIKitDictationFeedbackProvider()
        self.timing = timing
        reduceMotionEnabled = self.feedback.isReduceMotionEnabled
        refreshInlineKeyFromStore()
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

        if state != .keyVerifyingModal {
            refreshInlineKeyFromStore()
        }

        if isDictationActive,
           let originSessionKey,
           !originSessionKey.isEmpty,
           !sessionKey.isEmpty,
           sessionKey != originSessionKey,
           previousSession != sessionKey {
            guard streamSwitchStopTask == nil else { return }
            streamSwitchStopTask = Task { [weak self] in
                guard let self else { return }
                logDictation("DICTATION_STOP trace_id=DICTATION_STOP_STREAM_SWITCH caller=stream_switch_handler ts=\(Date().timeIntervalSince1970)")
                await self.stopKeep(
                    reason: "stream_switch",
                    timeout: self.timing.stopKeepFinalizeTimeout,
                    announceStop: false,
                    trigger: "stream_switch_context_update"
                )
                await MainActor.run {
                    self.streamSwitchStopTask = nil
                }
            }
        }

        if !isDictationActive,
           state != .error,
           state != .keyPromptModal,
           state != .keyVerifyingModal {
            state = idleStateForCurrentContext()
        }
    }

    func setComposeTextView(_ textView: PastableTextView?) {
        bridge.setComposeTextView(textView)
    }

    func startStickyDictation() {
        logDictation("DICTATION_UI startStickyDictation")
        start(mode: .sticky)
    }

    func startWalkieTalkieDictation() {
        logDictation("DICTATION_UI startWalkieTalkieDictation")
        start(mode: .walkieTalkie)
    }

    func updateInlineKeyText(_ value: String) {
        let previousTrimmed = inlineKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineKeyText = value
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        setConfiguredAPIKey(trimmed.isEmpty ? nil : trimmed)

        if trimmed.isEmpty {
            inlineKeyStatus = .missing
            setKeyStatus(.missing)
        } else if trimmed != previousTrimmed, inlineKeyStatus != .validating {
            inlineKeyStatus = .unverified
            setKeyStatus(.unverified)
        }
    }

    func handleComposeKeyPrimaryAction(openKeyURL: (URL) -> Void) async {
        let trimmed = inlineKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            inlineKeyStatus = .missing
            setConfiguredAPIKey(nil)
            setKeyStatus(.missing)
            state = .keyPromptModal
            openKeyURL(SonioxConfigurationStore.keyManagementURL)
            return
        }

        state = .keyVerifyingModal
        inlineKeyStatus = .validating
        setKeyStatus(.validating)
        setConfiguredAPIKey(trimmed)

        let isValid = await keyVerifier.verify(apiKey: trimmed)
        if isValid {
            inlineKeyStatus = .validated
            setKeyStatus(.validated)
            let requestedMode = pendingActivationMode
            pendingActivationMode = nil
            if let requestedMode {
                start(mode: requestedMode)
            } else {
                state = idleStateForCurrentContext()
            }
        } else {
            inlineKeyStatus = .invalid
            setKeyStatus(.invalid)
            state = .keyPromptModal
        }
    }

    func dismissComposeKeyPrompt() {
        guard state == .keyPromptModal || state == .keyVerifyingModal else { return }
        pendingActivationMode = nil
        state = idleStateForCurrentContext()
    }

    func stopDictationFromSwipeRight() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SWIPE_RIGHT caller=swipe_right_stop ts=\(Date().timeIntervalSince1970)")
            await self?.stopKeep(
                reason: "swipe_right",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "user_swipe_right"
            )
        }
    }

    func stopStickyFromMicTap() {
        guard state == .dictatingSticky else { return }
        Task { [weak self] in
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_MIC_TAP caller=mic_tap_stop ts=\(Date().timeIntervalSince1970)")
            await self?.stopKeep(
                reason: "mic_tap_toggle",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "mic_tap_toggle"
            )
        }
    }

    func endWalkieTalkieIfNeeded() {
        guard state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_WALKIE_RELEASE caller=walkie_release ts=\(Date().timeIntervalSince1970)")
            await self?.stopKeep(
                reason: "walkie_release",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "walkie_release"
            )
        }
    }

    func stopFromEscapeKey() {
        guard state == .dictatingSticky else { return }
        Task { [weak self] in
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_ESCAPE caller=stopFromEscapeKey ts=\(Date().timeIntervalSince1970)")
            await self?.stopKeep(
                reason: "escape",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "keyboard_escape"
            )
        }
    }

    func discardFromEscapeLongPress() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        logDictation("DICTATION_STOP trace_id=DICTATION_DISCARD_ESCAPE_LONG_PRESS caller=discardFromEscapeLongPress ts=\(Date().timeIntervalSince1970)")
        stopDiscard(reason: "escape_long_press", trigger: "keyboard_escape_long_press")
    }

    func stopFromVoiceOverAction() {
        guard state == .dictatingSticky else { return }
        Task { [weak self] in
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_VOICEOVER caller=stopFromVoiceOverAction ts=\(Date().timeIntervalSince1970)")
            await self?.stopKeep(
                reason: "voiceover_stop",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "voiceover_stop_action"
            )
        }
    }

    func discardFromVoiceOverAction() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        logDictation("DICTATION_STOP trace_id=DICTATION_DISCARD_VOICEOVER caller=discardFromVoiceOverAction ts=\(Date().timeIntervalSince1970)")
        stopDiscard(reason: "voiceover_discard", trigger: "voiceover_discard_action")
    }

    func handleSendTapped(sendAction: @escaping () -> Void) {
        logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SEND_TAPPED_ENTRY caller=handleSendTapped_entry ts=\(Date().timeIntervalSince1970) state=\(String(describing: state))")
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .stoppingKeep else {
            sendAction()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SEND_FINALIZE caller=send_tap_finalization ts=\(Date().timeIntervalSince1970)")
            let finalized = await self.stopKeep(
                reason: "send",
                timeout: self.timing.sendFinalizeTimeout,
                trigger: "send_button_tap"
            )
            self.analytics.trackSendWhileActive(finalizedWithinTimeout: finalized)
            sendAction()
        }
    }

    func handleAppBackgrounded() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_APP_BACKGROUND caller=app_background_handler ts=\(Date().timeIntervalSince1970)")
            await self?.stopKeep(
                reason: "app_background",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "app_background_notification"
            )
        }
    }

    private func start(mode: DictationMode) {
        guard !isDictationActive else { return }
        guard !currentSessionKey.isEmpty else { return }
        refreshInlineKeyFromStore()

        guard inlineKeyStatus == .validated,
              let apiKey = configuredAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingActivationMode = mode
            state = .keyPromptModal
            return
        }

        pendingActivationMode = nil
        self.mode = mode
        self.originSessionKey = currentSessionKey
        bridge.resetTranscriptState(for: currentSessionKey)
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=capture_snapshot_begin session=\(currentSessionKey)")
        self.preDictationSnapshot = bridge.captureSnapshot(for: currentSessionKey)
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=capture_snapshot_end session=\(currentSessionKey)")
        self.transcriptBuffer.reset()
        self.pendingTranscriptText = nil
        self.lastAppliedTranscriptText = ""
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
            let minimumWaveformUpdateInterval: CFTimeInterval = 0.05
            var lastWaveformUpdateAt = CFAbsoluteTimeGetCurrent() - minimumWaveformUpdateInterval
            var lastAppliedDisplacement: CGFloat = -1
            for await level in capture.levelStream {
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastWaveformUpdateAt >= minimumWaveformUpdateInterval else { continue }
                lastWaveformUpdateAt = now
                let nextDisplacement = Self.mappedDisplacement(for: level)
                guard abs(nextDisplacement - lastAppliedDisplacement) >= 0.05 else { continue }
                lastAppliedDisplacement = nextDisplacement
                let perfTs = Date().timeIntervalSince1970
                await MainActor.run {
                    logDictation("DICTATION_PERF ts=\(perfTs) event=waveform_update_main_thread displacement=\(nextDisplacement)")
                    self.waveformDisplacement = nextDisplacement
                }
            }
        }

        audioEventTask?.cancel()
        audioEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in capture.eventStream {
                await self.handleAudioCaptureEvent(event)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                logDictation("DICTATION_COORD socket_connect begin")
                try await client.connect(config: SonioxStreamingConfig(apiKey: apiKey, languageHint: languageHintProvider()))
                logDictation("DICTATION_COORD audio_capture start begin")
                try capture.start()
                logDictation("DICTATION_COORD audio_capture start success")
                await MainActor.run {
                    self.armSessionDurationTimer()
                    self.resetTokenInactivityTimer()
                }
            } catch {
                logDictation("DICTATION_COORD start failure stage=connect_or_audio_start error=\(error.localizedDescription)")
                await self.handleTransportFailure(stage: .connect, message: error.localizedDescription)
            }
        }
    }

    private func armSessionDurationTimer() {
        maxDurationTask?.cancel()
        maxDurationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: timing.maxSessionDuration)
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_TIMER_MAX_DURATION caller=timer_max_duration ts=\(Date().timeIntervalSince1970)")
            await self.stopKeep(
                reason: "max_duration",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "max_duration_timer_fired"
            )
        }
    }

    private func resetTokenInactivityTimer() {
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_RESET " +
            "caller=resetTokenInactivityTimer ts=\(Date().timeIntervalSince1970) " +
            "state=\(String(describing: state)) timeout=\(String(describing: timing.tokenInactivityTimeout))"
        )
        cancelTokenInactivityTimer(reason: "reset_token_inactivity_timer")
        tokenInactivityTaskID &+= 1
        let taskID = tokenInactivityTaskID
        activeTokenInactivityTaskID = taskID
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_START " +
            "caller=resetTokenInactivityTimer task_id=\(taskID) ts=\(Date().timeIntervalSince1970) " +
            "state=\(String(describing: state))"
        )
        tokenInactivityTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: timing.tokenInactivityTimeout)
            if Task.isCancelled {
                self.logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_CANCELLED_OBSERVED " +
                    "caller=timer_token_inactivity task_id=\(taskID) ts=\(Date().timeIntervalSince1970)"
                )
                return
            }
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY caller=timer_token_inactivity ts=\(Date().timeIntervalSince1970)")
            activeTokenInactivityTaskID = nil
            await self.stopKeep(
                reason: "token_inactivity",
                timeout: timing.stopKeepFinalizeTimeout,
                trigger: "token_inactivity_timer_fired"
            )
        }
    }

    private func cancelTokenInactivityTimer(reason: String) {
        guard let tokenInactivityTask else { return }
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_CANCEL " +
            "caller=cancelTokenInactivityTimer reason=\(reason) " +
            "task_id=\(activeTokenInactivityTaskID.map(String.init) ?? "nil") ts=\(Date().timeIntervalSince1970)"
        )
        tokenInactivityTask.cancel()
        self.tokenInactivityTask = nil
        activeTokenInactivityTaskID = nil
    }

    private func handleSonioxEvent(_ event: SonioxStreamingEvent) async {
        switch event {
        case .response(let response):
            if let errorCode = response.errorCode, !errorCode.isEmpty {
                logger.notice(
                    "SONIOX_ERROR_CODE code=\(errorCode, privacy: .public) message=\(response.errorMessage ?? errorCode, privacy: .public)"
                )
                let message: String
                if let errorMessage = response.errorMessage, !errorMessage.isEmpty {
                    message = errorMessage
                } else {
                    message = errorCode
                }
                handleProtocolError(code: errorCode, message: message)
                return
            }

            if let errorMessage = response.errorMessage, !errorMessage.isEmpty {
                handleProtocolError(code: nil, message: errorMessage)
                return
            }

            if !response.tokens.isEmpty || response.finished {
                let snapshot = transcriptBuffer.apply(tokens: response.tokens, finished: response.finished)
                queueTranscriptApply(snapshot.text, immediate: response.finished)
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
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SOCKET_CLOSED_EVENT caller=soniox_event_closed state=\(String(describing: state)) mode=\(String(describing: mode))")
            if let mode,
               state == .dictatingSticky || state == .dictatingWalkieTalkie {
                let elapsed = elapsedSessionMilliseconds()
                analytics.trackSocketDrop(mode: mode, elapsedMs: elapsed)
                await stopKeep(
                    reason: "socket_drop",
                    timeout: .zero,
                    announceStop: false,
                    gracefulFinalize: false,
                    trigger: "socket_closed_event"
                )
            }
        case .failed(let stage, let code, let message):
            logDictation("DICTATION_COORD soniox_event failed stage=\(stage.rawValue) code=\(code ?? "nil") message=\(message)")
            analytics.trackError(errorCode: code, stage: stage.rawValue)
            await handleTransportFailure(stage: stage, message: message)
        }
    }

    private func handleAudioCaptureEvent(_ event: DictationAudioCaptureEvent) async {
        switch event {
        case .interruptionBegan:
            logger.notice("Dictation capture interruption began")
            analytics.trackError(errorCode: nil, stage: "audio_interruption")
        case .interruptionEnded(let shouldResume):
            logger.notice("Dictation capture interruption ended shouldResume=\(shouldResume, privacy: .public)")
        case .routeChanged:
            logger.notice("Dictation audio route changed")
            analytics.trackError(errorCode: nil, stage: "audio_route_change")
        case .mediaServicesReset:
            logger.notice("Dictation media services reset")
            analytics.trackError(errorCode: nil, stage: "audio_media_services_reset")
        case .failed(let message):
            logger.notice("Dictation audio event failed: \(message, privacy: .public)")
            logDictation("DICTATION_COORD audio_event failed message=\(message)")
            await handleTransportFailure(stage: .audio, message: message)
        }
    }

    private func handleProtocolError(code: String?, message: String) {
        analytics.trackError(errorCode: code, stage: "protocol")
        Task { [weak self] in
            guard let self else { return }
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_PROTOCOL_ERROR caller=handleProtocolError ts=\(Date().timeIntervalSince1970) code=\(code ?? "nil")")
            await self.stopKeep(
                reason: "protocol_error",
                timeout: .zero,
                announceStop: false,
                gracefulFinalize: false,
                trigger: "protocol_error_event"
            )
            logDictation("DICTATION_ERROR path=handleProtocolError ts=\(Date().timeIntervalSince1970) code=\(code ?? "nil") message=\(message)")
            self.enterError(message: message, source: "handleProtocolError")
        }
    }

    private func handleTransportFailure(stage: SonioxStreamingClientStage, message: String) async {
        guard isDictationActive else { return }
        logDictation("DICTATION_STOP trace_id=DICTATION_STOP_TRANSPORT_FAILURE caller=handleTransportFailure ts=\(Date().timeIntervalSince1970) stage=\(stage.rawValue) message=\(message)")
        analytics.trackError(errorCode: nil, stage: stage.rawValue)
        await stopKeep(
            reason: "transport_failure",
            timeout: .zero,
            announceStop: false,
            gracefulFinalize: false,
            trigger: "transport_failure_event"
        )
        logDictation("DICTATION_ERROR path=handleTransportFailure ts=\(Date().timeIntervalSince1970) stage=\(stage.rawValue) message=\(message)")
        enterError(message: "Dictation failed", source: "handleTransportFailure")
    }

    @discardableResult
    private func stopKeep(
        reason: String,
        timeout: Duration,
        announceStop: Bool = true,
        gracefulFinalize: Bool = true,
        trigger: String = "unspecified",
        callSite: String = DictationCoordinator.callSite()
    ) async -> Bool {
        logDictation(
            "DICTATION_STOP stopKeep_top ts=\(Date().timeIntervalSince1970) reason=\(reason) " +
            "state=\(String(describing: state)) callsite=\(callSite)"
        )
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .stoppingKeep else {
            logger.notice(
                "Dictation stopKeep ignored reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
            )
            return false
        }

        pendingStopContext = "trigger=\(trigger) callSite=\(callSite)"
        logger.notice(
            "Dictation stopKeep requested reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) gracefulFinalize=\(gracefulFinalize, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
        )

        if state != .stoppingKeep {
            state = .stoppingKeep
        }

        maxDurationTask?.cancel()
        cancelTokenInactivityTimer(reason: "stopKeep_enter")
        flushPendingTranscriptApply()

        var finalizedWithinTimeout = false

        if gracefulFinalize {
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_SEND_FINALIZE_INTERNAL reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
            )
            do {
                try await streamingClient?.sendFinalize()
            } catch {
                logDictation("DICTATION_ERROR path=stopKeep_sendFinalize ts=\(Date().timeIntervalSince1970) reason=\(reason) error=\(error.localizedDescription)")
                enterError(message: "Failed to finalize dictation", source: "stopKeep_sendFinalize")
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

        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_CLOSE_CLIENT_FINALIZE reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )
        streamingClient?.close(
            code: .normalClosure,
            reason: "client_finalize",
            caller: "DictationCoordinator.stopKeep reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )
        finalizeSessionCleanup(reason: reason, announceStop: announceStop)
        return finalizedWithinTimeout
    }

    private func stopDiscard(
        reason: String,
        trigger: String = "unspecified",
        callSite: String = DictationCoordinator.callSite()
    ) {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .stoppingKeep else { return }

        pendingStopContext = "trigger=\(trigger) callSite=\(callSite)"
        logger.notice(
            "Dictation stopDiscard requested reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
        )

        state = .stoppingDiscard

        maxDurationTask?.cancel()
        cancelTokenInactivityTimer(reason: "stopDiscard_enter")
        cancelPendingTranscriptApply()

        audioCapture?.stop()
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_DISCARD_CLOSE_CLIENT_CANCELLED reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )
        streamingClient?.close(
            code: .normalClosure,
            reason: "client_cancelled",
            caller: "DictationCoordinator.stopDiscard reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )

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
        let stopContext = pendingStopContext ?? "trigger=unknown callSite=unknown"
        logger.notice(
            "Dictation finalizeSessionCleanup reason=\(reason, privacy: .public) stopContext=\(stopContext, privacy: .public) announceStop=\(announceStop, privacy: .public) durationMs=\(duration, privacy: .public)"
        )
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
        audioEventTask?.cancel()
        maxDurationTask?.cancel()
        cancelTokenInactivityTimer(reason: "finalizeSessionCleanup")
        errorDismissTask?.cancel()
        streamSwitchStopTask?.cancel()
        transcriptApplyTask?.cancel()

        eventTask = nil
        frameTask = nil
        levelTask = nil
        audioEventTask = nil
        maxDurationTask = nil
        errorDismissTask = nil
        streamSwitchStopTask = nil
        transcriptApplyTask = nil

        audioCapture = nil
        streamingClient = nil

        originSessionKey = nil
        preDictationSnapshot = .empty
        pendingTranscriptText = nil
        lastAppliedTranscriptText = ""
        pendingActivationMode = nil
        pendingStopContext = nil

        if state != .error {
            state = idleStateForCurrentContext()
        }
    }

    private func enterError(message: String, source: String = "unspecified") {
        logDictation("DICTATION_ERROR enter_error ts=\(Date().timeIntervalSince1970) source=\(source) state=\(String(describing: state)) message=\(message)")
        logDictation("DICTATION_COORD enter_error message=\(message)")
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
                logDictation("DICTATION_ERROR auto_dismiss ts=\(Date().timeIntervalSince1970) source=\(source) message=\(self.errorMessage ?? "nil")")
                self.errorMessage = nil
                if !self.isDictationActive {
                    self.state = self.idleStateForCurrentContext()
                }
            }
        }
    }

    private func idleStateForCurrentContext() -> DictationState {
        if !isTextFieldFocused,
           composeIsEmpty,
           !isDictationActive {
            return .idleMicVisible
        }
        return .idleMicHidden
    }

    private static func mappedDisplacement(for rms: Float) -> CGFloat {
        guard rms > 0 else { return 0.35 }
        let db = 20 * log10(rms)
        let minDb: Float = -55
        let maxDb: Float = -10
        let clamped = min(max((db - minDb) / (maxDb - minDb), 0), 1)
        let eased = pow(clamped, 0.7)
        return CGFloat(0.35 + eased * 8.65)
    }

    private func elapsedSessionMilliseconds() -> Int {
        guard let sessionStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
    }

    private func refreshInlineKeyFromStore() {
        inlineKeyText = editableAPIKeyProvider()
        inlineKeyStatus = keyStatusProvider()
    }

    private func queueTranscriptApply(_ transcriptText: String, immediate: Bool) {
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=queue_transcript_apply immediate=\(immediate) chars=\(transcriptText.count)")
        pendingTranscriptText = transcriptText
        if immediate {
            flushPendingTranscriptApply()
            return
        }
        guard transcriptApplyTask == nil else { return }
        transcriptApplyTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timing.composeUpdateCoalescingInterval)
            guard !Task.isCancelled else { return }
            await self.flushPendingTranscriptApply()
        }
    }

    private func flushPendingTranscriptApply() {
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=flush_transcript_apply_begin")
        transcriptApplyTask?.cancel()
        transcriptApplyTask = nil
        guard let transcriptText = pendingTranscriptText else { return }
        pendingTranscriptText = nil
        applyTranscriptIfNeeded(transcriptText)
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=flush_transcript_apply_end")
    }

    private func cancelPendingTranscriptApply() {
        transcriptApplyTask?.cancel()
        transcriptApplyTask = nil
        pendingTranscriptText = nil
    }

    private func logDictation(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print(message)
    }

    private func applyTranscriptIfNeeded(_ transcriptText: String) {
        guard transcriptText != lastAppliedTranscriptText else { return }
        guard let originSessionKey else { return }
        let wallTs = Date().timeIntervalSince1970
        logDictation("DICTATION_PERF ts=\(wallTs) event=apply_transcript_begin chars=\(transcriptText.count)")
        let startedAt = CFAbsoluteTimeGetCurrent()
        lastAppliedTranscriptText = transcriptText
        bridge.apply(transcript: transcriptText, baseSnapshot: preDictationSnapshot, to: originSessionKey)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=apply_transcript_end elapsedMs=\(elapsedMs)")
        logger.notice("[DICTATION-PERF] applyTranscriptIfNeeded: \(elapsedMs, privacy: .public)ms")
    }
}
