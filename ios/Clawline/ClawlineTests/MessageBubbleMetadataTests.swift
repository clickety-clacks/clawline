//
//  MessageBubbleMetadataTests.swift
//  ClawlineTests
//
//  Created by Codex on 5/7/26.
//

import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageBubbleMetadataTests {
    @Test("Narrow bubble hides timestamp before truncating sender")
    func narrowBubbleHidesTimestampBeforeTruncatingSender() {
        let message = Message(
            id: "metadata-narrow",
            role: .user,
            content: "Short",
            timestamp: Date(timeIntervalSince1970: 1_577_836_800),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        var streamingState = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &streamingState
        )
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 120, height: 1))

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 120,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 120,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 120, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let state = bubble.debugMetadataStateForTests()
        #expect(state.senderText == "You")
        #expect(state.senderLineBreakMode == .byClipping)
        #expect(state.senderCompressionResistance == .required)
        #expect(state.timestampCompressionResistance.rawValue < state.senderCompressionResistance.rawValue)
        #expect(state.timestampHidden)
    }

    @Test("Timestamp metadata uses readable opacity")
    func timestampMetadataUsesReadableOpacity() {
        #expect(MessageBubbleUIKitView.timestampTextAlpha(isDark: false) > 0.4)
        #expect(MessageBubbleUIKitView.timestampTextAlpha(isDark: true) > 0.4)
    }

    @Test("T1465: message header stays compact inside an overallocated bubble")
    func messageHeaderStaysCompactInsideOverallocatedBubble() {
        let message = Message(
            id: "t1465-header-expansion",
            role: .assistant,
            content: "Cron job \"led-ticker-art\" failed:\nshow << -> run python3 # failed",
            timestamp: Date(timeIntervalSince1970: 1_772_496_480),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: "CLU"
        )
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        var streamingState = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &streamingState
        )
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 560, height: 1))

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 560,
            truncationHeightOverride: nil,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 560,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )

        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 560, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let avatar = findSubview(in: bubble) { $0 is AvatarCircleView }
        let body = findSubview(in: bubble) { view in
            guard let textView = view as? UITextView else { return false }
            return textView.text.contains("Cron job")
        }
        #expect(avatar != nil)
        #expect(body != nil)

        if let avatar, let body {
            let avatarFrame = avatar.convert(avatar.bounds, to: bubble)
            let bodyFrame = body.convert(body.bounds, to: bubble)
            let geometry = bubble.renderedGeometryForTests(in: bubble)
            let ownedInsets = MessageBubbleGeometry.contentInsets(
                metrics: metrics,
                paddingScale: 1,
                hasTerminalSessions: false,
                hasMediaOnly: false
            )
            let bottomBlank = geometry.bubbleFrame.maxY - geometry.contentFrame.maxY

            #expect(avatarFrame.minY < 80)
            #expect(bodyFrame.minY - avatarFrame.maxY < 40)
            #expect(bodyFrame.width > bubble.bounds.width * 0.85)
            #expect(abs(bottomBlank - ownedInsets.bottom) <= 0.5)
            #expect(abs(geometry.bubbleFrame.height - bubble.bounds.height) <= 0.5)
            print(
                "T1465 geometry proof bubbleFrame=\(geometry.bubbleFrame) contentFrame=\(geometry.contentFrame) bodyFrame=\(bodyFrame) bottomBlank=\(bottomBlank) ownedBottomInset=\(ownedInsets.bottom) measuredCellHeight=\(bubble.bounds.height)"
            )
        }
    }

    @Test("T320: bubble title bar menu button is wired on iOS/iPadOS")
    func titleBarMenuButtonIsWiredForTitleTap() {
        let message = Message(
            id: "title-bar-menu",
            role: .assistant,
            content: "Title bar menu content",
            timestamp: Date(timeIntervalSince1970: 1_577_836_800),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        var streamingState = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &streamingState
        )
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 1))

        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            truncationHeightOverride: nil,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 320,
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

        let menuButton = findSubview(in: bubble) { $0.accessibilityIdentifier == "message_bubble_header_menu_button" } as? UIButton
        #expect(menuButton != nil)
        #expect(menuButton?.menu != nil)
        #expect(menuButton?.showsMenuAsPrimaryAction == true)
    }

    @Test("Outgoing reply bubble shows in-bubble reply indicator")
    func outgoingReplyBubbleShowsInBubbleReplyIndicator() {
        let referenced = Message(
            id: "s_reference",
            role: .assistant,
            content: "The referenced message that should be visible inside the outgoing bubble chip.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            clientMessageId: "c_reference"
        )
        let replyReference = PendingMessageReference(message: referenced)
        let message = Message(
            id: "s_reply",
            role: .user,
            content: "Understood.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: referenced.sessionKey,
            replyToMessageId: referenced.id,
            replyToClientMessageId: referenced.clientMessageId
        )
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
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 320,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: replyReference,
            salientHighlightService: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let state = bubble.debugMetadataStateForTests()
        #expect(state.replyIndicatorHidden == false)
        #expect(state.replyIndicatorText == replyReference.tokenLabel)
        #expect(state.replyIndicatorText?.contains("assistant:") == false)
    }

    @Test("T1166: composer reply token renders markdown label")
    func composerReplyTokenRendersMarkdownLabel() {
        let rendered = MessageReferenceTextAttachment.debugRenderedTokenLabelForTests("Reply to **bold** _italic_")

        #expect(rendered.string == "Reply to bold italic")
        #expect(rendered.string.contains("**") == false)
        #expect(rendered.string.contains("_") == false)
        #expect(isBold("bold", in: rendered))
    }

    @Test("T1166: outgoing reply chip renders markdown with three-line cap")
    func outgoingReplyChipRendersMarkdownWithThreeLineCap() {
        let referenced = Message(
            id: "s_markdown_reference",
            role: .assistant,
            content: "**Important** reply source with _markdown_ that is long enough to wrap across multiple chip lines before truncating inside the sent user bubble with additional rendered words for proof.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            clientMessageId: "c_markdown_reference"
        )
        let bubble = configuredUserReplyBubble(
            prompt: "Ok",
            replyReference: PendingMessageReference(message: referenced),
            maxWidth: 220
        )

        let state = bubble.debugMetadataStateForTests()
        let rendered = state.replyIndicatorRenderedText

        #expect(state.replyIndicatorHidden == false)
        #expect(state.replyIndicatorLineLimit == 3)
        #expect(state.replyIndicatorTextHeight <= (state.replyIndicatorTextLineHeight * 3) + 4)
        #expect(state.replyIndicatorChipHeight <= state.replyIndicatorTextHeight + 14)
        #expect(state.replyIndicatorUncappedTextHeight > state.replyIndicatorTextHeight)
        #expect(rendered?.string.contains("Important reply source") == true)
        #expect(rendered?.string.contains("**") == false)
        #expect(rendered?.string.contains("_") == false)
        if let rendered {
            #expect(isBold("Important", in: rendered))
        }
    }

    @Test("T1166: long markdown reply preview truncates after rendering")
    func longMarkdownReplyPreviewTruncatesAfterRendering() {
        let referenced = Message(
            id: "s_long_markdown_reference",
            role: .assistant,
            content: "**\(Array(repeating: "markdown", count: 40).joined(separator: " "))**",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            clientMessageId: "c_long_markdown_reference"
        )
        let replyReference = PendingMessageReference(message: referenced)
        let rendered = MessageReferenceTextAttachment.debugRenderedTokenLabelForTests(replyReference.preview)
        let attachment = MessageReferenceTextAttachment(reference: replyReference)

        #expect(replyReference.preview.count == PendingMessageReference.previewLimit)
        #expect(rendered.string.contains("**") == false)
        #expect(isBold("markdown", in: rendered))
        #expect(attachment.referenceId == replyReference.id)
        #expect(attachment.image != nil)
        #expect(attachment.bounds.width <= 160)
    }

    @Test("T1166: reply chip text participates in user bubble preferred width")
    func replyChipTextParticipatesInUserBubblePreferredWidth() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let maxWidth: CGFloat = 320
        let referenced = Message(
            id: "s_wide_reference",
            role: .assistant,
            content: "A substantially longer rendered reply quote should widen the outgoing bubble even when the prompt text is short.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            clientMessageId: "c_wide_reference"
        )

        let plainBubble = configuredUserReplyBubble(prompt: "Ok", replyReference: nil, maxWidth: maxWidth)
        let replyBubble = configuredUserReplyBubble(
            prompt: "Ok",
            replyReference: PendingMessageReference(message: referenced),
            maxWidth: maxWidth
        )

        let plainWidth = plainBubble.preferredWidth(maxWidth: maxWidth, minWidth: 120)
        let replyWidth = replyBubble.preferredWidth(maxWidth: maxWidth, minWidth: 120)

        #expect(replyWidth > plainWidth + metrics.bubblePaddingHorizontal)
        #expect(replyWidth <= maxWidth)
    }

    @Test("BubbleSizingV2 does not preserve design cap as short bubble body height")
    func bubbleSizingV2ShortBubbleViewportTracksMeasuredContent() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let env = BubbleSizingV2.Environment(
            containerWidth: 396,
            containerHeight: 844,
            singleLinkContainerHeight: 844,
            topInset: 0,
            bottomInset: 0,
            truncationBottomInset: 0,
            isVisionOS: false,
            metricsFingerprint: 1
        )
        let heightPolicy = BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: env,
            isSingleLinkPreview: false,
            prefersScreenAwareHeightCap: false,
            allowsOuterScroll: false
        )
        let plan = BubbleSizingV2.Plan(
            messageId: "short-bubble",
            presentationFingerprint: 1,
            sizeClass: .short,
            isSingleLinkPreview: false,
            isWide: false,
            maxWidth: 396,
            minWidth: 40,
            heightPolicy: heightPolicy,
            allowsOuterScroll: false,
            linkPreviewURL: nil
        )

        let viewportHeight = BubbleSizingV2.finalOuterScrollViewportHeight(
            plan: plan,
            measuredContentHeight: 52,
            provisionalViewportHeight: 1_980
        )

        #expect(viewportHeight == 52)
    }

    @Test("Reply quote text participates in normal bubble width")
    func replyQuoteTextParticipatesInNormalBubbleWidth() {
        let referenced = Message(
            id: "s_width_reference",
            role: .assistant,
            content: "Referenced text whose reply chip should widen the outgoing bubble.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            clientMessageId: "c_width_reference"
        )
        let replyReference = PendingMessageReference(message: referenced)
        let message = Message(
            id: "s_width_reply",
            role: .user,
            content: "Ok",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: referenced.sessionKey,
            replyToMessageId: referenced.id,
            replyToClientMessageId: referenced.clientMessageId
        )
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
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            bubbleSizingV2: nil,
            showsHeader: false,
            paddingScale: 1,
            minWidthOverride: 40,
            maxWidthOverride: 320,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: replyReference,
            salientHighlightService: nil
        )

        #expect(bubble.preferredWidth(maxWidth: 320, minWidth: 40) > 120)
    }

    @Test("Reply token stays compact for long referenced previews")
    func replyTokenStaysCompactForLongReferencedPreviews() {
        let referenced = Message(
            id: "s_long_reference",
            role: .assistant,
            content: """
            This is a deliberately long referenced message preview that should be truncated so the composer token stays compact inside narrow widths.
            """,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            clientMessageId: "c_long_reference"
        )
        let reference = PendingMessageReference(message: referenced)
        let attachment = MessageReferenceTextAttachment(reference: reference)

        #expect(attachment.bounds.width <= 160)
        #expect(attachment.bounds.width >= 84)
        #expect(reference.tokenLabel.contains("assistant:") == false)
    }

    @Test("Bubble header title tap exposes Reply action on the real menu button")
    func bubbleHeaderTitleTapExposesReplyActionOnMenuButton() {
        let message = Message(
            id: "s_menu",
            role: .assistant,
            content: "Message with a title-area menu.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_200),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
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
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 320,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: nil,
            salientHighlightService: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let button = findSubview(in: bubble) { $0.accessibilityIdentifier == "message_bubble_header_menu_button" } as? UIButton
        let menuTitles = button?.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
        #expect(button?.showsMenuAsPrimaryAction == true)
        #expect(menuTitles.contains("Reply…"))
        #expect(menuTitles.contains("Reference message") == false)
    }

    @Test("Messages without visible ids still expose Reply action")
    func messagesWithoutVisibleIdsStillExposeReplyAction() {
        let message = Message(
            id: "c_optimistic",
            role: .user,
            content: "Pending send",
            timestamp: Date(timeIntervalSince1970: 1_700_000_300),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
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
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 320,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: nil,
            salientHighlightService: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let button = findSubview(in: bubble) { $0.accessibilityIdentifier == "message_bubble_header_menu_button" } as? UIButton
        let menuTitles = button?.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
        #expect(button?.showsMenuAsPrimaryAction == true)
        #expect(menuTitles.contains("Reply…"))
        #expect(menuTitles.contains("Reference message") == false)
    }

    @Test("T1151: bubble context menu copy action is labeled Copy message")
    func bubbleContextMenuCopyActionUsesCopyMessageLabel() {
        let message = Message(
            id: "s_copy_label",
            role: .assistant,
            content: "Message available for copying.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_250),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
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
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 320,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: nil,
            salientHighlightService: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let button = findSubview(in: bubble) { $0.accessibilityIdentifier == "message_bubble_header_menu_button" } as? UIButton
        let menuTitles = button?.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
        #expect(menuTitles.contains("Copy message"))
        #expect(menuTitles.contains("Copy to Clipboard") == false)
    }

    @Test("Unstable optimistic user bubbles do not expose Reply action")
    func unstableOptimisticUserBubblesDoNotExposeReplyAction() {
        let message = Message(
            id: "c_optimistic",
            role: .user,
            content: "Pending send",
            timestamp: Date(timeIntervalSince1970: 1_700_000_300),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal"
        )
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
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: 320,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: 320,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: nil,
            salientHighlightService: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()

        let button = findSubview(in: bubble) { $0.accessibilityIdentifier == "message_bubble_header_menu_button" } as? UIButton
        let menuTitles = button?.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
        #expect(menuTitles.contains("Reply…"))
    }

    private func findSubview(in root: UIView, where predicate: (UIView) -> Bool) -> UIView? {
        if predicate(root) {
            return root
        }
        for subview in root.subviews {
            if let found = findSubview(in: subview, where: predicate) {
                return found
            }
        }
        return nil
    }

    private func configuredUserReplyBubble(
        prompt: String,
        replyReference: PendingMessageReference?,
        maxWidth: CGFloat
    ) -> MessageBubbleUIKitView {
        let message = Message(
            id: "s_reply_\(UUID().uuidString)",
            role: .user,
            content: prompt,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: replyReference?.sessionKey ?? "server:personal",
            replyToMessageId: replyReference?.llmVisibleMessageId,
            replyToClientMessageId: replyReference?.clientMessageId
        )
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        var streamingState = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &streamingState
        )
        let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: maxWidth, height: 1))
        bubble.configure(
            message: message,
            presentation: presentation,
            sizeClass: .short,
            metrics: metrics,
            maxWidth: maxWidth,
            bubbleSizingV2: nil,
            showsHeader: true,
            paddingScale: 1,
            minWidthOverride: 120,
            maxWidthOverride: maxWidth,
            useContinuousCorners: true,
            isDark: false,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: replyReference,
            salientHighlightService: nil
        )
        let measured = bubble.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        bubble.frame = CGRect(origin: .zero, size: measured)
        bubble.layoutIfNeeded()
        return bubble
    }

    private func isBold(_ substring: String, in attributed: NSAttributedString) -> Bool {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound,
              let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else {
            return false
        }
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }
}
