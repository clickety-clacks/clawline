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
}
