import Foundation
import Testing
import UIKit
@testable import Clawline

@Suite(.serialized)
struct TextLinkURLTemplateRulesTests {
    @Test("V1135-01: fresh installs have no configured text link rules")
    @MainActor
    func freshInstallsHaveNoConfiguredTextLinkRules() throws {
        let rendered = try withConfiguredRules([]) {
            try #require(makeRendered("Fix T123 and T1135."))
        }

        #expect(linkTarget("T123", in: rendered) == nil)
        #expect(linkTarget("T1135", in: rendered) == nil)
    }

    @Test("V1135-01: user-created Janus rule links T-number tokens")
    @MainActor
    func userCreatedJanusRuleLinksTicketTokens() throws {
        let rendered = try withConfiguredRules([.janusTrackerExample]) {
            try #require(makeRendered("Fix T123 and T1135, not t1135, AT1135, or T1135abc."))
        }

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
        let rendered = try withConfiguredRules([.janusTrackerExample]) {
            try #require(makeRendered("[T1135](https://example.com/original) and T123"))
        }

        #expect(linkTarget("T1135", in: rendered)?.absoluteString == "https://example.com/original")
        #expect(linkTarget("T123", in: rendered)?.absoluteString == "https://tars.tail4105e8.ts.net:19443/tracker.html?id=T123")
    }

    @Test("V1135-01: explicit links to generated URLs are not treated as generated")
    @MainActor
    func explicitLinksToGeneratedURLsAreNotTreatedAsGenerated() throws {
        let rendered = try withConfiguredRules([.janusTrackerExample]) {
            try #require(makeRendered("[ticket](https://tars.tail4105e8.ts.net:19443/tracker.html?id=T1135) and T1135"))
        }
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

    @Test("V1135-01: settings validation exposes visible invalid rule messages")
    func settingsValidationExposesInvalidRuleMessages() {
        let invalidPattern = TextLinkURLTemplateRule(id: "bad-pattern", enabled: true, pattern: #"("#, urlTemplate: "https://example.com/{match}")
        let badPlaceholder = TextLinkURLTemplateRule(id: "bad-placeholder", enabled: true, pattern: #"T([0-9]+)"#, urlTemplate: "https://example.com/{2}")
        let badURL = TextLinkURLTemplateRule(id: "bad-url", enabled: true, pattern: #"T([0-9]+)"#, urlTemplate: "not a url/{match}")
        let valid = TextLinkURLTemplateRule.janusTrackerExample

        #expect(TextLinkURLTemplateRules.validationMessage(for: invalidPattern)?.contains("bad-pattern") == true)
        #expect(TextLinkURLTemplateRules.validationMessage(for: badPlaceholder)?.contains("bad-placeholder") == true)
        #expect(TextLinkURLTemplateRules.validationMessage(for: badURL)?.contains("bad-url") == true)
        #expect(TextLinkURLTemplateRules.validationMessage(for: valid) == nil)
    }

    @Test("V1135-01: renderer path exposes invalid rule diagnostics")
    @MainActor
    func rendererPathExposesInvalidRuleDiagnostics() {
        var captured: [TextLinkURLTemplateDiagnostic] = []
        let originalRules = TextLinkURLTemplateRules.configuredRules
        let originalSink = TextLinkURLTemplateRules.diagnosticSink
        TextLinkURLTemplateRules.configuredRules = [
            TextLinkURLTemplateRule(id: "renderer-bad-pattern", enabled: true, pattern: #"("#, urlTemplate: "https://example.com/{match}")
        ]
        TextLinkURLTemplateRules.diagnosticSink = { captured.append($0) }
        defer {
            TextLinkURLTemplateRules.configuredRules = originalRules
            TextLinkURLTemplateRules.diagnosticSink = originalSink
        }

        _ = makeRendered("Invalid configuration probe T1135.")

        #expect(captured.first?.ruleID == "renderer-bad-pattern")
        #expect(isInvalidPattern(captured.first?.kind))
    }

    @Test("V1135-01: transcript and notification renderers expose the same generated link")
    @MainActor
    func secondarySurfaceUsesSameGeneratedLink() throws {
        let (transcript, notificationBlocks) = try withConfiguredRules([.janusTrackerExample]) {
            let transcript = try #require(makeRendered("See T1135."))
            let notificationBlocks = CrossChatNotificationMarkdownRenderer.renderBlocks(
                content: "See T1135.",
                messageID: "t1135_notification",
                baseFont: .systemFont(ofSize: 15),
                inkColor: .label,
                lineSpacing: 0,
                isDark: false
            )
            return (transcript, notificationBlocks)
        }
        guard case .attributedText(let notification) = notificationBlocks.first else {
            Issue.record("Expected attributed notification text")
            return
        }

        #expect(linkTarget("T1135", in: transcript) == linkTarget("T1135", in: notification))
    }

    @Test("V1135-01: generated text links suppress external text-view activation")
    @MainActor
    func generatedTextLinksSuppressExternalActivation() throws {
        let rendered = try withConfiguredRules([.janusTrackerExample]) {
            try #require(makeRendered("See T1135 and https://example.com."))
        }
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
    }

    @Test("V1135-01: generated text link tap fallback resolves only generated links")
    @MainActor
    func generatedTextLinkTapFallbackResolvesOnlyGeneratedLinks() throws {
        let rendered = try withConfiguredRules([.janusTrackerExample]) {
            try #require(makeRendered("See T1135 and https://example.com."))
        }
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        UnifiedMarkdownRenderer.configureTextView(textView, delegate: nil)
        textView.attributedText = rendered
        textView.layoutIfNeeded()

        let generatedPoint = point(for: "T1135", in: rendered, textView: textView)
        let explicitPoint = point(for: "https://example.com", in: rendered, textView: textView)
        let generatedURL = try #require(linkTarget("T1135", in: rendered))

        #expect(MessageBubbleUIKitView.generatedTextLinkURL(in: textView, at: generatedPoint) == generatedURL)
        #expect(MessageBubbleUIKitView.generatedTextLinkURL(in: textView, at: explicitPoint) == nil)
        #expect(MessageBubbleUIKitView.generatedTextLinkURL(in: textView, at: CGPoint(x: generatedPoint.x, y: generatedPoint.y + 24)) == nil)
    }

    @Test("V1135-01: settings can add many rules and delete exactly one after confirmation")
    @MainActor
    func settingsCanManageTextLinkRules() {
        let settings = SettingsManager()
        let originalRules = settings.textLinkURLTemplateRules
        defer { settings.textLinkURLTemplateRules = originalRules }
        settings.textLinkURLTemplateRules = []

        for index in 0..<12 {
            settings.addTextLinkURLTemplateRule()
            settings.textLinkURLTemplateRules[index].pattern = #"T\#(index)"#
            settings.textLinkURLTemplateRules[index].urlTemplate = "https://example.com/\(index)/{match}"
        }

        let deletedID = settings.textLinkURLTemplateRules[5].id
        let preservedID = settings.textLinkURLTemplateRules[6].id
        settings.deleteTextLinkURLTemplateRule(id: deletedID)

        #expect(settings.textLinkURLTemplateRules.count == 11)
        #expect(!settings.textLinkURLTemplateRules.contains { $0.id == deletedID })
        #expect(settings.textLinkURLTemplateRules.contains { $0.id == preservedID })
        #expect(TextLinkURLTemplateRules.configuredRules == settings.textLinkURLTemplateRules)

        settings.resetToDefaults()
        #expect(settings.textLinkURLTemplateRules.count == 11)
    }

    @Test("V1135-01: settings UI exposes add, delete, and confirmation controls")
    func settingsUIExposesRuleManagementControls() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Settings/SettingsView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(source.contains("ForEach($settings.textLinkURLTemplateRules)"))
        #expect(source.contains("Label(\"Add Text Link Rule\", systemImage: \"plus\")"))
        #expect(source.contains("Image(systemName: \"xmark.circle\")"))
        #expect(source.contains(".confirmationDialog("))
        #expect(source.contains("settings.deleteTextLinkURLTemplateRule(id: rulePendingDeletion.id)"))
        #expect(source.contains("TextLinkURLTemplateRules.validationMessage(for: rule)"))
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

    private func point(for token: String, in attributed: NSAttributedString, textView: UITextView) -> CGPoint {
        let characterRange = range(token, in: attributed)
        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        return CGPoint(
            x: rect.midX + textView.textContainerInset.left,
            y: rect.midY + textView.textContainerInset.top
        )
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

    @MainActor
    private func withConfiguredRules<T>(_ rules: [TextLinkURLTemplateRule], _ body: () throws -> T) rethrows -> T {
        let originalRules = TextLinkURLTemplateRules.configuredRules
        TextLinkURLTemplateRules.configuredRules = rules
        defer { TextLinkURLTemplateRules.configuredRules = originalRules }
        return try body()
    }
}
