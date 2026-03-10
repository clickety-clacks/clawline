//
//  URLSessionWebSocketConnector.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import OSLog

private let webSocketLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "WebSocketConnector")

protocol ProviderWebSocketTasking: AnyObject {
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var closeReason: Data? { get }

    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: ProviderWebSocketTasking {}

final class URLSessionWebSocketConnector: WebSocketConnecting {
    typealias WebSocketTaskFactory = (_ session: URLSession, _ request: URLRequest) -> any ProviderWebSocketTasking

    private let tlsSessionFactory: any ProviderTLSSessionFactoring
    private let connectTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let webSocketTaskFactory: WebSocketTaskFactory
    private let lock = NSLock()

    private var currentSession: ProviderTLSSessionHandle?
    private var activeTasks: [UUID: any ProviderWebSocketTasking] = [:]
    private var policyObservation: ProviderTLSPolicyChangeObservation?

    init(connectTimeout: TimeInterval = 20,
         resourceTimeout: TimeInterval = 360,
         tlsSessionFactory: any ProviderTLSSessionFactoring = ProviderTLSSessionFactory(),
         webSocketTaskFactory: @escaping WebSocketTaskFactory = { session, request in
             session.webSocketTask(with: request)
         }) {
        self.tlsSessionFactory = tlsSessionFactory
        self.connectTimeout = connectTimeout
        self.resourceTimeout = resourceTimeout
        self.webSocketTaskFactory = webSocketTaskFactory
        self.policyObservation = tlsSessionFactory.addPolicyChangeObserver { [weak self] _ in
            self?.handlePolicyChange()
        }
    }

    deinit {
        if let policyObservation {
            tlsSessionFactory.removePolicyChangeObserver(policyObservation)
        }

        let sessionsAndTasks: (URLSession?, [any ProviderWebSocketTasking])
        lock.lock()
        sessionsAndTasks = (currentSession?.session, Array(activeTasks.values))
        currentSession = nil
        activeTasks.removeAll()
        lock.unlock()

        sessionsAndTasks.1.forEach { $0.cancel(with: .normalClosure, reason: nil) }
        sessionsAndTasks.0?.invalidateAndCancel()
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        webSocketLogger.debug("URLSessionWebSocketConnector connecting to \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.timeoutInterval = connectTimeout
        if request.value(forHTTPHeaderField: "Origin") == nil {
            request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")
        }
        let taskID = UUID()
        var staleSession: URLSession?
        let client: URLSessionWebSocketClient = try tlsSessionFactory.withTaskStartBoundary(
            for: .webSocket(
                connectTimeout: connectTimeout,
                resourceTimeout: resourceTimeout
            ),
            current: currentSessionSnapshot()
        ) { [self] handle, replacedSession in
            staleSession = replacedSession
            let task = webSocketTaskFactory(handle.session, request)
            registerStarted(task: task, id: taskID, sessionHandle: handle)
            task.resume()
            return URLSessionWebSocketClient(task: task) { [weak self] in
                self?.unregisterTask(id: taskID)
            }
        }
        staleSession?.invalidateAndCancel()
        return client
    }

    private func currentSessionSnapshot() -> ProviderTLSSessionHandle? {
        lock.lock()
        let session = currentSession
        lock.unlock()
        return session
    }

    private func registerStarted(task: any ProviderWebSocketTasking, id: UUID, sessionHandle: ProviderTLSSessionHandle) {
        lock.lock()
        currentSession = sessionHandle
        activeTasks[id] = task
        lock.unlock()
    }

    private func unregisterTask(id: UUID) {
        lock.lock()
        activeTasks.removeValue(forKey: id)
        lock.unlock()
    }

    private func handlePolicyChange() {
        let sessionAndTasks: (URLSession?, [any ProviderWebSocketTasking])
        lock.lock()
        sessionAndTasks = (currentSession?.session, Array(activeTasks.values))
        currentSession = nil
        activeTasks.removeAll()
        lock.unlock()

        sessionAndTasks.1.forEach { $0.cancel(with: .goingAway, reason: nil) }
        sessionAndTasks.0?.invalidateAndCancel()
    }
}

private final class URLSessionWebSocketClient: WebSocketClient {
    private let task: any ProviderWebSocketTasking
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let onTermination: (() -> Void)?
    private var receiveTask: Task<Void, Never>?
    private(set) var lastCloseInfo: WebSocketCloseInfo?

    init(task: any ProviderWebSocketTasking, onTermination: (() -> Void)? = nil) {
        self.task = task
        self.onTermination = onTermination
        var continuation: AsyncStream<String>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        startReceiving()
    }

    deinit {
        onTermination?()
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
        onTermination?()
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
