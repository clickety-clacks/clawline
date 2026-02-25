//
//  ScrollToBottomButton.swift
//  Clawline
//
//  Created by Codex on 2/8/26.
//

import SwiftUI

struct ScrollToBottomButton: View {
    let isVisible: Bool
    let unreadCount: Int
    let bounceToken: Int
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @State private var bounceTask: Task<Void, Never>?
    @State private var bounceScale: CGFloat = 1

    private var resolvedScheme: ColorScheme {
#if os(visionOS)
        return settings.appearanceMode == .light ? .light : .dark
#else
        return colorScheme
#endif
    }

    private var visionOSBorderColor: Color {
        Color.white.opacity(0.9)
    }

    private var badgeText: String {
        if unreadCount > 99 { return "99+" }
        return String(unreadCount)
    }

    private var badgeBackground: Color {
        ChatFlowTheme.terracotta(resolvedScheme)
    }

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "chevron.down")
                .font(.clawline(.uiLabel).weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
#if os(visionOS)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(visionOSBorderColor, lineWidth: 1))
#else
        .glassEffect(.regular.interactive(), in: Circle())
#endif
        .overlay(alignment: .topTrailing) {
            if unreadCount > 0 {
                Text(badgeText)
                    .font(.clawline(.senderName))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, unreadCount > 9 ? 7 : 6)
                    .padding(.vertical, 3)
                    .background(badgeBackground, in: Capsule())
                    .overlay(Capsule().stroke(ChatFlowTheme.ink(resolvedScheme).opacity(0.15), lineWidth: 1))
                    .offset(x: 6, y: -6)
                    .zIndex(2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .scaleEffect(bounceScale)
        .shadow(color: Color.black.opacity(resolvedScheme == .dark ? 0.35 : 0.18), radius: 6, y: 2)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .allowsHitTesting(isVisible)
        .accessibilityIdentifier("scroll_to_bottom_button")
        .accessibilityLabel(unreadCount > 0 ? "Scroll to first unread message" : "Scroll to bottom")
        .accessibilityValue(unreadCount > 0 ? "\(unreadCount) unread" : "")
        .onChange(of: bounceToken) { _, _ in
            guard isVisible else { return }
            bounceTask?.cancel()
            bounceTask = Task { @MainActor in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
                    bounceScale = 1.12
                }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    bounceScale = 1
                }
            }
        }
        .onDisappear {
            bounceTask?.cancel()
            bounceTask = nil
        }
    }
}
