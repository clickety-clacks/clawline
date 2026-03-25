import Foundation
import CoreGraphics

enum WatchGestureArbitration {
    static let swipePreemptionDistance: CGFloat = 10
    static let holdDelay: TimeInterval = 0.2

    static func shouldPreemptHold(translation: CGSize) -> Bool {
        abs(translation.width) >= swipePreemptionDistance &&
        abs(translation.width) > abs(translation.height)
    }

    static func swipeDelta(for translation: CGSize) -> Int? {
        guard shouldPreemptHold(translation: translation) else { return nil }
        return translation.width < 0 ? 1 : -1
    }
}
