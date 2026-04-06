//
//  MessagePresentation.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import CryptoKit
import Markdown
import OSLog
import UIKit

struct TableModel: Equatable {
    struct Column: Equatable {
        let alignment: ColumnAlignment
    }

    struct Cell: Equatable {
        let attributed: AttributedString
        let intrinsicWidth: CGFloat
        let plainText: String
        let isEmpty: Bool
    }

    struct Row: Equatable, Identifiable {
        let id: UUID
        let cells: [Cell]
    }

    let columns: [Column]
    let header: [Cell]?
    let rows: [Row]
    let messageID: String
    let rowOffset: Int

    func appendingRow(_ row: [Cell]) -> TableModel {
        guard row.count == columns.count else { return self }
        var updatedRows = rows
        let identifier = TableModel.makeRowIdentifier(
            messageID: messageID,
            rowIndex: rowOffset + updatedRows.count,
            cells: row.map(\.plainText)
        )
        updatedRows.append(Row(id: identifier, cells: row))
        return TableModel(
            columns: columns,
            header: header,
            rows: updatedRows,
            messageID: messageID,
            rowOffset: rowOffset
        )
    }
}

enum ColumnAlignment: Equatable {
    case leading
    case center
    case trailing

    init(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
        case (true, true):
            self = .center
        case (false, true):
            self = .trailing
        case (true, false):
            self = .leading
        default:
            self = .leading
        }
    }
}

struct StreamingTableParseState {
    private(set) var lastUpdatedAt: Date?
    private(set) var pendingStartIndex: Int?
    private(set) var pendingStartedAt: Date?

    mutating func markStreamingUpdate() {
        lastUpdatedAt = Date()
    }

    mutating func beginPending(at startIndex: Int) {
        pendingStartIndex = startIndex
        pendingStartedAt = Date()
    }

    mutating func clearPending() {
        pendingStartIndex = nil
        pendingStartedAt = nil
    }

    mutating func reset() {
        lastUpdatedAt = nil
        clearPending()
    }

    var isDirty: Bool {
        lastUpdatedAt != nil || pendingStartIndex != nil
    }
}

struct MessagePresentation: Equatable {
    let parts: [MessagePart]
    let markdownRenderPlan: MarkdownRenderPlan
    let wordCount: Int
    let hasTextualContent: Bool
    let isEmojiOnly: Bool
    let hasMediaOnly: Bool
    /// Unique http/https URLs detected in the message text, in first-seen order.
    /// Used for sizing (single-link wide bubbles) and link-card rendering independent of preview availability.
    let detectedURLs: [URL]
    /// Number of URL occurrences detected (including duplicates).
    let detectedURLCount: Int
    /// True when the message contains exactly one URL occurrence (http/https) in its text content.
    /// This is used for sizing/routing decisions even if we don't render a preview card.
    let hasSingleURL: Bool

    init(
        parts: [MessagePart],
        markdownRenderPlan: MarkdownRenderPlan = .empty,
        wordCount: Int,
        hasTextualContent: Bool,
        isEmojiOnly: Bool,
        hasMediaOnly: Bool,
        detectedURLs: [URL],
        detectedURLCount: Int,
        hasSingleURL: Bool
    ) {
        self.parts = parts
        self.markdownRenderPlan = markdownRenderPlan
        self.wordCount = wordCount
        self.hasTextualContent = hasTextualContent
        self.isEmojiOnly = isEmojiOnly
        self.hasMediaOnly = hasMediaOnly
        self.detectedURLs = detectedURLs
        self.detectedURLCount = detectedURLCount
        self.hasSingleURL = hasSingleURL
    }
}

enum MessagePart: Equatable {
    case text(String)
    case markdown(String)
    case table(TableModel)
    case code(language: String?, code: String)
    case linkPreview(URL)
    case image(Attachment)
    case gallery([Attachment])
    case file(Attachment)
    case terminalSession(TerminalSessionDescriptor)
    case interactiveHTML(InteractiveHTMLDescriptor)
    case inlineEmoji(String)
}

enum MarkdownRenderBlock: Equatable {
    case richText(markdownSource: String)
    case code(language: String?, code: String)
    case table(TableModel)
}

struct MarkdownRenderPlan: Equatable {
    let blocks: [MarkdownRenderBlock]
    let plainTextForMetrics: String
    let containsTextualContent: Bool
    let isEmojiOnly: Bool

    nonisolated static let empty = MarkdownRenderPlan(
        blocks: [],
        plainTextForMetrics: "",
        containsTextualContent: false,
        isEmojiOnly: false
    )
}

struct MarkdownRenderOptions: Equatable {
    let baseFont: UIFont
    let inkColor: UIColor
    let lineSpacing: CGFloat
    let stripDetectedURLs: Bool
    let markHighlightColor: UIColor?
}

enum RenderedMarkdownBlock: Equatable {
    case attributedText(NSAttributedString)
    case code(language: String?, code: String)
    case table(TableModel)
}

/// Content types that can render without bubble chrome when they are the only element.
enum ChromelessStyle: Equatable {
    case image
    case table
    case codeBlock
    case emoji  // 1-3 emojis only, centered with amplified font size
    // case blockquote (future)
}

extension MessagePart {
    private static let chromelessIgnorableCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}")
        return set
    }()

    var isTextual: Bool {
        switch self {
        case .text, .markdown, .table, .inlineEmoji, .code:
            return true
        case .linkPreview:
            return true
        case .image, .gallery, .file, .terminalSession, .interactiveHTML:
            return false
        }
    }

    var isChromelessIgnorable: Bool {
        switch self {
        case .text(let text), .markdown(let text):
            return text.trimmingCharacters(in: Self.chromelessIgnorableCharacters).isEmpty
        default:
            return false
        }
    }
}

extension MessagePresentation {
    /// Returns the chromeless style if this message qualifies for chromeless rendering.
    /// A message qualifies when it contains exactly one visible element of a supported type.
    var chromelessStyle: ChromelessStyle? {
        let chromelessCandidates = parts.filter { !$0.isChromelessIgnorable }
        guard chromelessCandidates.count == 1, let candidate = chromelessCandidates.first else { return nil }

        switch candidate {
        case .image:
            return .image
        case .gallery:
            return .image
        case .table:
            return .table
        case .code:
            return .codeBlock
        case .inlineEmoji(let value):
            return EmojiOnlyClassifier.isEmojiOnly(value) ? .emoji : nil
        default:
            return nil
        }
    }

    /// Whether this message should render without bubble chrome.
    var isChromeless: Bool {
        chromelessStyle != nil
    }
}

enum MessagePresentationBuilder {
    private static let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MarkdownTable")
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private struct RichAttachmentPart {
        let part: MessagePart
    }

    private struct AttachmentBuckets {
        let richParts: [RichAttachmentPart]
        let imageAttachments: [Attachment]
        let fileAttachments: [Attachment]
    }

    static func build(
        from message: Message,
        metrics: ChatFlowTheme.Metrics,
        streamingState: inout StreamingTableParseState
    ) -> MessagePresentation {
        let markdownPlan = UnifiedMarkdownParser.parse(
            markdown: message.content,
            messageID: message.id,
            metrics: metrics
        )
        let terminalAllowed = SessionKey.isClawlinePersonalDM(message.sessionKey)
        let attachmentBuckets = partitionAttachments(
            from: message.attachments,
            terminalAllowed: terminalAllowed
        )
        let imageAttachments = attachmentBuckets.imageAttachments
        let fileAttachments = attachmentBuckets.fileAttachments
        let hasAttachments = !attachmentBuckets.richParts.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty
        var parts: [MessagePart] = []
        var markdownParts: [MessagePart] = []
        let hasTextual = markdownPlan.containsTextualContent
        var emojiOnly = markdownPlan.isEmojiOnly
        var hasBlockedParts = hasAttachments
        var detectedURLOccurrences: [URL] = []
        let suppressTextForFiles = shouldSuppressTextForFileAttachments(
            content: message.content,
            fileAttachments: fileAttachments
        )

        // Rich document attachments share one MIME dispatch path.
        for richPart in attachmentBuckets.richParts {
            parts.append(richPart.part)
            hasBlockedParts = true
        }

        if !suppressTextForFiles {
            for block in markdownPlan.blocks {
                switch block {
                case .richText(let source):
                    detectedURLOccurrences.append(contentsOf: extractMarkdownURLs(from: source))
                    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if hasAttachments, isAttachmentSummaryLine(trimmed) {
                        continue
                    }
                    if EmojiOnlyClassifier.isEmojiOnly(trimmed) {
                        markdownParts.append(.inlineEmoji(trimmed))
                    } else {
                        markdownParts.append(.markdown(trimmed))
                    }
                case .code(let language, let code):
                    markdownParts.append(.code(language: language, code: code))
                    hasBlockedParts = true
                    emojiOnly = false
                case .table(let model):
                    markdownParts.append(.table(model))
                    hasBlockedParts = true
                    emojiOnly = false
                }
            }
        }
        parts.append(contentsOf: markdownParts)

        // Preserve first-seen order for UI, but provide a stable unique list for sizing/cards.
        var uniqueURLs: [URL] = []
        var seen: Set<String> = []
        uniqueURLs.reserveCapacity(detectedURLOccurrences.count)
        for url in detectedURLOccurrences {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                uniqueURLs.append(url)
            }
        }

        if !hasBlockedParts,
           detectedURLOccurrences.count == 1 {
            parts.append(.linkPreview(detectedURLOccurrences[0]))
        }

        // Flynn #28: "single link" means exactly one detected URL occurrence, not "one unique URL repeated".
        let hasSingleURL = detectedURLOccurrences.count == 1

        var hasMedia = false
        if !imageAttachments.isEmpty {
            hasMedia = true
            if imageAttachments.count == 1 {
                parts.append(.image(imageAttachments[0]))
            } else {
                parts.append(.gallery(imageAttachments))
            }
        }
        if !fileAttachments.isEmpty {
            for attachment in fileAttachments {
                parts.append(.file(attachment))
            }
        }
        let hasTerminal = parts.contains(where: { if case .terminalSession = $0 { return true }; return false })

        let plainWordCount = stripMarkdownMarkers(from: markdownPlan.plainTextForMetrics)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count

        return MessagePresentation(
            parts: parts,
            markdownRenderPlan: suppressTextForFiles ? .empty : markdownPlan,
            wordCount: plainWordCount,
            hasTextualContent: hasTextual,
            isEmojiOnly: emojiOnly && hasTextual,
            hasMediaOnly: !hasTerminal && hasMedia && !hasTextual,
            detectedURLs: uniqueURLs,
            detectedURLCount: detectedURLOccurrences.count,
            hasSingleURL: hasSingleURL
        )
    }

    private static func isAttachmentSummaryLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("attachment:") || lower.hasPrefix("attachments:")
    }

    private static func isImageMime(_ mime: String?) -> Bool {
        mime?.lowercased().hasPrefix("image/") == true
    }

    private static func partitionAttachments(
        from attachments: [Attachment],
        terminalAllowed: Bool
    ) -> AttachmentBuckets {
        var richParts: [RichAttachmentPart] = []
        var imageAttachments: [Attachment] = []
        var fileAttachments: [Attachment] = []

        for attachment in attachments {
            switch attachment.type {
            case .image:
                imageAttachments.append(attachment)
            case .asset:
                // Check mime type first; only treat data-bearing assets as images
                // when mime is image/* (or absent, for backward compat with older data).
                if let mime = attachment.mimeType {
                    if isImageMime(mime) {
                        imageAttachments.append(attachment)
                    } else {
                        fileAttachments.append(attachment)
                    }
                    continue
                }
                // No mime: fall back to data presence (legacy behavior for image assets).
                if attachment.data != nil {
                    imageAttachments.append(attachment)
                } else {
                    fileAttachments.append(attachment)
                }
            case .document:
                // Terminal sessions are DM-only; invalid/blocked payloads fall back to generic files.
                if terminalAllowed,
                   let descriptor = decodeTerminalSessionDescriptor(from: attachment) {
                    richParts.append(
                        RichAttachmentPart(
                            part: .terminalSession(descriptor)
                        )
                    )
                    continue
                }
                if let descriptor = decodeInteractiveHTMLDescriptor(from: attachment) {
                    richParts.append(
                        RichAttachmentPart(
                            part: .interactiveHTML(descriptor)
                        )
                    )
                    continue
                }
                fileAttachments.append(attachment)
            }
        }

        return AttachmentBuckets(
            richParts: richParts,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )
    }

    private static func isTerminalSessionAttachment(_ attachment: Attachment) -> Bool {
        guard attachment.type == .document else { return false }
        return mimeTypeEquals(attachment.mimeType, expected: TerminalSessionDescriptor.mimeType)
    }

    private static func interactiveHTMLAttachments(from attachments: [Attachment]) -> [Attachment] {
        attachments.filter { attachment in
            guard attachment.type == .document else { return false }
            return mimeTypeEquals(attachment.mimeType, expected: InteractiveHTMLDescriptor.mimeType)
        }
    }

    private static func decodeTerminalSessionDescriptor(from attachment: Attachment) -> TerminalSessionDescriptor? {
        guard isTerminalSessionAttachment(attachment),
              let data = attachment.data,
              !data.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(TerminalSessionDescriptor.self, from: data)
        } catch {
            logger.error(
                "terminal_session_descriptor_decode_failed id=\(attachment.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func decodeInteractiveHTMLDescriptor(from attachment: Attachment) -> InteractiveHTMLDescriptor? {
        guard attachment.type == .document,
              mimeTypeEquals(attachment.mimeType, expected: InteractiveHTMLDescriptor.mimeType),
              let data = attachment.data,
              !data.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(InteractiveHTMLDescriptor.self, from: data)
        } catch {
            logger.error(
                "interactive_html_descriptor_decode_failed id=\(attachment.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }


    private static func shouldSuppressTextForFileAttachments(
        content: String,
        fileAttachments: [Attachment]
    ) -> Bool {
        guard !fileAttachments.isEmpty else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard looksLikeJSON(trimmed) else { return false }
        return fileAttachments.contains { attachment in
            if let mime = normalizedMimeType(attachment.mimeType) {
                if mime == "application/json" || mime == "text/json" || mime.hasSuffix("+json") {
                    return true
                }
            }
            if let filename = attachment.filename?.lowercased(), filename.hasSuffix(".json") {
                return true
            }
            return false
        }
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        if (first == "{" && last == "}") || (first == "[" && last == "]") {
            return true
        }
        return false
    }

    private static func normalizedMimeType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
        let trimmed = base?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func mimeTypeEquals(_ raw: String?, expected: String) -> Bool {
        normalizedMimeType(raw) == expected
    }

    private static func extractURLs(from text: String) -> [URL] {
        guard let detector = linkDetector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var urls: [URL] = []
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  let matchRange = Range(match.range, in: text) else { return }
            let rawMatch = String(text[matchRange])
            let validatedURL = wrappedMarkTrimmedURL(
                displayedText: rawMatch,
                href: rawMatch,
                previousRunText: wrappedMarkPrefix(in: text, matchRange: match.range)
            ) ?? sanitizedDetectedURL(from: rawMatch)
            guard let url = validatedURL else { return }
            urls.append(url)
        }
        return urls
    }

    private static func extractMarkdownURLs(from source: String) -> [URL] {
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        ) else {
            return extractURLs(from: markdownPlainText(from: source))
        }

        let runs = attributed.runs.map { run in
            (
                text: String(attributed[run.range].characters),
                link: run.link
            )
        }
        var urls: [URL] = []
        for index in runs.indices {
            guard let url = runs[index].link else { continue }
            let displayedText = runs[index].text
            let previousRunText = index > 0 ? runs[index - 1].text : nil
            let validatedURL = wrappedMarkTrimmedURL(
                    displayedText: displayedText,
                    href: url.absoluteString,
                    previousRunText: previousRunText
                )
                ?? sanitizedDetectedURL(from: displayedText)
                ?? sanitizedDetectedURL(from: url.absoluteString)
                ?? validatedDetectedURL(from: url.absoluteString)
            guard let validatedURL else { continue }
            urls.append(validatedURL)
        }

        // Bare URLs (e.g. `http://host:port`) are not recognized as links by the
        // CommonMark parser, but NSDataDetector *does* detect them—matching
        // UITextView's `.link` data-detector behavior.  Supplement the markdown-
        // extracted set so these URLs also produce link cards.
        let plainText = NSAttributedString(attributed).string
        let detectedBareURLs = extractURLs(from: plainText)
        let seen = Set(urls.map(\.absoluteString))
        for url in detectedBareURLs where !seen.contains(url.absoluteString) {
            urls.append(url)
        }

        return urls
    }

    private static func sanitizedDetectedURL(from rawMatch: String) -> URL? {
        MarkdownURLBoundarySanitizer.sanitizedURL(from: rawMatch)
    }

    private static func validatedDetectedURL(from candidate: String) -> URL? {
        guard let url = MarkdownURLBoundarySanitizer.validatedHTTPURL(from: candidate) else { return nil }
        if url.absoluteString.count > 2048 { return nil }
        return url
    }

    private static func wrappedMarkTrimmedURL(
        displayedText: String,
        href: String,
        previousRunText: String?
    ) -> URL? {
        guard previousRunText == "==" else { return nil }
        for candidate in [displayedText, href] where candidate.hasSuffix("==") {
            let trimmed = String(candidate.dropLast(2))
            if let url = validatedDetectedURL(from: trimmed) {
                return url
            }
        }
        return nil
    }

    private static func wrappedMarkPrefix(in text: String, matchRange: NSRange) -> String? {
        guard matchRange.location >= 2 else { return nil }
        let nsText = text as NSString
        return nsText.substring(with: NSRange(location: matchRange.location - 2, length: 2))
    }

    private static func markdownPlainText(from source: String) -> String {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        ) {
            return NSAttributedString(attributed).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
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

extension TableModel {
    nonisolated static func makeRowIdentifier(
        messageID: String,
        rowIndex: Int,
        cells: [String]
    ) -> UUID {
        let raw = "\(messageID)|row|\(rowIndex)|\(cells.joined(separator: "|"))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        var bytes = Array(digest.prefix(16))
        if bytes.count < 16 {
            bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
        }
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
