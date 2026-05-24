import Foundation
import Testing
import UIKit
@testable import Clawline

@Suite(.serialized)
struct TextLinkURLTemplateRulesTests {
    @Test("V1135-01: default Janus rule links T-number tokens")
    @MainActor
    func defaultJanusRuleLinksTicketTokens() throws {
        let rendered = try #require(makeRendered("Fix T123 and T1135, not t1135, AT1135, or T1135abc."))

        #expect(linkTarget("T123", in: rendered)?.absoluteString == "https://tars.tail4105e8.ts.net:19443/tracker.html?id=T123")
        #expect(linkTarget("T1135", in: rendered)?.absoluteString == "https://tars.tail4105e8.ts.net:19443/tracker.html?id=T1135")
        #expect(linkTarget("t1135", in: rendered) == nil)
        #expect(linkTarget("AT1135", in: rendered) == nil)
        #expect(linkTarget("T1135abc", in: rendered) == nil)
    }

    @Test("V1135-01: capture placeholders and unsafe characters are percent encoded")
    func capturePlaceholdersAndUnsafeCharactersAreEncoded() {
        let attributed = NSMutableAttributedString(string: "Open J:abc /?&=%#\u{0007}.")
        let diagnostics = TextLinkURLTemplateRules.apply(
            [
                TextLinkURLTemplateRule(
                    id: "custom",
                    enabled: true,
                    pattern: #"J:([^.]*)"#,
                    urlTemplate: "https://example.com/tickets/{1}"
                )
            ],
            to: attributed
        )

        #expect(diagnostics.isEmpty)
        #expect(linkTarget("J:abc /?&=%#\u{0007}", in: attributed)?.absoluteString == "https://example.com/tickets/abc%20%2F%3F%26%3D%25%23%07")
    }

    @Test("V1135-01: explicit links keep their markdown destinations")
    @MainActor
    func explicitLinksKeepTheirDestinations() throws {
        let rendered = try #require(makeRendered("[T1135](https://example.com/original) and T123"))

        #expect(linkTarget("T1135", in: rendered)?.absoluteString == "https://example.com/original")
        #expect(linkTarget("T123", in: rendered)?.absoluteString == "https://tars.tail4105e8.ts.net:19443/tracker.html?id=T123")
    }

    @Test("V1135-01: explicit links to generated URLs are not treated as generated")
    @MainActor
    func explicitLinksToGeneratedURLsAreNotTreatedAsGenerated() throws {
        let rendered = try #require(makeRendered("[ticket](https://tars.tail4105e8.ts.net:19443/tracker.html?id=T1135) and T1135"))
        let explicitRange = range("ticket", in: rendered)
        let generatedRange = range("T1135", in: rendered)
        let sharedURL = try #require(linkTarget("ticket", in: rendered))

        #expect(linkTarget("T1135", in: rendered) == sharedURL)
        #expect(!TextLinkURLTemplateRules.isGeneratedLink(in: rendered, characterRange: explicitRange))
        #expect(TextLinkURLTemplateRules.isGeneratedLink(in: rendered, characterRange: generatedRange))
    }

    @Test("V1135-01: invalid rules report visible diagnostics and do not create dead links")
    func invalidRulesReportDiagnostics() {
        let invalidPattern = NSMutableAttributedString(string: "T1135")
        let patternDiagnostics = TextLinkURLTemplateRules.apply(
            [TextLinkURLTemplateRule(id: "bad-pattern", enabled: true, pattern: #"("#, urlTemplate: "https://example.com/{match}")],
            to: invalidPattern
        )

        let unknownPlaceholder = NSMutableAttributedString(string: "T1135")
        let placeholderDiagnostics = TextLinkURLTemplateRules.apply(
            [TextLinkURLTemplateRule(id: "bad-placeholder", enabled: true, pattern: #"T([0-9]+)"#, urlTemplate: "https://example.com/{missing}")],
            to: unknownPlaceholder
        )

        let invalidURL = NSMutableAttributedString(string: "T1135")
        let urlDiagnostics = TextLinkURLTemplateRules.apply(
            [TextLinkURLTemplateRule(id: "bad-url", enabled: true, pattern: #"T([0-9]+)"#, urlTemplate: "not a url/{match}")],
            to: invalidURL
        )

        #expect(patternDiagnostics.first?.ruleID == "bad-pattern")
        #expect(isInvalidPattern(patternDiagnostics.first?.kind))
        #expect(placeholderDiagnostics.first?.ruleID == "bad-placeholder")
        #expect(isUnresolvedPlaceholder(placeholderDiagnostics.first?.kind))
        #expect(urlDiagnostics.first?.ruleID == "bad-url")
        #expect(isInvalidGeneratedURL(urlDiagnostics.first?.kind))
        #expect(linkTarget("T1135", in: invalidPattern) == nil)
        #expect(linkTarget("T1135", in: unknownPlaceholder) == nil)
        #expect(linkTarget("T1135", in: invalidURL) == nil)
    }

    @Test("V1135-01: renderer path exposes invalid rule diagnostics")
    @MainActor
    func rendererPathExposesInvalidRuleDiagnostics() {
        var captured: [TextLinkURLTemplateDiagnostic] = []
        let originalRules = TextLinkURLTemplateRules.defaultRules
        let originalSink = TextLinkURLTemplateRules.diagnosticSink
        TextLinkURLTemplateRules.defaultRules = [
            TextLinkURLTemplateRule(id: "renderer-bad-pattern", enabled: true, pattern: #"("#, urlTemplate: "https://example.com/{match}")
        ]
        TextLinkURLTemplateRules.diagnosticSink = { captured.append($0) }
        defer {
            TextLinkURLTemplateRules.defaultRules = originalRules
            TextLinkURLTemplateRules.diagnosticSink = originalSink
        }

        _ = makeRendered("Invalid configuration probe T1135.")

        #expect(captured.first?.ruleID == "renderer-bad-pattern")
        #expect(isInvalidPattern(captured.first?.kind))
    }

    @Test("V1135-01: transcript and notification renderers expose the same generated link")
    @MainActor
    func secondarySurfaceUsesSameGeneratedLink() throws {
        let transcript = try #require(makeRendered("See T1135."))
        let notificationBlocks = CrossChatNotificationMarkdownRenderer.renderBlocks(
            content: "See T1135.",
            messageID: "t1135_notification",
            baseFont: .systemFont(ofSize: 15),
            inkColor: .label,
            lineSpacing: 0,
            isDark: false
        )
        guard case .attributedText(let notification) = notificationBlocks.first else {
            Issue.record("Expected attributed notification text")
            return
        }

        #expect(linkTarget("T1135", in: transcript) == linkTarget("T1135", in: notification))
    }

    @Test("V1135-01: generated text links suppress external text-view activation")
    @MainActor
    func generatedTextLinksSuppressExternalActivation() throws {
        let rendered = try #require(makeRendered("See T1135 and https://example.com."))
        let textView = UITextView()
        textView.attributedText = rendered
        let bubble = MessageBubbleUIKitView()
        var openedGeneratedURL: URL?
        let originalGeneratedLinkOpener = GeneratedTextLinkActivationRouter.openGeneratedLink
        GeneratedTextLinkActivationRouter.openGeneratedLink = { url, _ in
            openedGeneratedURL = url
            return true
        }
        defer {
            GeneratedTextLinkActivationRouter.openGeneratedLink = originalGeneratedLinkOpener
        }

        let generatedURL = try #require(linkTarget("T1135", in: rendered))
        let explicitURL = try #require(linkTarget("https://example.com", in: rendered))

        #expect(!bubble.textView(textView, shouldInteractWith: generatedURL, in: range("T1135", in: rendered), interaction: .invokeDefaultAction))
        #expect(bubble.textView(textView, shouldInteractWith: explicitURL, in: range("https://example.com", in: rendered), interaction: .invokeDefaultAction))
        #expect(openedGeneratedURL == generatedURL)
        #expect(TextLinkURLTemplateRules.shouldOpenInInternalBrowser(generatedURL))
    }

    private func makeRendered(_ markdown: String) -> NSAttributedString? {
        UnifiedMarkdownRenderer.renderNSAttributedString(
            markdown: markdown,
            baseFont: .systemFont(ofSize: 15),
            inkColor: .label,
            lineSpacing: 0
        )
    }

    private func linkTarget(_ token: String, in attributed: NSAttributedString) -> URL? {
        let tokenRange = range(token, in: attributed)
        guard tokenRange.location != NSNotFound else { return nil }
        return attributed.attribute(.link, at: tokenRange.location, effectiveRange: nil) as? URL
    }

    private func range(_ token: String, in attributed: NSAttributedString) -> NSRange {
        (attributed.string as NSString).range(of: token)
    }

    private func isInvalidPattern(_ kind: TextLinkURLTemplateDiagnostic.Kind?) -> Bool {
        if case .invalidPattern = kind { return true }
        return false
    }

    private func isUnresolvedPlaceholder(_ kind: TextLinkURLTemplateDiagnostic.Kind?) -> Bool {
        if case .unresolvedPlaceholder = kind { return true }
        return false
    }

    private func isInvalidGeneratedURL(_ kind: TextLinkURLTemplateDiagnostic.Kind?) -> Bool {
        if case .invalidGeneratedURL = kind { return true }
        return false
    }
}
