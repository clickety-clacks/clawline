import UIKit
@testable import Clawline

enum MarkdownRenderBlock: Equatable {
    case richText(markdownSource: String)
    case code(language: String?, code: String)
    case table(TableModel)
}

struct MarkdownRenderPlan: Equatable {
    let blocks: [MarkdownRenderBlock]
    let plainTextForMetrics: String
    let containsTextualContent: Bool
    let isEmojiOnly: Bool

    static let empty = MarkdownRenderPlan(
        blocks: [],
        plainTextForMetrics: "",
        containsTextualContent: false,
        isEmojiOnly: false
    )
}

enum UnifiedMarkdownParser {
    static func parse(markdown: String, messageID: String, metrics: ChatFlowTheme.Metrics) -> MarkdownRenderPlan {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        return MarkdownRenderPlan(
            blocks: [.richText(markdownSource: trimmed)],
            plainTextForMetrics: trimmed,
            containsTextualContent: true,
            isEmojiOnly: EmojiOnlyClassifier.isEmojiOnly(trimmed)
        )
    }
}

func renderMarkdownForTests(
    plan: MarkdownRenderPlan,
    options: MarkdownRenderOptions,
    messageText: String = "",
    role: Message.Role = .user,
    messageID: String = "test-render"
) -> [RenderedMarkdownBlock] {
    let effectiveRole: Message.Role = options.markHighlightColor == nil ? role : .assistant
    let renderText = messageText.isEmpty ? planMarkdownText(plan) : messageText
    return UnifiedMarkdownRenderer.makeContent(
        messageText: renderText,
        context: MarkdownMessageRenderContext(
            role: effectiveRole,
            messageID: messageID,
            metrics: ChatFlowTheme.Metrics(isCompact: true)
        ),
        baseFont: options.baseFont,
        inkColor: options.inkColor,
        lineSpacing: options.lineSpacing,
        stripDetectedURLs: options.stripDetectedURLs,
        isDark: options.markHighlightColor == SalientHighlightApplier.highlightColor(isDark: true)
    ).renderedBlocks
}

private func planMarkdownText(_ plan: MarkdownRenderPlan) -> String {
    plan.blocks.map { block -> String in
        switch block {
        case .richText(let markdownSource):
            return markdownSource
        case .code(let language, let code):
            let fence = "```"
            return language.map { "\(fence)\($0)\n\(code)\n\(fence)" } ?? "\(fence)\n\(code)\n\(fence)"
        case .table(let model):
            let header = model.header?.map(\.plainText).joined(separator: " | ") ?? ""
            let rows = model.rows.map { $0.cells.map(\.plainText).joined(separator: " | ") }
            return ([header] + rows).filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }.joined(separator: "\n\n")
}

func attributedMarkdownForTests(
    markdown: String,
    baseFont: UIFont,
    inkColor: UIColor,
    lineSpacing: CGFloat,
    markHighlightColor: UIColor? = nil
) -> NSAttributedString? {
    let plan = MarkdownRenderPlan(
        blocks: [.richText(markdownSource: markdown)],
        plainTextForMetrics: markdown,
        containsTextualContent: !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        isEmojiOnly: false
    )
    return renderMarkdownForTests(
        plan: plan,
        options: MarkdownRenderOptions(
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: false,
            markHighlightColor: markHighlightColor
        ),
        messageText: markdown,
        role: markHighlightColor == nil ? .user : .assistant
    ).compactMap { block -> NSAttributedString? in
        guard case .attributedText(let attributed) = block else { return nil }
        return attributed
    }.first
}
