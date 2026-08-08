//
//  AgentCompactCellTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A, step 4. Covers AgentCompactCell configuration, the
//  handle-formatting/first-line helpers, and the tap-to-detail wiring
//  against a real wire-shaped `.agent` message (same convention as
//  SubstrateRowCellTests / MessageProvenanceTests: role=.user, a `sender`
//  prefix, a first-line `[from <sender>]` stamp).
//

import Foundation
import UIKit
import Testing
@testable import Clawline

struct AgentCompactCellTests {
    private func agentMessage(handle: String, content: String) -> Message {
        Message(
            id: "m_agent_\(UUID().uuidString.prefix(6))",
            role: .user,
            content: "[from agent:\(handle)]\n\(content)",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:mike:main s_test",
            sender: "agent:\(handle)"
        )
    }

    @Test("a real agent DM classifies as .agent")
    func agentMessageClassifiesAsAgent() {
        let message = agentMessage(handle: "coder:gibson", content: "Design pass complete.")
        #expect(message.messageKind == .agent)
    }

    @Test("displaySenderLine formats a colon-delimited handle with the middle-dot separator")
    func displaySenderLineFormatsHandle() {
        #expect(AgentCompactCell.displaySenderLine(forHandle: "coder:gibson") == "coder \u{00B7} gibson")
        #expect(AgentCompactCell.displaySenderLine(forHandle: "atlas") == "atlas")
    }

    @Test("firstLine extracts only the first line of multi-line content")
    func firstLineExtractsSingleLine() {
        #expect(AgentCompactCell.firstLine(of: "Report: revision drafted.\nMore detail below.") == "Report: revision drafted.")
        #expect(AgentCompactCell.firstLine(of: "single line") == "single line")
    }

    @Test("configures sender/preview text and accessibility from a real message")
    @MainActor
    func configuresFromRealMessage() {
        let message = agentMessage(handle: "coder:gibson", content: "Report: canonical design system read from shared-workspace.")
        let displayMessage = message.strippingProvenanceStampForDisplay()
        guard case let .agent(handle)? = message.provenanceOrigin else {
            Issue.record("expected .agent provenance origin")
            return
        }
        let cell = AgentCompactCell()
        cell.configure(
            senderLine: AgentCompactCell.displaySenderLine(forHandle: handle),
            previewText: AgentCompactCell.firstLine(of: displayMessage.content),
            isDark: false,
            onTap: {}
        )
        #expect(cell.accessibilityLabel == "Agent report from coder \u{00B7} gibson. Open full content.")
    }

    @Test("tap invokes the supplied click-to-detail closure")
    @MainActor
    func tapInvokesClosure() {
        let cell = AgentCompactCell()
        var tapped = false
        cell.configure(senderLine: "coder \u{00B7} gibson", previewText: "preview", isDark: false) {
            tapped = true
        }
        cell.handleTap()
        #expect(tapped)
    }

    @Test("touch-down shows the press wash, touch-up hides it again")
    @MainActor
    func touchDownShowsPressWash() {
        let cell = AgentCompactCell()
        cell.configure(senderLine: "coder \u{00B7} gibson", previewText: "preview", isDark: false) {}
        #expect(cell.isWashVisibleForTesting == false)
        cell.touchesBegan([], with: nil)
        #expect(cell.isWashVisibleForTesting == true)
        cell.touchesEnded([], with: nil)
        #expect(cell.isWashVisibleForTesting == false)
    }

    @Test("a cancelled touch (the tap recognizer taking over) also hides the press wash")
    @MainActor
    func cancelledTouchHidesPressWash() {
        let cell = AgentCompactCell()
        cell.configure(senderLine: "coder \u{00B7} gibson", previewText: "preview", isDark: false) {}
        cell.touchesBegan([], with: nil)
        #expect(cell.isWashVisibleForTesting == true)
        cell.touchesCancelled([], with: nil)
        #expect(cell.isWashVisibleForTesting == false)
    }
}
