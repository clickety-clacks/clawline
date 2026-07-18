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

    @Test("T1751 org-options decodes a minimal payload with absent keys as empty")
    func orgOptionsDecodesMinimalPayload() throws {
        let json = """
        { "harnesses": ["claude"] }
        """
        let options = try JSONDecoder().decode(OrgOptions.self, from: Data(json.utf8))
        #expect(options.harnesses == ["claude"])
        #expect(options.models.isEmpty)
        #expect(options.hosts.isEmpty)
        #expect(options.archetypes.isEmpty)
    }

    // MARK: - footer picker gating

    @Test("T1751 footer renders the harness picker only when the tightbeam gate is on")
    func footerRendersHarnessOnlyWhenGated() throws {
        let status = try decodedStatus(harness: "codex")

        // Gate on -> harness renders in the footer text.
        #expect(SessionMetadataFooterCell.footerText(
            for: status,
            isTightbeam: true,
            harnessOptions: ["claude", "codex"]
        )?.contains("codex") == true)

        // Gate off -> harness affordance is hidden even though the value exists.
        #expect(SessionMetadataFooterCell.footerText(
            for: status,
            isTightbeam: false,
            harnessOptions: ["claude", "codex"]
        )?.contains("codex") == false)
    }

    @Test("T1751 gated harness renders as an enabled picker button once options load")
    func gatedHarnessRendersAsEnabledPicker() throws {
        let status = try decodedStatus(harness: "codex")
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
        let status = try decodedStatus(harness: "codex")
        let cell = configuredCell(status: status, isTightbeam: true, harnessOptions: [])
        let button = try #require(
            descendants(of: cell)
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Harness codex" }
        )
        // No options yet -> not tappable, but the current engine is still shown.
        #expect(button.isEnabled == false)
    }

    @Test("T1751 ungated cell does not render the harness picker")
    func ungatedCellHidesHarness() throws {
        let status = try decodedStatus(harness: "codex")
        let cell = configuredCell(status: status, isTightbeam: false, harnessOptions: ["claude", "codex"])
        let hasHarness = descendants(of: cell)
            .compactMap { $0 as? UIButton }
            .contains { $0.accessibilityLabel == "Harness codex" }
        #expect(hasHarness == false)
    }

    // MARK: - helpers

    private func decodedStatus(harness: String) throws -> SessionStatus {
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
          "capabilities": {}
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
