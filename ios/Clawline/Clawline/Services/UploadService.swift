//
//  UploadService.swift
//  Clawline
//
//  Created by Codex on 1/15/26.
//

import Foundation

final class UploadService: UploadServicing {
    private struct UploadResponse: Decodable {
        let assetId: String
    }

    private let session: URLSession
    private let auth: any AuthManaging
    private let baseURLProvider: @Sendable () -> URL?

    init(auth: any AuthManaging,
         baseURLProvider: @escaping @Sendable () -> URL? = { ProviderBaseURLStore.baseURL },
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

        var request = URLRequest(url: baseURL.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        let boundary = "Boundary-" + UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = makeMultipartBody(
            boundary: boundary,
            fieldName: "file",
            filename: sanitizeFilename(filename ?? makeDefaultFilename(for: mimeType), mimeType: mimeType),
            mimeType: mimeType,
            data: data
        )
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentError.networkFailure
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw AttachmentError.missingAuth
            }
            throw AttachmentError.uploadFailed
        }

        let decoded = try JSONDecoder().decode(UploadResponse.self, from: responseData)
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

        let safeAssetId = try validatedAssetId(assetId)
        let downloadURL = baseURL
            .appendingPathComponent("download")
            .appendingPathComponent(safeAssetId)

        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentError.networkFailure
        }
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

    private func validatedAssetId(_ assetId: String) throws -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?#")
        guard !assetId.isEmpty,
              assetId.rangeOfCharacter(from: disallowed) == nil,
              !assetId.contains("..")
        else {
            throw AttachmentError.invalidData
        }
        return assetId
    }
}
