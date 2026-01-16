//
//  NSAttributedString+PendingAttachments.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import UIKit

extension NSAttributedString {
    private static let attachmentReplacement = String(UnicodeScalar(NSTextAttachment.character) ?? "\u{FFFC}")

    func contentForSending() -> (text: String, attachmentIds: [UUID]) {
        (
            textForSending().trimmingCharacters(in: .whitespacesAndNewlines),
            pendingAttachmentIds()
        )
    }

    func pendingAttachmentIds() -> [UUID] {
        var ids: [UUID] = []
        let range = NSRange(location: 0, length: length)
        enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let attachment = value as? PendingTextAttachment else { return }
            ids.append(attachment.pendingId)
        }
        return ids
    }

    func textForSending() -> String {
        string.replacingOccurrences(of: Self.attachmentReplacement, with: " ")
    }

    var isEffectivelyEmpty: Bool {
        textForSending().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachmentIds().isEmpty
    }
}

extension NSMutableAttributedString {
    func removePendingAttachment(with id: UUID) {
        let fullRange = NSRange(location: 0, length: length)
        enumerateAttribute(.attachment, in: fullRange, options: .reverse) { value, range, stop in
            guard let attachment = value as? PendingTextAttachment else { return }
            if attachment.pendingId == id {
                deleteCharacters(in: range)
                stop.pointee = true
            }
        }
    }
}
