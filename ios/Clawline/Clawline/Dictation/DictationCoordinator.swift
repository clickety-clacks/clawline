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

private enum DictationState: Equatable {
    case idleSurfaceClosed
    case keyPromptModal
    case keyVerifyingModal
    case dictatingSticky
    case dictatingPaused
    case dictatingWalkieTalkie
    case finalizing
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

enum SurfaceTarget: Sendable {
    case closed
    case open
}

@Observable
@MainActor
final class DictationSession {
    private enum WaveformDefaults {
        static let amplitudeFloor: CGFloat = 0.35
        static let amplitudeRange: CGFloat = 8.65
    }

    private enum WalkieOrigin {
        case pushHold
        case pausedHold
    }

    private enum PrewarmTeardownReason: String {
        case gestureAbandon = "gesture_abandon"
        case phase1IdleTimeout = "phase1_idle_timeout"
        case viewInactive = "view_inactive"
    }

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "DictationCoordinator")
    private var state: DictationState = .idleSurfaceClosed {
        didSet {
            guard oldValue != state else { return }
            let trace = "DICTATION_COORD state \(String(describing: oldValue)) -> \(String(describing: state))"
            logDictation(trace)
            surfaceTarget = isSurfaceOpen ? .open : .closed
        }
    }
    private(set) var errorMessage: String?
    private(set) var audioLevel: CGFloat = 1
    private(set) var reduceMotionEnabled: Bool = UIAccessibility.isReduceMotionEnabled
    private(set) var surfaceTarget: SurfaceTarget = .closed {
        didSet {
            guard oldValue != surfaceTarget else { return }
            setSystemIdleSleepDisabled(surfaceTarget == .open)
        }
    }

    private func setSystemIdleSleepDisabled(_ disabled: Bool) {
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
#endif
    }

    var inlineKeyText: String {
        get { keyStore.editableKey }
        set { keyStore.setKey(newValue) }
    }

    var inlineKeyStatus: SonioxKeyVerificationStatus {
        keyStore.keyStatus
    }

    var inlineKeyActionTitle: String {
        keyStore.ctaTitle
    }

    var inlineKeyStatusText: String? {
        keyStore.statusText
    }

    var showsComposeKeyPromptModal: Bool {
        state == .keyPromptModal || state == .keyVerifyingModal
    }

    var isDictationActive: Bool {
        switch state {
        case .dictatingSticky, .dictatingPaused, .dictatingWalkieTalkie, .finalizing, .stoppingKeep, .stoppingDiscard:
            return true
        case .idleSurfaceClosed, .keyPromptModal, .keyVerifyingModal, .error:
            return false
        }
    }

    var isListening: Bool {
        state == .dictatingSticky || state == .dictatingWalkieTalkie
    }

    var isListeningReady: Bool {
        isListening && isPhase3StreamingAudio && isSocketConnected
    }

    var isStickyDictationActive: Bool {
        state == .dictatingSticky
    }

    var isWalkieTalkieActive: Bool {
        state == .dictatingWalkieTalkie
    }

    var isWaveformVisible: Bool {
        switch state {
        case .dictatingSticky, .dictatingPaused, .dictatingWalkieTalkie, .finalizing, .stoppingKeep, .stoppingDiscard:
            return true
        case .idleSurfaceClosed, .keyPromptModal, .keyVerifyingModal, .error:
            return false
        }
    }

    var isSurfaceOpen: Bool {
        isWaveformVisible || state == .error || state == .keyPromptModal || state == .keyVerifyingModal
    }

    var micVisible: Bool {
        !isSurfaceOpen
    }

    var swipeActivationEnabled: Bool {
        !isSurfaceOpen && selectionLength == 0
    }

    private let bridge: ComposeInputDictationBridge
    private let keyStore: SonioxKeyStore
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
    private var contextTerms: [String] = []

    private var originSessionKey: String?
    private var preDictationSnapshot: ComposeDraftSnapshot = .empty
    private var transcriptBuffer = DictationTranscriptBuffer()
    private var pendingTranscriptText: String?
    private var pendingActivationMode: DictationMode?
    private(set) var mode: DictationMode?
    private var sessionStartedAt: Date?
    private var lastTokenAt: Date?
    private var finishedReceived = false
    private var pendingStopContext: String?
    private var walkieOrigin: WalkieOrigin?

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
    private var tokenInactivityDeadline: Date?
    private var maxDurationTaskID: UInt64 = 0
    private var activeMaxDurationTaskID: UInt64?
    private var maxDurationDeadline: Date?
    private var streamSwitchStopTask: Task<Void, Never>?
    private var transcriptApplyTask: Task<Void, Never>?
    private var phase1IdleTeardownTask: Task<Void, Never>?
    private var prewarmConnectTask: Task<Void, Never>?
    private var pauseListeningInFlight = false
    private var activationGeneration: UInt64 = 0
    private var prewarmGeneration: UInt64?
    private var isPhase3StreamingAudio = false
    private var isSocketConnected = false
    private var bufferedAudioFrames: [Data] = []
    private let maxBufferedAudioFrames = 64
    private var lastAudioActivityResetAt: Date?
    private var suppressedPrewarmFailureBudget = 0
    private var dictationAttemptID: UInt64 = 0
    private var activeAttemptID: UInt64?
    private var audioDecodeTimeoutRecoveryCount: Int = 0

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return Double(components.seconds) + attoseconds
    }

    private func cancelMaxDurationTimer(reason: String, caller: String) {
        guard let maxDurationTask else { return }
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_MAX_DURATION_CANCEL " +
            "caller=\(caller) reason=\(reason) task_id=\(activeMaxDurationTaskID.map(String.init) ?? "nil") " +
            "deadline_ts=\(maxDurationDeadline?.timeIntervalSince1970 ?? -1) ts=\(Date().timeIntervalSince1970) \(attemptContext())"
        )
        maxDurationTask.cancel()
        self.maxDurationTask = nil
        activeMaxDurationTaskID = nil
        maxDurationDeadline = nil
    }

    nonisolated private static func callSite(
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) -> String {
        "\(fileID):\(line) \(function)"
    }

    init(
        bridge: ComposeInputDictationBridge,
        keyStore: SonioxKeyStore,
        languageHintProvider: @escaping () -> String = { DictationLanguageHintResolver.resolve() },
        audioCaptureFactory: @escaping () -> any DictationAudioCapturing = { DictationAudioCapture() },
        streamingClientFactory: @escaping () -> any SonioxStreamingClienting = { SonioxStreamingClient() },
        analytics: any DictationAnalyticsTracking = DictationAnalytics(),
        feedback: (any DictationFeedbackProviding)? = nil,
        timing: DictationTiming = DictationTiming()
    ) {
        self.bridge = bridge
        self.keyStore = keyStore
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
        reduceMotionEnabled: Bool,
        contextTerms: [String] = []
    ) {
        let previousSession = currentSessionKey
        self.currentSessionKey = sessionKey
        self.composeIsEmpty = composeIsEmpty
        self.isTextFieldFocused = textFieldFocused
        self.selectionLength = selectionLength
        self.reduceMotionEnabled = reduceMotionEnabled
        self.contextTerms = contextTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sessionKey.isEmpty {
            teardownPhase1(reason: PrewarmTeardownReason.viewInactive.rawValue)
        } else {
            preparePhase1IfNeeded()
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
                    collapseSurface: false,
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
            state = .idleSurfaceClosed
        }
    }

    func setComposeTextView(_ textView: PastableTextView?) {
        bridge.setComposeTextView(textView)
    }

    func preparePhase1IfNeeded() {
        guard !currentSessionKey.isEmpty else { return }
        guard !isListening else { return }
        schedulePhase1IdleTeardown()
    }

    func teardownPhase1(reason: String) {
        phase1IdleTeardownTask?.cancel()
        phase1IdleTeardownTask = nil
        cancelGesturePrewarmIfNeeded(trigger: reason)
    }

    func beginGesturePrewarm() {
        schedulePhase1IdleTeardown()
        guard !isSurfaceOpen else { return }
        guard !isListening else { return }
        // Do not open Soniox sockets during gesture prewarm.
        // Opening phase-2 connections before phase-3 audio streaming can lead to
        // server-side decode timeouts when the user abandons the gesture.
        logDictation("DICTATION_CONN gesture_prewarm_phase2_skipped strategy=phase3_only")
    }

    func cancelGesturePrewarmIfNeeded(trigger: String = "gesture_abandon") {
        guard !isListening else { return }
        guard state == .idleSurfaceClosed || state == .keyPromptModal || state == .keyVerifyingModal else { return }
        logDictation("DICTATION_COORD prewarm_cancel trigger=\(trigger)")
        closeAndResetRealtimePipeline(closeReason: "prewarm_cancelled")
        prewarmGeneration = nil
        prewarmConnectTask?.cancel()
        prewarmConnectTask = nil
        bufferedAudioFrames.removeAll(keepingCapacity: false)
        isPhase3StreamingAudio = false
        isSocketConnected = false
    }

    func startStickyDictation() {
        logDictation("DICTATION_UI startStickyDictation state=\(String(describing: state)) \(attemptContext())")
        if state == .dictatingPaused {
            resumeFromPaused()
            return
        }
        walkieOrigin = nil
        start(mode: .sticky)
    }

    func startWalkieTalkieDictation() {
        logDictation("DICTATION_UI startWalkieTalkieDictation state=\(String(describing: state)) \(attemptContext())")
        walkieOrigin = .pushHold
        start(mode: .walkieTalkie)
    }

    func startWalkieTalkieFromPausedSurface() {
        guard state == .dictatingPaused else { return }
        walkieOrigin = .pausedHold
        start(mode: .walkieTalkie)
    }

    func pauseFromWaveformTap() {
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            await self?.pauseListening(reason: "waveform_tap_pause")
        }
    }

    func toggleWaveformTapAction() {
        if state == .dictatingPaused {
            resumeFromPaused()
        } else {
            pauseFromWaveformTap()
        }
    }

    func dismissSurfaceFromUserGesture() {
        guard isSurfaceOpen else { return }
        if state == .keyPromptModal || state == .keyVerifyingModal {
            dismissComposeKeyPrompt()
            return
        }
        Task { [weak self] in
            await self?.stopKeep(
                reason: "surface_dismiss",
                timeout: timing.stopKeepFinalizeTimeout,
                collapseSurfaceImmediately: true,
                trigger: "user_swipe_down"
            )
        }
    }

    func updateInlineKeyText(_ value: String) {
        inlineKeyText = value
    }

    func handleComposeKeyPrimaryAction(openKeyURL: (URL) -> Void) async {
        let trimmed = inlineKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state = .keyPromptModal
            openKeyURL(SonioxConfigurationStore.keyManagementURL)
            return
        }

        state = .keyVerifyingModal
        keyStore.setKey(trimmed)
        let isValid = await keyStore.verify()
        if isValid {
            let requestedMode = pendingActivationMode
            pendingActivationMode = nil
            if let requestedMode {
                start(mode: requestedMode)
            } else {
                state = idleStateForCurrentContext()
            }
        } else {
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
            guard let self else { return }
            switch self.walkieOrigin {
            case .pushHold:
                logDictation("DICTATION_STOP trace_id=DICTATION_STOP_WALKIE_RELEASE caller=walkie_release_collapse ts=\(Date().timeIntervalSince1970)")
                await self.stopKeep(
                    reason: "walkie_release",
                    timeout: self.timing.stopKeepFinalizeTimeout,
                    trigger: "walkie_release_collapse"
                )
            case .pausedHold:
                await self.pauseListening(reason: "walkie_release_to_paused")
            case .none:
                await self.pauseListening(reason: "walkie_release_to_paused")
            }
        }
    }

    func stopFromEscapeKey() {
        guard state == .dictatingSticky || state == .dictatingPaused else { return }
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
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie else { return }
        logDictation("DICTATION_STOP trace_id=DICTATION_DISCARD_ESCAPE_LONG_PRESS caller=discardFromEscapeLongPress ts=\(Date().timeIntervalSince1970)")
        stopDiscard(reason: "escape_long_press", trigger: "keyboard_escape_long_press")
    }

    func stopFromVoiceOverAction() {
        guard state == .dictatingSticky || state == .dictatingPaused else { return }
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
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie else { return }
        logDictation("DICTATION_STOP trace_id=DICTATION_DISCARD_VOICEOVER caller=discardFromVoiceOverAction ts=\(Date().timeIntervalSince1970)")
        stopDiscard(reason: "voiceover_discard", trigger: "voiceover_discard_action")
    }

    func handleSendTapped(sendAction: @escaping () -> Void) {
        logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SEND_TAPPED_ENTRY caller=handleSendTapped_entry ts=\(Date().timeIntervalSince1970) state=\(String(describing: state))")
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie || state == .stoppingKeep || state == .finalizing else {
            sendAction()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SEND_TAP_FINALIZATION caller=send_tap_finalization ts=\(Date().timeIntervalSince1970)")
            let finalizedWithinTimeout: Bool
            if self.state == .dictatingWalkieTalkie {
                finalizedWithinTimeout = await self.stopKeep(
                    reason: "send_tap_walkie",
                    timeout: self.timing.stopKeepFinalizeTimeout,
                    collapseSurfaceImmediately: true,
                    trigger: "send_tap_finalization_walkie"
                )
            } else {
                await self.pauseListening(reason: "send_tap_pause")
                finalizedWithinTimeout = true
            }
            await MainActor.run {
                sendAction()
            }
            self.analytics.trackSendWhileActive(finalizedWithinTimeout: finalizedWithinTimeout)
        }
    }

    func handleAppBackgrounded() {
        teardownPhase1(reason: PrewarmTeardownReason.viewInactive.rawValue)
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            await self?.stopKeep(
                reason: "app_background",
                timeout: self?.timing.stopKeepFinalizeTimeout ?? .milliseconds(1_200),
                announceStop: false,
                collapseSurface: false,
                trigger: "app_background"
            )
        }
    }

    private func start(mode: DictationMode) {
        guard !isListening else { return }
        guard !currentSessionKey.isEmpty else { return }
        guard let apiKey = validatedAPIKeyOrNil() else {
            pendingActivationMode = mode
            state = .keyPromptModal
            return
        }

        dictationAttemptID &+= 1
        activeAttemptID = dictationAttemptID
        let generation = prewarmGeneration ?? nextActivationGeneration()
        pendingActivationMode = nil
        self.mode = mode
        logDictation("DICTATION_ATTEMPT start_requested start_mode=\(mode.rawValue) \(attemptContext())")
        let needsSessionContextInitialization =
            state != .dictatingPaused ||
            originSessionKey == nil ||
            originSessionKey != currentSessionKey

        if needsSessionContextInitialization {
            self.originSessionKey = currentSessionKey
            bridge.resetTranscriptState(for: currentSessionKey)
            logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=capture_snapshot_begin session=\(currentSessionKey)")
            self.preDictationSnapshot = bridge.captureSnapshot(for: currentSessionKey)
            logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=capture_snapshot_end session=\(currentSessionKey)")
            self.transcriptBuffer.reset()
            self.pendingTranscriptText = nil
        }
        self.finishedReceived = false
        self.audioDecodeTimeoutRecoveryCount = 0
        self.sessionStartedAt = Date()
        self.lastTokenAt = Date()
        self.audioLevel = 1
        self.errorMessage = nil
        self.walkieOrigin = mode == .walkieTalkie ? .pushHold : nil

        feedback.impactLight()
        if state != .dictatingPaused {
            feedback.announce("Dictation started")
        }

        switch mode {
        case .sticky:
            state = .dictatingSticky
        case .walkieTalkie:
            state = .dictatingWalkieTalkie
        }
        logDictation("DICTATION_ATTEMPT mode_committed \(attemptContext())")

        analytics.trackStart(mode: mode, sessionKey: currentSessionKey)
        if prewarmGeneration != generation {
            beginPhase2Prewarm(apiKey: apiKey, generation: generation)
        }
        isPhase3StreamingAudio = true
        flushBufferedFramesIfPossible()
        armSessionDurationTimer()
        resetTokenInactivityTimer()
        schedulePhase1IdleTeardown()
    }

    private func nextActivationGeneration() -> UInt64 {
        activationGeneration &+= 1
        return activationGeneration
    }

    private func validatedAPIKeyOrNil() -> String? {
        let key = keyStore.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private func attemptContext() -> String {
        "attempt_id=\(activeAttemptID.map(String.init) ?? "nil") generation=\(prewarmGeneration.map(String.init) ?? "nil") mode=\(String(describing: mode)) state=\(String(describing: state)) socket=\(isSocketConnected) phase3=\(isPhase3StreamingAudio)"
    }

    private func beginPhase2Prewarm(apiKey: String, generation: UInt64) {
        closeAndResetRealtimePipeline(closeReason: "phase2_replacement")
        prewarmGeneration = generation
        suppressedPrewarmFailureBudget = 1
        isPhase3StreamingAudio = false
        isSocketConnected = false
        bufferedAudioFrames.removeAll(keepingCapacity: true)

        let client = streamingClientFactory()
        streamingClient = client

        let capture = audioCaptureFactory()
        audioCapture = capture

        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                await self.handleSonioxEvent(event)
            }
        }

        frameTask = Task { [weak self] in
            guard let self else { return }
            for await frame in capture.frameStream {
                await self.handleCapturedFrame(frame)
            }
        }

        levelTask = Task { [weak self] in
            guard let self else { return }
            let minimumWaveformUpdateInterval: CFTimeInterval = 1.0 / 60.0
            var lastWaveformUpdateAt = CFAbsoluteTimeGetCurrent() - minimumWaveformUpdateInterval
            var lastAppliedDisplacement: CGFloat = WaveformDefaults.amplitudeFloor
            let minDisplacement: CGFloat = WaveformDefaults.amplitudeFloor
            let maxDisplacement: CGFloat = WaveformDefaults.amplitudeFloor + WaveformDefaults.amplitudeRange
            let fastAttackAlpha: CGFloat = 0.82
            let slowReleaseAlpha: CGFloat = 0.18
            for await level in capture.levelStream {
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastWaveformUpdateAt >= minimumWaveformUpdateInterval else { continue }
                lastWaveformUpdateAt = now
                let mappedDisplacement = Self.mappedDisplacement(for: level)
                let targetDisplacement = min(max(mappedDisplacement, minDisplacement), maxDisplacement)
                let isAttacking = targetDisplacement >= lastAppliedDisplacement
                let alpha = isAttacking ? fastAttackAlpha : slowReleaseAlpha
                let nextDisplacement = lastAppliedDisplacement + ((targetDisplacement - lastAppliedDisplacement) * alpha)
                guard abs(nextDisplacement - lastAppliedDisplacement) >= 0.004 else { continue }
                lastAppliedDisplacement = nextDisplacement
                await MainActor.run {
                    self.audioLevel = nextDisplacement
                }
            }
        }

        audioEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in capture.eventStream {
                await self.handleAudioCaptureEvent(event)
            }
        }

        prewarmConnectTask = Task { [weak self] in
            guard let self else { return }
            var lastError: Error?
            for attempt in 1...2 {
                do {
                    logDictation("DICTATION_CONN phase2_connect_begin connect_attempt=\(attempt) \(attemptContext())")
                    try capture.start()
                    try await client.connect(
                        config: SonioxStreamingConfig(
                            apiKey: apiKey,
                            languageHint: languageHintProvider(),
                            contextTerms: self.contextTerms
                        )
                    )
                    await MainActor.run {
                        guard self.prewarmGeneration == generation else { return }
                        self.isSocketConnected = true
                        self.logDictation("DICTATION_CONN phase2_connect_success connect_attempt=\(attempt) \(self.attemptContext())")
                        self.prewarmConnectTask = nil
                        self.suppressedPrewarmFailureBudget = 0
                        self.flushBufferedFramesIfPossible()
                    }
                    return
                } catch {
                    lastError = error
                    logDictation("DICTATION_CONN phase2_connect_failed connect_attempt=\(attempt) error=\(error.localizedDescription) \(attemptContext())")
                    capture.stop()
                    client.close(code: .goingAway, reason: "phase2_retry", caller: "DictationSession.beginPhase2Prewarm attempt=\(attempt)")
                    if attempt < 2 {
                        do {
                            try await Task.sleep(for: .milliseconds(220))
                        } catch is CancellationError {
                            return
                        } catch {
                            return
                        }
                    }
                }
            }
            await MainActor.run {
                guard self.prewarmGeneration == generation else { return }
                self.prewarmConnectTask = nil
                self.suppressedPrewarmFailureBudget = 0
                self.closeAndResetRealtimePipeline(closeReason: "phase2_connect_failed")
                if let lastError {
                    self.logDictation("DICTATION_CONN phase2_connect_final_failed error=\(lastError.localizedDescription) \(self.attemptContext())")
                }
                self.enterError(message: "Dictation failed", source: "phase2_connect")
            }
        }
    }

    private func handleCapturedFrame(_ frame: Data) async {
        if !isPhase3StreamingAudio || !isSocketConnected {
            bufferedAudioFrames.append(frame)
            if bufferedAudioFrames.count > maxBufferedAudioFrames {
                bufferedAudioFrames.removeFirst(bufferedAudioFrames.count - maxBufferedAudioFrames)
            }
            return
        }

        do {
            try await streamingClient?.sendAudioFrame(frame)
        } catch {
            await handleTransportFailure(stage: .send, message: error.localizedDescription)
        }
    }

    private func flushBufferedFramesIfPossible() {
        guard isPhase3StreamingAudio, isSocketConnected else { return }
        guard !bufferedAudioFrames.isEmpty else { return }
        let frames = bufferedAudioFrames
        bufferedAudioFrames.removeAll(keepingCapacity: true)
        Task { [weak self] in
            guard let self else { return }
            for frame in frames {
                do {
                    try await self.streamingClient?.sendAudioFrame(frame)
                } catch {
                    await self.handleTransportFailure(stage: .send, message: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func armSessionDurationTimer() {
        if mode == .walkieTalkie {
            cancelMaxDurationTimer(reason: "walkie_mode_skip", caller: "armSessionDurationTimer")
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_MAX_DURATION_SKIP " +
                "caller=armSessionDurationTimer reason=walkie_mode \(attemptContext())"
            )
            return
        }
        cancelMaxDurationTimer(reason: "replace_existing", caller: "armSessionDurationTimer")
        maxDurationTaskID &+= 1
        let taskID = maxDurationTaskID
        activeMaxDurationTaskID = taskID
        let startedAt = Date().timeIntervalSince1970
        let deadline = Date(timeIntervalSinceNow: durationSeconds(timing.maxSessionDuration))
        maxDurationDeadline = deadline
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_MAX_DURATION_START " +
            "caller=armSessionDurationTimer task_id=\(taskID) ts=\(startedAt) deadline_ts=\(deadline.timeIntervalSince1970) " +
            "timeout=\(String(describing: timing.maxSessionDuration)) " +
            "\(attemptContext())"
        )
        maxDurationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: timing.maxSessionDuration)
            } catch {
                self.logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_MAX_DURATION_CANCELLED_OBSERVED " +
                    "caller=timer_max_duration task_id=\(taskID) ts=\(Date().timeIntervalSince1970) \(self.attemptContext())"
                )
                return
            }
            guard !Task.isCancelled else {
                self.logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_MAX_DURATION_CANCELLED_OBSERVED " +
                    "caller=timer_max_duration task_id=\(taskID) ts=\(Date().timeIntervalSince1970) \(self.attemptContext())"
                )
                return
            }
            let elapsedSinceLastToken = self.lastTokenAt.map { Date().timeIntervalSince($0) } ?? -1
            self.logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_MAX_DURATION_FIRED " +
                "caller=timer_max_duration task_id=\(taskID) ts=\(Date().timeIntervalSince1970) " +
                "elapsed_since_last_token_s=\(elapsedSinceLastToken) \(self.attemptContext())"
            )
            self.activeMaxDurationTaskID = nil
            self.maxDurationDeadline = nil
            await self.pauseListening(reason: "max_duration")
        }
    }

    private func resetTokenInactivityTimer() {
        if mode == .walkieTalkie {
            cancelTokenInactivityTimer(reason: "walkie_mode_skip")
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_SKIP " +
                "caller=resetTokenInactivityTimer reason=walkie_mode \(attemptContext())"
            )
            return
        }
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_RESET " +
            "caller=resetTokenInactivityTimer ts=\(Date().timeIntervalSince1970) " +
            "state=\(String(describing: state)) timeout=\(String(describing: timing.tokenInactivityTimeout)) " +
            "\(attemptContext())"
        )
        cancelTokenInactivityTimer(reason: "reset_token_inactivity_timer")
        tokenInactivityTaskID &+= 1
        let taskID = tokenInactivityTaskID
        activeTokenInactivityTaskID = taskID
        let deadline = Date(timeIntervalSinceNow: durationSeconds(timing.tokenInactivityTimeout))
        tokenInactivityDeadline = deadline
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_START " +
            "caller=resetTokenInactivityTimer task_id=\(taskID) ts=\(Date().timeIntervalSince1970) " +
            "deadline_ts=\(deadline.timeIntervalSince1970) " +
            "state=\(String(describing: state)) \(attemptContext())"
        )
        tokenInactivityTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: timing.tokenInactivityTimeout)
            } catch {
                self.logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_CANCELLED_OBSERVED " +
                    "caller=timer_token_inactivity task_id=\(taskID) ts=\(Date().timeIntervalSince1970) \(self.attemptContext())"
                )
                return
            }
            if Task.isCancelled {
                self.logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_CANCELLED_OBSERVED " +
                    "caller=timer_token_inactivity task_id=\(taskID) ts=\(Date().timeIntervalSince1970) \(self.attemptContext())"
                )
                return
            }
            let elapsedSinceLastToken = self.lastTokenAt.map { Date().timeIntervalSince($0) } ?? -1
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY " +
                "caller=timer_token_inactivity task_id=\(taskID) ts=\(Date().timeIntervalSince1970) " +
                "elapsed_since_last_token_s=\(elapsedSinceLastToken) \(attemptContext())"
            )
            activeTokenInactivityTaskID = nil
            tokenInactivityDeadline = nil
            await self.pauseListening(reason: "token_inactivity")
        }
    }

    private func markInactivityActivity(source: String, caller: String) {
        let now = Date()
        if source == "audio_level",
           let lastAudioActivityResetAt,
           now.timeIntervalSince(lastAudioActivityResetAt) < 0.35 {
            return
        }
        if source == "audio_level" {
            self.lastAudioActivityResetAt = now
        }
        lastTokenAt = now
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_ACTIVITY " +
            "source=\(source) caller=\(caller) ts=\(now.timeIntervalSince1970)"
        )
        resetTokenInactivityTimer()
    }

    private func cancelTokenInactivityTimer(reason: String) {
        guard let tokenInactivityTask else { return }
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_CANCEL " +
            "caller=cancelTokenInactivityTimer reason=\(reason) " +
            "task_id=\(activeTokenInactivityTaskID.map(String.init) ?? "nil") " +
            "deadline_ts=\(tokenInactivityDeadline?.timeIntervalSince1970 ?? -1) " +
            "ts=\(Date().timeIntervalSince1970) \(attemptContext())"
        )
        tokenInactivityTask.cancel()
        self.tokenInactivityTask = nil
        activeTokenInactivityTaskID = nil
        tokenInactivityDeadline = nil
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
                audioDecodeTimeoutRecoveryCount = 0
                let ts = Date().timeIntervalSince1970
                logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TOKEN_RECEIVED " +
                    "caller=handleSonioxEvent token_count=\(response.tokens.count) finished=\(response.finished) ts=\(ts)"
                )
                markInactivityActivity(source: "soniox_token", caller: "handleSonioxEvent")
            }

            if response.finished {
                finishedReceived = true
                logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_FINISHED_RECEIVED " +
                    "caller=handleSonioxEvent ts=\(Date().timeIntervalSince1970) \(attemptContext())"
                )
                if state == .stoppingKeep || state == .finalizing {
                    // stopKeep() polls this flag.
                }
            }
        case .closed:
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SOCKET_CLOSED_EVENT caller=soniox_event_closed state=\(String(describing: state)) mode=\(String(describing: mode)) \(attemptContext())")
            if let mode,
               state == .dictatingSticky || state == .dictatingWalkieTalkie {
                let elapsed = elapsedSessionMilliseconds()
                analytics.trackSocketDrop(mode: mode, elapsedMs: elapsed)
                await pauseListening(reason: "socket_drop")
            }
        case .failed(let stage, let code, let message):
            logDictation("DICTATION_CONN soniox_event_failed stage=\(stage.rawValue) code=\(code ?? "nil") message=\(message) \(attemptContext())")
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
        if message.localizedCaseInsensitiveContains("audio decode timeout") {
            Task { [weak self] in
                await self?.recoverFromAudioDecodeTimeout(message: message)
            }
            return
        }
        analytics.trackError(errorCode: code, stage: "protocol")
        Task { [weak self] in
            guard let self else { return }
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_PROTOCOL_ERROR caller=handleProtocolError ts=\(Date().timeIntervalSince1970) code=\(code ?? "nil")")
            await self.stopKeep(
                reason: "protocol_error",
                timeout: .zero,
                announceStop: false,
                gracefulFinalize: false,
                collapseSurface: false,
                trigger: "protocol_error_event"
            )
            logDictation("DICTATION_ERROR path=handleProtocolError ts=\(Date().timeIntervalSince1970) code=\(code ?? "nil") message=\(message)")
            self.enterError(message: message, source: "handleProtocolError")
        }
    }

    private func recoverFromAudioDecodeTimeout(message: String) async {
        guard isDictationActive else { return }
        guard audioDecodeTimeoutRecoveryCount < 1 else {
            analytics.trackError(errorCode: nil, stage: "protocol")
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_PROTOCOL_ERROR caller=audio_decode_timeout_exhausted ts=\(Date().timeIntervalSince1970)")
            await stopKeep(
                reason: "protocol_error",
                timeout: .zero,
                announceStop: false,
                gracefulFinalize: false,
                collapseSurface: false,
                trigger: "protocol_error_event"
            )
            logDictation("DICTATION_ERROR path=recoverFromAudioDecodeTimeout ts=\(Date().timeIntervalSince1970) message=\(message)")
            enterError(message: message, source: "audio_decode_timeout")
            return
        }

        audioDecodeTimeoutRecoveryCount += 1
        logDictation(
            "DICTATION_CONN audio_decode_timeout_recovering recovery_count=\(audioDecodeTimeoutRecoveryCount) " +
            "ts=\(Date().timeIntervalSince1970) \(attemptContext())"
        )
        closeAndResetRealtimePipeline(closeReason: "audio_decode_timeout_retry")
        guard let apiKey = validatedAPIKeyOrNil() else {
            enterError(message: message, source: "audio_decode_timeout_missing_key")
            return
        }

        let generation = nextActivationGeneration()
        beginPhase2Prewarm(apiKey: apiKey, generation: generation)
        isPhase3StreamingAudio = true
        resetTokenInactivityTimer()
        armSessionDurationTimer()
    }

    private func handleTransportFailure(stage: SonioxStreamingClientStage, message: String) async {
        guard isDictationActive || prewarmConnectTask != nil else { return }
        if prewarmConnectTask != nil, suppressedPrewarmFailureBudget > 0 {
            suppressedPrewarmFailureBudget -= 1
            logDictation("DICTATION_COORD suppressed_prewarm_failure stage=\(stage.rawValue) message=\(message) \(attemptContext())")
            return
        }
        logDictation("DICTATION_STOP trace_id=DICTATION_STOP_TRANSPORT_FAILURE caller=handleTransportFailure ts=\(Date().timeIntervalSince1970) stage=\(stage.rawValue) message=\(message) \(attemptContext())")
        analytics.trackError(errorCode: nil, stage: stage.rawValue)
        await pauseListening(reason: "transport_failure")
        guard shouldPresentDictationErrorSurface else {
            logDictation("DICTATION_COORD transport_failure_suppressed_to_idle stage=\(stage.rawValue) message=\(message) \(attemptContext())")
            errorMessage = nil
            if !isDictationActive {
                state = .idleSurfaceClosed
            }
            return
        }
        logDictation("DICTATION_ERROR path=handleTransportFailure ts=\(Date().timeIntervalSince1970) stage=\(stage.rawValue) message=\(message)")
        enterError(message: "Dictation failed", source: "handleTransportFailure")
    }

    @discardableResult
    private func stopKeep(
        reason: String,
        timeout: Duration,
        announceStop: Bool = true,
        gracefulFinalize: Bool = true,
        collapseSurface: Bool = true,
        collapseSurfaceImmediately: Bool = false,
        trigger: String = "unspecified",
        callSite: String = DictationSession.callSite()
    ) async -> Bool {
        logDictation(
            "DICTATION_STOP stopKeep_top ts=\(Date().timeIntervalSince1970) reason=\(reason) " +
            "state=\(String(describing: state)) callsite=\(callSite) \(attemptContext())"
        )
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie || state == .stoppingKeep else {
            logger.notice(
                "Dictation stopKeep ignored reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
            )
            return false
        }

        pendingStopContext = "trigger=\(trigger) callSite=\(callSite)"
        logger.notice(
            "Dictation stopKeep requested reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) gracefulFinalize=\(gracefulFinalize, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
        )

        if state != .finalizing {
            state = .finalizing
        }

        if collapseSurface && collapseSurfaceImmediately {
            state = .idleSurfaceClosed
        }

        cancelMaxDurationTimer(reason: "stopKeep_enter", caller: "stopKeep")
        cancelTokenInactivityTimer(reason: "stopKeep_enter")
        flushPendingTranscriptApply()

        var finalizedWithinTimeout = false

        if gracefulFinalize {
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_FINALIZATION_HOLD_BEGIN " +
                "caller=stopKeep reason=\(reason) timeout=\(timeout) ts=\(Date().timeIntervalSince1970)"
            )
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
        let keepAudioForPausedWaveform = !collapseSurface
        if !keepAudioForPausedWaveform {
            audioCapture?.stop()
        }

        if gracefulFinalize {
            do {
                try await streamingClient?.sendAudioFrame(Data())
            } catch {
                // Best effort; closing still proceeds.
            }
        }

        if gracefulFinalize {
            finalizedWithinTimeout = await waitForFinished(timeout: timeout)
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_FINALIZATION_HOLD_END " +
                "caller=stopKeep reason=\(reason) finalized_within_timeout=\(finalizedWithinTimeout) ts=\(Date().timeIntervalSince1970)"
            )
        }

        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_CLOSE_CLIENT_FINALIZE reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )
        streamingClient?.close(
            code: .normalClosure,
            reason: "client_finalize",
            caller: "DictationSession.stopKeep reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )
        finalizeSessionCleanup(
            reason: reason,
            announceStop: announceStop,
            collapseSurface: collapseSurface,
            keepAudioForPausedWaveform: keepAudioForPausedWaveform
        )
        return finalizedWithinTimeout
    }

    private func stopDiscard(
        reason: String,
        trigger: String = "unspecified",
        callSite: String = DictationSession.callSite()
    ) {
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie || state == .stoppingKeep else { return }

        pendingStopContext = "trigger=\(trigger) callSite=\(callSite)"
        logDictation("DICTATION_STOP stopDiscard_entry reason=\(reason) trigger=\(trigger) callsite=\(callSite) \(attemptContext())")
        logger.notice(
            "Dictation stopDiscard requested reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
        )

        state = .stoppingDiscard

        cancelMaxDurationTimer(reason: "stopDiscard_enter", caller: "stopDiscard")
        cancelTokenInactivityTimer(reason: "stopDiscard_enter")
        cancelPendingTranscriptApply()

        audioCapture?.stop()
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_DISCARD_CLOSE_CLIENT_CANCELLED reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )
        streamingClient?.close(
            code: .normalClosure,
            reason: "client_cancelled",
            caller: "DictationSession.stopDiscard reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
        )

        if let originSessionKey {
            bridge.restore(snapshot: preDictationSnapshot, to: originSessionKey)
        }

        finalizeSessionCleanup(reason: reason, announceStop: false, collapseSurface: true)
    }

    private func waitForFinished(timeout: Duration) async -> Bool {
        guard timeout > .zero else { return false }
        if finishedReceived { return true }

        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if finishedReceived {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch is CancellationError {
                return finishedReceived
            } catch {
                return finishedReceived
            }
        }
        return finishedReceived
    }

    private func finalizeSessionCleanup(
        reason: String,
        announceStop: Bool,
        collapseSurface: Bool,
        keepAudioForPausedWaveform: Bool = false
    ) {
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

        if !keepAudioForPausedWaveform {
            audioLevel = 1
        }
        finishedReceived = false
        mode = nil
        sessionStartedAt = nil
        lastTokenAt = nil

        eventTask?.cancel()
        frameTask?.cancel()
        if !keepAudioForPausedWaveform {
            levelTask?.cancel()
            audioEventTask?.cancel()
        }
        cancelMaxDurationTimer(reason: "finalizeSessionCleanup", caller: "finalizeSessionCleanup")
        cancelTokenInactivityTimer(reason: "finalizeSessionCleanup")
        streamSwitchStopTask?.cancel()
        transcriptApplyTask?.cancel()
        prewarmConnectTask?.cancel()

        eventTask = nil
        frameTask = nil
        if !keepAudioForPausedWaveform {
            levelTask = nil
            audioEventTask = nil
        }
        streamSwitchStopTask = nil
        transcriptApplyTask = nil
        prewarmConnectTask = nil

        if !keepAudioForPausedWaveform {
            audioCapture = nil
        }
        streamingClient = nil
        isSocketConnected = false
        isPhase3StreamingAudio = false
        bufferedAudioFrames.removeAll(keepingCapacity: false)
        prewarmGeneration = nil

        if !keepAudioForPausedWaveform {
            originSessionKey = nil
            preDictationSnapshot = .empty
            pendingTranscriptText = nil
            pendingActivationMode = nil
        }
        pendingStopContext = nil

        if collapseSurface, state != .error {
            state = .idleSurfaceClosed
        } else if !collapseSurface, state != .error {
            state = .dictatingPaused
        }
    }

    private func enterError(message: String, source: String = "unspecified") {
        logDictation("DICTATION_ERROR enter_error ts=\(Date().timeIntervalSince1970) source=\(source) state=\(String(describing: state)) message=\(message)")
        logDictation("DICTATION_COORD enter_error message=\(message)")
        errorMessage = message
        state = .error
        feedback.notifyError()
        feedback.announce("Dictation failed")
    }

    private var shouldPresentDictationErrorSurface: Bool {
        switch state {
        case .dictatingSticky, .dictatingPaused, .dictatingWalkieTalkie, .finalizing, .stoppingKeep, .stoppingDiscard, .error:
            return true
        case .idleSurfaceClosed, .keyPromptModal, .keyVerifyingModal:
            return false
        }
    }

    private func idleStateForCurrentContext() -> DictationState {
        .idleSurfaceClosed
    }

    private func pauseListening(reason: String) async {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .dictatingPaused || state == .finalizing else { return }
        guard !pauseListeningInFlight else {
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_PAUSE_DUPLICATE_SUPPRESSED " +
                "caller=pauseListening reason=\(reason) ts=\(Date().timeIntervalSince1970) \(attemptContext())"
            )
            return
        }
        pauseListeningInFlight = true
        defer { pauseListeningInFlight = false }
        logDictation("DICTATION_STOP pauseListening_entry reason=\(reason) \(attemptContext())")
        state = .finalizing
        let keepCaptureForPausedWaveform = reason == "waveform_tap_pause"
            || reason == "walkie_release_to_paused"
            || reason == "send_tap_pause"
        cancelMaxDurationTimer(reason: "pauseListening", caller: "pauseListening")
        cancelTokenInactivityTimer(reason: "pauseListening")
        flushPendingTranscriptApply()
        prewarmConnectTask?.cancel()
        prewarmConnectTask = nil
        suppressedPrewarmFailureBudget = 0

        await finalizeForPendingStopAction(reason: reason, timeout: timing.sendFinalizeTimeout)
        streamingClient?.close(
            code: .normalClosure,
            reason: "paused",
            caller: "DictationSession.pauseListening reason=\(reason)"
        )

        eventTask?.cancel()
        frameTask?.cancel()
        eventTask = nil
        frameTask = nil
        activeMaxDurationTaskID = nil
        maxDurationDeadline = nil
        streamingClient = nil
        isSocketConnected = false
        isPhase3StreamingAudio = false
        bufferedAudioFrames.removeAll(keepingCapacity: true)
        prewarmGeneration = nil
        lastAudioActivityResetAt = nil
        mode = nil

        if !keepCaptureForPausedWaveform {
            audioCapture?.stop()
            levelTask?.cancel()
            audioEventTask?.cancel()
            levelTask = nil
            audioEventTask = nil
            audioCapture = nil
        }

        state = .dictatingPaused
        schedulePhase1IdleTeardown()
    }

    private func finalizeForPendingStopAction(reason: String, timeout: Duration) async {
        guard streamingClient != nil else { return }
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_FINALIZATION_HOLD_BEGIN " +
            "caller=finalizeForPendingStopAction reason=\(reason) timeout=\(timeout) ts=\(Date().timeIntervalSince1970)"
        )
        do {
            try await streamingClient?.sendFinalize()
        } catch {
            logDictation("DICTATION_COORD finalize_for_pause sendFinalize_failed reason=\(reason) error=\(error.localizedDescription)")
        }
        do {
            try await streamingClient?.sendAudioFrame(Data())
        } catch {
            // Best-effort flush marker.
        }
        let finalizedWithinTimeout = await waitForFinished(timeout: timeout)
        logDictation(
            "DICTATION_STOP trace_id=DICTATION_STOP_FINALIZATION_HOLD_END " +
            "caller=finalizeForPendingStopAction reason=\(reason) finalized_within_timeout=\(finalizedWithinTimeout) ts=\(Date().timeIntervalSince1970)"
        )
    }

    private func resumeFromPaused() {
        guard state == .dictatingPaused else { return }
        start(mode: .sticky)
    }

    private func schedulePhase1IdleTeardown() {
        phase1IdleTeardownTask?.cancel()
        phase1IdleTeardownTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            await MainActor.run {
                guard !self.isListening else { return }
                self.teardownPhase1(reason: PrewarmTeardownReason.phase1IdleTimeout.rawValue)
            }
        }
    }

    private func closeAndResetRealtimePipeline(closeReason: String) {
        logDictation("DICTATION_CONN close_and_reset reason=\(closeReason) \(attemptContext())")
        prewarmConnectTask?.cancel()
        prewarmConnectTask = nil
        audioCapture?.stop()
        streamingClient?.close(
            code: .normalClosure,
            reason: closeReason,
            caller: "DictationSession.closeAndResetRealtimePipeline"
        )

        eventTask?.cancel()
        frameTask?.cancel()
        levelTask?.cancel()
        audioEventTask?.cancel()

        eventTask = nil
        frameTask = nil
        levelTask = nil
        audioEventTask = nil
        audioCapture = nil
        streamingClient = nil
        isSocketConnected = false
        isPhase3StreamingAudio = false
        prewarmGeneration = nil
        bufferedAudioFrames.removeAll(keepingCapacity: false)
    }

    private static func mappedDisplacement(for rms: Float) -> CGFloat {
        guard rms > 0 else { return WaveformDefaults.amplitudeFloor }
        let db = 20 * log10(rms)
        let minDb: Float = -55
        let maxDb: Float = -10
        let normalized = max(0, (db - minDb) / (maxDb - minDb))
        let curveGain: Float = 2.4
        let curved = tanh(normalized * curveGain) / tanh(curveGain)
        return WaveformDefaults.amplitudeFloor + CGFloat(curved) * WaveformDefaults.amplitudeRange
    }

    private func elapsedSessionMilliseconds() -> Int {
        guard let sessionStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
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
        guard let originSessionKey else { return }
        let wallTs = Date().timeIntervalSince1970
        logDictation("DICTATION_PERF ts=\(wallTs) event=apply_transcript_begin chars=\(transcriptText.count)")
        let startedAt = CFAbsoluteTimeGetCurrent()
        bridge.apply(transcript: transcriptText, baseSnapshot: preDictationSnapshot, to: originSessionKey)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=apply_transcript_end elapsedMs=\(elapsedMs)")
        logger.notice("[DICTATION-PERF] applyTranscriptIfNeeded: \(elapsedMs, privacy: .public)ms")
    }
}

typealias DictationCoordinator = DictationSession
