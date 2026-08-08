//
//  SubstrateRowCellTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A, step 2. Covers SubstrateRowCell / SubstrateRunCollapseCell
//  configuration against real wire-shaped fixtures (same convention as
//  MessageKindClassifierTests / MessageProvenanceTests: role=.user, a
//  `sender` prefix, a first-line `[from <sender>]` stamp). The run-collapse
//  GROUPING algorithm (snapshotItemsWithSubstrateRunCollapse) lives as a
//  private method on MessageFlowCollectionViewController and is not testable
//  at this access level without widening it beyond what step 2 needs;
//  covered instead by code review + the real build below. UI-level
//  verification of the full collection view against a LIVE connected
//  session was not reachable in this environment (no gateway credentials
//  configured on eezo -- the same "Loading chats..." wall Goal B's step-1
//  smoke hit; flagged, not silently worked around).
//

import Foundation
import UIKit
import Testing
@testable import Clawline

struct SubstrateRowCellTests {
    private func substrateMessage(content: String) -> Message {
        Message(
            id: "m_substrate_\(UUID().uuidString.prefix(6))",
            role: .user,
            content: "[from process:tightbeam]\n\(content)",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:mike:main s_test",
            sender: "process:tightbeam"
        )
    }

    @Test("a real substrate message classifies as .substrate and configures a chromeless row")
    @MainActor
    func substrateRowConfiguresFromRealMessage() {
        let message = substrateMessage(content: "check-in: the design assignment has an open obligation and no filing this turn")
        #expect(message.messageKind == .substrate)

        let cell = SubstrateRowCell()
        let displayMessage = message.strippingProvenanceStampForDisplay()
        cell.configure(
            leadLabel: "tightbeam",
            detail: displayMessage.content,
            style: .liveVoice,
            isDark: false,
            isIndentedUnderRun: false,
            onTap: {}
        )
        #expect(displayMessage.content == "check-in: the design assignment has an open obligation and no filing this turn")
        #expect(cell.accessibilityLabel == "Notice from tightbeam substrate. check-in: the design assignment has an open obligation and no filing this turn. Open full content.")
    }

    @Test("SubstrateRowCell tap invokes the supplied click-to-detail closure")
    @MainActor
    func substrateRowTapInvokesClosure() {
        let message = substrateMessage(content: "escalation: helper session missed two check-ins")
        let cell = SubstrateRowCell()
        var tapped = false
        cell.configure(
            leadLabel: "tightbeam",
            detail: message.strippingProvenanceStampForDisplay().content,
            style: .liveVoice,
            isDark: false,
            isIndentedUnderRun: false,
            onTap: { tapped = true }
        )
        cell.handleTap()
        #expect(tapped)
    }

    @Test("SubstrateRunCollapseCell renders the tightbeam N notices label and exposes expanded state via accessibility")
    @MainActor
    func runCollapseCellConfiguresCountAndAccessibility() {
        let cell = SubstrateRunCollapseCell()
        cell.configure(noticeCount: 3, isExpanded: false, isDark: false) {}
        #expect(cell.accessibilityLabel == "tightbeam, 3 notices")
        #expect(cell.accessibilityValue == "Collapsed")

        cell.configure(noticeCount: 1, isExpanded: true, isDark: true) {}
        #expect(cell.accessibilityLabel == "tightbeam, 1 notice")
        #expect(cell.accessibilityValue == "Expanded")
    }

    @Test("SubstrateRunCollapseCell tap invokes the supplied toggle closure")
    @MainActor
    func runCollapseCellTapInvokesClosure() {
        let cell = SubstrateRunCollapseCell()
        var tapped = false
        cell.configure(noticeCount: 2, isExpanded: false, isDark: false) {
            tapped = true
        }
        cell.handleTap()
        #expect(tapped)
    }
}
