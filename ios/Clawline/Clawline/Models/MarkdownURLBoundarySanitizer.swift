import Foundation

enum MarkdownURLBoundarySanitizer {
    private static let trailingUnsafeCharacters = CharacterSet(charactersIn: "`\"“”‘’<>\\^{}|[]")
    private static let defaultBoundaryTokens = ["`"]

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
                    if earliestBoundary == nil || range.lowerBound < earliestBoundary! {
                        earliestBoundary = range.lowerBound
                    }
                    break
                }
                searchRange = range.upperBound..<candidate.endIndex
            }
        }

        guard let earliestBoundary else { return candidate }
        return String(candidate[..<earliestBoundary])
    }

    private static func earliestBalancedMarkBoundary(in candidate: String) -> String.Index? {
        var searchRange = candidate.startIndex..<candidate.endIndex

        while let openingRange = candidate.range(of: "==", options: [], range: searchRange) {
            let prefix = String(candidate[..<openingRange.lowerBound])
            guard validatedHTTPURL(from: prefix) != nil else {
                searchRange = openingRange.upperBound..<candidate.endIndex
                continue
            }

            guard openingRange.upperBound < candidate.endIndex,
                  let closingRange = candidate.range(of: "==", options: [], range: openingRange.upperBound..<candidate.endIndex),
                  closingRange.lowerBound > openingRange.upperBound else {
                return nil
            }

            return openingRange.lowerBound
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
