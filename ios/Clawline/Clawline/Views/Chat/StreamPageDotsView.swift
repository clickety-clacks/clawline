//
//  StreamPageDotsView.swift
//  Clawline
//
//  Created by Codex on 2/12/26.
//

import SwiftUI

struct StreamPageDotsView: View {
    enum ActivationBehavior {
        case button
        case directTapGesture
    }

    @Environment(\.colorScheme) private var colorScheme

    let sessionKeys: [String]
    let activeSessionKey: String
    let dotStatesBySession: [String: StreamDotState]
    let maxWidth: CGFloat?
    let onTap: () -> Void
    let activationBehavior: ActivationBehavior

    private static let collapsedMaxVisibleDots = 11
    private static let dotDiameter: CGFloat = 7
    private static let overflowDotDiameter: CGFloat = 4
    private static let dotSpacing: CGFloat = 7
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8
    static let controlHeight: CGFloat = 23

    private var activeIndex: Int {
        sessionKeys.firstIndex(of: activeSessionKey) ?? 0
    }

    private var maxVisibleDots: Int {
        Self.fittingVisibleDotCount(totalSessionCount: sessionKeys.count, maxWidth: expandedWidthBudget)
    }

    private var expandedWidthBudget: CGFloat? {
        guard shouldExpandToMaxWidth else { return nil }
        return maxWidth
    }

    private var targetControlWidth: CGFloat? {
        Self.targetControlWidth(totalSessionCount: sessionKeys.count, maxWidth: expandedWidthBudget)
    }

    private var shouldExpandToMaxWidth: Bool {
        guard maxWidth != nil else { return false }
        return sessionKeys.count > Self.collapsedMaxVisibleDots
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

    private var hasHiddenUnreadLeading: Bool {
        guard let firstVisibleIndex = visibleDotIndices.first, firstVisibleIndex > 0 else {
            return false
        }
        return sessionKeys[..<firstVisibleIndex].contains { dotStatesBySession[$0] == .unread }
    }

    private var hasHiddenUnreadTrailing: Bool {
        guard let lastVisibleIndex = visibleDotIndices.last, lastVisibleIndex < sessionKeys.count - 1 else {
            return false
        }
        return sessionKeys[(lastVisibleIndex + 1)...].contains { dotStatesBySession[$0] == .unread }
    }

    private var warningBloomColor: Color {
        ChatFlowTheme.unreadIndicator(colorScheme)
    }

    static func fittingVisibleDotCount(totalSessionCount: Int, maxWidth: CGFloat?) -> Int {
        let collapsedCount = min(totalSessionCount, collapsedMaxVisibleDots)
        guard totalSessionCount > collapsedMaxVisibleDots, let maxWidth else {
            return collapsedCount
        }

        var bestCount = collapsedCount
        for candidateCount in collapsedCount...totalSessionCount {
            let requiredWidth = requiredControlWidth(
                visibleDotCount: candidateCount,
                includesOverflowIndicators: candidateCount < totalSessionCount
            )
            if requiredWidth <= maxWidth {
                bestCount = candidateCount
            } else {
                break
            }
        }
        return bestCount
    }

    static func requiredControlWidth(
        visibleDotCount: Int,
        includesOverflowIndicators: Bool
    ) -> CGFloat {
        let overflowCount = includesOverflowIndicators ? 2 : 0
        let elementCount = visibleDotCount + overflowCount
        let totalDotWidth = (CGFloat(visibleDotCount) * dotDiameter)
            + (CGFloat(overflowCount) * overflowDotDiameter)
        let totalSpacing = CGFloat(max(0, elementCount - 1)) * dotSpacing
        return totalDotWidth + totalSpacing + (horizontalPadding * 2)
    }

    static func targetControlWidth(totalSessionCount: Int, maxWidth: CGFloat?) -> CGFloat? {
        guard totalSessionCount > collapsedMaxVisibleDots, let maxWidth else { return nil }
        let collapsedWidth = requiredControlWidth(
            visibleDotCount: collapsedMaxVisibleDots,
            includesOverflowIndicators: true
        )
        let visibleDotCount = fittingVisibleDotCount(totalSessionCount: totalSessionCount, maxWidth: maxWidth)
        guard visibleDotCount > collapsedMaxVisibleDots else { return nil }
        guard maxWidth > collapsedWidth else { return nil }
        let requiredWidth = requiredControlWidth(
            visibleDotCount: visibleDotCount,
            includesOverflowIndicators: visibleDotCount < totalSessionCount
        )
        return min(maxWidth, requiredWidth)
    }

    var body: some View {
        interactiveBody
        .accessibilityLabel("Manage streams")
        .accessibilityValue("Stream \(activeIndex + 1) of \(sessionKeys.count)")
        .accessibilityHint("Opens stream manager")
    }

    @ViewBuilder
    private var interactiveBody: some View {
        switch activationBehavior {
        case .button:
            Button(action: onTap) {
                controlBody
            }
            .buttonStyle(.plain)
        case .directTapGesture:
            controlBody
                .contentShape(Capsule())
                .onTapGesture(perform: onTap)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text("Open stream manager"), onTap)
        }
    }

    private var controlBody: some View {
        HStack(spacing: 7) {
            if showsLeadingOverflow {
                Circle()
                    .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                    .frame(width: 4, height: 4)
            }
            ForEach(visibleDotIndices, id: \.self) { index in
                let sessionKey = sessionKeys[index]
                let isActive = index == activeIndex
                let dotState = dotStatesBySession[sessionKey] ?? .inactive
                Circle()
                    .fill(
                        StreamDotColor.resolve(
                            isActive: isActive,
                            dotState: dotState,
                            colorScheme: colorScheme
                        )
                    )
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                        radius: isActive ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
                    )
                    .shadow(
                        color: isActive ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                        radius: isActive ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
                    )
            }
            if showsTrailingOverflow {
                Circle()
                    .fill(StreamDotColor.inactive(colorScheme: colorScheme))
                    .frame(width: 4, height: 4)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: targetControlWidth)
#if !os(visionOS)
        .glassEffect(.regular.interactive(), in: Capsule())
#else
        .background(.regularMaterial, in: Capsule())
#endif
        .overlay {
            unreadEdgeBloomOverlay
                .mask(Capsule())
                .allowsHitTesting(false)
        }
#if os(visionOS)
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        }
#endif
        }

    private var unreadEdgeBloomOverlay: some View {
        ZStack {
            if hasHiddenUnreadLeading {
                edgeWarningBloom(edge: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasHiddenUnreadTrailing {
                edgeWarningBloom(edge: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func edgeWarningBloom(edge: HorizontalEdge) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            warningBloomColor.opacity(colorScheme == .dark ? 0.26 : 0.20),
                            warningBloomColor.opacity(colorScheme == .dark ? 0.14 : 0.10),
                            .clear
                        ],
                        startPoint: edge == .leading ? .leading : .trailing,
                        endPoint: edge == .leading ? .trailing : .leading
                    )
                )
                .frame(width: 24, height: 18)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            warningBloomColor.opacity(colorScheme == .dark ? 0.36 : 0.28),
                            warningBloomColor.opacity(colorScheme == .dark ? 0.10 : 0.08),
                            .clear
                        ],
                        startPoint: edge == .leading ? .leading : .trailing,
                        endPoint: edge == .leading ? .trailing : .leading
                    )
                )
                .frame(width: 34, height: 24)
                .blur(radius: colorScheme == .dark ? 4 : 5)
        }
        .frame(width: 28, height: 24)
        .offset(x: edge == .leading ? -5 : 5)
    }
}
