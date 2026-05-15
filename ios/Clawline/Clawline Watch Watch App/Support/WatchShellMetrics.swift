import CoreGraphics

struct WatchShellMetrics {
    static let maxRingDiameter: CGFloat = 145
    static let shellSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 8
    static let controlBottomBreathingRoom: CGFloat = 8
    static let pageOverscan: CGFloat = 48
    static let historyEntriesPerPage = 3
    private static let ringScale: CGFloat = 0.65

    static func ringDiameter(for availableSize: CGSize) -> CGFloat {
        min(min(availableSize.width, availableSize.height) * ringScale, maxRingDiameter)
    }
}
