//
//  T1753ProvenanceFingerprintTests.swift
//  ClawlineTests
//
//  F4 (sixth-review): the diffable fingerprint must include the provenance
//  fields (sender, role). A replay or authoritative server update can replace a
//  cached same-id, same-content message with corrected provenance; if the
//  fingerprint ignores it, changedIds stays empty and the cell keeps the wrong
//  chip class / sender label / stamp-strip (spec §T-D).
//

import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
struct T1753ProvenanceFingerprintTests {
    private func message(id: String, content: String, sender: String?, role: Message.Role) -> Message {
        Message(
            id: id, role: role, content: content,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), streaming: false,
            attachments: [], deviceId: sender == nil ? "device-1" : nil,
            sessionKey: "agent:main:clawline:user:s_fp", sender: sender
        )
    }

    @Test("F4 regression: fingerprint changes when only the provenance sender changes")
    func fingerprintReflectsSenderChange() {
        let controller = MessageFlowCollectionViewController()
        let base = message(id: "m1", content: "same body", sender: nil, role: .user)
        let corrected = message(id: "m1", content: "same body", sender: "user:mike", role: .user)
        #expect(controller.fingerprint(for: base) != controller.fingerprint(for: corrected))
    }

    @Test("F4 regression: fingerprint changes when only the role changes")
    func fingerprintReflectsRoleChange() {
        let controller = MessageFlowCollectionViewController()
        let asUser = message(id: "m2", content: "same body", sender: "process:cron", role: .user)
        let asAssistant = message(id: "m2", content: "same body", sender: "process:cron", role: .assistant)
        #expect(controller.fingerprint(for: asUser) != controller.fingerprint(for: asAssistant))
    }

    @Test("F4: identical messages keep a stable fingerprint")
    func fingerprintStableForIdenticalMessages() {
        let controller = MessageFlowCollectionViewController()
        let a = message(id: "m3", content: "same body", sender: "agent:atlas", role: .user)
        let b = message(id: "m3", content: "same body", sender: "agent:atlas", role: .user)
        #expect(controller.fingerprint(for: a) == controller.fingerprint(for: b))
    }
}
