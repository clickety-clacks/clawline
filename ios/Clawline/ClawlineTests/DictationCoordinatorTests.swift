import Foundation
import Testing
@testable import Clawline

struct DictationCoordinatorTests {
    @Test("Transcript buffer appends finals and replaces non-finals")
    func transcriptBufferReconciliation() {
        let buffer = DictationTranscriptBuffer()

        let first = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "hel", isFinal: false)
        ], finished: false)
        #expect(first.text == "hel")

        let second = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "hello ", isFinal: true),
            SonioxTranscriptToken(text: "wor", isFinal: false),
            SonioxTranscriptToken(text: "<end>", isFinal: true)
        ], finished: false)
        #expect(second.text == "hello wor")

        let third = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "world", isFinal: false)
        ], finished: true)
        #expect(third.text == "hello ")
    }

    @Test("Socket drop forces stop_keep and exits active dictation")
    @MainActor
    func socketDropStopsSession() async {
        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()
        #expect(coordinator.state == .dictatingSticky)

        harness.client.emit(.closed(code: nil, reason: "transport drop"))

        await waitUntil {
            coordinator.state == .idleMicVisible || coordinator.state == .idleMicHidden
        }

        #expect(harness.client.closeCalls.count >= 1)
        #expect(harness.analytics.stopEvents.contains(where: { $0.reason == "socket_drop" }))
    }

    @Test("Token inactivity timeout stops dictation")
    @MainActor
    func inactivityTimeoutStopsSession() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .milliseconds(120),
                stopKeepFinalizeTimeout: .milliseconds(50),
                sendFinalizeTimeout: .milliseconds(40),
                errorAutoDismissTimeout: .milliseconds(30),
                errorAutoDismissVoiceOverTimeout: .milliseconds(30)
            )
        )
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()
        #expect(coordinator.state == .dictatingSticky)

        await waitUntil(timeoutMs: 1_500) {
            harness.analytics.stopEvents.contains(where: { $0.reason == "token_inactivity" })
        }
    }

    @Test("Send while active uses timeout path and still sends current draft")
    @MainActor
    func sendWhileActiveTimeoutSendsCurrentText() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(30),
                stopKeepFinalizeTimeout: .milliseconds(80),
                sendFinalizeTimeout: .milliseconds(60),
                errorAutoDismissTimeout: .milliseconds(30),
                errorAutoDismissVoiceOverTimeout: .milliseconds(30)
            )
        )
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()
        harness.client.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: [SonioxTranscriptToken(text: "hello", isFinal: false)],
                    finished: false,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )

        await waitUntil {
            harness.host.currentText(for: harness.host.activeSessionKey) == "hello"
        }

        var didSend = false
        coordinator.handleSendTapped {
            didSend = true
        }

        await waitUntil {
            didSend
        }

        #expect(harness.host.currentText(for: harness.host.activeSessionKey) == "hello")
        #expect(harness.analytics.sendWhileActiveEvents.contains(false))
    }

    @Test("Discard restores pre-dictation snapshot")
    @MainActor
    func discardRestoresSnapshot() async {
        let harness = DictationTestHarness()
        harness.host.setText("seed text", for: harness.host.activeSessionKey)

        let coordinator = harness.makeCoordinator()
        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: false,
            textFieldFocused: true,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()

        harness.client.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: [SonioxTranscriptToken(text: " added", isFinal: false)],
                    finished: false,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )

        await waitUntil {
            harness.host.currentText(for: harness.host.activeSessionKey) == "seed text added"
        }

        coordinator.discardFromVoiceOverAction()

        await waitUntil {
            harness.host.currentText(for: harness.host.activeSessionKey) == "seed text"
        }
    }

    @Test("Attempting dictation without a validated key shows inline prompt and keeps mic visibility rules")
    @MainActor
    func missingOrUnverifiedKeyRoutesToInlinePrompt() {
        let harness = DictationTestHarness(apiKey: nil, keyStatus: .missing)
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        #expect(coordinator.micVisible)
        coordinator.startStickyDictation()

        #expect(coordinator.state == .keyPromptInline)
        #expect(coordinator.showsInlineKeyPrompt)
        #expect(coordinator.micVisible)
        #expect(!coordinator.isDictationActive)
    }

    @Test("Inline key CTA opens Soniox key page when key is empty")
    @MainActor
    func inlineGetKeyWhenEmpty() async {
        let harness = DictationTestHarness(apiKey: nil, keyStatus: .missing)
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )
        coordinator.startStickyDictation()
        #expect(coordinator.state == .keyPromptInline)
        #expect(coordinator.inlineKeyActionTitle == "Get Key")

        var openedURL: URL?
        await coordinator.handleInlineKeyPrimaryAction { url in
            openedURL = url
        }

        #expect(openedURL == SonioxConfigurationStore.keyManagementURL)
        #expect(coordinator.state == .keyPromptInline)
        #expect(coordinator.inlineKeyStatus == .missing)
        #expect(harness.keyStatus == .missing)
    }

    @Test("Inline verify failure shows Invalid and keeps prompt visible")
    @MainActor
    func inlineVerifyFailureShowsInvalid() async {
        let harness = DictationTestHarness(apiKey: "bad-key", keyStatus: .unverified)
        harness.keyVerifier.results = [false]
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()
        #expect(coordinator.state == .keyPromptInline)
        #expect(coordinator.inlineKeyActionTitle == "Verify")

        await coordinator.handleInlineKeyPrimaryAction { _ in }

        #expect(coordinator.state == .keyPromptInline)
        #expect(coordinator.inlineKeyStatus == .invalid)
        #expect(coordinator.inlineKeyStatusText == "Invalid")
        #expect(harness.keyStatus == .invalid)
        #expect(!coordinator.isDictationActive)
    }

    @Test("Inline verify success immediately enters pending requested dictation mode")
    @MainActor
    func inlineVerifySuccessStartsRequestedModeImmediately() async {
        let harness = DictationTestHarness(apiKey: "good-key", keyStatus: .unverified)
        harness.keyVerifier.results = [true]
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startWalkieTalkieDictation()
        #expect(coordinator.state == .keyPromptInline)
        #expect(!coordinator.isDictationActive)

        await coordinator.handleInlineKeyPrimaryAction { _ in }
        await waitUntil {
            harness.client.connected
        }

        #expect(coordinator.state == .dictatingWalkieTalkie)
        #expect(coordinator.isDictationActive)
        #expect(coordinator.inlineKeyStatus == .validated)
        #expect(harness.keyStatus == .validated)
        #expect(harness.client.connected)
    }
}

// MARK: - Test Harness

@MainActor
private final class DictationTestHarness {
    let host = MockComposeDraftHost()
    let client = SonioxMockFixtureClient()
    let audio = MockDictationAudioCapture()
    let analytics = MockDictationAnalytics()
    let feedback = MockDictationFeedback()
    let keyVerifier = MockSonioxKeyVerifier()
    let timing: DictationTiming
    var apiKey: String?
    var editableAPIKey: String
    var keyStatus: SonioxKeyVerificationStatus

    init(
        timing: DictationTiming = DictationTiming(
            maxSessionDuration: .seconds(30),
            tokenInactivityTimeout: .seconds(30),
            stopKeepFinalizeTimeout: .milliseconds(120),
            sendFinalizeTimeout: .milliseconds(80),
            errorAutoDismissTimeout: .milliseconds(50),
            errorAutoDismissVoiceOverTimeout: .milliseconds(50)
        ),
        apiKey: String? = "test-key",
        keyStatus: SonioxKeyVerificationStatus = .validated
    ) {
        self.timing = timing
        self.apiKey = apiKey
        self.editableAPIKey = apiKey ?? ""
        self.keyStatus = keyStatus
    }

    func makeCoordinator() -> DictationCoordinator {
        DictationCoordinator(
            bridge: ComposeInputDictationBridge(host: host),
            configuredAPIKey: { self.apiKey },
            editableAPIKeyProvider: { self.editableAPIKey },
            keyStatusProvider: { self.keyStatus },
            setConfiguredAPIKey: {
                self.apiKey = $0
                self.editableAPIKey = $0 ?? ""
            },
            setKeyStatus: { self.keyStatus = $0 },
            keyVerifier: keyVerifier,
            languageHintProvider: { "en" },
            audioCaptureFactory: { self.audio },
            streamingClientFactory: { self.client },
            analytics: analytics,
            feedback: feedback,
            timing: timing
        )
    }
}

@MainActor
private final class MockComposeDraftHost: DictationComposeDraftHosting {
    var activeSessionKey: String = "agent:main:test:main"
    private var drafts: [String: ComposeDraftSnapshot] = ["agent:main:test:main": .empty]

    func captureComposeDraftSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        drafts[sessionKey] ?? .empty
    }

    func applyComposeDraftSnapshot(_ snapshot: ComposeDraftSnapshot,
                                   to sessionKey: String,
                                   moveCursorToEnd: Bool,
                                   announceEditorReset: Bool) {
        drafts[sessionKey] = snapshot
    }

    func setText(_ text: String, for sessionKey: String) {
        drafts[sessionKey] = ComposeDraftSnapshot(content: NSAttributedString(string: text), attachments: [:])
    }

    func currentText(for sessionKey: String) -> String {
        drafts[sessionKey]?.content.string ?? ""
    }
}

private final class MockDictationAudioCapture: DictationAudioCapturing {
    private var frameContinuation: AsyncStream<Data>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    private(set) var started = false
    private(set) var stopped = false

    let frameStream: AsyncStream<Data>
    let levelStream: AsyncStream<Float>

    init() {
        var frameCont: AsyncStream<Data>.Continuation?
        frameStream = AsyncStream { frameCont = $0 }
        frameContinuation = frameCont

        var levelCont: AsyncStream<Float>.Continuation?
        levelStream = AsyncStream { levelCont = $0 }
        levelContinuation = levelCont
    }

    func start() throws {
        started = true
    }

    func stop() {
        stopped = true
        frameContinuation?.finish()
        levelContinuation?.finish()
    }

    func emit(level: Float) {
        levelContinuation?.yield(level)
    }
}

private final class MockSonioxKeyVerifier: SonioxKeyVerifying {
    var results: [Bool] = [true]
    private(set) var verifiedKeys: [String] = []

    func verify(apiKey: String) async -> Bool {
        verifiedKeys.append(apiKey)
        if !results.isEmpty {
            return results.removeFirst()
        }
        return false
    }
}

private final class SonioxMockFixtureClient: SonioxStreamingClienting {
    private var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
    let events: AsyncStream<SonioxStreamingEvent>

    private(set) var connected = false
    private(set) var finalized = false
    private(set) var sentFrames: [Data] = []
    private(set) var closeCalls: [(code: Int, reason: String?)] = []

    init() {
        var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(config: SonioxStreamingConfig) async throws {
        connected = true
    }

    func sendAudioFrame(_ frame: Data) async throws {
        sentFrames.append(frame)
    }

    func sendFinalize() async throws {
        finalized = true
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: String?) {
        closeCalls.append((Int(code.rawValue), reason))
    }

    func emit(_ event: SonioxStreamingEvent) {
        continuation?.yield(event)
    }

    func emitAfter(_ milliseconds: UInt64, _ event: SonioxStreamingEvent) {
        Task {
            try? await Task.sleep(for: .milliseconds(Int(milliseconds)))
            continuation?.yield(event)
        }
    }
}

@MainActor
private final class MockDictationAnalytics: DictationAnalyticsTracking {
    struct StopEvent {
        let reason: String
        let durationMs: Int
    }

    private(set) var stopEvents: [StopEvent] = []
    private(set) var sendWhileActiveEvents: [Bool] = []

    func trackStart(mode: DictationMode, sessionKey: String) {}

    func trackStop(reason: String, durationMs: Int) {
        stopEvents.append(StopEvent(reason: reason, durationMs: durationMs))
    }

    func trackError(errorCode: String?, stage: String) {}

    func trackSendWhileActive(finalizedWithinTimeout: Bool) {
        sendWhileActiveEvents.append(finalizedWithinTimeout)
    }

    func trackSocketDrop(mode: DictationMode, elapsedMs: Int) {}
}

@MainActor
private final class MockDictationFeedback: DictationFeedbackProviding {
    var isVoiceOverRunning: Bool = false
    var isReduceMotionEnabled: Bool = false

    func announce(_ message: String) {}
    func impactLight() {}
    func notifySuccess() {}
    func notifyError() {}
}

@MainActor
private func waitUntil(timeoutMs: UInt64 = 1_000, predicate: @escaping @MainActor () -> Bool) async {
    let start = Date()
    while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
        if predicate() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
