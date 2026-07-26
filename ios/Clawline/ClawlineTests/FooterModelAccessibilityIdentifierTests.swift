//
//  FooterModelAccessibilityIdentifierTests.swift
//  ClawlineTests
//
//  The two identifiers the tightbeam client-e2e driver needs for SMOKE §6
//  step 13 (shared-workspace specs client-e2e-v1.md, journey J6): the model
//  PICKER ENTRY it taps to change the model, and the footer LABEL it reads to
//  assert the new model actually shows.
//
//  Step 13 asserts the rendered footer rather than the raw JSON on purpose —
//  `GET /api/session-status` reporting the new ref proves nothing about what
//  the user sees, and the shipped failure was precisely a valid response the
//  client rendered as nothing. These tests hold the identifiers in place so
//  that assertion keeps having something to address.
//

import UIKit
import Testing
@testable import Clawline

@MainActor
struct FooterModelAccessibilityIdentifierTests {
    private func status(model: String) throws -> SessionStatus {
        let json = """
        {
          "sessionKey": "agent:main:clawline:user:s_footer_ax",
          "display": {"model": "\(model)", "provider": "anthropic", "harness": "claude"},
          "run": {"state": "idle"},
          "capabilities": {"setModel": {"supported": true}},
          "modelCatalog": {
            "available": true,
            "models": [
              {"id": "fable", "provider": "anthropic", "ref": "fable", "name": "Fable"},
              {"id": "opus", "provider": "anthropic", "ref": "opus", "name": "Opus"}
            ]
          }
        }
        """
        return try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
    }

    private func configuredCell(status: SessionStatus?, statusUnavailable: Bool = false) -> SessionMetadataFooterCell {
        let width: CGFloat = 390
        let cell = SessionMetadataFooterCell(
            frame: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: SessionMetadataFooterCell.height(for: status, width: width)
            )
        )
        cell.configure(
            status: status,
            statusUnavailable: statusUnavailable,
            isDark: false,
            onSelect: { _, _, _, _ in }
        )
        cell.layoutIfNeeded()
        return cell
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func modelControl(in cell: SessionMetadataFooterCell) -> UIView? {
        descendants(of: cell).first {
            $0.accessibilityIdentifier == SessionMetadataFooterCell.modelPickerAccessibilityIdentifier
        }
    }

    @Test("The model picker entry is addressable and shows the current model")
    func modelPickerIsAddressable() throws {
        let cell = configuredCell(status: try status(model: "fable"))
        let control = try #require(modelControl(in: cell), "no view carries the model picker identifier")
        let button = try #require(control as? UIButton)

        #expect(button.isEnabled)
        // The control shows the catalog's DISPLAY NAME, not the raw ref — a
        // driver asserting SMOKE §6 step 13 against the ref it just posted
        // would fail on a correct client.
        #expect(button.configuration?.title == "Fable")
    }

    @Test("The picker entry keeps its identifier after a model change")
    func identifierSurvivesAModelChange() throws {
        let cell = configuredCell(status: try status(model: "fable"))
        cell.configure(status: try status(model: "opus"), isDark: false, onSelect: { _, _, _, _ in })
        cell.layoutIfNeeded()

        let button = try #require(modelControl(in: cell) as? UIButton)
        #expect(button.configuration?.title == "Opus")
    }

    @Test("The footer label carries the composed footer text")
    func footerLabelCarriesComposedText() throws {
        let status = try status(model: "fable")
        let cell = configuredCell(status: status)

        #expect(cell.accessibilityIdentifier == SessionMetadataFooterCell.footerAccessibilityIdentifier)
        let value = try #require(cell.accessibilityValue)
        #expect(value.contains("Fable"))
        #expect(value == SessionMetadataFooterCell.footerText(for: status))
    }

    @Test("With no status the surfaces still exist and read truthfully")
    func placeholderStateStaysAddressable() throws {
        // The decode-failure state must remain legible rather than vanishing:
        // a driver that cannot find the control at all reports "element not
        // found", which says nothing about why the footer is empty.
        let cell = configuredCell(status: nil, statusUnavailable: true)

        let control = try #require(modelControl(in: cell))
        #expect(control.accessibilityLabel == "Model unavailable")
        #expect(cell.accessibilityValue?.contains("Model unavailable") == true)
    }
}
