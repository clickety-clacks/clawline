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
        if presentation.hasBlockContent || presentation.hasMultipleTextBlocks {
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

    var hasBlockContent: Bool {
        parts.contains { part in
            switch part {
            case .code, .table, .linkPreview, .remoteImage, .image, .gallery, .file, .terminalSession, .interactiveHTML:
                return true
            case .text, .markdown, .inlineEmoji:
                return false
            }
        }
    }

    var hasMultipleTextBlocks: Bool {
        let textBlocks = parts.filter { $0.isTextual }
        return textBlocks.count > 1
    }
}
