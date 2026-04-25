import Testing
import UIKit
@testable import Clawline

@MainActor
struct KeyboardPinnedHitTestingTests {
    @Test("Pinned-container hit testing honors custom hit regions instead of raw frames")
    func expandedHitRegionCountsAsInteractive() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let candidate = ExpandedHitRegionView(frame: CGRect(x: 100, y: 100, width: 24, height: 24))
        container.addSubview(candidate)

        let pointOutsideFrameButInsideExpandedRegion = CGPoint(x: 92, y: 92)

        #expect(candidate.frame.contains(pointOutsideFrameButInsideExpandedRegion) == false)
        #expect(
            KeyboardPinnedHitTesting.contains(
                pointOutsideFrameButInsideExpandedRegion,
                in: candidate,
                from: container,
                event: nil
            )
        )
    }

    @Test("Pinned-container hit testing ignores non-interactive candidates")
    func nonInteractiveCandidatesDoNotCaptureTouches() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let candidate = ExpandedHitRegionView(frame: CGRect(x: 100, y: 100, width: 24, height: 24))
        candidate.isUserInteractionEnabled = false
        container.addSubview(candidate)

        #expect(
            KeyboardPinnedHitTesting.contains(
                CGPoint(x: 100, y: 100),
                in: candidate,
                from: container,
                event: nil
            ) == false
        )
    }
}

private final class ExpandedHitRegionView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -12, dy: -12).contains(point)
    }
}
