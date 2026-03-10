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

    private let tlsSessionFactory: any ProviderTLSSessionFactoring
    private let auth: any AuthManaging
    private let baseURLProvider: () -> URL?
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "UploadService")
    private let lock = NSLock()

    private var uploadSession: ProviderTLSSessionHandle?
    private var assetDownloadSession: ProviderTLSSessionHandle?
    private var policyObservation: ProviderTLSPolicyChangeObservation?

    init(auth: any AuthManaging,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         tlsSessionFactory: any ProviderTLSSessionFactoring = ProviderTLSSessionFactory()) {
        self.auth = auth
        self.baseURLProvider = baseURLProvider
        self.tlsSessionFactory = tlsSessionFactory
        self.policyObservation = tlsSessionFactory.addPolicyChangeObserver { [weak self] _ in
            self?.handlePolicyChange()
        }
    }

    deinit {
        if let policyObservation {
            tlsSessionFactory.removePolicyChangeObserver(policyObservation)
        }
        invalidateOwnedSessions(cancelTasks: true)
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

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await uploadURLSession().data(for: request)
        } catch {
            logger.error("asset upload request failed error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("asset upload returned non-HTTP response")
            throw AttachmentError.networkFailure
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

        let downloadURL = try makeDownloadURL(baseURL: baseURL, assetId: assetId)
        logger.info("asset download url=\(downloadURL.absoluteString, privacy: .public)")

        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await assetDownloadURLSession().data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttachmentError.networkFailure
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

    private func makeDownloadURL(baseURL: URL, assetId: String) throws -> URL {
        guard !assetId.isEmpty else {
            throw AttachmentError.invalidData
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AttachmentError.invalidData
        }
        guard let encodedAssetId = encodePathComponent(assetId) else {
            throw AttachmentError.invalidData
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/download/\(encodedAssetId)"
        guard let url = components.url else {
            throw AttachmentError.invalidData
        }
        return url
    }

    private func encodePathComponent(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func summarizeResponseBody(_ data: Data, maxLength: Int = 512) -> String {
        guard !data.isEmpty else { return "<empty>" }
        if let string = String(data: data.prefix(maxLength), encoding: .utf8) {
            return string.replacingOccurrences(of: "\n", with: "\\n")
        }
        return data.prefix(maxLength).base64EncodedString()
    }

    private func uploadURLSession() -> URLSession {
        session(for: .upload)
    }

    private func assetDownloadURLSession() -> URLSession {
        session(for: .assetDownload)
    }

    private func session(for role: ProviderTLSSessionRole) -> URLSession {
        let staleSession: URLSession?
        let resolvedSession: URLSession

        lock.lock()
        let currentGeneration = tlsSessionFactory.currentGeneration
        let currentHandle: ProviderTLSSessionHandle? = {
            switch role {
            case .upload:
                return uploadSession
            case .assetDownload:
                return assetDownloadSession
            case .webSocket:
                return nil
            }
        }()

        if let currentHandle, currentHandle.generation == currentGeneration {
            resolvedSession = currentHandle.session
            lock.unlock()
            return resolvedSession
        }

        staleSession = currentHandle?.session
        let freshHandle = tlsSessionFactory.makeSession(for: role)
        switch role {
        case .upload:
            uploadSession = freshHandle
        case .assetDownload:
            assetDownloadSession = freshHandle
        case .webSocket:
            break
        }
        resolvedSession = freshHandle.session
        lock.unlock()

        staleSession?.finishTasksAndInvalidate()
        return resolvedSession
    }

    private func handlePolicyChange() {
        invalidateOwnedSessions(cancelTasks: false)
    }

    private func invalidateOwnedSessions(cancelTasks: Bool) {
        let sessions: [URLSession]

        lock.lock()
        sessions = [uploadSession?.session, assetDownloadSession?.session].compactMap { $0 }
        uploadSession = nil
        assetDownloadSession = nil
        lock.unlock()

        sessions.forEach { session in
            if cancelTasks {
                session.invalidateAndCancel()
            } else {
                session.finishTasksAndInvalidate()
            }
        }
    }
}
