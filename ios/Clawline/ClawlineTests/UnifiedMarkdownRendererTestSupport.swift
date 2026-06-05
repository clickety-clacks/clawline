import UIKit
@testable import Clawline

func renderMarkdownForTests(
    markdown: String,
    options: MarkdownRenderOptions,
    role: Message.Role = .user,
    messageID: String = "test-render"
) -> [RenderedMarkdownBlock] {
    let effectiveRole: Message.Role = options.markHighlightColor == nil ? role : .assistant
    return UnifiedMarkdownRenderer.makeContent(
        messageText: markdown,
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

func attributedMarkdownForTests(
    markdown: String,
    baseFont: UIFont,
    inkColor: UIColor,
    lineSpacing: CGFloat,
    markHighlightColor: UIColor? = nil
) -> NSAttributedString? {
    return renderMarkdownForTests(
        markdown: markdown,
        options: MarkdownRenderOptions(
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: false,
            markHighlightColor: markHighlightColor
        ),
        role: markHighlightColor == nil ? .user : .assistant
    ).compactMap { block -> NSAttributedString? in
        guard case .attributedText(let attributed) = block else { return nil }
        return attributed
    }.first
}
