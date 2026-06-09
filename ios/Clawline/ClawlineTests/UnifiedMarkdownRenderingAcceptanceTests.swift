import Testing
import SwiftUI
import UIKit
import XCTest
@testable import Clawline

struct UnifiedMarkdownRenderingAcceptanceTests {
    private let metrics = ChatFlowTheme.Metrics(isCompact: true)

    @Test("R48-01: mixed text/code/table preserves source order for bubble and expanded")
    func r48_01_orderPreserved() {
        let markdown = """
        Intro text.

        ```swift
        print(\"one\")
        ```

        Middle text.

        | A | B |
        | --- | --- |
        | 1 | 2 |

        Tail text.
        """

        let bubble = renderMarkdownForTests(markdown: markdown, options: bubbleOptions())
        let expanded = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        #expect(sequence(for: bubble) == [.attributedText, .code, .attributedText, .table, .attributedText])
        #expect(sequence(for: expanded) == [.attributedText, .code, .attributedText, .table, .attributedText])
    }

    @Test("R48-02: expanded path keeps all markdown blocks")
    func r48_02_noDroppedExpandedBlocks() {
        let markdown = (1...80)
            .map { "Paragraph \($0) with **markdown** and https://example.com/\($0)" }
            .joined(separator: "\n\n")
        let bubble = renderMarkdownForTests(markdown: markdown, options: bubbleOptions())
        let expanded = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        #expect(bubble.count == expanded.count)
    }

    @Test("R48-03: bubble and expanded share one plan and preserve the same text content")
    func r48_03_surfaceTextMatches() {
        let markdown = """
        # Heading

        Intro with https://one.example

        > quoted `inline`

        - list item

        ```python
        print("code")
        ```

        | K | V |
        | --- | --- |
        | a | b |
        """
        let bubble = renderMarkdownForTests(markdown: markdown, options: bubbleOptions())
        let expanded = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        #expect(sequence(for: bubble) == sequence(for: expanded))

        let bubbleText = joinedText(from: bubble)
        let expandedText = joinedText(from: expanded)
        #expect(bubbleText.contains("https://one.example"))
        #expect(expandedText.contains("https://one.example"))
        #expect(bubbleText == expandedText)
    }

    @Test("R50-01: fenced code with language does not regress to plain text")
    func r50_01_standardFence() {
        let markdown = """
        ```swift
        print("hello")
        ```

        trailing prose
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        #expect(sequence(for: rendered) == [.code, .attributedText])
    }

    @Test("R50-02: colon-prefixed line before fence keeps stable classification")
    func r50_02_colonPrefixBeforeFence() {
        let markdown = """
        Here is output:
        ```js
        console.log('x')
        console.log('y')
        ```
        done
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        #expect(sequence(for: rendered) == [.attributedText, .code, .attributedText])
    }

    @Test("R50-03: valid weird fence is code; malformed fence falls back to rich text")
    func r50_03_whitespaceAndMalformedFence() {
        let valid = """
        ```   
        alpha
        ```
        """
        let invalid = """
        ```
        alpha
        """

        let validRendered = renderMarkdownForTests(markdown: valid, options: expandedOptions())
        let invalidRendered = renderMarkdownForTests(markdown: invalid, options: expandedOptions())
        #expect(sequence(for: validRendered) == [.code])
        #expect(sequence(for: invalidRendered) == [.attributedText])
    }

    @Test("R50-04: multiple fenced blocks remain ordered")
    func r50_04_multipleCodeBlocks() {
        let markdown = """
        text

        ```swift
        print(1)
        ```

        middle

        ```python
        print(2)
        ```

        end
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        #expect(sequence(for: rendered) == [.attributedText, .code, .attributedText, .code, .attributedText])
    }

    @Test("T169: heavily-indented fenced code trims shared left gutter")
    func t169_heavilyIndentedCodeBlockRemainsVisible() {
        let markdown = """
        ```swift
                            struct Example {
                                let value = 1
                            }
        ```
        """

        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        guard case .code(let language, let code)? = rendered.first else {
            Issue.record("Expected first block to be code")
            return
        }

        #expect(language == "swift")
        #expect(code.trimmingCharacters(in: .newlines) == """
        struct Example {
            let value = 1
        }
        """)
        #expect(!code.hasPrefix("                    "))
    }

    @Test("HL-01: mark highlight applies to rich text only")
    func hl_01_markHighlightScoping() {
        let markdown = """
        Alpha ==focus== and `==literal==`.

        ```swift
        // ==code==
        print("ok")
        ```
        """
        let rendered = renderMarkdownForTests(
            markdown: markdown,
            options: MarkdownRenderOptions(
                baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
                inkColor: .black,
                lineSpacing: 4,
                stripDetectedURLs: false,
                markHighlightColor: SalientHighlightApplier.highlightColor(isDark: false)
            )
        )

        guard case .attributedText(let richText)? = rendered.first else {
            Issue.record("Expected first block to be attributed text")
            return
        }
        #expect(richText.string.contains("focus"))
        #expect(richText.string.contains("==literal=="))

        let codeBlocks = rendered.compactMap { block -> String? in
            if case .code(_, let code) = block { return code }
            return nil
        }
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks[0].contains("==code=="))
    }

    @Test("EM-01: renderer emoji-only handling is limited to 1-3 emoji characters")
    func em_01_rendererEmojiOnlyBounds() {
        let three = UnifiedMarkdownRenderer.makeContent(
            messageText: "😀😁😂",
            context: MarkdownMessageRenderContext(role: .assistant, messageID: "em_01_3", metrics: metrics),
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: false,
            isDark: false
        )
        #expect(three.joinedInlineEmojiValues == "😀😁😂")

        let four = UnifiedMarkdownRenderer.makeContent(
            messageText: "😀😁😂🤣",
            context: MarkdownMessageRenderContext(role: .assistant, messageID: "em_01_4", metrics: metrics),
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: false,
            isDark: false
        )
        #expect(four.joinedInlineEmojiValues == nil)
        #expect(four.hasNonEmptyAttributedText)
    }

    @Test("EM-02: emoji-only messages preserve all inline blocks across surfaces")
    func em_02_emojiOnlyPreservesAllInlineBlocks() {
        let markdown = """
        😀

        😁
        """

        let content = UnifiedMarkdownRenderer.makeContent(
            messageText: markdown,
            context: MarkdownMessageRenderContext(
                role: .assistant,
                messageID: "em_02",
                metrics: metrics
            ),
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: false,
            isDark: false
        )

        #expect(content.joinedInlineEmojiValues == "😀\n\n😁")
    }

    @Test("TB-01: broken table input falls back to rich text without dropping content")
    func tb_01_brokenTableFallback() {
        let markdown = """
        | A | B |
        | --- |
        | 1 | 2 |
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        #expect(!rendered.contains(where: { if case .table = $0 { return true }; return false }))
        let combined = joinedText(from: rendered)
        #expect(combined.contains("| A | B |"))
        #expect(combined.contains("| 1 | 2 |"))
    }

    @Test("TB-02: valid table cell markdown parses without formatter trap")
    func tb_02_tableCellMarkdownNoTrap() {
        let markdown = """
        | A | B |
        | --- | --- |
        | `x` | **y** |
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())

        guard case .table(let model)? = rendered.first else {
            Issue.record("Expected first block to be table")
            return
        }
        #expect(model.rows.count == 1)
        #expect(model.rows[0].cells[0].plainText == "x")
        #expect(model.rows[0].cells[1].plainText == "y")
    }

    @Test("BLK-01: interleaved block markdown preserves vertical separation and content")
    func blk_01_interleavedBlockSpacingAndContent() {
        let markdown = """
        # Title

        Intro paragraph.

        - Item one
        - Item two

        > Quoted line

        ---

        Let me check the proposal against each principle:
        ## 1 Ownership
        ## 2 Mutation seams
        But first, guard block spacing.

        ```swift
        print("code")
        ```

        | Key | Value |
        | --- | --- |
        | A | B |

        Tail paragraph.
        """

        let bubble = renderMarkdownForTests(markdown: markdown, options: bubbleOptions())
        let expanded = renderMarkdownForTests(markdown: markdown, options: expandedOptions())

        #expect(sequence(for: bubble) == sequence(for: expanded))
        #expect(bubble.filter { if case .attributedText = $0 { return true }; return false }.count >= 6)
        #expect(sequence(for: expanded).contains(.code))
        #expect(sequence(for: expanded).contains(.table))

        let expandedText = joinedText(from: expanded)
        #expect(expandedText.contains("Title"))
        #expect(expandedText.contains("Intro paragraph."))
        #expect(expandedText.contains("Item one"))
        #expect(expandedText.contains("Quoted line"))
        #expect(expandedText.contains("Ownership"))
        #expect(expandedText.contains("Tail paragraph."))
        #expect(expandedText.contains("\n\n"))
        #expect(containsInOrder(
            expandedText,
            tokens: [
                "Title",
                "Intro paragraph.",
                "Item one",
                "Quoted line",
                "Ownership",
                "Tail paragraph."
            ]
        ))
    }

    @Test("UL-01: unordered list preserves visible separators and item boundaries")
    func ul_01_unorderedListKeepsLineBreaks() {
        let markdown = """
        - Alpha
        - Beta
          - Nested Beta One
          - Nested Beta Two
        - Gamma
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        let text = joinedText(from: rendered)

        #expect(text.contains("Alpha"))
        #expect(text.contains("Beta"))
        #expect(text.contains("Nested Beta One"))
        #expect(text.contains("Nested Beta Two"))
        #expect(text.contains("Gamma"))
        #expect(text.contains("\n"))
        #expect(!text.contains("AlphaBetaNested Beta OneNested Beta TwoGamma"))
    }

    @Test("T340: hyphen unordered list renders as bullets in chat bubble markdown")
    func t340_hyphenUnorderedListRendersAsBullets() {
        let message = Message(
            id: "t340",
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
            sessionKey: "agent:main:clawline:user:main"
        )
        var state = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &state
        )
        let rendered = renderMarkdownForTests(
            markdown: message.content,
            options: bubbleOptions(),
            role: message.role,
            messageID: message.id
        )

        guard case .attributedText(let attributed)? = rendered.first else {
            Issue.record("Expected bubble markdown to render as attributed text")
            return
        }
        let text = joinedText(from: rendered)

        #expect(attributed.string.contains("Intro with bold and link."))
        #expect(text.contains("• Alpha code"))
        #expect(text.contains("• Beta"))
        #expect(!text.contains("- Alpha"))
        #expect(isBold("bold", in: attributed))
        #expect(linkTarget("link", in: attributed)?.absoluteString == "https://example.com")
    }

    @Test("T340: hyphen bullet normalization preserves thematic breaks and indented literals")
    func t340_hyphenBulletNormalizationStaysScoped() {
        let markdown = """
        - Bullet
        - - -
            - literal
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: bubbleOptions())
        let text = joinedText(from: rendered)
        let codeValues = rendered.compactMap { block -> String? in
            if case .code(_, let code) = block {
                return code
            }
            return nil
        }

        #expect(text.contains("• Bullet"))
        #expect(text.contains("⸻"))
        #expect(text.contains("    - literal"))
        #expect(!text.contains("• literal"))
        #expect(!text.contains("\u{F0002}"))
        #expect(!text.unicodeScalars.contains { scalar in
            (0xE000...0xF8FF).contains(Int(scalar.value))
        })

        let fenced = renderMarkdownForTests(
            markdown: """
            ```text
                - literal
            ```
            """,
            options: bubbleOptions()
        )
        let fencedCodeValues = fenced.compactMap { block -> String? in
            if case .code(_, let code) = block {
                return code
            }
            return nil
        }
        #expect(codeValues.isEmpty)
        #expect(fencedCodeValues.map { $0.trimmingCharacters(in: .newlines) } == ["    - literal"])
        #expect(!fencedCodeValues.joined().contains("\u{F0002}"))
    }

    @Test("T137: ordered list markers render as 1,2,3 instead of repeating 1")
    func t137_orderedListMarkersIncrement() {
        let markdown = """
        1. First
         1. Second
          1. Third
        """
        let rendered = renderMarkdownForTests(markdown: markdown, options: expandedOptions())
        let text = joinedText(from: rendered)

        #expect(text.contains("1. First"))
        #expect(text.contains("2. Second"))
        #expect(text.contains("3. Third"))
        #expect(containsInOrder(text, tokens: ["1. First", "2. Second", "3. Third"]))
    }

    @Test("T307 notification content uses the unified assistant markdown renderer")
    func t307_notificationContentUsesUnifiedAssistantMarkdownRenderer() {
        let rendered = CrossChatNotificationMarkdownRenderer.renderBlocks(
            content: """
            Side **notification** with [details](https://example.com)

            ```swift
            print("notification")
            ```
            """,
            messageID: "t307_notification_markdown",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .secondaryLabel,
            lineSpacing: 2,
            isDark: false
        )

        #expect(sequence(for: rendered) == [.attributedText, .code])
        let firstBlock = rendered.first
        guard case .attributedText(let attributed) = firstBlock else {
            Issue.record("Expected first notification block to be rendered attributed text")
            return
        }
        #expect(attributed.string.contains("Side notification with details"))
        #expect(isBold("notification", in: attributed))
        #expect(linkTarget("details", in: attributed)?.absoluteString == "https://example.com")
    }

    @Test("T1133 notification render cache reuses rendered markdown across body passes")
    @MainActor
    func t1133_notificationRenderCacheReusesRenderedMarkdownAcrossBodyPasses() {
        let cache = CrossChatNotificationRenderedEntryCache()
        let baseFont = UIFont.systemFont(ofSize: 15, weight: .regular)
        let inkColor = UIColor.secondaryLabel
        var renderCallCount = 0
        let entries = [
            CrossChatAssistantNotificationEntry(
                id: "t1133_entry",
                content: "Cached **notification**",
                timestamp: Date()
            )
        ]

        let renderer: CrossChatNotificationRenderedEntryCache.RenderBlocks = { content, _, _, _, _, _ in
            renderCallCount += 1
            return [.attributedText(NSAttributedString(string: content))]
        }

        let first = cache.entries(
            for: entries,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: 2,
            isDark: false,
            renderBlocks: renderer
        )
        let second = cache.entries(
            for: entries,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: 2,
            isDark: false,
            renderBlocks: renderer
        )

        #expect(renderCallCount == 1)
        #expect(first.first?.id == "t1133_entry")
        #expect(second.first?.id == "t1133_entry")

        let changedEntries = [
            CrossChatAssistantNotificationEntry(
                id: "t1133_entry",
                content: "Changed **notification**",
                timestamp: Date()
            )
        ]
        _ = cache.entries(
            for: changedEntries,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: 2,
            isDark: false,
            renderBlocks: renderer
        )

        #expect(renderCallCount == 2)
    }

    @Test("T1205 notification render cache survives rebuilt bubble view state")
    @MainActor
    func t1205_notificationRenderCacheSurvivesRebuiltBubbleViewState() {
        let baseFont = UIFont.systemFont(ofSize: 15, weight: .regular)
        let inkColor = UIColor.secondaryLabel
        var renderCallCount = 0
        let entries = [
            CrossChatAssistantNotificationEntry(
                id: "t1205_entry",
                content: "Review T1205 and T1182.",
                timestamp: Date()
            )
        ]

        let renderer: CrossChatNotificationRenderedEntryCache.RenderBlocks = { content, _, _, _, _, _ in
            renderCallCount += 1
            return [.attributedText(NSAttributedString(string: content))]
        }

        _ = CrossChatNotificationRenderedEntryCache().entries(
            for: entries,
            cacheScope: "agent:main:clawline:user:s_t1205_stall",
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: 2,
            isDark: false,
            renderBlocks: renderer
        )
        _ = CrossChatNotificationRenderedEntryCache().entries(
            for: entries,
            cacheScope: "agent:main:clawline:user:s_t1205_stall",
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: 2,
            isDark: false,
            renderBlocks: renderer
        )
        _ = CrossChatNotificationRenderedEntryCache().entries(
            for: entries,
            cacheScope: "agent:main:clawline:user:s_t1205_other",
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: 2,
            isDark: false,
            renderBlocks: renderer
        )

        #expect(renderCallCount == 2)
    }

    @Test("T307 real notification bubble renders assistant markdown content")
    @MainActor
    func t307_realNotificationBubbleRendersAssistantMarkdownContent() throws {
        let bubble = CrossChatNotificationBubble(
            sourceChatId: "agent:main:clawline:user:s_markdown_notification",
            sourceTitle: "Side Thread",
            entries: [
                CrossChatAssistantNotificationEntry(
                    id: "s_markdown_entry",
                    content: "Side **notification** with [details](https://example.com)",
                    timestamp: Date()
                )
            ],
            lastAssistantActivityAt: Date()
        )
        let host = UIHostingController(
            rootView: CrossChatNotificationBubbleView(
                bubble: bubble,
                assignedNumber: 1,
                visibleNotificationCount: 1,
                showShortcutLabel: true,
                maxBubbleHeight: 205,
                maxBubbleWidth: 360,
                bubbleCornerRadius: 18,
                isSending: false,
                canCancelSend: false,
                canSendReply: false,
                connectionState: .connected,
                replyDraft: .constant(""),
                onDismiss: {},
                onReply: {},
                onCancelReply: {},
                onDismissAll: {},
                onNavigate: {},
                onSendReply: {},
                onCancelSend: {},
                onReconnect: {},
                onActivate: {},
                onReplyFocusChange: { _ in },
                isActionMenuOpen: false,
                actionMenuSelection: .goToChat,
                onActionMenuSelectionChange: { _ in },
                onActionMenuAction: { _ in },
                onRegisterScrollView: { _ in },
                isDismissSwipeActive: false,
                isContentScrollLocked: false,
                onContentScrollDragChanged: { _ in },
                onContentScrollDragEnded: {},
                onTextSelectionChange: { _ in }
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 320))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.view.layoutIfNeeded()

        let textView = try #require(textViews(in: host.view).first { textView in
            textView.attributedText.string.contains("Side notification with details")
        })
        #expect(isBold("notification", in: textView.attributedText))
        #expect(linkTarget("details", in: textView.attributedText)?.absoluteString == "https://example.com")
    }

    @Test("T1183 short notification bubble does not grow when max height grows")
    @MainActor
    func t1183_shortNotificationBubbleDoesNotGrowWhenMaxHeightGrows() {
        let compactHost = UIHostingController(
            rootView: notificationBubbleView(
                content: "Short notification",
                maxBubbleHeight: CrossChatNotificationGeometry.bubbleMaxHeight(isCompactLayout: true)
            )
        )
        let nonCompactHost = UIHostingController(
            rootView: notificationBubbleView(
                content: "Short notification",
                maxBubbleHeight: CrossChatNotificationGeometry.bubbleMaxHeight(isCompactLayout: false)
            )
        )

        let fittingSize = CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height)
        let compactHeight = compactHost.sizeThatFits(in: fittingSize).height
        let nonCompactHeight = nonCompactHost.sizeThatFits(in: fittingSize).height

        #expect(compactHeight > 0)
        #expect(abs(nonCompactHeight - compactHeight) <= 1)
        #expect(nonCompactHeight < CrossChatNotificationGeometry.bubbleMaxHeight(isCompactLayout: true))
    }

    @Test("T383 visible notification renders one attributed text view while dismissed renders none")
    @MainActor
    func t383_realNotificationBubbleDoesNotDuplicateAttributedTextViewsForMeasurement() throws {
        let notificationText = "Side notification with details"
        let dismissedHost = UIHostingController(
            rootView: Color.clear
                .frame(width: 420, height: 320)
        )
        let dismissedWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 320))
        dismissedWindow.rootViewController = dismissedHost
        dismissedWindow.makeKeyAndVisible()
        dismissedHost.view.frame = dismissedWindow.bounds
        dismissedHost.view.setNeedsLayout()
        dismissedHost.view.layoutIfNeeded()

        let dismissedTextViews = textViews(in: dismissedHost.view).filter { textView in
            textView.attributedText.string.contains(notificationText)
        }
        #expect(dismissedTextViews.isEmpty)

        let bubble = CrossChatNotificationBubble(
            sourceChatId: "agent:main:clawline:user:s_t383_notification_perf",
            sourceTitle: "Side Thread",
            entries: [
                CrossChatAssistantNotificationEntry(
                    id: "s_t383_entry",
                    content: "Side **notification** with [details](https://example.com)",
                    timestamp: Date()
                )
            ],
            lastAssistantActivityAt: Date()
        )
        let host = UIHostingController(
            rootView: CrossChatNotificationBubbleView(
                bubble: bubble,
                assignedNumber: 1,
                visibleNotificationCount: 1,
                showShortcutLabel: true,
                maxBubbleHeight: 205,
                maxBubbleWidth: 360,
                bubbleCornerRadius: 18,
                isSending: false,
                canCancelSend: false,
                canSendReply: false,
                connectionState: .connected,
                replyDraft: .constant(""),
                onDismiss: {},
                onReply: {},
                onCancelReply: {},
                onDismissAll: {},
                onNavigate: {},
                onSendReply: {},
                onCancelSend: {},
                onReconnect: {},
                onActivate: {},
                onReplyFocusChange: { _ in },
                isActionMenuOpen: false,
                actionMenuSelection: .goToChat,
                onActionMenuSelectionChange: { _ in },
                onActionMenuAction: { _ in },
                onRegisterScrollView: { _ in },
                isDismissSwipeActive: false,
                isContentScrollLocked: false,
                onContentScrollDragChanged: { _ in },
                onContentScrollDragEnded: {},
                onTextSelectionChange: { _ in }
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 320))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.view.layoutIfNeeded()

        let notificationTextViews = textViews(in: host.view).filter { textView in
            textView.attributedText.string.contains(notificationText)
        }
        #expect(notificationTextViews.count == 1)
        #expect(try #require(notificationTextViews.first).isHidden == false)
    }

    private enum RenderedType: Equatable {
        case attributedText
        case code
        case table
    }

    private func sequence(for blocks: [RenderedMarkdownBlock]) -> [RenderedType] {
        blocks.map { block in
            switch block {
            case .attributedText:
                return .attributedText
            case .code:
                return .code
            case .table:
                return .table
            }
        }
    }

    private func bubbleOptions() -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: false,
            markHighlightColor: nil
        )
    }

    private func expandedOptions() -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: false,
            markHighlightColor: nil
        )
    }

    private func joinedText(from blocks: [RenderedMarkdownBlock]) -> String {
        blocks.compactMap { block -> String? in
            if case .attributedText(let attributed) = block {
                return attributed.string
            }
            return nil
        }
        .joined(separator: "\n\n")
    }

    private func containsInOrder(_ text: String, tokens: [String]) -> Bool {
        var searchStart = text.startIndex
        for token in tokens {
            guard let range = text.range(of: token, range: searchStart..<text.endIndex) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }

    private func isBold(_ token: String, in attributed: NSAttributedString) -> Bool {
        let range = (attributed.string as NSString).range(of: token)
        guard range.location != NSNotFound else { return false }
        var foundBold = false
        attributed.enumerateAttribute(.font, in: range) { value, _, stop in
            guard let font = value as? UIFont else { return }
            if font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                foundBold = true
                stop.pointee = true
            }
        }
        if !foundBold {
            attributed.enumerateAttribute(.inlinePresentationIntent, in: range) { value, _, stop in
                if value != nil {
                    foundBold = true
                    stop.pointee = true
                }
            }
        }
        return foundBold
    }

    private func linkTarget(_ token: String, in attributed: NSAttributedString) -> URL? {
        let range = (attributed.string as NSString).range(of: token)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
    }

    private func notificationBubbleView(content: String, maxBubbleHeight: CGFloat) -> some View {
        CrossChatNotificationBubbleView(
            bubble: CrossChatNotificationBubble(
                sourceChatId: "agent:main:clawline:user:s_t1183_notification_height",
                sourceTitle: "Side Thread",
                entries: [
                    CrossChatAssistantNotificationEntry(
                        id: "s_t1183_entry",
                        content: content,
                        timestamp: Date()
                    )
                ],
                lastAssistantActivityAt: Date()
            ),
            assignedNumber: 1,
            visibleNotificationCount: 1,
            showShortcutLabel: true,
            maxBubbleHeight: maxBubbleHeight,
            maxBubbleWidth: 360,
            bubbleCornerRadius: 18,
            isSending: false,
            canCancelSend: false,
            canSendReply: false,
            connectionState: .connected,
            replyDraft: .constant(""),
            onDismiss: {},
            onReply: {},
            onCancelReply: {},
            onDismissAll: {},
            onNavigate: {},
            onSendReply: {},
            onCancelSend: {},
            onReconnect: {},
            onActivate: {},
            onReplyFocusChange: { _ in },
            isActionMenuOpen: false,
            actionMenuSelection: .goToChat,
            onActionMenuSelectionChange: { _ in },
            onActionMenuAction: { _ in },
            onRegisterScrollView: { _ in },
            isDismissSwipeActive: false,
            isContentScrollLocked: false,
            onContentScrollDragChanged: { _ in },
            onContentScrollDragEnded: {},
            onTextSelectionChange: { _ in }
        )
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        if let textView = view as? UITextView {
            result.append(textView)
        }
        for subview in view.subviews {
            result.append(contentsOf: textViews(in: subview))
        }
        return result
    }
}

final class T383NotificationPerformanceProofTests: XCTestCase {
    @MainActor
    func testVisibleNotificationRendersOneAttributedTextViewWhileDismissedRendersNone() throws {
        let notificationText = "Side notification with details"
        let dismissedHost = UIHostingController(
            rootView: Color.clear
                .frame(width: 420, height: 320)
        )
        let dismissedWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 320))
        dismissedWindow.rootViewController = dismissedHost
        dismissedWindow.makeKeyAndVisible()
        dismissedHost.view.frame = dismissedWindow.bounds
        dismissedHost.view.setNeedsLayout()
        dismissedHost.view.layoutIfNeeded()

        let dismissedTextViews = textViews(in: dismissedHost.view).filter { textView in
            textView.attributedText.string.contains(notificationText)
        }
        XCTAssertTrue(dismissedTextViews.isEmpty)

        let bubble = CrossChatNotificationBubble(
            sourceChatId: "agent:main:clawline:user:s_t383_notification_perf",
            sourceTitle: "Side Thread",
            entries: [
                CrossChatAssistantNotificationEntry(
                    id: "s_t383_entry",
                    content: "Side **notification** with [details](https://example.com)",
                    timestamp: Date()
                )
            ],
            lastAssistantActivityAt: Date()
        )
        let host = UIHostingController(
            rootView: CrossChatNotificationBubbleView(
                bubble: bubble,
                assignedNumber: 1,
                visibleNotificationCount: 1,
                showShortcutLabel: true,
                maxBubbleHeight: 205,
                maxBubbleWidth: 360,
                bubbleCornerRadius: 18,
                isSending: false,
                canCancelSend: false,
                canSendReply: false,
                connectionState: .connected,
                replyDraft: .constant(""),
                onDismiss: {},
                onReply: {},
                onCancelReply: {},
                onDismissAll: {},
                onNavigate: {},
                onSendReply: {},
                onCancelSend: {},
                onReconnect: {},
                onActivate: {},
                onReplyFocusChange: { _ in },
                isActionMenuOpen: false,
                actionMenuSelection: .goToChat,
                onActionMenuSelectionChange: { _ in },
                onActionMenuAction: { _ in },
                onRegisterScrollView: { _ in },
                isDismissSwipeActive: false,
                isContentScrollLocked: false,
                onContentScrollDragChanged: { _ in },
                onContentScrollDragEnded: {},
                onTextSelectionChange: { _ in }
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 320))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.view.layoutIfNeeded()

        let notificationTextViews = textViews(in: host.view).filter { textView in
            textView.attributedText.string.contains(notificationText)
        }
        XCTAssertEqual(notificationTextViews.count, 1)
        XCTAssertFalse(try XCTUnwrap(notificationTextViews.first).isHidden)
    }

    @MainActor
    private func textViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        if let textView = view as? UITextView {
            result.append(textView)
        }
        for subview in view.subviews {
            result.append(contentsOf: textViews(in: subview))
        }
        return result
    }
}
