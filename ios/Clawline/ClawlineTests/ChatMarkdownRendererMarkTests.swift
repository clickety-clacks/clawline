//
//  UnifiedMarkdownRendererMarkTests.swift
//  ClawlineTests
//

import Testing
import UIKit
@testable import Clawline

struct UnifiedMarkdownRendererMarkTests {
    private struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    @Test("Markdown mark syntax applies rust color and skips inline code")
    func markSyntaxLightModeSkipsInlineCode() {
        let rust = SalientHighlightApplier.highlightColor(isDark: false)
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: "Alpha ==focus== and `==literal==`.",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            markHighlightColor: rust
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        #expect(rendered.string == "Alpha focus and ==literal==.")

        let text = rendered.string as NSString
        let focusRange = text.range(of: "focus")
        #expect(focusRange.location != NSNotFound)
        #expect(rgb(rendered, at: focusRange.location) == RGB(red: 158, green: 62, blue: 28))

        let literalRange = text.range(of: "==literal==")
        #expect(literalRange.location != NSNotFound)
        #expect(rgb(rendered, at: literalRange.location) != RGB(red: 158, green: 62, blue: 28))
    }

    @Test("Markdown mark syntax applies muted gold in dark mode")
    func markSyntaxDarkModeColor() {
        let mutedGold = SalientHighlightApplier.highlightColor(isDark: true)
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: "==focus==",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .white,
            lineSpacing: 4,
            markHighlightColor: mutedGold
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        #expect(rendered.string == "focus")
        #expect(rgb(rendered, at: 0) == RGB(red: 217, green: 175, blue: 98))
    }

    @Test("UnifiedMarkdownRenderer only applies markdown highlights when enabled")
    func unifiedMarkdownRendererHighlightToggle() {
        let presentation = MessagePresentation(
            parts: [.markdown("==focus==")],
            markdownRenderPlan: MarkdownRenderPlan(
                blocks: [.richText(markdownSource: "==focus==")],
                plainTextForMetrics: "focus",
                containsTextualContent: true,
                isEmojiOnly: false
            ),
            wordCount: 1,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )

        let disabled = UnifiedMarkdownRenderer.render(
            plan: presentation.markdownRenderPlan,
            options: MarkdownRenderOptions(
                baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
                inkColor: .black,
                lineSpacing: 4,
                stripDetectedURLs: false,
                markHighlightColor: nil
            )
        )
        #expect(disabled.count == 1)
        guard case .attributedText(let disabledText)? = disabled.first else {
            Issue.record("Expected attributed text block")
            return
        }
        #expect(disabledText.string == "==focus==")

        let enabled = UnifiedMarkdownRenderer.render(
            plan: presentation.markdownRenderPlan,
            options: MarkdownRenderOptions(
                baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
                inkColor: .black,
                lineSpacing: 4,
                stripDetectedURLs: false,
                markHighlightColor: rustColor(isDark: false)
            )
        )
        guard case .attributedText(let enabledText)? = enabled.first else {
            Issue.record("Expected attributed text block")
            return
        }
        #expect(enabledText.string == "focus")
        #expect(rgb(enabledText, at: 0) == RGB(red: 158, green: 62, blue: 28))
    }

    @Test("MessagePresentationBuilder routes mark syntax through markdown renderer")
    func messagePresentationBuilderRoutesMarkSyntaxThroughMarkdownRenderer() {
        let message = Message(
            id: "s_mark_route",
            role: .assistant,
            content: "Alpha ==focus== beta",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:main"
        )
        var state = StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: ChatFlowTheme.Metrics(isCompact: true),
            streamingState: &state
        )

        #expect(presentation.parts.contains(where: { part in
            if case .markdown(let value) = part {
                return value == "Alpha ==focus== beta"
            }
            return false
        }))

        let rendered = UnifiedMarkdownRenderer.render(
            plan: presentation.markdownRenderPlan,
            options: MarkdownRenderOptions(
                baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
                inkColor: .black,
                lineSpacing: 4,
                stripDetectedURLs: false,
                markHighlightColor: rustColor(isDark: false)
            )
        )
        guard case .attributedText(let renderedText)? = rendered.first else {
            Issue.record("Expected attributed text block")
            return
        }
        #expect(renderedText.string == "Alpha focus beta")
        let focusRange = (renderedText.string as NSString).range(of: "focus")
        #expect(focusRange.location != NSNotFound)
        #expect(rgb(renderedText, at: focusRange.location) == RGB(red: 158, green: 62, blue: 28))
    }

    @Test("Link spans stop before trailing backticks in assistant markdown rendering")
    func assistantMarkdownRenderingTrimsBacktickLinkSpan() {
        let rust = SalientHighlightApplier.highlightColor(isDark: false)
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: "http://tars:18800/www/tracker-dashboard.html`",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            markHighlightColor: rust
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        let text = rendered.string as NSString
        let urlRange = text.range(of: "http://tars:18800/www/tracker-dashboard.html")
        let backtickRange = text.range(of: "`")
        #expect(urlRange.location != NSNotFound)
        #expect(backtickRange.location != NSNotFound)
        #expect(rendered.attribute(.link, at: urlRange.location, effectiveRange: nil) != nil)
        #expect(rendered.attribute(.link, at: urlRange.location + urlRange.length - 1, effectiveRange: nil) != nil)
        #expect(rendered.attribute(.link, at: backtickRange.location, effectiveRange: nil) == nil)
    }

    @Test("Inline-code URLs remain tappable in assistant markdown rendering")
    func assistantMarkdownRenderingKeepsInlineCodeURLsTappable() {
        let rust = SalientHighlightApplier.highlightColor(isDark: false)
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: "Visit `https://example.com/path` now",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            markHighlightColor: rust
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        let text = rendered.string as NSString
        let urlRange = text.range(of: "https://example.com/path")
        #expect(urlRange.location != NSNotFound)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        #expect(rendered.attribute(.link, at: urlRange.location, effectiveRange: &effectiveRange) != nil)
        #expect(effectiveRange == urlRange)
        #expect(rendered.attribute(.link, at: urlRange.location + urlRange.length - 1, effectiveRange: nil) != nil)
    }

    @Test("Link spans stop before assistant mark delimiters")
    func assistantMarkdownRenderingStopsLinkSpanAtMarkDelimiter() {
        let rust = SalientHighlightApplier.highlightColor(isDark: false)
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: "http://example.com==nice==",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            markHighlightColor: rust
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        #expect(rendered.string == "http://example.comnice")
        let text = rendered.string as NSString
        let urlRange = text.range(of: "http://example.com")
        let highlightRange = text.range(of: "nice")
        #expect(urlRange.location != NSNotFound)
        #expect(highlightRange.location != NSNotFound)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        #expect(rendered.attribute(.link, at: urlRange.location, effectiveRange: &effectiveRange) != nil)
        #expect(effectiveRange == urlRange)
        #expect(rendered.attribute(.link, at: urlRange.location + urlRange.length - 1, effectiveRange: nil) != nil)
        #expect(rendered.attribute(.link, at: highlightRange.location, effectiveRange: nil) == nil)
        #expect((rendered.attribute(.underlineStyle, at: highlightRange.location, effectiveRange: nil) as? Int ?? 0) == 0)
    }

    @Test("Link spans stop before adjacent assistant mark delimiters without whitespace")
    func assistantMarkdownRenderingStopsLinkSpanAtAdjacentMarkDelimiter() {
        let rust = SalientHighlightApplier.highlightColor(isDark: false)
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: "http://example.com==text==",
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            markHighlightColor: rust
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        #expect(rendered.string == "http://example.comtext")
        let text = rendered.string as NSString
        let urlRange = text.range(of: "http://example.com")
        let highlightRange = text.range(of: "text")
        #expect(urlRange.location != NSNotFound)
        #expect(highlightRange.location != NSNotFound)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        #expect(rendered.attribute(.link, at: urlRange.location, effectiveRange: &effectiveRange) != nil)
        #expect(effectiveRange == urlRange)
        #expect(rendered.attribute(.link, at: urlRange.location + urlRange.length - 1, effectiveRange: nil) != nil)
        #expect(rendered.attribute(.link, at: highlightRange.location, effectiveRange: nil) == nil)
        #expect((rendered.attribute(.underlineStyle, at: highlightRange.location, effectiveRange: nil) as? Int ?? 0) == 0)
    }

    @Test("Legitimate URLs containing double equals remain fully linked")
    func assistantMarkdownRenderingPreservesURLsContainingDoubleEquals() {
        let rust = SalientHighlightApplier.highlightColor(isDark: false)
        let url = "https://example.com/path?token=YWJjZA=="
        let rendered = UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: url,
            baseFont: UIFont.systemFont(ofSize: 15, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            markHighlightColor: rust
        )

        guard let rendered else {
            Issue.record("Expected markdown render result")
            return
        }

        let text = rendered.string as NSString
        let urlRange = text.range(of: url)
        #expect(urlRange.location != NSNotFound)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        #expect(rendered.attribute(.link, at: urlRange.location, effectiveRange: &effectiveRange) != nil)
        #expect(effectiveRange == urlRange)
        #expect(rendered.attribute(.link, at: urlRange.location + urlRange.length - 1, effectiveRange: nil) != nil)
    }

    private func rustColor(isDark: Bool) -> UIColor {
        SalientHighlightApplier.highlightColor(isDark: isDark)
    }

    private func rgb(_ attributed: NSAttributedString, at index: Int) -> RGB? {
        guard index >= 0, index < attributed.length else { return nil }
        guard let color = attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor else {
            return nil
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return RGB(
            red: Int((red * 255).rounded()),
            green: Int((green * 255).rounded()),
            blue: Int((blue * 255).rounded())
        )
    }
}
