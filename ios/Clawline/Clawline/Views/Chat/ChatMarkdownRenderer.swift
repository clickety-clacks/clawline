//
//  ChatMarkdownRenderer.swift
//  Clawline
//
//  Shared markdown rendering for chat bubbles and expanded message sheet.
//

import Foundation
import UIKit

enum ChatMarkdownRenderer {
    private static let markOpenSentinel = "\u{F0000}"
    private static let markCloseSentinel = "\u{F0001}"

    static func renderAttributedString(markdown: String,
                                       baseFont: UIFont,
                                       inkColor: UIColor,
                                       lineSpacing: CGFloat,
                                       markHighlightColor: UIColor? = nil) -> AttributedString? {
        guard let ns = renderNSAttributedString(
            markdown: markdown,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            markHighlightColor: markHighlightColor
        ) else {
            return nil
        }
        return AttributedString(ns)
    }

    static func renderNSAttributedString(markdown: String,
                                         baseFont: UIFont,
                                         inkColor: UIColor,
                                         lineSpacing: CGFloat,
                                         markHighlightColor: UIColor? = nil) -> NSAttributedString? {
        let parsedMarkdown: String
        if markHighlightColor != nil {
            parsedMarkdown = preprocessMarkHighlightSyntax(markdown)
        } else {
            parsedMarkdown = markdown
        }

        // UIKit rendering relies on concrete line breaks in the backing string. Ordered lists parsed
        // with `.full` collapse separators into presentation intents, which become run-on text.
        let hasOrderedListSyntax = parsedMarkdown.range(
            of: #"(?m)^\s*\d+\.\s+"#,
            options: .regularExpression
        ) != nil

        // Prefer full parsing (block syntax like headings), but keep list separators intact.
        let attributed: AttributedString
        if hasOrderedListSyntax,
           let inline = try? AttributedString(markdown: parsedMarkdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attributed = inline
        } else if let full = try? AttributedString(markdown: parsedMarkdown, options: .init(interpretedSyntax: .full)) {
            attributed = full
        } else if let inline = try? AttributedString(markdown: parsedMarkdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
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

        // Preserve bold/italic/monospace traits while using the chat base font family.
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
                newFont = UIFont.systemFont(ofSize: size, weight: .bold)
            } else if traits.contains(.traitItalic) {
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    newFont = UIFont(descriptor: descriptor, size: size)
                }
            } else if traits.contains(.traitMonoSpace) {
                // Inline code runs: keep slightly smaller and add background fill.
                newFont = UIFont.monospacedSystemFont(ofSize: max(9, size - 1), weight: .medium)
                nsAttributed.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: range)
            }

            nsAttributed.addAttribute(.font, value: newFont, range: range)
        }

        // Ensure ATX heading levels (#..######) render visibly.
        applyHeadingStyles(markdown: parsedMarkdown, nsAttributed: nsAttributed, baseFont: baseFont)
        if let markHighlightColor {
            applyMarkHighlights(nsAttributed: nsAttributed, color: markHighlightColor)
        }

        return nsAttributed
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

            // Find the heading text at the start of a line to reduce false matches.
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

            let level = max(1, min(6, heading.level))
            let delta: CGFloat
            switch level {
            case 1: delta = 8
            case 2: delta = 6
            case 3: delta = 4
            case 4: delta = 2
            case 5: delta = 1
            default: delta = 0
            }

            let size = min(32, baseFont.pointSize + delta)
            let weight: UIFont.Weight = (level <= 2) ? .bold : .semibold
            nsAttributed.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: weight), range: range)

            searchStart = range.location + range.length
        }
    }

    private static func extractMarkdownHeadings(_ markdown: String) -> [(level: Int, text: String)] {
        var results: [(level: Int, text: String)] = []
        var inFence = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            // ATX headings: #..###### <text> (optionally closing with trailing #'s)
            guard line.hasPrefix("#") else { continue }

            var level = 0
            for ch in line {
                if ch == "#" { level += 1 } else { break }
            }
            guard level >= 1 && level <= 6 else { continue }

            let afterHashes = line.dropFirst(level)
            guard afterHashes.first == " " || afterHashes.first == "\t" else { continue }
            var text = afterHashes.trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip optional closing #'s: "### Title ###"
            if let hashIndex = text.firstIndex(of: "#") {
                let suffix = text[hashIndex...]
                if suffix.allSatisfy({ $0 == "#" || $0 == " " || $0 == "\t" }) {
                    text = text[..<hashIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            results.append((level: level, text: String(text)))
        }

        return results
    }
}
