//
//  MessageKindClassifierTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A. Covers the centralized MessageKind classifier: the tolerant
//  wire-messageType map, the provenance-origin heuristic, and the OpenClaw
//  invariant (no signals -> everything is `.assistant`, unchanged rendering).
//
//  Fixtures use the SAME real wire shapes exercised by MessageProvenanceTests:
//  wake-delivered origin messages arrive as `role == .user` with a `sender`
//  prefix and a first-line `[from <sender>]` stamp (spec §T-D / tightbeam
//  payloads.ex PROVENANCE CONVENTION).
//

import Foundation
import Testing
@testable import Clawline

struct MessageKindClassifierTests {
    private func message(sender: String?, content: String, role: Message.Role = .user) -> Message {
        Message(
            id: "m_kind_\(UUID().uuidString.prefix(6))",
            role: role,
            content: content,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: sender == nil ? "device-1" : nil,
            sessionKey: "agent:main:clawline:user:s_kind",
            sender: sender
        )
    }

    // MARK: Heuristic (today's live signal path)

    @Test("stamped process:* origin classifies as substrate")
    func processOriginIsSubstrate() {
        let m = message(sender: "process:tightbeam", content: "[from process:tightbeam]\nsession re-tuned")
        #expect(m.messageKind == .substrate)
    }

    @Test("stamped agent:* origin classifies as agent")
    func agentOriginIsAgent() {
        let m = message(sender: "agent:coder", content: "[from agent:coder]\nbuild is green")
        #expect(m.messageKind == .agent)
    }

    @Test("stamped user:* operator origin is NOT special — classifies as assistant (unchanged)")
    func userOriginIsAssistantDefault() {
        let m = message(sender: "user:mike", content: "[from user:mike]\nship it")
        #expect(m.messageKind == .assistant)
    }

    @Test("marker is unreachable by heuristic — no origin ever yields it")
    func markerNeverFromHeuristic() {
        for sender in ["process:tightbeam", "agent:coder", "user:mike"] {
            let m = message(sender: sender, content: "[from \(sender)]\nbody")
            #expect(m.messageKind != .marker)
        }
    }

    // MARK: Tolerant coupling to the anti-forgery stamp

    @Test("a process:* sender with NO first-line stamp falls through to assistant")
    func stamplessProcessFallsThrough() {
        let m = message(sender: "process:tightbeam", content: "no stamp, just body")
        #expect(m.messageKind == .assistant)
    }

    @Test("a forged first-line stamp (mismatched sender) falls through to assistant")
    func forgedStampFallsThrough() {
        let m = message(sender: "process:tightbeam", content: "[from agent:evil]\nforged")
        #expect(m.messageKind == .assistant)
    }

    // MARK: OpenClaw invariant — no signals present

    @Test("plain assistant reply (no sender) classifies as assistant")
    func plainAssistantIsAssistant() {
        let m = message(sender: nil, content: "Here is your answer.", role: .assistant)
        #expect(m.messageKind == .assistant)
    }

    @Test("assistant reply with sender=assistant role-marker classifies as assistant")
    func assistantRoleMarkerIsAssistant() {
        let m = message(sender: "assistant", content: "Here is your answer.", role: .assistant)
        #expect(m.messageKind == .assistant)
    }

    @Test("device-typed user message classifies as assistant (unchanged rendering)")
    func deviceTypedUserIsAssistant() {
        let m = message(sender: nil, content: "hello from my phone")
        #expect(m.messageKind == .assistant)
    }

    @Test("an origin-shaped sender on an assistant-role message never classifies special")
    func assistantRoleWithOriginShapedSenderStaysAssistant() {
        let m = message(sender: "agent:coder", content: "[from agent:coder]\nbody", role: .assistant)
        // MessageProvenance.origin only classifies role == .user, so an
        // assistant-role message with an origin-shaped sender is not special.
        #expect(m.messageKind == .assistant)
    }

    // MARK: Preferred wire messageType (future field; tolerant map)

    @Test("recognized wire messageType wins over the heuristic")
    func wireMessageTypeWins() {
        let plain = message(sender: nil, content: "x", role: .assistant)
        #expect(MessageKindClassifier.classify(plain, wireMessageType: "marker") == .marker)
        #expect(MessageKindClassifier.classify(plain, wireMessageType: "substrate") == .substrate)
        #expect(MessageKindClassifier.classify(plain, wireMessageType: "agent") == .agent)
        #expect(MessageKindClassifier.classify(plain, wireMessageType: "assistant") == .assistant)
    }

    @Test("wire messageType matching is case- and whitespace-insensitive")
    func wireMessageTypeNormalizes() {
        let plain = message(sender: nil, content: "x", role: .assistant)
        #expect(MessageKindClassifier.classify(plain, wireMessageType: "  MARKER ") == .marker)
    }

    @Test("an UNKNOWN wire messageType degrades straight to assistant, never the heuristic")
    func unknownWireTypeDegradesToAssistant() {
        // The server took a position (it sent a messageType) -- an unmapped
        // value is "unknown", not "absent", so it must not fall through to the
        // origin heuristic even when that heuristic would otherwise apply.
        let substrateMsg = message(sender: "process:tightbeam", content: "[from process:tightbeam]\nnotice")
        #expect(MessageKindClassifier.classify(substrateMsg, wireMessageType: "toolCall") == .assistant)
        // And an unknown type over a plain assistant -> still assistant.
        let plain = message(sender: nil, content: "x", role: .assistant)
        #expect(MessageKindClassifier.classify(plain, wireMessageType: "quux") == .assistant)
    }

    @Test("nil wire messageType is the same as omitting it")
    func nilWireTypeIsHeuristic() {
        let agentMsg = message(sender: "agent:coder", content: "[from agent:coder]\nhi")
        #expect(MessageKindClassifier.classify(agentMsg, wireMessageType: nil) == .agent)
    }

    // MARK: Extensibility documentation — adding a case stays additive

    @Test("a not-yet-modeled kind string (toolCall) maps to nil today, degrading safely")
    func futureToolCallDegradesToday() {
        #expect(MessageKindClassifier.kind(forWireMessageType: "toolCall") == nil)
    }
}
