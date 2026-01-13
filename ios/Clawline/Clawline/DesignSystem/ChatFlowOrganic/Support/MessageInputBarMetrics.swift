//
//  MessageInputBarMetrics.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import CoreGraphics
import SwiftUI

struct MessageInputBarMetrics {
    let horizontalSizeClass: UserInterfaceSizeClass?
    /// Raw bottom safe area inset from GeometryReader - used to detect keyboard.
    let bottomSafeAreaInset: CGFloat
    let deviceCornerRadius: CGFloat

    let addButtonSize: CGFloat = 48
    let inputBarHeight: CGFloat = 48

    /// Threshold for detecting keyboard presence.
    /// Home indicator is ~34pt; keyboard visibility adds ~300pt to safe area.
    /// Using 40pt detects keyboard even during animation transition.
    private static let keyboardThreshold: CGFloat = 40

    /// Computed keyboard visibility - no state involved, evaluated in same layout pass.
    var isKeyboardOnScreen: Bool {
        bottomSafeAreaInset > Self.keyboardThreshold
    }

    var sendButtonSize: CGFloat {
        horizontalSizeClass == .compact ? 44 : 48
    }

    var sendButtonPadding: CGFloat {
        max((inputBarHeight - sendButtonSize) / 2, 0)
    }

    var concentricPadding: CGFloat {
        max(deviceCornerRadius - (inputBarHeight / 2), 8)
    }

    /// Spacing between elements in the input bar HStack
    static let elementSpacing: CGFloat = 8

    var bottomPadding: CGFloat {
        isKeyboardOnScreen ? Self.elementSpacing : concentricPadding
    }

}

struct MessageInputMotionState {
    let reduceMotionEnabled: Bool

    var causticsEnabled: Bool { !reduceMotionEnabled }
}
