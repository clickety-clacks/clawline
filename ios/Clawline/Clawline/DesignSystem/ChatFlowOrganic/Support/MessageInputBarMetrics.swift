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
    /// Raw bottom safe area inset from GeometryReader.
    let bottomSafeAreaInset: CGFloat
    let deviceCornerRadius: CGFloat
    /// Focus state from @FocusState - fires BEFORE keyboard animation.
    /// Used as leading indicator for keyboard presence.
    let isFieldFocused: Bool

    let addButtonSize: CGFloat = 48
    let inputBarHeight: CGFloat = 48

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

    /// 8pt gap is ALWAYS present in layout.
    /// This ensures the gap is visible from the first frame when keyboard appears.
    var bottomPadding: CGFloat {
        Self.elementSpacing  // Always 8pt
    }

    /// Concentric offset using focus as leading indicator.
    /// @FocusState updates BEFORE body renders - use it directly, not via onChange/@State mirror.
    var concentricOffset: CGFloat {
        // Focus state is the LEADING indicator - fires before keyboard animation
        if isFieldFocused { return 0 }

        // Geometry-based smooth return when keyboard dismisses
        let minSafeArea: CGFloat = 34
        let maxSafeArea: CGFloat = 100
        let maxOffset = max(minSafeArea - concentricPadding + Self.elementSpacing, 0)
        let t = (bottomSafeAreaInset - minSafeArea) / (maxSafeArea - minSafeArea)
        let clampedT = max(0, min(1, t))
        return maxOffset * (1 - clampedT)
    }

}


struct MessageInputMotionState {
    let reduceMotionEnabled: Bool

    var causticsEnabled: Bool { !reduceMotionEnabled }
}
