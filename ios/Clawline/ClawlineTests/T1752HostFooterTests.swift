//
//  T1752HostFooterTests.swift
//  ClawlineTests
//
//  T-C: the session's host name (SessionStatus.display.host) renders near the
//  auth/CLI indicator in the footer, tightbeam-gated. Absent host key renders
//  nothing (openclaw payloads lack the key).
//

import Foundation
import Testing
import UIKit
@testable import Clawline

@MainActor
struct T1752HostFooterTests {
    @Test("T1752 decodes display.host when present")
    func decodesHostWhenPresent() throws {
        let status = try decodedStatus(hostJSON: "\"eezo\"")
        #expect(status.display.host == "eezo")
    }

    @Test("T1752 absent host key decodes as nil without failing")
    func absentHostDecodesNil() throws {
        let status = try decodedStatus(hostJSON: nil)
        #expect(status.display.host == nil)
    }

    @Test("T1752 renders host only when tightbeam gate is on and host is present")
    func footerRendersHostOnlyWhenGatedAndPresent() throws {
        let withHost = try decodedStatus(hostJSON: "\"eezo\"")
        let withoutHost = try decodedStatus(hostJSON: nil)

        // Gate on + host present -> host renders.
        #expect(SessionMetadataFooterCell.footerText(for: withHost, isTightbeam: true)?
            .contains("eezo") == true)

        // Gate off + host present -> nothing (openclaw safety already holds on absent key,
        // but the affordance is tightbeam-gated like the rest).
        #expect(SessionMetadataFooterCell.footerText(for: withHost, isTightbeam: false)?
            .contains("eezo") == false)

        // Gate on + host absent -> the host contributes nothing at all: the
        // footer is byte-identical to the with-host footer minus the host
        // segment, so no placeholder of any kind can sneak in.
        let gatedWithHost = try #require(SessionMetadataFooterCell.footerText(for: withHost, isTightbeam: true))
        let gatedNoHost = try #require(SessionMetadataFooterCell.footerText(for: withoutHost, isTightbeam: true))
        #expect(gatedNoHost.contains("eezo") == false)
        #expect(gatedWithHost.replacingOccurrences(of: "  ·  eezo", with: "") == gatedNoHost)
    }

    @Test("T1752 gated host renders as a labeled footer chip in the cell")
    func gatedHostRendersAsCellChip() throws {
        let status = try decodedStatus(hostJSON: "\"eezo\"")

        let gatedCell = configuredCell(status: status, isTightbeam: true)
        let gatedLabels = descendants(of: gatedCell).compactMap { $0 as? UILabel }
        let hostLabel = try #require(gatedLabels.first { $0.text == "eezo" })
        #expect(hostLabel.accessibilityLabel == "Host eezo")

        let ungatedCell = configuredCell(status: status, isTightbeam: false)
        let ungatedLabels = descendants(of: ungatedCell).compactMap { $0 as? UILabel }
        #expect(ungatedLabels.contains { $0.text == "eezo" } == false)
    }

    private func decodedStatus(hostJSON: String?) throws -> SessionStatus {
        let hostField = hostJSON.map { ", \"host\": \($0)" } ?? ""
        let json = """
        {
          "sessionKey": "agent:main:clawline:user:s_t1752",
          "display": {
            "model": "claude-fable-5",
            "provider": "anthropic",
            "harness": "claude",
            "authMode": "oauth"\(hostField)
          },
          "run": {"state": "idle"},
          "capabilities": {}
        }
        """
        return try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
    }

    private func configuredCell(status: SessionStatus, isTightbeam: Bool) -> SessionMetadataFooterCell {
        let cell = SessionMetadataFooterCell(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 320,
                height: SessionMetadataFooterCell.height(for: status, width: 320, isTightbeam: isTightbeam)
            )
        )
        cell.configure(
            status: status,
            isDark: false,
            isSpatial: false,
            isTightbeam: isTightbeam,
            onSelect: { _, _, _, _ in }
        )
        cell.layoutIfNeeded()
        return cell
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
