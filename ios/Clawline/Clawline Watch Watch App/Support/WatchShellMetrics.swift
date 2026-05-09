import CoreGraphics

struct WatchShellMetrics {
    static let maxRingDiameter: CGFloat = 145
    static let shellSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 8
    static let historyMinHeight: CGFloat = 72
    private static let ringScale: CGFloat = 0.65

    static func ringDiameter(for availableSize: CGSize) -> CGFloat {
        min(min(availableSize.width, availableSize.height) * ringScale, maxRingDiameter)
    }

    static func historyHeight(for availableSize: CGSize) -> CGFloat {
        max(historyMinHeight, min(availableSize.height * 0.42, 124))
    }
}
