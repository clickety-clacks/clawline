import Foundation
import Testing
import UIKit
@testable import Clawline

@Suite(.serialized)
struct DictationCoordinatorTests {
    @Test("Transcript buffer emits endpoint commit updates")
    func transcriptBufferReconciliation() {
        let buffer = DictationTranscriptBuffer()

        let first = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "hel", isFinal: false)
        ], finished: false)
        #expect(first.provisionalText == "hel")
        #expect(first.committedSegments.isEmpty)
        #expect(first.sawEndpoint == false)
        #expect(first.hadAnyTokens == true)

        let second = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "hello ", isFinal: true),
            SonioxTranscriptToken(text: "wor", isFinal: false),
            SonioxTranscriptToken(text: "<end>", isFinal: true),
            SonioxTranscriptToken(text: "<fin>", isFinal: true)
        ], finished: false)
        #expect(second.committedSegments == ["hello wor"])
        #expect(second.provisionalText.isEmpty)
        #expect(second.sawEndpoint == true)
        #expect(second.hadAnyTokens == true)

        let third = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "world", isFinal: false)
        ], finished: true)
        #expect(third.committedSegments.isEmpty)
        #expect(third.provisionalText == "world")
        #expect(third.finished == true)
    }

    @Test("Transcript buffer emits multiple committed segments from one update")
    func transcriptBufferCommitsMultipleSegmentsInOneUpdate() {
        let buffer = DictationTranscriptBuffer()
        let update = buffer.apply(tokens: [
            SonioxTranscriptToken(text: "hello", isFinal: true),
            SonioxTranscriptToken(text: "<end>", isFinal: true),
            SonioxTranscriptToken(text: " world", isFinal: true),
            SonioxTranscriptToken(text: "<end>", isFinal: true),
            SonioxTranscriptToken(text: "!", isFinal: false)
        ], finished: false)

        #expect(update.committedSegments == ["hello", " world"])
        #expect(update.provisionalText == "!")
        #expect(update.sawEndpoint == true)
        #expect(update.hadAnyTokens == true)
    }

    @Test("Socket drop pauses without collapsing the surface")
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
        #expect(coordinator.isStickyDictationActive)
        await waitUntil { harness.client.connected }

        harness.client.emit(.closed(code: nil, reason: "transport drop"))

        await waitUntil { !coordinator.isListening }

        #expect(coordinator.isSurfaceOpen)
        #expect(coordinator.isDictationActive)
        #expect(!coordinator.isListening)
    }

    @Test("Phase 1 prewarm prepares resources when compose becomes active")
    @MainActor
    func phase1PrewarmPreparesResources() {
        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        #expect(harness.audioFactoryCallCount == 1)
        #expect(harness.clientFactoryCallCount == 1)
        #expect(harness.client.connectCallCount == 0)
        #expect(harness.audio.started == false)
    }

    @Test("Gesture prewarm starts phase 2 connection before activation commit")
    @MainActor
    func gesturePrewarmStartsPhase2Connection() async {
        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.beginGesturePrewarm()

        await waitUntil { harness.client.connectCallCount >= 1 }

        #expect(harness.client.connectCallCount >= 1)
        #expect(harness.audio.started)
    }

    @Test("Gesture-time phase 2 failure cancels activation before surface opens")
    @MainActor
    func gestureTimePhase2FailureCancelsActivation() async {
        let harness = DictationTestHarness()
        harness.client.connectBehavior = .fail(DictationTestError.connectFailed)
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.beginGesturePrewarm()
        await waitUntil { coordinator.errorMessage == "Dictation failed" }

        coordinator.startStickyDictation()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.errorMessage == "Dictation failed")
        #expect(!coordinator.isDictationActive)
        #expect(!coordinator.isListening)
    }

    @Test("Stream switch while listening deterministically stops listening")
    @MainActor
    func streamSwitchStopsListeningDeterministically() async {
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
        #expect(coordinator.isListening)
        await waitUntil { harness.client.connected }

        let newSessionKey = "agent:main:test:switched"
        harness.host.activeSessionKey = newSessionKey
        coordinator.updateContext(
            sessionKey: newSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        // If streaming events arrive while session keys are mismatched, we should still stop listening.
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

        await waitUntil(timeoutMs: 1_500) {
            !coordinator.isListening
                && harness.client.finalized
                && !harness.client.closeCalls.isEmpty
                && harness.analytics.stopEvents.contains(where: { $0.reason == "stream_switch" })
        }
        #expect(!coordinator.isListening)
        #expect(coordinator.isSurfaceOpen)
        #expect(coordinator.isDictationActive)
        #expect(harness.analytics.stopEvents.contains(where: { $0.reason == "stream_switch" }))
        #expect(harness.client.finalized)
        #expect(harness.client.closeCalls.count >= 1)
    }

    @Test("Flick-up sticky honors activation eligibility captured at gesture begin")
    @MainActor
    func flickUpStickyUsesGestureStartActivationSnapshot() {
        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        let eligibleMotion = DictationMotion(session: coordinator)
        eligibleMotion.gestureBegan(originWasOpen: false, swipeActivationEnabled: true)
        eligibleMotion.gestureChanged(translationY: -60, velocityY: -1_100)
        let eligibleIntent = eligibleMotion.gestureEnded(
            translationY: -60,
            predictedY: -140,
            velocityY: -1_100,
            context: .init(pullToSendEligible: false, verticallyDominant: true)
        )
        #expect(eligibleIntent == .startSticky)

        let ineligibleMotion = DictationMotion(session: coordinator)
        ineligibleMotion.gestureBegan(originWasOpen: false, swipeActivationEnabled: false)
        ineligibleMotion.gestureChanged(translationY: -60, velocityY: -1_100)
        let ineligibleIntent = ineligibleMotion.gestureEnded(
            translationY: -60,
            predictedY: -140,
            velocityY: -1_100,
            context: .init(pullToSendEligible: false, verticallyDominant: true)
        )
        #expect(ineligibleIntent == .settleClosed)
    }

    @Test("Token inactivity timeout stops dictation")
    @MainActor
    func inactivityTimeoutStopsSession() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .milliseconds(120),
                stopKeepFinalizeTimeout: .milliseconds(50),
                sendFinalizeTimeout: .milliseconds(40)
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
        #expect(coordinator.isStickyDictationActive)

        await waitUntil(timeoutMs: 1_500) {
            harness.analytics.stopEvents.contains(where: { $0.reason == "token_inactivity" })
        }
    }

    @Test("Endpoint commit updates flush immediately without coalescing delay")
    @MainActor
    func endpointCommitFlushesImmediately() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(10),
                stopKeepFinalizeTimeout: .milliseconds(120),
                sendFinalizeTimeout: .milliseconds(80),
                composeUpdateCoalescingInterval: .milliseconds(600)
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
                    tokens: [
                        SonioxTranscriptToken(text: "hello", isFinal: true),
                        SonioxTranscriptToken(text: "<end>", isFinal: true)
                    ],
                    finished: false,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )

        await waitUntil(timeoutMs: 150) {
            harness.host.currentText(for: harness.host.activeSessionKey) == "hello"
        }
        #expect(harness.host.currentText(for: harness.host.activeSessionKey) == "hello")
    }

    @Test("Empty model draft owns activation over stale bound compose surface")
    @MainActor
    func emptyModelDraftClearsStaleBoundSurfaceOnActivation() async {
        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "previous sent message")
        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
        coordinator.setComposeTextView(textView)

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: true,
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
            textView.attributedText.string == "hello"
        }

        #expect(textView.attributedText.string == "hello")
    }

    @Test("Captured model draft owns activation over stale bound compose surface")
    @MainActor
    func capturedModelDraftReplacesStaleBoundSurfaceOnActivation() async {
        let harness = DictationTestHarness()
        harness.host.setText("live draft ", for: harness.host.activeSessionKey)
        let coordinator = harness.makeCoordinator()
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "previous sent message")
        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
        coordinator.setComposeTextView(textView)

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
                    tokens: [SonioxTranscriptToken(text: "hello", isFinal: false)],
                    finished: false,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )

        await waitUntil {
            textView.attributedText.string == "live draft hello"
        }

        #expect(textView.attributedText.string == "live draft hello")
    }

    @Test("Token activity resets inactivity timer while provisional updates are suppressed")
    @MainActor
    func suppressionStillResetsInactivityTimer() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .milliseconds(120),
                stopKeepFinalizeTimeout: .milliseconds(50),
                sendFinalizeTimeout: .milliseconds(40)
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

        coordinator.noteComposeUserEditDuringDictation(
            editedRangeUTF16: NSRange(location: 0, length: 0),
            replacementUTF16Length: 1
        )

        for idx in 0..<3 {
            try? await Task.sleep(for: .milliseconds(70))
            harness.client.emit(
                .response(
                    SonioxStreamingResponse(
                        tokens: [SonioxTranscriptToken(text: "hello\(idx)", isFinal: false)],
                        finished: false,
                        errorCode: nil,
                        errorMessage: nil
                    )
                )
            )
        }

        #expect(!harness.analytics.stopEvents.contains(where: { $0.reason == "token_inactivity" }))

        await waitUntil(timeoutMs: 1_500) {
            harness.analytics.stopEvents.contains(where: { $0.reason == "token_inactivity" })
        }
    }

    @Test("Send while active preserves dictation state and still sends current draft")
    @MainActor
    func sendWhileActiveTimeoutSendsCurrentText() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(30),
                stopKeepFinalizeTimeout: .milliseconds(80),
                sendFinalizeTimeout: .milliseconds(60)
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
        #expect(coordinator.isStickyDictationActive)
        #expect(coordinator.isListening)
        #expect(harness.analytics.sendWhileActiveEvents.contains(where: { $0.mode == .sticky && $0.sendSuccess }))
    }

    @Test("Activation queues through teardown and restarts after stop settles")
    @MainActor
    func activationQueuesThroughTeardown() async {
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
        await waitUntil { harness.client.connected }
        harness.client.emitAfter(
            10,
            .response(
                SonioxStreamingResponse(
                    tokens: [],
                    finished: true,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )

        coordinator.stopStickyFromMicTap()
        coordinator.startStickyDictation()

        await waitUntil(timeoutMs: 1_500) { coordinator.isStickyDictationActive && harness.client.connectCallCount >= 2 }

        #expect(coordinator.isStickyDictationActive)
        #expect(harness.client.connectCallCount >= 2)
    }

    @Test("Reported behavior 3: swipe-down dismiss collapses dictation surface")
    @MainActor
    func reportedBehaviorSwipeDownDismisses() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(30),
                stopKeepFinalizeTimeout: .milliseconds(80),
                sendFinalizeTimeout: .milliseconds(60)
            )
        )
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: true,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()
        await waitUntil { coordinator.isStickyDictationActive }

        coordinator.dismissSurfaceFromUserGesture()

        await waitUntil(timeoutMs: 1_500) {
            !coordinator.isSurfaceOpen && !coordinator.isDictationActive
        }

        #expect(!coordinator.isSurfaceOpen)
        #expect(!coordinator.isDictationActive)
    }

    @Test("Reported behavior 3: swipe-right stop collapses surface before finalization")
    @MainActor
    func reportedBehaviorSwipeRightPublishesClosedSurfaceImmediately() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(30),
                stopKeepFinalizeTimeout: .milliseconds(600),
                sendFinalizeTimeout: .milliseconds(600),
                composeUpdateCoalescingInterval: .milliseconds(75)
            )
        )
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: true,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()
        await waitUntil { coordinator.isStickyDictationActive }

        coordinator.stopDictationFromSwipeRight()

        await waitUntil(timeoutMs: 150) {
            !coordinator.isSurfaceOpen && !coordinator.isDictationActive
        }

        #expect(!coordinator.isSurfaceOpen)
        #expect(!coordinator.isDictationActive)
    }

    @Test("Swipe-right stop queues restart until finalization exits")
    @MainActor
    func swipeRightStopQueuesRestartUntilFinalizationExits() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(30),
                stopKeepFinalizeTimeout: .milliseconds(600),
                sendFinalizeTimeout: .milliseconds(600),
                composeUpdateCoalescingInterval: .milliseconds(75)
            )
        )
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: true,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()
        await waitUntil { coordinator.isStickyDictationActive }

        coordinator.stopDictationFromSwipeRight()
        await waitUntil(timeoutMs: 150) {
            !coordinator.isSurfaceOpen && !coordinator.isDictationActive
        }

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: true,
            selectionLength: 0,
            reduceMotionEnabled: false
        )
        coordinator.startStickyDictation()

        #expect(!coordinator.isStickyDictationActive)

        harness.client.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: [],
                    finished: true,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )

        await waitUntil(timeoutMs: 1_500) {
            coordinator.isStickyDictationActive
        }

        #expect(coordinator.isStickyDictationActive)
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

        #expect(harness.client.finalized)
        #expect(harness.client.sentFrames == [Data()])
        #expect(!coordinator.isSurfaceOpen)
    }

    @Test("Editor context changes stay live while dictation remains active")
    @MainActor
    func editorContextChangesDoNotStopDictation() {
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
        #expect(coordinator.isStickyDictationActive)

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: true,
            selectionLength: 4,
            reduceMotionEnabled: false
        )

        #expect(coordinator.isStickyDictationActive)
        #expect(coordinator.isDictationActive)
        #expect(coordinator.isListening)
        #expect(coordinator.isSurfaceOpen)
    }

    @Test("Attempting dictation without a key shows modal prompt and keeps mic visibility rules")
    @MainActor
    func missingKeyRoutesToModalPrompt() {
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

        #expect(coordinator.showsComposeKeyPromptModal)
        #expect(coordinator.micVisible)
        #expect(!coordinator.isDictationActive)
    }

    @Test("Attempting dictation with a non-empty unverified key starts dictation")
    @MainActor
    func unverifiedKeyStillAllowsActivation() async {
        let harness = DictationTestHarness(apiKey: "pending-key", keyStatus: .unverified)
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()

        await waitUntil { harness.client.connected }

        #expect(coordinator.isStickyDictationActive)
        #expect(harness.client.connected)
    }

    @Test("Re-entering unchanged key text preserves validated status and allows dictation")
    @MainActor
    func unchangedInlineKeyKeepsValidatedStatus() {
        let harness = DictationTestHarness(apiKey: "good-key", keyStatus: .validated)
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        #expect(coordinator.inlineKeyStatus == .validated)
        coordinator.updateInlineKeyText("good-key")

        #expect(coordinator.inlineKeyStatus == .validated)
        #expect(harness.keyStore.keyStatus == .validated)

        coordinator.startStickyDictation()
        #expect(coordinator.isStickyDictationActive)
    }

    @Test("Modal key CTA opens Soniox key page when key is empty")
    @MainActor
    func modalGetKeyWhenEmpty() async {
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
        #expect(coordinator.showsComposeKeyPromptModal)
        #expect(coordinator.inlineKeyActionTitle == "Get Key")

        var openedURL: URL?
        await coordinator.handleComposeKeyPrimaryAction { url in
            openedURL = url
        }

        #expect(openedURL == SonioxConfigurationStore.keyManagementURL)
        #expect(coordinator.showsComposeKeyPromptModal)
        #expect(coordinator.inlineKeyStatus == .missing)
        #expect(harness.keyStore.keyStatus == .missing)
    }

    @Test("Dismiss modal key prompt returns to normal compose state")
    @MainActor
    func dismissModalPromptReturnsToIdle() {
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
        #expect(coordinator.showsComposeKeyPromptModal)
        #expect(coordinator.showsComposeKeyPromptModal)

        coordinator.dismissComposeKeyPrompt()

        #expect(!coordinator.isDictationActive)
        #expect(!coordinator.showsComposeKeyPromptModal)
        #expect(coordinator.micVisible)
        #expect(!coordinator.isDictationActive)
    }

    @Test("Audio capture start failure surfaces graceful dictation error")
    @MainActor
    func audioStartFailureShowsError() async {
        let harness = DictationTestHarness()
        harness.audio.startError = DictationAudioCaptureError.outputFormatUnavailable
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()

        await waitUntil { coordinator.errorMessage == "Dictation failed" }

        #expect(coordinator.errorMessage == "Dictation failed")
        #expect(coordinator.isSurfaceOpen)
        #expect(!coordinator.isDictationActive)
        #expect(harness.analytics.stopEvents.contains(where: { $0.reason == "transport_failure" }))
    }

    @Test("Transport failure keeps dictation surface open")
    @MainActor
    func transportFailureKeepsSurfaceOpen() async {
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
        #expect(coordinator.isStickyDictationActive)

        harness.audio.emit(event: .failed(message: "transport failed"))

        await waitUntil { coordinator.errorMessage == "Dictation failed" }

        #expect(coordinator.isSurfaceOpen)
        #expect(coordinator.errorMessage == "Dictation failed")
    }

    @Test("Walkie connect hang times out instead of staying stuck in connecting")
    @MainActor
    func walkieConnectHangTimesOut() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(30),
                stopKeepFinalizeTimeout: .milliseconds(120),
                sendFinalizeTimeout: .milliseconds(80),
                phase2ConnectAttemptTimeout: .milliseconds(90)
            )
        )
        harness.client.connectBehavior = .hangUntilCancelled
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startWalkieTalkieDictation()

        await waitUntil(timeoutMs: 1_500) { coordinator.errorMessage == "Dictation failed" }

        #expect(coordinator.errorMessage == "Dictation failed")
        #expect(!coordinator.isListeningReady)
        #expect(harness.client.connectCallCount >= 2)
    }

    @Test("Walkie activation reaches listening-ready on a healthy connection")
    @MainActor
    func walkieActivationBecomesListeningReady() async {
        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        coordinator.startWalkieTalkieDictation()

        await waitUntil { coordinator.isListeningReady }

        #expect(coordinator.isWalkieTalkieActive)
        #expect(coordinator.isListening)
        #expect(coordinator.isListeningReady)
        #expect(harness.audio.started)
        #expect(harness.client.connected)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("Sticky dictation can start while text is selected")
    @MainActor
    func stickyDictationCanStartWithSelectedText() async {
        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: false,
            textFieldFocused: true,
            selectionLength: 5,
            reduceMotionEnabled: false
        )

        coordinator.startStickyDictation()

        await waitUntil { coordinator.isListeningReady }

        #expect(coordinator.isStickyDictationActive)
        #expect(coordinator.isListening)
        #expect(coordinator.isListeningReady)
        #expect(coordinator.swipeActivationEnabled == false)
    }

    @Test("Audio interruption pauses dictation and keeps surface open")
    @MainActor
    func interruptionBeganPausesSession() async {
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
        #expect(coordinator.isStickyDictationActive)
        await waitUntil { harness.client.connected }

        harness.audio.emit(event: .interruptionBegan)
        await waitUntil(timeoutMs: 1_500) {
            !coordinator.isListening
                && harness.client.finalized
                && !harness.client.closeCalls.isEmpty
        }

        #expect(!coordinator.isListening)
        #expect(coordinator.isDictationActive)
        #expect(coordinator.isSurfaceOpen)
        #expect(harness.client.finalized)
        #expect(!harness.client.closeCalls.isEmpty)
    }

    @Test("App background pauses dictation and keeps the surface open")
    @MainActor
    func appBackgroundPausesAndPreservesSurface() async {
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
        await waitUntil { coordinator.isListeningReady }

        coordinator.handleAppBackgrounded()

        await waitUntil(timeoutMs: 1_500) {
            !coordinator.isListening
                && coordinator.isSurfaceOpen
                && coordinator.isDictationActive
                && harness.client.finalized
                && !harness.client.closeCalls.isEmpty
        }

        #expect(coordinator.isSurfaceOpen)
        #expect(coordinator.isDictationActive)
        #expect(!coordinator.isStickyDictationActive)
        #expect(!coordinator.isWalkieTalkieActive)
        #expect(harness.client.finalized)
        #expect(!harness.client.closeCalls.isEmpty)
    }

    @Test("Finalizing is shielded from the UI projection")
    @MainActor
    func finalizingStateIsHiddenFromProjection() async {
        let harness = DictationTestHarness(
            timing: DictationTiming(
                maxSessionDuration: .seconds(30),
                tokenInactivityTimeout: .seconds(30),
                stopKeepFinalizeTimeout: .milliseconds(120),
                sendFinalizeTimeout: .milliseconds(250)
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
        await waitUntil { harness.client.connected }

        coordinator.handleAppBackgrounded()
        try? await Task.sleep(for: .milliseconds(40))

        let projection = DictationInteractionProjection(session: coordinator)
        #expect(projection.surfaceTarget == .open)
        #expect(projection.isSurfaceOpen)
        #expect(projection.isDictationActive)
        #expect(projection.isStickyDictationActive)
        #expect(projection.isListening)

        await waitUntil(timeoutMs: 1_500) { !coordinator.isListening }
        #expect(coordinator.isSurfaceOpen)
        #expect(coordinator.isDictationActive)
    }

    @Test("Idle sleep is disabled only while dictation is actively running")
    @MainActor
    func idleSleepTracksActiveDictationState() async {
        let previous = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = previous }

        let harness = DictationTestHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.updateContext(
            sessionKey: harness.host.activeSessionKey,
            composeIsEmpty: true,
            textFieldFocused: false,
            selectionLength: 0,
            reduceMotionEnabled: false
        )

        UIApplication.shared.isIdleTimerDisabled = false
        coordinator.startStickyDictation()
        await waitUntil { coordinator.isListeningReady }
        #expect(UIApplication.shared.isIdleTimerDisabled)

        harness.audio.emit(event: .interruptionBegan)
        await waitUntil(timeoutMs: 1_500) {
            !coordinator.isListening && !UIApplication.shared.isIdleTimerDisabled
        }
        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }

    @Test("Audio capture failure event stops dictation and enters error")
    @MainActor
    func audioCaptureFailureStopsSession() async {
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
        #expect(coordinator.isStickyDictationActive)

        harness.audio.emit(event: .failed(message: "route-change recovery failed"))

        await waitUntil { coordinator.errorMessage == "Dictation failed" }

        #expect(coordinator.errorMessage == "Dictation failed")
        #expect(harness.analytics.stopEvents.contains(where: { $0.reason == "transport_failure" }))
    }

    @Test("Protocol error code surfaces in error state when message missing")
    @MainActor
    func protocolErrorCodeSurfacesInErrorMessage() async {
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
        harness.client.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: [],
                    finished: false,
                    errorCode: "input_too_slow",
                    errorMessage: nil
                )
            )
        )

        await waitUntil { coordinator.errorMessage == "input_too_slow" }

        #expect(coordinator.errorMessage == "input_too_slow")
        let sawProtocolError = harness.analytics.errorEvents.contains { event in
            event.errorCode == "input_too_slow" && event.stage == "protocol"
        }
        #expect(sawProtocolError)
    }
}

// MARK: - Test Harness

@MainActor
final class DictationTestHarness {
    let host = MockComposeDraftHost()
    let client = SonioxMockFixtureClient()
    let audio = MockDictationAudioCapture()
    let analytics = MockDictationAnalytics()
    let feedback = MockDictationFeedback()
    let keyVerifier = MockSonioxKeyVerifier()
    let keyStore: SonioxKeyStore
    let timing: DictationTiming
    private(set) var audioFactoryCallCount = 0
    private(set) var clientFactoryCallCount = 0

    init(
        timing: DictationTiming = DictationTiming(
            maxSessionDuration: .seconds(30),
            tokenInactivityTimeout: .seconds(30),
            stopKeepFinalizeTimeout: .milliseconds(120),
            sendFinalizeTimeout: .milliseconds(80)
        ),
        apiKey: String? = "test-key",
        keyStatus: SonioxKeyVerificationStatus = .validated
    ) {
        self.timing = timing
        SonioxConfigurationStore.setAPIKey(apiKey)
        SonioxConfigurationStore.setKeyStatus(keyStatus)
        self.keyStore = SonioxKeyStore(verifier: keyVerifier)
    }

    deinit {
        SonioxConfigurationStore.setAPIKey(nil)
        SonioxConfigurationStore.setKeyStatus(.missing)
    }

    func makeCoordinator() -> DictationCoordinator {
        DictationCoordinator(
            bridge: DictationTranscriptApplicator(host: host),
            keyStore: keyStore,
            languageHintProvider: { "en" },
            audioCaptureFactory: {
                self.audioFactoryCallCount += 1
                return self.audio
            },
            streamingClientFactory: {
                self.clientFactoryCallCount += 1
                return self.client
            },
            analytics: analytics,
            feedback: feedback,
            timing: timing
        )
    }
}

@MainActor
final class MockComposeDraftHost: DictationComposeDraftHosting {
    var activeSessionKey: String = "agent:main:test:main"
    private var drafts: [String: ComposeDraftSnapshot] = ["agent:main:test:main": .empty]

    func captureComposeDraftSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        drafts[sessionKey] ?? .empty
    }

    func applyComposeDraftDelta(
        baseSnapshot: ComposeDraftSnapshot,
        previousTranscriptUTF16Length: Int,
        replacementText: NSAttributedString,
        to sessionKey: String,
        moveCursorToEnd: Bool
    ) {
        let _ = previousTranscriptUTF16Length
        let _ = moveCursorToEnd
        let mutable = NSMutableAttributedString(attributedString: baseSnapshot.content)
        mutable.append(replacementText)
        drafts[sessionKey] = ComposeDraftSnapshot(content: mutable, attachments: baseSnapshot.attachments)
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

final class MockDictationAudioCapture: DictationAudioCapturing {
    private var frameContinuation: AsyncStream<Data>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var eventContinuation: AsyncStream<DictationAudioCaptureEvent>.Continuation?

    private(set) var started = false
    private(set) var stopped = false
    var startError: Error?

    let frameStream: AsyncStream<Data>
    let levelStream: AsyncStream<Float>
    let eventStream: AsyncStream<DictationAudioCaptureEvent>

    init() {
        var frameCont: AsyncStream<Data>.Continuation?
        frameStream = AsyncStream { frameCont = $0 }
        frameContinuation = frameCont

        var levelCont: AsyncStream<Float>.Continuation?
        levelStream = AsyncStream { levelCont = $0 }
        levelContinuation = levelCont

        var eventCont: AsyncStream<DictationAudioCaptureEvent>.Continuation?
        eventStream = AsyncStream { eventCont = $0 }
        eventContinuation = eventCont
    }

    func start() throws {
        if let startError {
            throw startError
        }
        started = true
    }

    func stop() {
        stopped = true
        frameContinuation?.finish()
        levelContinuation?.finish()
        eventContinuation?.finish()
    }

    func emit(level: Float) {
        levelContinuation?.yield(level)
    }

    func emit(event: DictationAudioCaptureEvent) {
        eventContinuation?.yield(event)
    }
}

final class MockSonioxKeyVerifier: SonioxKeyVerifying {
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

final class SonioxMockFixtureClient: SonioxStreamingClienting {
    enum ConnectBehavior {
        case succeed
        case fail(any Error)
        case hangUntilCancelled
    }

    private var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
    let events: AsyncStream<SonioxStreamingEvent>

    private(set) var connected = false
    private(set) var finalized = false
    private(set) var sentFrames: [Data] = []
    private(set) var closeCalls: [(code: Int, reason: String?, caller: String)] = []
    private(set) var connectCallCount = 0
    var connectBehavior: ConnectBehavior = .succeed

    init() {
        var continuation: AsyncStream<SonioxStreamingEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(config: SonioxStreamingConfig) async throws {
        let _ = config
        connectCallCount += 1
        switch connectBehavior {
        case .succeed:
            connected = true
        case .fail(let error):
            throw error
        case .hangUntilCancelled:
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            throw CancellationError()
        }
    }

    func sendAudioFrame(_ frame: Data) async throws {
        sentFrames.append(frame)
    }

    func sendFinalize() async throws {
        finalized = true
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: String?, caller: String) {
        closeCalls.append((Int(code.rawValue), reason, caller))
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
final class MockDictationAnalytics: DictationAnalyticsTracking {
    struct StopEvent {
        let reason: String
        let durationMs: Int
    }

    struct ErrorEvent {
        let errorCode: String?
        let stage: String
    }

    private(set) var stopEvents: [StopEvent] = []
    private(set) var errorEvents: [ErrorEvent] = []
    struct SendWhileActiveEvent {
        let mode: DictationMode?
        let sendSuccess: Bool
    }

    private(set) var sendWhileActiveEvents: [SendWhileActiveEvent] = []

    func trackStart(mode: DictationMode, sessionKey: String) {}

    func trackStop(reason: String, durationMs: Int) {
        stopEvents.append(StopEvent(reason: reason, durationMs: durationMs))
    }

    func trackError(errorCode: String?, stage: String) {
        errorEvents.append(ErrorEvent(errorCode: errorCode, stage: stage))
    }

    func trackSendWhileActive(mode: DictationMode?, sendSuccess: Bool) {
        sendWhileActiveEvents.append(.init(mode: mode, sendSuccess: sendSuccess))
    }

    func trackSocketDrop(mode: DictationMode, elapsedMs: Int) {}
}

enum DictationTestError: Error {
    case connectFailed
}

@MainActor
final class MockDictationFeedback: DictationFeedbackProviding {
    var isVoiceOverRunning: Bool = false
    var isReduceMotionEnabled: Bool = false

    func announce(_ message: String) {}
    func impactLight() {}
    func notifySuccess() {}
    func notifyError() {}
}

@MainActor
func waitUntil(timeoutMs: UInt64 = 1_000, predicate: @escaping @MainActor () -> Bool) async {
    let start = Date()
    while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
        if predicate() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
