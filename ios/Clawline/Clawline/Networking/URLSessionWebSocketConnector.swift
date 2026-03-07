//
//  URLSessionWebSocketConnector.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import OSLog

private let webSocketLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "WebSocketConnector")

final class URLSessionWebSocketConnector: WebSocketConnecting {
    private let tlsSessionFactory: any ProviderTLSSessionFactoring
    private let connectTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let sessionStateQueue = DispatchQueue(label: "co.clicketyclacks.Clawline.websocket-session")
    private var currentSession: ProviderManagedSession?
    private var activeTask: URLSessionWebSocketTask?
    private var policyChangeObserver: NSObjectProtocol?

    init(tlsSessionFactory: any ProviderTLSSessionFactoring,
         connectTimeout: TimeInterval = 20,
         resourceTimeout: TimeInterval = 360) {
        self.tlsSessionFactory = tlsSessionFactory
        self.connectTimeout = connectTimeout
        self.resourceTimeout = resourceTimeout
        self.policyChangeObserver = NotificationCenter.default.addObserver(
            forName: tlsSessionFactory.policyChangeNotificationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handlePolicyChange()
        }
    }

    deinit {
        if let policyChangeObserver {
            NotificationCenter.default.removeObserver(policyChangeObserver)
        }
        handlePolicyChange()
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        webSocketLogger.debug("URLSessionWebSocketConnector connecting to \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.timeoutInterval = connectTimeout
        if request.value(forHTTPHeaderField: "Origin") == nil {
            request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")
        }

        let session = currentFreshSession()
        let task = session.webSocketTask(with: request)
        sessionStateQueue.sync {
            activeTask = task
        }
        task.resume()
        return URLSessionWebSocketClient(task: task) { [weak self, weak task] in
            self?.clearActiveTask(task)
        }
    }

    private func currentFreshSession() -> URLSession {
        sessionStateQueue.sync {
            if let currentSession, currentSession.generation == tlsSessionFactory.currentGeneration {
                return currentSession.session
            }

            let staleSession = currentSession
            let freshSession = tlsSessionFactory.makeSession(
                role: .webSocket,
                timeoutIntervalForRequest: connectTimeout,
                timeoutIntervalForResource: resourceTimeout
            )
            currentSession = freshSession
            staleSession?.session.invalidateAndCancel()
            return freshSession.session
        }
    }

    private func handlePolicyChange() {
        sessionStateQueue.sync {
            let staleSession = currentSession
            currentSession = nil
            let staleTask = activeTask
            activeTask = nil
            staleSession?.session.invalidateAndCancel()
            staleTask?.cancel(with: .goingAway, reason: nil)
        }
    }

    private func clearActiveTask(_ task: URLSessionWebSocketTask?) {
        sessionStateQueue.sync {
            guard activeTask === task else { return }
            activeTask = nil
        }
    }

#if DEBUG
    func debugHasActiveTaskForTesting() -> Bool {
        sessionStateQueue.sync {
            activeTask != nil
        }
    }
#endif
}

private final class URLSessionWebSocketClient: WebSocketClient {
    private let task: URLSessionWebSocketTask
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let onClose: () -> Void
    private var receiveTask: Task<Void, Never>?
    private(set) var lastCloseInfo: WebSocketCloseInfo?

    init(task: URLSessionWebSocketTask, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
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
        onClose()
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
                    onClose()
                    break
                }
            }
        }
    }
}
