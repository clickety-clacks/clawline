//
//  ClawlineTypography.swift
//  Clawline
//

import SwiftUI
import UIKit

enum ClawlineTextRole {
    case shortMessage
    case mediumMessage
    case bodyText
    case uiLabel
    case secondaryLabel
    case senderName
    case timestamp
    case sectionHeader
    case subsectionHeader

    fileprivate var swiftUITextStyle: Font.TextStyle {
        switch self {
        case .shortMessage:
            return .title3
        case .mediumMessage, .bodyText:
            return .body
        case .uiLabel:
            return .subheadline
        case .secondaryLabel:
            return .footnote
        case .senderName:
            return .caption
        case .timestamp:
            return .caption2
        case .sectionHeader:
            return .title
        case .subsectionHeader:
            return .title2
        }
    }

    fileprivate var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .shortMessage:
            return .title3
        case .mediumMessage, .bodyText:
            return .body
        case .uiLabel:
            return .subheadline
        case .secondaryLabel:
            return .footnote
        case .senderName:
            return .caption1
        case .timestamp:
            return .caption2
        case .sectionHeader:
            return .title1
        case .subsectionHeader:
            return .title2
        }
    }

    fileprivate var fontWeight: Font.Weight? {
        switch self {
        case .shortMessage:
            return .semibold
        case .mediumMessage:
            return .medium
        case .senderName:
            return .semibold
        case .sectionHeader:
            return .bold
        case .subsectionHeader:
            return .semibold
        case .bodyText, .uiLabel, .secondaryLabel, .timestamp:
            return nil
        }
    }

    fileprivate var uiWeight: UIFont.Weight? {
        switch self {
        case .shortMessage:
            return .semibold
        case .mediumMessage:
            return .medium
        case .senderName:
            return .semibold
        case .sectionHeader:
            return .bold
        case .subsectionHeader:
            return .semibold
        case .bodyText, .uiLabel, .secondaryLabel, .timestamp:
            return nil
        }
    }
}

extension Font {
    static func clawline(_ role: ClawlineTextRole, design: Font.Design = .default) -> Font {
        var font = Font.system(role.swiftUITextStyle, design: design)
        if let weight = role.fontWeight {
            font = font.weight(weight)
        }
        return font
    }

    static func clawline(
        _ role: ClawlineTextRole,
        weight: Font.Weight,
        design: Font.Design = .default
    ) -> Font {
        Font.system(role.swiftUITextStyle, design: design).weight(weight)
    }
}

extension UIFont {
    static func clawline(
        _ role: ClawlineTextRole,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        makePreferred(
            textStyle: role.uiTextStyle,
            weight: role.uiWeight,
            design: nil,
            traitCollection: traitCollection
        )
    }

    static func clawline(
        _ role: ClawlineTextRole,
        weight: UIFont.Weight,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        makePreferred(
            textStyle: role.uiTextStyle,
            weight: weight,
            design: nil,
            traitCollection: traitCollection
        )
    }

    static func clawlineMonospaced(
        _ role: ClawlineTextRole,
        weight: UIFont.Weight? = nil,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        makePreferred(
            textStyle: role.uiTextStyle,
            weight: weight ?? role.uiWeight,
            design: .monospaced,
            traitCollection: traitCollection
        )
    }

    private static func makePreferred(
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight?,
        design: UIFontDescriptor.SystemDesign?,
        traitCollection: UITraitCollection?
    ) -> UIFont {
        let preferredDescriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: textStyle,
            compatibleWith: traitCollection
        )
        var descriptor = preferredDescriptor
        if let design {
            descriptor = descriptor.withDesign(design) ?? descriptor
        }
        if let weight {
            descriptor = descriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight]
            ])
        }
        let baseFont = UIFont(descriptor: descriptor, size: preferredDescriptor.pointSize)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: baseFont, compatibleWith: traitCollection)
    }
}
