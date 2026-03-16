//
//  ChatFlowTheme.swift
//  Clawline
//
//  Created by Codex on 1/11/26.
//

import SwiftUI
import UIKit

enum ChatFlowTheme {
    // MARK: - Palette
    static func cream(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.110, green: 0.098, blue: 0.090) : Color(red: 0.969, green: 0.953, blue: 0.922)
    }

    static func terracotta(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.878, green: 0.478, blue: 0.373) : Color(red: 0.769, green: 0.471, blue: 0.361)
    }

    static func unreadIndicator(_ scheme: ColorScheme) -> Color {
        terracotta(scheme)
    }

    static func softCoral(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.769, green: 0.478, blue: 0.431) : Color(red: 0.910, green: 0.659, blue: 0.612)
    }

    static func sage(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.482, green: 0.639, blue: 0.463) : Color(red: 0.561, green: 0.651, blue: 0.541)
    }

    static func connectionReconnecting(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.92, green: 0.76, blue: 0.30) : Color(red: 0.89, green: 0.67, blue: 0.08)
    }

    static func connectionDisconnected(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.88, green: 0.30, blue: 0.30) : Color(red: 0.78, green: 0.19, blue: 0.17)
    }

    static var sageAdaptive: Color {
        Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 0.482, green: 0.639, blue: 0.463, alpha: 1)
            }
            return UIColor(red: 0.561, green: 0.651, blue: 0.541, alpha: 1)
        })
    }

    static func warmBrown(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.831, green: 0.769, blue: 0.690) : Color(red: 0.361, green: 0.290, blue: 0.239)
    }

    static func adminAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.549, green: 0.756, blue: 0.996)
            : Color(red: 0.141, green: 0.420, blue: 0.831)
    }

    static func stone(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.545, green: 0.502, blue: 0.471) : Color(red: 0.651, green: 0.608, blue: 0.553)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.910, green: 0.894, blue: 0.878) : Color(red: 0.239, green: 0.204, blue: 0.161)
    }

    // MARK: - Gradients
    static func pageBackground(_ scheme: ColorScheme) -> LinearGradient {
        // --bg-surface-gradient from design system: #1C1917 to #141210
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.110, green: 0.098, blue: 0.090),  // #1C1917
                                      Color(red: 0.078, green: 0.071, blue: 0.063)], // #141210
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.941, green: 0.918, blue: 0.878),  // #F0EAE0
                                      Color(red: 0.910, green: 0.878, blue: 0.831)], // #E8E0D4
                             startPoint: .top, endPoint: .bottom)
    }

    static func surfaceGradient(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.110, green: 0.098, blue: 0.090),
                                      Color(red: 0.078, green: 0.071, blue: 0.063)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.941, green: 0.918, blue: 0.878),
                                      Color(red: 0.910, green: 0.878, blue: 0.831)],
                             startPoint: .top, endPoint: .bottom)
    }

    static func bubbleSelfGradient(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.176, green: 0.231, blue: 0.165),
                                      Color(red: 0.141, green: 0.200, blue: 0.133)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(red: 0.722, green: 0.808, blue: 0.686),
                                      Color(red: 0.784, green: 0.851, blue: 0.753)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func bubbleOtherGradient(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.161, green: 0.145, blue: 0.141),
                                      Color(red: 0.161, green: 0.145, blue: 0.141)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 1.0, green: 0.992, blue: 0.976),
                                      Color(red: 0.992, green: 0.965, blue: 0.933)],
                             startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Metrics
    struct Metrics {
        let isCompact: Bool

        var flowGap: CGFloat { isCompact ? 12 : 16 }
        var containerPadding: CGFloat { isCompact ? 12 : 24 }
        var inputBarPaddingHorizontal: CGFloat { isCompact ? 24 : 24 }
        var bubblePaddingVertical: CGFloat { isCompact ? 14 : 16 }
        var bubblePaddingHorizontal: CGFloat { isCompact ? 12 : 20 }
        var shortFontSize: CGFloat { UIFont.clawline(.shortMessage).pointSize }
        var mediumFontSize: CGFloat { UIFont.clawline(.mediumMessage).pointSize }
        var bodyFontSize: CGFloat { UIFont.clawline(.bodyText).pointSize }
        var senderFontSize: CGFloat { UIFont.clawline(.senderName).pointSize }
        var truncationHeight: CGFloat { isCompact ? 320 : 400 }
    }

    // MARK: - Typography helpers
    static func maxLineWidth(bodyFontSize _: CGFloat = 0) -> CGFloat {
        let scaledFont = UIFont.clawline(.bodyText)
        let sample = String(repeating: "n", count: 65)
        let size = (sample as NSString).size(withAttributes: [.font: scaledFont])
        return ceil(size.width)
    }
}

enum MessageSizeClass: String {
    case short
    case medium
    case long
}

nonisolated struct MessageSizeClassKey: LayoutValueKey {
    static let defaultValue: MessageSizeClass = .medium
}
