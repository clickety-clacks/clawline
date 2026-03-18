import Foundation
import Testing
import UIKit
@testable import Clawline

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
        rig.coordinator.setComposeSelectionRange(rig.textView.selectedRange)
        syncContext(rig)

        rig.coordinator.startStickyDictation()
        emitCommitted(["spoken"], into: rig)

        await waitUntil { rig.textView.attributedText.string == "alpha spoken omega" }
        #expect(rig.textView.attributedText.string == "alpha spoken omega")
    }

    @Test("Caret changes during active dictation do not re-anchor transcript-owned updates")
    func movingCursorDuringDictationDoesNotAppendFullTranscript() async {
        let rig = makeRig(initialText: "", selectedRange: NSRange(location: 0, length: 0))

        startDictation(rig)
        emitProvisional("There", into: rig)
        await waitUntil { rig.textView.attributedText.string == "There" }

        rig.textView.selectedRange = NSRange(location: rig.textView.attributedText.length, length: 0)
        rig.coordinator.setComposeSelectionRange(rig.textView.selectedRange)
        syncContext(rig)

        emitProvisional("There's also", into: rig)
        await waitUntil { rig.textView.attributedText.string == "There's also" }
        #expect(rig.textView.attributedText.string == "There's also")
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

        rig.textView.beginDictationProgrammaticUpdate()
        rig.coordinator.noteComposeUserEditDuringDictation(
            editedRangeUTF16: NSRange(location: "seed hello worl".utf16.count, length: 0),
            replacementUTF16Length: 1
        )
        rig.textView.endDictationProgrammaticUpdate()

        emitProvisional("hello world from soniox", into: rig)
        await waitUntil { rig.textView.attributedText.string == "seed hello world from soniox" }
        #expect(rig.textView.attributedText.string == "seed hello world from soniox")
    }

    private func makeRig(initialText: String, selectedRange: NSRange) -> CoordinatorTranscriptRig {
        let harness = DictationTestHarness()
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
        rig.coordinator.setComposeSelectionRange(rig.textView.selectedRange)
        syncContext(rig)
        rig.coordinator.startStickyDictation()
    }

    private func emitProvisional(_ text: String, into rig: CoordinatorTranscriptRig) {
        rig.harness.client.emit(
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
        rig.harness.client.emit(
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
