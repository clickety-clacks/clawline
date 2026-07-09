//
//  UploadService.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import Foundation
import OSLog

final class UploadService: UploadServicing {
    private struct UploadResponse: Decodable {
        let assetId: String
        let mimeType: String?
    }

    private let session: URLSession
    private let auth: any AuthManaging
    private let baseURLProvider: () -> URL?
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "UploadService")

    init(auth: any AuthManaging,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         session: URLSession = .shared) {
        self.auth = auth
        self.baseURLProvider = baseURLProvider
        self.session = session
    }

    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
        try Task.checkCancellation()
        guard let baseURL = baseURLProvider() else {
            throw AttachmentError.missingBaseURL
        }
        guard let token = auth.token else {
            throw AttachmentError.missingAuth
        }

        let boundary = "Boundary-" + UUID().uuidString
        let body = makeMultipartBody(
            boundary: boundary,
            fieldName: "file",
            filename: sanitizeFilename(filename ?? makeDefaultFilename(for: mimeType), mimeType: mimeType),
            mimeType: mimeType,
            data: data
        )

        let (responseData, httpResponse) = try await performWithTransportFallback(baseURL: baseURL) { apiBase in
            var request = URLRequest(url: ProviderHTTPURLResolver.uploadURL(fromAPIBase: apiBase))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            return request
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.error(
                "asset upload failed status=\(httpResponse.statusCode, privacy: .public) body=\(self.summarizeResponseBody(responseData), privacy: .public)"
            )
            if httpResponse.statusCode == 401 {
                throw AttachmentError.missingAuth
            }
            throw AttachmentError.uploadFailed
        }

        let decoded: UploadResponse
        do {
            decoded = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        } catch {
            logger.error(
                "asset upload decode failed status=\(httpResponse.statusCode, privacy: .public) body=\(self.summarizeResponseBody(responseData), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        if let storedMimeType = decoded.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !storedMimeType.isEmpty {
            logger.info("asset upload stored mimeType=\(storedMimeType, privacy: .public)")
            if !storedMimeType.lowercased().hasPrefix("image/") {
                logger.warning(
                    "asset upload stored non-image mimeType=\(storedMimeType, privacy: .public) assetId=\(decoded.assetId, privacy: .public)"
                )
            }
        } else {
            logger.warning("asset upload response missing mimeType assetId=\(decoded.assetId, privacy: .public)")
        }
        return decoded.assetId
    }

    func download(assetId: String) async throws -> Data {
        try Task.checkCancellation()
        guard let baseURL = baseURLProvider() else {
            throw AttachmentError.missingBaseURL
        }
        guard let token = auth.token else {
            throw AttachmentError.missingAuth
        }

        let (data, httpResponse) = try await performWithTransportFallback(baseURL: baseURL) { apiBase in
            let downloadURL = try ProviderHTTPURLResolver.downloadURL(fromAPIBase: apiBase, assetId: assetId)
            self.logger.info("asset download url=\(downloadURL.absoluteString, privacy: .public)")
            var request = URLRequest(url: downloadURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        logger.info("asset download status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 {
                throw AttachmentError.invalidData
            }
            if httpResponse.statusCode == 401 {
                throw AttachmentError.missingAuth
            }
            throw AttachmentError.networkFailure
        }
        return data
    }

    // Last transport candidate that produced an HTTP response; tried first on
    // subsequent requests so a working direct-HTTP fallback is not re-penalized
    // by a dead or incomplete HTTPS front on every call.
    private var stickyAPIBaseURL: URL?

    private func performWithTransportFallback(
        baseURL: URL,
        makeRequest: (URL) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var candidates = ProviderHTTPURLResolver.apiBaseURLCandidates(from: baseURL)
        if let sticky = stickyAPIBaseURL, let stickyIndex = candidates.firstIndex(of: sticky), stickyIndex > 0 {
            candidates.swapAt(0, stickyIndex)
        }

        var lastError: Swift.Error?
        for (index, apiBase) in candidates.enumerated() {
            let isLastCandidate = index == candidates.count - 1
            let request = try makeRequest(apiBase)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                if error.code == .cancelled { throw error }
                logger.error("asset transport failed base=\(apiBase.absoluteString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                lastError = error
                if isLastCandidate { break }
                continue
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("asset transport returned non-HTTP response")
                throw AttachmentError.networkFailure
            }
            if !isLastCandidate,
               ProviderHTTPURLResolver.isTransportGapResponse(statusCode: httpResponse.statusCode, data: data) {
                logger.error("asset transport gap base=\(apiBase.absoluteString, privacy: .public) status=\(httpResponse.statusCode, privacy: .public)")
                lastError = AttachmentError.networkFailure
                continue
            }
            stickyAPIBaseURL = apiBase
            return (data, httpResponse)
        }

        throw lastError ?? AttachmentError.networkFailure
    }

    private func makeMultipartBody(boundary: String,
                                   fieldName: String,
                                   filename: String,
                                   mimeType: String,
                                   data: Data) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        if let boundaryData = "--\(boundary)\r\n".data(using: .utf8) {
            body.append(boundaryData)
        }
        if let disposition = "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8) {
            body.append(disposition)
        }
        if let typeLine = "Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8) {
            body.append(typeLine)
        }
        body.append(data)
        if let breakData = lineBreak.data(using: .utf8) {
            body.append(breakData)
        }
        if let closing = "--\(boundary)--\r\n".data(using: .utf8) {
            body.append(closing)
        }
        return body
    }

    private func makeDefaultFilename(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "attachment.png"
        case "image/jpeg", "image/jpg":
            return "attachment.jpg"
        case "image/gif":
            return "attachment.gif"
        case "image/webp":
            return "attachment.webp"
        case "image/heic":
            return "attachment.heic"
        default:
            return "attachment.bin"
        }
    }

    private func sanitizeFilename(_ filename: String, mimeType: String) -> String {
        let disallowed = CharacterSet(charactersIn: "\"\\\r\n;")
        let filteredScalars = filename.unicodeScalars.filter { !disallowed.contains($0) }
        let cleaned = String(filteredScalars.map(Character.init))
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return makeDefaultFilename(for: mimeType) }
        return trimmed
    }

    private func summarizeResponseBody(_ data: Data, maxLength: Int = 512) -> String {
        guard !data.isEmpty else { return "<empty>" }
        if let string = String(data: data.prefix(maxLength), encoding: .utf8) {
            return string.replacingOccurrences(of: "\n", with: "\\n")
        }
        return data.prefix(maxLength).base64EncodedString()
    }
}
