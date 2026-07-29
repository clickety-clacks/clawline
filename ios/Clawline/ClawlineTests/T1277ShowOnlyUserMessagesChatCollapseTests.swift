import XCTest
import UIKit
import SwiftUI
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

    func testStreamSearchFiltersVisibleMessageContent() {
        let messages = [
            t1277Message(id: "a1", role: .assistant, content: "assistant one"),
            t1277Message(id: "u1", role: .user, content: "user needle"),
            t1277Message(id: "a2", role: .assistant, content: "assistant needle")
        ]

        XCTAssertEqual(
            StreamMessageSearch.filteredMessages(from: messages, query: "needle").map(\.id),
            ["u1", "a2"]
        )
    }

    func testCollapsedProjectionSearchFiltersOnlyVisibleUserMessages() {
        let messages = [
            t1277Message(id: "a1", role: .assistant, content: "needle hidden"),
            t1277Message(id: "u1", role: .user, content: "visible needle"),
            t1277Message(id: "a2", role: .assistant, content: "needle hidden assistant")
        ]
        let visibleMessages = ShowOnlyUserMessagesChatCollapse.visibleMessages(from: messages, isCollapsed: true)

        XCTAssertEqual(
            StreamMessageSearch.filteredMessages(from: visibleMessages, query: "needle").map(\.id),
            ["u1"]
        )
    }

    func testClearingStreamSearchRestoresProjectedVisibleMessages() {
        let messages = [
            t1277Message(id: "a1", role: .assistant, content: "assistant one"),
            t1277Message(id: "u1", role: .user, content: "user one")
        ]

        XCTAssertEqual(
            StreamMessageSearch.filteredMessages(from: messages, query: "").map(\.id),
            ["a1", "u1"]
        )
    }

    func testMaterializationRefreshPreservesActiveStreamSearchQuery() throws {
        let source = try t1277MessageFlowCollectionViewSource()
        let body = try XCTUnwrap(t1277FunctionBody(named: "runMaterializationRefreshPass", in: source))

        XCTAssertTrue(body.contains("streamSearchQuery: streamSearchQuery"))
        XCTAssertTrue(body.contains("onStreamSearchQueryChanged: onStreamSearchQueryChanged"))
    }

    func testCollapsedModeRebuildPreservesStreamSearchCallback() throws {
        let source = try t1277MessageFlowCollectionViewSource()
        let body = try XCTUnwrap(t1277FunctionBody(named: "setShowOnlyUserMessages", in: source))

        XCTAssertTrue(body.contains("streamSearchQuery: streamSearchQuery"))
        XCTAssertTrue(body.contains("onStreamSearchQueryChanged: onStreamSearchQueryChanged"))
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
        let action = try XCTUnwrap(menuButton.menu?.children.compactMap { $0 as? UIKeyCommand }.first {
            $0.title == "Hide Assistant Messages"
        })

        _ = bubble.perform(action.action, with: action)

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
        let titles = menuButton.menu?.children.map(\.title) ?? []

        XCTAssertTrue(titles.contains("Show Only User Messages"))
        XCTAssertFalse(titles.contains("Show Assistant Messages"))
    }

    func testExistingMessageMenuShowsCommandBacktickShortcut() throws {
        let bubble = t1277ConfiguredBubble(
            message: t1277Message(id: "u_menu_shortcut", role: .user, content: "menu"),
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: false),
            onToggle: {}
        )
        let menuButton = try XCTUnwrap(t1277FindSubview(in: bubble) {
            $0.accessibilityIdentifier == "message_bubble_header_menu_button"
        } as? UIButton)
        let command = try XCTUnwrap(menuButton.menu?.children.compactMap { $0 as? UIKeyCommand }.first {
            $0.title == "Hide Assistant Messages"
        })

        XCTAssertEqual(command.input, "`")
        XCTAssertEqual(command.modifierFlags.intersection([.command, .shift, .alternate, .control]), [.command])
    }

    func testCollapsedUserMessageTapUsesMessageIdentityForReveal() {
        let message = t1277Message(id: "u_reveal_identity", role: .user, content: "repeat")
        var revealedMessageId: String?
        let bubble = t1277ConfiguredBubble(
            message: message,
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: {},
            isCollapsedUserOnlyMode: true,
            onReveal: { revealedMessageId = $0.id }
        )

        _ = bubble.perform(NSSelectorFromString("handleBubbleTap"))

        XCTAssertEqual(revealedMessageId, "u_reveal_identity")
    }

    func testCollapsedUserOnlyBubbleIsTapOnlyWithoutSelectionOrMenus() throws {
        let message = t1277Message(id: "u_tap_only", role: .user, content: "tap only")
        var toggled = 0
        var revealedMessageId: String?
        let bubble = t1277ConfiguredBubble(
            message: message,
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: { toggled += 1 },
            isCollapsedUserOnlyMode: true,
            onReveal: { revealedMessageId = $0.id }
        )

        XCTAssertFalse(try XCTUnwrap(t1277BodyTextView(in: bubble, containing: "tap only")).isSelectable)
        XCTAssertEqual(t1277HeaderMenuTitles(in: bubble), [])
        XCTAssertNil(bubble.contextMenuInteraction(
            UIContextMenuInteraction(delegate: bubble),
            configurationForMenuAtLocation: .zero
        ))

        _ = bubble.perform(NSSelectorFromString("handleBubbleTap"))

        XCTAssertEqual(revealedMessageId, "u_tap_only")
        XCTAssertEqual(toggled, 0)
    }

    func testFullTranscriptBubbleKeepsSelectionAndBubbleMenu() throws {
        let bubble = t1277ConfiguredBubble(
            message: t1277Message(id: "u_full_interactions", role: .user, content: "full"),
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: false),
            onToggle: {}
        )

        XCTAssertTrue(try XCTUnwrap(t1277BodyTextView(in: bubble, containing: "full")).isSelectable)
        XCTAssertTrue(t1277HeaderMenuTitles(in: bubble).contains("Hide Assistant Messages"))
        XCTAssertNotNil(bubble.contextMenuInteraction(
            UIContextMenuInteraction(delegate: bubble),
            configurationForMenuAtLocation: .zero
        ))
    }

    func testCollapsedUserOnlyLongBubbleDisablesOuterScrollInteraction() {
        let message = t1277Message(
            id: "u_long_tap_only",
            role: .user,
            content: Array(repeating: "Long collapsed bubble remains tap only.", count: 80).joined(separator: "\n")
        )
        let bubble = t1277ConfiguredBubble(
            message: message,
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: {},
            sizeClass: .long,
            isCollapsedUserOnlyMode: true,
            onReveal: { _ in }
        )

        XCTAssertFalse(t1277ScrollViews(in: bubble).contains { $0.isScrollEnabled })
    }

    func testCollapsedUserOnlyBubbleUsesDesignSystemGreenTintInLightAndDark() {
        let lightBubble = t1277ConfiguredBubble(
            message: t1277Message(id: "u_green_tint_light", role: .user, content: "collapsed"),
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: {},
            isCollapsedUserOnlyMode: true,
            isDark: false,
            onReveal: { _ in }
        )
        let darkBubble = t1277ConfiguredBubble(
            message: t1277Message(id: "u_green_tint_dark", role: .user, content: "collapsed"),
            menuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(isCollapsed: true),
            onToggle: {},
            isCollapsedUserOnlyMode: true,
            isDark: true,
            onReveal: { _ in }
        )

        XCTAssertTrue(t1277BubbleGradient(in: lightBubble, contains: UIColor(ChatFlowTheme.collapsedUserBubbleGreenTint(.light))))
        XCTAssertTrue(t1277BubbleGradient(in: darkBubble, contains: UIColor(ChatFlowTheme.collapsedUserBubbleGreenTint(.dark))))
        XCTAssertFalse(t1277BubbleGradient(in: lightBubble, contains: ChatFlowUIKitTheme.palette(isDark: false).bubbleSelfGradient[0]))
        XCTAssertFalse(t1277BubbleGradient(in: darkBubble, contains: ChatFlowUIKitTheme.palette(isDark: true).bubbleSelfGradient[0]))
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
            isCollapsedUserOnlyMode: true,
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

private func t1277MessageFlowCollectionViewSource() throws -> String {
    let testsURL = URL(fileURLWithPath: #filePath)
    let sourceURL = testsURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Clawline/Views/Chat/MessageFlowCollectionView.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func t1277FunctionBody(named name: String, in source: String) -> String? {
    guard let signatureRange = source.range(of: "func \(name)") else { return nil }
    guard let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        let character = source[index]
        if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 {
                return String(source[openingBrace...index])
            }
        }
        index = source.index(after: index)
    }
    return nil
}

@MainActor
private func t1277ConfiguredBubble(
    message: Message,
    menuLabel: String,
    onToggle: @escaping () -> Void,
    sizeClass: MessageSizeClass = .short,
    isCollapsedUserOnlyMode: Bool = false,
    isDark: Bool = false,
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
        stream: .personal,
        presentation: presentation,
        sizeClass: sizeClass,
        metrics: metrics,
        maxWidth: 320,
        bubbleSizingV2: nil,
        showsHeader: true,
        paddingScale: 1,
        minWidthOverride: 120,
        maxWidthOverride: 320,
        useContinuousCorners: true,
        isDark: isDark,
        onRequestExpand: nil,
        onRequestLayout: nil,
        onInteractiveCallback: nil,
        onInsertIntoPrompt: nil,
        onReferenceMessage: nil,
        showOnlyUserMessagesMenuLabel: menuLabel,
        onToggleShowOnlyUserMessages: onToggle,
        onShowOnlyUserMessagesReveal: onReveal,
        isCollapsedUserOnlyMode: isCollapsedUserOnlyMode,
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

@MainActor
private func t1277BodyTextView(in root: UIView, containing text: String) -> UITextView? {
    t1277FindSubview(in: root) { view in
        guard let textView = view as? UITextView else { return false }
        return textView.attributedText?.string.contains(text) == true
    } as? UITextView
}

@MainActor
private func t1277HeaderMenuTitles(in root: UIView) -> [String] {
    let menuButton = t1277FindSubview(in: root) {
        $0.accessibilityIdentifier == "message_bubble_header_menu_button"
    } as? UIButton
    return menuButton?.menu?.children.map(\.title) ?? []
}

@MainActor
private func t1277ScrollViews(in root: UIView) -> [UIScrollView] {
    let local = (root as? UIScrollView).map { [$0] } ?? []
    return local + root.subviews.flatMap { t1277ScrollViews(in: $0) }
}

@MainActor
private func t1277BubbleGradient(in root: UIView, contains expected: UIColor) -> Bool {
    t1277GradientLayers(in: root).contains { layer in
        (layer.colors as? [CGColor] ?? []).contains { color in
            t1277Color(UIColor(cgColor: color), matches: expected)
        }
    }
}

@MainActor
private func t1277GradientLayers(in root: UIView) -> [CAGradientLayer] {
    let local = root.layer.sublayers?.compactMap { $0 as? CAGradientLayer } ?? []
    return local + root.subviews.flatMap { t1277GradientLayers(in: $0) }
}

private func t1277Color(_ actual: UIColor?, matches expected: UIColor, tolerance: CGFloat = 0.001) -> Bool {
    guard let actual else { return false }
    var actualRed: CGFloat = 0
    var actualGreen: CGFloat = 0
    var actualBlue: CGFloat = 0
    var actualAlpha: CGFloat = 0
    var expectedRed: CGFloat = 0
    var expectedGreen: CGFloat = 0
    var expectedBlue: CGFloat = 0
    var expectedAlpha: CGFloat = 0
    guard actual.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha),
          expected.getRed(&expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha) else {
        return false
    }
    return abs(actualRed - expectedRed) <= tolerance
        && abs(actualGreen - expectedGreen) <= tolerance
        && abs(actualBlue - expectedBlue) <= tolerance
        && abs(actualAlpha - expectedAlpha) <= tolerance
}
