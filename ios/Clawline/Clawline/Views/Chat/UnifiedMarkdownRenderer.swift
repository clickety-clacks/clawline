import Foundation
import Markdown
import UIKit

private enum MarkdownRenderBlock: Equatable {
    case richText(markdownSource: String)
    case code(language: String?, code: String)
    case table(TableModel)
}

private struct MarkdownRenderPlan: Equatable {
    let blocks: [MarkdownRenderBlock]
    let plainTextForMetrics: String
    let containsTextualContent: Bool
    let isEmojiOnly: Bool

    nonisolated static let empty = MarkdownRenderPlan(
        blocks: [],
        plainTextForMetrics: "",
        containsTextualContent: false,
        isEmojiOnly: false
    )
}

struct UnifiedMarkdownContent {
    let renderedBlocks: [RenderedMarkdownBlock]
    let inlineEmojiValues: [String]

    var firstInlineEmojiValue: String? {
        inlineEmojiValues.first
    }

    var firstAttributedText: NSAttributedString? {
        renderedBlocks.compactMap { block -> NSAttributedString? in
            guard case .attributedText(let attributed) = block else { return nil }
            return attributed
        }.first
    }

    var joinedInlineEmojiValues: String? {
        guard !inlineEmojiValues.isEmpty else { return nil }
        return inlineEmojiValues.joined(separator: "\n\n")
    }

    var hasNonEmptyAttributedText: Bool {
        renderedBlocks.contains { block in
            guard case .attributedText(let attributed) = block else { return false }
            return !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasCodeOrTable: Bool {
        renderedBlocks.contains { block in
            if case .code = block { return true }
            if case .table = block { return true }
            return false
        }
    }

    var hasRenderableMarkdownContent: Bool {
        hasNonEmptyAttributedText || hasCodeOrTable
    }
}

private enum UnifiedMarkdownParser {
    nonisolated private static let maxColumns = 40
    nonisolated private static let maxCellsPerMessage = 400
    nonisolated private static let minimumCommonCodeIndentToTrim = 20
    nonisolated private static let fenceInvisibleScalars: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
    nonisolated private static let tablePipeSentinel = "\u{E000}"

    nonisolated static func parse(markdown: String, messageID: String, metrics: ChatFlowTheme.Metrics) -> MarkdownRenderPlan {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        let normalizedMarkdown = normalizeFenceLines(in: markdown)
        let protectedMarkdown = protectInlineCodePipesInTableRows(in: normalizedMarkdown)
        if containsUnclosedCodeFence(in: protectedMarkdown) {
            return planFromRichTextOnly(protectedMarkdown)
        }

        let document = Document(parsing: protectedMarkdown)
        var blocks: [MarkdownRenderBlock] = []

        func appendRichText(_ source: String) {
            let restored = restoreProtectedPipes(in: source)
            let trimmed = restored.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(.richText(markdownSource: trimmed))
            }
        }

        for child in document.children {
            if let code = child as? CodeBlock {
                blocks.append(
                    .code(
                        language: normalizedLanguage(code.language),
                        code: normalizeCodeBlockIndent(in: restoreProtectedPipes(in: code.code))
                    )
                )
                continue
            }

            if let table = child as? Table {
                if let model = buildTableModel(from: table, messageID: messageID, metrics: metrics) {
                    blocks.append(.table(model))
                } else {
                    appendRichText(child.format())
                }
                continue
            }

            appendRichText(child.format())
        }

        let plainTextForMetrics = blocks
            .map(plainText(from:))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let containsTextualContent = !plainTextForMetrics.isEmpty
        let isEmojiOnly = containsTextualContent && blocks.allSatisfy { block in
            switch block {
            case .richText(let source):
                return EmojiOnlyClassifier.isEmojiOnly(markdownPlainText(from: source))
            case .code, .table:
                return false
            }
        }

        return MarkdownRenderPlan(
            blocks: blocks,
            plainTextForMetrics: plainTextForMetrics,
            containsTextualContent: containsTextualContent,
            isEmojiOnly: isEmojiOnly
        )
    }

    nonisolated private static func planFromRichTextOnly(_ markdown: String) -> MarkdownRenderPlan {
        let restored = restoreProtectedPipes(in: markdown)
        let trimmed = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let plainTextForMetrics = markdownPlainText(from: trimmed)
        let containsTextualContent = !plainTextForMetrics.isEmpty
        let isEmojiOnly = containsTextualContent && EmojiOnlyClassifier.isEmojiOnly(plainTextForMetrics)

        return MarkdownRenderPlan(
            blocks: [.richText(markdownSource: trimmed)],
            plainTextForMetrics: plainTextForMetrics,
            containsTextualContent: containsTextualContent,
            isEmojiOnly: isEmojiOnly
        )
    }

    nonisolated private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func plainText(from block: MarkdownRenderBlock) -> String {
        switch block {
        case .richText(let source):
            return markdownPlainText(from: source)
        case .code(_, let code):
            return code.trimmingCharacters(in: .whitespacesAndNewlines)
        case .table(let model):
            var components: [String] = []
            if let header = model.header {
                components.append(contentsOf: header.map(\.plainText))
            }
            for row in model.rows {
                components.append(contentsOf: row.cells.map(\.plainText))
            }
            return components.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    nonisolated private static func markdownPlainText(from source: String) -> String {
        let source = displayMarkdown(fromPreprocessedMarkdown: source)
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        ) {
            return NSAttributedString(attributed).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func buildTableModel(
        from table: Table,
        messageID: String,
        metrics: ChatFlowTheme.Metrics
    ) -> TableModel? {
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows)

        guard !headerCells.isEmpty, !bodyRows.isEmpty else {
            return nil
        }

        let columnCount = headerCells.count
        guard columnCount <= maxColumns else {
            return nil
        }

        var totalCellCount = 0

        let headerCellMarkdowns = normalizeTableCellMarkdowns(
            headerCells.map(tableCellMarkdown(from:)),
            expectedCount: columnCount
        )
        guard headerCellMarkdowns.count == columnCount else {
            return nil
        }

        let headerModels = headerCellMarkdowns.map { markdown in
            totalCellCount += 1
            return makeCell(from: markdown, metrics: metrics)
        }

        var rows: [TableModel.Row] = []
        for (rowIndex, row) in bodyRows.enumerated() {
            let cells = Array(row.cells)
            guard cells.count == columnCount else {
                return nil
            }

            let rowCellMarkdowns = normalizeTableCellMarkdowns(
                cells.map(tableCellMarkdown(from:)),
                expectedCount: columnCount
            )
            guard rowCellMarkdowns.count == columnCount else {
                return nil
            }

            var rowModels: [TableModel.Cell] = []
            rowModels.reserveCapacity(rowCellMarkdowns.count)
            for markdown in rowCellMarkdowns {
                if totalCellCount >= maxCellsPerMessage {
                    break
                }
                totalCellCount += 1
                rowModels.append(makeCell(from: markdown, metrics: metrics))
            }

            guard rowModels.count == columnCount else { break }
            let rowID = TableModel.makeRowIdentifier(
                messageID: messageID,
                rowIndex: rowIndex,
                cells: rowModels.map(\.plainText)
            )
            rows.append(TableModel.Row(id: rowID, cells: rowModels))

            if totalCellCount >= maxCellsPerMessage {
                break
            }
        }

        guard !rows.isEmpty else { return nil }

        let columns = (0..<columnCount).map { index -> TableModel.Column in
            let alignment = (index < table.columnAlignments.count) ? table.columnAlignments[index] : nil
            return TableModel.Column(alignment: mapAlignment(alignment))
        }

        return TableModel(
            columns: columns,
            header: headerModels,
            rows: rows,
            messageID: messageID,
            rowOffset: 0
        )
    }

    nonisolated private static func mapAlignment(_ alignment: Table.ColumnAlignment?) -> ColumnAlignment {
        switch alignment {
        case .center:
            return .center
        case .right:
            return .trailing
        case .left, .none:
            return .leading
        }
    }

    nonisolated private static func makeCell(from markdown: String, metrics: ChatFlowTheme.Metrics) -> TableModel.Cell {
        let markdown = displayMarkdown(fromPreprocessedMarkdown: markdown)
        let attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(markdown)
        }

        let plainText = NSAttributedString(attributed).string.trimmingCharacters(in: .whitespacesAndNewlines)
        return TableModel.Cell(
            attributed: attributed,
            intrinsicWidth: intrinsicWidth(for: plainText, metrics: metrics),
            plainText: plainText,
            isEmpty: plainText.isEmpty
        )
    }

    nonisolated private static func displayMarkdown(fromPreprocessedMarkdown markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\u{F0000}", with: "")
            .replacingOccurrences(of: "\u{F0001}", with: "")
            .replacingOccurrences(of: UnifiedMarkdownRenderer.indentedLiteralSentinel, with: "")
    }

    nonisolated private static func tableCellMarkdown(from cell: Table.Cell) -> String {
        let source = cell.children
            .map { $0.format() }
            .joined()
            .replacingOccurrences(of: tablePipeSentinel, with: "|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            return source
        }
        return cell.plainText
            .replacingOccurrences(of: tablePipeSentinel, with: "|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizeTableCellMarkdowns(_ cells: [String], expectedCount: Int) -> [String] {
        guard !cells.isEmpty else { return cells }

        var merged: [String] = []
        merged.reserveCapacity(cells.count)
        var index = 0

        while index < cells.count {
            var candidate = cells[index]
            while hasUnbalancedInlineCodeDelimiter(candidate), index + 1 < cells.count {
                index += 1
                candidate += " | " + cells[index]
            }
            merged.append(candidate)
            index += 1
        }

        if merged.count < expectedCount {
            return merged + Array(repeating: "", count: expectedCount - merged.count)
        }
        return merged
    }

    nonisolated private static func hasUnbalancedInlineCodeDelimiter(_ source: String) -> Bool {
        var openDelimiterLength: Int?
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "`" {
                var end = source.index(after: index)
                while end < source.endIndex, source[end] == "`" {
                    end = source.index(after: end)
                }
                let runLength = source.distance(from: index, to: end)
                if let open = openDelimiterLength {
                    if open == runLength {
                        openDelimiterLength = nil
                    }
                } else {
                    openDelimiterLength = runLength
                }
                index = end
                continue
            }
            index = source.index(after: index)
        }
        return openDelimiterLength != nil
    }

    nonisolated private static func normalizeFenceLines(in markdown: String) -> String {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let hasTrailingNewline = markdown.last?.isNewline == true
        let normalized = lines.map { normalizeFenceLine(String($0)) }
        if hasTrailingNewline {
            return normalized.joined(separator: "\n") + "\n"
        }
        return normalized.joined(separator: "\n")
    }

    nonisolated private static func normalizeFenceLine(_ line: String) -> String {
        let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" })
        let remainder = line.dropFirst(leadingSpaces.count)
        guard let marker = remainder.first, marker == "`" || marker == "~" else {
            return line
        }

        var consumed = 0
        var markerCount = 0
        for char in remainder {
            if char == marker {
                markerCount += 1
                consumed += 1
                continue
            }
            if fenceInvisibleScalars.contains(char) {
                consumed += 1
                continue
            }
            break
        }

        guard markerCount >= 3 else { return line }
        let suffix = remainder.dropFirst(consumed)
        return String(leadingSpaces) + String(repeating: String(marker), count: markerCount) + suffix
    }

    nonisolated private static func protectInlineCodePipesInTableRows(in markdown: String) -> String {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let hasTrailingNewline = markdown.last?.isNewline == true
        var openFence: (marker: Character, count: Int)?
        var transformed: [String] = []
        transformed.reserveCapacity(lines.count)

        for rawLine in lines {
            let line = String(rawLine)
            let token = fenceToken(in: line)

            if let activeFence = openFence {
                transformed.append(line)
                if let token,
                   token.marker == activeFence.marker,
                   token.count >= activeFence.count,
                   token.isClosing {
                    openFence = nil
                }
                continue
            }

            if let token {
                openFence = (marker: token.marker, count: token.count)
                transformed.append(line)
                continue
            }

            transformed.append(protectInlineCodePipesInTableLine(line))
        }

        if hasTrailingNewline {
            return transformed.joined(separator: "\n") + "\n"
        }
        return transformed.joined(separator: "\n")
    }

    nonisolated private static func protectInlineCodePipesInTableLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), line.contains("|"), line.contains("`") else {
            return line
        }

        var result = ""
        result.reserveCapacity(line.count)
        var openDelimiterLength: Int?
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "`" {
                var end = line.index(after: index)
                while end < line.endIndex, line[end] == "`" {
                    end = line.index(after: end)
                }
                let runLength = line.distance(from: index, to: end)
                if let activeDelimiterLength = openDelimiterLength {
                    if activeDelimiterLength == runLength {
                        openDelimiterLength = nil
                    }
                } else {
                    openDelimiterLength = runLength
                }
                result += String(line[index..<end])
                index = end
                continue
            }

            if char == "|", openDelimiterLength != nil {
                result += tablePipeSentinel
            } else {
                result.append(char)
            }
            index = line.index(after: index)
        }
        return result
    }

    nonisolated private static func normalizeCodeBlockIndent(in code: String) -> String {
        let lines = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let commonIndent = lines
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { leadingCodeIndentWidth(for: $0) }
            .min() ?? 0

        guard commonIndent >= minimumCommonCodeIndentToTrim else {
            return code
        }

        let hasTrailingNewline = code.last?.isNewline == true
        let normalized = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return String(line)
            }
            return String(line.dropFirst(min(commonIndent, leadingCodeIndentWidth(for: line))))
        }

        if hasTrailingNewline {
            return normalized.joined(separator: "\n") + "\n"
        }
        return normalized.joined(separator: "\n")
    }

    nonisolated private static func leadingCodeIndentWidth<S: StringProtocol>(for line: S) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    nonisolated private static func restoreProtectedPipes(in source: String) -> String {
        source.replacingOccurrences(of: tablePipeSentinel, with: "|")
    }

    nonisolated private static func containsUnclosedCodeFence(in markdown: String) -> Bool {
        struct FenceState {
            let marker: Character
            let count: Int
        }

        var openFence: FenceState?
        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let token = fenceToken(in: line) else { continue }

            if let activeFence = openFence {
                if token.marker == activeFence.marker,
                   token.count >= activeFence.count,
                   token.isClosing {
                    openFence = nil
                }
                continue
            }

            openFence = FenceState(marker: token.marker, count: token.count)
        }

        return openFence != nil
    }

    nonisolated private static func fenceToken(in line: String) -> (marker: Character, count: Int, isClosing: Bool)? {
        let leadingSpaceCount = line.prefix(while: { $0 == " " }).count
        guard leadingSpaceCount <= 3 else { return nil }

        let trimmed = line.dropFirst(leadingSpaceCount)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }

        var runCount = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == marker {
            runCount += 1
            index = trimmed.index(after: index)
        }
        guard runCount >= 3 else { return nil }

        let trailing = trimmed[index...]
        let isClosing = trailing.allSatisfy { $0 == " " || $0 == "\t" }
        if marker == "`", !isClosing, trailing.contains("`") {
            return nil
        }
        return (marker: marker, count: runCount, isClosing: isClosing)
    }

    nonisolated private static func intrinsicWidth(for text: String, metrics: ChatFlowTheme.Metrics) -> CGFloat {
        _ = metrics
        let scaledFont = UIFont.clawline(.bodyText)
        let width = (text as NSString).size(withAttributes: [.font: scaledFont]).width
        return ceil(width)
    }
}

struct MarkdownMessageRenderContext {
    let role: Message.Role
    let messageID: String
    let metrics: ChatFlowTheme.Metrics
}

enum UnifiedMarkdownRenderer {
    nonisolated private static let markOpenSentinel = "\u{F0000}"
    nonisolated private static let markCloseSentinel = "\u{F0001}"
    nonisolated fileprivate static let indentedLiteralSentinel = "\u{F0002}"
    nonisolated private static let markdownLinkBoundaryTokens = [markOpenSentinel, markCloseSentinel]
    private static let attributedMarkdownCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 512
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private static let attributedMarkdownCacheMaxSourceLength = 20_000

    private static func makeOptions(
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        stripDetectedURLs: Bool,
        role: Message.Role,
        isDark: Bool
    ) -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: stripDetectedURLs,
            markHighlightColor: SalientHighlightApplier.highlightColor(isDark: isDark)
        )
    }

    static func makeContent(
        messageText: String,
        context: MarkdownMessageRenderContext,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        stripDetectedURLs: Bool,
        isDark: Bool
    ) -> UnifiedMarkdownContent {
        let plan = makeRenderPlan(messageText: messageText, context: context)
        let renderedBlocks = render(
            plan: plan,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: stripDetectedURLs,
            role: context.role,
            isDark: isDark
        )
        return UnifiedMarkdownContent(
            renderedBlocks: renderedBlocks,
            inlineEmojiValues: inlineEmojiValues(from: plan)
        )
    }

    private static func makeRenderPlan(
        messageText: String,
        context: MarkdownMessageRenderContext
    ) -> MarkdownRenderPlan {
        UnifiedMarkdownParser.parse(
            markdown: preprocessClawlineMarkdownDialect(messageText),
            messageID: context.messageID,
            metrics: context.metrics
        )
    }

    private static func render(
        plan: MarkdownRenderPlan,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        stripDetectedURLs: Bool,
        role: Message.Role,
        isDark: Bool
    ) -> [RenderedMarkdownBlock] {
        let options = makeOptions(
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: stripDetectedURLs,
            role: role,
            isDark: isDark
        )
        return render(plan: plan, options: options)
    }

    static func configureTextView(
        _ textView: UITextView,
        delegate: UITextViewDelegate?,
        linkTextAttributes: [NSAttributedString.Key: Any] = [:],
        enableDataDetectors: Bool = false
    ) {
        textView.backgroundColor = .clear
        textView.isUserInteractionEnabled = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = enableDataDetectors ? [.link] : []
        textView.delegate = delegate
        textView.linkTextAttributes = linkTextAttributes
    }

    @available(iOS 17.0, macCatalyst 17.0, visionOS 1.0, *)
    @MainActor
    static func primaryActionForTextItem(
        _ textItem: UITextItem,
        defaultAction: UIAction,
        openURL: @escaping (URL, NSRange) -> Void
    ) -> UIAction? {
        guard case .link(let url) = textItem.content else {
            return defaultAction
        }
        return UIAction { _ in
            openURL(url, textItem.range)
        }
    }

    private static func render(
        plan: MarkdownRenderPlan,
        options: MarkdownRenderOptions
    ) -> [RenderedMarkdownBlock] {
        plan.blocks.compactMap { block in
            switch block {
            case .richText(let markdownSource):
                let attributed = renderNSAttributedString(
                    markdown: markdownSource,
                    baseFont: options.baseFont,
                    inkColor: options.inkColor,
                    lineSpacing: options.lineSpacing,
                    markHighlightColor: options.markHighlightColor
                ) ?? NSAttributedString(
                    string: markdownSource,
                    attributes: baseAttributes(
                        baseFont: options.baseFont,
                        inkColor: options.inkColor,
                        lineSpacing: options.lineSpacing
                    )
                )

                let cleaned = options.stripDetectedURLs
                    ? stripDetectedLinks(from: attributed)
                    : attributed
                return .attributedText(cleaned)
            case .code(let language, let code):
                return .code(language: language, code: code)
            case .table(let model):
                return .table(model)
            }
        }
    }

    private static func renderNSAttributedString(
        markdown: String,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        markHighlightColor: UIColor? = nil
    ) -> NSAttributedString? {
        let parsedMarkdown = preprocessClawlineMarkdownDialect(markdown)

        // UIKit rendering relies on concrete line breaks in the backing string. Ordered lists parsed
        // with `.full` collapse separators into presentation intents, which become run-on text.
        let hasOrderedListSyntax = parsedMarkdown.range(
            of: #"(?m)^\s*\d+[.)]\s+"#,
            options: .regularExpression
        ) != nil
        let hasUnorderedListSyntax = parsedMarkdown.range(
            of: #"(?m)^[ \t]*[-*+]\s+"#,
            options: .regularExpression
        ) != nil
        let shouldUseInlineListParsing = hasOrderedListSyntax || hasUnorderedListSyntax
        var markdownForRender = parsedMarkdown
        if hasOrderedListSyntax {
            markdownForRender = normalizeOrderedListMarkers(in: markdownForRender)
        }
        if hasUnorderedListSyntax {
            markdownForRender = normalizeHyphenUnorderedListMarkers(in: markdownForRender)
        }
        let cacheKey = attributedMarkdownCacheKey(
            markdown: markdownForRender,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            markHighlightColor: markHighlightColor,
            textLinkRulesComponent: TextLinkURLTemplateRules.cacheKeyComponent
        )
        if let cached = attributedMarkdownCache.object(forKey: cacheKey as NSString) {
            return NSAttributedString(attributedString: cached)
        }

        // Prefer full parsing (block syntax like headings), but keep list separators intact.
        let nsAttributed: NSMutableAttributedString
        if shouldUseInlineListParsing,
           let inline = try? AttributedString(markdown: markdownForRender, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            nsAttributed = NSMutableAttributedString(inline)
        } else if let full = try? AttributedString(markdown: markdownForRender, options: .init(interpretedSyntax: .full)) {
            nsAttributed = NSMutableAttributedString(full)
        } else if let inline = try? AttributedString(markdown: markdownForRender, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            nsAttributed = NSMutableAttributedString(inline)
        } else {
            return nil
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left
        let immutableParagraph = paragraph.copy() as? NSParagraphStyle ?? paragraph

        let fullRange = NSRange(location: 0, length: nsAttributed.length)
        nsAttributed.addAttribute(.foregroundColor, value: inkColor, range: fullRange)
        nsAttributed.addAttribute(.paragraphStyle, value: immutableParagraph, range: fullRange)

        nsAttributed.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let existingFont = value as? UIFont else {
                nsAttributed.addAttribute(.font, value: baseFont, range: range)
                return
            }

            var traits = existingFont.fontDescriptor.symbolicTraits
            let inlineIntent = nsAttributed.attribute(.inlinePresentationIntent, at: range.location, effectiveRange: nil) as? NSNumber
            if let rawIntent = inlineIntent?.uintValue {
                if (rawIntent & InlinePresentationIntent.stronglyEmphasized.rawValue) != 0 {
                    traits.insert(.traitBold)
                }
                if (rawIntent & InlinePresentationIntent.emphasized.rawValue) != 0 {
                    traits.insert(.traitItalic)
                }
                if (rawIntent & InlinePresentationIntent.code.rawValue) != 0 {
                    traits.insert(.traitMonoSpace)
                }
            }
            let size = baseFont.pointSize
            var newFont = UIFont(descriptor: baseFont.fontDescriptor, size: size)

            if traits.contains(.traitBold) && traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitBold) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitMonoSpace) {
                newFont = UIFont.clawlineMonospaced(.secondaryLabel, weight: .regular)
                nsAttributed.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: range)
            }

            nsAttributed.addAttribute(.font, value: newFont, range: range)
        }

        annotateDetectedLinks(nsAttributed)
        sanitizeLinkAttributes(nsAttributed)
        _ = TextLinkURLTemplateRules.applyConfiguredRules(to: nsAttributed)
        applyHeadingStyles(markdown: markdownForRender, nsAttributed: nsAttributed, baseFont: baseFont)
        applyMarkHighlights(nsAttributed: nsAttributed, color: markHighlightColor)

        let rendered = NSAttributedString(attributedString: nsAttributed)
        if markdownForRender.count <= attributedMarkdownCacheMaxSourceLength {
            attributedMarkdownCache.setObject(
                rendered,
                forKey: cacheKey as NSString,
                cost: attributedMarkdownCacheCost(markdown: markdownForRender, rendered: rendered)
            )
        }
        return rendered
    }

    nonisolated private static func attributedMarkdownCacheKey(
        markdown: String,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        markHighlightColor: UIColor?,
        textLinkRulesComponent: String
    ) -> String {
        [
            markdown,
            baseFont.fontDescriptor.postscriptName,
            String(format: "%.3f", baseFont.pointSize),
            String(format: "%.3f", lineSpacing),
            colorCacheComponent(inkColor),
            markHighlightColor.map(colorCacheComponent) ?? "nil",
            textLinkRulesComponent
        ].joined(separator: "\u{1F}")
    }

    nonisolated private static func colorCacheComponent(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let identity = "\(type(of: color))|\(String(describing: color))"
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return identity
        }
        return identity + "|" + String(format: "%.5f,%.5f,%.5f,%.5f", red, green, blue, alpha)
    }

    nonisolated private static func attributedMarkdownCacheCost(markdown: String, rendered: NSAttributedString) -> Int {
        (markdown.utf16.count + rendered.string.utf16.count) * 2
    }

    private static func baseAttributes(baseFont: UIFont, inkColor: UIColor, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left
        return [
            .font: baseFont,
            .foregroundColor: inkColor,
            .paragraphStyle: paragraph
        ]
    }

    private static let detectedLinkStripper: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func annotateDetectedLinks(_ attributed: NSMutableAttributedString) {
        guard let detector = detectedLinkStripper else { return }
        let text = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let matches = detector.matches(in: attributed.string, options: [], range: fullRange)

        for match in matches {
            guard match.resultType == .link else { continue }
            guard attributed.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let rawMatch = text.substring(with: match.range)
            let url = MarkdownURLBoundarySanitizer.sanitizedURL(
                from: rawMatch,
                additionalBoundaryTokens: markdownLinkBoundaryTokens
            ) ?? match.url
            guard let url else { continue }
            attributed.addAttribute(.link, value: url, range: match.range)
        }
    }

    private static func sanitizeLinkAttributes(_ attributed: NSMutableAttributedString) {
        let text = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        var updates: [(range: NSRange, trimmedLength: Int, url: URL)] = []

        attributed.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            guard let rawValue = value else { return }
            let displayedText = text.substring(with: range)
            let currentURL: URL? = {
                if let url = rawValue as? URL { return url }
                if let string = rawValue as? String { return URL(string: string) }
                return nil
            }()

            let desiredURL =
                MarkdownURLBoundarySanitizer.sanitizedURL(
                    from: displayedText,
                    additionalBoundaryTokens: markdownLinkBoundaryTokens
                )
                ?? currentURL.flatMap {
                    MarkdownURLBoundarySanitizer.sanitizedURL(
                        from: $0.absoluteString,
                        additionalBoundaryTokens: markdownLinkBoundaryTokens
                    )
                }

            guard let desiredURL else { return }
            let desiredString = desiredURL.absoluteString
            guard displayedText.hasPrefix(desiredString) else { return }

            let trimmedLength = (desiredString as NSString).length
            let currentString = currentURL?.absoluteString
            let needsUpdate = trimmedLength != range.length || currentString != desiredString
            guard needsUpdate else { return }

            updates.append((range: range, trimmedLength: trimmedLength, url: desiredURL))
        }

        for update in updates.reversed() {
            attributed.removeAttribute(.link, range: update.range)
            guard update.trimmedLength > 0 else { continue }
            let trimmedRange = NSRange(location: update.range.location, length: update.trimmedLength)
            attributed.addAttribute(.link, value: update.url, range: trimmedRange)
            let trailingLength = update.range.length - update.trimmedLength
            if trailingLength > 0 {
                let trailingRange = NSRange(location: update.range.location + update.trimmedLength, length: trailingLength)
                // Explicitly clear underline styling on the trailing punctuation run so UITextView
                // does not visually carry link styling one character too far.
                attributed.addAttribute(.underlineStyle, value: 0, range: trailingRange)
            }
        }
    }

    private static func stripDetectedLinks(from attributed: NSAttributedString) -> NSAttributedString {
        guard let detector = detectedLinkStripper else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.string.utf16.count)
        let matches = detector.matches(in: mutable.string, options: [], range: fullRange)
        for match in matches.reversed() {
            guard match.resultType == .link else { continue }
            mutable.replaceCharacters(in: match.range, with: "")
        }

        func isTrimmable(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while let first = mutable.string.unicodeScalars.first, isTrimmable(first) {
            mutable.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        }
        while let last = mutable.string.unicodeScalars.last, isTrimmable(last) {
            let len = mutable.string.utf16.count
            guard len > 0 else { break }
            mutable.replaceCharacters(in: NSRange(location: len - 1, length: 1), with: "")
        }

        if mutable.string.contains("\n\n\n") {
            let regex = try? NSRegularExpression(pattern: "\n{3,}", options: [])
            let range = NSRange(location: 0, length: mutable.string.utf16.count)
            regex?.replaceMatches(in: mutable.mutableString, options: [], range: range, withTemplate: "\n\n")
        }

        return mutable
    }

    private static func applyMarkHighlights(nsAttributed: NSMutableAttributedString, color: UIColor?) {
        let text = nsAttributed.string as NSString
        let openToken = markOpenSentinel as NSString
        let closeToken = markCloseSentinel as NSString

        var pairs: [(open: NSRange, close: NSRange)] = []
        var searchStart = 0

        while searchStart < text.length {
            let openRange = text.range(of: openToken as String, options: [], range: NSRange(location: searchStart, length: text.length - searchStart))
            if openRange.location == NSNotFound { break }

            let closeSearchStart = openRange.location + openRange.length
            if closeSearchStart >= text.length { break }

            let closeRange = text.range(of: closeToken as String, options: [], range: NSRange(location: closeSearchStart, length: text.length - closeSearchStart))
            if closeRange.location == NSNotFound { break }

            pairs.append((open: openRange, close: closeRange))
            searchStart = closeRange.location + closeRange.length
        }

        for pair in pairs.reversed() {
            let contentStart = pair.open.location + pair.open.length
            let contentLength = pair.close.location - contentStart
            if contentLength > 0, let color {
                nsAttributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: contentStart, length: contentLength))
            }
            nsAttributed.deleteCharacters(in: pair.close)
            nsAttributed.deleteCharacters(in: pair.open)
        }
    }

    private static func inlineEmojiValues(from plan: MarkdownRenderPlan) -> [String] {
        plan.blocks.compactMap { block -> String? in
            guard case .richText(let value) = block else { return nil }
            return EmojiOnlyClassifier.isEmojiOnly(value) ? value : nil
        }
    }

    private static func preprocessClawlineMarkdownDialect(_ markdown: String) -> String {
        preserveIndentedHyphenLiteralLines(preprocessMarkHighlightSyntax(markdown))
    }

    private static func preserveIndentedHyphenLiteralLines(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let transformed = lines.map { line -> String in
            let leadingSpaces = line.prefix { $0 == " " }.count
            guard leadingSpaces >= 4 else { return line }
            let remainder = line.dropFirst(leadingSpaces)
            guard remainder.hasPrefix("- ") else { return line }
            return indentedLiteralSentinel + line
        }
        return transformed.joined(separator: "\n")
    }

    private static func preprocessMarkHighlightSyntax(_ markdown: String) -> String {
        let characters = Array(markdown)
        guard characters.count >= 4 else { return markdown }

        var delimiterPositions: [Int] = []
        var index = 0
        var inFence = false
        var inlineCodeDelimiterLength: Int?
        var isLineStart = true

        while index < characters.count {
            let character = characters[index]

            if character == "\n" {
                isLineStart = true
                index += 1
                continue
            }

            if character == "`" {
                let tickCount = countConsecutiveBackticks(characters, from: index)

                if inlineCodeDelimiterLength == nil && tickCount >= 3 && isLineStart {
                    inFence.toggle()
                    index += tickCount
                    isLineStart = false
                    continue
                }

                if !inFence {
                    if let delimiterLength = inlineCodeDelimiterLength {
                        if tickCount == delimiterLength {
                            inlineCodeDelimiterLength = nil
                            index += tickCount
                            isLineStart = false
                            continue
                        }
                    } else {
                        inlineCodeDelimiterLength = tickCount
                        index += tickCount
                        isLineStart = false
                        continue
                    }
                }

                index += tickCount
                isLineStart = false
                continue
            }

            if !inFence,
               inlineCodeDelimiterLength == nil,
               character == "=",
               index + 1 < characters.count,
               characters[index + 1] == "=" {
                delimiterPositions.append(index)
                index += 2
                isLineStart = false
                continue
            }

            if character != " " && character != "\t" && character != "\r" {
                isLineStart = false
            }
            index += 1
        }

        var pairs: [(open: Int, close: Int)] = []
        var open: Int?
        index = 0
        while index < delimiterPositions.count {
            let delimiter = delimiterPositions[index]
            if let start = open {
                let contentStart = start + 2
                if delimiter > contentStart {
                    if index + 1 < delimiterPositions.count,
                       delimiterPositions[index + 1] == delimiter + 2 {
                        index += 1
                        continue
                    }
                    pairs.append((open: start, close: delimiter))
                    open = nil
                } else {
                    open = delimiter
                }
            } else {
                open = delimiter
            }
            index += 1
        }

        guard !pairs.isEmpty else { return markdown }

        var replacements: [Int: String] = [:]
        replacements.reserveCapacity(pairs.count * 2)
        for pair in pairs {
            replacements[pair.open] = markOpenSentinel
            replacements[pair.close] = markCloseSentinel
        }

        var output = String()
        output.reserveCapacity(markdown.count)
        index = 0
        while index < characters.count {
            if let replacement = replacements[index] {
                output.append(replacement)
                index += 2
            } else {
                output.append(characters[index])
                index += 1
            }
        }

        return output
    }

    private static func normalizeOrderedListMarkers(in markdown: String) -> String {
        let linePattern = #"^([ \t>]*)(\d{1,9})([.)])([ \t]+)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: linePattern) else { return markdown }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var normalized: [String] = []
        normalized.reserveCapacity(lines.count)

        var inFence = false
        var activeListKey: String?
        var nextOrderedValue: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                activeListKey = nil
                nextOrderedValue = nil
                normalized.append(line)
                continue
            }

            if inFence {
                normalized.append(line)
                continue
            }

            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.range.location != NSNotFound else {
                if trimmed.isEmpty {
                    normalized.append(line)
                    continue
                }

                // Keep active list context through indented continuation lines.
                if activeListKey != nil,
                   let leadingScalar = line.unicodeScalars.first,
                   CharacterSet.whitespacesAndNewlines.contains(leadingScalar) {
                    normalized.append(line)
                    continue
                }

                activeListKey = nil
                nextOrderedValue = nil
                normalized.append(line)
                continue
            }

            let prefix = nsLine.substring(with: match.range(at: 1))
            let rawNumber = nsLine.substring(with: match.range(at: 2))
            let delimiter = nsLine.substring(with: match.range(at: 3))
            let spacing = nsLine.substring(with: match.range(at: 4))
            let content = nsLine.substring(with: match.range(at: 5))

            let key = orderedListContextKey(prefix: prefix, delimiter: delimiter)
            let startValue = Int(rawNumber) ?? 1
            let value: Int
            if activeListKey == key, let nextOrderedValue {
                value = nextOrderedValue
            } else {
                value = startValue
            }

            activeListKey = key
            nextOrderedValue = value + 1
            normalized.append("\(prefix)\(value)\(delimiter)\(spacing)\(content)")
        }

        return normalized.joined(separator: "\n")
    }

    private static func normalizeHyphenUnorderedListMarkers(in markdown: String) -> String {
        let linePattern = #"^([ \t]{0,3})(-)([ \t]+)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: linePattern) else { return markdown }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var normalized: [String] = []
        normalized.reserveCapacity(lines.count)

        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                normalized.append(line)
                continue
            }

            guard !inFence else {
                normalized.append(line)
                continue
            }

            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.range.location != NSNotFound else {
                normalized.append(line)
                continue
            }

            let prefix = nsLine.substring(with: match.range(at: 1))
            let spacing = nsLine.substring(with: match.range(at: 3))
            let content = nsLine.substring(with: match.range(at: 4))
            if isHyphenThematicBreakContent(content) {
                normalized.append(line)
                continue
            }
            normalized.append("\(prefix)•\(spacing)\(content)")
        }

        return normalized.joined(separator: "\n")
    }

    private static func isHyphenThematicBreakContent(_ content: String) -> Bool {
        let compact = content.filter { $0 != " " && $0 != "\t" }
        return compact.count >= 2 && compact.allSatisfy { $0 == "-" }
    }

    private static func orderedListContextKey(prefix: String, delimiter: String) -> String {
        var blockQuoteDepth = 0
        var indentColumns = 0

        for scalar in prefix.unicodeScalars {
            if scalar == ">" {
                blockQuoteDepth += 1
                continue
            }
            if scalar == "\t" {
                indentColumns += 4
                continue
            }
            if CharacterSet.whitespaces.contains(scalar) {
                indentColumns += 1
            }
        }

        // Group into coarse list-depth bands so harmless spacing variation doesn't reset numbering.
        let indentLevel = indentColumns / 2
        return "\(blockQuoteDepth)|\(indentLevel)|\(delimiter)"
    }

    private static func countConsecutiveBackticks(_ characters: [Character], from start: Int) -> Int {
        var count = 0
        var index = start
        while index < characters.count, characters[index] == "`" {
            count += 1
            index += 1
        }
        return count
    }

    private static func applyHeadingStyles(markdown: String,
                                           nsAttributed: NSMutableAttributedString,
                                           baseFont: UIFont) {
        let headings = extractMarkdownHeadings(markdown)
        guard !headings.isEmpty else { return }

        let fullText = nsAttributed.string as NSString
        var searchStart = 0

        for heading in headings {
            let target = heading.text
            guard !target.isEmpty else { continue }

            var foundRange: NSRange?
            while searchStart < fullText.length {
                let searchRange = NSRange(location: searchStart, length: fullText.length - searchStart)
                let range = fullText.range(of: target, options: [], range: searchRange)
                if range.location == NSNotFound { break }

                let isLineStart = (range.location == 0) || (fullText.substring(with: NSRange(location: range.location - 1, length: 1)) == "\n")
                if isLineStart {
                    foundRange = range
                    break
                }
                searchStart = range.location + range.length
            }

            guard let range = foundRange else { continue }

            let role: ClawlineTextRole
            switch heading.level {
            case 1:
                role = .sectionHeader
            case 2:
                role = .subsectionHeader
            case 3:
                role = .shortMessage
            case 4:
                role = .mediumMessage
            case 5:
                role = .uiLabel
            default:
                role = .secondaryLabel
            }

            let headingFont = UIFont.clawline(role)
            nsAttributed.addAttribute(.font, value: headingFont, range: range)
            searchStart = range.location + range.length
        }
    }

    private struct HeadingInfo {
        let level: Int
        let text: String
    }

    private static func extractMarkdownHeadings(_ markdown: String) -> [HeadingInfo] {
        markdown
            .components(separatedBy: .newlines)
            .compactMap { line -> HeadingInfo? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                var level = 0
                for char in trimmed {
                    if char == "#" {
                        level += 1
                    } else {
                        break
                    }
                }

                guard level > 0, level <= 6 else { return nil }
                let hashEndIndex = trimmed.index(trimmed.startIndex, offsetBy: level)
                guard hashEndIndex < trimmed.endIndex,
                      trimmed[hashEndIndex] == " " else {
                    return nil
                }

                let textStart = trimmed.index(after: hashEndIndex)
                let text = String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }

                return HeadingInfo(level: level, text: text)
            }
    }
}
