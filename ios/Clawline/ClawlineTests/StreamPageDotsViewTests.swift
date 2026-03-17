import CoreGraphics
import Testing
@testable import Clawline

struct StreamPageDotsViewTests {
    @Test("Stream page dots preserve main visual height")
    func controlHeightMatchesMainGeometry() {
        #expect(StreamPageDotsView.controlHeight == 23)
    }

    @Test("Expanded pager hit rect reaches minimum tap target without moving center")
    func expandedPagerHitRectPreservesVisiblePosition() {
        let originalFrame = CGRect(x: 40, y: 100, width: 88, height: StreamPageDotsView.controlHeight)
        let hitRect = expandedPageDotsHitRect(frame: originalFrame)

        #expect(hitRect.height == 44)
        #expect(hitRect.midY == originalFrame.midY)
        #expect(hitRect.width == originalFrame.width)
    }

    @Test("Frozen layout fallback reuses settled composer height")
    func frozenPagerFallbackUsesSettledHeight() {
        let fallbackHeight = runtimeInsetFallbackBarHeight(
            measuredInputBarHeight: 0,
            settledInputBarHeight: 88,
            layoutFrozen: true
        )

        #expect(fallbackHeight == 88)
    }
}
