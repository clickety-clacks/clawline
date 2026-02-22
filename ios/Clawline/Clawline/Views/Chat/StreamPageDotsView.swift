//
//  StreamPageDotsView.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamPageDotsView: View {
    @Environment(\.colorScheme) private var colorScheme

    let sessionKeys: [String]
    let activeSessionKey: String
    let unreadSessionKeys: Set<String>
    let onTap: () -> Void

    private let maxVisibleDots = 11
    static let controlHeight: CGFloat = 23

    private var activeIndex: Int {
        sessionKeys.firstIndex(of: activeSessionKey) ?? 0
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
        Button(action: onTap) {
            HStack(spacing: 7) {
                if showsLeadingOverflow {
                    Circle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 4, height: 4)
                }
                ForEach(visibleDotIndices, id: \.self) { index in
                    let sessionKey = sessionKeys[index]
                    let isActive = index == activeIndex
                    let hasUnread = unreadSessionKeys.contains(sessionKey)
                    Circle()
                        .fill(
                            StreamDotColor.resolve(
                                isActive: isActive,
                                hasUnread: hasUnread,
                                colorScheme: colorScheme
                            )
                        )
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
#if !os(visionOS)
            .glassEffect(.regular, in: Capsule())
#endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage streams")
        .accessibilityValue("Stream \(activeIndex + 1) of \(sessionKeys.count)")
        .accessibilityHint("Opens stream manager")
    }
}
