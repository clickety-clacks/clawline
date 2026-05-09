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

    @Test("T257: scrub start maps touch position through the visible dot window")
    func scrubStartMapsTouchPositionThroughVisibleWindow() {
        let visibleDotIndices = Array(15...25)
        let controlWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: visibleDotIndices.count,
            includesOverflowIndicators: true
        )
        let centerX = StreamPageDotsView.dotCenterX(
            for: 20,
            totalSessionCount: 40,
            visibleDotIndices: visibleDotIndices,
            fieldWidth: controlWidth
        )!
        let startIndex = StreamPageDotsView.scrubStartCandidateIndex(
            startLocationX: centerX,
            fieldWidth: controlWidth,
            totalSessionCount: 40,
            visibleDotIndices: visibleDotIndices,
            fallbackIndex: 20
        )
        let virtualIndex = StreamPageDotsView.scrubStartVirtualIndex(
            startLocationX: centerX,
            fieldWidth: controlWidth,
            totalSessionCount: 40,
            visibleDotIndices: visibleDotIndices,
            fallbackIndex: 20
        )

        #expect(startIndex == 20)
        #expect(abs(virtualIndex - 20) < 0.001)
    }

    @Test("T276: every visible dot center maps back to the same scrub candidate")
    func everyVisibleDotCenterMapsBackToSameScrubCandidate() {
        let visibleDotIndices = Array(15...25)
        let controlWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: visibleDotIndices.count,
            includesOverflowIndicators: true
        )

        for index in visibleDotIndices {
            let centerX = StreamPageDotsView.dotCenterX(
                for: index,
                totalSessionCount: 40,
                visibleDotIndices: visibleDotIndices,
                fieldWidth: controlWidth
            )

            #expect(centerX != nil)
            if let centerX {
                let candidateIndex = StreamPageDotsView.scrubStartCandidateIndex(
                    startLocationX: centerX,
                    fieldWidth: controlWidth,
                    totalSessionCount: 40,
                    visibleDotIndices: visibleDotIndices,
                    fallbackIndex: 20
                )
                let virtualIndex = StreamPageDotsView.scrubStartVirtualIndex(
                    startLocationX: centerX,
                    fieldWidth: controlWidth,
                    totalSessionCount: 40,
                    visibleDotIndices: visibleDotIndices,
                    fallbackIndex: 20
                )

                #expect(candidateIndex == index)
                #expect(abs(virtualIndex - CGFloat(index)) < 0.001)
            }
        }
    }

    @Test("T276: dot centers account for optional overflow indicators")
    func dotCentersAccountForOverflowIndicators() {
        let middleWindow = Array(15...25)
        let middleWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: middleWindow.count,
            includesOverflowIndicators: true
        )
        let leadingEdgeWindow = Array(0...10)
        let leadingEdgeWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: leadingEdgeWindow.count,
            includesOverflowIndicators: true
        )

        let middleCenters = StreamPageDotsView.visibleDotCenters(
            totalSessionCount: 40,
            visibleDotIndices: middleWindow,
            fieldWidth: middleWidth
        )
        let leadingEdgeCenters = StreamPageDotsView.visibleDotCenters(
            totalSessionCount: 40,
            visibleDotIndices: leadingEdgeWindow,
            fieldWidth: leadingEdgeWidth
        )

        #expect(middleCenters.map { $0.index } == middleWindow)
        #expect(leadingEdgeCenters.map { $0.index } == leadingEdgeWindow)
        #expect(abs((middleCenters[1].centerX - middleCenters[0].centerX) - 14) < 0.001)
        #expect(abs((leadingEdgeCenters[1].centerX - leadingEdgeCenters[0].centerX) - 14) < 0.001)
        #expect(middleCenters[0].centerX > leadingEdgeCenters[0].centerX)
    }

    @Test("T276: expanded scrub field coordinates rebase to stable dock coordinates")
    func expandedScrubFieldCoordinatesRebaseToStableDockCoordinates() {
        let visibleDotIndices = Array(15...25)
        let baseWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: visibleDotIndices.count,
            includesOverflowIndicators: true
        )
        let expandedMetrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: visibleDotIndices.count,
            controlWidth: baseWidth,
            maxWidth: 420,
            isScrubbing: true
        )
        let fieldExtra = expandedMetrics.scrubFieldWidth - baseWidth

        #expect(fieldExtra > 0)
        for index in visibleDotIndices {
            let dockCenterX = StreamPageDotsView.dotCenterX(
                for: index,
                totalSessionCount: 40,
                visibleDotIndices: visibleDotIndices,
                fieldWidth: baseWidth
            )!
            let expandedLocalX = dockCenterX + (fieldExtra / 2)
            let rebasedX = StreamPageDotsView.dockLocationX(
                fromScrubFieldLocationX: expandedLocalX,
                scrubFieldWidth: expandedMetrics.scrubFieldWidth,
                baseControlWidth: baseWidth
            )
            let candidateIndex = StreamPageDotsView.scrubStartCandidateIndex(
                startLocationX: rebasedX,
                fieldWidth: baseWidth,
                totalSessionCount: 40,
                visibleDotIndices: visibleDotIndices,
                fallbackIndex: 20
            )

            #expect(abs(rebasedX - dockCenterX) < 0.001)
            #expect(candidateIndex == index)
        }
    }

    @Test("T257: scrub translation can reach dots truncated beyond both edges")
    func scrubTranslationCanReachTruncatedEdges() {
        let rightEdge = StreamPageDotsView.scrubCandidateIndex(
            sessionCount: 40,
            startIndex: 20,
            translationWidth: 19 * 14
        )
        let leftEdge = StreamPageDotsView.scrubCandidateIndex(
            sessionCount: 40,
            startIndex: 20,
            translationWidth: -20 * 14
        )
        let rightVirtualEdge = StreamPageDotsView.scrubVirtualIndex(
            sessionCount: 40,
            startVirtualIndex: 20,
            startLocationX: 95,
            currentLocationX: 95 + (19 * 14)
        )
        let leftVirtualEdge = StreamPageDotsView.scrubVirtualIndex(
            sessionCount: 40,
            startVirtualIndex: 20,
            startLocationX: 95,
            currentLocationX: 95 - (20 * 14)
        )

        #expect(rightEdge == 39)
        #expect(leftEdge == 0)
        #expect(rightVirtualEdge == 39)
        #expect(leftVirtualEdge == 0)
    }

    @Test("T257: scrub haptic fires only when candidate changes after initial highlight")
    func scrubHapticFiresOnlyForCandidateChangesAfterInitialHighlight() {
        #expect(StreamPageDotsView.shouldEmitScrubCandidateHaptic(previousIndex: nil, candidateIndex: 10) == false)
        #expect(StreamPageDotsView.shouldEmitScrubCandidateHaptic(previousIndex: 10, candidateIndex: 10) == false)
        #expect(StreamPageDotsView.shouldEmitScrubCandidateHaptic(previousIndex: 10, candidateIndex: 11) == true)
    }

    @Test("T276: selection ring resolves to the active dot unless scrub has a valid candidate")
    func selectionRingFollowsResolvedSelectedDot() {
        #expect(
            StreamPageDotsView.selectionRingIndex(
                activeIndex: 3,
                scrubCandidateIndex: nil,
                sessionCount: 8
            ) == 3
        )
        #expect(
            StreamPageDotsView.selectionRingIndex(
                activeIndex: 3,
                scrubCandidateIndex: 5,
                sessionCount: 8
            ) == 5
        )
        #expect(
            StreamPageDotsView.selectionRingIndex(
                activeIndex: 3,
                scrubCandidateIndex: 12,
                sessionCount: 8
            ) == 3
        )
    }

    @Test("T277: scrub drag-away cancel uses the indicator hit target distance")
    func scrubDragAwayCancelUsesIndicatorHitTargetDistance() {
        #expect(StreamPageDotsView.shouldCancelScrub(locationY: 21) == false)
        #expect(StreamPageDotsView.shouldCancelScrub(locationY: 44) == false)
        #expect(StreamPageDotsView.shouldCancelScrub(locationY: -23) == false)
        #expect(StreamPageDotsView.shouldCancelScrub(locationY: 88) == false)
        #expect(StreamPageDotsView.shouldCancelScrub(locationY: -24) == true)
        #expect(StreamPageDotsView.shouldCancelScrub(locationY: 89) == true)
    }

    @Test("T257: scrub candidate haptic strength follows existing dot visual state")
    func scrubCandidateHapticStrengthFollowsDotVisualState() {
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: false, dotState: .inactive) == .light)
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: true, dotState: .inactive) == .strong)
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: false, dotState: .unread) == .strong)
        #expect(StreamPageDotsView.scrubCandidateHapticStyle(isActive: false, dotState: .userTail) == .strong)
    }

    @Test("T257: scrub metrics temporarily widen dense dot lists")
    func scrubMetricsTemporarilyWidenDenseDotLists() {
        let rest = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: false
        )
        let active = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )

        #expect(rest.scrubFieldWidth == 190)
        #expect(active.scrubFieldWidth > rest.scrubFieldWidth)
        #expect(active.magnificationRadius > rest.magnificationRadius)
        #expect(active.magnificationRadius > 9)
        #expect(active.magnificationRadius < 10)
        #expect(active.maximumScale > rest.maximumScale)
    }

    @Test("T257: scrub magnification uses a shorter tail with a wider central spike")
    func scrubMagnificationFallsOffWithDistance() {
        let metrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )
        let primary = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10, metrics: metrics)
        let neighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10, metrics: metrics)
        let outer = StreamPageDotsView.scrubMagnificationScale(dotIndex: 12, virtualIndex: 10, metrics: metrics)
        let farParticipant = StreamPageDotsView.scrubMagnificationScale(dotIndex: 18, virtualIndex: 10, metrics: metrics)
        let outside = StreamPageDotsView.scrubMagnificationScale(dotIndex: 20, virtualIndex: 10, metrics: metrics)

        #expect(primary > neighbor)
        #expect(neighbor > outer)
        #expect(outer > farParticipant)
        #expect(farParticipant > outside)
        #expect(outside == 1)
        #expect(primary > 3.0)
        #expect(neighbor > 2.8)
        #expect(outer > 1.9)
        #expect(outer < 2.2)
        #expect(farParticipant < 1.1)
        #expect(primary - neighbor < 0.5)
        #expect((neighbor - outer) > (primary - neighbor))
    }

    @Test("T257: scrub magnification tracks continuous finger position")
    func scrubMagnificationTracksContinuousFingerPosition() {
        let metrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )
        let leftBiasDot = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10.25, metrics: metrics)
        let leftBiasNeighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10.25, metrics: metrics)
        let midpointLeft = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10.5, metrics: metrics)
        let midpointRight = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10.5, metrics: metrics)
        let rightBiasDot = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10.75, metrics: metrics)
        let rightBiasNeighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10.75, metrics: metrics)

        #expect(leftBiasDot > leftBiasNeighbor)
        #expect(abs(midpointLeft - midpointRight) < 0.001)
        #expect(rightBiasNeighbor > rightBiasDot)
    }

    @Test("T257: scrub magnification lifts the center dot without a group raise")
    func scrubMagnificationLiftsCenterDotWithoutGroupRaise() {
        let metrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )
        let primary = StreamPageDotsView.scrubMagnificationScale(dotIndex: 10, virtualIndex: 10, metrics: metrics)
        let neighbor = StreamPageDotsView.scrubMagnificationScale(dotIndex: 11, virtualIndex: 10, metrics: metrics)

        #expect(StreamPageDotsView.scrubMagnificationVerticalOffset(scale: primary) < -40)
        #expect(StreamPageDotsView.scrubMagnificationVerticalOffset(scale: neighbor) < 0)
        #expect(StreamPageDotsView.scrubMagnificationVerticalOffset(scale: 1) == 0)
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

    @Test("Offscreen unread edge bloom is blurred behind the glass")
    func offscreenUnreadEdgeBloomUsesBlur() {
        #expect(StreamPageDotsView.unreadEdgeBloomOpacity(colorScheme: .light) == 0.40)
        #expect(StreamPageDotsView.unreadEdgeBloomOpacity(colorScheme: .dark) == 0.40)
        #expect(StreamPageDotsView.unreadEdgeBloomBlurRadius(colorScheme: .light) == 4.0)
        #expect(StreamPageDotsView.unreadEdgeBloomBlurRadius(colorScheme: .dark) == 4.5)
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
