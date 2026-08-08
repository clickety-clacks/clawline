//
//  MarkerDividerCellTests.swift
//  ClawlineTests
//
//  Cycle-3 Goal A, step 3. Covers MarkerDividerCell configuration and its
//  step-3b segment-anchor tap (same "internal handleTap(), no simulated
//  UIGestureRecognizer" convention as SubstrateRunCollapseCellTests).
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
        cell.configure(content: .sessionBoundary, isDark: false, isSegmentAnchorActive: false) {}
        #expect(cell.accessibilityLabel == "Session boundary")
        #expect(cell.accessibilityValue == nil)
    }

    @Test("exposes the active segment-anchor state via accessibility")
    @MainActor
    func exposesSegmentAnchorActiveState() {
        let cell = MarkerDividerCell()
        cell.configure(content: .sessionBoundary, isDark: true, isSegmentAnchorActive: true) {}
        #expect(cell.accessibilityValue == "Showing only since this boundary")
    }

    @Test("tap invokes the supplied segment-anchor toggle closure")
    @MainActor
    func tapInvokesToggleClosure() {
        let cell = MarkerDividerCell()
        var tapped = false
        cell.configure(content: .sessionBoundary, isDark: false, isSegmentAnchorActive: false) {
            tapped = true
        }
        cell.handleTap()
        #expect(tapped)
    }
}
