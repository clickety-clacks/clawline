//
//  ChannelSwitcherView.swift
//  Clawline
//
//  Created by Codex on 1/16/26.
//

import SwiftUI
import UIKit

struct ChannelSwitcherView: View {
    let activeChannel: ChatChannelType
    let onSelect: (ChatChannelType) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 12) {
            switchButton(for: .personal)
            switchButton(for: .admin)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 12)
        .onAppear { feedbackGenerator.prepare() }
    }

    private func switchButton(for channel: ChatChannelType) -> some View {
        let isSelected = channel == activeChannel
        let accent = accentColor(for: channel)

        return Button {
            guard channel != activeChannel else { return }
            feedbackGenerator.impactOccurred()
            onSelect(channel)
        } label: {
            Text(channel.displayName)
                .font(.system(size: 15, weight: .semibold))
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(accent.opacity(isSelected ? 0.3 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(accent.opacity(isSelected ? 0.9 : 0.3), lineWidth: isSelected ? 2 : 1)
                )
                .foregroundColor(accent)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeChannel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(channel.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func accentColor(for channel: ChatChannelType) -> Color {
        switch channel {
        case .personal:
            return ChatFlowTheme.terracotta(colorScheme)
        case .admin:
            return ChatFlowTheme.adminAccent(colorScheme)
        }
    }
}
