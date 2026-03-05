//
//  LinkCardMetadataFetcher.swift
//  Clawline
//
//  Fetches lightweight OpenGraph metadata for URL link cards in chat bubbles.
//

import Foundation
import OSLog

struct LinkCardMetadata: Equatable {
    let url: URL
    let resolvedURL: URL
    let title: String
    let description: String?
    let imageURL: URL?
}

actor LinkCardMetadataFetcher {
    static let shared = LinkCardMetadataFetcher()

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "LinkCardMetadata")
    private var cache: [String: LinkCardMetadata] = [:]
    private var inFlight: [String: Task<LinkCardMetadata?, Never>] = [:]

    func metadata(for url: URL) async -> LinkCardMetadata? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task { [logger] in
            let result = await Self.fetch(url: url, logger: logger)
            return result
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        if let value { cache[key] = value }
        return value
    }

    private static func fetch(url: URL, logger: Logger) async -> LinkCardMetadata? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)

        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)

            guard let http = response as? HTTPURLResponse else {
                logger.error("link_card_metadata_fetch_failed url=\(url.absoluteString, privacy: .public) reason=non_http_response elapsed_ms=\(elapsedMS, privacy: .public)")
                return nil
            }

            guard (200..<400).contains(http.statusCode) else {
                logger.error("link_card_metadata_fetch_failed url=\(url.absoluteString, privacy: .public) status=\(http.statusCode, privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public)")
                return nil
            }

            let mime = http.mimeType?.lowercased() ?? ""
            if !mime.isEmpty, !(mime.hasPrefix("text/html") || mime.hasPrefix("application/xhtml")) {
                logger.error("link_card_metadata_fetch_failed url=\(url.absoluteString, privacy: .public) reason=non_html_mime mime=\(mime, privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public)")
                return nil
            }

            let encoding = String.Encoding.from(httpResponse: http) ?? .utf8
            guard var html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) else {
                logger.error("link_card_metadata_fetch_failed url=\(url.absoluteString, privacy: .public) reason=decode_failed elapsed_ms=\(elapsedMS, privacy: .public)")
                return nil
            }

            // Parsing doesn't need the whole document; keep a small prefix for performance.
            if html.count > 200_000 {
                html = String(html.prefix(200_000))
            }

            let resolvedURL = response.url ?? url
            let baseURL = URL(string: resolvedURL.deletingLastPathComponent().absoluteString + "/") ?? resolvedURL

            let meta = OpenGraphParser.parse(html: html, baseURL: baseURL)
            let title = (meta.title ?? meta.fallbackTitle)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? resolvedURL.absoluteString

            let desc = meta.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalDesc = (desc?.isEmpty == false) ? desc : nil

            let metadata = LinkCardMetadata(
                url: url,
                resolvedURL: resolvedURL,
                title: finalTitle,
                description: finalDesc,
                imageURL: meta.imageURL
            )
            logger.debug("link_card_metadata_ok url=\(url.absoluteString, privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public)")
            return metadata
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.error("link_card_metadata_fetch_failed url=\(url.absoluteString, privacy: .public) reason=network_error error=\(String(describing: error), privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public)")
            return nil
        }
    }
}

private struct OpenGraphParseResult {
    let title: String?
    let description: String?
    let imageURL: URL?
    let fallbackTitle: String?
}

private enum OpenGraphParser {
    nonisolated static func parse(html: String, baseURL: URL) -> OpenGraphParseResult {
        let headPrefix: String = {
            if let range = html.range(of: "</head>", options: [.caseInsensitive]) {
                return String(html[..<range.lowerBound])
            }
            return String(html.prefix(80_000))
        }()

        func metaContent(keys: [String]) -> String? {
            for key in keys {
                if let value = firstMetaContent(in: headPrefix, key: key) {
                    return decodeHTMLEntities(value)
                }
            }
            return nil
        }

        let ogTitle = metaContent(keys: ["og:title", "twitter:title"])
        let ogDesc = metaContent(keys: ["og:description", "twitter:description", "description"])
        let ogImage = metaContent(keys: ["og:image", "twitter:image"])

        let titleTag = firstTitleTag(in: headPrefix).map(decodeHTMLEntities)
        let imageURL = ogImage.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }

        return OpenGraphParseResult(
            title: ogTitle,
            description: ogDesc,
            imageURL: imageURL,
            fallbackTitle: titleTag
        )
    }

    nonisolated private static func firstTitleTag(in html: String) -> String? {
        let pattern = #"<title[^>]*>\s*([^<]{1,300})\s*</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[r])
    }

    nonisolated private static func firstMetaContent(in html: String, key: String) -> String? {
        // Handle both orders:
        // <meta property="og:title" content="...">
        // <meta content="..." property="og:title">
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            #"<meta\b[^>]*(?:property|name)\s*=\s*['"]\#(escaped)['"][^>]*content\s*=\s*['"]([^'"]{1,500})['"][^>]*>"#,
            #"<meta\b[^>]*content\s*=\s*['"]([^'"]{1,500})['"][^>]*(?:property|name)\s*=\s*['"]\#(escaped)['"][^>]*>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: html) {
                return String(html[r])
            }
        }
        return nil
    }
}

nonisolated private func decodeHTMLEntities(_ input: String) -> String {
    var s = input
    let replacements: [(String, String)] = [
        ("&amp;", "&"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&nbsp;", " ")
    ]
    for (from, to) in replacements {
        s = s.replacingOccurrences(of: from, with: to)
    }
    return s
}

private extension String.Encoding {
    nonisolated static func from(httpResponse response: HTTPURLResponse) -> String.Encoding? {
        guard let name = response.textEncodingName else { return nil }
        let cfName = name as CFString
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(cfName)
        if cfEnc == kCFStringEncodingInvalidId { return nil }
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        let enc = String.Encoding(rawValue: nsEnc)
        return enc
    }
}
