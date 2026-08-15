import Foundation

enum MarkdownURLBoundarySanitizer {
    private static let trailingUnsafeCharacters = CharacterSet(charactersIn: "`\"“”‘’<>\\^{}|[]\u{F0000}\u{F0001}")
    private static let defaultBoundaryTokens = ["`", "%F3%B0%80%80", "%F3%B0%80%81"]

    static func validatedHTTPURL(from candidate: String) -> URL? {
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    static func sanitizedURL(from rawMatch: String, additionalBoundaryTokens: [String] = []) -> URL? {
        validatedHTTPURL(from: trimBoundarySuffix(from: rawMatch, additionalBoundaryTokens: additionalBoundaryTokens))
    }

    static func trimBoundarySuffix(from rawMatch: String, additionalBoundaryTokens: [String] = []) -> String {
        let candidate = trimTrailingUnsafeCharacters(from: rawMatch)
        var earliestBoundary: String.Index?

        if let markBoundary = earliestBalancedMarkBoundary(in: candidate) {
            earliestBoundary = markBoundary
        }

        for token in defaultBoundaryTokens + additionalBoundaryTokens {
            var searchRange = candidate.startIndex..<candidate.endIndex
            while let range = candidate.range(of: token, options: [], range: searchRange) {
                let prefix = String(candidate[..<range.lowerBound])
                if validatedHTTPURL(from: prefix) != nil {
                    earliestBoundary = earliestBoundary.map { min($0, range.lowerBound) } ?? range.lowerBound
                    break
                }
                searchRange = range.upperBound..<candidate.endIndex
            }
        }

        guard let earliestBoundary else { return candidate }
        return String(candidate[..<earliestBoundary])
    }

    private static func earliestBalancedMarkBoundary(in candidate: String) -> String.Index? {
        var earliestBoundary: String.Index?

        // "==" (mark highlight) must stay paired: a lone "==", such as base64 query-value
        // padding, is legitimate URL content and must not be trimmed.
        if let boundary = earliestBalancedPairBoundary(in: candidate, token: "==") {
            earliestBoundary = boundary
        }

        // "**" (emphasis) has no such legitimate-content exception here, and GFM autolink's own
        // trailing-punctuation trim can leave an unpaired "**" by the time it reaches us (e.g.
        // "html**URL" from "html**URL**"), so any occurrence after a valid URL is a boundary.
        if let boundary = earliestUnpairedBoundary(in: candidate, token: "**") {
            earliestBoundary = earliestBoundary.map { min($0, boundary) } ?? boundary
        }

        return earliestBoundary
    }

    private static func earliestBalancedPairBoundary(in candidate: String, token: String) -> String.Index? {
        var searchRange = candidate.startIndex..<candidate.endIndex

        while let openingRange = candidate.range(of: token, options: [], range: searchRange) {
            let prefix = String(candidate[..<openingRange.lowerBound])
            guard validatedHTTPURL(from: prefix) != nil else {
                searchRange = openingRange.upperBound..<candidate.endIndex
                continue
            }

            guard openingRange.upperBound < candidate.endIndex,
                  let closingRange = candidate.range(of: token, options: [], range: openingRange.upperBound..<candidate.endIndex),
                  closingRange.lowerBound > openingRange.upperBound else {
                return nil
            }

            return openingRange.lowerBound
        }

        return nil
    }

    private static func earliestUnpairedBoundary(in candidate: String, token: String) -> String.Index? {
        var searchRange = candidate.startIndex..<candidate.endIndex

        while let openingRange = candidate.range(of: token, options: [], range: searchRange) {
            let prefix = String(candidate[..<openingRange.lowerBound])
            if validatedHTTPURL(from: prefix) != nil {
                return openingRange.lowerBound
            }
            searchRange = openingRange.upperBound..<candidate.endIndex
        }

        return nil
    }

    private static func trimTrailingUnsafeCharacters(from rawMatch: String) -> String {
        var candidate = rawMatch
        while let last = candidate.last,
              last.unicodeScalars.allSatisfy({ trailingUnsafeCharacters.contains($0) }) {
            let trimmed = String(candidate.dropLast())
            guard !trimmed.isEmpty, URL(string: trimmed) != nil else { break }
            candidate = trimmed
        }
        return candidate
    }
}
