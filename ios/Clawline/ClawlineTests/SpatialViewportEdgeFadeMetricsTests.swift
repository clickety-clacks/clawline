//
//  SpatialViewportEdgeFadeMetricsTests.swift
//  ClawlineTests
//

import CoreGraphics
import Testing
@testable import Clawline

struct SpatialViewportEdgeFadeMetricsTests {
    @Test("T345 side fade width follows the resolved chat gutter")
    func sideFadeWidthFollowsResolvedChatGutter() {
        let regularMetrics = ChatFlowTheme.Metrics(isCompact: false)
        let compactMetrics = ChatFlowTheme.Metrics(isCompact: true)

        #expect(
            SpatialViewportEdgeFadeMetrics.distances(
                viewportSize: CGSize(width: 900, height: 700),
                horizontalGutter: regularMetrics.containerPadding
            ).horizontal == regularMetrics.containerPadding
        )
        #expect(
            SpatialViewportEdgeFadeMetrics.distances(
                viewportSize: CGSize(width: 900, height: 700),
                horizontalGutter: compactMetrics.containerPadding
            ).horizontal == compactMetrics.containerPadding
        )
    }

    @Test("T345 bounceback retunes vertical fade distances")
    func bouncebackRetunesVerticalFadeDistances() {
        let distances = SpatialViewportEdgeFadeMetrics.distances(
            viewportSize: CGSize(width: 900, height: 700),
            horizontalGutter: 24
        )

        #expect(distances.top < CGFloat(88))
        #expect(distances.bottom > CGFloat(120))
        #expect(distances.top == SpatialViewportEdgeFadeMetrics.topDistance)
        #expect(distances.bottom == SpatialViewportEdgeFadeMetrics.bottomDistance)
    }

    @Test("T345 fade distances are capped to half the viewport")
    func fadeDistancesCapToHalfViewport() {
        let distances = SpatialViewportEdgeFadeMetrics.distances(
            viewportSize: CGSize(width: 40, height: 100),
            horizontalGutter: 24
        )

        #expect(distances.top == CGFloat(50))
        #expect(distances.bottom == CGFloat(50))
        #expect(distances.horizontal == CGFloat(20))
    }
}
