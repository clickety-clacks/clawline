import CoreGraphics
import Testing
@testable import Clawline

struct MessageFlowCollectionFrameResizeTests {
    @Test("Width-only resize updates collection frame")
    func widthOnlyResizeUpdatesCollectionFrame() {
        let current = CGRect(x: 0, y: -64, width: 800, height: 900)
        let target = CGRect(x: 0, y: -64, width: 1100, height: 900)

        let shouldUpdate = MessageFlowCollectionViewController.shouldUpdateCollectionFrame(
            current: current,
            target: target
        )

        #expect(shouldUpdate == true)
    }

    @Test("Sub-point jitter does not update collection frame")
    func subPointJitterDoesNotUpdateCollectionFrame() {
        let current = CGRect(x: 0, y: -64, width: 800, height: 900)
        let target = CGRect(x: 0.25, y: -64.25, width: 800.25, height: 900.25)

        let shouldUpdate = MessageFlowCollectionViewController.shouldUpdateCollectionFrame(
            current: current,
            target: target
        )

        #expect(shouldUpdate == false)
    }
}
