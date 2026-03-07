//
//  AssetDownloadService.swift
//  Clawline
//
//  Created by Codex on 3/7/26.
//

import Foundation
import OSLog

final class AssetDownloadService: AssetDownloading {
    private let auth: any AuthManaging
    private let tlsSessionFactory: any ProviderTLSSessionFactoring
    private let baseURLProvider: () -> URL?
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "AssetDownloadService")
    private let sessionStateQueue = DispatchQueue(label: "co.clicketyclacks.Clawline.asset-download-session")
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private var currentSession: ProviderManagedSession?
    private var policyChangeObserver: NSObjectProtocol?

    init(auth: any AuthManaging,
         tlsSessionFactory: any ProviderTLSSessionFactoring,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         requestTimeout: TimeInterval = 60,
         resourceTimeout: TimeInterval = 600) {
        self.auth = auth
        self.tlsSessionFactory = tlsSessionFactory
        self.baseURLProvider = baseURLProvider
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

    func download(assetId: String) async throws -> Data {
        try Task.checkCancellation()
        guard let baseURL = baseURLProvider() else {
            throw AttachmentError.missingBaseURL
        }
        guard let token = auth.token else {
            throw AttachmentError.missingAuth
        }

        let downloadURL = try Self.makeDownloadURL(baseURL: baseURL, assetId: assetId)
        logger.info("asset download url=\(downloadURL.absoluteString, privacy: .public)")

        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let session = currentFreshSession()
        let (data, response) = try await session.data(for: request)
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

    private func currentFreshSession() -> URLSession {
        sessionStateQueue.sync {
            if let currentSession, currentSession.generation == tlsSessionFactory.currentGeneration {
                return currentSession.session
            }

            let staleSession = currentSession
            let freshSession = tlsSessionFactory.makeSession(
                role: .assetDownload,
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

    private static func makeDownloadURL(baseURL: URL, assetId: String) throws -> URL {
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

    private static func encodePathComponent(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
