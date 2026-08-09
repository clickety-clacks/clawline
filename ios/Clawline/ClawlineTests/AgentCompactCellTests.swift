//
//  AgentCompactCellTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A, step 4. Covers AgentCompactCell configuration, the
//  handle formatting, three-line preview geometry, and tap-to-detail wiring
//  against a real wire-shaped `.agent` message (same convention as
//  SubstrateRowCellTests / MessageProvenanceTests: role=.user, a `sender`
//  prefix, a first-line `[from <sender>]` stamp).
//

import Foundation
import UIKit
import Testing
@testable import Clawline

struct AgentCompactCellTests {
    private let regularWidth: CGFloat = 700
    private let compactWidth: CGFloat = 320

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

    @MainActor
    private func measuredHeight(
        _ previewText: String,
        width: CGFloat,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> CGFloat {
        AgentCompactCell.measuredHeight(
            senderLine: "coder \u{00B7} gibson",
            previewText: previewText,
            rowWidth: width,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        )
    }

    @Test("one, two, and three lines grow; a fourth line truncates at the same height")
    @MainActor
    func previewCapsAfterThreeVisibleLines() {
        let one = measuredHeight("one", width: regularWidth)
        let two = measuredHeight("one\ntwo", width: regularWidth)
        let three = measuredHeight("one\ntwo\nthree", width: regularWidth)
        let four = measuredHeight("one\ntwo\nthree\nfour", width: regularWidth)

        #expect(two > one)
        #expect(three > two)
        #expect(abs(four - three) < 0.5)
    }

    @Test("one long line wraps within compact and regular bounded widths")
    @MainActor
    func longLineWrapsAtRepresentativeWidths() {
        let shortCompact = measuredHeight("short", width: compactWidth)
        let longText = String(repeating: "wrapped preview words ", count: 20)
        let longCompact = measuredHeight(longText, width: compactWidth)
        let longRegular = measuredHeight(longText, width: regularWidth)
        let threeCompact = measuredHeight("one\ntwo\nthree", width: compactWidth)

        #expect(longCompact > shortCompact)
        #expect(longCompact <= threeCompact)
        #expect(longRegular <= longCompact)
    }

    @Test("Dynamic Type increases the bounded preview height")
    @MainActor
    func dynamicTypeIncreasesPreviewHeight() {
        let text = "one\ntwo\nthree"
        let standard = measuredHeight(text, width: regularWidth, contentSizeCategory: .large)
        let accessibility = measuredHeight(
            text,
            width: regularWidth,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        )

        #expect(accessibility > standard)
    }

    @Test("compact accessibility keeps three body lines after attribution")
    @MainActor
    func compactAccessibilityKeepsBodyLineBudget() {
        let category = UIContentSizeCategory.accessibilityExtraLarge
        let one = measuredHeight("one", width: compactWidth, contentSizeCategory: category)
        let two = measuredHeight("one\ntwo", width: compactWidth, contentSizeCategory: category)
        let three = measuredHeight("one\ntwo\nthree", width: compactWidth, contentSizeCategory: category)
        let four = measuredHeight("one\ntwo\nthree\nfour", width: compactWidth, contentSizeCategory: category)

        #expect(two > one)
        #expect(three > two)
        #expect(abs(four - three) < 0.5)
    }

    @Test("regular accessibility allows a third body line before truncation")
    @MainActor
    func regularAccessibilityKeepsBodyLineBudget() {
        let category = UIContentSizeCategory.accessibilityExtraLarge
        let one = measuredHeight("one", width: regularWidth, contentSizeCategory: category)
        let two = measuredHeight("one\ntwo", width: regularWidth, contentSizeCategory: category)
        let three = measuredHeight("one\ntwo\nthree", width: regularWidth, contentSizeCategory: category)
        let four = measuredHeight("one\ntwo\nthree\nfour", width: regularWidth, contentSizeCategory: category)

        #expect(two > one)
        #expect(three > two)
        #expect(abs(four - three) < 0.5)
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
            previewText: displayMessage.content,
            isDark: false,
            onTap: {}
        )
        #expect(cell.accessibilityLabel == "Agent report from coder \u{00B7} gibson. Open full content.")
        #expect(cell.contentTextForTesting?.contains("canonical design system") == true)
        #expect(cell.previewLineLimitForTesting == 3)
        #expect(cell.previewLineBreakModeForTesting == .byTruncatingTail)
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

    @Test("reuse clears preview content and the old tap closure")
    @MainActor
    func reuseClearsContentAndTap() {
        let cell = AgentCompactCell()
        var tapCount = 0
        cell.configure(senderLine: "coder \u{00B7} gibson", previewText: "preview", isDark: false) {
            tapCount += 1
        }
        cell.handleTap()
        cell.prepareForReuse()
        cell.handleTap()

        #expect(tapCount == 1)
        #expect(cell.contentTextForTesting == nil)
        #expect(cell.accessibilityLabel == nil)
    }
}
