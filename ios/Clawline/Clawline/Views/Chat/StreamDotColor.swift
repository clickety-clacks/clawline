//
//  StreamDotColor.swift
//  Clawline
//
//  Created by Codex on 2/21/26.
//

import SwiftUI

enum StreamDotColor {
    private static let avatarGreen = Color(red: 0.42, green: 0.61, blue: 0.42)

    static func inactive(colorScheme: ColorScheme) -> Color {
        ChatFlowTheme.stone(colorScheme).opacity(colorScheme == .dark ? 0.46 : 0.34)
    }

    static func resolve(
        isActive: Bool,
        hasUnread: Bool,
        colorScheme: ColorScheme
    ) -> Color {
        if hasUnread {
            return ChatFlowTheme.unreadIndicator(colorScheme)
        }
        if isActive {
            return avatarGreen
        }
        return inactive(colorScheme: colorScheme)
    }

    static func activeGlow(colorScheme: ColorScheme) -> Color {
        avatarGreen.opacity(colorScheme == .dark ? 0.94 : 0.86)
    }

    static func activeOuterGlowRadius(colorScheme: ColorScheme) -> CGFloat {
        colorScheme == .dark ? 16 : 20
    }

    static func activeInnerGlowRadius(colorScheme: ColorScheme) -> CGFloat {
        colorScheme == .dark ? 6 : 8
    }
}
