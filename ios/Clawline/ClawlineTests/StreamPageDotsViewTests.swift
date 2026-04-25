//
//  StreamPageDotsViewTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/1/26.
//

import Testing
import CoreGraphics
import SwiftUI
import UIKit
@testable import Clawline

@MainActor
struct StreamPageDotsViewTests {

    @Test("Expanded indicator width allows more visible dots than the collapsed cap")
    func expandedIndicatorShowsMoreDots() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )

        #expect(visibleCount > 11)
    }

    @Test("Expanded indicator fills the available width envelope when it can reveal more dots")
    func expandedIndicatorUsesAvailableWidthEnvelope() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )
        let targetWidth = StreamPageDotsView.targetControlWidth(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )
        let expectedWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: visibleCount,
            includesOverflowIndicators: visibleCount < 40
        )

        #expect(targetWidth != nil)
        #expect(targetWidth == expectedWidth)
    }

    @Test("Expanded indicator stays collapsed when the width budget cannot reveal more dots")
    func expandedIndicatorSkipsWidthExpansionWithoutAdditionalCapacity() {
        let collapsedWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: 11,
            includesOverflowIndicators: true
        )
        let targetWidth = StreamPageDotsView.targetControlWidth(
            totalSessionCount: 40,
            maxWidth: collapsedWidth
        )

        #expect(targetWidth == nil)
    }

    @Test("Collapsed indicator keeps the legacy visible-dot cap")
    func collapsedIndicatorKeepsLegacyCap() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: nil
        )

        #expect(visibleCount == 11)
    }

    @Test("Rendered indicator width matches the visible control width")
    func renderedControlWidthMatchesVisibleControlWidth() {
        let visibleCount = StreamPageDotsView.fittingVisibleDotCount(
            totalSessionCount: 40,
            maxWidth: CGFloat(640)
        )
        let expectedWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: visibleCount,
            includesOverflowIndicators: visibleCount < 40
        )

        #expect(
            StreamPageDotsView.renderedControlWidth(
                totalSessionCount: 40,
                maxWidth: CGFloat(640)
            ) == expectedWidth
        )
    }

    @Test("Popup route controller owns popup search and track picker surfaces")
    func popupRouteControllerOwnsPopupAndTrackPickerSurfaces() {
        let routeController = StreamPopupRouteController()

        #expect(routeController.route == .closed)
        #expect(routeController.isPopupPresented == false)
        #expect(routeController.isTrackPickerPresented == false)

        routeController.openPopup(focusSearch: false)

        #expect(routeController.route == .popup(searchFocus: .none))
        #expect(routeController.isPopupPresented)
        #expect(routeController.popupSearchFocusRequestID == nil)

        routeController.openPopup(focusSearch: true)
        let initialSearchFocusRequestID = routeController.popupSearchFocusRequestID

        #expect(initialSearchFocusRequestID != nil)
        if let initialSearchFocusRequestID {
            #expect(routeController.route == .popup(searchFocus: .request(id: initialSearchFocusRequestID)))
        }

        routeController.consumeSearchFocusRequest()

        #expect(routeController.route == .popup(searchFocus: .none))
        #expect(routeController.popupSearchFocusRequestID == nil)

        routeController.presentTrackPicker()

        #expect(routeController.route == .trackPicker)
        #expect(routeController.isPopupPresented == false)
        #expect(routeController.isTrackPickerPresented)

        routeController.dismissTrackPicker()

        #expect(routeController.route == .closed)
    }

    @Test("Active dots override unread styling")
    func activeKindWinsPrecedence() {
        let kind = StreamDotColor.kind(
            isActive: true,
            dotState: .unread
        )

        #expect(kind == .active)
    }

    @Test("User-tail dots use the dedicated gold state when not active or unread")
    func userTailKindIsDistinct() {
        let kind = StreamDotColor.kind(
            isActive: false,
            dotState: .userTail
        )

        #expect(kind == .userTail)
    }

    @Test("Active dots use the brighter avatar highlight green")
    func activeDotsUseAvatarHighlightGreen() {
        let color = StreamDotColor.resolve(
            isActive: true,
            dotState: .inactive,
            colorScheme: .light
        )

        #expect(Self.rgb(color) == RGB(red: 0.48, green: 0.68, blue: 0.48))
    }

    @Test("Unread dots keep the unread indicator color")
    func unreadDotsUseUnreadIndicatorColor() {
        let color = StreamDotColor.resolve(
            isActive: false,
            dotState: .unread,
            colorScheme: .light
        )

        #expect(Self.rgb(color) == Self.rgb(ChatFlowTheme.unreadIndicator(.light)))
    }

    private struct RGB: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private static func rgb(_ color: Color) -> RGB {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(
            red: rounded(red),
            green: rounded(green),
            blue: rounded(blue)
        )
    }

    private static func rounded(_ value: CGFloat) -> CGFloat {
        (value * 100).rounded() / 100
    }
}
