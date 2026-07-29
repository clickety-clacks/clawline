//
//  SessionStatusDecodeResilienceTests.swift
//  ClawlineTests
//
//  Decode posture for `SessionStatus`: resilient with explicit defaults, never
//  silent. The failure these tests exist to prevent shipped once and was
//  invisible from both sides — the gateway answered 200 with a payload that
//  was well-formed by its own contract, one field the client declared
//  non-optional was absent, Swift's all-or-nothing synthesized `Decodable`
//  threw, the view model's status stayed nil, and the model footer read
//  "Model loading" forever.
//
//  FIXTURE PROVENANCE: `capturedPayload` is a REAL response, not a
//  hand-written one — `GET /api/session-status` from a tightbeam gateway
//  booted on 2026-07-25 from the client-e2e driver's own leg provisioning
//  (tightbeam_ex feat-client-e2e, harness claude, model fable, host eezo),
//  captured through the sim client and copied verbatim. `modelCatalog.models`
//  is empty in the capture because that org's credential metadata row was
//  missing and its catalog refresh was degraded — a real state, and the one
//  the footer's "no options" path renders.
//
//  Assertions are on CONSUMED fields only: what the footer and the view model
//  actually read.
//

import Foundation
import Testing
@testable import Clawline

struct SessionStatusDecodeResilienceTests {
    /// Verbatim `GET /api/session-status` capture (see the provenance note).
    private static let capturedPayload = """
    {
      "approval": null,
      "capabilities": {
        "canCancelCurrentRun": true,
        "canChangeFastMode": false,
        "canChangeModel": true,
        "canChangeReasoning": false,
        "canChangeVerbosity": false,
        "cancelCurrentRun": {"supported": true},
        "readOnlyStatus": false,
        "setFastMode": {"reason": "not supported", "supported": false},
        "setMode": {"reason": "sessions run YOLO", "supported": false},
        "setModel": {"options": [], "supported": true},
        "setReasoning": {"reason": "current model has no effort tiers", "supported": false},
        "setThinking": {"reason": "thinking control lands in a later milestone", "supported": false},
        "setVerbosity": {"reason": "not supported", "supported": false}
      },
      "context": null,
      "display": {
        "authMode": null,
        "fastMode": null,
        "harness": "claude",
        "host": "eezo",
        "mode": null,
        "model": "fable",
        "modelPreferences": null,
        "provider": "anthropic",
        "reasoningLevel": null,
        "thinkingLevel": null,
        "verbosity": null
      },
      "modelCatalog": {"available": true, "models": []},
      "run": {
        "messageId": null,
        "queueDepth": 0,
        "runId": null,
        "startedAt": null,
        "state": "idle"
      },
      "sessionKey": "agent:main:clawline:capture:main"
    }
    """

    /// Every top-level key of the real payload, so a field added to the
    /// gateway's contract cannot quietly escape this suite.
    private static let capturedKeys = [
        "approval", "capabilities", "context", "display", "modelCatalog", "run", "sessionKey"
    ]

    private func decode(_ json: String) throws -> SessionStatus {
        try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
    }

    private func payloadDropping(_ key: String) throws -> String {
        let data = Data(Self.capturedPayload.utf8)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: key)
        let trimmed = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: trimmed, encoding: .utf8))
    }

    @Test("The real captured payload decodes and carries what the footer reads")
    func capturedPayloadDecodes() throws {
        let status = try decode(Self.capturedPayload)

        #expect(status.sessionKey == "agent:main:clawline:capture:main")
        #expect(status.display.model == "fable")
        #expect(status.display.harness == "claude")
        #expect(status.display.host == "eezo")
        #expect(status.run.state == .idle)
        #expect(status.capabilities.setModel?.supported == true)
        #expect(status.modelCatalog?.models.isEmpty == true)
    }

    @Test("The fixture covers the gateway's whole top-level contract")
    func fixtureCoversTheContract() throws {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(Self.capturedPayload.utf8)) as? [String: Any]
        )
        #expect(Set(object.keys) == Set(Self.capturedKeys))
    }

    // MARK: - Per-field resilience
    //
    // One test per required section: drop it from the real payload and assert
    // the chosen posture — a usable status with an explicit default, NOT a
    // thrown decode that empties the footer.

    @Test("A payload with no `display` still yields a usable status")
    func missingDisplayDefaults() throws {
        let status = try decode(try payloadDropping("display"))

        #expect(status.sessionKey == "agent:main:clawline:capture:main")
        #expect(status.display == SessionStatus.Display.empty)
        #expect(status.display.model == nil)
        // The rest of the payload survives — that is the whole point of the
        // posture: one absent section does not cost the others.
        #expect(status.run.state == .idle)
        #expect(status.capabilities.canChangeModel == true)
    }

    @Test("A payload with no `run` still yields a usable status, in state .unknown")
    func missingRunDefaults() throws {
        let status = try decode(try payloadDropping("run"))

        #expect(status.run == SessionStatus.Run.empty)
        #expect(status.run.state == .unknown)
        #expect(status.display.model == "fable")
    }

    @Test("A payload with no `capabilities` still yields a usable status")
    func missingCapabilitiesDefaults() throws {
        let status = try decode(try payloadDropping("capabilities"))

        #expect(status.capabilities == SessionStatus.Capabilities.empty)
        #expect(status.capabilities.setModel == nil)
        #expect(status.display.model == "fable")
    }

    @Test("A `run` whose required `state` is gone defaults the section, not the status")
    func undecodableRunSectionDefaults() throws {
        let json = Self.capturedPayload.replacingOccurrences(
            of: "\"state\": \"idle\"",
            with: "\"stage\": \"idle\""
        )
        let status = try decode(json)

        #expect(status.run.state == .unknown)
        #expect(status.display.model == "fable")
        #expect(status.sessionKey == "agent:main:clawline:capture:main")
    }

    @Test("An unrecognized run state decodes as .unknown rather than failing")
    func unknownRunStateDecodes() throws {
        let json = Self.capturedPayload.replacingOccurrences(
            of: "\"state\": \"idle\"",
            with: "\"state\": \"reticulating\""
        )

        #expect(try decode(json).run.state == .unknown)
    }

    @Test("Optional sections that arrive malformed default without taking the status down")
    func malformedOptionalSectionDefaults() throws {
        let json = Self.capturedPayload.replacingOccurrences(
            of: "\"modelCatalog\": {\"available\": true, \"models\": []}",
            with: "\"modelCatalog\": \"not-an-object\""
        )
        let status = try decode(json)

        #expect(status.modelCatalog == nil)
        #expect(status.display.model == "fable")
    }

    // MARK: - The one field that stays strict

    @Test("A payload with no `sessionKey` FAILS the decode")
    func missingSessionKeyThrows() throws {
        // sessionKey is not display material: it is the identity of what the
        // status describes and the target of every session-control action the
        // footer's pickers post. A defaulted empty key would build a picker
        // that sends set_model at no session at all, which is worse than a
        // decode failure — the status refresh already surfaces that as the
        // footer's truthful `unavailable` state.
        #expect(throws: DecodingError.self) {
            _ = try decode(try payloadDropping("sessionKey"))
        }
    }
}
