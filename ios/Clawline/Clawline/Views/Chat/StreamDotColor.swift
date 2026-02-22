//
//  StreamDotColor.swift
//  Clawline
//
//  Created by Codex on 2/21/26.
//

import SwiftUI

enum StreamDotColor {
    static func resolve(
        isActive: Bool,
        hasUnread: Bool,
        colorScheme: ColorScheme
    ) -> Color {
        if hasUnread {
            return ChatFlowTheme.connectionDisconnected(colorScheme)
        }
        if isActive {
            return ChatFlowTheme.sage(colorScheme)
        }
        return ChatFlowTheme.stone(colorScheme)
    }
}
