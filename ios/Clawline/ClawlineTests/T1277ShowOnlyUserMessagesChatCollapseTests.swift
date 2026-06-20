import XCTest
import UIKit
@testable import Clawline

@MainActor
final class T1277ShowOnlyUserMessagesChatCollapseTests: XCTestCase {
    func testCollapsedProjectionKeepsOnlyUserMessagesInTranscriptOrder() {
        let messages = [
            t1277Message(id: "a1", role: .assistant, content: "assistant one"),
            t1277Message(id: "u1", role: .user, content: "repeat"),
            t1277Message(id: "a2", role: .assistant, content: "assistant two"),
            t1277Message(id: "u2", role: .user, content: "repeat")
        ]

        XCTAssertEqual(
            ShowOnlyUserMessagesChatCollapse.visibleMessages(from: messages, isCollapsed: true).map(\.id),
            ["u1", "u2"]
        )
        XCTAssertEqual(
            ShowOnlyUserMessagesChatCollapse.visibleMessages(from: messages, isCollapsed: false).map(\.id),
            ["a1", "u1", "a2", "u2"]
        )
    }

    func testAnimationAndRetainedCountsMatchSpecValues() {
        XCTAssertEqual(ShowOnlyUserMessagesChatCollapse.animationDuration, 0.3)
        XCTAssertEqual(
            MessageFlowCollectionViewController.stagedMaterializationTailWindowCount(isShowingOnlyUserMessages: false),
            50
        )
        XCTAssertEqual(
            MessageFlowCollectionViewController.stagedMaterializationTailWindowCount(isShowingOnlyUserMessages: true),
            100
        )
        XCTAssertEqual(ChatViewModel.messageCacheLimit, 500)
        XCTAssertEqual(ChatViewModel.showOnlyUserMessagesMessageCacheLimit, 1_000)
    }

    func testExistingMessageMenuShowsExactFullChatLabel() throws {
        var toggled = 0
        let bubble = t1277ConfiguredBubble(
            message: t1277Message(id: "u_menu_full", role: .user, content: "menu"),
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: false),
            onToggle: { toggled += 1 }
        )
        let menuButton = try XCTUnwrap(t1277FindSubview(in: bubble) {
            $0.accessibilityIdentifier == "message_bubble_header_menu_button"
        } as? UIButton)
        let action = try XCTUnwrap(menuButton.menu?.children.compactMap { $0 as? UIAction }.first {
            $0.title == "Hide Assistant Messages"
        })

        action.performWithSender(nil, target: nil)

        XCTAssertTrue(menuButton.showsMenuAsPrimaryAction)
        XCTAssertEqual(toggled, 1)
    }

    func testExistingMessageMenuShowsExactCollapsedLabel() throws {
        let bubble = t1277ConfiguredBubble(
            message: t1277Message(id: "u_menu_collapsed", role: .user, content: "menu"),
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: {}
        )
        let menuButton = try XCTUnwrap(t1277FindSubview(in: bubble) {
            $0.accessibilityIdentifier == "message_bubble_header_menu_button"
        } as? UIButton)
        let titles = menuButton.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []

        XCTAssertTrue(titles.contains("Show Only User Messages"))
        XCTAssertFalse(titles.contains("Show Assistant Messages"))
    }

    func testCollapsedUserMessageTapUsesMessageIdentityForReveal() {
        let message = t1277Message(id: "u_reveal_identity", role: .user, content: "repeat")
        var revealedMessageId: String?
        let bubble = t1277ConfiguredBubble(
            message: message,
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: {},
            onReveal: { revealedMessageId = $0.id }
        )

        _ = bubble.perform(NSSelectorFromString("handleBubbleTap"))

        XCTAssertEqual(revealedMessageId, "u_reveal_identity")
    }

    func testCollapsedUserMessageWithLinkCardStillRevealsOnNonLinkBubbleTap() {
        let message = t1277Message(
            id: "u_reveal_link_card",
            role: .user,
            content: "Review https://example.com/t1277 for details."
        )
        var revealedMessageId: String?
        let bubble = t1277ConfiguredBubble(
            message: message,
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: {},
            onReveal: { revealedMessageId = $0.id }
        )

        _ = bubble.perform(NSSelectorFromString("handleBubbleTap"))

        XCTAssertEqual(revealedMessageId, "u_reveal_link_card")
    }
}

private let t1277SessionKey = SessionKey.clawlineMain(userId: "t1277")

private func t1277Message(id: String, role: Message.Role, content: String) -> Message {
    Message(
        id: id,
        role: role,
        content: content,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        streaming: false,
        attachments: [],
        deviceId: nil,
        sessionKey: t1277SessionKey
    )
}

@MainActor
private func t1277ConfiguredBubble(
    message: Message,
    menuLabel: String,
    onToggle: @escaping () -> Void,
    onReveal: ((Message) -> Void)? = nil
) -> MessageBubbleUIKitView {
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
        showOnlyUserMessagesMenuLabel: menuLabel,
        onToggleShowOnlyUserMessages: onToggle,
        onShowOnlyUserMessagesReveal: onReveal,
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
    return bubble
}

@MainActor
private func t1277FindSubview(in root: UIView, where predicate: (UIView) -> Bool) -> UIView? {
    if predicate(root) {
        return root
    }
    for subview in root.subviews {
        if let found = t1277FindSubview(in: subview, where: predicate) {
            return found
        }
    }
    return nil
}
