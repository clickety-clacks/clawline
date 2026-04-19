import Testing
import UIKit
@testable import Clawline

@MainActor
struct DictationTranscriptApplicatorTests {
    @Test("Applicator replaces the selected range in a bound text view")
    func applicatorReplacesSelectedRangeInTextView() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 6, length: 5)
        applicator.setComposeTextView(textView)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: ComposeDraftSnapshot(
                    content: NSAttributedString(string: "hello world"),
                    attachments: [:]
                ),
                replacementRange: NSRange(location: 6, length: 5),
                fallbackLocation: 11,
                replacementText: NSAttributedString(string: "mars"),
                moveCursorToEnd: true
            )
        )

        #expect(textView.attributedText.string == "hello mars")
    }

    @Test("Applicator preserves user selection outside the transcript-owned replacement range")
    func applicatorPreservesSelectionOutsideReplacementRange() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 0, length: 5)
        applicator.setComposeTextView(textView)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: ComposeDraftSnapshot(
                    content: NSAttributedString(string: "hello world"),
                    attachments: [:]
                ),
                replacementRange: NSRange(location: 6, length: 5),
                fallbackLocation: 11,
                replacementText: NSAttributedString(string: "mars"),
                moveCursorToEnd: true
            )
        )

        #expect(textView.attributedText.string == "hello mars")
        #expect(textView.selectedRange == NSRange(location: 0, length: 5))
        #expect(textView.consumeExpectedDictationProgrammaticSelectionFeedback(textView.selectedRange))
    }

    @Test("Applicator transforms a user selection through transcript replacement")
    func applicatorTransformsSelectionAcrossReplacement() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 6, length: 5)
        applicator.setComposeTextView(textView)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: ComposeDraftSnapshot(
                    content: NSAttributedString(string: "hello world"),
                    attachments: [:]
                ),
                replacementRange: NSRange(location: 6, length: 5),
                fallbackLocation: 11,
                replacementText: NSAttributedString(string: "planet earth"),
                moveCursorToEnd: true
            )
        )

        #expect(textView.attributedText.string == "hello planet earth")
        #expect(textView.selectedRange == NSRange(location: 6, length: 12))
    }

    @Test("Applicator collapses a caret inside the replacement range to the transcript end")
    func applicatorMovesCaretInsideReplacementToTranscriptEnd() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 8, length: 0)
        applicator.setComposeTextView(textView)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: ComposeDraftSnapshot(
                    content: NSAttributedString(string: "hello world"),
                    attachments: [:]
                ),
                replacementRange: NSRange(location: 6, length: 5),
                fallbackLocation: 11,
                replacementText: NSAttributedString(string: "mars"),
                moveCursorToEnd: true
            )
        )

        #expect(textView.attributedText.string == "hello mars")
        #expect(textView.selectedRange == NSRange(location: 10, length: 0))
    }

    @Test("Applicator updates the host snapshot when no UITextView is attached")
    func applicatorUpdatesHostSnapshotWithoutTextView() {
        let host = MockComposeDraftHost()
        host.setText("seed ", for: host.activeSessionKey)
        let applicator = DictationTranscriptApplicator(host: host)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: host.captureComposeDraftSnapshot(for: host.activeSessionKey),
                replacementRange: NSRange(location: 5, length: 0),
                fallbackLocation: 5,
                replacementText: NSAttributedString(string: "hello"),
                moveCursorToEnd: true
            )
        )

        #expect(host.currentText(for: host.activeSessionKey) == "seed hello")
    }

    @Test("Applicator restore writes the provided snapshot back to the host")
    func applicatorRestoreWritesSnapshotToHost() {
        let host = MockComposeDraftHost()
        host.setText("stale", for: host.activeSessionKey)
        let applicator = DictationTranscriptApplicator(host: host)
        let snapshot = ComposeDraftSnapshot(
            content: NSAttributedString(string: "restored"),
            attachments: [:]
        )

        applicator.restore(snapshot: snapshot, to: host.activeSessionKey)

        #expect(host.currentText(for: host.activeSessionKey) == "restored")
    }

    @Test("Applicator ignores plans for inactive session keys")
    func applicatorSkipsInactiveSessionKey() {
        let host = MockComposeDraftHost()
        host.setText("seed ", for: host.activeSessionKey)
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "seed ")
        textView.selectedRange = NSRange(location: 5, length: 0)
        applicator.setComposeTextView(textView)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: "agent:main:test:other",
                baseSnapshot: host.captureComposeDraftSnapshot(for: host.activeSessionKey),
                replacementRange: NSRange(location: 5, length: 0),
                fallbackLocation: 5,
                replacementText: NSAttributedString(string: "hello"),
                moveCursorToEnd: true
            )
        )

        #expect(textView.attributedText.string == "seed ")
        #expect(host.currentText(for: host.activeSessionKey) == "seed ")
    }

    @Test("Applicator replays the current machine-authored plan when a compose surface rebinds")
    func applicatorReplaysCurrentPlanOnComposeSurfaceRebind() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let replayPlan = DictationTextApplicationPlan(
            sessionKey: host.activeSessionKey,
            baseSnapshot: ComposeDraftSnapshot(
                content: NSAttributedString(string: "seed "),
                attachments: [:]
            ),
            replacementRange: NSRange(location: 5, length: 0),
            fallbackLocation: 5,
            replacementText: NSAttributedString(string: "hello"),
            moveCursorToEnd: true
        )
        applicator.setReplayPlanProvider { replayPlan }

        let firstTextView = PastableTextView()
        firstTextView.attributedText = NSAttributedString(string: "seed ")
        applicator.setComposeTextView(firstTextView)
        #expect(firstTextView.attributedText.string == "seed hello")

        let reboundTextView = PastableTextView()
        reboundTextView.attributedText = NSAttributedString(string: "seed ")
        applicator.setComposeTextView(reboundTextView)
        #expect(reboundTextView.attributedText.string == "seed hello")
    }

    @Test("Applicator does not replay when the machine reports no active replay plan")
    func applicatorSkipsReplayWhenMachineHasNoActivePlan() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        applicator.setReplayPlanProvider { nil }

        let reboundTextView = PastableTextView()
        reboundTextView.attributedText = NSAttributedString(string: "seed ")
        applicator.setComposeTextView(reboundTextView)

        #expect(reboundTextView.attributedText.string == "seed ")
    }

    @Test("Programmatic edit flag is set during dictation text replacement")
    func programmaticEditFlagSetDuringReplace() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 6, length: 5)
        applicator.setComposeTextView(textView)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: ComposeDraftSnapshot(
                    content: NSAttributedString(string: "hello world"),
                    attachments: [:]
                ),
                replacementRange: NSRange(location: 6, length: 5),
                fallbackLocation: 11,
                replacementText: NSAttributedString(string: "mars"),
                moveCursorToEnd: true
            )
        )

        // Flag is cleared after apply completes
        #expect(textView.dictationProgrammaticEditInFlight == false)
        #expect(textView.attributedText.string == "hello mars")
    }
}
