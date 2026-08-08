//
//  MessageDetailContentViewTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A/B, step B1. Covers MessageDetailContentView.renderedBlocks --
//  the detail viewer routes through UnifiedMarkdownRenderer instead of a raw
//  Text(message.content), so these exercise real markdown syntax (bold, a
//  link) end to end through that seam, plus the provenance-stamp stripping.
//

import Foundation
import UIKit
import SwiftUI
import Testing
@testable import Clawline

struct MessageDetailContentViewTests {
    private func detailMessage(content: String, sender: String? = nil) -> Message {
        let stamped = sender.map { "[from \($0)]\n\(content)" } ?? content
        return Message(
            id: "m_detail_\(UUID().uuidString.prefix(6))",
            // A [from <sender>] stamp is only real on role=.user wire messages
            // (same convention as AgentCompactCellTests.agentMessage) -- an
            // unstamped message stays .assistant, this app's ordinary reply.
            role: sender == nil ? .assistant : .user,
            content: stamped,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:mike:main s_test",
            sender: sender
        )
    }

    private func blocks(_ message: Message) -> [RenderedMarkdownBlock] {
        MessageDetailContentView.renderedBlocks(
            for: message,
            baseFont: UIFont.clawline(.bodyText),
            colorScheme: .light,
            metrics: ChatFlowTheme.Metrics(isCompact: false)
        )
    }

    private func firstAttributedText(_ blocks: [RenderedMarkdownBlock]) -> NSAttributedString? {
        blocks.compactMap { block -> NSAttributedString? in
            guard case .attributedText(let attributed) = block else { return nil }
            return attributed
        }.first
    }

    private func detailPresentation(text: String) -> MessagePresentation {
        MessagePresentation(
            parts: [.text(text)],
            copyableReadableText: text,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            hasTextualContent: true,
            isEmojiOnly: false,
            hasMediaOnly: false,
            detectedURLs: [],
            detectedURLCount: 0,
            hasSingleURL: false
        )
    }

    @MainActor
    private func detailPayload(
        message: Message,
        presentationText: String,
        fontScaleChangeSequence: Int = 3
    ) -> MessageDetailPayload {
        MessageDetailPayload(
            message: message,
            presentation: detailPresentation(text: presentationText),
            fontScaleChangeSequence: fontScaleChangeSequence,
            terminalConnectionPool: TerminalSessionConnectionPool { _ in
                fatalError("Text-only detail must not create a terminal service")
            }
        )
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var result = (view as? UITextView).map { [$0] } ?? []
        for subview in view.subviews {
            result.append(contentsOf: textViews(in: subview))
        }
        return result
    }

    @Test("bold markdown syntax is parsed away, not shown as literal asterisks")
    func boldMarkdownStripsAsterisks() {
        let message = detailMessage(content: "This is **bold** text.")
        guard let attributed = firstAttributedText(blocks(message)) else {
            Issue.record("expected an attributed text block")
            return
        }
        // The meaningful contrast against the raw Text(message.content) this
        // replaced: markdown syntax gets interpreted, not displayed literally.
        #expect(!attributed.string.contains("**"))
        #expect(attributed.string.contains("This is bold text."))
    }

    @Test("a URL in message content becomes a tappable link attribute")
    func urlBecomesLinkAttribute() {
        let message = detailMessage(content: "See https://example.com for details.")
        guard let attributed = firstAttributedText(blocks(message)) else {
            Issue.record("expected an attributed text block")
            return
        }

        var foundLink = false
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { foundLink = true }
        }
        #expect(foundLink)
    }

    @Test("a provenance-stamped message strips the [from ...] line before rendering")
    func stampedMessageStripsFirstLineBeforeRendering() {
        let message = detailMessage(content: "Report: revision drafted.", sender: "agent:coder:gibson")
        guard let attributed = firstAttributedText(blocks(message)) else {
            Issue.record("expected an attributed text block")
            return
        }
        #expect(!attributed.string.contains("[from agent:coder:gibson]"))
        #expect(attributed.string.contains("Report: revision drafted."))
    }

    @Test("plain text with no markdown syntax still renders as a single attributed block")
    func plainTextRendersAsAttributedBlock() {
        let message = detailMessage(content: "Nothing fancy here, just prose.")
        let renderedBlocks = blocks(message)
        #expect(renderedBlocks.count == 1)
        #expect(firstAttributedText(renderedBlocks)?.string.contains("Nothing fancy here") == true)
    }

    @Test("rich detail action delivers presentation payload without using message fallback")
    @MainActor
    func richDetailActionDeliversPayload() {
        let message = detailMessage(content: "Raw message body")
        let payload = detailPayload(message: message, presentationText: "Presentation body")
        var fallbackMessageID: String?
        var receivedPayload: MessageDetailPayload?
        let action = MessageDetailAction(
            handler: { fallbackMessageID = $0.id },
            payloadHandler: { receivedPayload = $0 }
        )

        action(for: payload)

        #expect(fallbackMessageID == nil)
        #expect(receivedPayload?.message.id == message.id)
        #expect(receivedPayload?.presentation.copyableReadableText == "Presentation body")
        #expect(receivedPayload?.fontScaleChangeSequence == 3)
    }

    @Test("payload action falls back to message handler when rich presentation is unavailable")
    @MainActor
    func payloadActionPreservesMessageFallback() {
        let message = detailMessage(content: "Vision fallback body")
        let payload = detailPayload(message: message, presentationText: "Presentation body")
        var receivedMessageID: String?
        let action = MessageDetailAction { receivedMessageID = $0.id }

        action(for: payload)

        #expect(receivedMessageID == message.id)
    }

    @Test("large detail viewer renders expanded-sheet semantics and refreshed live content")
    @MainActor
    func largeViewerRendersPresentationFallbackAndRefreshesLiveContent() async {
        let presentationText = "Presentation-only **Markdown** survives the large viewer."
        let message = detailMessage(content: "")
        let payload = detailPayload(message: message, presentationText: presentationText)
        let host = UIHostingController(
            rootView: MessageDetailViewer(payload: payload, onDismiss: {})
                .environment(\.horizontalSizeClass, .regular)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()

        let renderedText = textViews(in: host.view).map(\.text).joined(separator: "\n")
        #expect(renderedText.contains("Presentation-only Markdown survives the large viewer."))
        #expect(!renderedText.contains("**Markdown**"))

        let streamedMessage = Message(
            id: message.id,
            role: message.role,
            content: "Streamed raw content",
            timestamp: message.timestamp,
            streaming: true,
            attachments: message.attachments,
            deviceId: message.deviceId,
            sessionKey: message.sessionKey,
            sender: message.sender
        )
        let refreshedPayload = detailPayload(
            message: streamedMessage,
            presentationText: "Live *streaming* update reached the viewer.",
            fontScaleChangeSequence: 4
        )
        host.rootView = MessageDetailViewer(payload: refreshedPayload, onDismiss: {})
            .environment(\.horizontalSizeClass, .regular)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(10))
            host.view.layoutIfNeeded()
            if textViews(in: host.view).contains(where: { textView in
                textView.text.contains("Live streaming update reached the viewer.")
            }) {
                break
            }
        }

        let refreshedText = textViews(in: host.view).map(\.text).joined(separator: "\n")
        #expect(refreshedText.contains("Live streaming update reached the viewer."))
        #expect(!refreshedText.contains("Presentation-only Markdown survives the large viewer."))
        #expect(refreshedPayload.message.streaming)
        #expect(refreshedPayload.fontScaleChangeSequence == 4)
        window.isHidden = true
    }
}
