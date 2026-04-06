import SwiftUI

struct WatchStreamDotsView: View {
    let sessionKeys: [String]
    let activeSessionKey: String?
    let dotStatesBySession: [String: StreamDotState]

    private let maxVisibleDots = 11

    private var activeIndex: Int {
        guard let activeSessionKey,
              let index = sessionKeys.firstIndex(of: activeSessionKey) else {
            return 0
        }
        return index
    }

    private var visibleDotIndices: [Int] {
        guard sessionKeys.count > maxVisibleDots else {
            return Array(sessionKeys.indices)
        }
        let halfWindow = maxVisibleDots / 2
        let maxStart = sessionKeys.count - maxVisibleDots
        let start = min(max(0, activeIndex - halfWindow), maxStart)
        return Array(start..<(start + maxVisibleDots))
    }

    private var showsLeadingOverflow: Bool {
        (visibleDotIndices.first ?? 0) > 0
    }

    private var showsTrailingOverflow: Bool {
        (visibleDotIndices.last ?? -1) < sessionKeys.count - 1
    }

    var body: some View {
        HStack(spacing: 7) {
            if showsLeadingOverflow {
                Circle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 4, height: 4)
            }

            ForEach(visibleDotIndices, id: \.self) { index in
                let key = sessionKeys[index]
                let isActive = index == activeIndex
                let dotState = dotStatesBySession[key] ?? .inactive

                Circle()
                    .fill(dotColor(isActive: isActive, dotState: dotState))
                    .frame(width: 7, height: 7)
            }

            if showsTrailingOverflow {
                Circle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func dotColor(isActive: Bool, dotState: StreamDotState) -> Color {
        if dotState == .unread {
            return .primary.opacity(0.75)
        }
        if isActive {
            return .primary
        }
        switch dotState {
        case .userTail:
            return .yellow
        case .inactive:
            return .primary.opacity(0.35)
        case .unread:
            return .primary.opacity(0.75)
        }
    }
}
