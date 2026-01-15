//
//  MessagePresentation.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

struct MessagePresentation: Equatable {
    let parts: [MessagePart]
    let wordCount: Int
    let hasTextualContent: Bool
    let isEmojiOnly: Bool
    let hasMediaOnly: Bool
}

enum MessagePart: Equatable {
    case text(String)
    case markdown(String)
    case code(language: String?, code: String)
    case linkPreview(URL)
    case image(Attachment)
    case gallery([Attachment])
    case inlineEmoji(String)
}

extension MessagePart {
    var isTextual: Bool {
        switch self {
        case .text, .markdown, .inlineEmoji, .code:
            return true
        case .linkPreview, .image, .gallery:
            return false
        }
    }
}

enum MessagePresentationBuilder {
    static func build(from message: Message) -> MessagePresentation {
        let segments = Segmenter.split(message.content)
        var parts: [MessagePart] = []
        var collectedPlainText: [String] = []
        var hasTextual = false
        var emojiOnly = true

        for segment in segments {
            switch segment.kind {
            case .code(let language):
                parts.append(.code(language: language, code: segment.content))
                emojiOnly = false
            case .text:
                let trimmed = segment.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                collectedPlainText.append(trimmed)

                if isEmojiOnly(trimmed) {
                    parts.append(.inlineEmoji(trimmed))
                    emojiOnly = true
                    hasTextual = true
                    continue
                }

                let lines = segment.content.components(separatedBy: CharacterSet.newlines)
                for line in lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmedLine.isEmpty else { continue }
                    if let url = exactURL(from: trimmedLine) {
                        parts.append(.linkPreview(url))
                        emojiOnly = false
                    } else if looksLikeMarkdown(trimmedLine) {
                        parts.append(.markdown(trimmedLine))
                        hasTextual = true
                        emojiOnly = false
                    } else {
                        parts.append(.text(trimmedLine))
                        hasTextual = true
                        emojiOnly = false
                    }
                }
            }
        }

        let imageAttachments = imageAttachments(from: message.attachments)
        var hasMedia = false
        if !imageAttachments.isEmpty {
            hasMedia = true
            if imageAttachments.count == 1 {
                parts.append(.image(imageAttachments[0]))
            } else {
                parts.append(.gallery(imageAttachments))
            }
        }

        let plainWordCount = stripMarkdownMarkers(from: collectedPlainText
            .joined(separator: " "))
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count

        return MessagePresentation(
            parts: parts,
            wordCount: plainWordCount,
            hasTextualContent: hasTextual,
            isEmojiOnly: emojiOnly && hasTextual,
            hasMediaOnly: hasMedia && !hasTextual
        )
    }

    private static func imageAttachments(from attachments: [Attachment]) -> [Attachment] {
        attachments.filter { attachment in
            switch attachment.type {
            case .image:
                return true
            case .asset:
                return attachment.mimeType?.hasPrefix("image/") ?? false
            case .document:
                return false
            }
        }
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        let markdownIndicators = ["#", "*", "_", "~", "`", ">", "[", "]"]
        return markdownIndicators.contains(where: { text.contains($0) })
    }

    private static func exactURL(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.range.length == range.length else { return nil }
        return match.url
    }

    private static func isEmojiOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isEmoji }
    }

    private static func stripMarkdownMarkers(from text: String) -> String {
        let replacements: [String] = [
            "**", "__", "~~", "`", "*", "_", "~", "[", "]", "(", ")", "#", ">", "!", "-", "+"
        ]
        var stripped = text
        for marker in replacements {
            stripped = stripped.replacingOccurrences(of: marker, with: " ")
        }
        return stripped
    }
}

private enum SegmentKind {
    case text
    case code(language: String?)
}

private struct Segment {
    let kind: SegmentKind
    let content: String
}

private enum Segmenter {
    static func split(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        var remaining = input

        while let fenceRange = remaining.range(of: "```") {
            let before = String(remaining[..<fenceRange.lowerBound])
            if !before.isEmpty {
                segments.append(Segment(kind: .text, content: before))
            }

            remaining = String(remaining[fenceRange.upperBound...])
            var language: String? = nil
            if let newline = remaining.firstIndex(of: "\n") {
                let languageLine = String(remaining[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                language = languageLine.isEmpty ? nil : languageLine
                remaining = String(remaining[remaining.index(after: newline)...])
            }

            if let endRange = remaining.range(of: "```") {
                let code = String(remaining[..<endRange.lowerBound])
                segments.append(Segment(kind: .code(language: language), content: code))
                remaining = String(remaining[endRange.upperBound...])
            } else {
                segments.append(Segment(kind: .code(language: language), content: remaining))
                remaining = ""
            }
        }

        if !remaining.isEmpty {
            segments.append(Segment(kind: .text, content: remaining))
        }

        return segments
    }
}

private extension Character {
    var isEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmoji && (scalar.properties.generalCategory == .otherSymbol || scalar.properties.generalCategory == .modifierSymbol || scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark)
        }
    }
}
