import CoreGraphics

struct WatchShellMetrics {
    static let maxRingDiameter: CGFloat = 104
    static let shellSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let historyMinHeight: CGFloat = 64
    private static let ringScale: CGFloat = 0.42

    static func ringDiameter(for availableSize: CGSize) -> CGFloat {
        min(min(availableSize.width, availableSize.height) * ringScale, maxRingDiameter)
    }

    static func historyHeight(for availableSize: CGSize) -> CGFloat {
        max(historyMinHeight, min(availableSize.height * 0.34, 86))
    }
}
