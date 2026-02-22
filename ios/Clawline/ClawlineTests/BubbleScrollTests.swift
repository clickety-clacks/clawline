//
//  BubbleScrollTests.swift
//  ClawlineTests
//
//  Regression coverage for inner bubble scrolling when truncated content includes embedded previews.
//

import Testing
import UIKit
@testable import Clawline

struct BubbleScrollTests {

    @Test("Bug #62: Truncated bubbles enable inner scroll when link preview pushes content past cap")
    @MainActor
    func bubbleEnablesInnerScrollForEmbeddedPreview() {
        let url = "https://example.com/some/path"
        let content = """
        This is a message with enough text to be near the truncation cap but not exceed it by itself.

        It has multiple paragraphs so it lays out like a real message, and then a URL.

        \(url)
        """

        let message = Message(
            id: "bubbleScroll62",
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )

        let metrics = ChatFlowTheme.Metrics(isCompact: false) // larger cap to avoid false positives from text-only truncation

        let presentationNoPreview = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let presentationWithPreview = buildPresentation(message, metrics: metrics, enableLinkPreviews: true)

        let scrollEnabledNoPreview = isInnerBubbleScrollEnabled(
            message: message,
            presentation: presentationNoPreview,
            metrics: metrics,
            maxWidth: 360
        )
        let scrollEnabledWithPreview = isInnerBubbleScrollEnabled(
            message: message,
            presentation: presentationWithPreview,
            metrics: metrics,
            maxWidth: 360
        )

        #expect(scrollEnabledNoPreview == false)
        #expect(scrollEnabledWithPreview == true)
    }

    @Test("T047/T046: Overflow-to-fit transition clears stale inner offset and fade state")
    @MainActor
    func overflowTransitionResetsOffsetAndFade() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let longMessage = Message(
            id: "overflow-long",
            role: .assistant,
            content: Array(repeating: "This sentence is intentionally long for truncation coverage.", count: 36).joined(separator: " "),
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let shortMessage = Message(
            id: "overflow-short",
            role: .assistant,
            content: "Short follow-up.",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )

        let longPresentation = buildPresentation(longMessage, metrics: metrics, enableLinkPreviews: false)
        let shortPresentation = buildPresentation(shortMessage, metrics: metrics, enableLinkPreviews: false)
        let longSizeClass = MessageFlowRules.sizeClass(for: longPresentation)
        let shortSizeClass = MessageFlowRules.sizeClass(for: shortPresentation)

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        host.layoutIfNeeded()
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 260))
        host.addSubview(bubble)

        bubble.configure(
            message: longMessage,
            presentation: longPresentation,
            sizeClass: longSizeClass,
            metrics: metrics,
            maxWidth: 320,
            truncationHeightOverride: 140,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        bubble.layoutIfNeeded()

        guard let scroll = innerBubbleScrollView(in: bubble),
              let fade = truncationFadeView(in: bubble) else {
            Issue.record("Expected inner scroll + fade views to exist")
            return
        }
        #expect(scroll.isScrollEnabled)
        #expect(fade.isHidden == false)

        // Simulate a stale/bouncy offset that can leak across reuse/reconfigure.
        scroll.contentOffset = CGPoint(x: 0, y: -18)

        bubble.configure(
            message: shortMessage,
            presentation: shortPresentation,
            sizeClass: shortSizeClass,
            metrics: metrics,
            maxWidth: 320,
            truncationHeightOverride: 240,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        bubble.layoutIfNeeded()

        #expect(scroll.isScrollEnabled == false)
        #expect(fade.isHidden)
        #expect(abs(scroll.contentOffset.y) < 0.5)
    }

    @Test("T048: Single-link previews keep fixed full-height viewport using the available-height cap")
    @MainActor
    func linkPreviewCapsHoldOnLargeContainerInputs() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let link = "https://example.com/status"
        let message = Message(
            id: "link-preview-cap",
            role: .assistant,
            content: "Status page:\n\(link)",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: true)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        host.layoutIfNeeded()
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 1200, height: 300))
        host.addSubview(bubble)

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: 1200,
            truncationHeightOverride: 900,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 1200, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let referenceWidthCap = 744 - (metrics.containerPadding * 2)
        let widthConstraintPresent = allConstraints(in: bubble).contains { constraint in
            constraint.isActive &&
            constraint.firstAttribute == .width &&
            constraint.relation == .equal &&
            abs(constraint.constant - referenceWidthCap) <= 1
        }
        #expect(widthConstraintPresent)

        guard let preview = linkPreviewView(in: bubble) else {
            Issue.record("Expected LinkPreviewView in bubble content")
            return
        }
        let expectedPreviewMaxHeight = 900 - (metrics.bubblePaddingVertical * 2)
        let previewMeasured = preview.sizeThatFits(
            CGSize(width: referenceWidthCap, height: .greatestFiniteMagnitude)
        )
        #expect(abs(previewMeasured.height - expectedPreviewMaxHeight) <= 1)
    }

    @Test("T060: Single-link cap uses live bottom inset (not truncation reserve)")
    func singleLinkCapUsesLiveViewportInsets() {
        let cap = BubbleSizingV2.availableHeightCap(
            containerHeight: 1366,
            topInset: 24,
            bottomInset: 120,
            flowPadding: 12
        )
        #expect(abs(cap - 1198) <= 0.5)
    }

    @Test("T060: Single-link cap tracks full container height for large iPad/vision viewports")
    func singleLinkCapUsesFullContainerHeight() {
        let cap = BubbleSizingV2.availableHeightCap(
            containerHeight: 1600,
            topInset: 20,
            bottomInset: 160,
            flowPadding: 12
        )
        #expect(abs(cap - 1396) <= 0.5)
    }

    @Test("T032: Salient highlight style-only updates avoid layout reflow callbacks")
    @MainActor
    func salientHighlightAvoidsLayoutReflowWhenHeightStable() async throws {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "salient-style-only",
            role: .user,
            content: "Topic phrase stays one line and should not reflow",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let renderedText = message.content
        let highlights = SalientHighlights(
            messageId: message.id,
            renderedTextHash: SalientHighlightService.sha256Hex(renderedText),
            renderedTextLengthUTF16: (renderedText as NSString).length,
            algorithmVersion: 2,
            spans: [
                SalientSpan(startUTF16: 0, lengthUTF16: 5, style: .bold, kind: .fact, confidence: 0.9)
            ]
        )
        let service = ImmediateHighlightService(storedHighlights: highlights)

        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        var layoutRequests = 0
        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: MessageFlowRules.sizeClass(for: presentation),
            metrics: metrics,
            maxWidth: 320,
            truncationHeightOverride: 220,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: { _ in layoutRequests += 1 },
            onInteractiveCallback: nil,
            salientHighlightService: service
        )
        bubble.layoutIfNeeded()

        try await Task.sleep(for: .milliseconds(80))
        #expect(layoutRequests == 0)
    }

    @Test("T089: Bubble tap-to-expand is suppressed when link cards are present")
    @MainActor
    func bubbleTapSuppressedWhenLinkCardsPresent() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let url = "https://example.com/very/long/link"
        let repeated = Array(
            repeating: "This sentence exists to force truncation in the message bubble.",
            count: 24
        ).joined(separator: " ")
        let message = Message(
            id: "link-card-tap-suppress",
            role: .assistant,
            content: "\(repeated)\n\n\(url)",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )

        let presentationWithPreview = buildPresentation(message, metrics: metrics, enableLinkPreviews: true)
        let presentationWithoutPreview = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)

        let expandsWithoutPreview = expandCallbackCount(
            message: message,
            presentation: presentationWithoutPreview,
            metrics: metrics
        )
        let expandsWithPreview = expandCallbackCount(
            message: message,
            presentation: presentationWithPreview,
            metrics: metrics
        )

        #expect(expandsWithoutPreview == 1)
        #expect(expandsWithPreview == 0)
    }

    @Test("T057: Bubble uses per-block text containers without re-merging rich text")
    @MainActor
    func bubbleUsesPerBlockTextContainers() {
        let content = """
        # Title

        Intro paragraph.

        - Item one
        - Item two

        > Quoted line

        Tail paragraph.
        """

        let message = Message(
            id: "bubble-block-separation",
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 900))
        host.layoutIfNeeded()
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 360, height: 1))
        host.addSubview(bubble)

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: 360,
            truncationHeightOverride: 1000,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        bubble.layoutIfNeeded()

        let textRuns = textViews(in: bubble)
            .compactMap { $0.attributedText?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        #expect(textRuns.count >= 2)
        #expect(textRuns.contains(where: { $0.contains("Title") }))
        #expect(textRuns.contains(where: { $0.contains("Tail paragraph.") }))
        #expect(!textRuns.contains(where: { $0.contains("Title") && $0.contains("Tail paragraph.") }))
    }

    // MARK: Helpers

    @MainActor
    private func isInnerBubbleScrollEnabled(message: Message,
                                           presentation: MessagePresentation,
                                           metrics: ChatFlowTheme.Metrics,
                                           maxWidth: CGFloat) -> Bool {
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)

        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: maxWidth, height: 1))
        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth,
            truncationHeightOverride: 240,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.setNeedsLayout()
        bubble.layoutIfNeeded()

        // Identify the bubble's inner scroll view: it is vertical-only and has directional lock enabled.
        let scrolls = allScrollViews(in: bubble)
        guard let inner = scrolls.first(where: { $0.isDirectionalLockEnabled && !$0.showsHorizontalScrollIndicator }) else {
            Issue.record("Expected inner bubble UIScrollView not found")
            return false
        }
        return inner.isScrollEnabled
    }

    @MainActor
    private func expandCallbackCount(message: Message,
                                     presentation: MessagePresentation,
                                     metrics: ChatFlowTheme.Metrics) -> Int {
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 360, height: 1))
        var count = 0

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: 360,
            truncationHeightOverride: 140,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: { count += 1 },
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        _ = bubble.perform(NSSelectorFromString("handleBubbleTap"))
        return count
    }

    private func allScrollViews(in view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        if let scroll = view as? UIScrollView {
            result.append(scroll)
        }
        for sub in view.subviews {
            result.append(contentsOf: allScrollViews(in: sub))
        }
        return result
    }

    private func innerBubbleScrollView(in view: UIView) -> UIScrollView? {
        allScrollViews(in: view).first(where: { $0.isDirectionalLockEnabled && !$0.showsHorizontalScrollIndicator })
    }

    private func truncationFadeView(in view: UIView) -> TruncationFadeView? {
        if let fade = view as? TruncationFadeView {
            return fade
        }
        for sub in view.subviews {
            if let found = truncationFadeView(in: sub) {
                return found
            }
        }
        return nil
    }

    private func linkPreviewView(in view: UIView) -> LinkPreviewView? {
        if let preview = view as? LinkPreviewView {
            return preview
        }
        for sub in view.subviews {
            if let found = linkPreviewView(in: sub) {
                return found
            }
        }
        return nil
    }

    private func allConstraints(in view: UIView) -> [NSLayoutConstraint] {
        var result = view.constraints
        for sub in view.subviews {
            result.append(contentsOf: allConstraints(in: sub))
        }
        return result
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        if let textView = view as? UITextView {
            result.append(textView)
        }
        for sub in view.subviews {
            result.append(contentsOf: textViews(in: sub))
        }
        return result
    }

    private struct ImmediateHighlightService: SalientHighlightServicing {
        let storedHighlights: SalientHighlights
        func cachedHighlights(messageId: String, renderedText: String) -> SalientHighlights? { nil }
        func highlights(messageId: String, renderedText: String) async -> SalientHighlights? { storedHighlights }
    }

    private func buildPresentation(_ message: Message,
                                   metrics: ChatFlowTheme.Metrics,
                                   enableLinkPreviews: Bool) -> MessagePresentation {
        var state = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &state
        )
        guard !enableLinkPreviews else { return presentation }

        let filtered = presentation.parts.filter { part in
            if case .linkPreview = part { return false }
            return true
        }
        return MessagePresentation(
            parts: filtered,
            markdownRenderPlan: presentation.markdownRenderPlan,
            wordCount: presentation.wordCount,
            hasTextualContent: presentation.hasTextualContent,
            isEmojiOnly: presentation.isEmojiOnly,
            hasMediaOnly: presentation.hasMediaOnly,
            detectedURLs: presentation.detectedURLs,
            detectedURLCount: presentation.detectedURLCount,
            hasSingleURL: presentation.hasSingleURL
        )
    }
}
