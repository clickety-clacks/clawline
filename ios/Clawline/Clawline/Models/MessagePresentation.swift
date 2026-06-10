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
    let copyableReadableText: String?
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
        copyableReadableText: String? = nil,
        wordCount: Int,
        hasTextualContent: Bool,
        isEmojiOnly: Bool,
        hasMediaOnly: Bool,
        detectedURLs: [URL],
        detectedURLCount: Int,
        hasSingleURL: Bool
    ) {
        self.parts = parts
        self.copyableReadableText = copyableReadableText
        self.wordCount = wordCount
        self.hasTextualContent = hasTextualContent
        self.isEmojiOnly = isEmojiOnly
        self.hasMediaOnly = hasMediaOnly
        self.detectedURLs = detectedURLs
        self.detectedURLCount = detectedURLCount
        self.hasSingleURL = hasSingleURL
    }
}

extension MessagePresentation {
}

enum MessagePart: Equatable {
    case text(String)
    case markdown(String)
    case table(TableModel)
    case code(language: String?, code: String)
    case linkPreview(URL)
    case remoteImage(URL)
    case image(Attachment)
    case gallery([Attachment])
    case file(Attachment)
    case terminalSession(TerminalSessionDescriptor)
    case interactiveHTML(InteractiveHTMLDescriptor)
    case inlineEmoji(String)
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
        case .remoteImage, .image, .gallery, .file, .terminalSession, .interactiveHTML:
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
        case .remoteImage:
            return .image
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

    private struct RemoteImageExtraction {
        let markdownSource: String
        let urls: [URL]
    }

    private struct InlineImageExtraction {
        let markdownSource: String
        let attachments: [Attachment]
    }

    private struct InlineImagePayload {
        let mimeType: String
        let data: Data
    }

    static func build(
        from message: Message,
        metrics: ChatFlowTheme.Metrics,
        streamingState: inout StreamingTableParseState
    ) -> MessagePresentation {
        let markdownContent = UnifiedMarkdownRenderer.makeContent(
            messageText: message.content,
            context: MarkdownMessageRenderContext(
                role: message.role,
                messageID: message.id,
                metrics: metrics
            ),
            baseFont: UIFont.systemFont(ofSize: metrics.bodyFontSize),
            inkColor: .label,
            lineSpacing: 0,
            stripDetectedURLs: false,
            isDark: false
        )
        return buildPrepared(
            from: message,
            metrics: metrics,
            streamingState: &streamingState,
            renderedBlocks: markdownContent.renderedBlocks
        )
    }

    private static func buildPrepared(
        from message: Message,
        metrics: ChatFlowTheme.Metrics,
        streamingState: inout StreamingTableParseState,
        renderedBlocks: [RenderedMarkdownBlock]
    ) -> MessagePresentation {
        let terminalAllowed = SessionKey.isClawlinePersonalDM(message.sessionKey)
        let attachmentBuckets = partitionAttachments(
            from: message.attachments,
            terminalAllowed: terminalAllowed
        )
        var imageAttachments = attachmentBuckets.imageAttachments
        let fileAttachments = attachmentBuckets.fileAttachments
        var hasRenderableAttachments = !attachmentBuckets.richParts.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty
        var parts: [MessagePart] = []
        var markdownParts: [MessagePart] = []
        var plainTextForMetricsParts: [String] = []
        var copyableTextParts: [String] = []
        var remoteImageURLs: [URL] = []
        var emojiOnly = false
        var hasBlockedParts = hasRenderableAttachments
        var detectedURLOccurrences: [URL] = []
        let suppressTextForFiles = shouldSuppressTextForFileAttachments(
            content: message.content,
            fileAttachments: fileAttachments
        )
        let messageInlineImageExtraction = extractInlineImagePayloads(
            from: message.content,
            messageID: message.id,
            startingAt: imageAttachments.count
        )
        let messageRemoteImageExtraction = extractRemoteImageURLs(from: messageInlineImageExtraction.markdownSource)
        let hasCodeBlock = renderedBlocks.contains { block in
            if case .code = block { return true }
            return false
        }
        let shouldUseMessageMediaExtraction = !messageInlineImageExtraction.attachments.isEmpty
            || !messageRemoteImageExtraction.urls.isEmpty
        let shouldExtractMessageMedia = shouldUseMessageMediaExtraction && !hasCodeBlock

        // Rich document attachments share one MIME dispatch path.
        for richPart in attachmentBuckets.richParts {
            parts.append(richPart.part)
            hasBlockedParts = true
        }

        if shouldExtractMessageMedia {
            imageAttachments.append(contentsOf: messageInlineImageExtraction.attachments)
            remoteImageURLs.append(contentsOf: messageRemoteImageExtraction.urls)
            if !messageInlineImageExtraction.attachments.isEmpty {
                hasRenderableAttachments = true
                hasBlockedParts = true
            }
        }

        if !suppressTextForFiles {
            for block in renderedBlocks {
                switch block {
                case .attributedText(let attributedText):
                    let source = shouldExtractMessageMedia
                        ? messageRemoteImageExtraction.markdownSource
                        : attributedText.string
                    if !shouldExtractMessageMedia {
                        let inlineImageExtraction = extractInlineImagePayloads(
                            from: source,
                            messageID: message.id,
                            startingAt: imageAttachments.count
                        )
                        imageAttachments.append(contentsOf: inlineImageExtraction.attachments)
                        if !inlineImageExtraction.attachments.isEmpty {
                            hasRenderableAttachments = true
                            hasBlockedParts = true
                        }

                        let remoteImageExtraction = extractRemoteImageURLs(from: inlineImageExtraction.markdownSource)
                        remoteImageURLs.append(contentsOf: remoteImageExtraction.urls)
                    }
                    detectedURLOccurrences.append(contentsOf: extractRenderedURLs(
                        from: attributedText,
                        excludingMediaURLs: shouldExtractMessageMedia ? remoteImageURLs : []
                    ))
                    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if hasRenderableAttachments, isAttachmentSummaryLine(trimmed) {
                        continue
                    }
                    let displayText = trimmed
                    let plainText = markdownPlainText(from: displayText)
                    plainTextForMetricsParts.append(plainText)
                    if !plainText.isEmpty {
                        copyableTextParts.append(plainText)
                    }
                    if EmojiOnlyClassifier.isEmojiOnly(displayText) {
                        markdownParts.append(.inlineEmoji(displayText))
                    } else {
                        markdownParts.append(.markdown(displayText))
                    }
                case .code(let language, let code):
                    let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    plainTextForMetricsParts.append(trimmedCode)
                    if !trimmedCode.isEmpty {
                        copyableTextParts.append(trimmedCode)
                    }
                    markdownParts.append(.code(language: language, code: code))
                    hasBlockedParts = true
                    emojiOnly = false
                case .table(let model):
                    let tableText = tablePlainText(from: model)
                    plainTextForMetricsParts.append(tableText)
                    if !tableText.isEmpty {
                        copyableTextParts.append(tableCopyableText(from: model))
                    }
                    markdownParts.append(.table(model))
                    hasBlockedParts = true
                    emojiOnly = false
                }
            }
        }
        parts.append(contentsOf: markdownParts)
        if !remoteImageURLs.isEmpty {
            hasBlockedParts = true
        }

        let effectivePlainTextForMetrics = plainTextForMetricsParts
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTextual = !effectivePlainTextForMetrics.isEmpty
        emojiOnly = hasTextual
            && markdownParts.allSatisfy { part in
                if case .inlineEmoji = part { return true }
                return false
            }

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
        if !remoteImageURLs.isEmpty {
            hasMedia = true
            for url in remoteImageURLs {
                parts.append(.remoteImage(url))
            }
        }
        if !fileAttachments.isEmpty {
            for attachment in fileAttachments {
                parts.append(.file(attachment))
            }
        }
        let hasTerminal = parts.contains(where: { if case .terminalSession = $0 { return true }; return false })

        let plainWordCount = stripMarkdownMarkers(from: effectivePlainTextForMetrics)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
        let copyableReadableText = copyableTextParts
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return MessagePresentation(
            parts: parts,
            copyableReadableText: copyableReadableText.isEmpty ? nil : copyableReadableText,
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

    private static func extractRemoteImageURLs(from source: String) -> RemoteImageExtraction {
        var matches: [(range: Range<String.Index>, url: URL)] = []
        matches.append(contentsOf: markdownImageMatches(in: source))
        let markdownImageRanges = matches.map(\.range)
        for match in detectedURLMatches(in: source) where !markdownImageRanges.contains(where: { $0.overlaps(match.range) }) {
            matches.append(match)
        }
        guard !matches.isEmpty else {
            return RemoteImageExtraction(markdownSource: source, urls: [])
        }

        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        var strippedSource = source
        for match in matches.reversed() {
            strippedSource.removeSubrange(match.range)
        }
        return RemoteImageExtraction(
            markdownSource: normalizeMarkdownAfterRemovingImageURLs(strippedSource),
            urls: matches.map(\.url)
        )
    }

    private static func extractInlineImagePayloads(
        from source: String,
        messageID: String,
        startingAt attachmentOffset: Int
    ) -> InlineImageExtraction {
        var matches: [(range: Range<String.Index>, payload: InlineImagePayload)] = []
        matches.append(contentsOf: markdownInlineImageMatches(in: source))
        let markdownImageRanges = matches.map(\.range)
        for match in bareInlineImageMatches(in: source) where !markdownImageRanges.contains(where: { $0.overlaps(match.range) }) {
            matches.append(match)
        }
        guard !matches.isEmpty else {
            return InlineImageExtraction(markdownSource: source, attachments: [])
        }

        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        var strippedSource = source
        for match in matches.reversed() {
            strippedSource.removeSubrange(match.range)
        }
        let attachments = matches.enumerated().map { index, match in
            Attachment(
                id: "inline-data-image-\(messageID)-\(attachmentOffset + index)",
                type: .image,
                mimeType: match.payload.mimeType,
                data: match.payload.data,
                assetId: nil,
                size: match.payload.data.count
            )
        }
        return InlineImageExtraction(
            markdownSource: normalizeMarkdownAfterRemovingImageURLs(strippedSource),
            attachments: attachments
        )
    }

    private static func markdownInlineImageMatches(in source: String) -> [(range: Range<String.Index>, payload: InlineImagePayload)] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\((data:image\/[A-Za-z0-9.+-]+(?:;[^,\)]*)?,.*?)(?:\s+"[^"]*")?\)"#, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: source),
                  let payloadRange = Range(match.range(at: 1), in: source),
                  let payload = inlineImagePayload(from: String(source[payloadRange])) else {
                return nil
            }
            return (fullRange, payload)
        }
    }

    private static func bareInlineImageMatches(in source: String) -> [(range: Range<String.Index>, payload: InlineImagePayload)] {
        guard let regex = try? NSRegularExpression(pattern: #"data:image\/[A-Za-z0-9.+-]+(?:;[^,\s)]*)?,[^\s)]+"#) else {
            return []
        }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: source),
                  let payload = inlineImagePayload(from: String(source[range])) else {
                return nil
            }
            return (range, payload)
        }
    }

    private static func inlineImagePayload(from rawDataURL: String) -> InlineImagePayload? {
        guard rawDataURL.lowercased().hasPrefix("data:image/"),
              let commaIndex = rawDataURL.firstIndex(of: ",") else {
            return nil
        }

        let metadata = rawDataURL[rawDataURL.index(rawDataURL.startIndex, offsetBy: 5)..<commaIndex]
        let metadataParts = metadata.split(separator: ";", omittingEmptySubsequences: false)
        guard let mediaType = metadataParts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              mediaType.hasPrefix("image/"),
              !mediaType.isEmpty else {
            return nil
        }

        let payload = String(rawDataURL[rawDataURL.index(after: commaIndex)...])
        let isBase64 = metadataParts.dropFirst().contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "base64" }
        let decodedData: Data?
        if isBase64 {
            decodedData = Data(base64Encoded: payload.filter { !$0.isWhitespace })
        } else {
            decodedData = percentDecodedData(from: payload)
        }

        guard let data = decodedData,
              !data.isEmpty,
              UIImage(data: data) != nil else {
            return nil
        }
        return InlineImagePayload(mimeType: mediaType, data: data)
    }

    private static func percentDecodedData(from payload: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(payload.utf8.count)
        let scalars = Array(payload.unicodeScalars)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "%" {
                let firstHexIndex = scalars.index(after: index)
                let secondHexIndex = scalars.index(firstHexIndex, offsetBy: 1, limitedBy: scalars.endIndex)
                guard let secondHexIndex,
                      secondHexIndex < scalars.endIndex,
                      let first = hexValue(scalars[firstHexIndex]),
                      let second = hexValue(scalars[secondHexIndex]) else {
                    return nil
                }
                bytes.append((first << 4) | second)
                index = scalars.index(after: secondHexIndex)
            } else if scalar.isASCII,
                      let byte = scalar.value <= UInt8.max ? UInt8(exactly: scalar.value) : nil {
                bytes.append(byte)
                index = scalars.index(after: index)
            } else {
                return nil
            }
        }
        return Data(bytes)
    }

    private static func hexValue(_ scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 48...57:
            return UInt8(scalar.value - 48)
        case 97...102:
            return UInt8(scalar.value - 97 + 10)
        case 65...70:
            return UInt8(scalar.value - 65 + 10)
        default:
            return nil
        }
    }

    private static func markdownImageMatches(in source: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) else {
            return []
        }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: source),
                  let urlRange = Range(match.range(at: 1), in: source),
                  let url = validatedDetectedURL(from: String(source[urlRange])),
                  isDirectImageURL(url) else {
                return nil
            }
            return (fullRange, url)
        }
    }

    private static func detectedURLMatches(in source: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let detector = linkDetector else { return [] }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return detector.matches(in: source, range: nsRange).compactMap { match in
            guard let url = match.url,
                  let range = Range(match.range, in: source),
                  let validated = sanitizedDetectedURL(from: url.absoluteString) ?? validatedDetectedURL(from: url.absoluteString),
                  isDirectImageURL(validated) else {
                return nil
            }
            return (range, validated)
        }
    }

    private static func isDirectImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func normalizeMarkdownAfterRemovingImageURLs(_ source: String) -> String {
        source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tablePlainText(from model: TableModel) -> String {
        var components: [String] = []
        if let header = model.header {
            components.append(contentsOf: header.map(\.plainText))
        }
        for row in model.rows {
            components.append(contentsOf: row.cells.map(\.plainText))
        }
        return components.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableCopyableText(from model: TableModel) -> String {
        var lines: [String] = []
        if let header = model.header {
            let headerText = header.map(\.plainText).joined(separator: "\t")
            if !headerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(headerText)
            }
        }
        for row in model.rows {
            let rowText = row.cells.map(\.plainText).joined(separator: "\t")
            if !rowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(rowText)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
                if isInteractiveHTMLAttachment(attachment),
                   let descriptor = decodeInteractiveHTMLDescriptor(from: attachment) {
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
            isInteractiveHTMLAttachment(attachment)
        }
    }

    private static func isInteractiveHTMLAttachment(_ attachment: Attachment) -> Bool {
        guard attachment.type == .document else { return false }
        return mimeTypeEquals(attachment.mimeType, expected: InteractiveHTMLDescriptor.mimeType)
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
        guard isInteractiveHTMLAttachment(attachment),
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
            return invalidInteractiveHTMLDescriptor()
        }
    }

    private static func invalidInteractiveHTMLDescriptor() -> InteractiveHTMLDescriptor {
        InteractiveHTMLDescriptor(
            version: 1,
            html: """
            <!doctype html>
            <html>
              <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
              </head>
              <body style="margin:0;padding:12px;font:15px -apple-system,system-ui,sans-serif;color:var(--clawline-fg);background:var(--clawline-bubble-bg);">
                Interactive content could not be displayed because its attachment data is invalid.
              </body>
            </html>
            """,
            metadata: .init(title: nil, height: .auto, maxHeight: 160, backgroundColor: nil)
        )
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

    private static func extractRenderedURLs(
        from attributed: NSAttributedString,
        excludingMediaURLs mediaURLs: [URL] = []
    ) -> [URL] {
        let text = attributed.string
        var urls: [URL] = []
        let mediaURLStrings = Set(mediaURLs.map(\.absoluteString))
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let value else { return }
            guard !TextLinkURLTemplateRules.isGeneratedLink(in: attributed, characterRange: range) else { return }
            let href: String
            if let url = value as? URL {
                href = url.absoluteString
            } else if let string = value as? String {
                href = string
            } else {
                return
            }
            let displayedText = range.location != NSNotFound && NSMaxRange(range) <= (text as NSString).length
                ? (text as NSString).substring(with: range)
                : href
            let previousRunText = wrappedMarkPrefix(in: text, matchRange: range)
            let validatedURL = wrappedMarkTrimmedURL(
                    displayedText: displayedText,
                    href: href,
                    previousRunText: previousRunText
                )
                ?? sanitizedDetectedURL(from: displayedText)
                ?? sanitizedDetectedURL(from: href)
                ?? validatedDetectedURL(from: href)
            guard let validatedURL else { return }
            let sanitizedURL = sanitizedDetectedURL(from: validatedURL.absoluteString) ?? validatedURL
            guard !shouldExcludeRenderedURL(sanitizedURL, mediaURLStrings: mediaURLStrings) else { return }
            urls.append(sanitizedURL)
        }

        let detectedBareURLs = extractURLs(from: text)
        let seen = Set(urls.map(\.absoluteString))
        for url in detectedBareURLs where !seen.contains(url.absoluteString)
            && !seen.contains(where: { seenURL in
                seenURL.hasPrefix(url.absoluteString) && seenURL.dropFirst(url.absoluteString.count).allSatisfy { $0 == "=" }
            })
            && !shouldExcludeRenderedURL(url, mediaURLStrings: mediaURLStrings) {
            urls.append(url)
        }

        return urls
    }

    private static func shouldExcludeRenderedURL(_ url: URL, mediaURLStrings: Set<String>) -> Bool {
        mediaURLStrings.contains(url.absoluteString) || isDirectImageURL(url)
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
