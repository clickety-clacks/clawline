//
//  SubstrateRowCellTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A, step 2. Covers SubstrateRowCell / SubstrateRunCollapseCell
//  configuration against real wire-shaped fixtures (same convention as
//  MessageKindClassifierTests / MessageProvenanceTests: role=.user, a
//  `sender` prefix, a first-line `[from <sender>]` stamp). Run-collapse
//  coverage exercises the production projection seam with durable provenance
//  so other process deliveries cannot be folded into Tightbeam aggregates.
//  UI-level
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
    private func substrateMessage(
        id: String = "m_substrate_\(UUID().uuidString.prefix(6))",
        content: String,
        sender: String = "process:tightbeam"
    ) -> Message {
        Message(
            id: id,
            role: .user,
            content: "[from \(sender)]\n\(content)",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:mike:main s_test",
            sender: sender
        )
    }

    @Test("a real substrate message classifies as .substrate and configures a chromeless row")
    @MainActor
    func substrateRowConfiguresFromRealMessage() {
        let message = substrateMessage(content: "check-in: the design assignment has an open obligation and no filing this turn")
        #expect(message.messageKind == .substrate)

        let cell = SubstrateRowCell()
        let displayMessage = message.strippingProvenanceStampForDisplay()
        let header = SubstrateRowHeader.liveVoice(for: message.provenanceOrigin)
        #expect(header == .tightbeam)
        #expect(header.leadLabel == "Tightbeam")
        #expect(header.avatarSystemName == "gearshape.fill")
        cell.configure(
            header: header,
            detail: displayMessage.content,
            isDark: false,
            isIndentedUnderRun: false,
            onTap: {}
        )
        #expect(displayMessage.content == "check-in: the design assignment has an open obligation and no filing this turn")
        #expect(cell.accessibilityLabel == "Notice from Tightbeam substrate. check-in: the design assignment has an open obligation and no filing this turn. Open full content.")
    }

    @Test("durable ChatGPT provenance renders a process delivery header")
    @MainActor
    func chatGPTProvenanceConfiguresSecondarySource() {
        let message = substrateMessage(
            content: "release polish is ready for review",
            sender: "process:chatgpt"
        )
        #expect(message.messageKind == .substrate)

        let header = SubstrateRowHeader.liveVoice(for: message.provenanceOrigin)
        #expect(header == .process(name: "ChatGPT"))
        #expect(header.leadLabel == "Process • ChatGPT")
        #expect(header.avatarSystemName == "dot.radiowaves.left.and.right")

        let cell = SubstrateRowCell()
        cell.configure(
            header: header,
            detail: message.strippingProvenanceStampForDisplay().content,
            isDark: false,
            isIndentedUnderRun: false,
            onTap: {}
        )
        #expect(
            cell.accessibilityLabel
                == "Process delivery from ChatGPT. release polish is ready for review. Open full content."
        )
    }

    @Test("known process origins use their meaningful display identity")
    @MainActor
    func knownProcessOriginsUseDisplayIdentity() {
        let expected = [
            "anthropic": "Anthropic",
            "ci": "CI",
            "claude": "Claude",
            "codex": "Codex",
            "gemini": "Gemini",
            "github": "GitHub",
            "gitlab": "GitLab",
            "openai": "OpenAI"
        ]
        for (origin, displayName) in expected {
            #expect(
                SubstrateRowHeader.liveVoice(for: .process(name: origin))
                    == .process(name: displayName)
            )
        }
    }

    @Test("source fallback preserves unknown provenance without empty or redundant slots")
    @MainActor
    func processSourceFallbacksStayMeaningful() {
        #expect(
            SubstrateRowHeader.liveVoice(for: .process(name: "release-bot"))
                == .process(name: "release-bot")
        )
        #expect(
            SubstrateRowHeader.liveVoice(for: .process(name: "tightbeam"))
                == .tightbeam
        )
        #expect(
            SubstrateRowHeader.liveVoice(for: .process(name: "TIGHTBEAM"))
                == .tightbeam
        )
        #expect(
            SubstrateRowHeader.liveVoice(for: .process(name: "  "))
                == .tightbeam
        )
        let blankProcess = substrateMessage(
            id: "blank-process",
            content: "missing process identity",
            sender: "process:"
        )
        #expect(!MessageFlowCollectionViewController.isTightbeamRunEligible(blankProcess))
        #expect(SubstrateRowHeader.liveVoice(for: nil) == .tightbeam)
        #expect(SubstrateRowHeader.liveVoice(for: .agent(handle: "coder")) == .tightbeam)
    }

    @Test("header identity ignores message body text")
    func headerIdentityUsesOnlyDurableProvenance() {
        let message = substrateMessage(
            content: "body mentions process:chatgpt and Process • ChatGPT",
            sender: "process:tightbeam"
        )
        #expect(SubstrateRowHeader.liveVoice(for: message.provenanceOrigin) == .tightbeam)
    }

    @Test("consecutive non-Tightbeam process deliveries never collapse as Tightbeam")
    @MainActor
    func consecutiveProcessDeliveriesStayIndividual() {
        let messages = [
            substrateMessage(id: "chatgpt-1", content: "first delivery", sender: "process:chatgpt"),
            substrateMessage(id: "chatgpt-2", content: "second delivery", sender: "process:chatgpt")
        ]
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        let projection = MessageFlowCollectionViewController.collapsedTightbeamRunProjection(
            from: messages.map(\.id),
            expandedRunItemIds: [],
            isTightbeamNotice: { id in
                guard let message = messagesByID[id] else { return false }
                return MessageFlowCollectionViewController.isTightbeamRunEligible(message)
            }
        )

        #expect(messages.allSatisfy { $0.messageKind == .substrate })
        #expect(projection.itemIds == ["chatgpt-1", "chatgpt-2"])
        #expect(projection.memberIdsByItemId.isEmpty)
    }

    @Test("process delivery provenance breaks otherwise collapsible Tightbeam runs")
    @MainActor
    func mixedProcessOriginsKeepTheirPresentationBoundary() {
        let messages = [
            substrateMessage(id: "tightbeam-1", content: "first notice"),
            substrateMessage(id: "tightbeam-2", content: "second notice"),
            substrateMessage(id: "chatgpt", content: "process delivery", sender: "process:chatgpt"),
            substrateMessage(id: "tightbeam-3", content: "third notice"),
            substrateMessage(id: "tightbeam-4", content: "fourth notice")
        ]
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        let projection = MessageFlowCollectionViewController.collapsedTightbeamRunProjection(
            from: messages.map(\.id),
            expandedRunItemIds: [],
            isTightbeamNotice: { id in
                guard let message = messagesByID[id] else { return false }
                return MessageFlowCollectionViewController.isTightbeamRunEligible(message)
            }
        )

        #expect(projection.itemIds == [
            "__substrate_run__|tightbeam-1",
            "chatgpt",
            "__substrate_run__|tightbeam-3"
        ])
        #expect(projection.memberIdsByItemId == [
            "__substrate_run__|tightbeam-1": ["tightbeam-1", "tightbeam-2"],
            "__substrate_run__|tightbeam-3": ["tightbeam-3", "tightbeam-4"]
        ])
        #expect(
            SubstrateRowHeader.liveVoice(for: messagesByID["chatgpt"]?.provenanceOrigin)
                == .process(name: "ChatGPT")
        )
    }

    @Test("record header preserves its distinct event identity")
    func recordHeaderKeepsRecordTreatment() {
        let header = SubstrateRowHeader.record(eventName: "Progress filed")
        #expect(header.leadLabel == "Progress filed")
        #expect(header.avatarSystemName == "checkmark")
        #expect(header.accessibilityPrefix == "Event: Progress filed")
    }

    @Test("SubstrateRowCell tap invokes the supplied click-to-detail closure")
    @MainActor
    func substrateRowTapInvokesClosure() {
        let message = substrateMessage(content: "escalation: helper session missed two check-ins")
        let cell = SubstrateRowCell()
        var tapped = false
        cell.configure(
            header: SubstrateRowHeader.liveVoice(for: message.provenanceOrigin),
            detail: message.strippingProvenanceStampForDisplay().content,
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
