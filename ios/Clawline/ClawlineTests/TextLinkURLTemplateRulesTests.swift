import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
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

    @Test("T1192: rule display mode is direct by default and Codable")
    func ruleDisplayModeDefaultsToDirectAndCodable() throws {
        let legacyJSON = """
        [{"id":"legacy","enabled":true,"pattern":"T([0-9]+)","urlTemplate":"https://example.com/{match}"}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([TextLinkURLTemplateRule].self, from: legacyJSON)

        #expect(decoded.first?.displayMode == .direct)

        let popupRule = TextLinkURLTemplateRule(
            id: "popup",
            enabled: true,
            pattern: #"T([0-9]+)"#,
            urlTemplate: "https://example.com/{match}",
            displayMode: .popup
        )
        let encoded = try JSONEncoder().encode([popupRule])
        let roundTrip = try JSONDecoder().decode([TextLinkURLTemplateRule].self, from: encoded)

        #expect(roundTrip.first?.displayMode == .popup)
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

    @Test("T190: detected URL followed by a backtick excludes the backtick from link range and URL")
    @MainActor
    func detectedURLFollowedByBacktickExcludesBoundary() throws {
        let rendered = try #require(makeRendered("Open https://example.com/path` then continue."))
        let linkRange = range("https://example.com/path", in: rendered)
        let backtickRange = range("`", in: rendered)

        #expect(linkTarget("https://example.com/path", in: rendered)?.absoluteString == "https://example.com/path")
        #expect(rendered.attribute(.link, at: backtickRange.location, effectiveRange: nil) == nil)
        #expect(rendered.attribute(.link, at: NSMaxRange(linkRange) - 1, effectiveRange: nil) != nil)
    }

    @Test("T190: detected URL keeps normal URL punctuation before a boundary")
    @MainActor
    func detectedURLKeepsNormalURLPunctuationBeforeBoundary() throws {
        let rendered = try #require(makeRendered("Open https://example.com/search?q=a,b.c` now."))

        #expect(linkTarget("https://example.com/search?q=a,b.c", in: rendered)?.absoluteString == "https://example.com/search?q=a,b.c")
        #expect(rendered.attribute(.link, at: range("`", in: rendered).location, effectiveRange: nil) == nil)
    }

    @Test("T1513: Spatial Links submenu exposes detected links using rendered text-link attributes")
    @MainActor
    func spatialLinksSubmenuExposesDetectedLinks() throws {
        let rendered = try withConfiguredRules([.janusTrackerExample]) {
            try #require(makeRendered("See T1513 and https://example.com/details."))
        }
        let menu = try #require(MessageDetectedTextLinkMenuBuilder.linksSubmenu(
            from: rendered,
            isSpatial: true,
            actionHandler: { _ in }
        ))

        #expect(menu.title == "Links")
        #expect(menu.children.count == 2)
        #expect(MessageDetectedTextLinkMenuBuilder.linksSubmenu(from: rendered, isSpatial: false, actionHandler: { _ in }) == nil)
        #expect(MessageDetectedTextLinkMenuBuilder.linksSubmenu(from: makeRendered("No links here."), isSpatial: true, actionHandler: { _ in }) == nil)

        let links = MessageDetectedTextLinkMenuBuilder.detectedTextLinks(from: rendered)
        #expect(links.map(\.title) == ["T1513", "https://example.com/details"])
        #expect(links.first?.url.absoluteString == "https://tars.tail4105e8.ts.net:19443/tracker.html?id=T1513")
        #expect(links.first?.isGenerated == true)
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

    @Test("T1182: notification and full content renderers expose generated Text Link Rules")
    @MainActor
    func notificationAndFullContentRenderersExposeGeneratedTextLinkRules() throws {
        let (notificationBlocks, expandedContent) = withConfiguredRules([.janusTrackerExample]) {
            let notificationBlocks = CrossChatNotificationMarkdownRenderer.renderBlocks(
                content: "Review T1182.",
                messageID: "t1182_notification",
                baseFont: .systemFont(ofSize: 15),
                inkColor: .label,
                lineSpacing: 0,
                isDark: false
            )
            var streamingState = StreamingTableParseState()
            let expandedMessage = Message(
                id: "t1182_full_content",
                role: .assistant,
                content: "Review T1182.",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: "agent:main:clawline:user:s_t1182"
            )
            let metrics = ChatFlowTheme.Metrics(isCompact: false)
            let presentation = MessagePresentationBuilder.build(
                from: expandedMessage,
                metrics: metrics,
                streamingState: &streamingState
            )
            let expandedContent = UnifiedMarkdownRenderer.makeContent(
                messageText: expandedMessage.content,
                context: MarkdownMessageRenderContext(
                    role: expandedMessage.role,
                    messageID: expandedMessage.id,
                    metrics: metrics
                ),
                baseFont: UIFont.clawline(.bodyText),
                inkColor: .label,
                lineSpacing: 4,
                stripDetectedURLs: false,
                isDark: false
            )
            return (notificationBlocks, expandedContent)
        }

        let notification = try #require(firstAttributedText(in: notificationBlocks))
        let expanded = try #require(firstAttributedText(in: expandedContent.renderedBlocks))
        let expectedURL = URL(string: "https://tars.tail4105e8.ts.net:19443/tracker.html?id=T1182")

        #expect(linkTarget("T1182", in: notification) == expectedURL)
        #expect(linkTarget("T1182", in: expanded) == expectedURL)
        #expect(TextLinkURLTemplateRules.isGeneratedLink(in: notification, characterRange: range("T1182", in: notification)))
        #expect(TextLinkURLTemplateRules.isGeneratedLink(in: expanded, characterRange: range("T1182", in: expanded)))
    }

    @Test("T1192: generated link metadata carries each rule display mode")
    @MainActor
    func generatedLinkMetadataCarriesRuleDisplayMode() throws {
        let rules = [
            TextLinkURLTemplateRule(
                id: "modal-ticket",
                enabled: true,
                pattern: #"\bM([0-9]+)\b"#,
                urlTemplate: "https://example.com/modal/{match}",
                displayMode: .modal
            ),
            TextLinkURLTemplateRule(
                id: "popup-ticket",
                enabled: true,
                pattern: #"\bP([0-9]+)\b"#,
                urlTemplate: "https://example.com/popup/{match}",
                displayMode: .popup
            ),
            TextLinkURLTemplateRule(
                id: "direct-ticket",
                enabled: true,
                pattern: #"\bD([0-9]+)\b"#,
                urlTemplate: "https://example.com/direct/{match}",
                displayMode: .direct
            ),
        ]
        let rendered = try withConfiguredRules(rules) {
            try #require(makeRendered("Review M1192, P1192, and D1192."))
        }

        #expect(TextLinkURLTemplateRules.displayMode(in: rendered, characterRange: range("M1192", in: rendered)) == .modal)
        #expect(TextLinkURLTemplateRules.displayMode(in: rendered, characterRange: range("P1192", in: rendered)) == .popup)
        #expect(TextLinkURLTemplateRules.displayMode(in: rendered, characterRange: range("D1192", in: rendered)) == .direct)
    }

    @Test("T1182: full content layout uses compact width and regular reading width")
    func fullContentLayoutUsesCompactWidthAndRegularReadingWidth() {
        let compact = ExpandedMessageSheetLayout.resolve(
            availableWidth: 390,
            isCompact: true,
            compactHorizontalPadding: 16,
            regularOuterPadding: 28,
            regularContentHorizontalPadding: 44,
            regularReadingWidth: 720
        )
        let regular = ExpandedMessageSheetLayout.resolve(
            availableWidth: 1_000,
            isCompact: false,
            compactHorizontalPadding: 16,
            regularOuterPadding: 28,
            regularContentHorizontalPadding: 44,
            regularReadingWidth: 720
        )
        let constrainedRegular = ExpandedMessageSheetLayout.resolve(
            availableWidth: 640,
            isCompact: false,
            compactHorizontalPadding: 16,
            regularOuterPadding: 28,
            regularContentHorizontalPadding: 44,
            regularReadingWidth: 720
        )

        #expect(compact.outerHorizontalPadding == 0)
        #expect(compact.contentWidth == 390)
        #expect(regular.outerHorizontalPadding == 28)
        #expect(regular.contentHorizontalPadding == 44)
        #expect(regular.contentWidth == 720)
        #expect(constrainedRegular.outerHorizontalPadding == 28)
        #expect(constrainedRegular.contentWidth == 584)
    }

    @Test("T1369: full content sheet renders presentation text when selected message content is blank")
    func fullContentSheetRendersPresentationTextForBlankSelectedMessageContent() {
        let message = Message(
            id: "t1369-empty-detail-modal",
            role: .assistant,
            content: "   \n",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: "CLU"
        )
        let presentation = MessagePresentation(
            parts: [.markdown("Recovered detail content")],
            copyableReadableText: "Recovered detail content",
            wordCount: 3,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )
        let blocks = ExpandedMessageSheet.renderedBlocks(
            message: message,
            presentation: presentation,
            baseFont: UIFont.clawline(.bodyText),
            inkColor: .label,
            isDark: false
        )

        #expect(blocks.contains { block in
            if case .attributedText(let attributed) = block {
                return attributed.string.contains("Recovered detail content")
            }
            return false
        })
    }


    @Test("T1578: expanded detail has fallback content instead of an empty modal")
    func expandedDetailShowsFallbackForUnrenderableSelectedBubble() {
        let message = Message(
            id: "t1578-empty-detail",
            role: .assistant,
            content: "   \n",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: "CLU"
        )
        let presentation = MessagePresentation(
            parts: [],
            copyableReadableText: nil,
            wordCount: 0,
            hasTextualContent: false,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )
        let blocks = ExpandedMessageSheet.renderedBlocks(
            message: message,
            presentation: presentation,
            baseFont: UIFont.clawline(.bodyText),
            inkColor: .label,
            isDark: false
        )

        #expect(blocks.isEmpty)
        #expect(ExpandedMessageSheet.shouldShowFallbackDetail(
            renderedBlocks: blocks,
            message: message,
            presentation: presentation
        ))
        #expect(ExpandedMessageSheet.fallbackDetailText(
            message: message,
            presentation: presentation
        ).contains("No detail content"))
        #expect(ExpandedMessageSheet.minimumRegularDetailSize.width >= 420)
        #expect(ExpandedMessageSheet.minimumRegularDetailSize.height >= 320)
    }

    @Test("T1369: expanded detail resolves selected snapshot to canonical message text")
    @MainActor
    func expandedDetailResolvesSelectedSnapshotToCanonicalMessageText() {
        let viewModel = makeT1369ChatViewModel()
        defer { viewModel.onDisappear(origin: "T1369TextDetailTest") }
        let canonical = Message(
            id: "t1369-canonical-detail",
            role: .assistant,
            content: "Canonical detail body survives the selected snapshot.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: "CLU"
        )
        let selectedSnapshot = Message(
            id: canonical.id,
            role: .assistant,
            content: "",
            timestamp: canonical.timestamp,
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: canonical.sessionKey,
            sender: "CLU"
        )
        viewModel.debugUpsertMessage(canonical, isServer: true)

        let resolved = viewModel.expandedDetailMessage(for: selectedSnapshot)
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let presentation = viewModel.presentation(for: resolved, metrics: metrics)
        let blocks = ExpandedMessageSheet.renderedBlocks(
            message: resolved,
            presentation: presentation,
            baseFont: UIFont.clawline(.bodyText),
            inkColor: .label,
            isDark: false
        )

        #expect(resolved.content == canonical.content)
        #expect(blocks.contains { block in
            if case .attributedText(let attributed) = block {
                return attributed.string.contains("Canonical detail body")
            }
            return false
        })
    }

    @Test("T1369: expanded detail does not resolve selected snapshot across sessions")
    @MainActor
    func expandedDetailDoesNotResolveSelectedSnapshotAcrossSessions() {
        let viewModel = makeT1369ChatViewModel()
        defer { viewModel.onDisappear(origin: "T1369CrossSessionDetailTest") }
        let sharedID = "t1369-shared-detail-id"
        let otherSessionMessage = Message(
            id: sharedID,
            role: .assistant,
            content: "Other session content must not appear.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:other",
            sender: "CLU"
        )
        let selectedSnapshot = Message(
            id: sharedID,
            role: .assistant,
            content: "",
            timestamp: otherSessionMessage.timestamp,
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: "CLU"
        )
        viewModel.debugUpsertMessage(otherSessionMessage, isServer: true)

        let resolved = viewModel.expandedDetailMessage(for: selectedSnapshot)

        #expect(resolved.sessionKey == selectedSnapshot.sessionKey)
        #expect(resolved.content == selectedSnapshot.content)
    }

    @Test("T1369: full content sheet renders presentation table when selected message content is blank")
    func fullContentSheetRendersPresentationTableForBlankSelectedMessageContent() {
        let table = TableModel(
            columns: [
                TableModel.Column(alignment: .leading),
                TableModel.Column(alignment: .trailing)
            ],
            header: [
                makeT1369TableCell("Name"),
                makeT1369TableCell("Count")
            ],
            rows: [
                TableModel.Row(
                    id: TableModel.makeRowIdentifier(messageID: "t1369-empty-table-modal", rowIndex: 0, cells: ["Alpha", "1"]),
                    cells: [
                        makeT1369TableCell("Alpha"),
                        makeT1369TableCell("1")
                    ]
                ),
                TableModel.Row(
                    id: TableModel.makeRowIdentifier(messageID: "t1369-empty-table-modal", rowIndex: 1, cells: ["Beta", "2"]),
                    cells: [
                        makeT1369TableCell("Beta"),
                        makeT1369TableCell("2")
                    ]
                )
            ],
            messageID: "t1369-empty-table-modal",
            rowOffset: 0
        )
        let message = Message(
            id: "t1369-empty-table-modal",
            role: .assistant,
            content: "",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: "CLU"
        )
        let presentation = MessagePresentation(
            parts: [.table(table)],
            copyableReadableText: "Name\tCount\nAlpha\t1\nBeta\t2",
            wordCount: 6,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )
        let blocks = ExpandedMessageSheet.renderedBlocks(
            message: message,
            presentation: presentation,
            baseFont: UIFont.clawline(.bodyText),
            inkColor: .label,
            isDark: false
        )

        #expect(blocks.contains { block in
            if case .table(let renderedTable) = block {
                return renderedTable.messageID == table.messageID
                    && renderedTable.rows.count == 2
                    && renderedTable.rows.first?.cells.first?.plainText == "Alpha"
            }
            return false
        })
    }

    @Test("T1369: expanded detail resolves selected snapshot to canonical markdown table")
    @MainActor
    func expandedDetailResolvesSelectedSnapshotToCanonicalMarkdownTable() {
        let viewModel = makeT1369ChatViewModel()
        defer { viewModel.onDisappear(origin: "T1369TableDetailTest") }
        let content = """
        | Name | Count |
        | --- | ---: |
        | Alpha | 1 |
        | Beta | 2 |
        | Gamma | 3 |
        | Delta | 4 |
        | Epsilon | 5 |
        | Zeta | 6 |
        """
        let canonical = Message(
            id: "t1369-canonical-table-detail",
            role: .assistant,
            content: content,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "server:personal",
            sender: "CLU"
        )
        let selectedSnapshot = Message(
            id: canonical.id,
            role: .assistant,
            content: "",
            timestamp: canonical.timestamp,
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: canonical.sessionKey,
            sender: "CLU"
        )
        viewModel.debugUpsertMessage(canonical, isServer: true)

        let resolved = viewModel.expandedDetailMessage(for: selectedSnapshot)
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let presentation = viewModel.presentation(for: resolved, metrics: metrics)
        let blocks = ExpandedMessageSheet.renderedBlocks(
            message: resolved,
            presentation: presentation,
            baseFont: UIFont.clawline(.bodyText),
            inkColor: .label,
            isDark: false
        )

        #expect(resolved.content == content)
        #expect(blocks.contains { block in
            if case .table(let table) = block {
                return table.rows.count == 6
                    && table.rows.first?.cells.first?.plainText == "Alpha"
                    && table.rows.last?.cells.first?.plainText == "Zeta"
            }
            return false
        })
    }

    @MainActor
    private func makeT1369ChatViewModel() -> ChatViewModel {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        return ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: T1369UploadStub(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
    }

    private struct T1369UploadStub: UploadServicing {
        func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
            _ = data
            _ = mimeType
            _ = filename
            return "asset"
        }

        func download(assetId: String) async throws -> Data {
            _ = assetId
            return Data()
        }
    }

    private func makeT1369TableCell(_ value: String) -> TableModel.Cell {
        TableModel.Cell(
            attributed: AttributedString(value),
            intrinsicWidth: 80,
            plainText: value,
            isEmpty: value.isEmpty
        )
    }

    @Test("T1182: selectable notification and full content text activates generated links internally")
    @MainActor
    func selectableTextActivatesGeneratedLinksInternally() throws {
        let rendered = try withConfiguredRules([.janusTrackerExample]) {
            try #require(makeRendered("Review T1182."))
        }
        let generatedURL = try #require(linkTarget("T1182", in: rendered))
        let generatedRange = range("T1182", in: rendered)
        var openedGeneratedURL: URL?
        let originalGeneratedLinkOpener = GeneratedTextLinkActivationRouter.openGeneratedLink
        GeneratedTextLinkActivationRouter.openGeneratedLink = { url, _ in
            openedGeneratedURL = url
            return true
        }
        defer {
            GeneratedTextLinkActivationRouter.openGeneratedLink = originalGeneratedLinkOpener
        }

        let host = UIHostingController(
            rootView: SelectableAttributedText(
                attributedString: rendered,
                alignment: .left,
                colorScheme: .light,
                onSelectionChange: { _ in },
                onLinkTap: { _ in Issue.record("Generated links should not use the fallback link tap closure") }
            )
            .frame(width: 280)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let textView = try #require(textViews(in: host.view).first)
        let shouldInteract = textView.delegate?.textView?(
            textView,
            shouldInteractWith: generatedURL,
            in: generatedRange,
            interaction: UITextItemInteraction.invokeDefaultAction
        )

        #expect(shouldInteract == false)
        #expect(openedGeneratedURL == generatedURL)
    }

    @Test("T1250: selectable notification text reset clears selection and allows fresh selections")
    @MainActor
    func selectableNotificationTextResetClearsSelectionAndAllowsFreshSelections() throws {
        let rendered = NSAttributedString(string: "Selectable notification text")
        var firstSelectionStates: [Bool] = []
        var secondSelectionStates: [Bool] = []
        let firstHost = UIHostingController(
            rootView: SelectableAttributedText(
                attributedString: rendered,
                alignment: .left,
                colorScheme: .light,
                selectionResetToken: 0,
                onSelectionChange: { firstSelectionStates.append($0) },
                onLinkTap: { _ in }
            )
            .frame(width: 280)
        )
        let secondHost = UIHostingController(
            rootView: SelectableAttributedText(
                attributedString: rendered,
                alignment: .left,
                colorScheme: .light,
                selectionResetToken: 0,
                onSelectionChange: { secondSelectionStates.append($0) },
                onLinkTap: { _ in }
            )
            .frame(width: 280)
        )
        let stack = UIStackView(arrangedSubviews: [firstHost.view, secondHost.view])
        stack.axis = .vertical
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        let container = UIViewController()
        container.view.addSubview(stack)
        window.rootViewController = container
        window.makeKeyAndVisible()
        stack.frame = window.bounds
        firstHost.view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        secondHost.view.frame = CGRect(x: 0, y: 110, width: 320, height: 100)
        firstHost.view.setNeedsLayout()
        secondHost.view.setNeedsLayout()
        firstHost.view.layoutIfNeeded()
        secondHost.view.layoutIfNeeded()

        let firstTextView = try #require(textViews(in: firstHost.view).first)
        let secondTextView = try #require(textViews(in: secondHost.view).first)

        firstTextView.selectedRange = NSRange(location: 0, length: 10)
        firstTextView.delegate?.textViewDidChangeSelection?(firstTextView)
        #expect(firstSelectionStates.last == true)

        firstHost.rootView = SelectableAttributedText(
            attributedString: rendered,
            alignment: .left,
            colorScheme: .light,
            selectionResetToken: 1,
            onSelectionChange: { firstSelectionStates.append($0) },
            onLinkTap: { _ in }
        )
        .frame(width: 280)
        firstHost.view.setNeedsLayout()
        firstHost.view.layoutIfNeeded()

        #expect(firstTextView.selectedRange.length == 0)
        #expect(firstSelectionStates.last == false)

        firstTextView.selectedRange = NSRange(location: 11, length: 12)
        firstTextView.delegate?.textViewDidChangeSelection?(firstTextView)
        secondTextView.selectedRange = NSRange(location: 0, length: 10)
        secondTextView.delegate?.textViewDidChangeSelection?(secondTextView)

        #expect(firstSelectionStates.last == true)
        #expect(secondSelectionStates.last == true)
    }

    @Test("T1192/T1370: chat generated link taps honor direct, modal, and popup display modes")
    @MainActor
    func chatGeneratedLinkTapsHonorDisplayModes() throws {
        let cases: [(TextLinkResolvedURLDisplayMode, String)] = [
            (.direct, "D1192"),
            (.modal, "M1192"),
            (.popup, "P1192"),
        ]
        let rules = cases.map { mode, token in
            TextLinkURLTemplateRule(
                id: "\(mode.rawValue)-ticket",
                enabled: true,
                pattern: #"\#(token)"#,
                urlTemplate: "https://example.com/\(mode.rawValue)/{match}",
                displayMode: mode
            )
        }
        let rendered = try withConfiguredRules(rules) {
            try #require(makeRendered("Open D1192 M1192 P1192."))
        }

        var directURLs: [URL] = []
        var modalURLs: [URL] = []
        var popupURLs: [URL] = []
        let originalGeneratedLinkOpener = GeneratedTextLinkActivationRouter.openGeneratedLink
        let originalModalPresenter = GeneratedTextLinkActivationRouter.presentResolvedURLModal
        let originalPopupPresenter = GeneratedTextLinkActivationRouter.presentResolvedURLPopup
        GeneratedTextLinkActivationRouter.openGeneratedLink = { url, _ in
            directURLs.append(url)
            return true
        }
        GeneratedTextLinkActivationRouter.presentResolvedURLModal = { url, _ in
            modalURLs.append(url)
            return true
        }
        GeneratedTextLinkActivationRouter.presentResolvedURLPopup = { url, _ in
            popupURLs.append(url)
            return true
        }
        defer {
            GeneratedTextLinkActivationRouter.openGeneratedLink = originalGeneratedLinkOpener
            GeneratedTextLinkActivationRouter.presentResolvedURLModal = originalModalPresenter
            GeneratedTextLinkActivationRouter.presentResolvedURLPopup = originalPopupPresenter
        }

        let textView = UITextView()
        textView.attributedText = rendered
        let bubble = MessageBubbleUIKitView()

        for (mode, token) in cases {
            let tokenRange = range(token, in: rendered)
            let url = try #require(linkTarget(token, in: rendered))
            #expect(!bubble.textView(textView, shouldInteractWith: url, in: tokenRange, interaction: .invokeDefaultAction))
            #expect(TextLinkURLTemplateRules.displayMode(in: rendered, characterRange: tokenRange) == mode)
        }

        #expect(directURLs.map(\.absoluteString) == ["https://example.com/direct/D1192"])
        #expect(modalURLs.map(\.absoluteString) == ["https://example.com/modal/M1192"])
        #expect(popupURLs.map(\.absoluteString) == ["https://example.com/popup/P1192"])
    }

    @Test("T1370: popup display mode tap opens resolved URL content")
    @MainActor
    func popupDisplayModeTapOpensResolvedURLContent() throws {
        let popupRule = TextLinkURLTemplateRule(
            id: "popup",
            enabled: true,
            pattern: #"T([0-9]+)"#,
            urlTemplate: "https://example.com/popup/{match}",
            displayMode: .popup
        )
        let rendered = try withConfiguredRules([popupRule]) {
            try #require(makeRendered("Open T1370."))
        }
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        UnifiedMarkdownRenderer.configureTextView(textView, delegate: nil)
        textView.attributedText = rendered
        textView.layoutIfNeeded()

        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = presenter
        window.isHidden = false
        presenter.view.addSubview(textView)
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let expectedURL = try #require(linkTarget("T1370", in: rendered))
        let bubble = MessageBubbleUIKitView()
        #expect(!bubble.textView(
            textView,
            shouldInteractWith: expectedURL,
            in: range("T1370", in: rendered),
            interaction: .invokeDefaultAction
        ))
        let popup = try #require(presenter.presentedViewController as? TextLinkResolvedURLContentViewController)
        popup.loadViewIfNeeded()
        #expect(popup.isPopup(for: expectedURL))
        #expect(webViews(in: popup.view).first?.url == expectedURL)
    }

    @Test("T1192: popup display mode is presented by hover route")
    @MainActor
    func popupDisplayModeUsesHoverRoute() throws {
        let popupURL = try #require(URL(string: "https://example.com/popup/P1192"))
        var popupURLs: [URL] = []
        let originalPopupPresenter = GeneratedTextLinkActivationRouter.presentResolvedURLPopup
        GeneratedTextLinkActivationRouter.presentResolvedURLPopup = { url, _ in
            popupURLs.append(url)
            return true
        }
        defer {
            GeneratedTextLinkActivationRouter.presentResolvedURLPopup = originalPopupPresenter
        }

        #expect(GeneratedTextLinkActivationRouter.presentResolvedURLPopup(popupURL, nil))
        #expect(popupURLs == [popupURL])
    }

    @Test("T1192: popup hover route carries anchor point")
    @MainActor
    func popupHoverRouteCarriesAnchorPoint() throws {
        let popupURL = try #require(URL(string: "https://example.com/popup/P1192"))
        let anchor = CGPoint(x: 44, y: 18)
        var received: (URL, UIView?, CGPoint?)?
        let originalPopupPresenter = GeneratedTextLinkActivationRouter.presentResolvedURLPopupAnchored
        GeneratedTextLinkActivationRouter.presentResolvedURLPopupAnchored = { url, view, point in
            received = (url, view, point)
            return true
        }
        defer {
            GeneratedTextLinkActivationRouter.presentResolvedURLPopupAnchored = originalPopupPresenter
        }

        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 280, height: 80))
        #expect(GeneratedTextLinkActivationRouter.presentResolvedURLPopupAnchored(popupURL, textView, anchor))
        #expect(received?.0 == popupURL)
        #expect(received?.1 === textView)
        #expect(received?.2 == anchor)
    }

    @Test("D11/R1135-11/T1341: popup resolved URL chrome keeps clear outer background and overlaid close control")
    @MainActor
    func popupResolvedURLPresentationUsesClearOuterBackgroundAndOverlaidCloseControl() throws {
        let popupURL = try #require(URL(string: "https://example.com/popup/P1192"))
        let controller = TextLinkResolvedURLContentViewController(
            url: popupURL,
            presentation: .popup,
            anchorPoint: CGPoint(x: 80, y: 90)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }

        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        #expect(controller.view.backgroundColor == .clear)
        let webView = try #require(webViews(in: controller.view).first)
        #expect(webView.frame.width >= 320)
        #expect(webView.frame.height >= 280)
        let closeButton = try #require(buttons(in: controller.view).first { !$0.isHidden })
        #expect(closeButton.accessibilityLabel == "Close resolved URL")

        let webFrame = webView.convert(webView.bounds, to: controller.view)
        let closeFrame = closeButton.convert(closeButton.bounds, to: controller.view)
        #expect(webFrame.intersects(closeFrame))
        #expect(closeFrame.minY < webFrame.minY)
        #expect(closeFrame.maxX > webFrame.maxX)

        let visibleFloatingPoint = CGPoint(x: closeFrame.maxX - 4, y: closeFrame.midY)
        #expect(!webFrame.contains(visibleFloatingPoint))
        #expect(closeFrame.contains(visibleFloatingPoint))
        #expect(controller.view.hitTest(visibleFloatingPoint, with: nil) === closeButton)
    }

    @Test("T1192: popup layout keeps edge hover point inside content")
    @MainActor
    func popupLayoutKeepsEdgeHoverPointInsideContent() throws {
        let popupURL = try #require(URL(string: "https://example.com/popup/P1192"))
        let anchor = CGPoint(x: 790, y: 590)
        let controller = TextLinkResolvedURLContentViewController(
            url: popupURL,
            presentation: .popup,
            anchorPoint: anchor
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }

        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let webView = try #require(webViews(in: controller.view).first)
        let contentFrame = webView.convert(webView.bounds, to: controller.view)
        #expect(contentFrame.contains(CGPoint(x: 781, y: 581)))
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

    @Test("T1370: popup hover presents content from larger generated-link target")
    @MainActor
    func generatedTextLinkHoverPresentsPopupFromLargerTarget() throws {
        let popupRule = TextLinkURLTemplateRule(
            id: "popup",
            enabled: true,
            pattern: #"T([0-9]+)"#,
            urlTemplate: "https://example.com/popup/{match}",
            displayMode: .popup
        )
        let rendered = try withConfiguredRules([popupRule]) {
            try #require(makeRendered("See T1370."))
        }
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        UnifiedMarkdownRenderer.configureTextView(textView, delegate: nil)
        textView.attributedText = rendered
        textView.layoutIfNeeded()

        let characterRange = range("T1370", in: rendered)
        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        let hoverPoint = CGPoint(
            x: rect.maxX + textView.textContainerInset.left + 6,
            y: rect.midY + textView.textContainerInset.top
        )
        let expectedURL = try #require(linkTarget("T1370", in: rendered))
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = presenter
        window.isHidden = false
        presenter.view.addSubview(textView)
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        #expect(MessageBubbleUIKitView.generatedTextLinkURL(in: textView, at: hoverPoint) == nil)
        #expect(MessageBubbleUIKitView.presentGeneratedTextLinkPopupForHover(in: textView, at: hoverPoint))
        let popup = try #require(presenter.presentedViewController as? TextLinkResolvedURLContentViewController)
        popup.loadViewIfNeeded()
        popup.view.frame = presenter.view.bounds
        popup.view.setNeedsLayout()
        popup.view.layoutIfNeeded()
        #expect(webViews(in: popup.view).first?.url == expectedURL)
    }

    @Test("T1370: popup hover replaces stale resolved URL content")
    @MainActor
    func generatedTextLinkHoverReplacesStaleResolvedURLContent() throws {
        let popupRule = TextLinkURLTemplateRule(
            id: "popup",
            enabled: true,
            pattern: #"T([0-9]+)"#,
            urlTemplate: "https://example.com/popup/{match}",
            displayMode: .popup
        )
        let rendered = try withConfiguredRules([popupRule]) {
            try #require(makeRendered("See T1370."))
        }
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        UnifiedMarkdownRenderer.configureTextView(textView, delegate: nil)
        textView.attributedText = rendered
        textView.layoutIfNeeded()

        let expectedURL = try #require(linkTarget("T1370", in: rendered))
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = presenter
        window.isHidden = false
        presenter.view.addSubview(textView)
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animationsWereEnabled)
            window.isHidden = true
        }

        let staleController = TextLinkResolvedURLContentViewController(
            url: try #require(URL(string: "https://example.com/popup/stale")),
            presentation: .popup
        )
        presenter.present(staleController, animated: false)

        #expect(MessageBubbleUIKitView.presentGeneratedTextLinkPopupForHover(
            in: textView,
            at: point(for: "T1370", in: rendered, textView: textView)
        ))
        let popup = try #require(presenter.presentedViewController as? TextLinkResolvedURLContentViewController)
        popup.loadViewIfNeeded()
        #expect(popup.isPopup(for: expectedURL))
        #expect(webViews(in: popup.view).first?.url == expectedURL)
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
        #expect(source.contains("Picker(\"Display URL\", selection: $rule.displayMode)"))
        #expect(source.contains("TextLinkResolvedURLDisplayMode.allCases"))
    }

    private func makeRendered(_ markdown: String) -> NSAttributedString? {
        attributedMarkdownForTests(
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

    private func firstAttributedText(in blocks: [RenderedMarkdownBlock]) -> NSAttributedString? {
        for block in blocks {
            if case .attributedText(let attributed) = block {
                return attributed
            }
        }
        return nil
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var matches: [UITextView] = []
        if let textView = view as? UITextView {
            matches.append(textView)
        }
        for subview in view.subviews {
            matches.append(contentsOf: textViews(in: subview))
        }
        return matches
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        var matches: [WKWebView] = []
        if let webView = view as? WKWebView {
            matches.append(webView)
        }
        for subview in view.subviews {
            matches.append(contentsOf: webViews(in: subview))
        }
        return matches
    }

    private func buttons(in view: UIView) -> [UIButton] {
        var matches: [UIButton] = []
        if let button = view as? UIButton {
            matches.append(button)
        }
        for subview in view.subviews {
            matches.append(contentsOf: buttons(in: subview))
        }
        return matches
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
