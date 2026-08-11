//
//  T1751HarnessSelectorTests.swift
//  ClawlineTests
//
//  T-A: the footer harness selector (tightbeam only). The current harness
//  (SessionStatus.display.harness) renders as a picker whose options come from
//  GET /api/org-options → harnesses. Absent gate / absent harness render
//  nothing; org-options decodes the full four-key shape and a minimal payload.
//

import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
struct T1751HarnessSelectorTests {
    // MARK: - org-options decode

    @Test("T1751 org-options decodes the full four-key shape")
    func orgOptionsDecodesFullShape() throws {
        let json = """
        {
          "harnesses": ["claude", "codex"],
          "models": {
            "claude": [{"id": "m1", "ref": "claude-fable-5", "name": "Fable 5", "provider": "anthropic"}],
            "codex": [{"id": "m2", "ref": "gpt-5.6-sol", "name": "Sol", "provider": "openai"}]
          },
          "hosts": ["eezo", "tars"],
          "archetypes": [{"name": "researcher", "where": ["*"], "defaults": {"harness": "claude"}}]
        }
        """
        let options = try JSONDecoder().decode(OrgOptions.self, from: Data(json.utf8))
        #expect(options.harnesses == ["claude", "codex"])
        #expect(options.models["claude"]?.first?.ref == "claude-fable-5")
        #expect(options.models["codex"]?.first?.provider == "openai")
        #expect(options.hosts == ["eezo", "tars"])
        #expect(options.archetypes.first?.name == "researcher")
        #expect(options.archetypes.first?.where == ["*"])
    }

    @Test("R4 regression: org-options decode is strict — a payload missing any contract key fails loudly")
    func orgOptionsRejectsMissingContractKeys() throws {
        let fullPayload: [String: Any] = [
            "harnesses": ["claude"],
            "models": ["claude": [["id": "m1", "ref": "claude-fable-5", "name": "Fable 5", "provider": "anthropic"]]],
            "hosts": ["eezo"],
            "archetypes": [["name": "default", "where": ["*"], "defaults": [:]]]
        ]
        for missingKey in ["harnesses", "models", "hosts", "archetypes"] {
            var payload = fullPayload
            payload.removeValue(forKey: missingKey)
            let data = try JSONSerialization.data(withJSONObject: payload)
            #expect(throws: (any Error).self, "missing \(missingKey) must fail the decode") {
                _ = try JSONDecoder().decode(OrgOptions.self, from: data)
            }
        }
        // Archetype `where` is client-consumed and equally required.
        let missingWhere = """
        {"harnesses": [], "models": {}, "hosts": [], "archetypes": [{"name": "default"}]}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OrgOptions.self, from: Data(missingWhere.utf8))
        }

        let missingDefaults = """
        {"harnesses": [], "models": {}, "hosts": [], "archetypes": [{"name": "default", "where": ["*"]}]}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OrgOptions.self, from: Data(missingDefaults.utf8))
        }

        // Spec §T-B names the full model shape {id, ref, name, provider}; a
        // model missing name or provider is contract drift, not a tolerance.
        for missingModelKey in ["id", "ref", "name", "provider"] {
            var model: [String: Any] = [
                "id": "m1", "ref": "claude-fable-5", "name": "Fable 5", "provider": "anthropic"
            ]
            model.removeValue(forKey: missingModelKey)
            let payload: [String: Any] = [
                "harnesses": ["claude"], "models": ["claude": [model]],
                "hosts": ["eezo"],
                "archetypes": [["name": "default", "where": ["*"], "defaults": [:]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            #expect(throws: (any Error).self, "model missing \(missingModelKey) must fail") {
                _ = try JSONDecoder().decode(OrgOptions.self, from: data)
            }
        }
    }

    // MARK: - footer picker gating

    @Test("T1751 footer renders the harness from per-session capability when the coarse gate is absent")
    func footerRendersHarnessFromCapabilityWhenCoarseGateIsAbsent() throws {
        let status = try decodedStatus(harness: "codex", harnessOptions: ["claude", "codex"])

        // Coarse gate on -> harness renders in the footer text.
        #expect(SessionMetadataFooterCell.footerText(
            for: status,
            isTightbeam: true,
            harnessOptions: ["claude", "codex"]
        )?.contains("codex") == true)

        // Coarse gate off -> per-session capability still renders the harness.
        #expect(SessionMetadataFooterCell.footerText(
            for: status,
            isTightbeam: false,
            harnessOptions: ["claude", "codex"]
        )?.contains("codex") == true)
    }

    @Test("T1751 gated harness renders as an enabled picker button once options load")
    func gatedHarnessRendersAsEnabledPicker() throws {
        let status = try decodedStatus(harness: "codex", harnessOptions: ["claude", "codex"])
        let cell = configuredCell(status: status, isTightbeam: true, harnessOptions: ["claude", "codex"])
        let button = try #require(
            descendants(of: cell)
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Harness codex" }
        )
        #expect(button.isEnabled)
        #expect(button.menu != nil)
    }

    @Test("T1751 harness shows as a disabled label before org-options load")
    func harnessRendersDisabledBeforeOptionsLoad() throws {
        let status = try decodedStatus(harness: "codex", harnessOptions: [])
        let cell = configuredCell(status: status, isTightbeam: true, harnessOptions: [])
        let button = try #require(
            descendants(of: cell)
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Harness codex" }
        )
        // No live per-session options yet -> not tappable, but the current engine is still shown.
        #expect(button.isEnabled == false)
        #expect(button.menu == nil)
        #expect(button.accessibilityHint == "harness_options_unavailable")
    }

    @Test("T1751 capability-present coarse-flag-absent cell renders the harness picker")
    func capabilityPresentCoarseFlagAbsentCellRendersHarness() throws {
        let status = try decodedStatus(harness: "codex", harnessOptions: ["claude", "codex"])
        let cell = configuredCell(status: status, isTightbeam: false, harnessOptions: ["claude", "codex"])
        let button = try #require(
            descendants(of: cell)
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Harness codex" }
        )
        #expect(button.isEnabled)
        #expect(button.menu != nil)
    }

    // MARK: - helpers

    private func decodedStatus(harness: String, harnessOptions: [String]? = nil) throws -> SessionStatus {
        let setHarnessCapability: String
        if let harnessOptions {
            let options = harnessOptions
                .map { #"{"title": "\#($0)", "value": "\#($0)", "enabled": true}"# }
                .joined(separator: ", ")
            setHarnessCapability = #""setHarness": {"supported": true, "options": [\#(options)]}"#
        } else {
            setHarnessCapability = ""
        }
        let json = """
        {
          "sessionKey": "agent:main:clawline:user:s_t1751",
          "display": {
            "model": "claude-fable-5",
            "provider": "anthropic",
            "harness": "\(harness)",
            "authMode": "oauth"
          },
          "run": {"state": "idle"},
          "capabilities": {\(setHarnessCapability)}
        }
        """
        return try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
    }

    private func configuredCell(
        status: SessionStatus,
        isTightbeam: Bool,
        harnessOptions: [String]
    ) -> SessionMetadataFooterCell {
        let cell = SessionMetadataFooterCell(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 320,
                height: SessionMetadataFooterCell.height(
                    for: status,
                    width: 320,
                    isTightbeam: isTightbeam,
                    harnessOptions: harnessOptions
                )
            )
        )
        cell.configure(
            status: status,
            isDark: false,
            isSpatial: false,
            isTightbeam: isTightbeam,
            harnessOptions: harnessOptions,
            onSelect: { _, _, _, _ in }
        )
        cell.layoutIfNeeded()
        return cell
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
