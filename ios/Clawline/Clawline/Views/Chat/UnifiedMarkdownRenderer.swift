import Foundation
import UIKit

struct UnifiedMarkdownContent {
    let renderedBlocks: [RenderedMarkdownBlock]
    let inlineEmojiValues: [String]

    var firstInlineEmojiValue: String? {
        inlineEmojiValues.first
    }

    var joinedInlineEmojiValues: String? {
        guard !inlineEmojiValues.isEmpty else { return nil }
        return inlineEmojiValues.joined(separator: "\n\n")
    }

    var hasNonEmptyAttributedText: Bool {
        renderedBlocks.contains { block in
            guard case .attributedText(let attributed) = block else { return false }
            return !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasCodeOrTable: Bool {
        renderedBlocks.contains { block in
            if case .code = block { return true }
            if case .table = block { return true }
            return false
        }
    }

    var hasRenderableMarkdownContent: Bool {
        hasNonEmptyAttributedText || hasCodeOrTable
    }
}

enum UnifiedMarkdownRenderer {
    private static let markOpenSentinel = "\u{F0000}"
    private static let markCloseSentinel = "\u{F0001}"
    private static let markdownLinkBoundaryTokens = [markOpenSentinel, markCloseSentinel]

    static func makeOptions(
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        stripDetectedURLs: Bool,
        role: Message.Role,
        isDark: Bool
    ) -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: stripDetectedURLs,
            markHighlightColor: role == .assistant
                ? SalientHighlightApplier.highlightColor(isDark: isDark)
                : nil
        )
    }

    static func makeContent(
        presentation: MessagePresentation,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        stripDetectedURLs: Bool,
        role: Message.Role,
        isDark: Bool
    ) -> UnifiedMarkdownContent {
        let renderedBlocks = render(
            plan: presentation.markdownRenderPlan,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: stripDetectedURLs,
            role: role,
            isDark: isDark
        )
        let inlineEmojiValues = presentation.parts.compactMap { part -> String? in
            if case .inlineEmoji(let value) = part { return value }
            return nil
        }
        return UnifiedMarkdownContent(
            renderedBlocks: renderedBlocks,
            inlineEmojiValues: inlineEmojiValues
        )
    }

    static func render(
        plan: MarkdownRenderPlan,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        stripDetectedURLs: Bool,
        role: Message.Role,
        isDark: Bool
    ) -> [RenderedMarkdownBlock] {
        let options = makeOptions(
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: stripDetectedURLs,
            role: role,
            isDark: isDark
        )
        return render(plan: plan, options: options)
    }

    static func configureTextView(
        _ textView: UITextView,
        delegate: UITextViewDelegate?,
        linkTextAttributes: [NSAttributedString.Key: Any] = [:],
        enableDataDetectors: Bool = false
    ) {
        textView.backgroundColor = .clear
        textView.isUserInteractionEnabled = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = enableDataDetectors ? [.link] : []
        textView.delegate = delegate
        textView.linkTextAttributes = linkTextAttributes
    }

    @available(iOS 17.0, macCatalyst 17.0, visionOS 1.0, *)
    @MainActor
    static func primaryActionForTextItem(
        _ textItem: UITextItem,
        defaultAction: UIAction,
        openURL: @escaping (URL) -> Void
    ) -> UIAction? {
        guard case .link(let url) = textItem.content else {
            return defaultAction
        }
        return UIAction { _ in
            openURL(url)
        }
    }

    static func render(
        plan: MarkdownRenderPlan,
        options: MarkdownRenderOptions
    ) -> [RenderedMarkdownBlock] {
        plan.blocks.compactMap { block in
            switch block {
            case .richText(let markdownSource):
                let attributed = renderNSAttributedString(
                    markdown: markdownSource,
                    baseFont: options.baseFont,
                    inkColor: options.inkColor,
                    lineSpacing: options.lineSpacing,
                    markHighlightColor: options.markHighlightColor
                ) ?? NSAttributedString(
                    string: markdownSource,
                    attributes: baseAttributes(
                        baseFont: options.baseFont,
                        inkColor: options.inkColor,
                        lineSpacing: options.lineSpacing
                    )
                )

                let cleaned = options.stripDetectedURLs
                    ? stripDetectedLinks(from: attributed)
                    : attributed
                return .attributedText(cleaned)
            case .code(let language, let code):
                return .code(language: language, code: code)
            case .table(let model):
                return .table(model)
            }
        }
    }

    static func renderNSAttributedString(
        markdown: String,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        markHighlightColor: UIColor? = nil
    ) -> NSAttributedString? {
        let parsedMarkdown = (markHighlightColor != nil)
            ? preprocessMarkHighlightSyntax(markdown)
            : markdown

        // UIKit rendering relies on concrete line breaks in the backing string. Ordered lists parsed
        // with `.full` collapse separators into presentation intents, which become run-on text.
        let hasOrderedListSyntax = parsedMarkdown.range(
            of: #"(?m)^\s*\d+[.)]\s+"#,
            options: .regularExpression
        ) != nil
        let hasUnorderedListSyntax = parsedMarkdown.range(
            of: #"(?m)^[ \t]*[-*+]\s+"#,
            options: .regularExpression
        ) != nil
        let shouldUseInlineListParsing = hasOrderedListSyntax || hasUnorderedListSyntax
        let markdownForRender = hasOrderedListSyntax
            ? normalizeOrderedListMarkers(in: parsedMarkdown)
            : parsedMarkdown

        // Prefer full parsing (block syntax like headings), but keep list separators intact.
        let attributed: AttributedString
        if shouldUseInlineListParsing,
           let inline = try? AttributedString(markdown: markdownForRender, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attributed = inline
        } else if let full = try? AttributedString(markdown: markdownForRender, options: .init(interpretedSyntax: .full)) {
            attributed = full
        } else if let inline = try? AttributedString(markdown: markdownForRender, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attributed = inline
        } else {
            return nil
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left

        let nsAttributed = NSMutableAttributedString(attributed)
        let fullRange = NSRange(location: 0, length: nsAttributed.length)
        nsAttributed.addAttribute(.foregroundColor, value: inkColor, range: fullRange)
        nsAttributed.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        nsAttributed.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let existingFont = value as? UIFont else {
                nsAttributed.addAttribute(.font, value: baseFont, range: range)
                return
            }

            let traits = existingFont.fontDescriptor.symbolicTraits
            let size = baseFont.pointSize
            var newFont = UIFont(descriptor: baseFont.fontDescriptor, size: size)

            if traits.contains(.traitBold) && traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitBold) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitMonoSpace) {
                newFont = UIFont.clawlineMonospaced(.secondaryLabel, weight: .regular)
                nsAttributed.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: range)
            }

            nsAttributed.addAttribute(.font, value: newFont, range: range)
        }

        annotateDetectedLinks(nsAttributed)
        sanitizeLinkAttributes(nsAttributed)
        applyHeadingStyles(markdown: markdownForRender, nsAttributed: nsAttributed, baseFont: baseFont)
        if let markHighlightColor {
            applyMarkHighlights(nsAttributed: nsAttributed, color: markHighlightColor)
        }

        return nsAttributed
    }

    private static func baseAttributes(baseFont: UIFont, inkColor: UIColor, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left
        return [
            .font: baseFont,
            .foregroundColor: inkColor,
            .paragraphStyle: paragraph
        ]
    }

    private static let detectedLinkStripper: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func annotateDetectedLinks(_ attributed: NSMutableAttributedString) {
        guard let detector = detectedLinkStripper else { return }
        let text = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let matches = detector.matches(in: attributed.string, options: [], range: fullRange)

        for match in matches {
            guard match.resultType == .link else { continue }
            guard attributed.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let rawMatch = text.substring(with: match.range)
            let url = MarkdownURLBoundarySanitizer.sanitizedURL(
                from: rawMatch,
                additionalBoundaryTokens: markdownLinkBoundaryTokens
            ) ?? match.url
            guard let url else { continue }
            attributed.addAttribute(.link, value: url, range: match.range)
        }
    }

    private static func sanitizeLinkAttributes(_ attributed: NSMutableAttributedString) {
        let text = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        var updates: [(range: NSRange, trimmedLength: Int, url: URL)] = []

        attributed.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            guard let rawValue = value else { return }
            let displayedText = text.substring(with: range)
            let currentURL: URL? = {
                if let url = rawValue as? URL { return url }
                if let string = rawValue as? String { return URL(string: string) }
                return nil
            }()

            let desiredURL =
                MarkdownURLBoundarySanitizer.sanitizedURL(
                    from: displayedText,
                    additionalBoundaryTokens: markdownLinkBoundaryTokens
                )
                ?? currentURL.flatMap {
                    MarkdownURLBoundarySanitizer.sanitizedURL(
                        from: $0.absoluteString,
                        additionalBoundaryTokens: markdownLinkBoundaryTokens
                    )
                }

            guard let desiredURL else { return }
            let desiredString = desiredURL.absoluteString
            guard displayedText.hasPrefix(desiredString) else { return }

            let trimmedLength = (desiredString as NSString).length
            let currentString = currentURL?.absoluteString
            let needsUpdate = trimmedLength != range.length || currentString != desiredString
            guard needsUpdate else { return }

            updates.append((range: range, trimmedLength: trimmedLength, url: desiredURL))
        }

        for update in updates.reversed() {
            attributed.removeAttribute(.link, range: update.range)
            guard update.trimmedLength > 0 else { continue }
            let trimmedRange = NSRange(location: update.range.location, length: update.trimmedLength)
            attributed.addAttribute(.link, value: update.url, range: trimmedRange)
            let trailingLength = update.range.length - update.trimmedLength
            if trailingLength > 0 {
                let trailingRange = NSRange(location: update.range.location + update.trimmedLength, length: trailingLength)
                // Explicitly clear underline styling on the trailing punctuation run so UITextView
                // does not visually carry link styling one character too far.
                attributed.addAttribute(.underlineStyle, value: 0, range: trailingRange)
            }
        }
    }

    private static func stripDetectedLinks(from attributed: NSAttributedString) -> NSAttributedString {
        guard let detector = detectedLinkStripper else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.string.utf16.count)
        let matches = detector.matches(in: mutable.string, options: [], range: fullRange)
        for match in matches.reversed() {
            guard match.resultType == .link else { continue }
            mutable.replaceCharacters(in: match.range, with: "")
        }

        func isTrimmable(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while let first = mutable.string.unicodeScalars.first, isTrimmable(first) {
            mutable.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        }
        while let last = mutable.string.unicodeScalars.last, isTrimmable(last) {
            let len = mutable.string.utf16.count
            guard len > 0 else { break }
            mutable.replaceCharacters(in: NSRange(location: len - 1, length: 1), with: "")
        }

        if mutable.string.contains("\n\n\n") {
            let regex = try? NSRegularExpression(pattern: "\n{3,}", options: [])
            let range = NSRange(location: 0, length: mutable.string.utf16.count)
            regex?.replaceMatches(in: mutable.mutableString, options: [], range: range, withTemplate: "\n\n")
        }

        return mutable
    }

    private static func applyMarkHighlights(nsAttributed: NSMutableAttributedString, color: UIColor) {
        let text = nsAttributed.string as NSString
        let openToken = markOpenSentinel as NSString
        let closeToken = markCloseSentinel as NSString

        var pairs: [(open: NSRange, close: NSRange)] = []
        var searchStart = 0

        while searchStart < text.length {
            let openRange = text.range(of: openToken as String, options: [], range: NSRange(location: searchStart, length: text.length - searchStart))
            if openRange.location == NSNotFound { break }

            let closeSearchStart = openRange.location + openRange.length
            if closeSearchStart >= text.length { break }

            let closeRange = text.range(of: closeToken as String, options: [], range: NSRange(location: closeSearchStart, length: text.length - closeSearchStart))
            if closeRange.location == NSNotFound { break }

            pairs.append((open: openRange, close: closeRange))
            searchStart = closeRange.location + closeRange.length
        }

        for pair in pairs.reversed() {
            let contentStart = pair.open.location + pair.open.length
            let contentLength = pair.close.location - contentStart
            if contentLength > 0 {
                nsAttributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: contentStart, length: contentLength))
            }
            nsAttributed.deleteCharacters(in: pair.close)
            nsAttributed.deleteCharacters(in: pair.open)
        }
    }

    private static func preprocessMarkHighlightSyntax(_ markdown: String) -> String {
        let characters = Array(markdown)
        guard characters.count >= 4 else { return markdown }

        var delimiterPositions: [Int] = []
        var index = 0
        var inFence = false
        var inlineCodeDelimiterLength: Int?
        var isLineStart = true

        while index < characters.count {
            let character = characters[index]

            if character == "\n" {
                isLineStart = true
                index += 1
                continue
            }

            if character == "`" {
                let tickCount = countConsecutiveBackticks(characters, from: index)

                if inlineCodeDelimiterLength == nil && tickCount >= 3 && isLineStart {
                    inFence.toggle()
                    index += tickCount
                    isLineStart = false
                    continue
                }

                if !inFence {
                    if let delimiterLength = inlineCodeDelimiterLength {
                        if tickCount == delimiterLength {
                            inlineCodeDelimiterLength = nil
                            index += tickCount
                            isLineStart = false
                            continue
                        }
                    } else {
                        inlineCodeDelimiterLength = tickCount
                        index += tickCount
                        isLineStart = false
                        continue
                    }
                }

                index += tickCount
                isLineStart = false
                continue
            }

            if !inFence,
               inlineCodeDelimiterLength == nil,
               character == "=",
               index + 1 < characters.count,
               characters[index + 1] == "=" {
                delimiterPositions.append(index)
                index += 2
                isLineStart = false
                continue
            }

            if character != " " && character != "\t" && character != "\r" {
                isLineStart = false
            }
            index += 1
        }

        var pairs: [(open: Int, close: Int)] = []
        var open: Int?
        for delimiter in delimiterPositions {
            if let start = open {
                let contentStart = start + 2
                if delimiter > contentStart {
                    pairs.append((open: start, close: delimiter))
                    open = nil
                } else {
                    open = delimiter
                }
            } else {
                open = delimiter
            }
        }

        guard !pairs.isEmpty else { return markdown }

        var replacements: [Int: String] = [:]
        replacements.reserveCapacity(pairs.count * 2)
        for pair in pairs {
            replacements[pair.open] = markOpenSentinel
            replacements[pair.close] = markCloseSentinel
        }

        var output = String()
        output.reserveCapacity(markdown.count)
        index = 0
        while index < characters.count {
            if let replacement = replacements[index] {
                output.append(replacement)
                index += 2
            } else {
                output.append(characters[index])
                index += 1
            }
        }

        return output
    }

    private static func normalizeOrderedListMarkers(in markdown: String) -> String {
        let linePattern = #"^([ \t>]*)(\d{1,9})([.)])([ \t]+)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: linePattern) else { return markdown }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var normalized: [String] = []
        normalized.reserveCapacity(lines.count)

        var inFence = false
        var activeListKey: String?
        var nextOrderedValue: Int?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                activeListKey = nil
                nextOrderedValue = nil
                normalized.append(line)
                continue
            }

            if inFence {
                normalized.append(line)
                continue
            }

            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.range.location != NSNotFound else {
                if trimmed.isEmpty {
                    normalized.append(line)
                    continue
                }

                // Keep active list context through indented continuation lines.
                if activeListKey != nil,
                   let leadingScalar = line.unicodeScalars.first,
                   CharacterSet.whitespacesAndNewlines.contains(leadingScalar) {
                    normalized.append(line)
                    continue
                }

                activeListKey = nil
                nextOrderedValue = nil
                normalized.append(line)
                continue
            }

            let prefix = nsLine.substring(with: match.range(at: 1))
            let rawNumber = nsLine.substring(with: match.range(at: 2))
            let delimiter = nsLine.substring(with: match.range(at: 3))
            let spacing = nsLine.substring(with: match.range(at: 4))
            let content = nsLine.substring(with: match.range(at: 5))

            let key = orderedListContextKey(prefix: prefix, delimiter: delimiter)
            let startValue = Int(rawNumber) ?? 1
            let value: Int
            if activeListKey == key, let nextOrderedValue {
                value = nextOrderedValue
            } else {
                value = startValue
            }

            activeListKey = key
            nextOrderedValue = value + 1
            normalized.append("\(prefix)\(value)\(delimiter)\(spacing)\(content)")
        }

        return normalized.joined(separator: "\n")
    }

    private static func orderedListContextKey(prefix: String, delimiter: String) -> String {
        var blockQuoteDepth = 0
        var indentColumns = 0

        for scalar in prefix.unicodeScalars {
            if scalar == ">" {
                blockQuoteDepth += 1
                continue
            }
            if scalar == "\t" {
                indentColumns += 4
                continue
            }
            if CharacterSet.whitespaces.contains(scalar) {
                indentColumns += 1
            }
        }

        // Group into coarse list-depth bands so harmless spacing variation doesn't reset numbering.
        let indentLevel = indentColumns / 2
        return "\(blockQuoteDepth)|\(indentLevel)|\(delimiter)"
    }

    private static func countConsecutiveBackticks(_ characters: [Character], from start: Int) -> Int {
        var count = 0
        var index = start
        while index < characters.count, characters[index] == "`" {
            count += 1
            index += 1
        }
        return count
    }

    private static func applyHeadingStyles(markdown: String,
                                           nsAttributed: NSMutableAttributedString,
                                           baseFont: UIFont) {
        let headings = extractMarkdownHeadings(markdown)
        guard !headings.isEmpty else { return }

        let fullText = nsAttributed.string as NSString
        var searchStart = 0

        for heading in headings {
            let target = heading.text
            guard !target.isEmpty else { continue }

            var foundRange: NSRange?
            while searchStart < fullText.length {
                let searchRange = NSRange(location: searchStart, length: fullText.length - searchStart)
                let range = fullText.range(of: target, options: [], range: searchRange)
                if range.location == NSNotFound { break }

                let isLineStart = (range.location == 0) || (fullText.substring(with: NSRange(location: range.location - 1, length: 1)) == "\n")
                if isLineStart {
                    foundRange = range
                    break
                }
                searchStart = range.location + range.length
            }

            guard let range = foundRange else { continue }

            let role: ClawlineTextRole
            switch heading.level {
            case 1:
                role = .sectionHeader
            case 2:
                role = .subsectionHeader
            case 3:
                role = .shortMessage
            case 4:
                role = .mediumMessage
            case 5:
                role = .uiLabel
            default:
                role = .secondaryLabel
            }

            let headingFont = UIFont.clawline(role)
            nsAttributed.addAttribute(.font, value: headingFont, range: range)
            searchStart = range.location + range.length
        }
    }

    private struct HeadingInfo {
        let level: Int
        let text: String
    }

    private static func extractMarkdownHeadings(_ markdown: String) -> [HeadingInfo] {
        markdown
            .components(separatedBy: .newlines)
            .compactMap { line -> HeadingInfo? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                var level = 0
                for char in trimmed {
                    if char == "#" {
                        level += 1
                    } else {
                        break
                    }
                }

                guard level > 0, level <= 6 else { return nil }
                let hashEndIndex = trimmed.index(trimmed.startIndex, offsetBy: level)
                guard hashEndIndex < trimmed.endIndex,
                      trimmed[hashEndIndex] == " " else {
                    return nil
                }

                let textStart = trimmed.index(after: hashEndIndex)
                let text = String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }

                return HeadingInfo(level: level, text: text)
            }
    }
}
