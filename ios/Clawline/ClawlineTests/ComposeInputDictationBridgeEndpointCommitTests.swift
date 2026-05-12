import Foundation
import Testing
import UIKit
@testable import Clawline

@Suite(.serialized)
@MainActor
struct DictationCoordinatorTranscriptOwnershipTests {
    @Test("Dictation replaces the current selection instead of appending")
    func dictationReplacesCurrentSelection() async {
        let rig = makeRig(initialText: "hello world", selectedRange: NSRange(location: 6, length: 5))

        startDictation(rig)
        emitProvisional("mars", into: rig)

        await waitUntil { rig.textView.attributedText.string == "hello mars" }
        #expect(rig.textView.attributedText.string == "hello mars")
        #expect(rig.textView.selectedRange == NSRange(location: 6, length: 4))
    }

    @Test("Long dictation keeps finalized prefix when Soniox interim window advances")
    func longDictationKeepsFinalizedPrefixWhenInterimWindowAdvances() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitTokens([
            SonioxTranscriptToken(text: "The first half ", isFinal: true),
            SonioxTranscriptToken(text: "of the paragraph", isFinal: false)
        ], into: rig)
        await waitUntil {
            rig.textView.attributedText.string == "The first half of the paragraph"
        }

        emitTokens([
            SonioxTranscriptToken(text: "continues with the second half", isFinal: false)
        ], into: rig)

        await waitUntil {
            rig.textView.attributedText.string == "The first half continues with the second half"
        }
        #expect(rig.textView.attributedText.string == "The first half continues with the second half")
    }

    @Test("Long dictation merges newly final advanced-window prefix")
    func longDictationMergesNewlyFinalAdvancedWindowPrefix() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitTokens([
            SonioxTranscriptToken(text: "The first half ", isFinal: true),
            SonioxTranscriptToken(text: "of the paragraph", isFinal: false)
        ], into: rig)
        await waitUntil {
            rig.textView.attributedText.string == "The first half of the paragraph"
        }

        emitTokens([
            SonioxTranscriptToken(text: "of the paragraph ", isFinal: true),
            SonioxTranscriptToken(text: "continues with the second half", isFinal: false)
        ], into: rig)

        await waitUntil {
            rig.textView.attributedText.string == "The first half of the paragraph continues with the second half"
        }
        #expect(rig.textView.attributedText.string == "The first half of the paragraph continues with the second half")
    }

    @Test("Activation capture wins over later ambient selection changes before dictation starts")
    func activationCapturePreservesCaretBeforeStart() async {
        let initial = "alpha BETA omega"
        let capturedRange = NSRange(location: 6, length: 4)
        let rig = makeRig(initialText: initial, selectedRange: capturedRange)

        rig.coordinator.captureComposeSelectionRangeForActivation(capturedRange)
        rig.textView.selectedRange = NSRange(location: initial.utf16.count, length: 0)
        syncContext(rig)

        rig.coordinator.startStickyDictation()
        emitCommitted(["spoken"], into: rig)

        await waitUntil { rig.textView.attributedText.string == "alpha spoken omega" }
        #expect(rig.textView.attributedText.string == "alpha spoken omega")
    }

    @Test("Moving the cursor during active dictation makes the next dictated text insert at the moved caret")
    func movingCursorDuringDictationReanchorsNextInsertion() async {
        let rig = makeRig(initialText: "hello world", selectedRange: NSRange(location: "hello world".utf16.count, length: 0))

        startDictation(rig)
        emitCommitted([" tail"], into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello world tail" }

        moveSelection(in: rig, to: NSRange(location: "hello ".utf16.count, length: 0))

        emitProvisional("new ", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello new world tail" }
        #expect(rig.textView.attributedText.string == "hello new world tail")
    }

    @Test("Moving the cursor inside active cumulative provisional dictation inserts only the new suffix at the moved caret")
    func movingCursorInsideCumulativeProvisionalDictationInsertsOnlyNewSuffix() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitProvisional("abcdef", into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcdef" }

        moveSelection(in: rig, to: NSRange(location: 3, length: 0))

        emitProvisional("abcdefXYZ", into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcXYZdef" }

        #expect(rig.textView.attributedText.string == "abcXYZdef")
        #expect(rig.textView.selectedRange == NSRange(location: 6, length: 0))
    }

    @Test("Repeated cursor movement keeps cumulative transcript prefix ownership")
    func repeatedCursorMovementKeepsCumulativeTranscriptPrefixOwnership() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitProvisional("abcdef", into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcdef" }

        moveSelection(in: rig, to: NSRange(location: 3, length: 0))
        emitProvisional("abcdefXYZ", into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcXYZdef" }

        moveSelection(in: rig, to: NSRange(location: 4, length: 0))
        emitProvisional("abcdefXYZ123", into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcX123YZdef" }

        #expect(rig.textView.attributedText.string == "abcX123YZdef")
    }

    @Test("Cursor movement after finalized prefix inserts only new advanced-window text")
    func cursorMovementAfterFinalizedPrefixInsertsOnlyNewAdvancedWindowText() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitTokens([
            SonioxTranscriptToken(text: "abcdef", isFinal: true),
            SonioxTranscriptToken(text: "ghi", isFinal: false)
        ], into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcdefghi" }

        moveSelection(in: rig, to: NSRange(location: 3, length: 0))
        emitTokens([
            SonioxTranscriptToken(text: "XYZ", isFinal: false)
        ], into: rig)

        await waitUntil { rig.textView.attributedText.string == "abcXYZdefghi" }
        #expect(rig.textView.attributedText.string == "abcXYZdefghi")
    }

    @Test("Substring selection during active dictation is replaced by the next dictated suffix")
    func substringSelectionDuringActiveDictationIsReplacedByNextDictatedSuffix() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitProvisional("abcdef", into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcdef" }

        moveSelection(in: rig, to: NSRange(location: 3, length: 3))

        emitProvisional("abcdefXYZ", into: rig)
        await waitUntil { rig.textView.attributedText.string == "abcXYZ" }

        #expect(rig.textView.attributedText.string == "abcXYZ")
    }

    @Test("Paused dictation does not replay over user cursor movement")
    func movingCursorDuringPausedDictationSurvivesComposeSurfaceUpdate() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitProvisional("hello world", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello world" }

        rig.coordinator.pauseFromWaveformTap()
        await waitUntil { rig.coordinator.isDictationActive && !rig.coordinator.isListening }

        rig.textView.selectedRange = NSRange(location: 5, length: 0)
        syncContext(rig)
        rig.coordinator.setComposeTextView(rig.textView)

        #expect(rig.textView.attributedText.string == "hello world")
        #expect(rig.textView.selectedRange == NSRange(location: 5, length: 0))
    }

    @Test("Paused dictation resume inserts new text at the moved caret")
    func pausedResumeInsertsAtMovedCaret() async {
        let rig = makeRig(
            initialText: "hello world",
            selectedRange: NSRange(location: "hello world".utf16.count, length: 0),
            freshClientPerFactoryCall: true
        )

        startDictation(rig)
        emitCommitted([" tail"], into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello world tail" }

        rig.coordinator.pauseFromWaveformTap()
        await waitUntil { rig.coordinator.isDictationActive && !rig.coordinator.isListening }
        moveSelection(in: rig, to: NSRange(location: "hello ".utf16.count, length: 0))

        rig.coordinator.startStickyDictation()
        await waitUntil { rig.harness.clientFactoryCallCount >= 2 && rig.harness.latestClient.connected }
        emitProvisional("new ", into: rig)

        await waitUntil { rig.textView.attributedText.string == "hello new world tail" }
        #expect(rig.textView.attributedText.string == "hello new world tail")
    }

    @Test("Paused resume applies new stream text even when it prefixes the prior dictation")
    func pausedResumeAppliesNewTextThatPrefixesPriorDictation() async {
        let rig = makeRig(
            initialText: "",
            selectedRange: NSRange(location: 0, length: 0),
            freshClientPerFactoryCall: true
        )

        startDictation(rig)
        emitProvisional("hello world", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello world" }

        rig.coordinator.pauseFromWaveformTap()
        await waitUntil { rig.coordinator.isDictationActive && !rig.coordinator.isListening }

        rig.coordinator.startStickyDictation()
        await waitUntil { rig.harness.clientFactoryCallCount >= 2 && rig.harness.latestClient.connected }
        emitProvisional("hello", into: rig)

        await waitUntil { rig.textView.attributedText.string == "hello worldhello" }
        #expect(rig.textView.attributedText.string == "hello worldhello")
    }

    @Test("Paused resume does not truncate a new paragraph sharing the prior dictation prefix")
    func pausedResumeDoesNotTruncateNewParagraphSharingPriorPrefix() async {
        let rig = makeRig(
            initialText: "",
            selectedRange: NSRange(location: 0, length: 0),
            freshClientPerFactoryCall: true
        )

        startDictation(rig)
        emitProvisional("hello world", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello world" }

        rig.coordinator.pauseFromWaveformTap()
        await waitUntil { rig.coordinator.isDictationActive && !rig.coordinator.isListening }

        rig.coordinator.startStickyDictation()
        await waitUntil { rig.harness.clientFactoryCallCount >= 2 && rig.harness.latestClient.connected }
        emitProvisional("hello world again with more detail", into: rig)

        await waitUntil {
            rig.textView.attributedText.string == "hello worldhello world again with more detail"
        }
        #expect(rig.textView.attributedText.string == "hello worldhello world again with more detail")
    }

    @Test("Paused resume does not replay late old-stream text into the new stream")
    func pausedResumeDoesNotReplayLateOldStreamUpdateIntoNewStream() async {
        let rig = makeRig(
            initialText: "",
            selectedRange: NSRange(location: 0, length: 0),
            freshClientPerFactoryCall: true
        )

        startDictation(rig)
        emitProvisional("hello world", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello world" }

        rig.coordinator.pauseFromWaveformTap()
        await waitUntil { rig.coordinator.isDictationActive && !rig.coordinator.isListening }
        emitProvisional("hello world again", into: rig)

        rig.coordinator.startStickyDictation()
        await waitUntil { rig.harness.clientFactoryCallCount >= 2 && rig.harness.latestClient.connected }
        emitProvisional("hello", into: rig)

        await waitUntil { rig.textView.attributedText.string == "hello worldhello" }
        #expect(rig.textView.attributedText.string == "hello worldhello")
    }

    @Test("Paused resume ignores late responses from the old stream after the new stream is active")
    func pausedResumeIgnoresLateOldStreamAfterNewStreamIsActive() async {
        let rig = makeRig(
            initialText: "",
            selectedRange: NSRange(location: 0, length: 0),
            freshClientPerFactoryCall: true
        )

        startDictation(rig)
        emitProvisional("hello world", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello world" }

        let oldClient = rig.harness.latestClient
        rig.coordinator.pauseFromWaveformTap()
        await waitUntil { rig.coordinator.isDictationActive && !rig.coordinator.isListening }

        rig.coordinator.startStickyDictation()
        await waitUntil { rig.harness.clientFactoryCallCount >= 2 && rig.harness.latestClient.connected }
        emitProvisional("new text", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello worldnew text" }

        oldClient.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: [SonioxTranscriptToken(text: " old stream", isFinal: false)],
                    finished: false,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )
        try? await Task.sleep(for: .milliseconds(60))

        #expect(rig.textView.attributedText.string == "hello worldnew text")
    }

    @Test("User edit in provisional range suppresses Soniox provisional updates until endpoint")
    func userEditInProvisionalRangeSuppressesUntilEndpoint() async {
        let rig = makeRig(initialText: "seed ", selectedRange: NSRange(location: 5, length: 0))

        startDictation(rig)
        emitProvisional("hello worl", into: rig)
        await waitUntil { rig.textView.attributedText.string == "seed hello worl" }

        simulateUserEdit(
            in: rig,
            range: NSRange(location: "seed hello worl".utf16.count, length: 0),
            replacement: "d!"
        )
        #expect(rig.textView.attributedText.string == "seed hello world!")

        emitProvisional("hello world from soniox", into: rig)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.textView.attributedText.string == "seed hello world!")

        emitCommitted(["hello world from soniox"], into: rig)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.textView.attributedText.string == "seed hello world!")

        emitProvisional(" plus", into: rig)
        await waitUntil { rig.textView.attributedText.string == "seed hello world! plus" }
        #expect(rig.textView.attributedText.string == "seed hello world! plus")
    }

    @Test("Edit before dictation anchor shifts ownership range")
    func editBeforeDictationAnchorShiftsOwnershipRange() async {
        let rig = makeRig(initialText: "AAA BBB CCC", selectedRange: NSRange(location: 4, length: 3))

        startDictation(rig)
        emitProvisional("dict", into: rig)
        await waitUntil { rig.textView.attributedText.string == "AAA dict CCC" }

        simulateUserEdit(in: rig, range: NSRange(location: 0, length: 0), replacement: "X")
        #expect(rig.textView.attributedText.string == "XAAA dict CCC")

        emitProvisional("dict!", into: rig)
        await waitUntil { rig.textView.attributedText.string == "XAAA dict! CCC" }
        #expect(rig.textView.attributedText.string == "XAAA dict! CCC")
    }

    @Test("Reported behavior 1: dictation inserts text into compose field")
    func reportedBehaviorTextInsertedAfterDictation() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitProvisional("hello", into: rig)

        await waitUntil { rig.textView.attributedText.string == "hello" }
        #expect(rig.textView.attributedText.string == "hello")
    }

    @Test("Reported behavior 2: swipe-up dictation does not duplicate inserted text")
    func reportedBehaviorNoDuplicateInsertionOnSwipeUp() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitProvisional("hello", into: rig)
        await waitUntil { rig.textView.attributedText.string == "hello" }

        emitProvisional("hello", into: rig)
        emitCommitted(["hello"], into: rig)

        await waitUntil { rig.textView.attributedText.string == "hello" }
        #expect(rig.textView.attributedText.string == "hello")
    }

    @Test("Programmatic dictation updates do not feed back as user-edit suppression")
    func programmaticDictationUpdatesDoNotFeedBackAsUserEditSuppression() async {
        let rig = makeRig(initialText: "seed ", selectedRange: NSRange(location: 5, length: 0))

        startDictation(rig)
        emitProvisional("hello worl", into: rig)
        await waitUntil { rig.textView.attributedText.string == "seed hello worl" }

        rig.textView.dictationProgrammaticEditInFlight = true
        rig.coordinator.noteComposeUserEditDuringDictation(
            editedRangeUTF16: NSRange(location: "seed hello worl".utf16.count, length: 0),
            replacementUTF16Length: 1
        )
        rig.textView.dictationProgrammaticEditInFlight = false

        emitProvisional("hello world from soniox", into: rig)
        await waitUntil { rig.textView.attributedText.string == "seed hello world from soniox" }
        #expect(rig.textView.attributedText.string == "seed hello world from soniox")
    }

    @Test("Active dictation transcript application preserves compose attachments")
    func activeDictationPreservesComposeAttachments() async {
        let attachment = makePendingAttachment()
        let rig = makeRig(
            initialText: "seed ",
            selectedRange: NSRange(location: 5, length: 0),
            attachments: [attachment.id: attachment]
        )

        startDictation(rig)
        emitProvisional("hello", into: rig)

        await waitUntil { rig.textView.attributedText.string == "seed hello" }
        #expect(rig.textView.attributedText.string == "seed hello")
        #expect(rig.harness.host.currentAttachments(for: rig.harness.host.activeSessionKey).keys.contains(attachment.id))
    }

    @Test("Coordinator-owned fallback restores base snapshot when live transcript range diverges")
    func coordinatorFallbackRestoresBaseSnapshotWhenLiveTranscriptRangeDiverges() async {
        let attachment = makePendingAttachment()
        let rig = makeRig(
            initialText: "seed ",
            selectedRange: NSRange(location: 5, length: 0),
            attachments: [attachment.id: attachment]
        )

        startDictation(rig)
        emitProvisional("hello", into: rig)
        await waitUntil { rig.textView.attributedText.string == "seed hello" }

        rig.textView.attributedText = NSAttributedString(string: "corrupt")
        rig.textView.selectedRange = NSRange(location: "corrupt".utf16.count, length: 0)
        emitProvisional("hello world", into: rig)

        await waitUntil { rig.textView.attributedText.string == "seed hello world" }
        #expect(rig.textView.attributedText.string == "seed hello world")
        #expect(rig.harness.host.currentAttachments(for: rig.harness.host.activeSessionKey).keys.contains(attachment.id))
    }

    @Test("Coordinator-owned fallback replaces selected base range when live transcript range diverges")
    func coordinatorFallbackReplacesSelectedBaseRangeWhenLiveTranscriptRangeDiverges() async {
        let attachment = makePendingAttachment()
        let rig = makeRig(
            initialText: "alpha TARGET omega",
            selectedRange: NSRange(location: "alpha ".utf16.count, length: "TARGET".utf16.count),
            attachments: [attachment.id: attachment]
        )

        startDictation(rig)
        emitProvisional("dictated", into: rig)
        await waitUntil { rig.textView.attributedText.string == "alpha dictated omega" }

        rig.textView.attributedText = NSAttributedString(string: "corrupt")
        rig.textView.selectedRange = NSRange(location: "corrupt".utf16.count, length: 0)
        emitProvisional("dictated text", into: rig)

        await waitUntil { rig.textView.attributedText.string == "alpha dictated text omega" }
        #expect(rig.textView.attributedText.string == "alpha dictated text omega")
        #expect(rig.harness.host.currentAttachments(for: rig.harness.host.activeSessionKey).keys.contains(attachment.id))
    }

    @Test("Active dictation replay on compose rebind preserves attachments")
    func activeDictationReplayOnComposeRebindPreservesAttachments() async {
        let attachment = makePendingAttachment()
        let rig = makeRig(
            initialText: "seed ",
            selectedRange: NSRange(location: 5, length: 0),
            attachments: [attachment.id: attachment]
        )

        startDictation(rig)
        emitProvisional("hello", into: rig)
        await waitUntil { rig.textView.attributedText.string == "seed hello" }

        let reboundTextView = PastableTextView()
        reboundTextView.attributedText = NSAttributedString(string: "seed ")
        reboundTextView.selectedRange = NSRange(location: 5, length: 0)
        rig.coordinator.setComposeTextView(reboundTextView)

        await waitUntil { reboundTextView.attributedText.string == "seed hello" }
        #expect(reboundTextView.attributedText.string == "seed hello")
        #expect(rig.harness.host.currentAttachments(for: rig.harness.host.activeSessionKey).keys.contains(attachment.id))
    }

    private func makeRig(
        initialText: String,
        selectedRange: NSRange,
        attachments: [UUID: PendingAttachment] = [:],
        freshClientPerFactoryCall: Bool = false
    ) -> CoordinatorTranscriptRig {
        let harness = DictationTestHarness(freshClientPerFactoryCall: freshClientPerFactoryCall)
        harness.host.setSnapshot(
            ComposeDraftSnapshot(
                content: NSAttributedString(string: initialText),
                attachments: attachments
            ),
            for: harness.host.activeSessionKey
        )

        let coordinator = harness.makeCoordinator()
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: initialText)
        textView.selectedRange = selectedRange
        coordinator.setComposeTextView(textView)

        let rig = CoordinatorTranscriptRig(
            harness: harness,
            coordinator: coordinator,
            textView: textView
        )
        syncContext(rig)
        return rig
    }

    private func syncContext(_ rig: CoordinatorTranscriptRig) {
        rig.coordinator.updateContext(
            sessionKey: rig.harness.host.activeSessionKey,
            composeIsEmpty: rig.textView.attributedText.length == 0,
            textFieldFocused: true,
            selectionLength: rig.textView.selectedRange.length,
            reduceMotionEnabled: false
        )
    }

    private func startDictation(_ rig: CoordinatorTranscriptRig) {
        rig.coordinator.captureComposeSelectionRangeForActivation(rig.textView.selectedRange)
        syncContext(rig)
        rig.coordinator.startStickyDictation()
    }

    private func moveSelection(in rig: CoordinatorTranscriptRig, to selectedRange: NSRange) {
        rig.textView.selectedRange = selectedRange
        rig.coordinator.noteComposeSelectionChanged(selectedRange)
        syncContext(rig)
    }

    private func emitProvisional(_ text: String, into rig: CoordinatorTranscriptRig) {
        emitTokens([SonioxTranscriptToken(text: text, isFinal: false)], into: rig)
    }

    private func emitTokens(_ tokens: [SonioxTranscriptToken], into rig: CoordinatorTranscriptRig) {
        rig.harness.latestClient.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: tokens,
                    finished: false,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )
    }

    private func emitCommitted(_ segments: [String], into rig: CoordinatorTranscriptRig) {
        var tokens: [SonioxTranscriptToken] = []
        for segment in segments where !segment.isEmpty {
            tokens.append(SonioxTranscriptToken(text: segment, isFinal: true))
            tokens.append(SonioxTranscriptToken(text: "<end>", isFinal: true))
        }
        rig.harness.latestClient.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: tokens,
                    finished: false,
                    errorCode: nil,
                    errorMessage: nil
                )
            )
        )
    }

    private func simulateUserEdit(
        in rig: CoordinatorTranscriptRig,
        range: NSRange,
        replacement: String
    ) {
        let mutable = NSMutableAttributedString(attributedString: rig.textView.attributedText)
        mutable.replaceCharacters(in: range, with: replacement)
        rig.textView.attributedText = mutable
        rig.textView.selectedRange = NSRange(location: range.location + replacement.utf16.count, length: 0)
        rig.coordinator.noteComposeUserEditDuringDictation(
            editedRangeUTF16: range,
            replacementUTF16Length: replacement.utf16.count
        )
        syncContext(rig)
    }

    private func makePendingAttachment() -> PendingAttachment {
        PendingAttachment(
            id: UUID(),
            data: Data([0x01]),
            thumbnail: UIImage(),
            mimeType: "image/png",
            filename: "image.png"
        )
    }
}

@MainActor
private struct CoordinatorTranscriptRig {
    let harness: DictationTestHarness
    let coordinator: DictationCoordinator
    let textView: PastableTextView
}
