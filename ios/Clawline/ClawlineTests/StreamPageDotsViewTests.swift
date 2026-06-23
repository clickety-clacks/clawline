//
//  StreamPageDotsViewTests.swift
//  ClawlineTests
//
//  Created by Codex on 4/1/26.
//

import Testing
import CoreGraphics
import Foundation
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


    @Test("Expanded indicator host stays within requested width envelope")
    func expandedIndicatorHostFitsRequestedWidth() {
        let sessionKeys = (0..<40).map { "session-\($0)" }
        let requestedWidth = CGFloat(220)
        let targetWidth = StreamPageDotsView.renderedControlWidth(
            totalSessionCount: sessionKeys.count,
            maxWidth: requestedWidth
        )

        let view = StreamPageDotsView(
            sessionKeys: sessionKeys,
            activeSessionKey: sessionKeys[35],
            dotStateLookup: StreamDotStateLookup { _ in .inactive },
            maxWidth: requestedWidth,
            onTap: {},
            onScrubPreview: { _ in },
            onScrubCommit: { _ in },
            onScrubCancel: {},
            onScrubCandidateHaptic: { _ in }
        )

        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        let measured = host.sizeThatFits(in: CGSize(width: requestedWidth, height: 200))

        #expect(targetWidth <= requestedWidth)
        #expect(measured.width <= requestedWidth + 1)
    }

    @Test("T278: dot indicator state matrix preserves wave overflow while containing blobs")
    func dotIndicatorStateMatrixPreservesWaveOverflowWhileContainingBlobs() {
        let restMetrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: false
        )
        let swipeMetrics = StreamPageDotsView.scrubLayoutMetrics(
            totalSessionCount: 40,
            visibleDotCount: 11,
            controlWidth: 190,
            maxWidth: 190,
            isScrubbing: true
        )
        let waveScale = StreamPageDotsView.scrubMagnificationScale(
            dotIndex: 10,
            virtualIndex: 10,
            metrics: swipeMetrics
        )
        let waveBounds = StreamPageDotsView.dotWaveVisualBounds(scale: waveScale)
        let capsuleTopY = StreamPageDotsView.waveRenderHeight - StreamPageDotsView.controlHeight
        let capsuleBounds = StreamPageDotsView.unreadEdgeBloomCapsuleBounds(capsuleWidth: 190)
        let trailingBlobBounds = StreamPageDotsView.unreadEdgeBloomVisualBounds(
            edge: .trailing,
            layoutDirection: .leftToRight,
            capsuleBounds: capsuleBounds,
            colorScheme: .dark
        )
        let edgeUnreadDotCenter = StreamPageDotsView.dotCenterX(
            for: 0,
            totalSessionCount: 11,
            visibleDotIndices: Array(0..<11),
            fieldWidth: 190
        )!
        let edgeUnreadDotBounds = CGRect(
            x: edgeUnreadDotCenter - 3.5,
            y: (StreamPageDotsView.controlHeight / 2) - 3.5,
            width: 7,
            height: 7
        )

        #expect(restMetrics.scrubFieldWidth == 190)
        #expect(swipeMetrics.scrubFieldWidth > restMetrics.scrubFieldWidth)
        #expect(StreamPageDotsView.scrubMagnificationVerticalOffset(scale: waveScale) < -40)
        #expect(waveBounds.minY >= 0)
        #expect(waveBounds.minY < capsuleTopY)
        #expect(waveBounds.maxY < capsuleTopY)
        #expect(edgeUnreadDotBounds.minX >= 0)
        #expect(edgeUnreadDotBounds.maxX <= 190)
        #expect(edgeUnreadDotBounds.minY >= 0)
        #expect(edgeUnreadDotBounds.maxY <= StreamPageDotsView.controlHeight)
        #expect(trailingBlobBounds.maxX <= capsuleBounds.maxX)
        #expect(StreamPageDotsView.selectionRingIndex(activeIndex: 10, scrubCandidateIndex: nil, sessionCount: 40) == 10)
        #expect(StreamPageDotsView.selectionRingIndex(activeIndex: 10, scrubCandidateIndex: 12, sessionCount: 40) == 12)
        #expect(StreamPageDotsView.shouldCancelScrub(locationY: -24))
    }

    @Test("T278: source invariants preserve wave overflow and local blob containment")
    func sourceInvariantsPreserveWaveOverflowAndLocalBlobContainment() throws {
        let source = try Self.streamPageDotsSource()
        let controlBodySource = try Self.sourceSection(
            source,
            from: "private var controlBody",
            to: "private func dockChrome"
        )

        #expect(!controlBodySource.contains(".clipShape(Capsule())"))
        #expect(!controlBodySource.contains(".frame(width: controlWidth, height: Self.controlHeight"))
        #expect(controlBodySource.contains(".frame(width: scrubFieldWidth, height: Self.waveRenderHeight, alignment: .bottom)"))
        #expect(controlBodySource.contains(".frame(width: scrubFieldWidth, height: Self.minimumHitTargetHeight, alignment: .bottom)"))
        #expect(source.contains("unreadEdgeBloomOverlay(capsuleBounds: capsuleBounds)"))
        #expect(source.contains(".blur(radius: Self.unreadEdgeBloomBlurRadius(colorScheme: colorScheme))\n                    .mask(Capsule())"))
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

    @Test("T1136 stream popup search focus follows software keyboard visibility")
    func streamPopupSearchFocusFollowsSoftwareKeyboardVisibility() {
        #expect(StreamPopupFocusHandoff.shouldFocusSearchOnOpen(isSoftwareKeyboardVisible: true))
        #expect(StreamPopupFocusHandoff.shouldFocusSearchOnOpen(isSoftwareKeyboardVisible: false) == false)
    }

    @Test("T1136 software keyboard visibility is safe-area compensated")
    func softwareKeyboardVisibilityIsSafeAreaCompensated() {
        #expect(
            StreamPopupFocusHandoff.isSoftwareKeyboardVisible(
                keyboardHeight: 336,
                safeAreaBottom: 34
            )
        )
        #expect(
            StreamPopupFocusHandoff.isSoftwareKeyboardVisible(
                keyboardHeight: 34,
                safeAreaBottom: 34
            ) == false
        )
    }

    @Test("T1136 keyboard-down popup presentation keeps filter out of initial focus")
    func keyboardDownPopupPresentationKeepsFilterOutOfInitialFocus() {
        #expect(
            StreamPopupSearchPresentationFocusPolicy
                .shouldRenderSearchTextFieldOnInitialPresentation(searchFocusRequestID: nil) == false
        )
        #expect(
            StreamPopupSearchPresentationFocusPolicy
                .shouldRenderSearchTextFieldOnInitialPresentation(searchFocusRequestID: 1)
        )
    }

    @Test("T1136 stream popup restores composer only for displaced focus while keyboard remains visible")
    func streamPopupRestoresComposerOnlyForDisplacedFocusWhileKeyboardVisible() {
        #expect(
            StreamPopupFocusHandoff.shouldRestoreComposerOnClose(
                didDisplaceComposerFocus: true,
                isSoftwareKeyboardVisible: true
            )
        )
        #expect(
            StreamPopupFocusHandoff.shouldRestoreComposerOnClose(
                didDisplaceComposerFocus: true,
                isSoftwareKeyboardVisible: false
            ) == false
        )
        #expect(
            StreamPopupFocusHandoff.shouldRestoreComposerOnClose(
                didDisplaceComposerFocus: false,
                isSoftwareKeyboardVisible: true
            ) == false
        )
    }

    @Test("T1136 tracked popup close restores composer from presentation flag")
    func streamPopupTrackedCloseRestoresComposerFromPresentationFlag() {
        #expect(
            StreamPopupFocusHandoff.shouldRestoreComposerOnCloseAfterTrackedKeyboardState(
                didDisplaceComposerFocus: true,
                isSoftwareKeyboardVisible: true
            )
        )
        #expect(
            StreamPopupFocusHandoff.shouldRestoreComposerOnCloseAfterTrackedKeyboardState(
                didDisplaceComposerFocus: false,
                isSoftwareKeyboardVisible: true
            ) == false
        )
        #expect(
            StreamPopupFocusHandoff.shouldRestoreComposerOnCloseAfterTrackedKeyboardState(
                didDisplaceComposerFocus: true,
                isSoftwareKeyboardVisible: false
            ) == false
        )
    }

    @Test("T1146 stream switch preserves only pre-existing software keyboard state")
    func streamSwitchRestoresComposerOnlyWhenKeyboardWasAlreadyUp() {
        #expect(
            StreamSwitchKeyboardFocusPolicy.shouldRestoreComposerAfterSwitch(
                wasSoftwareKeyboardVisible: true
            )
        )
        #expect(
            StreamSwitchKeyboardFocusPolicy.shouldRestoreComposerAfterSwitch(
                wasSoftwareKeyboardVisible: false
            ) == false
        )
    }

    @Test("T1136 popup close requests composer focus after popup dismissal")
    func streamPopupCloseRequestsComposerFocusAfterDismissal() {
        #expect(
            StreamPopupFocusHandoff.closeActions(shouldRestoreComposerFocus: true) == [
                .closePopup,
                .requestComposerFocusAfterDismissal
            ]
        )
        #expect(
            StreamPopupFocusHandoff.closeActions(shouldRestoreComposerFocus: false) == [
                .closePopup
            ]
        )
    }

    @Test("T1136 dots-indicator popup close preserves composer focus during dismissal")
    func streamPopupDotsIndicatorClosePreservesComposerFocusDuringDismissal() {
        #expect(
            StreamPopupFocusHandoff.closeActions(
                shouldRestoreComposerFocus: true,
                preserveComposerFocusDuringDismissal: true
            ) == [
                .requestComposerFocusBeforeDismissal,
                .closePopup
            ]
        )
        #expect(
            StreamPopupFocusHandoff.closeActions(
                shouldRestoreComposerFocus: false,
                preserveComposerFocusDuringDismissal: true
            ) == [
                .closePopup
            ]
        )
    }

    @Test("T1136 composer focus request closes popup before focusing composer")
    func composerFocusRequestClosesOpenStreamPopup() {
        #expect(
            StreamPopupFocusHandoff.shouldClosePopupForComposerFocusRequest(isStreamPopupPresented: true)
        )
        #expect(
            StreamPopupFocusHandoff.shouldClosePopupForComposerFocusRequest(isStreamPopupPresented: false) == false
        )
    }

    @Test("T1146 stream pager does not dismiss the software keyboard")
    @MainActor
    func streamPagerDoesNotDismissSoftwareKeyboard() {
        let scrollView = UIScrollView()
        scrollView.keyboardDismissMode = .interactive

        StreamPagerKeyboardDismissPolicy.apply(to: scrollView)

        #expect(scrollView.keyboardDismissMode == .none)
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

    @Test("T1188 popup row dot identity includes materialized session")
    func popupRowDotIdentityIncludesMaterializedSession() {
        let first = StreamPopupRowStatusDotIdentity(
            sessionKey: "agent:main:clawline:user:s_initial",
            dotState: .inactive,
            isActive: false,
            colorScheme: .light
        )
        let scrolledIn = StreamPopupRowStatusDotIdentity(
            sessionKey: "agent:main:clawline:user:s_scrolled",
            dotState: .inactive,
            isActive: false,
            colorScheme: .light
        )

        #expect(first != scrolledIn)
    }

    @Test("T1188 popup row dot identity includes rendered status")
    func popupRowDotIdentityIncludesRenderedStatus() {
        let inactive = StreamPopupRowStatusDotIdentity(
            sessionKey: "agent:main:clawline:user:s_popup",
            dotState: .inactive,
            isActive: false,
            colorScheme: .light
        )
        let unread = StreamPopupRowStatusDotIdentity(
            sessionKey: "agent:main:clawline:user:s_popup",
            dotState: .unread,
            isActive: false,
            colorScheme: .light
        )
        let active = StreamPopupRowStatusDotIdentity(
            sessionKey: "agent:main:clawline:user:s_popup",
            dotState: .unread,
            isActive: true,
            colorScheme: .light
        )
        let dark = StreamPopupRowStatusDotIdentity(
            sessionKey: "agent:main:clawline:user:s_popup",
            dotState: .inactive,
            isActive: false,
            colorScheme: .dark
        )

        #expect(inactive != unread)
        #expect(unread != active)
        #expect(inactive != dark)
    }

    @Test("Offscreen unread edge bloom is blurred behind the glass")
    func offscreenUnreadEdgeBloomUsesBlur() {
        #expect(StreamPageDotsView.unreadEdgeBloomOpacity(colorScheme: .light) == 0.40)
        #expect(StreamPageDotsView.unreadEdgeBloomOpacity(colorScheme: .dark) == 0.40)
        #expect(StreamPageDotsView.unreadEdgeBloomBlurRadius(colorScheme: .light) == 4.0)
        #expect(StreamPageDotsView.unreadEdgeBloomBlurRadius(colorScheme: .dark) == 4.5)
    }

    @Test("T278: offscreen unread bloom is positioned inside the glass capsule")
    func offscreenUnreadBloomStaysInsideCapsuleAfterBlur() {
        let controlWidth = StreamPageDotsView.requiredControlWidth(
            visibleDotCount: 11,
            includesOverflowIndicators: true
        )
        let capsuleBounds = StreamPageDotsView.unreadEdgeBloomCapsuleBounds(capsuleWidth: controlWidth)
        let cases: [(HorizontalEdge, LayoutDirection)] = [
            (.leading, .leftToRight),
            (.trailing, .leftToRight),
            (.leading, .rightToLeft),
            (.trailing, .rightToLeft)
        ]

        for (edge, direction) in cases {
            let sourceFrame = StreamPageDotsView.unreadEdgeBloomSourceFrame(
                edge: edge,
                layoutDirection: direction,
                capsuleBounds: capsuleBounds
            )
            let visualBounds = StreamPageDotsView.unreadEdgeBloomVisualBounds(
                edge: edge,
                layoutDirection: direction,
                capsuleBounds: capsuleBounds,
                colorScheme: .dark
            )

            #expect(sourceFrame.minX > capsuleBounds.minX)
            #expect(sourceFrame.maxX < capsuleBounds.maxX)
            #expect(visualBounds.minX >= capsuleBounds.minX)
            #expect(visualBounds.maxX <= capsuleBounds.maxX)
            #expect(visualBounds.minY >= capsuleBounds.minY)
            #expect(visualBounds.maxY <= capsuleBounds.maxY)

            let capsuleInset = Self.capsuleHorizontalInset(at: visualBounds.minY)
            if sourceFrame.midX < capsuleBounds.midX {
                #expect(visualBounds.minX >= capsuleBounds.minX + capsuleInset)
            } else {
                #expect(visualBounds.maxX <= capsuleBounds.maxX - capsuleInset)
            }
        }
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

    private static func capsuleHorizontalInset(at y: CGFloat) -> CGFloat {
        let radius = StreamPageDotsView.controlHeight / 2
        let dy = abs(y - radius)
        return radius - sqrt(max(0, (radius * radius) - (dy * dy)))
    }

    private static func streamPageDotsSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Clawline/Views/Chat/StreamPageDotsView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceSection(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            struct MissingSourceSection: Error {}
            throw MissingSourceSection()
        }
        return String(source[start..<end])
    }
}
