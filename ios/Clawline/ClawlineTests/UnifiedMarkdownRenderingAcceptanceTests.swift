import Testing
import UIKit
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

        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r48_01", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.richText, .code, .richText, .table, .richText])

        let bubble = UnifiedMarkdownRenderer.render(plan: plan, options: bubbleOptions())
        let expanded = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        #expect(sequence(for: bubble) == [.attributedText, .code, .attributedText, .table, .attributedText])
        #expect(sequence(for: expanded) == [.attributedText, .code, .attributedText, .table, .attributedText])
    }

    @Test("R48-02: expanded path keeps all markdown blocks")
    func r48_02_noDroppedExpandedBlocks() {
        let markdown = (1...80)
            .map { "Paragraph \($0) with **markdown** and https://example.com/\($0)" }
            .joined(separator: "\n\n")
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r48_02", metrics: metrics)

        let bubble = UnifiedMarkdownRenderer.render(plan: plan, options: bubbleOptions())
        let expanded = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        #expect(bubble.count == expanded.count)
        #expect(expanded.count == plan.blocks.count)
    }

    @Test("R48-03: bubble and expanded share one plan; options-only divergence")
    func r48_03_surfaceDifferenceIsOptionsOnly() {
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
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r48_03", metrics: metrics)

        let bubble = UnifiedMarkdownRenderer.render(plan: plan, options: bubbleOptions())
        let expanded = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        #expect(sequence(for: bubble) == sequence(for: expanded))

        let bubbleText = joinedText(from: bubble)
        let expandedText = joinedText(from: expanded)
        #expect(!bubbleText.contains("https://one.example"))
        #expect(expandedText.contains("https://one.example"))
    }

    @Test("R50-01: fenced code with language does not regress to plain text")
    func r50_01_standardFence() {
        let markdown = """
        ```swift
        print("hello")
        ```

        trailing prose
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r50_01", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.code, .richText])
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
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r50_02", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.richText, .code, .richText])
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

        let validPlan = UnifiedMarkdownParser.parse(markdown: valid, messageID: "r50_03_valid", metrics: metrics)
        let invalidPlan = UnifiedMarkdownParser.parse(markdown: invalid, messageID: "r50_03_invalid", metrics: metrics)
        #expect(sequence(for: validPlan.blocks) == [.code])
        #expect(sequence(for: invalidPlan.blocks) == [.richText])
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
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "r50_04", metrics: metrics)
        #expect(sequence(for: plan.blocks) == [.richText, .code, .richText, .code, .richText])
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
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "hl_01", metrics: metrics)
        let rendered = UnifiedMarkdownRenderer.render(
            plan: plan,
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

    @Test("EM-01: parser emoji-only metric is limited to 1-3 emoji characters")
    func em_01_parserEmojiOnlyBounds() {
        let three = UnifiedMarkdownParser.parse(markdown: "😀😁😂", messageID: "em_01_3", metrics: metrics)
        #expect(three.isEmojiOnly)

        let four = UnifiedMarkdownParser.parse(markdown: "😀😁😂🤣", messageID: "em_01_4", metrics: metrics)
        #expect(!four.isEmojiOnly)
    }

    @Test("TB-01: broken table input falls back to rich text without dropping content")
    func tb_01_brokenTableFallback() {
        let markdown = """
        | A | B |
        | --- |
        | 1 | 2 |
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "tb_01", metrics: metrics)
        #expect(!plan.blocks.contains(where: { if case .table = $0 { return true }; return false }))
        let combined = plan.blocks.compactMap { block -> String? in
            if case .richText(let source) = block { return source }
            return nil
        }.joined(separator: "\n")
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
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "tb_02", metrics: metrics)

        guard case .table(let model)? = plan.blocks.first else {
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

        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "blk_01", metrics: metrics)
        let bubble = UnifiedMarkdownRenderer.render(plan: plan, options: bubbleOptions())
        let expanded = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())

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
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "ul_01", metrics: metrics)
        let rendered = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        let text = joinedText(from: rendered)

        #expect(text.contains("Alpha"))
        #expect(text.contains("Beta"))
        #expect(text.contains("Nested Beta One"))
        #expect(text.contains("Nested Beta Two"))
        #expect(text.contains("Gamma"))
        #expect(text.contains("\n"))
        #expect(!text.contains("AlphaBetaNested Beta OneNested Beta TwoGamma"))
    }

    @Test("T137: ordered list markers render as 1,2,3 instead of repeating 1")
    func t137_orderedListMarkersIncrement() {
        let markdown = """
        1. First
         1. Second
          1. Third
        """
        let plan = UnifiedMarkdownParser.parse(markdown: markdown, messageID: "t137", metrics: metrics)
        let rendered = UnifiedMarkdownRenderer.render(plan: plan, options: expandedOptions())
        let text = joinedText(from: rendered)

        #expect(text.contains("1. First"))
        #expect(text.contains("2. Second"))
        #expect(text.contains("3. Third"))
        #expect(containsInOrder(text, tokens: ["1. First", "2. Second", "3. Third"]))
    }

    private enum BlockType: Equatable {
        case richText
        case code
        case table
    }

    private enum RenderedType: Equatable {
        case attributedText
        case code
        case table
    }

    private func sequence(for blocks: [MarkdownRenderBlock]) -> [BlockType] {
        blocks.map { block in
            switch block {
            case .richText:
                return .richText
            case .code:
                return .code
            case .table:
                return .table
            }
        }
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
            stripDetectedURLs: true,
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
}
