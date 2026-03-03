import Foundation
import Markdown
import UIKit

enum UnifiedMarkdownParser {
    private static let maxColumns = 40
    private static let maxCellsPerMessage = 400
    private static let fenceInvisibleScalars: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
    private static let tablePipeSentinel = "\u{E000}"

    static func parse(markdown: String, messageID: String, metrics: ChatFlowTheme.Metrics) -> MarkdownRenderPlan {
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
                        code: restoreProtectedPipes(in: code.code)
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

    private static func planFromRichTextOnly(_ markdown: String) -> MarkdownRenderPlan {
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

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func plainText(from block: MarkdownRenderBlock) -> String {
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

    private static func markdownPlainText(from source: String) -> String {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        ) {
            return NSAttributedString(attributed).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildTableModel(
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

    private static func mapAlignment(_ alignment: Table.ColumnAlignment?) -> ColumnAlignment {
        switch alignment {
        case .center:
            return .center
        case .right:
            return .trailing
        case .left, .none:
            return .leading
        }
    }

    private static func makeCell(from markdown: String, metrics: ChatFlowTheme.Metrics) -> TableModel.Cell {
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

    private static func tableCellMarkdown(from cell: Table.Cell) -> String {
        // Calling Table.Cell.format() can assert inside swift-markdown's formatter.
        // Format each child node instead so malformed/edge cell content is still preserved.
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

    private static func normalizeTableCellMarkdowns(_ cells: [String], expectedCount: Int) -> [String] {
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

    private static func hasUnbalancedInlineCodeDelimiter(_ source: String) -> Bool {
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

    private static func normalizeFenceLines(in markdown: String) -> String {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let hasTrailingNewline = markdown.last?.isNewline == true
        let normalized = lines.map { normalizeFenceLine(String($0)) }
        if hasTrailingNewline {
            return normalized.joined(separator: "\n") + "\n"
        }
        return normalized.joined(separator: "\n")
    }

    private static func normalizeFenceLine(_ line: String) -> String {
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

    private static func protectInlineCodePipesInTableRows(in markdown: String) -> String {
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

    private static func protectInlineCodePipesInTableLine(_ line: String) -> String {
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

    private static func restoreProtectedPipes(in source: String) -> String {
        source.replacingOccurrences(of: tablePipeSentinel, with: "|")
    }

    private static func containsUnclosedCodeFence(in markdown: String) -> Bool {
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

    private static func fenceToken(in line: String) -> (marker: Character, count: Int, isClosing: Bool)? {
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

    private static func intrinsicWidth(for text: String, metrics: ChatFlowTheme.Metrics) -> CGFloat {
        _ = metrics
        let scaledFont = UIFont.clawline(.bodyText)
        let width = (text as NSString).size(withAttributes: [.font: scaledFont]).width
        return ceil(width)
    }
}
