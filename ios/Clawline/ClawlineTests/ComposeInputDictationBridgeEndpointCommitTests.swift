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

    private func makeRig(
        initialText: String,
        selectedRange: NSRange,
        freshClientPerFactoryCall: Bool = false
    ) -> CoordinatorTranscriptRig {
        let harness = DictationTestHarness(freshClientPerFactoryCall: freshClientPerFactoryCall)
        harness.host.setText(initialText, for: harness.host.activeSessionKey)

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
        rig.harness.latestClient.emit(
            .response(
                SonioxStreamingResponse(
                    tokens: [SonioxTranscriptToken(text: text, isFinal: false)],
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
}

@MainActor
private struct CoordinatorTranscriptRig {
    let harness: DictationTestHarness
    let coordinator: DictationCoordinator
    let textView: PastableTextView
}
