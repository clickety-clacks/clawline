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
    var sendFinalizeTimeout: Duration = .milliseconds(1_200)
    var composeUpdateCoalescingInterval: Duration = .milliseconds(75)
    var phase2ConnectAttemptTimeout: Duration = .seconds(3)
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
    private enum WalkieOrigin {
        case pushHold
        case pausedHold
    }

    private enum PrewarmTeardownReason: String {
        case gestureAbandon = "gesture_abandon"
        case phase1IdleTimeout = "phase1_idle_timeout"
        case viewInactive = "view_inactive"
    }

    private enum Phase2ConnectTimeoutError: Error {
        case timeout
    }

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "DictationCoordinator")
    private var uiProjectionState: DictationState = .idleSurfaceClosed
    private var state: DictationState = .idleSurfaceClosed {
        didSet {
            guard oldValue != state else { return }
            let trace = "DICTATION_COORD state \(String(describing: oldValue)) -> \(String(describing: state))"
            logDictation(trace)
            uiProjectionState = projectedUIState(for: state, fallback: uiProjectionState)
            surfaceTarget = surfaceTarget(for: uiProjectionState)
            setSystemIdleSleepDisabled(shouldDisableIdleSleep(for: state))
        }
    }
    private(set) var errorMessage: String?
    private(set) var audioLevel: Float = 0
    private(set) var reduceMotionEnabled: Bool = UIAccessibility.isReduceMotionEnabled
    private(set) var surfaceTarget: SurfaceTarget = .closed {
        didSet {
            guard oldValue != surfaceTarget else { return }
        }
    }

    private func setSystemIdleSleepDisabled(_ disabled: Bool) {
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
#endif
    }

    private func shouldDisableIdleSleep(for state: DictationState) -> Bool {
        switch state {
        case .dictatingSticky, .dictatingWalkieTalkie, .finalizing, .stoppingKeep, .stoppingDiscard:
            return true
        case .idleSurfaceClosed, .keyPromptModal, .keyVerifyingModal, .dictatingPaused, .error:
            return false
        }
    }

    private func projectedUIState(for state: DictationState, fallback previous: DictationState) -> DictationState {
        switch state {
        case .finalizing, .stoppingKeep, .stoppingDiscard:
            return previous
        case .idleSurfaceClosed,
                .keyPromptModal,
                .keyVerifyingModal,
                .dictatingSticky,
                .dictatingPaused,
                .dictatingWalkieTalkie,
                .error:
            return state
        }
    }

    private func surfaceTarget(for state: DictationState) -> SurfaceTarget {
        switch state {
        case .idleSurfaceClosed:
            return .closed
        case .keyPromptModal,
                .keyVerifyingModal,
                .dictatingSticky,
                .dictatingPaused,
                .dictatingWalkieTalkie,
                .finalizing,
                .stoppingKeep,
                .stoppingDiscard,
                .error:
            return .open
        }
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
        uiProjectionState == .keyPromptModal || uiProjectionState == .keyVerifyingModal
    }

    var isDictationActive: Bool {
        switch uiProjectionState {
        case .dictatingSticky, .dictatingPaused, .dictatingWalkieTalkie:
            return true
        case .idleSurfaceClosed, .keyPromptModal, .keyVerifyingModal, .error:
            return false
        case .finalizing, .stoppingKeep, .stoppingDiscard:
            return false
        }
    }

    var isListening: Bool {
        uiProjectionState == .dictatingSticky || uiProjectionState == .dictatingWalkieTalkie
    }

    var isListeningReady: Bool {
        isListening && isPhase3StreamingAudio && isSocketConnected
    }

    var isStickyDictationActive: Bool {
        uiProjectionState == .dictatingSticky
    }

    var isWalkieTalkieActive: Bool {
        uiProjectionState == .dictatingWalkieTalkie
    }

    var isWaveformVisible: Bool {
        switch uiProjectionState {
        case .dictatingSticky, .dictatingPaused, .dictatingWalkieTalkie, .error:
            return true
        case .idleSurfaceClosed, .keyPromptModal, .keyVerifyingModal:
            return false
        case .finalizing, .stoppingKeep, .stoppingDiscard:
            return false
        }
    }

    var isSurfaceOpen: Bool {
        surfaceTarget == .open
    }

    var micVisible: Bool {
        if uiProjectionState == .keyPromptModal || uiProjectionState == .keyVerifyingModal {
            return true
        }
        return !isSurfaceOpen
    }

    var swipeActivationEnabled: Bool {
        !isSurfaceOpen && latestComposeSelectionRange.length == 0
    }

    private struct TranscriptSession {
        var originSessionKey: String
        var baseSnapshot: ComposeDraftSnapshot
        var dictationStartUTF16: Int
        var baseReplacementLenUTF16: Int
        var committedLenUTF16: Int
        var provisionalText: String
        var suppressedUntilNextEndpoint: Bool
        var committedText: String
        var pendingUpdate: DictationSegmentUpdate?
        var activationSelectionRange: NSRange?
        var transcriptPrefixToDiscardAfterReanchor: String
        var walkieOrigin: WalkieOrigin?

        var provisionalLenUTF16: Int {
            provisionalText.utf16.count
        }

        var previousTranscriptUTF16Length: Int {
            committedLenUTF16 + provisionalLenUTF16
        }
    }

    private struct TranscriptEngine {
        private enum BoundaryAffinity {
            case start
            case end
        }

        static func noteUserEdit(
            session: inout TranscriptSession,
            editedRangeUTF16: NSRange,
            replacementUTF16Length: Int
        ) {
            let provisionalRange = NSRange(
                location: session.dictationStartUTF16 + session.committedLenUTF16,
                length: session.provisionalLenUTF16
            )
            if rangesIntersect(editedRangeUTF16, provisionalRange) {
                session.committedText += session.provisionalText
                session.committedLenUTF16 += session.provisionalLenUTF16
                session.provisionalText = ""
                session.suppressedUntilNextEndpoint = true
            }

            let committedStart = session.dictationStartUTF16
            let committedEnd = committedStart + session.committedLenUTF16
            let baseReplacementEnd = committedStart + session.baseReplacementLenUTF16
            let newCommittedStart = transformBoundary(
                committedStart,
                editedRange: editedRangeUTF16,
                replacementUTF16Length: replacementUTF16Length,
                affinity: .start
            )
            let newCommittedEnd = transformBoundary(
                committedEnd,
                editedRange: editedRangeUTF16,
                replacementUTF16Length: replacementUTF16Length,
                affinity: .end
            )
            let newBaseReplacementEnd = transformBoundary(
                baseReplacementEnd,
                editedRange: editedRangeUTF16,
                replacementUTF16Length: replacementUTF16Length,
                affinity: .end
            )

            session.dictationStartUTF16 = max(0, newCommittedStart)
            session.committedLenUTF16 = max(0, newCommittedEnd - newCommittedStart)
            session.baseReplacementLenUTF16 = max(0, newBaseReplacementEnd - newCommittedStart)
        }

        static func applySegmentUpdate(_ update: DictationSegmentUpdate, to session: inout TranscriptSession) {
            let update = transcriptUpdateByDiscardingReanchorPrefix(update, session: &session)
            var shouldSkipFirstEndpointCommit = session.suppressedUntilNextEndpoint
            var processedAnyEndpoint = false

            for segment in update.committedSegments {
                processedAnyEndpoint = true
                if shouldSkipFirstEndpointCommit {
                    shouldSkipFirstEndpointCommit = false
                    session.suppressedUntilNextEndpoint = false
                    session.provisionalText = ""
                    continue
                }

                session.committedText += segment
                session.committedLenUTF16 += segment.utf16.count
                session.provisionalText = ""
            }

            if session.suppressedUntilNextEndpoint && update.sawEndpoint && !processedAnyEndpoint {
                session.suppressedUntilNextEndpoint = false
                shouldSkipFirstEndpointCommit = false
                session.provisionalText = ""
            } else {
                session.suppressedUntilNextEndpoint = shouldSkipFirstEndpointCommit
            }

            if !session.suppressedUntilNextEndpoint {
                session.provisionalText = update.provisionalText
            }

            if update.finished {
                if session.suppressedUntilNextEndpoint {
                    session.suppressedUntilNextEndpoint = false
                    session.provisionalText = ""
                } else if !session.provisionalText.isEmpty {
                    session.committedText += session.provisionalText
                    session.committedLenUTF16 += session.provisionalLenUTF16
                    session.provisionalText = ""
                }
            }
        }

        static func syncCommittedText(from text: String, session: inout TranscriptSession) {
            let committedRange = NSRange(location: session.dictationStartUTF16, length: session.committedLenUTF16)
            guard let committedSubstring = TranscriptEngine.substring(text: text, utf16Range: committedRange) else { return }
            session.committedText = committedSubstring
        }

        static func safeReplacementRange(selectedRange: NSRange, textLength: Int, fallbackLocation: Int) -> NSRange {
            let replacementLength = selectedRange.location == NSNotFound ? 0 : selectedRange.length
            let location = selectedRange.location == NSNotFound
                ? min(max(fallbackLocation, 0), textLength)
                : min(max(selectedRange.location, 0), textLength)
            let length = min(max(replacementLength, 0), max(0, textLength - location))
            return NSRange(location: location, length: length)
        }

        static func substring(text: String, utf16Range: NSRange) -> String? {
            let nsString = text as NSString
            guard utf16Range.location >= 0,
                  utf16Range.length >= 0,
                  utf16Range.location + utf16Range.length <= nsString.length else {
                return nil
            }
            return nsString.substring(with: utf16Range)
        }

        static func mergeUpdates(
            _ lhs: DictationSegmentUpdate,
            _ rhs: DictationSegmentUpdate
        ) -> DictationSegmentUpdate {
            DictationSegmentUpdate(
                provisionalText: rhs.provisionalText,
                committedSegments: lhs.committedSegments + rhs.committedSegments,
                finished: lhs.finished || rhs.finished,
                sawEndpoint: lhs.sawEndpoint || rhs.sawEndpoint,
                hadAnyTokens: lhs.hadAnyTokens || rhs.hadAnyTokens
            )
        }

        private static func transcriptUpdateByDiscardingReanchorPrefix(
            _ update: DictationSegmentUpdate,
            session: inout TranscriptSession
        ) -> DictationSegmentUpdate {
            guard !session.transcriptPrefixToDiscardAfterReanchor.isEmpty else { return update }
            var prefix = session.transcriptPrefixToDiscardAfterReanchor
            var committedSegments: [String] = []
            var didConsumeEndpointPrefix = false

            for segment in update.committedSegments {
                let normalized = textByRemovingPrefix(prefix, from: segment)
                if normalized.didRemovePrefix {
                    didConsumeEndpointPrefix = true
                    prefix = ""
                }
                committedSegments.append(normalized.text)
            }

            let normalizedProvisional = textByRemovingPrefix(prefix, from: update.provisionalText)
            if update.sawEndpoint || didConsumeEndpointPrefix {
                session.transcriptPrefixToDiscardAfterReanchor = ""
            }

            return DictationSegmentUpdate(
                provisionalText: normalizedProvisional.text,
                committedSegments: committedSegments,
                finished: update.finished,
                sawEndpoint: update.sawEndpoint,
                hadAnyTokens: update.hadAnyTokens
            )
        }

        private static func textByRemovingPrefix(_ prefix: String, from text: String) -> (text: String, didRemovePrefix: Bool) {
            guard !prefix.isEmpty else { return (text, false) }
            if prefix.hasPrefix(text) {
                return ("", false)
            }
            guard text.hasPrefix(prefix) else { return (text, false) }
            let index = text.index(text.startIndex, offsetBy: prefix.count)
            return (String(text[index...]), true)
        }

        private static func transformBoundary(
            _ boundary: Int,
            editedRange: NSRange,
            replacementUTF16Length: Int,
            affinity: BoundaryAffinity
        ) -> Int {
            let editStart = editedRange.location
            let editEnd = editedRange.location + editedRange.length
            let delta = replacementUTF16Length - editedRange.length

            if boundary < editStart {
                return boundary
            }
            if boundary > editEnd {
                return boundary + delta
            }

            switch affinity {
            case .start:
                return editStart
            case .end:
                return editStart + replacementUTF16Length
            }
        }

        private static func rangesIntersect(_ a: NSRange, _ b: NSRange) -> Bool {
            if a.length == 0 {
                let point = a.location
                return point >= b.location && point <= b.location + b.length
            }
            return NSIntersectionRange(a, b).length > 0
        }
    }

    private enum TranscriptOwnership {
        case inactive
        case active(TranscriptSession)
    }

    private enum PendingAction {
        case none
        case pause(reason: String)
        case dismiss(reason: String, trigger: String, callSite: String)
        case send(reason: String)
        case stopKeep(reason: String, trigger: String, callSite: String)
        case transportFailure(stage: String)
        case protocolError(code: String?, message: String)

        var logContext: String {
            switch self {
            case .none:
                return "action=none"
            case .pause(let reason):
                return "action=pause reason=\(reason)"
            case .dismiss(let reason, let trigger, let callSite):
                return "action=dismiss reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
            case .send(let reason):
                return "action=send reason=\(reason)"
            case .stopKeep(let reason, let trigger, let callSite):
                return "action=stopKeep reason=\(reason) trigger=\(trigger) callSite=\(callSite)"
            case .transportFailure(let stage):
                return "action=transportFailure stage=\(stage)"
            case .protocolError(let code, let message):
                return "action=protocolError code=\(code ?? "nil") message=\(message)"
            }
        }
    }

    private let bridge: DictationTranscriptApplicator
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
    private var latestComposeSelectionRange = NSRange(location: 0, length: 0)
    private var contextTerms: [String] = []

    private var transcriptOwnership: TranscriptOwnership = .inactive
    private var transcriptBuffer = DictationTranscriptBuffer()
    private var pendingActivationMode: DictationMode?
    private var pendingActivationWalkieOrigin: WalkieOrigin?
    private var pendingActivationSelectionRange: NSRange?
    private var hasExplicitActivationSelectionCapture = false
    private var gesturePrewarmGeneration: UInt64?
    private var gestureActivationFailed = false
    private(set) var mode: DictationMode?
    private var sessionStartedAt: Date?
    private var lastTokenAt: Date?
    private var finishedReceived = false
    private var pendingAction: PendingAction = .none

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
    private var prewarmConnectStartedAt: Date?
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
    private let uiTestSessionKey = "agent:main:ui-test:main"

    private var isKeyboardDictationUITestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-keyboard-dictation")
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return Double(components.seconds) + attoseconds
    }

    private func runWithTimeout<T>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Phase2ConnectTimeoutError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
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
        bridge: DictationTranscriptApplicator,
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
        bridge.setReplayPlanProvider { [weak self] in
            self?.currentTranscriptReplayPlan()
        }
    }

    private var originSessionKey: String? {
        guard case .active(let session) = transcriptOwnership else { return nil }
        return session.originSessionKey
    }

    private var preDictationSnapshot: ComposeDraftSnapshot {
        guard case .active(let session) = transcriptOwnership else { return .empty }
        return session.baseSnapshot
    }

    private var activeWalkieOrigin: WalkieOrigin? {
        guard case .active(let session) = transcriptOwnership else { return nil }
        return session.walkieOrigin
    }

    private func activeTranscriptSession() -> TranscriptSession? {
        guard case .active(let session) = transcriptOwnership else { return nil }
        return session
    }

    private func updateActiveTranscriptSession(_ mutate: (inout TranscriptSession) -> Void) {
        guard case .active(var session) = transcriptOwnership else { return }
        mutate(&session)
        transcriptOwnership = .active(session)
    }

    func updateContext(
        sessionKey: String,
        composeIsEmpty: Bool,
        textFieldFocused: Bool,
        reduceMotionEnabled: Bool,
        contextTerms: [String] = []
    ) {
        let previousComposeIsEmpty = self.composeIsEmpty
        let effectiveSessionKey: String
        if sessionKey.isEmpty && isKeyboardDictationUITestMode {
            effectiveSessionKey = uiTestSessionKey
        } else {
            effectiveSessionKey = sessionKey
        }

        self.currentSessionKey = effectiveSessionKey
        self.composeIsEmpty = composeIsEmpty
        self.isTextFieldFocused = textFieldFocused
        self.reduceMotionEnabled = reduceMotionEnabled
        self.contextTerms = contextTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if effectiveSessionKey.isEmpty {
            teardownPhase1(reason: PrewarmTeardownReason.viewInactive.rawValue)
        } else {
            preparePhase1IfNeeded()
        }

        if isDictationActive,
           let originSessionKey,
           !originSessionKey.isEmpty,
           !effectiveSessionKey.isEmpty,
           effectiveSessionKey != originSessionKey {
            requestStreamSwitchStopIfNeeded(trigger: "stream_switch_context_update")
        }

        if !isDictationActive,
           state != .error,
           state != .keyPromptModal,
           state != .keyVerifyingModal,
           state != .finalizing,
           state != .stoppingKeep,
           state != .stoppingDiscard {
            state = .idleSurfaceClosed
        }

        if isDictationActive,
           !previousComposeIsEmpty,
           composeIsEmpty,
           let originSessionKey,
           !originSessionKey.isEmpty,
           originSessionKey == effectiveSessionKey {
            resetActiveTranscriptSessionAfterComposeCleared()
        }
    }

    private func requestStreamSwitchStopIfNeeded(trigger: String) {
        if let streamSwitchStopTask, !streamSwitchStopTask.isCancelled {
            return
        }
        streamSwitchStopTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.streamSwitchStopTask = nil
                }
            }
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_STREAM_SWITCH caller=stream_switch_handler trigger=\(trigger) ts=\(Date().timeIntervalSince1970)")
            await self.stopKeep(
                reason: "stream_switch",
                timeout: self.timing.sendFinalizeTimeout,
                announceStop: false,
                gracefulFinalize: true,
                collapseSurface: false,
                trigger: trigger
            )
        }
    }

    func setComposeTextView(_ textView: PastableTextView?) {
        bridge.setComposeTextView(textView)
    }

    func focusComposeTextViewForTesting() {
        bridge.focusComposeTextView()
    }

    func dismissComposeTextViewKeyboard() {
        bridge.dismissComposeTextViewKeyboard()
    }

    func stopDictationForKeyboardDismissUITest() {
        guard isDictationActive else { return }
        Task { [weak self] in
            await self?.stopKeep(
                reason: "ui_test_keyboard_dismiss",
                timeout: .zero,
                announceStop: false,
                gracefulFinalize: false,
                collapseSurface: true,
                collapseSurfaceImmediately: true,
                trigger: "ui_test_keyboard_dismiss"
            )
        }
    }

    func captureComposeSelectionRangeForActivation(_ selectionRange: NSRange) {
        let resolvedSelectionRange: NSRange?
        if selectionRange.location != NSNotFound {
            resolvedSelectionRange = selectionRange
        } else if let liveSelectionRange = bridge.boundComposeTextView?.selectedRange,
                  liveSelectionRange.location != NSNotFound {
            resolvedSelectionRange = liveSelectionRange
        } else {
            resolvedSelectionRange = nil
        }

        pendingActivationSelectionRange = resolvedSelectionRange
        if let resolvedSelectionRange {
            latestComposeSelectionRange = resolvedSelectionRange
        }
        hasExplicitActivationSelectionCapture = true
        updateActiveTranscriptSession { session in
            session.activationSelectionRange = resolvedSelectionRange
        }
    }

    func noteComposeSelectionChanged(_ selectionRange: NSRange) {
        guard selectionRange.location != NSNotFound else { return }
        latestComposeSelectionRange = selectionRange
        guard isDictationActive else {
            if !hasExplicitActivationSelectionCapture {
                pendingActivationSelectionRange = selectionRange
            }
            return
        }
        guard let originSessionKey, !originSessionKey.isEmpty, originSessionKey == currentSessionKey else { return }
        guard bridge.boundComposeTextView?.dictationProgrammaticEditInFlight != true else { return }
        reanchorActiveTranscriptSession(to: selectionRange)
    }

    func noteComposeUserEditDuringDictation(editedRangeUTF16: NSRange, replacementUTF16Length: Int) {
        guard isDictationActive else { return }
        guard let originSessionKey, !originSessionKey.isEmpty, originSessionKey == currentSessionKey else { return }
        guard bridge.boundComposeTextView?.dictationProgrammaticEditInFlight != true else { return }
        updateActiveTranscriptSession { session in
            TranscriptEngine.noteUserEdit(
                session: &session,
                editedRangeUTF16: editedRangeUTF16,
                replacementUTF16Length: replacementUTF16Length
            )
        }
    }

    func preparePhase1IfNeeded() {
        guard !currentSessionKey.isEmpty else { return }
        guard !isListening else { return }
        ensurePhase1Prepared()
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
        gestureActivationFailed = false
        guard let apiKey = configuredAPIKeyOrNil() else {
            gesturePrewarmGeneration = nil
            return
        }
        let generation = nextActivationGeneration()
        gesturePrewarmGeneration = generation
        ensurePhase1Prepared()
        beginPhase2Prewarm(apiKey: apiKey, generation: generation)
    }

    func cancelGesturePrewarmIfNeeded(trigger: String = "gesture_abandon") {
        guard !isListening else { return }
        guard state == .idleSurfaceClosed || state == .keyPromptModal || state == .keyVerifyingModal else { return }
        logDictation("DICTATION_COORD prewarm_cancel trigger=\(trigger)")
        gesturePrewarmGeneration = nil
        gestureActivationFailed = false
        closeAndResetRealtimePipeline(closeReason: "prewarm_cancelled")
        prewarmGeneration = nil
        prewarmConnectTask?.cancel()
        prewarmConnectTask = nil
        prewarmConnectStartedAt = nil
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
        start(mode: .sticky, walkieOrigin: nil)
    }

    func startWalkieTalkieDictation() {
        logDictation("DICTATION_UI startWalkieTalkieDictation state=\(String(describing: state)) \(attemptContext())")
        start(mode: .walkieTalkie, walkieOrigin: .pushHold)
    }

    func startWalkieTalkieFromPausedSurface() {
        guard state == .dictatingPaused else { return }
        start(mode: .walkieTalkie, walkieOrigin: .pausedHold)
    }

    func pauseFromWaveformTap() {
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            await self?.pauseListening(reason: "waveform_tap_pause")
        }
    }

    func toggleWaveformTapAction() {
        if state == .error {
            errorMessage = nil
            state = .idleSurfaceClosed
            return
        }
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
        if state == .error {
            errorMessage = nil
            state = .idleSurfaceClosed
            return
        }
        beginStopKeepTransitionIfNeeded()
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
            let requestedWalkieOrigin = pendingActivationWalkieOrigin
            pendingActivationMode = nil
            pendingActivationWalkieOrigin = nil
            if let requestedMode {
                start(mode: requestedMode, walkieOrigin: requestedWalkieOrigin)
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
        pendingActivationWalkieOrigin = nil
        state = idleStateForCurrentContext()
    }

    func stopDictationFromSwipeRight() {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie else { return }
        beginStopKeepTransitionIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            self.logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SWIPE_RIGHT caller=swipe_right_stop ts=\(Date().timeIntervalSince1970)")
            await self.stopKeep(
                reason: "swipe_right",
                timeout: self.timing.stopKeepFinalizeTimeout,
                collapseSurfaceImmediately: true,
                trigger: "user_swipe_right"
            )
        }
    }

    func stopStickyFromMicTap() {
        guard state == .dictatingSticky else { return }
        beginStopKeepTransitionIfNeeded()
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
            switch self.activeWalkieOrigin {
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
        beginStopKeepTransitionIfNeeded()
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
        Task { [weak self] in
            await self?.stopDiscard(reason: "escape_long_press", trigger: "keyboard_escape_long_press")
        }
    }

    func stopFromVoiceOverAction() {
        guard state == .dictatingSticky || state == .dictatingPaused else { return }
        beginStopKeepTransitionIfNeeded()
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
        Task { [weak self] in
            await self?.stopDiscard(reason: "voiceover_discard", trigger: "voiceover_discard_action")
        }
    }

    func handleSendTapped(sendAction: @escaping () -> Void) {
        logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SEND_TAPPED_ENTRY caller=handleSendTapped_entry ts=\(Date().timeIntervalSince1970) state=\(String(describing: state))")
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie || state == .stoppingKeep || state == .finalizing else {
            sendAction()
            return
        }
        sendAction()
        analytics.trackSendWhileActive(mode: mode, sendSuccess: true)
    }

    func handleAppBackgrounded() {
        teardownPhase1(reason: PrewarmTeardownReason.viewInactive.rawValue)
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.stopKeep(
                reason: "app_background",
                timeout: self.timing.stopKeepFinalizeTimeout,
                collapseSurface: true,
                collapseSurfaceImmediately: true,
                trigger: "app_background"
            )
        }
    }

    private func start(mode: DictationMode, walkieOrigin: WalkieOrigin?) {
        if state == .finalizing || state == .stoppingKeep || state == .stoppingDiscard {
            pendingActivationMode = mode
            pendingActivationWalkieOrigin = walkieOrigin
            logDictation("DICTATION_ATTEMPT queued_during_teardown mode=\(mode.rawValue) \(attemptContext())")
            return
        }
        guard !isListening else { return }
        guard !currentSessionKey.isEmpty else { return }
        if gestureActivationFailed {
            logDictation("DICTATION_ATTEMPT cancelled_after_gesture_prewarm_failure mode=\(mode.rawValue) \(attemptContext())")
            gestureActivationFailed = false
            gesturePrewarmGeneration = nil
            return
        }
        guard let apiKey = configuredAPIKeyOrNil() else {
            pendingActivationMode = mode
            pendingActivationWalkieOrigin = walkieOrigin
            state = .keyPromptModal
            return
        }

        dictationAttemptID &+= 1
        activeAttemptID = dictationAttemptID
        let generation = gesturePrewarmGeneration ?? prewarmGeneration ?? nextActivationGeneration()
        pendingActivationMode = nil
        pendingActivationWalkieOrigin = nil
        gesturePrewarmGeneration = nil
        self.mode = mode
        logDictation("DICTATION_ATTEMPT start_requested start_mode=\(mode.rawValue) \(attemptContext())")
        let needsSessionContextInitialization =
            state != .dictatingPaused ||
            originSessionKey == nil ||
            originSessionKey != currentSessionKey

        if state == .dictatingPaused, !needsSessionContextInitialization {
            flushPendingTranscriptApply()
            reanchorActiveTranscriptSessionToLiveSelection(discardCurrentMachineTextFromPendingStream: false)
            transcriptBuffer.reset()
        }

        if needsSessionContextInitialization {
            initializeOriginSessionContext(for: currentSessionKey, walkieOrigin: walkieOrigin)
        }
        self.finishedReceived = false
        self.audioDecodeTimeoutRecoveryCount = 0
        self.sessionStartedAt = Date()
        self.lastTokenAt = Date()
        self.audioLevel = 0
        self.errorMessage = nil
        updateActiveTranscriptSession { session in
            session.walkieOrigin = walkieOrigin
        }

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
        let needsFreshPhase2Connection =
            prewarmGeneration != generation ||
            streamingClient == nil ||
            audioCapture == nil ||
            (!isSocketConnected && prewarmConnectTask == nil) ||
            (!isSocketConnected && isPrewarmConnectStale(maxAge: 3))
        if needsFreshPhase2Connection {
            if isPrewarmConnectStale(maxAge: 3) {
                prewarmConnectTask?.cancel()
                prewarmConnectTask = nil
                prewarmConnectStartedAt = nil
            }
            beginPhase2Prewarm(apiKey: apiKey, generation: generation)
        }
        isPhase3StreamingAudio = true
        flushBufferedFramesIfPossible()
        armSessionDurationTimer()
        resetTokenInactivityTimer()
        schedulePhase1IdleTeardown()
    }

    @discardableResult
    private func beginStopKeepTransitionIfNeeded() -> Bool {
        switch state {
        case .dictatingSticky, .dictatingPaused, .dictatingWalkieTalkie:
            state = .stoppingKeep
            return true
        case .stoppingKeep, .finalizing:
            return true
        default:
            return false
        }
    }

    private func nextActivationGeneration() -> UInt64 {
        activationGeneration &+= 1
        return activationGeneration
    }

    private func configuredAPIKeyOrNil() -> String? {
        let key = keyStore.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return key
    }

    private func attemptContext() -> String {
        "attempt_id=\(activeAttemptID.map(String.init) ?? "nil") generation=\(prewarmGeneration.map(String.init) ?? "nil") mode=\(String(describing: mode)) state=\(String(describing: state)) socket=\(isSocketConnected) phase3=\(isPhase3StreamingAudio)"
    }

    private func stopLivenessContext() -> String {
        let now = Date()
        let elapsedSinceLastToken = lastTokenAt.map { now.timeIntervalSince($0) } ?? -1
        let tokenDeadlineDelta = tokenInactivityDeadline.map { $0.timeIntervalSince(now) } ?? -1
        return "elapsed_since_last_token_s=\(elapsedSinceLastToken) token_deadline_delta_s=\(tokenDeadlineDelta) finished=\(finishedReceived) buffered_frames=\(bufferedAudioFrames.count)"
    }

    private func beginPhase2Prewarm(apiKey: String, generation: UInt64) {
        ensurePhase1Prepared()
        prewarmGeneration = generation
        suppressedPrewarmFailureBudget = 1
        isPhase3StreamingAudio = false
        isSocketConnected = false
        bufferedAudioFrames.removeAll(keepingCapacity: true)

        guard let client = streamingClient, let capture = audioCapture else { return }

        prewarmConnectStartedAt = Date()
        prewarmConnectTask = Task { [weak self] in
            guard let self else { return }
            var lastError: Error?
            for attempt in 1...2 {
                do {
                    logDictation("DICTATION_CONN phase2_connect_begin connect_attempt=\(attempt) \(attemptContext())")
                    try capture.start()
                    try await runWithTimeout(timeout: timing.phase2ConnectAttemptTimeout) {
                        try await client.connect(
                            config: SonioxStreamingConfig(
                                apiKey: apiKey,
                                languageHint: self.languageHintProvider(),
                                contextTerms: self.contextTerms
                            )
                        )
                    }
                    await MainActor.run {
                        guard self.prewarmGeneration == generation else { return }
                        self.isSocketConnected = true
                        self.logDictation("DICTATION_CONN phase2_connect_success connect_attempt=\(attempt) \(self.attemptContext())")
                        self.prewarmConnectTask = nil
                        self.prewarmConnectStartedAt = nil
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
                        guard !Task.isCancelled else {
                            return
                        }
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
                self.prewarmConnectStartedAt = nil
                self.suppressedPrewarmFailureBudget = 0
                self.closeAndResetRealtimePipeline(closeReason: "phase2_connect_failed")
                if self.gesturePrewarmGeneration == generation {
                    self.gestureActivationFailed = true
                    self.gesturePrewarmGeneration = nil
                    self.enterError(message: "Dictation failed", source: "phase2_connect_failed")
                }
                if let lastError {
                    self.logDictation("DICTATION_CONN phase2_connect_final_failed error=\(lastError.localizedDescription) \(self.attemptContext())")
                }
            }
            await self.handleTransportFailure(
                stage: .connect,
                message: lastError?.localizedDescription ?? "phase2_connect_failed"
            )
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

    private func handleSonioxEvent(_ event: SonioxStreamingEvent, from client: any SonioxStreamingClienting) async {
        guard streamingClient === client else {
            logDictation("DICTATION_CONN dropped_stale_soniox_event \(attemptContext())")
            return
        }
        await handleSonioxEvent(event)
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
        if isKeyboardDictationUITestMode {
            cancelMaxDurationTimer(reason: "ui_test_mode_skip", caller: "armSessionDurationTimer")
            return
        }
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
            await self.stopKeep(
                reason: "max_duration",
                timeout: self.timing.stopKeepFinalizeTimeout,
                announceStop: false,
                gracefulFinalize: true,
                collapseSurface: true,
                collapseSurfaceImmediately: true,
                trigger: "timer_max_duration"
            )
        }
    }

    private func resetTokenInactivityTimer() {
        if isKeyboardDictationUITestMode {
            cancelTokenInactivityTimer(reason: "ui_test_mode_skip")
            return
        }
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
            guard self.activeTokenInactivityTaskID == taskID else {
                self.logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TIMER_TOKEN_INACTIVITY_STALE_IGNORED " +
                    "caller=timer_token_inactivity task_id=\(taskID) active_task_id=\(self.activeTokenInactivityTaskID.map(String.init) ?? "nil") " +
                    "ts=\(Date().timeIntervalSince1970) \(self.attemptContext())"
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
            await self.stopKeep(
                reason: "token_inactivity",
                timeout: self.timing.stopKeepFinalizeTimeout,
                announceStop: false,
                gracefulFinalize: true,
                collapseSurface: true,
                collapseSurfaceImmediately: true,
                trigger: "timer_token_inactivity"
            )
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

            if !response.tokens.isEmpty {
                audioDecodeTimeoutRecoveryCount = 0
                let ts = Date().timeIntervalSince1970
                logDictation(
                    "DICTATION_STOP trace_id=DICTATION_STOP_TOKEN_RECEIVED " +
                    "caller=handleSonioxEvent token_count=\(response.tokens.count) finished=\(response.finished) ts=\(ts)"
                )
                markInactivityActivity(source: "soniox_token", caller: "handleSonioxEvent")
            }

            if !response.tokens.isEmpty || response.finished {
                let update = transcriptBuffer.apply(tokens: response.tokens, finished: response.finished)
                queueTranscriptApply(
                    update,
                    immediate: update.finished || update.sawEndpoint
                )
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
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_SOCKET_CLOSED_EVENT caller=soniox_event_closed state=\(String(describing: state)) mode=\(String(describing: mode)) \(stopLivenessContext()) \(attemptContext())")
            if let mode,
               state == .dictatingSticky || state == .dictatingWalkieTalkie {
                let elapsed = elapsedSessionMilliseconds()
                analytics.trackSocketDrop(mode: mode, elapsedMs: elapsed)
                pendingAction = .transportFailure(stage: "socket_closed")
                await stopKeep(
                    reason: "socket_drop",
                    timeout: .zero,
                    announceStop: false,
                    gracefulFinalize: false,
                    collapseSurface: false,
                    keepAudioForPausedWaveform: false,
                    trigger: "soniox_socket_closed"
                )
                enterError(message: "Dictation failed", source: "socket_drop")
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
            let _ = await pauseListening(reason: "audio_interruption")
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
        if isKeyboardDictationUITestMode {
            logDictation(
                "DICTATION_COORD ui_test_suppressed_protocol_error code=\(code ?? "nil") message=\(message)"
            )
            return
        }
        if message.localizedCaseInsensitiveContains("audio decode timeout") {
            Task { [weak self] in
                await self?.recoverFromAudioDecodeTimeout(message: message)
            }
            return
        }
        analytics.trackError(errorCode: code, stage: "protocol")
        Task { [weak self] in
            guard let self else { return }
            self.pendingAction = .protocolError(code: code, message: message)
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_PROTOCOL_ERROR caller=handleProtocolError ts=\(Date().timeIntervalSince1970) code=\(code ?? "nil")")
            await self.stopKeep(
                reason: "protocol_error",
                timeout: .zero,
                announceStop: false,
                gracefulFinalize: false,
                collapseSurface: false,
                keepAudioForPausedWaveform: false,
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
            pendingAction = .protocolError(code: nil, message: message)
            logDictation("DICTATION_STOP trace_id=DICTATION_STOP_PROTOCOL_ERROR caller=audio_decode_timeout_exhausted ts=\(Date().timeIntervalSince1970)")
            await stopKeep(
                reason: "protocol_error",
                timeout: .zero,
                announceStop: false,
                gracefulFinalize: false,
                collapseSurface: false,
                keepAudioForPausedWaveform: false,
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
        guard let apiKey = configuredAPIKeyOrNil() else {
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
        if isKeyboardDictationUITestMode {
            logDictation(
                "DICTATION_COORD ui_test_suppressed_transport_failure stage=\(stage.rawValue) message=\(message)"
            )
            return
        }
        if stage == .connect, prewarmConnectTask != nil, suppressedPrewarmFailureBudget > 0 {
            suppressedPrewarmFailureBudget -= 1
            logDictation("DICTATION_COORD suppressed_prewarm_failure stage=\(stage.rawValue) message=\(message) \(attemptContext())")
            return
        }
        logDictation("DICTATION_STOP trace_id=DICTATION_STOP_TRANSPORT_FAILURE caller=handleTransportFailure ts=\(Date().timeIntervalSince1970) stage=\(stage.rawValue) message=\(message) \(stopLivenessContext()) \(attemptContext())")
        analytics.trackError(errorCode: nil, stage: stage.rawValue)
        pendingAction = .transportFailure(stage: stage.rawValue)
        await stopKeep(
            reason: "transport_failure",
            timeout: .zero,
            announceStop: false,
            gracefulFinalize: false,
            collapseSurface: false,
            keepAudioForPausedWaveform: false,
            trigger: "transport_failure"
        )
        guard shouldPresentDictationErrorSurface else {
            logDictation("DICTATION_COORD transport_failure_suppressed_to_idle stage=\(stage.rawValue) message=\(message) \(attemptContext())")
            errorMessage = nil
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
        keepAudioForPausedWaveform explicitKeepAudioForPausedWaveform: Bool? = nil,
        trigger: String = "unspecified",
        callSite: String = DictationSession.callSite()
    ) async -> Bool {
        logDictation(
            "DICTATION_STOP stopKeep_top ts=\(Date().timeIntervalSince1970) reason=\(reason) " +
            "state=\(String(describing: state)) callsite=\(callSite) \(stopLivenessContext()) \(attemptContext())"
        )
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie || state == .stoppingKeep else {
            logger.notice(
                "Dictation stopKeep ignored reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
            )
            return false
        }

        switch pendingAction {
        case .protocolError, .transportFailure:
            // Preserve failure outcomes while reusing stopKeep finalization mechanics.
            break
        default:
            pendingAction = .stopKeep(reason: reason, trigger: trigger, callSite: callSite)
        }
        logger.notice(
            "Dictation stopKeep requested reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) gracefulFinalize=\(gracefulFinalize, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
        )

        if state != .finalizing {
            state = .finalizing
        }

        if collapseSurface && collapseSurfaceImmediately {
            projectSurfaceClosedForFinalization()
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
        let keepAudioForPausedWaveform = explicitKeepAudioForPausedWaveform ?? !collapseSurface
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
    ) async {
        guard state == .dictatingSticky || state == .dictatingPaused || state == .dictatingWalkieTalkie || state == .stoppingKeep else { return }

        pendingAction = .dismiss(reason: reason, trigger: trigger, callSite: callSite)
        logDictation("DICTATION_STOP stopDiscard_entry reason=\(reason) trigger=\(trigger) callsite=\(callSite) \(attemptContext())")
        logger.notice(
            "Dictation stopDiscard requested reason=\(reason, privacy: .public) trigger=\(trigger, privacy: .public) callSite=\(callSite, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
        )

        state = .stoppingDiscard

        cancelMaxDurationTimer(reason: "stopDiscard_enter", caller: "stopDiscard")
        cancelTokenInactivityTimer(reason: "stopDiscard_enter")
        cancelPendingTranscriptApply()
        prewarmConnectTask?.cancel()
        prewarmConnectTask = nil
        prewarmConnectStartedAt = nil
        suppressedPrewarmFailureBudget = 0
        audioCapture?.stop()
        state = .finalizing
        let _ = await finalizeForPendingStopAction(
            reason: reason,
            timeout: timing.sendFinalizeTimeout
        )
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
            guard !Task.isCancelled else {
                return finishedReceived
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
        let queuedActivationMode = pendingActivationMode
        let queuedActivationWalkieOrigin = pendingActivationWalkieOrigin
        let duration = elapsedSessionMilliseconds()
        let stopContext = pendingAction.logContext
        logger.notice(
            "Dictation finalizeSessionCleanup reason=\(reason, privacy: .public) stopContext=\(stopContext, privacy: .public) announceStop=\(announceStop, privacy: .public) durationMs=\(duration, privacy: .public)"
        )
        analytics.trackStop(reason: reason, durationMs: duration)

        if announceStop {
            feedback.notifySuccess()
            feedback.announce("Dictation stopped")
        }

        if !keepAudioForPausedWaveform {
            audioLevel = 0
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
        prewarmConnectStartedAt = nil

        if !keepAudioForPausedWaveform {
            audioCapture = nil
        }
        streamingClient = nil
        isSocketConnected = false
        isPhase3StreamingAudio = false
        bufferedAudioFrames.removeAll(keepingCapacity: false)
        prewarmGeneration = nil

        if !keepAudioForPausedWaveform {
            clearOriginSessionContext()
        }
        pendingAction = .none

        if collapseSurface, state != .error {
            state = .idleSurfaceClosed
        } else if !collapseSurface, keepAudioForPausedWaveform, state != .error {
            state = .dictatingPaused
        }

        if let queuedActivationMode {
            pendingActivationMode = nil
            pendingActivationWalkieOrigin = nil
            start(mode: queuedActivationMode, walkieOrigin: queuedActivationWalkieOrigin)
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

    private func projectSurfaceClosedForFinalization() {
        uiProjectionState = .idleSurfaceClosed
        surfaceTarget = .closed
    }

    @discardableResult
    private func pauseListening(reason: String) async -> Bool {
        guard state == .dictatingSticky || state == .dictatingWalkieTalkie || state == .dictatingPaused || state == .finalizing else { return false }
        guard !pauseListeningInFlight else {
            logDictation(
                "DICTATION_STOP trace_id=DICTATION_STOP_PAUSE_DUPLICATE_SUPPRESSED " +
                "caller=pauseListening reason=\(reason) ts=\(Date().timeIntervalSince1970) \(attemptContext())"
            )
            return false
        }
        pauseListeningInFlight = true
        defer { pauseListeningInFlight = false }
        logDictation("DICTATION_STOP pauseListening_entry reason=\(reason) \(attemptContext())")
        if case .transportFailure = pendingAction {
            // Preserve the transport-failure outcome while reusing pause finalization mechanics.
        } else {
            pendingAction = .pause(reason: reason)
        }
        state = .finalizing
        let keepCaptureForPausedWaveform = reason == "waveform_tap_pause"
            || reason == "walkie_release_to_paused"
            || reason == "send_tap_pause"
        cancelMaxDurationTimer(reason: "pauseListening", caller: "pauseListening")
        cancelTokenInactivityTimer(reason: "pauseListening")
        flushPendingTranscriptApply()
        prewarmConnectTask?.cancel()
        prewarmConnectTask = nil
        prewarmConnectStartedAt = nil
        suppressedPrewarmFailureBudget = 0

        let finalizedWithinTimeout = await finalizeForPendingStopAction(
            reason: reason,
            timeout: timing.sendFinalizeTimeout
        )
        streamingClient?.close(
            code: .normalClosure,
            reason: "paused",
            caller: "DictationSession.pauseListening reason=\(reason)"
        )

        eventTask?.cancel()
        eventTask = nil
        if !keepCaptureForPausedWaveform {
            frameTask?.cancel()
            frameTask = nil
        }
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

        let queuedActivationMode = pendingActivationMode
        let queuedActivationWalkieOrigin = pendingActivationWalkieOrigin
        state = .dictatingPaused
        schedulePhase1IdleTeardown()
        if let queuedActivationMode {
            pendingActivationMode = nil
            pendingActivationWalkieOrigin = nil
            start(mode: queuedActivationMode, walkieOrigin: queuedActivationWalkieOrigin)
        }
        return finalizedWithinTimeout
    }

    @discardableResult
    private func finalizeForPendingStopAction(reason: String, timeout: Duration) async -> Bool {
        guard streamingClient != nil else { return false }
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
        return finalizedWithinTimeout
    }

    private func resumeFromPaused() {
        guard state == .dictatingPaused else { return }
        start(mode: .sticky, walkieOrigin: nil)
    }

    private func schedulePhase1IdleTeardown() {
        phase1IdleTeardownTask?.cancel()
        phase1IdleTeardownTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
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
        prewarmConnectStartedAt = nil
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

    private func ensurePhase1Prepared() {
        if streamingClient == nil {
            let client = streamingClientFactory()
            streamingClient = client
            eventTask = Task { [weak self] in
                guard let self else { return }
                for await event in client.events {
                    await self.handleSonioxEvent(event, from: client)
                }
            }
        }

        if audioCapture == nil {
            audioCapture = audioCaptureFactory()
        }

        if let capture = audioCapture {
            if frameTask == nil {
                frameTask = Task { [weak self] in
                    guard let self else { return }
                    for await frame in capture.frameStream {
                        await self.handleCapturedFrame(frame)
                    }
                }
            }

            if levelTask == nil {
                levelTask = Task { [weak self] in
                    guard let self else { return }
                    let minimumWaveformUpdateInterval: CFTimeInterval = 1.0 / 60.0
                    var lastWaveformUpdateAt = CFAbsoluteTimeGetCurrent() - minimumWaveformUpdateInterval
                    for await level in capture.levelStream {
                        let now = CFAbsoluteTimeGetCurrent()
                        guard now - lastWaveformUpdateAt >= minimumWaveformUpdateInterval else { continue }
                        lastWaveformUpdateAt = now
                        let nextLevel = max(0, level)
                        await MainActor.run {
                            self.audioLevel = nextLevel
                        }
                    }
                }
            }

            if audioEventTask == nil {
                audioEventTask = Task { [weak self] in
                    guard let self else { return }
                    for await event in capture.eventStream {
                        await self.handleAudioCaptureEvent(event)
                    }
                }
            }
        }
    }

    private func elapsedSessionMilliseconds() -> Int {
        guard let sessionStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
    }

    private func queueTranscriptApply(_ update: DictationSegmentUpdate, immediate: Bool) {
        logDictation(
            "DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=queue_transcript_apply immediate=\(immediate) " +
            "committed_segments=\(update.committedSegments.count) provisional_chars=\(update.provisionalText.count) finished=\(update.finished)"
        )
        updateActiveTranscriptSession { session in
            if let pending = session.pendingUpdate {
                session.pendingUpdate = TranscriptEngine.mergeUpdates(pending, update)
            } else {
                session.pendingUpdate = update
            }
        }
        // Endpoint commits (committedSegments) must never wait behind provisional coalescing.
        let shouldFlushImmediately = immediate || !update.committedSegments.isEmpty
        if shouldFlushImmediately {
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
        guard var session = activeTranscriptSession(), let update = session.pendingUpdate else { return }
        session.pendingUpdate = nil
        transcriptOwnership = .active(session)
        applyTranscriptIfNeeded(update)
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=flush_transcript_apply_end")
    }

    private func cancelPendingTranscriptApply() {
        transcriptApplyTask?.cancel()
        transcriptApplyTask = nil
        updateActiveTranscriptSession { session in
            session.pendingUpdate = nil
        }
    }

    private func logDictation(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print(message)
    }

    private func initializeOriginSessionContext(for sessionKey: String, walkieOrigin: WalkieOrigin?) {
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=capture_snapshot_begin session=\(sessionKey)")
        let capturedSnapshot = bridge.captureSnapshot(for: sessionKey)
        let snapshot = authoritativeActivationSnapshot(
            capturedSnapshot,
            sessionKey: sessionKey
        )
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=capture_snapshot_end session=\(sessionKey)")
        let activationSelectionRange = activationSelectionRangeForAuthoritativeSnapshot(snapshot)
        let selectedRange = resolvedTranscriptAnchorRange(
            activationSelectionRange: activationSelectionRange,
            snapshot: snapshot
        )
        let initialProvisionalText = TranscriptEngine.substring(text: snapshot.content.string, utf16Range: selectedRange) ?? ""
        transcriptOwnership = .active(
            TranscriptSession(
                originSessionKey: sessionKey,
                baseSnapshot: snapshot,
                dictationStartUTF16: selectedRange.location,
                baseReplacementLenUTF16: selectedRange.length,
                committedLenUTF16: 0,
                provisionalText: initialProvisionalText,
                suppressedUntilNextEndpoint: false,
                committedText: "",
                pendingUpdate: nil,
                activationSelectionRange: activationSelectionRange,
                transcriptPrefixToDiscardAfterReanchor: "",
                walkieOrigin: walkieOrigin
            )
        )
        transcriptBuffer.reset()
        pendingActivationSelectionRange = nil
        hasExplicitActivationSelectionCapture = false
    }

    private func authoritativeActivationSnapshot(
        _ capturedSnapshot: ComposeDraftSnapshot,
        sessionKey: String
    ) -> ComposeDraftSnapshot {
        guard let boundComposeTextView = bridge.boundComposeTextView,
              !((boundComposeTextView.attributedText?.isEqual(capturedSnapshot.content)) ?? false) else {
            return capturedSnapshot
        }
        bridge.restore(snapshot: capturedSnapshot, to: sessionKey)
        return capturedSnapshot
    }

    private func activationSelectionRangeForAuthoritativeSnapshot(_ snapshot: ComposeDraftSnapshot) -> NSRange? {
        if composeIsEmpty, snapshot.content.length == 0 {
            return nil
        }
        return pendingActivationSelectionRange
    }

    private func clearOriginSessionContext() {
        transcriptOwnership = .inactive
        pendingActivationSelectionRange = nil
        hasExplicitActivationSelectionCapture = false
    }

    private func resetActiveTranscriptSessionAfterComposeCleared() {
        guard var session = activeTranscriptSession() else { return }
        guard session.originSessionKey == currentSessionKey else { return }

        let machineTextToDiscard =
            session.transcriptPrefixToDiscardAfterReanchor +
            session.committedText +
            session.provisionalText
        cancelPendingTranscriptApply()
        let capturedSnapshot = bridge.captureSnapshot(for: session.originSessionKey)
        let snapshot = authoritativeActivationSnapshot(
            capturedSnapshot,
            sessionKey: session.originSessionKey
        )
        let anchor = NSRange(location: snapshot.content.length, length: 0)

        session.baseSnapshot = snapshot
        session.dictationStartUTF16 = anchor.location
        session.baseReplacementLenUTF16 = 0
        session.committedLenUTF16 = 0
        session.committedText = ""
        session.provisionalText = ""
        session.suppressedUntilNextEndpoint = false
        session.pendingUpdate = nil
        session.activationSelectionRange = anchor
        session.transcriptPrefixToDiscardAfterReanchor = machineTextToDiscard
        transcriptOwnership = .active(session)
        transcriptBuffer.reset()
        latestComposeSelectionRange = anchor
        pendingActivationSelectionRange = nil
        hasExplicitActivationSelectionCapture = false
    }

    private func applyTranscriptIfNeeded(_ update: DictationSegmentUpdate) {
        if isDictationActive,
           let originSessionKey,
           !originSessionKey.isEmpty,
           !currentSessionKey.isEmpty,
           originSessionKey != currentSessionKey {
            logDictation("DICTATION_STOP stream_switch_guard_apply_mismatch origin=\(originSessionKey) current=\(currentSessionKey)")
            if state == .dictatingSticky || state == .dictatingWalkieTalkie {
                state = .stoppingKeep
            }
            requestStreamSwitchStopIfNeeded(trigger: "stream_switch_apply_guard")
            return
        }
        let wallTs = Date().timeIntervalSince1970
        logDictation(
            "DICTATION_PERF ts=\(wallTs) event=apply_transcript_begin " +
            "committed_segments=\(update.committedSegments.count) provisional_chars=\(update.provisionalText.count) finished=\(update.finished)"
        )
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard var session = activeTranscriptSession() else { return }
        let previousTranscriptUTF16Length = session.previousTranscriptUTF16Length
        let previousTranscriptText = session.committedText + session.provisionalText
        if let textView = bridge.boundComposeTextView {
            TranscriptEngine.syncCommittedText(from: textView.attributedText.string, session: &session)
        } else {
            TranscriptEngine.syncCommittedText(
                from: bridge.captureSnapshot(for: session.originSessionKey).content.string,
                session: &session
            )
        }
        TranscriptEngine.applySegmentUpdate(update, to: &session)
        let replacementText = NSAttributedString(
            string: session.committedText + session.provisionalText,
            attributes: defaultTextAttributes()
        )
        let replacementRange = NSRange(
            location: session.dictationStartUTF16,
            length: previousTranscriptUTF16Length
        )
        let applicationMode = textApplicationMode(
            for: session,
            replacementRange: replacementRange,
            expectedTranscript: previousTranscriptText
        )
        let plan = DictationTextApplicationPlan(
            sessionKey: session.originSessionKey,
            baseSnapshot: session.baseSnapshot,
            replacementRange: replacementRange,
            fallbackReplacementRange: NSRange(
                location: session.dictationStartUTF16,
                length: session.baseReplacementLenUTF16
            ),
            fallbackLocation: session.dictationStartUTF16,
            replacementText: replacementText,
            selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd,
            applicationMode: applicationMode,
            suppressReentrantFeedback: true
        )
        transcriptOwnership = .active(session)
        bridge.apply(plan)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        logDictation("DICTATION_PERF ts=\(Date().timeIntervalSince1970) event=apply_transcript_end elapsedMs=\(elapsedMs)")
        logger.notice("[DICTATION-PERF] applyTranscriptIfNeeded: \(elapsedMs, privacy: .public)ms")
    }

    private func currentTranscriptReplayPlan() -> DictationTextApplicationPlan? {
        guard let session = activeTranscriptSession() else { return nil }
        guard !session.originSessionKey.isEmpty else { return nil }
        guard session.originSessionKey == currentSessionKey else { return nil }
        switch state {
        case .dictatingSticky, .dictatingPaused, .dictatingWalkieTalkie, .finalizing, .stoppingKeep:
            break
        case .idleSurfaceClosed, .keyPromptModal, .keyVerifyingModal, .stoppingDiscard, .error:
            return nil
        }
        return DictationTextApplicationPlan(
            sessionKey: session.originSessionKey,
            baseSnapshot: session.baseSnapshot,
            replacementRange: NSRange(
                location: session.dictationStartUTF16,
                length: session.previousTranscriptUTF16Length
            ),
            fallbackLocation: session.dictationStartUTF16,
            replacementText: NSAttributedString(
                string: session.committedText + session.provisionalText,
                attributes: defaultTextAttributes()
            ),
            selectionPolicy: .preserveUserSelection,
            suppressReentrantFeedback: true
        )
    }

    private func textApplicationMode(
        for session: TranscriptSession,
        replacementRange: NSRange,
        expectedTranscript: String
    ) -> DictationTextApplicationMode {
        guard !expectedTranscript.isEmpty else { return .replaceRange }
        let snapshot = liveComposeSnapshot(for: session.originSessionKey)
        guard TranscriptEngine.substring(text: snapshot.content.string, utf16Range: replacementRange) == expectedTranscript else {
            return .restoreBaseAndAppendReplacement
        }
        return .replaceRange
    }

    private func resolvedTranscriptAnchorRange(
        activationSelectionRange: NSRange?,
        snapshot: ComposeDraftSnapshot
    ) -> NSRange {
        let selectedRange = activationSelectionRange
        return TranscriptEngine.safeReplacementRange(
            selectedRange: selectedRange ?? NSRange(location: NSNotFound, length: 0),
            textLength: snapshot.content.length,
            fallbackLocation: snapshot.content.length
        )
    }

    private func defaultTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
    }

    private func reanchorActiveTranscriptSessionToLiveSelection(discardCurrentMachineTextFromPendingStream: Bool = true) {
        guard let selectionRange = bridge.boundComposeTextView?.selectedRange,
              selectionRange.location != NSNotFound else { return }
        reanchorActiveTranscriptSession(
            to: selectionRange,
            discardCurrentMachineTextFromPendingStream: discardCurrentMachineTextFromPendingStream
        )
    }

    private func reanchorActiveTranscriptSession(
        to selectionRange: NSRange,
        discardCurrentMachineTextFromPendingStream: Bool = true
    ) {
        guard var session = activeTranscriptSession() else { return }
        guard session.originSessionKey == currentSessionKey else { return }
        let snapshot = liveComposeSnapshot(for: session.originSessionKey)
        let selectedRange = TranscriptEngine.safeReplacementRange(
            selectedRange: selectionRange,
            textLength: snapshot.content.length,
            fallbackLocation: snapshot.content.length
        )
        let selectedText = TranscriptEngine.substring(text: snapshot.content.string, utf16Range: selectedRange) ?? ""
        let currentMachineText =
            session.transcriptPrefixToDiscardAfterReanchor +
            session.committedText +
            session.provisionalText
        let pendingUpdate = session.pendingUpdate

        transcriptApplyTask?.cancel()
        transcriptApplyTask = nil
        session.baseSnapshot = snapshot
        session.dictationStartUTF16 = selectedRange.location
        session.baseReplacementLenUTF16 = selectedRange.length
        session.committedLenUTF16 = 0
        session.committedText = ""
        session.provisionalText = selectedText
        session.suppressedUntilNextEndpoint = false
        session.pendingUpdate = pendingUpdate
        session.activationSelectionRange = selectedRange
        session.transcriptPrefixToDiscardAfterReanchor = discardCurrentMachineTextFromPendingStream
            ? currentMachineText
            : ""
        transcriptOwnership = .active(session)
        if discardCurrentMachineTextFromPendingStream {
            transcriptBuffer.reset()
        }
        if pendingUpdate != nil {
            flushPendingTranscriptApply()
        }
    }

    private func liveComposeSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        let capturedSnapshot = bridge.captureSnapshot(for: sessionKey)
        guard let textView = bridge.boundComposeTextView else { return capturedSnapshot }
        return ComposeDraftSnapshot(
            content: textView.attributedText ?? NSAttributedString(string: ""),
            attachments: capturedSnapshot.attachments
        )
    }

    private func isPrewarmConnectStale(maxAge seconds: TimeInterval) -> Bool {
        guard let startedAt = prewarmConnectStartedAt else { return false }
        guard prewarmConnectTask != nil else { return false }
        return Date().timeIntervalSince(startedAt) >= seconds
    }
}

typealias DictationCoordinator = DictationSession
