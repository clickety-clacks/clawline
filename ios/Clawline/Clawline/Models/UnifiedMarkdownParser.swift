import Foundation
import Markdown
import UIKit

enum UnifiedMarkdownParser {
    private static let maxColumns = 40
    private static let maxCellsPerMessage = 400

    static func parse(markdown: String, messageID: String, metrics: ChatFlowTheme.Metrics) -> MarkdownRenderPlan {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        let document = Document(parsing: markdown)
        var blocks: [MarkdownRenderBlock] = []

        func appendRichText(_ source: String) {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(.richText(markdownSource: trimmed))
            }
        }

        for child in document.children {
            if let code = child as? CodeBlock {
                blocks.append(.code(language: normalizedLanguage(code.language), code: code.code))
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

        let headerModels = headerCells.map { cell in
            totalCellCount += 1
            return makeCell(from: cell, metrics: metrics)
        }

        var rows: [TableModel.Row] = []
        for (rowIndex, row) in bodyRows.enumerated() {
            let cells = Array(row.cells)
            guard cells.count == columnCount else {
                return nil
            }

            var rowModels: [TableModel.Cell] = []
            rowModels.reserveCapacity(cells.count)
            for cell in cells {
                if totalCellCount >= maxCellsPerMessage {
                    break
                }
                totalCellCount += 1
                rowModels.append(makeCell(from: cell, metrics: metrics))
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

    private static func makeCell(from cell: Table.Cell, metrics: ChatFlowTheme.Metrics) -> TableModel.Cell {
        let markdown = tableCellMarkdown(from: cell)
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            return source
        }
        return cell.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intrinsicWidth(for text: String, metrics: ChatFlowTheme.Metrics) -> CGFloat {
        let baseFont = UIFont.systemFont(ofSize: metrics.bodyFontSize, weight: .regular)
        let scaledFont = UIFontMetrics.default.scaledFont(for: baseFont)
        let width = (text as NSString).size(withAttributes: [.font: scaledFont]).width
        return ceil(width)
    }
}
