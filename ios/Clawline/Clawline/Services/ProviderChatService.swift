//
//  ProviderChatService.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

final class ProviderChatService: ChatServicing {
    enum Error: Swift.Error, LocalizedError {
        case missingBaseURL
        case notConnected
        case authFailed(String)
        case tokenRevoked(String)
        case sessionReplaced
        case invalidMessageId
        case serverError(code: String, message: String?)

        var errorDescription: String? {
            switch self {
            case .missingBaseURL:
                return "No provider configured. Pair with a provider first."
            case .notConnected:
                return "Not connected to provider."
            case .authFailed(let reason):
                return "Authentication failed: \(reason)"
            case .tokenRevoked(let reason):
                return "Access revoked: \(reason)"
            case .sessionReplaced:
                return "Session replaced by another device."
            case .invalidMessageId:
                return "Client message IDs must start with c_."
            case .serverError(let code, let message):
                if let message, !message.isEmpty {
                    return message
                }
                return "Server error (\(code))."
            }
        }
    }

    private struct AuthPayload: Encodable {
        let type = "auth"
        let protocolVersion = 1
        let token: String
        let deviceId: String
        let lastMessageId: String?
    }

    private struct Envelope: Decodable {
        let type: String
    }

    private struct AuthResultPayload: Decodable {
        let type: String
        let success: Bool
        let reason: String?
    }

    private struct AckPayload: Decodable {
        let type: String
        let id: String
    }

    private struct ErrorPayload: Decodable {
        let type: String
        let code: String
        let message: String?
        let messageId: String?
    }

    private struct PendingMessage {
        let payload: ClientMessagePayload
        var retryTask: Task<Void, Never>?
    }

    private let connector: any WebSocketConnecting
    private let deviceId: String
    private let baseURLProvider: () -> URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let ackInterval: Duration = .seconds(5)

    private lazy var messageStream: AsyncStream<Message> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
        }
    }()

    private lazy var stateStream: AsyncStream<ConnectionState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(.disconnected)
        }
    }()

    private lazy var serviceEventStream: AsyncStream<ChatServiceEvent> = {
        AsyncStream { continuation in
            self.serviceEventContinuation = continuation
        }
    }()

    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var serviceEventContinuation: AsyncStream<ChatServiceEvent>.Continuation?
    private var socket: (any WebSocketClient)?
    private var receiveTask: Task<Void, Never>?
    private var authContinuation: CheckedContinuation<Void, Swift.Error>?
    private var pendingMessages: [String: PendingMessage] = [:]

    init(connector: any WebSocketConnecting,
         deviceId: String,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.connector = connector
        self.deviceId = deviceId
        self.baseURLProvider = baseURLProvider
        self.encoder = encoder
        self.decoder = decoder
    }

    var incomingMessages: AsyncStream<Message> { messageStream }
    var connectionState: AsyncStream<ConnectionState> { stateStream }
    var serviceEvents: AsyncStream<ChatServiceEvent> { serviceEventStream }

    func connect(token: String, lastMessageId: String?) async throws {
        guard let baseURL = baseURLProvider(),
              let wsURL = makeWebSocketURL(from: baseURL) else {
            throw Error.missingBaseURL
        }

        try await teardownConnection()

        stateContinuation?.yield(.connecting)
        let client = try await connector.connect(to: wsURL)
        socket = client
        startListening(on: client)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            authContinuation = continuation
            Task {
                do {
                    let authPayload = AuthPayload(
                        token: token,
                        deviceId: deviceId,
                        lastMessageId: lastMessageId
                    )
                    let data = try encoder.encode(authPayload)
                        guard let text = String(data: data, encoding: .utf8) else {
                            self.resolveAuthContinuation(with: .failure(Error.notConnected))
                            return
                        }
                        try await client.send(text: text)
                    } catch {
                        self.resolveAuthContinuation(with: .failure(error))
                    }
                }
            }
        }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close(with: .normalClosure)
        socket = nil
        pendingMessages.values.forEach { $0.retryTask?.cancel() }
        pendingMessages.removeAll()
        stateContinuation?.yield(.disconnected)
    }

    func send(id: String, content: String, attachments: [WireAttachment]) async throws {
        guard let socket else {
            throw Error.notConnected
        }
        guard id.hasPrefix("c_") else {
            throw Error.invalidMessageId
        }

        let payload = ClientMessagePayload(id: id, content: content, attachments: attachments)
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else { return }

        pendingMessages[id]?.retryTask?.cancel()
        let retryTask = scheduleRetry(for: payload)
        pendingMessages[id] = PendingMessage(payload: payload, retryTask: retryTask)

        try await socket.send(text: text)
    }

    // MARK: - Internal helpers

    private func makeWebSocketURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (components.scheme == "https" ? "wss" : "ws")
        if components.path.isEmpty || components.path == "/" {
            components.path = "/ws"
        } else if !components.path.hasSuffix("/ws") {
            components.path.append("/ws")
        }
        return components.url
    }

    private func startListening(on client: any WebSocketClient) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            var iterator = client.incomingTextMessages.makeAsyncIterator()
            while let text = await iterator.next() {
                handle(text: text)
            }
            handleSocketClose()
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            switch envelope.type {
            case "auth_result":
                handleAuthResult(data: data)
            case "message":
                handleMessage(data: data)
            case "ack":
                handleAck(data: data)
            case "error":
                handleServerError(data: data)
            default:
                break
            }
        }
    }

    private func handleAuthResult(data: Data) {
        guard let result = try? decoder.decode(AuthResultPayload.self, from: data) else { return }
        if result.success {
            resolveAuthContinuation(with: .success(()))
            stateContinuation?.yield(.connected)
        } else {
            let reason = result.reason ?? "Unknown error"
            resolveAuthContinuation(with: .failure(Error.authFailed(reason)))
            stateContinuation?.yield(.failed(Error.authFailed(reason)))
            disconnect()
        }
    }

    private func handleMessage(data: Data) {
        guard let payload = try? decoder.decode(ServerMessagePayload.self, from: data) else { return }
        let message = Message(payload: payload)
        messageContinuation?.yield(message)
    }

    private func handleAck(data: Data) {
        guard let payload = try? decoder.decode(AckPayload.self, from: data) else { return }
        if let pending = pendingMessages.removeValue(forKey: payload.id) {
            pending.retryTask?.cancel()
        }
    }

    private func handleServerError(data: Data) {
        guard let payload = try? decoder.decode(ErrorPayload.self, from: data) else { return }

        if let messageId = payload.messageId {
            if let pending = pendingMessages.removeValue(forKey: messageId) {
                pending.retryTask?.cancel()
            }
            serviceEventContinuation?.yield(.messageError(messageId: messageId, code: payload.code, message: payload.message))
            return
        }

        let message = payload.message ?? payload.code
        switch payload.code {
        case "auth_failed":
            let error = Error.authFailed(message)
            resolveAuthContinuation(with: .failure(error))
            stateContinuation?.yield(.failed(error))
            disconnect()
        case "token_revoked":
            let error = Error.tokenRevoked(message)
            resolveAuthContinuation(with: .failure(error))
            stateContinuation?.yield(.failed(error))
            disconnect()
        case "session_replaced":
            let error = Error.sessionReplaced
            stateContinuation?.yield(.failed(error))
            disconnect()
        default:
            stateContinuation?.yield(.failed(Error.serverError(code: payload.code, message: payload.message)))
        }
    }

    private func handleSocketClose() {
        resolveAuthContinuation(with: .failure(Error.notConnected))
        pendingMessages.values.forEach { $0.retryTask?.cancel() }
        pendingMessages.removeAll()
        stateContinuation?.yield(.disconnected)
    }

    private func teardownConnection() async throws {
        disconnect()
    }

    private func scheduleRetry(for payload: ClientMessagePayload) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: ackInterval)
                guard let socket = self.socket else { return }
                guard self.pendingMessages[payload.id] != nil else { return }
                if let data = try? self.encoder.encode(payload),
                   let text = String(data: data, encoding: .utf8) {
                    try? await socket.send(text: text)
                }
            }
        }
    }

    private func resolveAuthContinuation(with result: Result<Void, Swift.Error>) {
        guard let continuation = authContinuation else { return }
        authContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
