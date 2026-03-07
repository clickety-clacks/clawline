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
    }

    private let auth: any AuthManaging
    private let tlsSessionFactory: any ProviderTLSSessionFactoring
    private let baseURLProvider: () -> URL?
    private let sessionStateQueue = DispatchQueue(label: "co.clicketyclacks.Clawline.upload-session")
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private var currentSession: ProviderManagedSession?
    private var policyChangeObserver: NSObjectProtocol?

    init(auth: any AuthManaging,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         tlsSessionFactory: any ProviderTLSSessionFactoring,
         requestTimeout: TimeInterval = 60,
         resourceTimeout: TimeInterval = 600) {
        self.auth = auth
        self.baseURLProvider = baseURLProvider
        self.tlsSessionFactory = tlsSessionFactory
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.policyChangeObserver = NotificationCenter.default.addObserver(
            forName: tlsSessionFactory.policyChangeNotificationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateCurrentSession()
        }
    }

    deinit {
        if let policyChangeObserver {
            NotificationCenter.default.removeObserver(policyChangeObserver)
        }
        invalidateCurrentSession()
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

        let session = currentFreshSession()
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

    private func currentFreshSession() -> URLSession {
        sessionStateQueue.sync {
            if let currentSession, currentSession.generation == tlsSessionFactory.currentGeneration {
                return currentSession.session
            }

            let staleSession = currentSession
            let freshSession = tlsSessionFactory.makeSession(
                role: .upload,
                timeoutIntervalForRequest: requestTimeout,
                timeoutIntervalForResource: resourceTimeout
            )
            currentSession = freshSession
            staleSession?.session.invalidateAndCancel()
            return freshSession.session
        }
    }

    private func invalidateCurrentSession() {
        sessionStateQueue.sync {
            let staleSession = currentSession
            currentSession = nil
            staleSession?.session.invalidateAndCancel()
        }
    }

#if DEBUG
    func debugPrepareSessionForTesting() {
        _ = currentFreshSession()
    }
#endif

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

}
