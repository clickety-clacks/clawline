//
//  URLSessionWebSocketConnector.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import OSLog
import CryptoKit

private let webSocketLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "WebSocketConnector")

final class URLSessionWebSocketConnector: WebSocketConnecting {
    private let session: URLSession
    private let sessionDelegate: URLSessionDelegate
    private let connectTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    init(connectTimeout: TimeInterval = 20,
         resourceTimeout: TimeInterval = 360,
         tlsPolicyProvider: @escaping () -> ProviderTLSPolicy = { ProviderTLSSettingsStore.policy }) {
        self.connectTimeout = connectTimeout
        self.resourceTimeout = resourceTimeout
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = connectTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        let delegate = ProviderWebSocketTLSSessionDelegate(policyProvider: tlsPolicyProvider)
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        webSocketLogger.debug("URLSessionWebSocketConnector connecting to \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.timeoutInterval = connectTimeout
        if request.value(forHTTPHeaderField: "Origin") == nil {
            request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketClient(task: task)
    }
}

final class ProviderWebSocketTLSSessionDelegate: NSObject, URLSessionDelegate {
    private let policyProvider: () -> ProviderTLSPolicy

    init(policyProvider: @escaping () -> ProviderTLSPolicy) {
        self.policyProvider = policyProvider
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let policy = policyProvider()
        if let pinned = policy.pinnedLeafCertificateSHA256 {
            if Self.matchesPinnedLeafSHA256(serverTrust: serverTrust, pinned: pinned) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        if policy.trustSelfSignedCertificates {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    private static func matchesPinnedLeafSHA256(serverTrust: SecTrust, pinned: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        let data = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: data)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return fingerprint == pinned
    }
}

private final class URLSessionWebSocketClient: WebSocketClient {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var receiveTask: Task<Void, Never>?
    private(set) var lastCloseInfo: WebSocketCloseInfo?

    init(task: URLSessionWebSocketTask) {
        self.task = task
        var continuation: AsyncStream<String>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        startReceiving()
    }

    var incomingTextMessages: AsyncStream<String> { stream }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {
        lastCloseInfo = WebSocketCloseInfo(code: Int((code ?? .normalClosure).rawValue), reason: nil)
        task.cancel(with: code ?? .normalClosure, reason: nil)
        receiveTask?.cancel()
        continuation.finish()
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        continuation.yield(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            continuation.yield(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    let rawCode = self.task.closeCode
                    let code = rawCode == .invalid ? nil : Int(rawCode.rawValue)
                    let reason: String? = {
                        guard let data = self.task.closeReason, !data.isEmpty else { return nil }
                        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                    }()
                    self.lastCloseInfo = WebSocketCloseInfo(code: code, reason: reason)
                    webSocketLogger.error("WS receive loop error: \(error.localizedDescription, privacy: .public)")
                    continuation.finish()
                    break
                }
            }
        }
    }
}
