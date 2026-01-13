//
//  MessageFlowRules.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import CoreGraphics
import Foundation

enum MessageFlowRules {
    static func sizeClass(for presentation: MessagePresentation) -> MessageSizeClass {
        if presentation.hasMediaOnly {
            return .long
        }
        if presentation.wordCount <= 3 {
            return .short
        }
        if presentation.wordCount <= 20 && !presentation.hasMediaOnly {
            return .medium
        }
        return .long
    }

    static func shouldTruncate(hasTextualParts: Bool,
                               sizeClass: MessageSizeClass,
                               isExpanded: Bool,
                               measuredHeight: CGFloat,
                               metrics: ChatFlowTheme.Metrics) -> Bool {
        guard hasTextualParts else { return false }
        guard sizeClass == .long else { return false }
        guard measuredHeight > metrics.truncationHeight else { return false }
        return !isExpanded
    }

    static func shouldShowTruncationControl(hasTextualParts: Bool,
                                            sizeClass: MessageSizeClass,
                                            measuredHeight: CGFloat,
                                            metrics: ChatFlowTheme.Metrics) -> Bool {
        guard hasTextualParts else { return false }
        guard sizeClass == .long else { return false }
        return measuredHeight > metrics.truncationHeight
    }

    static let streamingPromotionDelay: Duration = .milliseconds(280)

    static func promotedSizeClass(current: MessageSizeClass, next: MessageSizeClass) -> MessageSizeClass {
        switch (current, next) {
        case (.long, _), (_, .long):
            return .long
        case (.medium, _), (_, .medium):
            return .medium
        default:
            return .short
        }
    }
}

extension MessagePresentation {
    func inferredSizeClass() -> MessageSizeClass {
        MessageFlowRules.sizeClass(for: self)
    }
}
