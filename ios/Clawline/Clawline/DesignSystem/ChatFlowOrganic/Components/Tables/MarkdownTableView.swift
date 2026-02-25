import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MarkdownTableView: View {
    let model: TableModel
    let role: Message.Role
    let metrics: ChatFlowTheme.Metrics
    let maxLineWidth: CGFloat
    let isExpanded: Bool
    let onExpand: () -> Void
    let onCollapse: () -> Void

    private let cellPaddingHorizontal: CGFloat = 12
    private let cellPaddingVertical: CGFloat = 10

    @Environment(\.openURL) private var openURLAction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var scrollOffset: CGFloat = 0
    @State private var hasActiveSelection = false
    @State private var didTapLink = false
    @State private var keyboardFocus = false
    @State private var focusedCell: (row: Int, column: Int)?
    @State private var containerWidth: CGFloat = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var headerHeight: CGFloat = 0

    private var headerFill: Color { Color(uiColor: headerFillColor) }
    private var backgroundFill: Color { Color(uiColor: backgroundFillColor) }
    private var borderColor: Color { Color(uiColor: borderColorValue) }
    private var headerDividerColor: Color { Color(uiColor: headerDividerColorValue) }
    private var cellDividerColor: Color { Color(uiColor: cellDividerColorValue) }
    private var tableTextColor: UIColor { dynamicColor { colorScheme in
        if colorScheme == .dark {
            return UIColor(red: 0.941, green: 0.918, blue: 0.894, alpha: 1.0)
        }
        return UIColor(ChatFlowTheme.ink(colorScheme))
    } }
    private var emptyCellTextColor: UIColor { dynamicColor { colorScheme in
        UIColor(ChatFlowTheme.ink(colorScheme)).withAlphaComponent(colorScheme == .dark ? 0.82 : 0.60)
    } }

    private var headerFillColor: UIColor {
        dynamicColor { colorScheme in
            switch role {
            case .user:
                return UIColor(ChatFlowTheme.terracotta(colorScheme)).withAlphaComponent(colorScheme == .dark ? 0.24 : 0.30)
            case .assistant:
                return UIColor(ChatFlowTheme.warmBrown(colorScheme)).withAlphaComponent(colorScheme == .dark ? 0.22 : 0.30)
            }
        }
    }

    private var backgroundFillColor: UIColor {
        dynamicColor { colorScheme in
            switch role {
            case .user:
                return UIColor(ChatFlowTheme.sage(colorScheme)).withAlphaComponent(colorScheme == .dark ? 0.24 : 0.12)
            case .assistant:
                if colorScheme == .dark {
                    return UIColor(ChatFlowTheme.warmBrown(colorScheme)).withAlphaComponent(0.08)
                }
                return UIColor(ChatFlowTheme.cream(colorScheme)).withAlphaComponent(0.12)
            }
        }
    }

    private var borderColorValue: UIColor {
        dynamicColor { colorScheme in
            if colorScheme == .dark {
                return UIColor.white.withAlphaComponent(0.34)
            }
            return UIColor(ChatFlowTheme.stone(colorScheme)).withAlphaComponent(0.40)
        }
    }

    private var headerDividerColorValue: UIColor {
        dynamicColor { colorScheme in
            borderBaseColor(colorScheme).withAlphaComponent(colorScheme == .dark ? 0.72 : 0.30)
        }
    }

    private var cellDividerColorValue: UIColor {
        dynamicColor { colorScheme in
            borderBaseColor(colorScheme).withAlphaComponent(colorScheme == .dark ? 0.45 : 0.20)
        }
    }

    private var visibleRows: [(index: Int, row: TableModel.Row)] {
        let enumerated = model.rows.enumerated().map { (index: $0.offset, row: $0.element) }
        if isExpanded { return enumerated }
        return Array(enumerated.prefix(5))
    }

    private var remainingRowCount: Int {
        max(model.rows.count - visibleRows.count, 0)
    }

    private var columnTitles: [String] {
        if let header = model.header {
            return header.map { $0.plainText }
        }
        return model.columns.enumerated().map { index, _ in "Column \(index + 1)" }
    }

    private var columnWidths: [CGFloat] {
        var widths: [CGFloat] = Array(repeating: 0, count: model.columns.count)
        if let header = model.header {
            for (idx, cell) in header.prefix(model.columns.count).enumerated() {
                widths[idx] = max(widths[idx], measuredCellTextWidth(cell: cell, alignment: model.columns[idx].alignment, isHeader: true))
            }
        }
        for row in model.rows {
            for (idx, cell) in row.cells.prefix(model.columns.count).enumerated() {
                widths[idx] = max(widths[idx], measuredCellTextWidth(cell: cell, alignment: model.columns[idx].alignment, isHeader: false))
            }
        }
        return widths
    }

    private var contentWidth: CGFloat {
        let paddingWidth = CGFloat(model.columns.count) * cellPaddingHorizontal * 2
        let separators = CGFloat(max(model.columns.count - 1, 0))
        return columnWidths.reduce(0, +) + paddingWidth + separators
    }

    private var isLandscapePhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
    }

    private var effectiveMaxWidth: CGFloat {
        guard isLandscapePhone else { return maxLineWidth }
        let clamped = containerWidth * 0.9
        return min(maxLineWidth, max(clamped, 0))
    }

    private var needsHorizontalScroll: Bool {
        contentWidth > effectiveMaxWidth
    }

    private var showFooterOverlay: Bool {
        !isExpanded && remainingRowCount > 0
    }

    private var shouldShowGradients: Bool {
        needsHorizontalScroll && !isExpanded
    }

    var body: some View {
        ErrorCatchingView {
            ZStack(alignment: .bottomLeading) {
                scrollContainer
                if shouldShowGradients {
                    gradientOverlay
                }
                if showFooterOverlay {
                    footerOverlay
                }
            }
        }
        .padding(1) // Make room for border
        .background(widthReader)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy as Markdown") { writeCopyPayload(preferred: .markdown) }
            Button("Copy as Tab-Separated Text") { writeCopyPayload(preferred: .tsv) }
        }
        .onTapGesture { handleTapGesture() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("table-\(model.messageID)")
        .accessibilityLabel("Table with \(model.rows.count) rows and \(model.columns.count) columns")
        .overlay(
            TableKeyCommandBridge(
                isFirstResponder: $keyboardFocus,
                onDirection: handleKeyDirection,
                onTab: handleTabKey,
                onEscape: handleEscapeKey,
                onCopy: handleCopyCommand
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: isExpanded) { _, newValue in handleExpansionChange(newValue) }
        .onChange(of: model.rows.count) { _, _ in clampFocusedCell() }
        .onDisappear { keyboardFocus = false }
    }

    private var scrollContainer: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 1).id("leading")
                    gridContent
                }
                .frame(minWidth: max(containerWidth - 2, 0))  // Fill container width (minus border padding)
                .padding(.vertical, 1)
                .background(offsetReader)
            }
            .coordinateSpace(name: "tableScroll")
            .onPreferenceChange(HorizontalOffsetPreferenceKey.self) { value in
                scrollOffset = -value
            }
            .onAppear {
                scrollProxy = proxy
                resetHorizontalScrollToLeading(using: proxy)
            }
            .onChange(of: containerWidth) { _, _ in
                resetHorizontalScrollToLeading(using: proxy)
            }
        }
    }

    private var gridContent: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            if let header = model.header {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        cellView(
                            rowPosition: nil,
                            columnIndex: column,
                            cell: cell,
                            alignment: model.columns[column].alignment,
                            columnWidth: columnWidths[column],
                            isHeader: true
                        )
                    }
                }
                .gridCellAnchor(.topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(headerFill)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(headerDividerColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                }
            }

            ForEach(visibleRows, id: \.row.id) { item in
                GridRow {
                    ForEach(Array(item.row.cells.enumerated()), id: \.offset) { column, cell in
                        cellView(
                            rowPosition: item.index,
                            columnIndex: column,
                            cell: cell,
                            alignment: model.columns[column].alignment,
                            columnWidth: columnWidths[column],
                            isHeader: false
                        )
                        .overlay(alignment: .trailing) {
                            if model.columns.count > 1 && column < model.columns.count - 1 {
                                Rectangle()
                                    .fill(cellDividerColor)
                                    .frame(width: 1)
                            }
                        }
                    }
                }
                .gridCellAnchor(.topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(cellDividerColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: model.rows.count)
            }

            if showFooterOverlay {
                GridRow {
                    footerGridLabel
                        .gridCellColumns(model.columns.count)
                        .padding(.horizontal, cellPaddingHorizontal)
                        .padding(.vertical, 8)
                }
                .gridCellAnchor(.topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerGridLabel: some View {
        Text(footerLabel(for: remainingRowCount))
            .font(.clawline(.secondaryLabel).weight(.medium))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerOverlay: some View {
        HStack {
            Text(footerLabel(for: remainingRowCount))
                .font(.clawline(.secondaryLabel).weight(.medium))
            Spacer()
            Image(systemName: "chevron.down")
                .font(.clawline(.secondaryLabel).weight(.semibold))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, cellPaddingHorizontal)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [backgroundFill.opacity(0.2), backgroundFill.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }

    private var gradientOverlay: some View {
        HStack {
            LinearGradient(
                colors: [backgroundFill.opacity(scrollOffset > 5 ? 0.9 : 0.0), backgroundFill.opacity(0.0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 24)
            .allowsHitTesting(false)

            Spacer()

            LinearGradient(
                colors: [backgroundFill.opacity(0.0), backgroundFill.opacity(contentWidth - scrollOffset > effectiveMaxWidth ? 0.9 : 0.0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 24)
            .allowsHitTesting(false)
        }
    }

    private var offsetReader: some View {
        GeometryReader { geo in
            Color.clear
                .preference(key: HorizontalOffsetPreferenceKey.self, value: geo.frame(in: .named("tableScroll")).origin.x)
        }
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { containerWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newValue in containerWidth = newValue }
        }
    }

    @ViewBuilder
    private func cellView(
        rowPosition: Int?,
        columnIndex: Int,
        cell: TableModel.Cell,
        alignment: ColumnAlignment,
        columnWidth: CGFloat,
        isHeader: Bool
    ) -> some View {
        let alignmentStyle = alignmentAlignment(for: alignment)
        let isFocused = keyboardFocus && focusedCell?.row == rowPosition && focusedCell?.column == columnIndex

        Group {
            if cell.isEmpty {
                Text("—")
                    .font(isHeader ? .clawline(.mediumMessage) : .clawline(.bodyText))
                    .foregroundColor(Color(uiColor: emptyCellTextColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SelectableAttributedText(
                    attributedString: styledAttributedString(for: cell, alignment: alignment, isHeader: isHeader),
                    alignment: nsTextAlignment(for: alignment),
                    colorScheme: colorScheme,
                    onSelectionChange: { hasActiveSelection = $0 },
                    onLinkTap: { url in
                        registerLinkTap()
                        openURLAction(url)
                    }
                )
            }
        }
        .frame(width: columnWidth, alignment: alignmentStyle)
        .padding(.horizontal, cellPaddingHorizontal)
        .padding(.vertical, cellPaddingVertical)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor.opacity(isFocused ? 0.8 : 0.0), lineWidth: isFocused ? 1.5 : 0)
        )
        .accessibilityLabel(accessibilityLabel(for: cell, rowPosition: rowPosition, columnIndex: columnIndex, isHeader: isHeader))
        .accessibilityAddTraits(isHeader ? .isHeader : [])
    }

    private func accessibilityLabel(for cell: TableModel.Cell, rowPosition: Int?, columnIndex: Int, isHeader: Bool) -> String {
        if isHeader {
            return columnTitles[columnIndex]
        }
        let rowLabel = rowPosition.map { "Row \($0 + 1)" } ?? "Row"
        let columnLabel = columnTitles[columnIndex]
        let value = cell.plainText.isEmpty ? "Empty" : cell.plainText
        return "\(rowLabel), \(columnLabel): \(value)"
    }

    private func nsTextAlignment(for alignment: ColumnAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    private func alignmentAlignment(for alignment: ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func styledAttributedString(for cell: TableModel.Cell, alignment: ColumnAlignment, isHeader: Bool) -> NSAttributedString {
        let attributed = cell.attributed
        let mutable = NSMutableAttributedString(attributed)
        _ = metrics
        let scaledFont = isHeader ? UIFont.clawline(.mediumMessage) : UIFont.clawline(.bodyText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: scaledFont, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: tableTextColor, range: fullRange)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsTextAlignment(for: alignment)
        paragraph.lineBreakMode = .byWordWrapping
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let nsRange = NSRange(run.range, in: attributed)
                let codeFont = UIFont.clawlineMonospaced(.secondaryLabel)
                mutable.addAttribute(.font, value: codeFont, range: nsRange)
                mutable.addAttribute(.backgroundColor, value: inlineCodeBackgroundColor(), range: nsRange)
            }
        }

        return mutable
    }

    private func measuredCellTextWidth(cell: TableModel.Cell, alignment: ColumnAlignment, isHeader: Bool) -> CGFloat {
        guard !cell.isEmpty else {
            _ = metrics
            let scaledFont = isHeader ? UIFont.clawline(.mediumMessage) : UIFont.clawline(.bodyText)
            let width = ("—" as NSString).size(withAttributes: [.font: scaledFont]).width
            return ceil(width)
        }

        let styled = styledAttributedString(for: cell, alignment: alignment, isHeader: isHeader)
        let measured = styled.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        // Small safety margin prevents edge-case glyph clipping/wrapping in UITextView layout.
        return ceil(measured.width) + 1
    }

    private func inlineCodeBackgroundColor() -> UIColor {
        dynamicColor { colorScheme in
            colorScheme == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.08)
        }
    }

    private func dynamicColor(_ makeColor: @escaping (ColorScheme) -> UIColor) -> UIColor {
        UIColor { traitCollection in
            makeColor(traitCollection.userInterfaceStyle == .dark ? .dark : .light)
        }
    }

    private func borderBaseColor(_ colorScheme: ColorScheme) -> UIColor {
        if colorScheme == .dark {
            return UIColor.white
        }
        return UIColor(ChatFlowTheme.stone(colorScheme))
    }

    private func handleTapGesture() {
        guard !hasActiveSelection && !didTapLink else { return }
        if isExpanded {
            keyboardFocus = true
            focusedCell = focusedCell ?? (0, 0)
        } else {
            onExpand()
        }
    }

    private func registerLinkTap() {
        didTapLink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            didTapLink = false
        }
    }

    private func handleExpansionChange(_ expanded: Bool) {
        if expanded {
            keyboardFocus = true
            focusedCell = focusedCell ?? (0, 0)
        } else {
            keyboardFocus = false
            focusedCell = nil
            if needsHorizontalScroll {
                scrollProxy?.scrollTo("leading", anchor: .leading)
            }
        }
    }

    private func resetHorizontalScrollToLeading(using proxy: ScrollViewProxy) {
        guard !isExpanded else { return }
        guard needsHorizontalScroll else { return }
        // Ensure collapsed tables always start at the left-most columns when mounted in bubble UIKit wrappers.
        DispatchQueue.main.async {
            proxy.scrollTo("leading", anchor: .leading)
        }
    }

    private func handleKeyDirection(_ direction: TableKeyCommandBridge.Direction) {
        guard !visibleRows.isEmpty else { return }
        var current = focusedCell ?? (row: 0, column: 0)
        switch direction {
        case .up:
            current.row = max(current.row - 1, 0)
        case .down:
            current.row = min(current.row + 1, visibleRows.count - 1)
        case .left:
            current.column = max(current.column - 1, 0)
        case .right:
            current.column = min(current.column + 1, model.columns.count - 1)
        }
        focusedCell = current
    }

    private func handleTabKey(_ isReverse: Bool) {
        guard !visibleRows.isEmpty else { return }
        var current = focusedCell ?? (row: 0, column: 0)
        if isReverse {
            current.row = max(current.row - 1, 0)
        } else {
            current.row = min(current.row + 1, visibleRows.count - 1)
        }
        focusedCell = current
    }

    private func handleEscapeKey() {
        if isExpanded {
            onCollapse()
        }
        keyboardFocus = false
    }

    private func handleCopyCommand() {
        writeCopyPayload(preferred: .markdown)
    }

    private func clampFocusedCell() {
        guard let current = focusedCell else { return }
        guard !visibleRows.isEmpty else {
            focusedCell = nil
            return
        }
        let row = min(current.row, max(visibleRows.count - 1, 0))
        let column = min(current.column, max(model.columns.count - 1, 0))
        focusedCell = (row, column)
    }

    private enum CopyFormat {
        case markdown
        case tsv
    }

    private func writeCopyPayload(preferred: CopyFormat) {
        guard !hasActiveSelection else { return }
        let markdown = markdownRepresentation()
        let tsv = tsvRepresentation()
        var item: [String: Any] = [:]
        let markdownType = UTType("net.daringfireball.markdown")
        item[UTType.utf8PlainText.identifier] = preferred == .tsv ? tsv : markdown
        item[UTType.tabSeparatedText.identifier] = tsv
        if let markdownType {
            item[markdownType.identifier] = markdown
        }
        UIPasteboard.general.setItems([item])
    }

    private func markdownRepresentation() -> String {
        var lines: [String] = []
        if let header = model.header {
            lines.append("| " + header.map { $0.plainText }.joined(separator: " | ") + " |")
            let alignmentLine = model.columns.map { column -> String in
                switch column.alignment {
                case .leading: return ":---"
                case .center: return ":---:"
                case .trailing: return "---:"
                }
            }.joined(separator: " | ")
            lines.append("| \(alignmentLine) |")
        }
        for row in model.rows {
            lines.append("| " + row.cells.map { $0.plainText }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private func tsvRepresentation() -> String {
        var rows: [[String]] = []
        if let header = model.header {
            rows.append(header.map { $0.plainText })
        }
        for row in model.rows {
            rows.append(row.cells.map { $0.plainText })
        }
        return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    private func footerLabel(for count: Int) -> LocalizedStringResource {
        if count == 1 {
            return LocalizedStringResource("table.more.rows.one", defaultValue: "+1 more row")
        }
        return LocalizedStringResource("table.more.rows.many", defaultValue: "+\(count) more rows")
    }
}

private struct HorizontalOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
