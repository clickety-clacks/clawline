import CoreGraphics

struct WatchShellMetrics {
    static let maxRingDiameter: CGFloat = 145
    private static let ringScale: CGFloat = 0.65

    static func ringDiameter(for availableSize: CGSize) -> CGFloat {
        min(min(availableSize.width, availableSize.height) * ringScale, maxRingDiameter)
    }
}
