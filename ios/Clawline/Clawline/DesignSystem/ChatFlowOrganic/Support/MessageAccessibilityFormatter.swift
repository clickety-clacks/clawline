//
//  MessageAccessibilityFormatter.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

enum MessageAccessibilityFormatter {
    static func label(for message: Message, presentation: MessagePresentation) -> String {
        var parts: [String] = []
        parts.append(message.role == .user ? "You" : "Assistant")

        if presentation.isEmojiOnly {
            parts.append("emoji only message")
        } else if presentation.hasMediaOnly {
            parts.append(mediaDescription(from: presentation))
        } else if presentation.hasTextualContent {
            parts.append(textDescription(from: presentation))
        }

        let mediaDescriptionString = mediaDescription(from: presentation)
        if !mediaDescriptionString.isEmpty && !presentation.hasMediaOnly {
            parts.append(mediaDescriptionString)
        }

        return parts.joined(separator: ", ")
    }

    private static func textDescription(from presentation: MessagePresentation) -> String {
        if presentation.parts.contains(where: { part in
            if case .code = part { return true }
            if case .markdown = part { return true }
            return false
        }) {
            return "text with formatting"
        }
        if presentation.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }) {
            return "text with link preview"
        }
        return "text message"
    }

    private static func mediaDescription(from presentation: MessagePresentation) -> String {
        var imageCount = 0
        for part in presentation.parts {
            switch part {
            case .image:
                imageCount += 1
            case .gallery(let attachments):
                imageCount += attachments.count
            default:
                break
            }
        }

        guard imageCount > 0 else { return "" }
        if imageCount == 1 {
            return "one image attachment"
        }
        return "\(imageCount) image attachments"
    }
}
