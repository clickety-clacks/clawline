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

    static func softCoral(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.769, green: 0.478, blue: 0.431) : Color(red: 0.910, green: 0.659, blue: 0.612)
    }

    static func sage(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.482, green: 0.639, blue: 0.463) : Color(red: 0.561, green: 0.651, blue: 0.541)
    }

    static func warmBrown(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.831, green: 0.769, blue: 0.690) : Color(red: 0.361, green: 0.290, blue: 0.239)
    }

    static func stone(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.545, green: 0.502, blue: 0.471) : Color(red: 0.651, green: 0.608, blue: 0.553)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.910, green: 0.894, blue: 0.878) : Color(red: 0.239, green: 0.204, blue: 0.161)
    }

    // MARK: - Gradients
    static func pageBackground(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.059, green: 0.055, blue: 0.051),
                                      Color(red: 0.102, green: 0.094, blue: 0.086)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(red: 0.910, green: 0.878, blue: 0.831),
                                      Color(red: 0.831, green: 0.784, blue: 0.737)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
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
        var containerPadding: CGFloat { isCompact ? 16 : 24 }
        var bubblePaddingVertical: CGFloat { isCompact ? 14 : 16 }
        var bubblePaddingHorizontal: CGFloat { isCompact ? 16 : 20 }
        var shortFontSize: CGFloat { isCompact ? 18 : 22 }
        var mediumFontSize: CGFloat { 17 }
        var bodyFontSize: CGFloat { 15 }
        var senderFontSize: CGFloat { 12 }
        var truncationHeight: CGFloat { isCompact ? 320 : 400 }
    }

    // MARK: - Typography helpers
    static func maxLineWidth(bodyFontSize: CGFloat) -> CGFloat {
        let baseFont = UIFont.systemFont(ofSize: bodyFontSize, weight: .regular)
        let scaledFont = UIFontMetrics.default.scaledFont(for: baseFont)
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

struct MessageSizeClassKey: LayoutValueKey {
    static let defaultValue: MessageSizeClass = .medium
}
