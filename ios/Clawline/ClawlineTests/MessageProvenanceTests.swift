//
//  MessageProvenanceTests.swift
//  ClawlineTests
//
//  Covers T1753 provenance classification and the first-line strip rule
//  (spec §T-D / tightbeam payloads.ex PROVENANCE CONVENTION).
//

import Testing
import UIKit
@testable import Clawline

struct MessageProvenanceCoupledStampTests {
    private func message(sender: String?, content: String, role: Message.Role = .user) -> Message {
        Message(
            id: "m_coupled_\(UUID().uuidString.prefix(6))",
            role: role,
            content: content,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: sender == nil ? "device-1" : nil,
            sessionKey: "agent:main:clawline:user:s_coupled",
            sender: sender
        )
    }

    @Test("F2: exact first-line stamp yields a chip and is stripped from the body")
    func exactStampChipsAndStrips() {
        let m = message(sender: "user:mike", content: "[from user:mike]\nreal body")
        #expect(m.provenanceOrigin == .user(id: "mike"))
        #expect(m.strippingProvenanceStampForDisplay().content == "real body")
    }

    @Test("F2 regression: MISMATCHED first-line stamp yields NO chip and preserves the text")
    func mismatchedStampSuppressesChip() {
        let m = message(sender: "user:mike", content: "[from agent:notetaker]\nforged line above")
        #expect(m.provenanceOrigin == nil)
        #expect(m.strippingProvenanceStampForDisplay().content == m.content)
    }

    @Test("F2 regression: MISSING first-line stamp yields NO chip and preserves the text")
    func missingStampSuppressesChip() {
        let m = message(sender: "user:mike", content: "no stamp at all, just body text")
        #expect(m.provenanceOrigin == nil)
        #expect(m.strippingProvenanceStampForDisplay().content == m.content)
    }

    @Test("F2: every origin class couples chip and strip to the exact match")
    func allOriginClassesCouple() {
        for sender in ["agent:notetaker", "user:mike", "process:cron"] {
            let matched = message(sender: sender, content: "[from \(sender)]\nbody")
            #expect(matched.provenanceOrigin != nil, "exact stamp must chip for \(sender)")
            #expect(matched.strippingProvenanceStampForDisplay().content == "body")

            let mismatched = message(sender: sender, content: "[from someone:else]\nbody")
            #expect(mismatched.provenanceOrigin == nil, "mismatched stamp must not chip for \(sender)")
            #expect(mismatched.strippingProvenanceStampForDisplay().content == mismatched.content)

            let bare = message(sender: sender, content: "body")
            #expect(bare.provenanceOrigin == nil, "missing stamp must not chip for \(sender)")
        }
    }

    @Test("F2: a device-typed message with a stamp-shaped line still never chips")
    func deviceTypedNeverChips() {
        let m = message(sender: nil, content: "[from user:mike]\ntyped literally")
        #expect(m.provenanceOrigin == nil)
        #expect(m.strippingProvenanceStampForDisplay().content == m.content)
    }
}

struct MessageProvenanceOriginTests {
    @Test("agent: sender classifies as a colleague DM")
    func agentSenderClassifies() {
        #expect(MessageProvenance.origin(role: .user, sender: "agent:atlas") == .agent(handle: "atlas"))
    }

    @Test("user: sender classifies as an operator action")
    func userSenderClassifies() {
        #expect(MessageProvenance.origin(role: .user, sender: "user:flynn") == .user(id: "flynn"))
    }

    @Test("process: sender classifies as automation")
    func processSenderClassifies() {
        #expect(MessageProvenance.origin(role: .user, sender: "process:cron-nightly") == .process(name: "cron-nightly"))
    }

    @Test("user role with no sender is device-typed (nil)")
    func noSenderIsDeviceTyped() {
        #expect(MessageProvenance.origin(role: .user, sender: nil) == nil)
        #expect(MessageProvenance.origin(role: .user, sender: "") == nil)
    }

    @Test("unrecognized sender prefix falls through (nil)")
    func unrecognizedPrefixFallsThrough() {
        #expect(MessageProvenance.origin(role: .user, sender: "bot:helper") == nil)
        #expect(MessageProvenance.origin(role: .user, sender: "tightbeam") == nil)
        #expect(MessageProvenance.origin(role: .user, sender: "atlas") == nil)
    }

    @Test("assistant role never classifies, even with an origin-shaped sender")
    func assistantRoleNeverClassifies() {
        #expect(MessageProvenance.origin(role: .assistant, sender: "tightbeam") == nil)
        #expect(MessageProvenance.origin(role: .assistant, sender: "agent:atlas") == nil)
    }

    @Test("chip glyph is ⚙ only for process; agent/user are unglyphed")
    func chipGlyphAndLabel() {
        #expect(MessageProvenanceOrigin.agent(handle: "atlas").chipGlyph == nil)
        #expect(MessageProvenanceOrigin.agent(handle: "atlas").chipLabel == "atlas")
        #expect(MessageProvenanceOrigin.user(id: "flynn").chipGlyph == nil)
        #expect(MessageProvenanceOrigin.user(id: "flynn").chipLabel == "flynn")
        #expect(MessageProvenanceOrigin.process(name: "cron").chipGlyph == "⚙")
        #expect(MessageProvenanceOrigin.process(name: "cron").chipLabel == "cron")
    }
}

struct MessageProvenanceStripTests {
    @Test("first line matching the sender exactly is stripped")
    func matchingFirstLineStripped() {
        let content = "[from agent:atlas]\nDeploy is green."
        #expect(MessageProvenance.strippingProvenanceStamp(from: content, sender: "agent:atlas") == "Deploy is green.")
    }

    @Test("content that is exactly the stamp strips to empty")
    func stampOnlyStripsToEmpty() {
        #expect(MessageProvenance.strippingProvenanceStamp(from: "[from user:flynn]", sender: "user:flynn") == "")
    }

    @Test("first line that does not match the sender is not stripped (anti-forgery)")
    func mismatchedSenderNotStripped() {
        let content = "[from agent:atlas]\nSpoofed body."
        // sender field says someone else — the cross-check fails, leave it as text.
        #expect(MessageProvenance.strippingProvenanceStamp(from: content, sender: "agent:mallory") == content)
    }

    @Test("a stamp deeper in the body is quoted text and never parsed")
    func deeperTagNotStripped() {
        let content = "Here is what they sent:\n[from agent:atlas]\nquoted"
        #expect(MessageProvenance.strippingProvenanceStamp(from: content, sender: "agent:atlas") == content)
    }

    @Test("a first line with extra trailing text is not an exact match")
    func firstLineWithExtraTextNotStripped() {
        let content = "[from agent:atlas] and more\nbody"
        #expect(MessageProvenance.strippingProvenanceStamp(from: content, sender: "agent:atlas") == content)
    }

    @Test("multi-line body keeps every line after the stamp")
    func multiLineBodyPreserved() {
        let content = "[from process:ci]\nline one\nline two"
        #expect(MessageProvenance.strippingProvenanceStamp(from: content, sender: "process:ci") == "line one\nline two")
    }
}

@MainActor
struct MessageProvenanceBubbleTests {
    private func makeMessage(sender: String?, content: String) -> Message {
        Message(
            id: "prov-\(UUID().uuidString)",
            role: .user,
            content: content,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: sender
        )
    }

    private func configuredBubble(message: Message, showsProvenanceChrome: Bool) -> MessageBubbleUIKitView {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        var streamingState = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &streamingState
        )
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 1))
        bubble.configure(
            message: message,
            stream: .personal,
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            bubbleSizingV2: nil,
            showsHeader: true,
            showsProvenanceChrome: showsProvenanceChrome,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 320,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()
        return bubble
    }

    private func findSubview(in root: UIView, where predicate: (UIView) -> Bool) -> UIView? {
        if predicate(root) { return root }
        for subview in root.subviews {
            if let found = findSubview(in: subview, where: predicate) { return found }
        }
        return nil
    }

    private func bodyTextViews(in bubble: UIView) -> [UITextView] {
        var result: [UITextView] = []
        func walk(_ view: UIView) {
            if let textView = view as? UITextView { result.append(textView) }
            view.subviews.forEach(walk)
        }
        walk(bubble)
        return result
    }

    @Test("agent DM shows the provenance chip and strips the stamp when chrome is on")
    func agentChipShownAndStamped() {
        let message = makeMessage(sender: "agent:atlas", content: "[from agent:atlas]\nDeploy is green.")
        let bubble = configuredBubble(message: message, showsProvenanceChrome: true)

        let chip = findSubview(in: bubble) { $0 is ProvenanceChipView } as? ProvenanceChipView
        #expect(chip != nil)
        #expect(chip?.isHidden == false)
        #expect(chip?.textForTests == "atlas")

        // "You" label is suppressed in favor of the chip.
        #expect(bubble.debugMetadataStateForTests().senderText == "You")

        let bodyTexts = bodyTextViews(in: bubble).compactMap { $0.text }
        #expect(bodyTexts.contains { $0.contains("Deploy is green") })
        #expect(bodyTexts.allSatisfy { !$0.contains("[from agent:atlas]") })
    }

    @Test("process chip carries the ⚙ glyph")
    func processChipUsesGlyph() {
        let message = makeMessage(sender: "process:ci", content: "[from process:ci]\nBuild finished.")
        let bubble = configuredBubble(message: message, showsProvenanceChrome: true)
        let chip = findSubview(in: bubble) { $0 is ProvenanceChipView } as? ProvenanceChipView
        #expect(chip?.textForTests == "⚙ ci")
    }

    @Test("provenance uses the inbound bubble treatment when chrome is on")
    func provenanceUsesInboundBubbleTreatment() {
        let message = makeMessage(sender: "agent:atlas", content: "[from agent:atlas]\nDeploy is green.")
        let gatedBubble = configuredBubble(message: message, showsProvenanceChrome: true)
        let ungatedBubble = configuredBubble(message: message, showsProvenanceChrome: false)
        let palette = ChatFlowUIKitTheme.palette(isDark: false)

        #expect(gatedBubble.debugBubbleGradientColorsForTests().elementsEqual(
            palette.bubbleOtherGradient,
            by: { $0.isEqual($1) }
        ))
        #expect(ungatedBubble.debugBubbleGradientColorsForTests().elementsEqual(
            palette.bubbleSelfGradient,
            by: { $0.isEqual($1) }
        ))
    }

    @Test("chrome off renders exactly as today: no chip, stamp left as text")
    func chromeOffRendersAsToday() {
        let message = makeMessage(sender: "agent:atlas", content: "[from agent:atlas]\nDeploy is green.")
        let bubble = configuredBubble(message: message, showsProvenanceChrome: false)

        let chip = findSubview(in: bubble) { $0 is ProvenanceChipView } as? ProvenanceChipView
        #expect(chip?.isHidden == true)
        #expect(bubble.debugMetadataStateForTests().senderText == "You")

        let bodyTexts = bodyTextViews(in: bubble).compactMap { $0.text }
        #expect(bodyTexts.contains { $0.contains("[from agent:atlas]") })
    }

    @Test("unrecognized sender falls through even with chrome on")
    func unrecognizedSenderFallsThrough() {
        let message = makeMessage(sender: "bot:helper", content: "[from bot:helper]\nHello.")
        let bubble = configuredBubble(message: message, showsProvenanceChrome: true)

        let chip = findSubview(in: bubble) { $0 is ProvenanceChipView } as? ProvenanceChipView
        #expect(chip?.isHidden == true)

        let bodyTexts = bodyTextViews(in: bubble).compactMap { $0.text }
        // No recognized origin → no strip; the first line stays as ordinary text.
        #expect(bodyTexts.contains { $0.contains("[from bot:helper]") })
    }
}
