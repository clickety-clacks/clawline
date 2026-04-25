//
//  StreamDotColor.swift
//  Clawline
//
//  Created by Codex on 2/21/26.
//

import SwiftUI

enum StreamDotColor {
    enum Kind: Equatable {
        case unread
        case active
        case userTail
        case inactive
    }

    private static let avatarGreen = Color(red: 0.42, green: 0.61, blue: 0.42)
    private static let avatarGreenHighlight = Color(red: 0.48, green: 0.68, blue: 0.48)

    static func inactive(colorScheme: ColorScheme) -> Color {
        ChatFlowTheme.stone(colorScheme).opacity(colorScheme == .dark ? 0.46 : 0.34)
    }

    static func userTail(colorScheme: ColorScheme) -> Color {
        ChatFlowTheme.connectionReconnecting(colorScheme)
    }

    static func kind(
        isActive: Bool,
        dotState: StreamDotState
    ) -> Kind {
        if isActive {
            return .active
        }
        if dotState == .unread {
            return .unread
        }
        if dotState == .userTail {
            return .userTail
        }
        return .inactive
    }

    static func resolve(
        isActive: Bool,
        dotState: StreamDotState,
        colorScheme: ColorScheme
    ) -> Color {
        switch kind(isActive: isActive, dotState: dotState) {
        case .unread:
            return ChatFlowTheme.unreadIndicator(colorScheme)
        case .active:
            return avatarGreenHighlight
        case .userTail:
            return userTail(colorScheme: colorScheme)
        case .inactive:
            return inactive(colorScheme: colorScheme)
        }
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
