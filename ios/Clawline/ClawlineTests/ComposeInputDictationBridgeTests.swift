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

    @Test("Applicator keeps programmatic-update suppression alive through the async callback grace window")
    func applicatorKeepsProgrammaticUpdateSuppressionThroughGraceWindow() async {
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

        #expect(textView.dictationProgrammaticUpdateInFlight == true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(textView.dictationProgrammaticUpdateInFlight == true)
        try? await Task.sleep(for: .milliseconds(140))
        #expect(textView.dictationProgrammaticUpdateInFlight == false)
    }
}
