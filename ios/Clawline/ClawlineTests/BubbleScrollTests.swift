//
//  BubbleScrollTests.swift
//  ClawlineTests
//
//  Regression coverage for inner bubble scrolling when truncated content includes embedded previews.
//

import Testing
import UIKit
import WebKit
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

    @Test("Measurement bubble disables data detectors while visible bubbles keep link detectors")
    @MainActor
    func measurementBubbleDisablesDataDetectors() {
        let visibleBubble = MessageBubbleUIKitView()
        let measurementBubble = MessageBubbleUIKitView(enableDataDetectors: false)
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "measurement-detectors",
            role: .assistant,
            content: "Visit https://example.com",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)

        for bubble in [visibleBubble, measurementBubble] {
            bubble.configure(
                message: message,
                presentation: presentation,
                sizeClass: sizeClass,
                metrics: metrics,
                maxWidth: 320,
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
        }

        let visibleDetectors = textViews(in: visibleBubble).map(\.dataDetectorTypes)
        let measurementDetectors = textViews(in: measurementBubble).map(\.dataDetectorTypes)

        #expect(visibleDetectors.contains([.link]))
        #expect(measurementDetectors.allSatisfy { $0.isEmpty })
    }

    @Test("BubbleSizingV2 short bubbles honor the plan min width instead of the legacy 120pt floor")
    @MainActor
    func bubbleSizingV2ShortBubbleUsesPlanMinWidthConstraint() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "bubble-v2-min-width",
            role: .assistant,
            content: "Short",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let env = BubbleSizingV2.Environment(
            containerWidth: 320,
            containerHeight: 640,
            singleLinkContainerHeight: 640,
            topInset: 0,
            bottomInset: 0,
            truncationBottomInset: 0,
            isVisionOS: false,
            metricsFingerprint: BubbleSizingV2.metricsFingerprint(metrics: metrics, traitCollection: UITraitCollection())
        )
        let heightPolicy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: env,
            isSingleLinkPreview: false,
            prefersScreenAwareHeightCap: false,
            allowsOuterScroll: false
        )
        let planMaxWidth: CGFloat = 200
        let planMinWidth: CGFloat = 40
        let plan = BubbleSizingV2.Plan(
            messageId: message.id,
            presentationFingerprint: 1,
            sizeClass: sizeClass,
            isSingleLinkPreview: false,
            isWide: false,
            maxWidth: planMaxWidth,
            minWidth: planMinWidth,
            heightPolicy: heightPolicy,
            allowsOuterScroll: false,
            linkPreviewURL: nil
        )
        let layoutState = BubbleSizingV2.LayoutState(
            plan: plan,
            measurement: BubbleSizingV2.Measurement(
                measuredCellSize: CGSize(width: planMaxWidth, height: 72),
                measuredBubbleWidth: planMaxWidth,
                contentHeight: 24,
                chromeHeight: 48,
                outerScrollEnabled: false,
                outerScrollViewportHeight: heightPolicy.heightCap,
                isFinal: true
            ),
            linkPreviewCacheKey: nil,
            linkPreviewEstimatedHeight: nil,
            linkPreviewMinHeight: 40,
            linkPreviewMaxHeight: heightPolicy.heightCap
        )

        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: planMaxWidth, height: 1))
        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: planMaxWidth,
            bubbleHeightPolicy: heightPolicy,
            bubbleSizingV2: layoutState,
            showsHeader: false,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )

        let preferred = bubble.preferredWidth(maxWidth: planMaxWidth, minWidth: planMinWidth)
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: preferred, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        #expect(preferred >= planMinWidth)
        #expect(preferred < 120)
        #expect(abs(measured.width - preferred) < 0.5)
    }

    @Test("T1377: BubbleSizingV2 measurement key ignores raw viewport motion when resolved cap is unchanged")
    @MainActor
    func bubbleSizingV2MeasurementKeyIgnoresEquivalentViewportMotion() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let metricsFingerprint = BubbleSizingV2.metricsFingerprint(metrics: metrics, traitCollection: UITraitCollection())
        let baseEnv = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 236,
            truncationBottomInset: 236,
            isVisionOS: false,
            metricsFingerprint: metricsFingerprint
        )
        let shiftedEnv = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 720,
            singleLinkContainerHeight: 720,
            topInset: 20,
            bottomInset: 196,
            truncationBottomInset: 196,
            isVisionOS: false,
            metricsFingerprint: metricsFingerprint
        )
        let basePolicy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: baseEnv,
            isSingleLinkPreview: false,
            prefersScreenAwareHeightCap: true,
            allowsOuterScroll: true
        )
        let shiftedPolicy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: shiftedEnv,
            isSingleLinkPreview: false,
            prefersScreenAwareHeightCap: true,
            allowsOuterScroll: true
        )

        let first = basePolicy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: baseEnv,
            linkPreviewStateVersion: 0
        )
        let second = shiftedPolicy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: shiftedEnv,
            linkPreviewStateVersion: 0
        )

        #expect(basePolicy.heightCap == shiftedPolicy.heightCap)
        #expect(first == second)
    }

    @Test("T1377: BubbleSizingV2 measurement key changes when resolved height cap changes")
    @MainActor
    func bubbleSizingV2MeasurementKeyTracksResolvedHeightCap() {
        let env = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: false,
            metricsFingerprint: 11
        )
        let firstPolicy = BubbleSizingV2.BubbleHeightPolicy(
            isSingleLinkPreview: false,
            heightCapMode: .screenAware,
            heightCap: 480,
            v1TruncationHeightOverride: 480,
            linkPreviewViewportMaxHeight: 432,
            cacheFingerprint: BubbleSizingV2.heightPolicyFingerprint(
                isSingleLinkPreview: false,
                heightCapMode: .screenAware,
                heightCap: 480,
                v1TruncationHeightOverride: 480,
                linkPreviewViewportMaxHeight: 432
            )
        )
        let secondPolicy = BubbleSizingV2.BubbleHeightPolicy(
            isSingleLinkPreview: false,
            heightCapMode: .screenAware,
            heightCap: 520,
            v1TruncationHeightOverride: 520,
            linkPreviewViewportMaxHeight: 472,
            cacheFingerprint: BubbleSizingV2.heightPolicyFingerprint(
                isSingleLinkPreview: false,
                heightCapMode: .screenAware,
                heightCap: 520,
                v1TruncationHeightOverride: 520,
                linkPreviewViewportMaxHeight: 472
            )
        )

        let first = firstPolicy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: env,
            linkPreviewStateVersion: 0
        )
        let second = secondPolicy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: env,
            linkPreviewStateVersion: 0
        )

        #expect(first != second)
    }

    @Test("T1377: BubbleSizingV2 measurement key keeps width platform and metrics identity")
    @MainActor
    func bubbleSizingV2MeasurementKeyKeepsMeasurementIdentityFields() {
        let policy = BubbleSizingV2.BubbleHeightPolicy(
            isSingleLinkPreview: false,
            heightCapMode: .designSystem,
            heightCap: 2_000,
            v1TruncationHeightOverride: nil,
            linkPreviewViewportMaxHeight: 1_952,
            cacheFingerprint: BubbleSizingV2.heightPolicyFingerprint(
                isSingleLinkPreview: false,
                heightCapMode: .designSystem,
                heightCap: 2_000,
                v1TruncationHeightOverride: nil,
                linkPreviewViewportMaxHeight: 1_952
            )
        )
        let baseEnv = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: false,
            metricsFingerprint: 11
        )
        let widerEnv = BubbleSizingV2.Environment(
            containerWidth: 430,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: false,
            metricsFingerprint: 11
        )
        let visionEnv = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: true,
            metricsFingerprint: 11
        )
        let dynamicTypeEnv = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: false,
            metricsFingerprint: 12
        )

        let base = policy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: baseEnv,
            linkPreviewStateVersion: 0
        )

        #expect(base != policy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: widerEnv,
            linkPreviewStateVersion: 0
        ))
        #expect(base != policy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: visionEnv,
            linkPreviewStateVersion: 0
        ))
        #expect(base != policy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: dynamicTypeEnv,
            linkPreviewStateVersion: 0
        ))
    }

    @Test("T1377: resolved height policy fingerprint invalidates measurements when cap changes")
    @MainActor
    func resolvedHeightPolicyFingerprintInvalidatesMeasurementKeyWhenCapChanges() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let baseEnv = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: false,
            metricsFingerprint: BubbleSizingV2.metricsFingerprint(metrics: metrics, traitCollection: UITraitCollection())
        )
        let compactEnv = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 720,
            singleLinkContainerHeight: 720,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: false,
            metricsFingerprint: baseEnv.metricsFingerprint
        )
        let basePolicy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: baseEnv,
            isSingleLinkPreview: false,
            prefersScreenAwareHeightCap: true,
            allowsOuterScroll: true
        )
        let compactPolicy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: compactEnv,
            isSingleLinkPreview: false,
            prefersScreenAwareHeightCap: true,
            allowsOuterScroll: true
        )

        let base = basePolicy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: baseEnv,
            linkPreviewStateVersion: 0
        )
        let compact = compactPolicy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: compactEnv,
            linkPreviewStateVersion: 0
        )

        #expect(basePolicy.heightCap != compactPolicy.heightCap)
        #expect(base != compact)
    }

    @Test("T1377: BubbleSizingV2 measurement key tracks link preview state version")
    @MainActor
    func bubbleSizingV2MeasurementKeyTracksLinkPreviewStateVersion() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let env = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 760,
            singleLinkContainerHeight: 760,
            topInset: 20,
            bottomInset: 120,
            truncationBottomInset: 120,
            isVisionOS: false,
            metricsFingerprint: BubbleSizingV2.metricsFingerprint(metrics: metrics, traitCollection: UITraitCollection())
        )
        let policy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: env,
            isSingleLinkPreview: true,
            prefersScreenAwareHeightCap: true,
            allowsOuterScroll: false
        )

        let initial = policy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: env,
            linkPreviewStateVersion: 0
        )
        let loadedPreview = policy.measurementCacheKey(
            sessionKey: "s",
            messageId: "m",
            presentationFingerprint: 1,
            layoutFingerprintSeed: 2,
            env: env,
            linkPreviewStateVersion: 1
        )

        #expect(initial != loadedPreview)
    }

    @Test("T1193/T149: Same message id in a different session resets stale inner bubble offset")
    @MainActor
    func sessionAwareReuseResetsOffsetForSameMessageId() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let firstMessage = Message(
            id: "shared-id",
            role: .assistant,
            content: Array(repeating: "This sentence is intentionally long for truncation coverage.", count: 36).joined(separator: " "),
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:flynn:main"
        )
        let secondMessage = Message(
            id: "shared-id",
            role: .assistant,
            content: "Short follow-up in a different session.",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:flynn:s_other"
        )

        let firstPresentation = buildPresentation(firstMessage, metrics: metrics, enableLinkPreviews: false)
        let secondPresentation = buildPresentation(secondMessage, metrics: metrics, enableLinkPreviews: false)
        let firstSizeClass = MessageFlowRules.sizeClass(for: firstPresentation)
        let secondSizeClass = MessageFlowRules.sizeClass(for: secondPresentation)

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        host.layoutIfNeeded()
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 260))
        host.addSubview(bubble)

        bubble.configure(
            message: firstMessage,
            presentation: firstPresentation,
            sizeClass: firstSizeClass,
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

        guard let scroll = innerBubbleScrollView(in: bubble) else {
            Issue.record("Expected inner bubble UIScrollView not found")
            return
        }
        scroll.contentOffset = CGPoint(x: 0, y: 48)

        bubble.configure(
            message: secondMessage,
            presentation: secondPresentation,
            sizeClass: secondSizeClass,
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

        #expect(abs(scroll.contentOffset.y) < 0.5)
    }

    @Test("T1193: Production text bubble metrics stay compact")
    func productionTextBubbleMetricsStayCompact() {
        let compact = ChatFlowTheme.Metrics(isCompact: true)
        let regular = ChatFlowTheme.Metrics(isCompact: false)

        #expect(compact.bubblePaddingVertical == 8)
        #expect(compact.bubblePaddingTop == 8)
        #expect(compact.bubblePaddingBottom == 6)
        #expect(compact.bubblePaddingHorizontal == 10)
        #expect(regular.bubblePaddingVertical == 10)
        #expect(regular.bubblePaddingTop == 10)
        #expect(regular.bubblePaddingBottom == 6)
        #expect(regular.bubblePaddingHorizontal == 14)
    }

    @Test("T1193: Production markdown body block spacing stays compact")
    @MainActor
    func productionMarkdownBodyBlockSpacingStaysCompact() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "t1193-markdown-body-spacing",
            role: .assistant,
            content: """
            First paragraph in a realistic transcript bubble.

            Second paragraph should not create a loose body gap.

            ```swift
            let value = "code block"
            ```
            """,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:flynn:s_111df227"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 360, height: 1))

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: MessageFlowRules.sizeClass(for: presentation),
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

        guard let bodyStack = markdownBodyStack(in: bubble, arrangedSubviewCountAtLeast: 2) else {
            Issue.record("Expected production markdown body stack with multiple rendered blocks")
            return
        }

        #expect(bodyStack.spacing == 6)
    }

    @Test("T1193: Rendered text bubble bottom chrome is tighter than top chrome")
    @MainActor
    func renderedTextBubbleBottomChromeIsTighterThanTopChrome() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "t1193-rendered-bottom-chrome",
            role: .assistant,
            content: "A compact production bubble should not carry a heavy blank pad below the final line.",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:flynn:s_111df227"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 360, height: 1))

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: MessageFlowRules.sizeClass(for: presentation),
            metrics: metrics,
            maxWidth: 360,
            truncationHeightOverride: 1000,
            bubbleSizingV2: nil,
            showsHeader: false,
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
            CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        guard let textView = textViews(in: bubble).first(where: {
            !$0.attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            Issue.record("Expected rendered text view inside production bubble")
            return
        }
        let textFrame = renderedGlyphFrame(for: textView, in: bubble)
        let topChrome = textFrame.minY
        let bottomChrome = bubble.bounds.maxY - textFrame.maxY

        #expect(topChrome >= metrics.bubblePaddingTop)
        #expect(bottomChrome >= metrics.bubblePaddingBottom)
        #expect(bottomChrome <= metrics.bubblePaddingBottom + 4)
        #expect(bottomChrome < topChrome)
    }

    @Test("T1390: short user BubbleSizingV2 bubble ignores oversized viewport height")
    @MainActor
    func shortUserBubbleSizingV2SizesToContentHeight() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "t1390-short-user",
            role: .user,
            content: "OK",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:flynn:s_111df227"
        )
        let measured = measuredUserBubble(
            message: message,
            metrics: metrics,
            injectedViewportHeight: 260
        )

        #expect(measured.height < 80)
    }

    @Test("T1390: multi-line user BubbleSizingV2 bubble still grows to text")
    @MainActor
    func multilineUserBubbleSizingV2SizesToContentHeight() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "t1390-multiline-user",
            role: .user,
            content: "First line for Ansible.\nSecond line stays visible.\nThird line keeps natural height.",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:flynn:s_111df227"
        )
        let measured = measuredUserBubble(
            message: message,
            metrics: metrics,
            injectedViewportHeight: 260
        )

        #expect(measured.height > 80)
        #expect(measured.height < 150)
    }

    @Test("BubbleSizingV2 live short-bubble remeasure keeps plan min width below legacy floor")
    func bubbleSizingV2LiveRemeasureUsesPlanMinWidth() {
        let abovePlanMin = MessageFlowCollectionViewController.enforcedLiveMeasuredWidth(
            sizeClass: .short,
            measuredWidth: 52,
            maxWidth: 88,
            minWidth: 40
        )
        let belowPlanMin = MessageFlowCollectionViewController.enforcedLiveMeasuredWidth(
            sizeClass: .short,
            measuredWidth: 20,
            maxWidth: 88,
            minWidth: 40
        )
        let mediumWidth = MessageFlowCollectionViewController.enforcedLiveMeasuredWidth(
            sizeClass: .medium,
            measuredWidth: 52,
            maxWidth: 88,
            minWidth: 40
        )

        #expect(abovePlanMin == 52)
        #expect(belowPlanMin == 40)
        #expect(mediumWidth == 88)
    }

    @Test("T330: UIKit fitting target can override fixed bubble width")
    @MainActor
    func fittingTargetCanOverrideFixedBubbleWidth() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "t330-fixed-width",
            role: .assistant,
            content: "This message is measured at the wide bubble width before UIKit asks the cell for a narrow fitting target.",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let cell = MessageBubbleUIKitCell(frame: CGRect(x: 0, y: 0, width: 396, height: 120))
        cell.contentView.frame = cell.bounds
        cell.configure(
            message: message,
            presentation: presentation,
            sendIndicatorState: nil,
            isCompact: false,
            maxWidth: 396,
            showsHeader: false,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            onResend: nil
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        let fixedWidthConstraints = allConstraints(in: cell).filter {
            $0.identifier == "MessageBubbleUIKitView.fixedWidth" && abs($0.constant - 396) < 0.5
        }
        let measured = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 120, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        #expect(!fixedWidthConstraints.isEmpty)
        #expect(fixedWidthConstraints.allSatisfy { $0.priority < .required })
        #expect(measured.width <= 120.5)
    }

    @Test("T340: real chat bubble renders hyphen markdown bullets")
    @MainActor
    func t340HyphenMarkdownBulletsRenderInMessageBubbleUIKitView() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let message = Message(
            id: "t340-bubble-render",
            role: .assistant,
            content: """
            Intro with **bold** and [link](https://example.com).
            - Alpha `code`
            - Beta
            """,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 360, height: 1))

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
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.setNeedsLayout()
        bubble.layoutIfNeeded()

        let attributedRuns = textViews(in: bubble)
            .compactMap(\.attributedText)
            .filter { !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let combinedText = attributedRuns.map(\.string).joined(separator: "\n")

        guard let bulletRun = attributedRuns.first(where: { $0.string.contains("Alpha") && $0.string.contains("Beta") }) else {
            Issue.record("Expected rendered chat bubble text view for T340 content")
            return
        }
        guard let introRun = attributedRuns.first(where: { $0.string.contains("Intro with bold and link.") }) else {
            Issue.record("Expected rendered chat bubble prose text view for T340 content")
            return
        }

        #expect(combinedText.contains("Intro with bold and link."))
        #expect(combinedText.contains("• Alpha code"))
        #expect(combinedText.contains("• Beta"))
        #expect(!combinedText.contains("- Alpha"))
        #expect(isBold("bold", in: introRun))
        #expect(linkTarget("link", in: introRun)?.absoluteString == "https://example.com")
        #expect(bulletRun.string.contains("• Alpha code"))
        #expect(bulletRun.string.contains("• Beta"))
    }

    @Test("T233: Popup viewer keeps smaller images at 1:1 scale")
    func imagePopupInitialScaleKeepsSmallImagesAtActualSize() {
        let scale = ImagePopupViewerLayout.initialZoomScale(
            imageSize: CGSize(width: 320, height: 200),
            viewportSize: CGSize(width: 700, height: 500)
        )

        #expect(scale == 1)
    }

    @Test("T233: Popup viewer fits oversized images inside viewport")
    func imagePopupInitialScaleFitsOversizedImages() {
        let scale = ImagePopupViewerLayout.initialZoomScale(
            imageSize: CGSize(width: 1200, height: 900),
            viewportSize: CGSize(width: 600, height: 500)
        )

        #expect(scale == 0.5)
    }

    @Test("T233: Popup viewer uses fit-scaled content size for oversized images")
    func imagePopupUsesFitScaledContentSizeForOversizedImages() {
        let imageSize = CGSize(width: 1200, height: 900)
        let viewportSize = CGSize(width: 600, height: 500)
        let scale = ImagePopupViewerLayout.initialZoomScale(
            imageSize: imageSize,
            viewportSize: viewportSize
        )
        let contentSize = ImagePopupViewerLayout.zoomedContentSize(
            imageSize: imageSize,
            zoomScale: scale
        )

        #expect(contentSize.width == 600)
        #expect(contentSize.height == 450)
        #expect(contentSize.width <= viewportSize.width)
        #expect(contentSize.height <= viewportSize.height)
    }

    @Test("T233: Popup viewer uses natural content size for smaller images")
    func imagePopupUsesNaturalContentSizeForSmallerImages() {
        let imageSize = CGSize(width: 320, height: 200)
        let scale = ImagePopupViewerLayout.initialZoomScale(
            imageSize: imageSize,
            viewportSize: CGSize(width: 700, height: 500)
        )
        let contentSize = ImagePopupViewerLayout.zoomedContentSize(
            imageSize: imageSize,
            zoomScale: scale
        )

        #expect(scale == 1)
        #expect(contentSize == imageSize)
    }

    @Test("T233: Popup viewer centers content that is smaller than viewport")
    func imagePopupCentersSmallerScaledContent() {
        let insets = ImagePopupViewerLayout.centeredContentInset(
            contentSize: CGSize(width: 400, height: 250),
            viewportSize: CGSize(width: 700, height: 500)
        )

        #expect(insets.left == 150)
        #expect(insets.right == 150)
        #expect(insets.top == 125)
        #expect(insets.bottom == 125)
    }

    @Test("T233: Popup viewer defers initial fit scale until viewport has bounds")
    @MainActor
    func imagePopupViewerDefersInitialFitScaleUntilViewportHasBounds() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        }
        let controller = ImagePopupViewerController(image: image)
        controller.loadViewIfNeeded()

        controller.view.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        controller.view.frame = CGRect(x: 0, y: 0, width: 636, height: 536)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        let viewportSize = controller.debugScrollView.bounds.size
        let expectedScale = ImagePopupViewerLayout.initialZoomScale(
            imageSize: image.size,
            viewportSize: viewportSize
        )

        #expect(viewportSize.width > 0)
        #expect(viewportSize.height > 0)
        #expect(expectedScale < 1)
        #expect(abs(controller.debugScrollView.zoomScale - expectedScale) < 0.001)
        #expect(controller.debugScrollView.contentSize.width <= viewportSize.width + 0.5)
        #expect(controller.debugScrollView.contentSize.height <= viewportSize.height + 0.5)
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
        let expectedPreviewMaxHeight = 900 - (metrics.bubblePaddingTop + metrics.bubblePaddingBottom)
        let previewMeasured = preview.sizeThatFits(
            CGSize(width: referenceWidthCap, height: .greatestFiniteMagnitude)
        )
        #expect(abs(previewMeasured.height - expectedPreviewMaxHeight) <= 1)
    }

    @Test("T1193: BubbleSizingV2 link preview viewport uses asymmetric bubble padding")
    func bubbleSizingV2LinkPreviewViewportUsesAsymmetricPadding() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let env = BubbleSizingV2.Environment(
            containerWidth: 1200,
            containerHeight: 900,
            singleLinkContainerHeight: 900,
            topInset: 0,
            bottomInset: 0,
            truncationBottomInset: 0,
            isVisionOS: false,
            metricsFingerprint: BubbleSizingV2.metricsFingerprint(metrics: metrics, traitCollection: UITraitCollection())
        )

        let policy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: env,
            isSingleLinkPreview: true,
            prefersScreenAwareHeightCap: true,
            allowsOuterScroll: false
        )

        let expectedPreviewMaxHeight = policy.heightCap - (metrics.bubblePaddingTop + metrics.bubblePaddingBottom)
        #expect(abs(policy.linkPreviewViewportMaxHeight - expectedPreviewMaxHeight) <= 1)
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
            count: 72
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
        let presentationWithoutLinkCards = MessagePresentation(
            parts: presentationWithoutPreview.parts,
            wordCount: presentationWithoutPreview.wordCount,
            hasTextualContent: presentationWithoutPreview.hasTextualContent,
            isEmojiOnly: presentationWithoutPreview.isEmojiOnly,
            hasMediaOnly: presentationWithoutPreview.hasMediaOnly,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )

        let expandsWithoutPreview = expandCallbackCount(
            message: message,
            presentation: presentationWithoutLinkCards,
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

    @Test("T118: Single-link bubble swipe-up opens expanded viewer")
    @MainActor
    func singleLinkSwipeUpRequestsExpand() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let singleLinkMessage = Message(
            id: "single-link-swipe-up",
            role: .assistant,
            content: "Read this:\nhttps://example.com/preview",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let multiLinkMessage = Message(
            id: "multi-link-swipe-up",
            role: .assistant,
            content: "Links:\nhttps://a.example\nhttps://b.example",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )

        let singleLinkPresentation = buildPresentation(singleLinkMessage, metrics: metrics, enableLinkPreviews: true)
        let multiLinkPresentation = buildPresentation(multiLinkMessage, metrics: metrics, enableLinkPreviews: true)
        let noPreviewPresentation = buildPresentation(singleLinkMessage, metrics: metrics, enableLinkPreviews: false)

        #expect(
            swipeUpExpandCallbackCount(
                message: singleLinkMessage,
                presentation: singleLinkPresentation,
                metrics: metrics
            ) == 1
        )
        #expect(
            swipeUpExpandCallbackCount(
                message: multiLinkMessage,
                presentation: multiLinkPresentation,
                metrics: metrics
            ) == 0
        )
        #expect(
            swipeUpExpandCallbackCount(
                message: singleLinkMessage,
                presentation: noPreviewPresentation,
                metrics: metrics
            ) == 0
        )
    }

    @Test("T028: Link preview uses one outer squircle radius (no inner webview corner radius)")
    @MainActor
    func linkPreviewAvoidsInnerCornerRadiusLayer() {
        let preview = LinkPreviewView()
        preview.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        preview.layoutIfNeeded()

        guard let webView = firstWebView(in: preview) else {
            Issue.record("Expected WKWebView in LinkPreviewView hierarchy")
            return
        }

        #expect(webView.layer.cornerRadius == 0)
        #expect(webView.scrollView.layer.cornerRadius == 0)
    }

    @Test("T191: Link preview keeps video embedded and blocks in-bubble playback")
    @MainActor
    func linkPreviewBlocksMediaPlaybackAndFullscreenPromotion() {
        let preview = LinkPreviewView()
        preview.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        preview.layoutIfNeeded()

        guard let webView = firstWebView(in: preview) else {
            Issue.record("Expected WKWebView in LinkPreviewView hierarchy")
            return
        }

        #expect(preview.mediaPlaybackSuspendedForPreview)
        #expect(webView.configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(webView.configuration.allowsInlineMediaPlayback)
        #expect(webView.configuration.allowsAirPlayForMediaPlayback == false)
        #expect(webView.configuration.allowsPictureInPictureMediaPlayback == false)
        #expect(webView.configuration.preferences.isElementFullscreenEnabled == false)
    }

    @Test("T191: Direct video previews use embedded aspect-height sizing")
    @MainActor
    func directVideoPreviewUsesAspectHeightSizing() {
        let preview = LinkPreviewView()
        let url = URL(string: "https://example.com/demo.mp4")!

        preview.configure(url: url, maxHeight: 360)

        let measured = preview.sizeThatFits(CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height))

        #expect(LinkPreviewView.isDirectMediaPreviewURL(url))
        #expect(abs(measured.height - 180) <= 1)
    }

    @Test("T191: Plug-in handled load is suppressed for direct media navigation")
    func directVideoPluginHandledLoadErrorIsRecognized() {
        let pluginError = NSError(
            domain: "WebKitErrorDomain",
            code: 204,
            userInfo: [NSLocalizedDescriptionKey: "Plug-in handled load"]
        )
        let unrelatedError = NSError(
            domain: "WebKitErrorDomain",
            code: 102,
            userInfo: [NSLocalizedDescriptionKey: "Frame load interrupted"]
        )

        #expect(LinkPreviewView.isPluginHandledLoadNavigationError(pluginError))
        #expect(!LinkPreviewView.isPluginHandledLoadNavigationError(unrelatedError))
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
            truncationHeightOverride: 44,
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
        if let inner = innerBubbleScrollView(in: bubble) {
            inner.contentSize = CGSize(width: max(1, inner.bounds.width), height: inner.bounds.height + 200)
        }

        _ = bubble.perform(NSSelectorFromString("handleBubbleTap"))
        return count
    }

    @MainActor
    private func swipeUpExpandCallbackCount(message: Message,
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

        _ = bubble.perform(NSSelectorFromString("handleBubbleSwipeUp"))
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

    private func markdownBodyStack(in view: UIView, arrangedSubviewCountAtLeast minimumCount: Int) -> UIStackView? {
        if let stack = view as? UIStackView,
           stack.axis == .vertical,
           stack.superview is UIScrollView,
           stack.arrangedSubviews.count >= minimumCount {
            return stack
        }
        for sub in view.subviews {
            if let found = markdownBodyStack(in: sub, arrangedSubviewCountAtLeast: minimumCount) {
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

    private func renderedGlyphFrame(for textView: UITextView, in targetView: UIView) -> CGRect {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let usedRect = textView.layoutManager.usedRect(for: textView.textContainer)
        let glyphFrame = CGRect(
            x: usedRect.minX + textView.textContainerInset.left,
            y: usedRect.minY + textView.textContainerInset.top,
            width: usedRect.width,
            height: usedRect.height
        )
        return textView.convert(glyphFrame, to: targetView)
    }

    @MainActor
    private func measuredUserBubble(
        message: Message,
        metrics: ChatFlowTheme.Metrics,
        injectedViewportHeight: CGFloat
    ) -> CGSize {
        let presentation = buildPresentation(message, metrics: metrics, enableLinkPreviews: false)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let env = BubbleSizingV2.Environment(
            containerWidth: 320,
            containerHeight: 640,
            singleLinkContainerHeight: 640,
            topInset: 0,
            bottomInset: 0,
            truncationBottomInset: 0,
            isVisionOS: false,
            metricsFingerprint: BubbleSizingV2.metricsFingerprint(metrics: metrics, traitCollection: UITraitCollection())
        )
        let heightPolicy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: env,
            isSingleLinkPreview: false,
            prefersScreenAwareHeightCap: false,
            allowsOuterScroll: false
        )
        let plan = BubbleSizingV2.Plan(
            messageId: message.id,
            presentationFingerprint: 1,
            sizeClass: sizeClass,
            isSingleLinkPreview: false,
            isWide: false,
            maxWidth: 320,
            minWidth: 40,
            heightPolicy: heightPolicy,
            allowsOuterScroll: false,
            linkPreviewURL: nil
        )
        let layoutState = BubbleSizingV2.LayoutState(
            plan: plan,
            measurement: BubbleSizingV2.Measurement(
                measuredCellSize: CGSize(width: 320, height: injectedViewportHeight),
                measuredBubbleWidth: 320,
                contentHeight: 24,
                chromeHeight: 20,
                outerScrollEnabled: false,
                outerScrollViewportHeight: injectedViewportHeight,
                isFinal: true
            ),
            linkPreviewCacheKey: nil,
            linkPreviewEstimatedHeight: nil,
            linkPreviewMinHeight: 40,
            linkPreviewMaxHeight: heightPolicy.heightCap
        )
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 1))
        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: 320,
            bubbleHeightPolicy: heightPolicy,
            bubbleSizingV2: layoutState,
            showsHeader: false,
            paddingScale: 1,
            minWidthOverride: nil,
            maxWidthOverride: nil,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        return bubble.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    private func isBold(_ substring: String, in attributed: NSAttributedString) -> Bool {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound,
              let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else {
            return false
        }
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }

    private func linkTarget(_ substring: String, in attributed: NSAttributedString) -> URL? {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        if let url = attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL {
            return url
        }
        if let value = attributed.attribute(.link, at: range.location, effectiveRange: nil) as? String {
            return URL(string: value)
        }
        return nil
    }

    private func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }
        for sub in view.subviews {
            if let found = firstWebView(in: sub) {
                return found
            }
        }
        return nil
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
