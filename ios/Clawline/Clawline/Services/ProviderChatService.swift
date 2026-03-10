//
//  ProviderChatService.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation
import OSLog

private final class AsyncStreamBroadcaster<Element> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let lock = NSLock()

    func stream(initial: Element? = nil) -> AsyncStream<Element> {
        AsyncStream { [weak self] continuation in
            let id = UUID()
            self?.lock.lock()
            self?.continuations[id] = continuation
            self?.lock.unlock()
            if let initial {
                continuation.yield(initial)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.remove(id)
                }
            }
        }
    }

    func send(_ value: Element) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        current.forEach { $0.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

final class ProviderChatService: ChatServicing {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ProviderChatService")
    private let messageLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    enum Error: Swift.Error, LocalizedError {
        case missingBaseURL
        case notConnected
        case authFailed(String)
        case authTimeout
        case tokenRevoked(String)
        case sessionReplaced
        case invalidMessageId
        case serverError(code: String, message: String?)
        case policyViolation(code: Int, reason: String?)

        var errorDescription: String? {
            switch self {
            case .missingBaseURL:
                return "No provider configured. Pair with a provider first."
            case .notConnected:
                return "Could not send; not connected."
            case .authFailed(let reason):
                return "Authentication failed: \(reason)"
            case .authTimeout:
                return "Authentication timed out. Retrying..."
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
            case .policyViolation(_, let reason):
                if let reason, !reason.isEmpty {
                    return reason
                }
                return "Connection rejected by server."
            }
        }
    }

    private struct AuthPayload: Encodable {
        let type = "auth"
        let protocolVersion = 1
        let token: String
        let deviceId: String
        let lastMessageId: String?
        let clientFeatures: [String]?
        let client: ClientDescriptor
    }

    private struct ClientDescriptor: Encodable {
        /// Required by the gateway schema (connect params validation).
        /// Treated as an opaque identifier by the server.
        let id: String
        /// Optional capabilities advertised by the client. The server should ignore unknown values.
        let features: [String]?
    }

    private struct InteractiveCallbackOutboundPayload: Encodable {
        let type = "interactive-callback"
        let messageId: String
        let payload: Payload

        struct Payload: Encodable {
            let action: String
            let data: JSONValue?
        }
    }

    private struct Envelope: Decodable {
        let type: String
    }

    private struct AuthResultPayload: Decodable {
        let type: String
        let success: Bool
        let userId: String?
        let isAdmin: Bool?
        let dmScope: String?
        let features: [String]?
        let sessionKeys: [String]?
        let sessions: [SessionDescriptor]?
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

    private struct UserInfoPayload: Decodable {
        let type: String
        let userId: String
        let isAdmin: Bool
    }

    private struct SessionDescriptor: Decodable, Equatable {
        let stream: ChatStream
        let sessionKey: String
    }

    private struct SessionInfoPayload: Decodable, Equatable {
        let type: String
        let userId: String?
        let isAdmin: Bool?
        let dmScope: String?
        let sessionKeys: [String]?
        let sessions: [SessionDescriptor]?
    }

    private struct EventEnvelope: Decodable {
        let type: String
        let event: String
    }

    private struct TypingEventPayload: Decodable {
        let type: String
        let role: Message.Role?
        let active: Bool
        let sessionKey: String?
    }

    private struct ActivityEventPayload: Decodable {
        let type: String
        let event: String
        let payload: ActivityPayload

        struct ActivityPayload: Decodable {
            let isActive: Bool
            let sessionKey: String?
        }
    }

    private let connector: any WebSocketConnecting
    private let deviceId: String
    private let baseURLProvider: () -> URL?
    private let userIdProvider: () -> String?
    private let streamAPIClient: StreamAPIClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let supportedClientFeatures = ["terminal_bubbles_v1"]
    private let authTimeout: Duration = .seconds(12)

    private let messageBroadcaster = AsyncStreamBroadcaster<Message>()
    private let stateBroadcaster = AsyncStreamBroadcaster<ConnectionState>()
    private let serviceEventBroadcaster = AsyncStreamBroadcaster<ChatServiceEvent>()
    private var lastConnectionState: ConnectionState = .disconnected

    private var socket: (any WebSocketClient)?
    private var receiveTask: Task<Void, Never>?
    private var authContinuation: CheckedContinuation<Void, Swift.Error>?
    private var pendingMessages: Set<String> = []
    private var sentMessageIDs: Set<String> = []
    private var shouldNotifyDisconnect = true
    private var pendingDisconnectReason: String?
    private var isConnecting = false
    private var authToken: String?

    init(connector: any WebSocketConnecting,
         deviceId: String,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         userIdProvider: @escaping () -> String? = { nil },
         streamAPIClient: StreamAPIClient? = nil,
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.connector = connector
        self.deviceId = deviceId
        self.baseURLProvider = baseURLProvider
        self.userIdProvider = userIdProvider
        self.encoder = encoder
        self.decoder = decoder
        self.streamAPIClient = streamAPIClient ?? StreamAPIClient(baseURLProvider: baseURLProvider)
    }

    var incomingMessages: AsyncStream<Message> { messageBroadcaster.stream() }
    var connectionState: AsyncStream<ConnectionState> { stateBroadcaster.stream(initial: lastConnectionState) }
    var serviceEvents: AsyncStream<ChatServiceEvent> { serviceEventBroadcaster.stream() }

    func fetchStreams() async throws -> [StreamSession] {
        do {
            return try await streamAPIClient.fetchStreams(token: authToken)
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        do {
            return try await streamAPIClient.createStream(
                displayName: displayName,
                idempotencyKey: idempotencyKey,
                token: authToken
            )
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        do {
            return try await streamAPIClient.renameStream(
                sessionKey: sessionKey,
                displayName: displayName,
                token: authToken
            )
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String {
        do {
            return try await streamAPIClient.deleteStream(
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey,
                token: authToken
            )
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func connect(token: String, lastMessageId: String?) async throws {
        if isConnecting {
            logger.info("connect suppressed: already connecting")
            resolveAuthContinuation(with: .failure(Error.notConnected))
            return
        }
        isConnecting = true
        defer { isConnecting = false }

        guard let baseURL = baseURLProvider() else {
            throw Error.missingBaseURL
        }
        let wsURLs = makeWebSocketURLs(from: baseURL)
        guard !wsURLs.isEmpty else {
            throw Error.missingBaseURL
        }

        try await teardownConnection()
        shouldNotifyDisconnect = true
        pendingDisconnectReason = nil

        var lastError: Swift.Error?
        for (index, wsURL) in wsURLs.enumerated() {
            logger.info("connect start attempt=\(index + 1, privacy: .public)/\(wsURLs.count, privacy: .public) ws=\(wsURL.absoluteString, privacy: .public)")
            updateState(.connecting)
            do {
                let client = try await connector.connect(to: wsURL)
                socket = client
                startListening(on: client)
                try await awaitAuthResult(client: client, token: token, lastMessageId: lastMessageId)
                authToken = token
                return
            } catch {
                lastError = error
                if index < wsURLs.count - 1, shouldFallbackToNextTransport(after: error) {
                    logger.warning("connect fallback after \(error.localizedDescription, privacy: .public)")
                    performDisconnect(shouldNotify: false)
                    continue
                }
                logger.info("state -> failed (connect/auth) error=\(error.localizedDescription, privacy: .public)")
                updateState(.failed(error))
                performDisconnect(shouldNotify: false, reason: error.localizedDescription)
                throw error
            }
        }

        throw lastError ?? Error.notConnected
    }

    func disconnect() {
        logger.info("disconnect requested")
        performDisconnect(shouldNotify: false)
    }

    private func performDisconnect(shouldNotify: Bool, reason: String? = nil) {
        logger.info("performDisconnect notify=\(shouldNotify, privacy: .public) reason=\(reason ?? "nil", privacy: .public)")
        shouldNotifyDisconnect = shouldNotify
        pendingDisconnectReason = reason
        resolveAuthContinuation(with: .failure(Error.notConnected))
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close(with: .normalClosure)
        socket = nil
        authToken = nil
        if !pendingMessages.isEmpty {
            for messageId in pendingMessages {
                emitServiceEvent(.messageError(
                    messageId: messageId,
                    code: "connection_lost",
                    message: nil
                ))
            }
        }
        pendingMessages.removeAll()
        logger.info("state -> disconnected (performDisconnect)")
        updateState(.disconnected)
    }

    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?
    ) async throws {
        guard let socket else {
            throw Error.notConnected
        }
        guard id.hasPrefix("c_") else {
            throw Error.invalidMessageId
        }
        if sentMessageIDs.contains(id) {
            logger.warning("duplicate outbound message suppressed id=\(id, privacy: .public)")
            return
        }

        let payload = ClientMessagePayload(
            id: id,
            content: content,
            attachments: attachments,
            sessionKey: sessionKey
        )
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode outbound message payload as UTF-8 id=\(id, privacy: .public)")
            throw Error.serverError(
                code: "client_encode_failed",
                message: "Failed to encode outbound message payload."
            )
        }

        sentMessageIDs.insert(id)
        pendingMessages.insert(id)
        do {
            try await socket.send(text: text)
        } catch {
            pendingMessages.remove(id)
            throw error
        }
    }

    func sendInteractiveCallback(
        sourceMessageId: String,
        action: String,
        data: JSONValue?
    ) async throws {
        guard let socket else {
            throw Error.notConnected
        }
        let payload = InteractiveCallbackOutboundPayload(
            messageId: sourceMessageId,
            payload: .init(action: action, data: data)
        )
        let encoded = try encoder.encode(payload)
        guard let text = String(data: encoded, encoding: .utf8) else {
            logger.error("Failed to encode interactive callback payload as UTF-8 sourceMessageId=\(sourceMessageId, privacy: .public)")
            throw Error.serverError(
                code: "client_encode_failed",
                message: "Failed to encode interactive callback payload."
            )
        }
        try await socket.send(text: text)
    }

    // MARK: - Internal helpers

    private func makeWebSocketURLs(from baseURL: URL) -> [URL] {
        ProviderWebSocketURLBuilder.candidateURLs(from: baseURL, defaultPath: "/ws")
    }

    private func shouldFallbackToNextTransport(after error: Swift.Error) -> Bool {
        if let providerError = error as? Error {
            switch providerError {
            case .missingBaseURL,
                 .authFailed,
                 .tokenRevoked,
                 .sessionReplaced,
                 .invalidMessageId,
                 .serverError,
                 .policyViolation:
                return false
            case .notConnected, .authTimeout:
                return true
            }
        }
        if error is URLError {
            return true
        }
        return true
    }

    private func startListening(on client: any WebSocketClient) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            var iterator = client.incomingTextMessages.makeAsyncIterator()
            while let text = await iterator.next() {
                handle(text: text)
            }
            handleSocketClose(closeInfo: client.lastCloseInfo)
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else {
            logger.warning("Dropping inbound frame: failed UTF-8 conversion")
            return
        }

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            logger.warning("Dropping inbound frame: failed to decode envelope error=\(error.localizedDescription, privacy: .public)")
            return
        }

        switch envelope.type {
        case "auth_result":
            handleAuthResult(data: data)
        case "message":
            handleMessage(data: data)
        case "ack":
            handleAck(data: data)
        case "error":
            handleServerError(data: data)
        case "user_info":
            handleUserInfo(data: data)
        case "typing":
            handleTyping(data: data)
        case "session_info":
            handleSessionInfo(data: data)
        case "stream_snapshot":
            handleStreamSnapshot(data: data)
        case "stream_created":
            handleStreamCreated(data: data)
        case "stream_updated":
            handleStreamUpdated(data: data)
        case "stream_deleted":
            handleStreamDeleted(data: data)
        case "event":
            handleEvent(data: data)
        default:
            logger.debug("Unknown message type: \(envelope.type, privacy: .public)")
        }
    }

    private func handleAuthResult(data: Data) {
        let result: AuthResultPayload
        do {
            result = try decoder.decode(AuthResultPayload.self, from: data)
        } catch {
            logger.warning("Dropping auth_result: decode failed error=\(error.localizedDescription, privacy: .public)")
            return
        }
        if result.success {
            resolveAuthContinuation(with: .success(()))
            logger.info("state -> connected (auth success)")
            updateState(.connected)
            let supportsSessionProvisioning = result.features?.contains("session_info") ?? false
            emitServiceEvent(.sessionProvisioningAvailable(supportsSessionProvisioning))
            if let info = sessionInfo(from: result) {
                emitServiceEvent(.sessionInfo(info))
            }
            if let isAdmin = result.isAdmin {
                logger.info("Auth result received (userId: \(result.userId ?? "unknown", privacy: .public), isAdmin: \(isAdmin, privacy: .public))")
                let info = ChatUserInfo(userId: result.userId ?? "", isAdmin: isAdmin)
                emitServiceEvent(.userInfo(info))
            }
        } else {
            let reason = result.reason ?? "Unknown error"
            let error = Error.authFailed(reason)
            resolveAuthContinuation(with: .failure(error))
            logger.info("state -> failed (auth result) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        }
    }

    private func handleMessage(data: Data) {
        let payload: ServerMessagePayload
        do {
            payload = try decoder.decode(ServerMessagePayload.self, from: data)
        } catch {
            logger.warning("Dropping message payload: decode failed error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard let sessionKey = resolveSessionKey(from: payload) else {
            logger.warning("Dropping message: missing sessionKey id=\(payload.id, privacy: .public)")
            return
        }
        let snippet = String(payload.content.prefix(80))
        messageLogger.info(
            "recv message id=\(payload.id, privacy: .public) sessionKey=\(sessionKey, privacy: .public) role=\(String(describing: payload.role), privacy: .public) streaming=\(payload.streaming, privacy: .public) deviceId=\(payload.deviceId ?? "nil", privacy: .public) snippet=\"\(snippet, privacy: .public)\""
        )
        let message = Message(payload: payload, sessionKey: sessionKey)
        messageBroadcaster.send(message)
    }

    private func handleTyping(data: Data) {
        guard let payload = try? decoder.decode(TypingEventPayload.self, from: data) else {
            logger.warning("Failed to decode typing event payload")
            return
        }
        if let role = payload.role, role != .assistant {
            logger.info("Ignoring typing event for role=\(role.rawValue, privacy: .public)")
            return
        }
        let sessionKey = resolveSessionKey(from: payload)
        logger.info("typing event active=\(payload.active, privacy: .public) sessionKey=\(sessionKey ?? "nil", privacy: .public)")
        if let sessionKey {
            emitServiceEvent(.typingStateChanged(isTyping: payload.active, sessionKey: sessionKey))
        }
    }

    private func handleAck(data: Data) {
        let payload: AckPayload
        do {
            payload = try decoder.decode(AckPayload.self, from: data)
        } catch {
            logger.warning("Dropping ack payload: decode failed error=\(error.localizedDescription, privacy: .public)")
            return
        }
        pendingMessages.remove(payload.id)
        emitServiceEvent(.messageAcked(id: payload.id))
    }

    private func handleServerError(data: Data) {
        let payload: ErrorPayload
        do {
            payload = try decoder.decode(ErrorPayload.self, from: data)
        } catch {
            logger.warning("Dropping error payload: decode failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        if let messageId = payload.messageId {
            pendingMessages.remove(messageId)
            emitServiceEvent(.messageError(messageId: messageId, code: payload.code, message: payload.message))
            return
        }

        let message = payload.message ?? payload.code
        switch payload.code {
        case "auth_failed":
            let error = Error.authFailed(message)
            resolveAuthContinuation(with: .failure(error))
            logger.info("state -> failed (server error auth_failed) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        case "token_revoked":
            let error = Error.tokenRevoked(message)
            resolveAuthContinuation(with: .failure(error))
            logger.info("state -> failed (server error token_revoked) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        case "session_replaced":
            let error = Error.sessionReplaced
            logger.info("state -> failed (server error session_replaced)")
            updateState(.failed(error))
            performDisconnect(shouldNotify: false, reason: error.localizedDescription)
        case "invalid_message", "payload_too_large", "invalid_channel":
            logger.info("message-level error without messageId code=\(payload.code, privacy: .public)")
            if !pendingMessages.isEmpty {
                for messageId in pendingMessages {
                    emitServiceEvent(.messageError(
                        messageId: messageId,
                        code: payload.code,
                        message: payload.message
                    ))
                }
                pendingMessages.removeAll()
            } else {
                emitServiceEvent(.messageError(messageId: nil, code: payload.code, message: payload.message))
            }
        default:
            logger.info("state -> failed (server error) code=\(payload.code, privacy: .public)")
            updateState(.failed(Error.serverError(code: payload.code, message: payload.message)))
        }
    }

    private func handleUserInfo(data: Data) {
        guard let payload = try? decoder.decode(UserInfoPayload.self, from: data) else { return }
        let info = ChatUserInfo(userId: payload.userId, isAdmin: payload.isAdmin)
        emitServiceEvent(.userInfo(info))
    }

    private func handleSessionInfo(data: Data) {
        guard let payload = try? decoder.decode(SessionInfoPayload.self, from: data) else {
            logger.warning("Failed to decode session_info payload")
            return
        }
        if let info = sessionInfo(from: payload) {
            emitServiceEvent(.sessionInfo(info))
        }
    }

    private func handleEvent(data: Data) {
        guard let envelope = try? decoder.decode(EventEnvelope.self, from: data) else {
            logger.warning("Failed to decode event envelope")
            return
        }
        logger.info("Received event: \(envelope.event, privacy: .public)")

        switch envelope.event {
        case "activity":
            guard let payload = try? decoder.decode(ActivityEventPayload.self, from: data) else {
                logger.warning("Failed to decode activity event payload")
                return
            }
            let sessionKey = resolveSessionKey(from: payload.payload)
            logger.info("activity event isActive=\(payload.payload.isActive, privacy: .public) sessionKey=\(sessionKey ?? "nil", privacy: .public)")
            if let sessionKey {
                emitServiceEvent(.typingStateChanged(isTyping: payload.payload.isActive, sessionKey: sessionKey))
            }
        default:
            logger.debug("Unknown event type: \(envelope.event, privacy: .public)")
        }
    }

    private func handleStreamSnapshot(data: Data) {
        guard let payload = try? decoder.decode(StreamSnapshotPayload.self, from: data) else {
            logger.warning("Failed to decode stream_snapshot payload")
            return
        }
        emitServiceEvent(.streamSnapshot(payload.streams))
    }

    private func handleStreamCreated(data: Data) {
        guard let payload = try? decoder.decode(StreamMutationPayload.self, from: data) else {
            logger.warning("Failed to decode stream_created payload")
            return
        }
        emitServiceEvent(.streamCreated(payload.stream))
    }

    private func handleStreamUpdated(data: Data) {
        guard let payload = try? decoder.decode(StreamMutationPayload.self, from: data) else {
            logger.warning("Failed to decode stream_updated payload")
            return
        }
        emitServiceEvent(.streamUpdated(payload.stream))
    }

    private func handleStreamDeleted(data: Data) {
        guard let payload = try? decoder.decode(StreamDeletedPayload.self, from: data) else {
            logger.warning("Failed to decode stream_deleted payload")
            return
        }
        emitServiceEvent(.streamDeleted(sessionKey: payload.sessionKey))
    }

    private func resolveSessionKey(from payload: TypingEventPayload) -> String? {
        payload.sessionKey
    }

    private func resolveSessionKey(from payload: ServerMessagePayload) -> String? {
        payload.sessionKey
    }

    private func resolveSessionKey(from payload: ActivityEventPayload.ActivityPayload) -> String? {
        payload.sessionKey
    }

    private func updateState(_ state: ConnectionState) {
        lastConnectionState = state
        stateBroadcaster.send(state)
    }

    private func emitServiceEvent(_ event: ChatServiceEvent) {
        serviceEventBroadcaster.send(event)
    }

    private static let clientID = "openclaw"

    private func normalizeSessionKeys(_ raw: [String]) -> [String] {
        // Preserve order but dedupe identical keys.
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(raw.count)
        for key in raw {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    private func sessionInfo(from payload: AuthResultPayload) -> SessionInfo? {
        if let sessionKeys = payload.sessionKeys {
            return SessionInfo(
                userId: payload.userId,
                isAdmin: payload.isAdmin,
                dmScope: payload.dmScope,
                sessionKeys: normalizeSessionKeys(sessionKeys)
            )
        }
        if let sessions = payload.sessions, !sessions.isEmpty {
            // Back-compat: older gateways returned labeled streams.
            return SessionInfo(
                userId: payload.userId,
                isAdmin: payload.isAdmin,
                dmScope: payload.dmScope,
                sessionKeys: normalizeSessionKeys(sessions.map(\.sessionKey))
            )
        }
        return nil
    }

    private func sessionInfo(from payload: SessionInfoPayload) -> SessionInfo? {
        if let sessionKeys = payload.sessionKeys {
            return SessionInfo(
                userId: payload.userId,
                isAdmin: payload.isAdmin,
                dmScope: payload.dmScope,
                sessionKeys: normalizeSessionKeys(sessionKeys)
            )
        }
        if let sessions = payload.sessions, !sessions.isEmpty {
            return SessionInfo(
                userId: payload.userId,
                isAdmin: payload.isAdmin,
                dmScope: payload.dmScope,
                sessionKeys: normalizeSessionKeys(sessions.map(\.sessionKey))
            )
        }
        return nil
    }

    private func sessionMap(from sessions: [SessionDescriptor]) -> [ChatStream: String] {
        var map: [ChatStream: String] = [:]
        for session in sessions {
            map[session.stream] = session.sessionKey
        }
        return map
    }

    private func handleSocketClose(closeInfo: WebSocketCloseInfo?) {
        let rejectionError: Error? = {
            guard let closeInfo else { return nil }
            guard closeInfo.code == 1008 else { return nil }
            guard let reason = closeInfo.reason?.lowercased() else { return nil }
            if reason == "pairing required" || reason.hasPrefix("invalid connect params") {
                return Error.policyViolation(code: closeInfo.code ?? 1008, reason: closeInfo.reason)
            }
            return nil
        }()

        if let rejectionError {
            resolveAuthContinuation(with: .failure(rejectionError))
        } else {
            resolveAuthContinuation(with: .failure(Error.notConnected))
        }

        // Notify the UI about each pending message that failed to send
        // This removes the optimistic placeholders so users know messages weren't delivered
        for messageId in pendingMessages {
            emitServiceEvent(.messageError(
                messageId: messageId,
                code: "connection_lost",
                message: nil
            ))
        }
        pendingMessages.removeAll()

        if let rejectionError {
            let closeCode = String(describing: closeInfo?.code)
            let closeReason = closeInfo?.reason ?? "nil"
            logger.info(
                "state -> failed (socket close policy violation) notify=\(self.shouldNotifyDisconnect, privacy: .public) code=\(closeCode, privacy: .public) reason=\(closeReason, privacy: .public)"
            )
            updateState(.failed(rejectionError))
            if shouldNotifyDisconnect {
                emitServiceEvent(.connectionInterrupted(reason: rejectionError.errorDescription ?? pendingDisconnectReason))
            }
        } else {
            logger.info("state -> disconnected (socket close) notify=\(self.shouldNotifyDisconnect, privacy: .public)")
            updateState(.disconnected)
            if shouldNotifyDisconnect {
                emitServiceEvent(.connectionInterrupted(reason: pendingDisconnectReason))
            }
        }
        shouldNotifyDisconnect = true
        pendingDisconnectReason = nil
    }

    private func teardownConnection() async throws {
        performDisconnect(shouldNotify: false)
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

    private func mapStreamAPIError(_ error: Swift.Error) -> Swift.Error {
        if let streamError = error as? StreamAPIError {
            return Error.serverError(code: streamError.code, message: streamError.message)
        }
        if let providerError = error as? Error {
            return providerError
        }
        return error
    }

    private func awaitAuthResult(client: any WebSocketClient, token: String, lastMessageId: String?) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                    self.authContinuation = continuation
                    Task {
                        do {
                            let authPayload = AuthPayload(
                                token: token,
                                deviceId: self.deviceId,
                                lastMessageId: lastMessageId,
                                clientFeatures: self.supportedClientFeatures,
                                client: ClientDescriptor(
                                    id: Self.clientID,
                                    features: self.supportedClientFeatures
                                )
                            )
                            let data = try self.encoder.encode(authPayload)
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

            group.addTask { [authTimeout] in
                try await Task.sleep(forDuration: authTimeout)
                throw Error.authTimeout
            }

            guard let _ = try await group.next() else {
                throw Error.authTimeout
            }
            group.cancelAll()
        }
    }
}
