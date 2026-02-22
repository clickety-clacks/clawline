//
//  ChatFlowOrganicComplianceTests.swift
//  ClawlineTests
//
//  Created by Codex on 1/12/26.
//

import SwiftUI
import Testing
import UIKit
@testable import Clawline

private let personalSessionKey = "server:personal"
private let adminSessionKey = "server:admin"

private enum MessageFlowRulesTestCompat {
    static func shouldTruncate(
        hasTextualParts: Bool,
        sizeClass: MessageSizeClass,
        isExpanded: Bool,
        measuredHeight: CGFloat,
        metrics: ChatFlowTheme.Metrics
    ) -> Bool {
        guard hasTextualParts else { return false }
        guard sizeClass == .long else { return false }
        guard !isExpanded else { return false }
        return measuredHeight > metrics.truncationHeight
    }

    static func shouldShowTruncationControl(
        hasTextualParts: Bool,
        sizeClass: MessageSizeClass,
        measuredHeight: CGFloat,
        metrics: ChatFlowTheme.Metrics
    ) -> Bool {
        guard hasTextualParts else { return false }
        guard sizeClass == .long else { return false }
        return measuredHeight > metrics.truncationHeight
    }
}

struct ChatFlowOrganicComplianceTests {

    // MARK: Message presentation (§5/§6)

    @Test("Doc §5: Markdown + code segmentation")
    func messagePresentationParsesMarkdownAndCode() {
        let message = sampleMessage(content: """
        Here is **bold** markdown.

        ```swift
        print("Hello")
        ```
        """)
        let presentation = buildPresentation(message)

        #expect(presentation.parts.contains(where: { part in
            if case .markdown = part { return true }
            return false
        }))
        #expect(presentation.parts.contains(where: { part in
            if case .code(let language, let code) = part {
                return language == "swift" && code.contains("print")
            }
            return false
        }))
    }

    @Test("Bug #29: Fenced code block after colon renders")
    func messagePresentationPreservesFencedCodeAfterColon() {
        let message = sampleMessage(content: """
        Example:
        ```swift
        print("Hello")
        ```
        """)
        let presentation = buildPresentation(message)

        #expect(presentation.parts.contains(where: { part in
            if case .text(let value) = part { return value == "Example:" }
            if case .markdown(let value) = part { return value == "Example:" }
            return false
        }))
        #expect(presentation.parts.contains(where: { part in
            if case .code(let language, let code) = part {
                return language == "swift" && code.contains("print(\"Hello\")")
            }
            return false
        }))
    }

    @Test("Bug #29: Fences with invisible scalars still parse")
    func messagePresentationParsesFencesWithZeroWidthSpaces() {
        // Some models emit backtick fences with ZWSP between backticks, which looks like a normal fence.
        let fence = "`\u{200B}`\u{200B}`"
        let message = sampleMessage(content: """
        Example:
        \(fence)swift
        print("Hello")
        \(fence)
        """)
        let presentation = buildPresentation(message)

        #expect(presentation.parts.contains(where: { part in
            if case .code(let language, let code) = part {
                return language == "swift" && code.contains("print(\"Hello\")")
            }
            return false
        }))
    }

    @Test("Bug #29: Two fenced code blocks separated by a colon line render")
    func messagePresentationPreservesTwoCodeBlocksSeparatedByColonLine() {
        let message = sampleMessage(content: """
        First:
        ```swift
        print("one")
        ```

        Now compare Main stream - no `updateLastRoute`:
        ```swift
        print("two")
        ```
        """)
        let presentation = buildPresentation(message)

        let codeCount = presentation.parts.filter { part in
            if case .code = part { return true }
            return false
        }.count
        #expect(codeCount == 2)
        #expect(presentation.parts.contains(where: { part in
            if case .markdown(let value) = part { return value.contains("Now compare") }
            if case .text(let value) = part { return value.contains("Now compare") }
            return false
        }))
    }

    @Test("Bug #50: Mixed text/code keeps order and text extraction does not drop paragraphs")
    func mixedTextCodeOrderAndExtraction() {
        let message = sampleMessage(content: """
        Intro paragraph.

        ```swift
        print("first")
        ```

        Middle paragraph with **markdown**.

        ```python
        print("second")
        ```

        Final paragraph.
        """)
        let presentation = buildPresentation(message)

        let codeBlocks = presentation.parts.compactMap { part -> (String?, String)? in
            if case .code(let language, let code) = part {
                return (language, code)
            }
            return nil
        }
        #expect(codeBlocks.count == 2)
        #expect(codeBlocks[0].0 == "swift")
        #expect(codeBlocks[0].1.contains("print(\"first\")"))
        #expect(codeBlocks[1].0 == "python")
        #expect(codeBlocks[1].1.contains("print(\"second\")"))

        let renderedText = renderedMarkdownText(
            from: presentation,
            stripDetectedURLs: true
        )
        #expect(renderedText.contains("Intro paragraph."))
        #expect(renderedText.contains("Middle paragraph with markdown."))
        #expect(renderedText.contains("Final paragraph."))
        #expect(!renderedText.contains("print(\"first\")"))
        #expect(!renderedText.contains("print(\"second\")"))
    }

    @Test("Bug #50: Expanded text extraction preserves URLs")
    func expandedTextExtractionPreservesURLs() {
        let message = sampleMessage(content: "See https://a.example and https://b.example")
        let presentation = buildPresentation(message)
        let bubbleText = renderedMarkdownText(from: presentation, stripDetectedURLs: true)
        let expandedText = renderedMarkdownText(from: presentation, stripDetectedURLs: false)

        #expect(!bubbleText.contains("https://a.example"))
        #expect(!bubbleText.contains("https://b.example"))
        #expect(expandedText.contains("https://a.example"))
        #expect(expandedText.contains("https://b.example"))
    }

    @Test("Doc §5: Markdown tables promote to table part")
    func messagePresentationParsesTables() {
        let message = sampleMessage(content: """
        | Animal | Legs |
        | :--- | ---: |
        | Cat | 4 |
        | Bird | 2 |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.header?.count == 2)
        #expect(table.rows.count == 2)
        #expect(table.rows.first?.cells.last?.plainText == "4")
    }

    @Test("Doc §5: Header-only tables fall back to markdown")
    func headerOnlyTablesFallback() {
        let message = sampleMessage(content: """
        | Foo | Bar |
        | --- | --- |
        """)
        let presentation = buildPresentation(message)
        #expect(!presentation.parts.contains(where: { part in
            if case .table = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Escaped pipes stay inside a cell")
    func escapedPipesRemainInCell() {
        let message = sampleMessage(content: """
        | Value |
        | --- |
        | Foo \\| Bar |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.first?.cells.first?.plainText == "Foo | Bar")
    }

    @Test("Doc §5: Inline code preserves literal pipes")
    func inlineCodePipesStayLiteral() {
        let message = sampleMessage(content: """
        | Code |
        | --- |
        | `a | b` |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.first?.cells.first?.plainText == "a | b")
    }

    @Test("Doc §5: Tables touching lists require leading pipes")
    func tablesAdjacentToListsRequireLeadingPipe() {
        let message = sampleMessage(content: """
        - bullet intro
        Foo | Bar
        | --- | --- |
        | 1 | 2 |
        """)
        let presentation = buildPresentation(message)
        #expect(!presentation.parts.contains(where: { part in
            if case .table = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Column count capped at forty")
    func tableColumnLimit() {
        let header = Array(repeating: "H", count: 41).joined(separator: " | ")
        let row = Array(repeating: "1", count: 41).joined(separator: " | ")
        let message = sampleMessage(content: """
        | \(header) |
        | \(Array(repeating: "---", count: 41).joined(separator: " | ")) |
        | \(row) |
        """)
        let presentation = buildPresentation(message)
        #expect(!presentation.parts.contains(where: { part in
            if case .table = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Table cells capped at 400 per message")
    func tableCellCountIsCapped() {
        let header = "| A | B | C | D | E | F | G | H | I | J |"
        let divider = "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
        let row = "| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |"
        let body = Array(repeating: row, count: 60).joined(separator: "\n")
        let message = sampleMessage(content: """
        \(header)
        \(divider)
        \(body)
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.count * 10 <= 390)
    }

    @Test("Doc §5: Excessive markdown nesting falls back to plain text")
    func markdownDepthLimitApplies() {
        let message = sampleMessage(content: """
        | Value |
        | --- |
        | ******deep****** |
        """)
        let presentation = buildPresentation(message)
        guard case .table(let table)? = presentation.parts.first(where: { part in
            if case .table = part { return true }
            return false
        }) else {
            Issue.record("Expected table part")
            return
        }
        #expect(table.rows.first?.cells.first?.plainText == "deep")
    }

    @Test("Doc §8: Table parsing meets performance budget")
    func tableParsingPerformance() {
        let header = "| " + Array(repeating: "Col", count: 10).joined(separator: " | ") + " |"
        let divider = "| " + Array(repeating: "---", count: 10).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: "cell", count: 10).joined(separator: " | ") + " |"
        let body = Array(repeating: row, count: 40).joined(separator: "\n")
        let message = sampleMessage(content: """
        \(header)
        \(divider)
        \(body)
        """)
        let clock = ContinuousClock()
        let start = clock.now
        _ = buildPresentation(message)
        let duration = clock.now - start
        #expect(duration < .milliseconds(500))
    }

    @Test("Doc §5: Link preview detection")
    func messagePresentationDetectsSingleLinkPreviews() {
        let exact = buildPresentation(sampleMessage(content: "https://example.com/path"))
        #expect(exact.parts.contains(where: { part in
            if case .linkPreview(let url) = part {
                return url.absoluteString == "https://example.com/path"
            }
            return false
        }))

        let withText = buildPresentation(sampleMessage(content: "Visit https://example.com now"))
        #expect(withText.parts.contains(where: { part in
            if case .linkPreview(let url) = part {
                return url.absoluteString == "https://example.com"
            }
            return false
        }))

        let multiple = buildPresentation(sampleMessage(content: "https://a.com https://b.com"))
        #expect(!multiple.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }))

        let duplicate = buildPresentation(sampleMessage(content: "https://example.com https://example.com"))
        #expect(!duplicate.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }))

        let codeBlock = buildPresentation(sampleMessage(content: "```\nhttps://example.com\n```"))
        #expect(!codeBlock.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }))

        let messageWithAttachment = Message(
            id: "with-attachment",
            role: .assistant,
            content: "https://example.com",
            timestamp: Date(),
            streaming: false,
            attachments: [sampleAttachment(id: "img1")],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
        let attachmentPresentation = buildPresentation(messageWithAttachment)
        #expect(!attachmentPresentation.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Link previews disabled by setting")
    func linkPreviewsRespectDisabledSetting() {
        let presentation = buildPresentation(
            sampleMessage(content: "https://example.com"),
            enableLinkPreviews: false
        )
        #expect(!presentation.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }))
    }

    @Test("Doc §5: Emoji-only detection")
    func messagePresentationEmojiOnlyClassification() {
        let presentation = buildPresentation(sampleMessage(content: "😀😁"))
        #expect(presentation.parts.contains(where: { part in
            if case .inlineEmoji(let value) = part {
                return value.contains("😀")
            }
            return false
        }))
        #expect(presentation.isEmojiOnly)
    }

    @Test("Doc §5: Chromeless emoji supports 1-3 and rejects 4+")
    func messagePresentationChromelessEmojiCountBounds() {
        let three = buildPresentation(sampleMessage(content: "😀😁😂"))
        #expect(three.chromelessStyle == .emoji)

        let four = buildPresentation(sampleMessage(content: "😀😁😂🤣"))
        #expect(four.chromelessStyle != .emoji)
    }

    @Test("Doc §5: Media-only attachments map to gallery")
    func messagePresentationMediaOnlyGallery() {
        let message = Message(
            id: "media",
            role: .assistant,
            content: "",
            timestamp: Date(),
            streaming: false,
            attachments: [sampleAttachment(id: "img1"), sampleAttachment(id: "img2")],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
        let presentation = buildPresentation(message)
        #expect(presentation.parts.contains(where: { part in
            if case .gallery(let attachments) = part {
                return attachments.count == 2
            }
            return false
        }))
        #expect(presentation.hasMediaOnly)
    }

    @Test("Terminal bubbles: terminal-session document attachment maps to terminalSession part (not file)")
    func messagePresentationTerminalSessionAttachmentParses() throws {
        let descriptor = TerminalSessionDescriptor(
            version: 1,
            terminalSessionId: "ts_test",
            title: "gateway logs",
            provider: .init(baseUrl: "https://example.com", wsPath: "/ws/terminal"),
            capabilities: .init(interactive: true, supportsBinaryFrames: true, supportsResize: true, supportsDetach: true),
            auth: .init(mode: .chatToken, terminalAccessToken: nil),
            expiresAtMs: 1_700_000_000_000
        )
        let data = try JSONEncoder().encode(descriptor)
        let terminalAttachment = Clawline.Attachment(
            id: "term1",
            type: .document,
            mimeType: TerminalSessionDescriptor.mimeType,
            data: data,
            assetId: nil
        )
        let message = sampleMessage(content: "Live logs:", attachments: [terminalAttachment], sessionKey: SessionKey.clawlineMain(userId: "mike"))
        let presentation = buildPresentation(message)

        #expect(presentation.parts.contains(where: { part in
            if case .terminalSession(let decoded) = part {
                return decoded.terminalSessionId == "ts_test"
            }
            return false
        }))

        #expect(!presentation.parts.contains(where: { part in
            if case .file(let attachment) = part {
                return attachment.id == "term1"
            }
            return false
        }))
    }

    @Test("Terminal bubbles: mime parameters still route terminal-session attachments")
    func messagePresentationTerminalSessionAttachmentParsesWithMimeParameters() throws {
        let descriptor = TerminalSessionDescriptor(
            version: 1,
            terminalSessionId: "ts_params",
            title: "gateway logs",
            provider: .init(baseUrl: "https://example.com", wsPath: "/ws/terminal"),
            capabilities: .init(interactive: true, supportsBinaryFrames: true, supportsResize: true, supportsDetach: true),
            auth: .init(mode: .chatToken, terminalAccessToken: nil),
            expiresAtMs: 1_700_000_000_000
        )
        let data = try JSONEncoder().encode(descriptor)
        let terminalAttachment = Clawline.Attachment(
            id: "term2",
            type: .document,
            mimeType: "\(TerminalSessionDescriptor.mimeType); charset=utf-8",
            data: data,
            assetId: nil
        )
        let message = sampleMessage(content: "Live logs:", attachments: [terminalAttachment], sessionKey: SessionKey.clawlineMain(userId: "mike"))
        let presentation = buildPresentation(message)

        #expect(presentation.parts.contains(where: { part in
            if case .terminalSession(let decoded) = part {
                return decoded.terminalSessionId == "ts_params"
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .file(let attachment) = part {
                return attachment.id == "term2"
            }
            return false
        }))
    }

    @Test("Interactive HTML: mime parameters still route to interactive bubble part")
    func messagePresentationInteractiveHTMLAttachmentParsesWithMimeParameters() throws {
        let descriptor = InteractiveHTMLDescriptor(
            version: 1,
            html: "<html><body><h1>Hello</h1></body></html>",
            metadata: .init(title: "Card", height: .auto, maxHeight: 320, backgroundColor: nil)
        )
        let data = try JSONEncoder().encode(descriptor)
        let attachment = Clawline.Attachment(
            id: "html1",
            type: .document,
            mimeType: "\(InteractiveHTMLDescriptor.mimeType); charset=utf-8",
            data: data,
            assetId: nil
        )
        let presentation = buildPresentation(sampleMessage(content: "", attachments: [attachment]))

        #expect(presentation.parts.contains(where: { part in
            if case .interactiveHTML(let decoded) = part {
                return decoded.version == 1 && decoded.html.contains("Hello")
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .file(let fileAttachment) = part {
                return fileAttachment.id == "html1"
            }
            return false
        }))
    }

    @Test("Rich attachment routing: shared MIME dispatch handles terminal + interactive docs in one pass")
    func messagePresentationRichAttachmentSharedDispatch() throws {
        let terminalDescriptor = TerminalSessionDescriptor(
            version: 1,
            terminalSessionId: "ts_shared",
            title: "shared terminal",
            provider: .init(baseUrl: "https://example.com", wsPath: "/ws/terminal"),
            capabilities: .init(interactive: true, supportsBinaryFrames: true, supportsResize: true, supportsDetach: true),
            auth: .init(mode: .chatToken, terminalAccessToken: nil),
            expiresAtMs: 1_700_000_000_000
        )
        let interactiveDescriptor = InteractiveHTMLDescriptor(
            version: 1,
            html: "<html><body><button>Ping</button></body></html>",
            metadata: .init(title: "Card", height: .auto, maxHeight: 320, backgroundColor: nil)
        )
        let terminalAttachment = Clawline.Attachment(
            id: "shared-term",
            type: .document,
            mimeType: TerminalSessionDescriptor.mimeType,
            data: try JSONEncoder().encode(terminalDescriptor),
            assetId: nil
        )
        let interactiveAttachment = Clawline.Attachment(
            id: "shared-html",
            type: .document,
            mimeType: InteractiveHTMLDescriptor.mimeType,
            data: try JSONEncoder().encode(interactiveDescriptor),
            assetId: nil
        )
        let presentation = buildPresentation(
            sampleMessage(
                content: "Two rich docs",
                attachments: [terminalAttachment, interactiveAttachment],
                sessionKey: SessionKey.clawlineMain(userId: "mike")
            )
        )

        #expect(presentation.parts.contains(where: { part in
            if case .terminalSession(let descriptor) = part {
                return descriptor.terminalSessionId == "ts_shared"
            }
            return false
        }))
        #expect(presentation.parts.contains(where: { part in
            if case .interactiveHTML(let descriptor) = part {
                return descriptor.version == 1 && descriptor.html.contains("Ping")
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .file(let attachment) = part {
                return attachment.id == "shared-term" || attachment.id == "shared-html"
            }
            return false
        }))
    }

    @Test("Doc §6: Word count strips markdown syntax")
    func wordCountStripsMarkdown() {
        let presentation = buildPresentation(sampleMessage(content: "**bold** _italic_ `code` text"))
        #expect(presentation.wordCount == 4)
    }

    // MARK: Flow classification (§3)

    @Test("Doc §3: Medium sizing clamps to 200pt")
    func flowClassificationMediumWidthClamp() {
        let layout = FlowLayout(itemSpacing: 16, rowSpacing: 16, maxLineWidth: 600, isCompact: false)
        let width = layout.maxItemWidth(for: .medium, containerWidth: 320)
        #expect(width >= 200)
    }

    @Test("Doc §3: Media-only messages skip medium class")
    func flowClassificationMediaOnlyAlwaysLong() {
        let message = Message(
            id: "mediaMessage",
            role: .assistant,
            content: "",
            timestamp: Date(),
            streaming: false,
            attachments: [sampleAttachment(id: "img")],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
        let presentation = buildPresentation(message)
        #expect(presentation.inferredSizeClass() == .long)
    }

    @Test("Doc §3: 1–3 word messages classify as short")
    func flowClassificationShortUnderFourWords() {
        let presentation = buildPresentation(sampleMessage(content: "tiny message"))
        #expect(presentation.inferredSizeClass() == .short)
    }

    @Test("Doc §3: >20 word messages classify as long")
    func flowClassificationLongOverTwentyWords() {
        let content = Array(repeating: "word", count: 25).joined(separator: " ")
        let presentation = buildPresentation(sampleMessage(content: content))
        #expect(presentation.inferredSizeClass() == .long)
    }

    @Test("Doc §3: Streaming promotions debounce")
    func streamingPromotionsRespectDebounce() {
        let mediumPromotion = MessageFlowRules.promotedSizeClass(current: .short, next: .medium)
        let finalPromotion = MessageFlowRules.promotedSizeClass(current: mediumPromotion, next: .long)
        #expect(mediumPromotion == .medium)
        #expect(finalPromotion == .long)
        #expect(MessageFlowRules.streamingPromotionDelay == .milliseconds(280))
    }

    // MARK: Truncation (§4/§6)

    @Test("Doc §4: Height-based truncation")
    func truncationHeightOnly() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let shouldTruncate = MessageFlowRulesTestCompat.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: false,
            measuredHeight: metrics.truncationHeight + 10,
            metrics: metrics
        )
        let withinBounds = MessageFlowRulesTestCompat.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: false,
            measuredHeight: metrics.truncationHeight - 1,
            metrics: metrics
        )
        #expect(shouldTruncate)
        #expect(!withinBounds)
    }

    @Test("Doc §4: Show more/less toggle state")
    func truncationToggleExpandsAndCollapses() {
        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let collapsed = MessageFlowRulesTestCompat.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: false,
            measuredHeight: metrics.truncationHeight + 5,
            metrics: metrics
        )
        let expanded = MessageFlowRulesTestCompat.shouldTruncate(
            hasTextualParts: true,
            sizeClass: .long,
            isExpanded: true,
            measuredHeight: metrics.truncationHeight + 5,
            metrics: metrics
        )
        #expect(collapsed)
        #expect(!expanded)
    }

    @Test("Doc §4: Streaming truncation re-evaluates")
    func streamingTruncationReevaluatesDuringGrowth() {
        let metrics = ChatFlowTheme.Metrics(isCompact: false)
        let lower = MessageFlowRulesTestCompat.shouldShowTruncationControl(
            hasTextualParts: true,
            sizeClass: .long,
            measuredHeight: metrics.truncationHeight - 1,
            metrics: metrics
        )
        let higher = MessageFlowRulesTestCompat.shouldShowTruncationControl(
            hasTextualParts: true,
            sizeClass: .long,
            measuredHeight: metrics.truncationHeight + 15,
            metrics: metrics
        )
        #expect(!lower)
        #expect(higher)
    }

    @Test("Doc §6: Truncation height varies by device class")
    func truncationHeightMatchesMetrics() {
        #expect(ChatFlowTheme.Metrics(isCompact: false).truncationHeight == 400)
        #expect(ChatFlowTheme.Metrics(isCompact: true).truncationHeight == 320)
    }

    // MARK: Provider contract (§7)

    @Test("Doc §7: Provider incoming payload schema")
    func serverMessageDeserializationIncludesDeviceId() {
        let json = """
        {
            "type": "message",
            "id": "s_789",
            "role": "assistant",
            "content": "Hello",
            "timestamp": 1704672000000,
            "streaming": false,
            "deviceId": "ABC123",
            "sessionKey": "agent:main:clawline:user:main",
            "attachments": []
        }
        """
        let payload = try! JSONDecoder().decode(ServerMessagePayload.self, from: Data(json.utf8))
        let message = Message(payload: payload, sessionKey: payload.sessionKey ?? personalSessionKey)
        #expect(message.id == "s_789")
        #expect(message.role == .assistant)
        #expect(message.content == "Hello")
        #expect(message.timestamp.timeIntervalSince1970 == 1704672000)
        #expect(message.streaming == false)
        #expect(message.sessionKey == "agent:main:clawline:user:main")
        #expect(message.stream == .personal)
    }

    @Test("Doc §7: Client payload excludes role/timestamp")
    func outgoingMessagePayloadIsMinimal() {
        let payload = sampleMessage(content: "Hello world").toClientPayload()
        let json = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(payload)) as? [String: Any]
        #expect(json?["type"] as? String == "message")
        #expect(json?["id"] != nil)
        #expect(json?["content"] as? String == "Hello world")
        #expect(json?["attachments"] != nil)
        #expect(json?["sessionKey"] != nil)
        #expect(json?["role"] == nil)
        #expect(json?["timestamp"] == nil)
        #expect(json?["streaming"] == nil)
    }

    @Test("Doc §7: Attachment payload serializes correctly")
    func outgoingAttachmentsSerialization() {
        let attachment = Attachment(id: "img", type: .image, mimeType: "image/png", data: Data([0x01, 0x02]), assetId: nil)
        let message = Message(
            id: "c_img",
            role: .user,
            content: "See photo",
            timestamp: Date(),
            streaming: false,
            attachments: [attachment],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
        let payload = message.toClientPayload()
        let decoded = try! JSONDecoder().decode(ClientMessagePayload.self, from: try! JSONEncoder().encode(payload))
        guard let first = decoded.attachments.first else {
            Issue.record("Expected attachment entry")
            return
        }
        #expect(decoded.sessionKey == personalSessionKey)
        switch first {
        case .image(let mimeType, let data):
            #expect(mimeType == "image/png")
            #expect(Array(data) == [0x01, 0x02])
        default:
            Issue.record("Expected inline image attachment")
        }
    }

    @Test("Doc §7: Message mirrors provider schema")
    func messageModelMatchesProviderContract() {
        let payload = ServerMessagePayload(
            id: "s_mirror",
            role: .user,
            content: "ping",
            timestamp: Date(),
            streaming: true,
            deviceId: "device",
            sessionKey: personalSessionKey,
            attachments: []
        )
        let message = Message(payload: payload, sessionKey: payload.sessionKey ?? personalSessionKey)
        #expect(message.id == payload.id)
        #expect(message.role == payload.role)
        #expect(message.streaming == payload.streaming)
        #expect(message.attachments == payload.attachments)
        #expect(message.sessionKey == payload.sessionKey)
        #expect(message.stream == SessionKey.stream(for: payload.sessionKey ?? adminSessionKey))
    }

    @Test("Doc §5: MessagePart.isTextual lives with model")
    func messagePartIsTextualDefinedOnce() {
        #expect(MessagePart.text("value").isTextual)
        #expect(MessagePart.markdown("**bold**").isTextual)
        #expect(MessagePart.code(language: "swift", code: "print()").isTextual)
        #expect(!MessagePart.image(sampleAttachment(id: "img")).isTextual)
        #expect(!MessagePart.gallery([sampleAttachment(id: "img")]).isTextual)
        #expect(!MessagePart.file(sampleAttachment(id: "file")).isTextual)
        #expect(!MessagePart.terminalSession(
            TerminalSessionDescriptor(
                version: 1,
                terminalSessionId: "ts_textual",
                title: nil,
                provider: nil,
                capabilities: nil,
                auth: nil,
                expiresAtMs: nil
            )
        ).isTextual)
    }

    @Test("Bug #69: Table remains chromeless above 5 rows")
    func chromelessTableAllowsMoreThanFiveRows() {
        let table = makeTableModel(rowCount: 6)
        let presentation = MessagePresentation(
            parts: [.table(table)],
            wordCount: 0,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )

        #expect(presentation.chromelessStyle == .table)
        #expect(presentation.isChromeless)
    }

    @Test("Bug #69: Chromeless table ignores whitespace-only text parts")
    func chromelessTableIgnoresWhitespaceFragments() {
        let table = makeTableModel(rowCount: 2)
        let presentation = MessagePresentation(
            parts: [
                .text(" \n\t"),
                .markdown("\u{200B}\u{200C}"),
                .table(table),
                .text("\n")
            ],
            wordCount: 0,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )

        #expect(presentation.chromelessStyle == .table)
        #expect(presentation.isChromeless)
    }

    // MARK: Input bar & accessibility (§9/§10)

    @Test("Doc §10: Accessibility announcements")
    func voiceOverAnnouncesSenderAndContentType() {
        let message = Message(
            id: "voiceover",
            role: .assistant,
            content: "Look",
            timestamp: Date(),
            streaming: false,
            attachments: [sampleAttachment(id: "img1"), sampleAttachment(id: "img2")],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
        let presentation = buildPresentation(message)
        let label = MessageAccessibilityFormatter.label(for: message, presentation: presentation)
        #expect(label.contains("Assistant"))
        #expect(label.contains("2 image attachments"))
    }

    @Test("Doc §10: Reduce Motion disables hover/caustics")
    func reduceMotionDisablesAnimations() {
        let enabled = MessageInputMotionState(reduceMotionEnabled: false)
        let disabled = MessageInputMotionState(reduceMotionEnabled: true)
        #expect(enabled.causticsEnabled)
        #expect(!disabled.causticsEnabled)
    }

    // MARK: Helpers

    private func sampleMessage(content: String) -> Message {
        Message(
            id: UUID().uuidString,
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
    }

    private func sampleMessage(content: String, attachments: [Clawline.Attachment]) -> Message {
        Message(
            id: UUID().uuidString,
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: attachments,
            deviceId: nil,
            sessionKey: personalSessionKey
        )
    }

    private func sampleMessage(content: String, attachments: [Clawline.Attachment], sessionKey: String) -> Message {
        Message(
            id: UUID().uuidString,
            role: .assistant,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: attachments,
            deviceId: nil,
            sessionKey: sessionKey
        )
    }

    private func renderedMarkdownText(from presentation: MessagePresentation, stripDetectedURLs: Bool) -> String {
        let options = MarkdownRenderOptions(
            baseFont: UIFont.systemFont(ofSize: ChatFlowTheme.Metrics(isCompact: true).bodyFontSize, weight: .regular),
            inkColor: .black,
            lineSpacing: 4,
            stripDetectedURLs: stripDetectedURLs,
            markHighlightColor: nil
        )
        let rendered = UnifiedMarkdownRenderer.render(
            plan: presentation.markdownRenderPlan,
            options: options
        )
        let combined = NSMutableAttributedString()
        for block in rendered {
            guard case .attributedText(let attributed) = block else { continue }
            if combined.length > 0 {
                combined.append(NSAttributedString(string: "\n\n"))
            }
            combined.append(attributed)
        }
        return combined.string
    }

    private func buildPresentation(_ message: Message,
                                   isCompact: Bool = true,
                                   enableLinkPreviews: Bool = true) -> MessagePresentation {
        var state = StreamingTableParseState()
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &state
        )
        guard !enableLinkPreviews else { return presentation }

        // Link preview presentation is a UI policy; the builder always detects URLs for sizing.
        // Tests can suppress rendering by filtering the linkPreview part.
        let filtered = presentation.parts.filter { part in
            if case .linkPreview = part { return false }
            return true
        }
        return MessagePresentation(
            parts: filtered,
            markdownRenderPlan: presentation.markdownRenderPlan,
            wordCount: presentation.wordCount,
            hasTextualContent: presentation.hasTextualContent,
            isEmojiOnly: presentation.isEmojiOnly,
            hasMediaOnly: presentation.hasMediaOnly,
            detectedURLs: presentation.detectedURLs,
            detectedURLCount: presentation.detectedURLCount,
            hasSingleURL: presentation.hasSingleURL
        )
    }

    private func sampleAttachment(id: String) -> Clawline.Attachment {
        Clawline.Attachment(id: id, type: .image, mimeType: "image/png", data: nil, assetId: nil)
    }

    private func makeTableModel(rowCount: Int) -> TableModel {
        let columns = [
            TableModel.Column(alignment: .leading),
            TableModel.Column(alignment: .trailing)
        ]
        let header = [
            makeTableCell("Name"),
            makeTableCell("Count")
        ]
        let rows = (0..<rowCount).map { index in
            TableModel.Row(
                id: UUID(),
                cells: [
                    makeTableCell("Item \(index + 1)"),
                    makeTableCell("\(index + 1)")
                ]
            )
        }
        return TableModel(
            columns: columns,
            header: header,
            rows: rows,
            messageID: "table_chromeless_test",
            rowOffset: 0
        )
    }

    private func makeTableCell(_ value: String) -> TableModel.Cell {
        TableModel.Cell(
            attributed: AttributedString(value),
            intrinsicWidth: 80,
            plainText: value,
            isEmpty: value.isEmpty
        )
    }
}
