//
//  MarkerDividerCellTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A. Covers MarkerDividerCell's render-only configuration. The
//  cell stays dormant -- nothing inserts a marker-divider item id today, since
//  the wire carries no marker signal -- but must render correctly once a
//  future typed marker payload wires it up.
//

import Foundation
import UIKit
import Testing
@testable import Clawline

struct MarkerDividerCellTests {
    @Test("configures the session-boundary label and accessibility")
    @MainActor
    func configuresSessionBoundaryContent() {
        let cell = MarkerDividerCell()
        cell.configure(content: .sessionBoundary, isDark: false)
        #expect(cell.accessibilityLabel == "Session boundary")
    }

    @Test("prepareForReuse clears the configured content")
    @MainActor
    func prepareForReuseClearsContent() {
        let cell = MarkerDividerCell()
        cell.configure(content: .sessionBoundary, isDark: false)
        cell.prepareForReuse()
        #expect(cell.accessibilityLabel == nil)
    }

    @Test("itemID prefixes the anchor message id")
    @MainActor
    func itemIDPrefixesAnchorMessageID() {
        let id = MarkerDividerCell.itemID(before: "msg-123")
        #expect(MarkerDividerCell.isMarkerDividerItemID(id))
        #expect(id == "\(MarkerDividerCell.itemIdPrefix)msg-123")
    }
}
