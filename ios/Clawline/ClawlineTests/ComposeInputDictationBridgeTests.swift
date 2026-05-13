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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(textView.attributedText.string == "hello mars")
    }

    @Test("Applicator collapses the consumed selection after dictation replacement")
    func applicatorCollapsesConsumedSelectionAfterReplacement() {
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(textView.attributedText.string == "hello mars")
        #expect(textView.selectedRange == NSRange(location: 10, length: 0))
        #expect(textView.consumeExpectedDictationProgrammaticSelectionFeedback(textView.selectedRange))
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(textView.attributedText.string == "hello mars")
        #expect(textView.selectedRange == NSRange(location: 0, length: 5))
        #expect(textView.consumeExpectedDictationProgrammaticSelectionFeedback(textView.selectedRange))
    }

    @Test("Applicator preserves a user substring selection inside transcript replacement")
    func applicatorPreservesSubstringSelectionInsideReplacement() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 8, length: 2)
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(textView.attributedText.string == "hello planet earth")
        #expect(textView.selectedRange == NSRange(location: 8, length: 2))
    }

    @Test("Applicator preserves a user caret inside transcript replacement")
    func applicatorPreservesCaretInsideReplacement() {
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(textView.attributedText.string == "hello mars")
        #expect(textView.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test("Applicator follows transcript end when the user selection was already tracking the end")
    func applicatorFollowsTranscriptEndWhenSelectionAlreadyAtEnd() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "hello world")
        textView.selectedRange = NSRange(location: 11, length: 0)
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(textView.attributedText.string == "hello planet earth")
        #expect(textView.selectedRange == NSRange(location: 18, length: 0))
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(host.currentText(for: host.activeSessionKey) == "seed hello")
    }

    @Test("Applicator preserves host attachments when applying without a UITextView")
    func applicatorPreservesHostAttachmentsWithoutTextView() {
        let host = MockComposeDraftHost()
        let attachment = makePendingAttachment()
        host.setSnapshot(
            ComposeDraftSnapshot(
                content: NSAttributedString(string: "seed "),
                attachments: [attachment.id: attachment]
            ),
            for: host.activeSessionKey
        )
        let applicator = DictationTranscriptApplicator(host: host)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: host.captureComposeDraftSnapshot(for: host.activeSessionKey),
                replacementRange: NSRange(location: 5, length: 0),
                fallbackLocation: 5,
                replacementText: NSAttributedString(string: "hello"),
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(host.currentText(for: host.activeSessionKey) == "seed hello")
        #expect(host.currentAttachments(for: host.activeSessionKey).keys.contains(attachment.id))
    }

    @Test("Applicator fallback preserves machine base attachments")
    func applicatorFallbackPreservesMachineBaseAttachments() {
        let host = MockComposeDraftHost()
        host.setText("", for: host.activeSessionKey)
        let attachment = makePendingAttachment()
        let applicator = DictationTranscriptApplicator(host: host)

        applicator.apply(
            DictationTextApplicationPlan(
                sessionKey: host.activeSessionKey,
                baseSnapshot: ComposeDraftSnapshot(
                    content: NSAttributedString(string: "base "),
                    attachments: [attachment.id: attachment]
                ),
                replacementRange: NSRange(location: NSNotFound, length: 0),
                fallbackLocation: 5,
                replacementText: NSAttributedString(string: "dictated"),
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        #expect(host.currentText(for: host.activeSessionKey) == "base dictated")
        #expect(host.currentAttachments(for: host.activeSessionKey).keys.contains(attachment.id))
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
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
            selectionPolicy: .preserveUserSelection
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

    @Test("Applicator does not replay when SwiftUI reports the same compose surface again")
    func applicatorDoesNotReplaySameComposeSurfaceUpdate() {
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
            selectionPolicy: .preserveUserSelection
        )
        applicator.setReplayPlanProvider { replayPlan }

        let textView = PastableTextView()
        textView.attributedText = NSAttributedString(string: "seed ")
        applicator.setComposeTextView(textView)
        #expect(textView.attributedText.string == "seed hello")

        textView.selectedRange = NSRange(location: 2, length: 3)
        applicator.setComposeTextView(textView)

        #expect(textView.attributedText.string == "seed hello")
        #expect(textView.selectedRange == NSRange(location: 2, length: 3))
    }

    @Test("Applicator carries visible user selection across compose surface rebind")
    func applicatorCarriesSelectionAcrossComposeSurfaceRebind() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let replayPlan = DictationTextApplicationPlan(
            sessionKey: host.activeSessionKey,
            baseSnapshot: ComposeDraftSnapshot(
                content: NSAttributedString(string: "seed "),
                attachments: [:]
            ),
            replacementRange: NSRange(location: 5, length: 5),
            fallbackLocation: 5,
            replacementText: NSAttributedString(string: "hello"),
            selectionPolicy: .preserveUserSelection
        )
        applicator.setReplayPlanProvider { replayPlan }

        let firstTextView = PastableTextView()
        firstTextView.attributedText = NSAttributedString(string: "seed hello")
        firstTextView.selectedRange = NSRange(location: 2, length: 3)
        applicator.setComposeTextView(firstTextView)

        let reboundTextView = PastableTextView()
        reboundTextView.attributedText = NSAttributedString(string: "seed hello")
        applicator.setComposeTextView(reboundTextView)

        #expect(reboundTextView.attributedText.string == "seed hello")
        #expect(reboundTextView.selectedRange == NSRange(location: 2, length: 3))
    }

    @Test("Applicator carries selection after replaying transcript into a shorter rebound surface")
    func applicatorCarriesSelectionAfterReplayOnShorterReboundSurface() {
        let host = MockComposeDraftHost()
        let applicator = DictationTranscriptApplicator(host: host)
        let replayPlan = DictationTextApplicationPlan(
            sessionKey: host.activeSessionKey,
            baseSnapshot: ComposeDraftSnapshot(
                content: NSAttributedString(string: "seed "),
                attachments: [:]
            ),
            replacementRange: NSRange(location: 5, length: 5),
            fallbackLocation: 5,
            replacementText: NSAttributedString(string: "hello"),
            selectionPolicy: .preserveUserSelection
        )
        applicator.setReplayPlanProvider { replayPlan }

        let firstTextView = PastableTextView()
        firstTextView.attributedText = NSAttributedString(string: "seed hello")
        firstTextView.selectedRange = NSRange(location: 10, length: 0)
        applicator.setComposeTextView(firstTextView)

        let reboundTextView = PastableTextView()
        reboundTextView.attributedText = NSAttributedString(string: "seed ")
        applicator.setComposeTextView(reboundTextView)

        #expect(reboundTextView.attributedText.string == "seed hello")
        #expect(reboundTextView.selectedRange == NSRange(location: 10, length: 0))
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
                selectionPolicy: .followTranscriptEndWhenSelectionAlreadyAtEnd
            )
        )

        // Flag is cleared after apply completes
        #expect(textView.dictationProgrammaticEditInFlight == false)
        #expect(textView.attributedText.string == "hello mars")
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
