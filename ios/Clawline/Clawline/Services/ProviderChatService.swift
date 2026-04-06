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

enum TransportOwnerMode {
    case managed
    case standalone
}

class ProviderChatService: ChatServicing {
    fileprivate actor TransportSessionCoordinator {
        struct AttemptState {
            let mode: TransportOwnerMode
            let generation: UUID
            let token: String
            let lastMessageId: String?
            let managedEpoch: Int?
            var task: Task<Void, Never>?
            var waiters: [CheckedContinuation<Void, Swift.Error>]
        }

        struct SessionState {
            let mode: TransportOwnerMode
            let generation: UUID
            let token: String
            let managedEpoch: Int?
            var sentMessageIDs: Set<String>
        }

        struct AuthResultResolution {
            let shouldProcess: Bool
        }

        struct FailureResolution {
            let shouldProcess: Bool
        }

        struct SocketCloseResolution {
            let shouldProcess: Bool
            let shouldNotifyDisconnect: Bool
            let pendingDisconnectReason: String?
            let rejectionError: ProviderChatService.Error?
        }

        private let mode: TransportOwnerMode
        private var socket: (any WebSocketClient)?
        private var receiveTask: Task<Void, Never>?
        private var authContinuation: CheckedContinuation<Void, Swift.Error>?
        private var authToken: String?
        private var shouldNotifyDisconnect = true
        private var pendingDisconnectReason: String?
        private var attemptState: AttemptState?
        private var sessionState: SessionState?

        init(mode: TransportOwnerMode) {
            self.mode = mode
        }

        func currentControlPlaneToken() -> String? {
            authToken
        }

        func currentGeneration() -> UUID? {
            sessionState?.generation ?? attemptState?.generation
        }

        func beginManagedAttempt(epoch: Int, token: String, lastMessageId: String?) -> UUID {
            resetTransportState(closeSocket: true)
            let generation = UUID()
            attemptState = AttemptState(
                mode: .managed,
                generation: generation,
                token: token,
                lastMessageId: lastMessageId,
                managedEpoch: epoch,
                task: nil,
                waiters: []
            )
            shouldNotifyDisconnect = false
            pendingDisconnectReason = nil
            return generation
        }

        func prepareStandaloneConnect(
            token: String,
            lastMessageId: String?
        ) -> (generation: UUID?, shouldJoinExisting: Bool, shouldReuseConnected: Bool) {
            if let sessionState {
                switch sessionState.mode {
                case .standalone:
                    return (nil, false, true)
                case .managed:
                    break
                }
            }
            if let attemptState {
                switch attemptState.mode {
                case .standalone:
                    return (nil, true, false)
                case .managed:
                    break
                }
            }

            resetTransportState(closeSocket: true)
            let generation = UUID()
            attemptState = AttemptState(
                mode: .standalone,
                generation: generation,
                token: token,
                lastMessageId: lastMessageId,
                managedEpoch: nil,
                task: nil,
                waiters: []
            )
            shouldNotifyDisconnect = true
            pendingDisconnectReason = nil
            return (generation, false, false)
        }

        func attachAttemptTask(_ task: Task<Void, Never>, generation: UUID) -> Bool {
            guard var attemptState, attemptState.generation == generation else {
                task.cancel()
                return false
            }
            attemptState.task = task
            self.attemptState = attemptState
            return true
        }

        func cancelAttempt() {
            attemptState?.task?.cancel()
            finishAttemptWaiters(Result<Void, Swift.Error>.failure(ProviderChatService.Error.notConnected))
        }

        func waitForStandaloneAttemptToFinish() async throws {
            if let sessionState, authToken != nil {
                switch sessionState.mode {
                case .standalone:
                    return
                case .managed:
                    break
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                guard var attemptState else {
                    continuation.resume(throwing: ProviderChatService.Error.notConnected)
                    return
                }
                switch attemptState.mode {
                case .standalone:
                    break
                case .managed:
                    continuation.resume(throwing: ProviderChatService.Error.notConnected)
                    return
                }
                attemptState.waiters.append(continuation)
                self.attemptState = attemptState
            }
        }

        private func finishAttemptWaiters(_ result: Result<Void, Swift.Error>) {
            guard var attemptState else { return }
            let waiters = attemptState.waiters
            attemptState.waiters.removeAll()
            attemptState.task = nil
            self.attemptState = attemptState
            for waiter in waiters {
                switch result {
                case .success:
                    waiter.resume()
                case .failure(let error):
                    waiter.resume(throwing: error)
                }
            }
        }

        func registerSocket(_ socket: any WebSocketClient, generation: UUID) -> Bool {
            guard currentGeneration() == generation else {
                socket.close(with: .normalClosure)
                return false
            }
            self.socket = socket
            return true
        }

        func registerReceiveTask(_ task: Task<Void, Never>, generation: UUID) -> Bool {
            guard currentGeneration() == generation else {
                task.cancel()
                return false
            }
            receiveTask = task
            return true
        }

        func installAuthContinuation(
            _ continuation: CheckedContinuation<Void, Swift.Error>,
            generation: UUID
        ) -> Bool {
            guard currentGeneration() == generation else {
                continuation.resume(throwing: ProviderChatService.Error.notConnected)
                return false
            }
            authContinuation = continuation
            return true
        }

        func resolveAuthContinuation(with result: Result<Void, Swift.Error>) {
            guard let continuation = authContinuation else { return }
            authContinuation = nil
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }

        func applyAuthSuccess(generation: UUID) -> AuthResultResolution {
            guard let attemptState, attemptState.generation == generation else {
                return AuthResultResolution(shouldProcess: false)
            }
            authToken = attemptState.token
            sessionState = SessionState(
                mode: attemptState.mode,
                generation: generation,
                token: attemptState.token,
                managedEpoch: attemptState.managedEpoch,
                sentMessageIDs: []
            )
            resolveAuthContinuation(with: .success(()))
            finishAttemptWaiters(.success(()))
            self.attemptState = nil
            return AuthResultResolution(shouldProcess: true)
        }

        func applyAuthFailure(generation: UUID, error: Swift.Error) -> FailureResolution {
            guard currentGeneration() == generation else {
                return FailureResolution(shouldProcess: false)
            }
            resolveAuthContinuation(with: .failure(error))
            finishAttemptWaiters(.failure(error))
            return FailureResolution(shouldProcess: true)
        }

        func shouldProcess(generation: UUID?) -> Bool {
            guard let generation else { return true }
            return currentGeneration() == generation
        }

        func applyDisconnect(shouldNotify: Bool, reason: String? = nil) {
            self.shouldNotifyDisconnect = shouldNotify
            pendingDisconnectReason = reason
            resetTransportState(closeSocket: true)
        }

        func clearActiveTransportPreservingAttempt(shouldNotify: Bool, reason: String? = nil) {
            self.shouldNotifyDisconnect = shouldNotify
            pendingDisconnectReason = reason
            resolveAuthContinuation(with: .failure(ProviderChatService.Error.notConnected))
            receiveTask?.cancel()
            receiveTask = nil
            socket?.close(with: .normalClosure)
            socket = nil
            authToken = nil
            sessionState = nil
        }

        func applySocketClose(generation: UUID?, closeInfo: WebSocketCloseInfo?) -> SocketCloseResolution {
            guard shouldProcess(generation: generation) else {
                return SocketCloseResolution(
                    shouldProcess: false,
                    shouldNotifyDisconnect: false,
                    pendingDisconnectReason: nil,
                    rejectionError: nil
                )
            }

            let rejectionError: ProviderChatService.Error? = {
                guard let closeInfo else { return nil }
                guard closeInfo.code == 1008 else { return nil }
                guard let reason = closeInfo.reason?.lowercased() else { return nil }
                if reason == "pairing required" || reason.hasPrefix("invalid connect params") {
                    return .policyViolation(code: closeInfo.code ?? 1008, reason: closeInfo.reason)
                }
                return nil
            }()

            if let rejectionError {
                resolveAuthContinuation(with: .failure(rejectionError))
            } else {
                resolveAuthContinuation(with: .failure(ProviderChatService.Error.notConnected))
            }

            let shouldNotifyDisconnect = self.shouldNotifyDisconnect
            let pendingDisconnectReason = self.pendingDisconnectReason
            if attemptState != nil, sessionState == nil {
                receiveTask?.cancel()
                receiveTask = nil
                socket = nil
                authToken = nil
                sessionState = nil
            } else {
                resetTransportState(closeSocket: false)
            }
            self.shouldNotifyDisconnect = true
            self.pendingDisconnectReason = nil

            return SocketCloseResolution(
                shouldProcess: true,
                shouldNotifyDisconnect: shouldNotifyDisconnect,
                pendingDisconnectReason: pendingDisconnectReason,
                rejectionError: rejectionError
            )
        }

        func reserveOutboundMessage(id: String) throws -> Bool {
            guard socket != nil else {
                throw ProviderChatService.Error.notConnected
            }
            if var sessionState {
                if sessionState.sentMessageIDs.contains(id) {
                    return false
                }
                sessionState.sentMessageIDs.insert(id)
                self.sessionState = sessionState
            }
            return true
        }

        func rollbackOutboundMessage(id: String) {
            guard var sessionState else { return }
            sessionState.sentMessageIDs.remove(id)
            self.sessionState = sessionState
        }

        func send(text: String) async throws {
            guard let socket else {
                throw ProviderChatService.Error.notConnected
            }
            try await socket.send(text: text)
        }

        private func resetTransportState(closeSocket: Bool) {
            attemptState?.task?.cancel()
            finishAttemptWaiters(.failure(ProviderChatService.Error.notConnected))
            resolveAuthContinuation(with: .failure(ProviderChatService.Error.notConnected))
            receiveTask?.cancel()
            receiveTask = nil
            if closeSocket {
                socket?.close(with: .normalClosure)
            }
            socket = nil
            authToken = nil
            attemptState = nil
            sessionState = nil
        }
    }

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
        let adoptedSessionKeys: [String]?
        let replayCursorsBySessionKey: [String: String]?
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
        let replayCount: Int?
        let replayTruncated: Bool?
        let historyReset: Bool?
        let streamReadStates: [String: String]?
        let streamTailStates: [String: StreamTailState]?
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

    private struct PendingMessage {
        let payload: ClientMessagePayload
        var retryTask: Task<Void, Never>?
    }

    fileprivate let connector: any WebSocketConnecting
    fileprivate let deviceId: String
    fileprivate let baseURLProvider: () -> URL?
    fileprivate let userIdProvider: () -> String?
    fileprivate let authTokenProvider: @Sendable () async -> String?
    private let adoptedSessionKeysProvider: @Sendable () -> [String]
    fileprivate let streamAPIClient: StreamAPIClient
    fileprivate let encoder: JSONEncoder
    fileprivate let decoder: JSONDecoder
    fileprivate let replayCursorDefaults = UserDefaults.standard
    fileprivate let supportedClientFeatures = ["terminal_bubbles_v1"]
    fileprivate let authTimeout: Duration = .seconds(12)
    fileprivate let transportSessionCoordinator: TransportSessionCoordinator

    private let messageBroadcaster = AsyncStreamBroadcaster<Message>()
    private let stateBroadcaster = AsyncStreamBroadcaster<ConnectionState>()
    private let serviceEventBroadcaster = AsyncStreamBroadcaster<ChatServiceEvent>()
    private let lifecycleTransportEventBroadcaster = AsyncStreamBroadcaster<LifecycleTransportEvent>()
    private var lastConnectionState: ConnectionState = .disconnected

    private var authTimeoutTask: Task<Void, Never>?
    private var pendingMessages: [String: PendingMessage] = [:]
    private var replayCursorBySessionKey: [String: String] = [:]
    private var knownSessionKeys: Set<String> = []

    private static let serverEventIDPrefix = "s_"

    var isTransportReadyForSend: Bool {
        lastConnectionState == .connected
    }

    init(connector: any WebSocketConnecting,
         deviceId: String,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         userIdProvider: @escaping () -> String? = { nil },
         authTokenProvider: @escaping @Sendable () async -> String? = { nil },
         adoptedSessionKeysProvider: @escaping @Sendable () -> [String] = { [] },
         streamAPIClient: StreamAPIClient? = nil,
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.transportSessionCoordinator = TransportSessionCoordinator(mode: .managed)
        self.connector = connector
        self.deviceId = deviceId
        self.baseURLProvider = baseURLProvider
        self.userIdProvider = userIdProvider
        self.authTokenProvider = authTokenProvider
        self.adoptedSessionKeysProvider = adoptedSessionKeysProvider
        self.encoder = encoder
        self.decoder = decoder
        self.streamAPIClient = streamAPIClient ?? StreamAPIClient(baseURLProvider: baseURLProvider)
        self.replayCursorBySessionKey = restoreReplayCursorSnapshot()
    }

    fileprivate init(connector: any WebSocketConnecting,
                     deviceId: String,
                     transportOwnerMode: TransportOwnerMode,
                     baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
                     userIdProvider: @escaping () -> String? = { nil },
                     authTokenProvider: @escaping @Sendable () async -> String? = { nil },
                     adoptedSessionKeysProvider: @escaping @Sendable () -> [String] = { [] },
                     streamAPIClient: StreamAPIClient? = nil,
                     encoder: JSONEncoder = JSONEncoder(),
                     decoder: JSONDecoder = JSONDecoder()) {
        self.transportSessionCoordinator = TransportSessionCoordinator(mode: transportOwnerMode)
        self.connector = connector
        self.deviceId = deviceId
        self.baseURLProvider = baseURLProvider
        self.userIdProvider = userIdProvider
        self.authTokenProvider = authTokenProvider
        self.adoptedSessionKeysProvider = adoptedSessionKeysProvider
        self.encoder = encoder
        self.decoder = decoder
        self.streamAPIClient = streamAPIClient ?? StreamAPIClient(baseURLProvider: baseURLProvider)
        self.replayCursorBySessionKey = restoreReplayCursorSnapshot()
    }

    var incomingMessages: AsyncStream<Message> { messageBroadcaster.stream() }
    var connectionState: AsyncStream<ConnectionState> { stateBroadcaster.stream(initial: lastConnectionState) }
    var serviceEvents: AsyncStream<ChatServiceEvent> { serviceEventBroadcaster.stream() }
    var lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent> { lifecycleTransportEventBroadcaster.stream() }

    func fetchStreams() async throws -> [StreamSession] {
        guard let token = await resolveControlPlaneToken() else {
            throw Error.notConnected
        }
        do {
            return try await streamAPIClient.fetchStreams(token: token)
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        guard let token = await resolveControlPlaneToken() else {
            throw Error.notConnected
        }
        do {
            return try await streamAPIClient.createStream(
                displayName: displayName,
                idempotencyKey: idempotencyKey,
                token: token
            )
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func fetchTrackableSessions() async throws -> [TrackableSession] {
        guard let token = await resolveControlPlaneToken() else {
            throw Error.notConnected
        }
        do {
            return try await streamAPIClient.fetchTrackableSessions(token: token)
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func adoptStream(sessionKey: String) async throws -> StreamSession {
        guard let token = await resolveControlPlaneToken() else {
            throw Error.notConnected
        }
        do {
            let stream = try await streamAPIClient.adoptStream(
                sessionKey: sessionKey,
                token: token
            )
            emitServiceEvent(.streamCreated(stream))
            return stream
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        guard let token = await resolveControlPlaneToken() else {
            throw Error.notConnected
        }
        do {
            return try await streamAPIClient.renameStream(
                sessionKey: sessionKey,
                displayName: displayName,
                token: token
            )
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String {
        guard let token = await resolveControlPlaneToken() else {
            throw Error.notConnected
        }
        do {
            let deletedKey = try await streamAPIClient.deleteStream(
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey,
                token: token
            )
            emitServiceEvent(.streamDeleted(sessionKey: deletedKey))
            return deletedKey
        } catch {
            throw mapStreamAPIError(error)
        }
    }

    private func resolveControlPlaneToken() async -> String? {
        if let authToken = await transportSessionCoordinator.currentControlPlaneToken(),
           !authToken.isEmpty {
            return authToken
        }
        guard let fallback = await authTokenProvider() else {
            return nil
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate func performStandaloneConnect(token: String, lastMessageId: String?) async throws {
        guard let baseURL = baseURLProvider() else {
            throw Error.missingBaseURL
        }
        let wsURLs = makeWebSocketURLs(from: baseURL)
        guard !wsURLs.isEmpty else {
            throw Error.missingBaseURL
        }

        let generation = await transportSessionCoordinator.currentGeneration()

        var lastError: Swift.Error?
        for (index, wsURL) in wsURLs.enumerated() {
            logger.info("connect start attempt=\(index + 1, privacy: .public)/\(wsURLs.count, privacy: .public) ws=\(wsURL.absoluteString, privacy: .public)")
            updateState(.connecting)
            do {
                let client = try await connector.connect(to: wsURL)
                guard let generation,
                      await transportSessionCoordinator.registerSocket(client, generation: generation) else {
                    continue
                }
                startListening(on: client, generation: generation, lifecycleEpoch: nil)
                try await awaitAuthResult(
                    client: client,
                    generation: generation,
                    token: token,
                    forcedLastMessageId: lastMessageId
                )
                return
            } catch {
                lastError = error
                if index < wsURLs.count - 1, shouldFallbackToNextTransport(after: error) {
                    logger.warning("connect fallback after \(error.localizedDescription, privacy: .public)")
                    await transportSessionCoordinator.clearActiveTransportPreservingAttempt(
                        shouldNotify: false,
                        reason: error.localizedDescription
                    )
                    continue
                }
                logger.info("state -> failed (connect/auth) error=\(error.localizedDescription, privacy: .public)")
                updateState(.failed(error))
                await transportSessionCoordinator.applyDisconnect(
                    shouldNotify: false,
                    reason: error.localizedDescription
                )
                throw error
            }
        }

        throw lastError ?? Error.notConnected
    }

    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {
        Task { [weak self] in
            guard let self else { return }
            let generation = await self.transportSessionCoordinator.beginManagedAttempt(
                epoch: epoch,
                token: token,
                lastMessageId: lastMessageId
            )
            await MainActor.run {
                self.updateState(.connecting)
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runLifecycleConnectAttempt(epoch: epoch, lastMessageId: lastMessageId, token: token)
            }
            _ = await self.transportSessionCoordinator.attachAttemptTask(task, generation: generation)
        }
    }

    func stopConnectionAttempt() {
        Task { [weak self] in
            guard let self else { return }
            await self.transportSessionCoordinator.cancelAttempt()
            await self.transportSessionCoordinator.applyDisconnect(shouldNotify: false)
            await MainActor.run {
                self.updateState(.disconnected)
            }
        }
    }

    func disconnect() {
        logger.info("disconnect requested")
        cancelAuthTimeout()
        Task { [weak self] in
            guard let self else { return }
            await self.transportSessionCoordinator.cancelAttempt()
            await self.transportSessionCoordinator.applyDisconnect(shouldNotify: false)
            await MainActor.run {
                self.updateState(.disconnected)
            }
        }
    }

    func replayCursorSnapshot() -> [String: String] {
        replayCursorBySessionKey
    }

    func setReplayCursor(_ cursor: String?, for sessionKey: String) {
        let trimmedKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        let normalizedCursor = normalizeServerEventID(cursor)
        let previousCursor = replayCursorBySessionKey[trimmedKey]
        if previousCursor == normalizedCursor { return }
        if let normalizedCursor {
            replayCursorBySessionKey[trimmedKey] = normalizedCursor
        } else {
            replayCursorBySessionKey.removeValue(forKey: trimmedKey)
        }
        persistReplayCursorSnapshot()
    }

    func clearReplayCursors() {
        guard !replayCursorBySessionKey.isEmpty else { return }
        replayCursorBySessionKey.removeAll()
        persistReplayCursorSnapshot()
    }

    private func performDisconnect(shouldNotify: Bool, reason: String? = nil) {
        logger.info("performDisconnect notify=\(shouldNotify, privacy: .public) reason=\(reason ?? "nil", privacy: .public)")
        cancelAuthTimeout()
        if !pendingMessages.isEmpty {
            for (messageId, pending) in pendingMessages {
                pending.retryTask?.cancel()
                emitServiceEvent(.messageError(
                    messageId: messageId,
                    code: "connection_lost",
                    message: nil
                ))
            }
        }
        pendingMessages.removeAll()
        Task {
            await transportSessionCoordinator.applyDisconnect(shouldNotify: shouldNotify, reason: reason)
        }
        logger.info("state -> disconnected (performDisconnect)")
        updateState(.disconnected)
    }

    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?
    ) async throws {
        guard id.hasPrefix("c_") else {
            throw Error.invalidMessageId
        }
        let shouldSend = try await transportSessionCoordinator.reserveOutboundMessage(id: id)
        if !shouldSend {
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

        pendingMessages[id]?.retryTask?.cancel()
        pendingMessages[id] = PendingMessage(payload: payload, retryTask: nil)
        do {
            try await transportSessionCoordinator.send(text: text)
        } catch {
            await transportSessionCoordinator.rollbackOutboundMessage(id: id)
            if let pending = pendingMessages.removeValue(forKey: id) {
                pending.retryTask?.cancel()
            }
            throw error
        }
    }

    func sendInteractiveCallback(
        sourceMessageId: String,
        action: String,
        data: JSONValue?
    ) async throws {
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
        try await transportSessionCoordinator.send(text: text)
    }

    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {
        let payload = ClientStreamReadPayload(sessionKey: sessionKey, lastReadMessageId: lastReadMessageId)
        let encoded = try encoder.encode(payload)
        guard let text = String(data: encoded, encoding: .utf8) else {
            logger.error(
                "Failed to encode stream read payload as UTF-8 sessionKey=\(sessionKey, privacy: .public) lastReadMessageId=\(lastReadMessageId, privacy: .public)"
            )
            throw Error.serverError(
                code: "client_encode_failed",
                message: "Failed to encode stream read payload."
            )
        }
        try await transportSessionCoordinator.send(text: text)
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

    private func runLifecycleConnectAttempt(epoch: Int, lastMessageId: String?, token: String) async {
        guard let baseURL = baseURLProvider() else {
            emitLifecycleEvent(
                epoch: epoch,
                payload: .authResult(
                    success: false,
                    replayCount: nil,
                    replayTruncated: nil,
                    historyReset: nil,
                    failureReason: .protocolMismatch
                )
            )
            await transportSessionCoordinator.applyDisconnect(
                shouldNotify: false,
                reason: Error.missingBaseURL.localizedDescription
            )
            return
        }
        let wsURLs = makeWebSocketURLs(from: baseURL)
        guard !wsURLs.isEmpty else {
            emitLifecycleEvent(
                epoch: epoch,
                payload: .authResult(
                    success: false,
                    replayCount: nil,
                    replayTruncated: nil,
                    historyReset: nil,
                    failureReason: .protocolMismatch
                )
            )
            await transportSessionCoordinator.applyDisconnect(
                shouldNotify: false,
                reason: Error.missingBaseURL.localizedDescription
            )
            return
        }

        guard let generation = await transportSessionCoordinator.currentGeneration() else {
            return
        }

        for (index, wsURL) in wsURLs.enumerated() {
            if Task.isCancelled { return }
            do {
                logger.info("lifecycle attempt epoch=\(epoch, privacy: .public) connect \(index + 1, privacy: .public)/\(wsURLs.count, privacy: .public) ws=\(wsURL.absoluteString, privacy: .public)")
                let client = try await connector.connect(to: wsURL)
                if Task.isCancelled { return }
                guard await transportSessionCoordinator.registerSocket(client, generation: generation) else {
                    continue
                }
                startListening(on: client, generation: generation, lifecycleEpoch: epoch)
                emitLifecycleEvent(
                    epoch: epoch,
                    payload: .transportOpened,
                    generation: generation
                )
                try await awaitAuthResult(
                    client: client,
                    generation: generation,
                    token: token,
                    forcedLastMessageId: lastMessageId
                )
                return
            } catch {
                if index < wsURLs.count - 1, shouldFallbackToNextTransport(after: error) {
                    await transportSessionCoordinator.clearActiveTransportPreservingAttempt(
                        shouldNotify: false,
                        reason: error.localizedDescription
                    )
                    continue
                }
                emitLifecycleEvent(
                    epoch: epoch,
                    payload: .transportClosed(reason: .error),
                    generation: generation
                )
                await transportSessionCoordinator.applyDisconnect(shouldNotify: false)
                return
            }
        }
    }

    private func normalizedAdoptedSessionKeys() -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for sessionKey in adoptedSessionKeysProvider() {
            let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                normalized.append(trimmed)
            }
        }
        return normalized
    }

    private func sendAuth(client: any WebSocketClient, token: String, lastMessageId: String?) async throws {
        let sanitizedLastMessageId = normalizeServerEventID(lastMessageId)
        let adoptedKeys = normalizedAdoptedSessionKeys()
        let authPayload = AuthPayload(
            token: token,
            deviceId: deviceId,
            lastMessageId: sanitizedLastMessageId,
            adoptedSessionKeys: adoptedKeys.isEmpty ? nil : adoptedKeys,
            replayCursorsBySessionKey: nil,
            clientFeatures: supportedClientFeatures,
            client: ClientDescriptor(
                id: Self.clientID,
                features: supportedClientFeatures
            )
        )
        let data = try encoder.encode(authPayload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.notConnected
        }
        try await client.send(text: text)
    }

    private func startListening(on client: any WebSocketClient, generation: UUID, lifecycleEpoch: Int?) {
        let task = Task { [weak self] in
            guard let self else { return }
            var iterator = client.incomingTextMessages.makeAsyncIterator()
            while let text = await iterator.next() {
                await handle(text: text, generation: generation, lifecycleEpoch: lifecycleEpoch)
            }
            await handleSocketClose(
                closeInfo: client.lastCloseInfo,
                generation: generation,
                lifecycleEpoch: lifecycleEpoch
            )
        }
        Task {
            await transportSessionCoordinator.registerReceiveTask(task, generation: generation)
        }
    }

    private func handle(text: String, generation: UUID, lifecycleEpoch: Int?) async {
        guard await transportSessionCoordinator.shouldProcess(generation: generation) else {
            logger.debug("dropping stale inbound frame")
            return
        }
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
            await handleAuthResult(
                data: data,
                generation: generation,
                lifecycleEpoch: lifecycleEpoch
            )
        case "message":
            await handleMessage(
                data: data,
                generation: generation,
                lifecycleEpoch: lifecycleEpoch
            )
        case "ack":
            handleAck(data: data)
        case "error":
            await handleServerError(
                data: data,
                generation: generation,
                lifecycleEpoch: lifecycleEpoch
            )
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
        case "stream_read_state":
            handleStreamReadState(data: data)
        case "stream_tail_state":
            handleStreamTailState(data: data)
        case "event":
            handleEvent(data: data)
        default:
            logger.debug("Unknown message type: \(envelope.type, privacy: .public)")
        }
    }

    private func handleAuthResult(data: Data, generation: UUID, lifecycleEpoch: Int?) async {
        let result: AuthResultPayload
        do {
            result = try decoder.decode(AuthResultPayload.self, from: data)
        } catch {
            logger.warning("Dropping auth_result: decode failed error=\(error.localizedDescription, privacy: .public)")
            return
        }
        if let lifecycleEpoch {
            emitLifecycleEvent(
                epoch: lifecycleEpoch,
                payload: .authResult(
                    success: result.success,
                    replayCount: result.replayCount,
                    replayTruncated: result.replayTruncated,
                    historyReset: result.historyReset,
                    failureReason: authFailureReason(from: result.reason)
                ),
                generation: generation
            )
        }
        if result.success {
            let resolution = await applyAuthSuccess(generation: generation)
            guard resolution.shouldProcess else { return }
            logger.info("state -> connected (auth success)")
            updateState(.connected)
            let supportsSessionProvisioning = result.features?.contains("session_info") ?? false
            emitServiceEvent(.sessionProvisioningAvailable(supportsSessionProvisioning))
            if let info = sessionInfo(from: result) {
                emitServiceEvent(.sessionInfo(info))
            }
            if let streamReadStates = result.streamReadStates {
                emitServiceEvent(.streamReadStateSnapshot(streamReadStates))
            }
            if let streamTailStates = result.streamTailStates {
                emitServiceEvent(.streamTailStateSnapshot(streamTailStates))
            }
            if let isAdmin = result.isAdmin {
                logger.info("Auth result received (userId: \(result.userId ?? "unknown", privacy: .public), isAdmin: \(isAdmin, privacy: .public))")
                let info = ChatUserInfo(userId: result.userId ?? "", isAdmin: isAdmin)
                emitServiceEvent(.userInfo(info))
            }
        } else {
            let reason = result.reason ?? "Unknown error"
            let error = Error.authFailed(reason)
            let resolution = await applyAuthFailure(generation: generation, error: error)
            guard resolution.shouldProcess else { return }
            logger.info("state -> failed (auth result) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            await transportSessionCoordinator.applyDisconnect(
                shouldNotify: false,
                reason: error.localizedDescription
            )
            if !pendingMessages.isEmpty {
                for (messageId, pending) in pendingMessages {
                    pending.retryTask?.cancel()
                    emitServiceEvent(.messageError(
                        messageId: messageId,
                        code: "connection_lost",
                        message: nil
                    ))
                }
                pendingMessages.removeAll()
            }
            updateState(.disconnected)
        }
    }

    private func handleMessage(data: Data, generation: UUID, lifecycleEpoch: Int?) async {
        if let lifecycleEpoch {
            emitLifecycleEvent(
                epoch: lifecycleEpoch,
                payload: .serverMessage(data: data),
                generation: generation
            )
            return
        }
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
        if message.id.hasPrefix("s_") {
            setReplayCursor(message.id, for: sessionKey)
        }
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
        guard let payload = try? decoder.decode(AckPayload.self, from: data) else { return }
        if let pending = pendingMessages.removeValue(forKey: payload.id) {
            pending.retryTask?.cancel()
        }
        emitServiceEvent(.messageAcked(id: payload.id))
    }

    private func handleServerError(data: Data, generation: UUID, lifecycleEpoch: Int?) async {
        let payload: ErrorPayload
        do {
            payload = try decoder.decode(ErrorPayload.self, from: data)
        } catch {
            logger.warning("Dropping error payload: decode failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        if let messageId = payload.messageId {
            if let pending = pendingMessages.removeValue(forKey: messageId) {
                pending.retryTask?.cancel()
            }
            emitServiceEvent(.messageError(messageId: messageId, code: payload.code, message: payload.message))
            return
        }

        let message = payload.message ?? payload.code
        switch payload.code {
        case "auth_failed":
            let error = Error.authFailed(message)
            if let lifecycleEpoch {
                emitLifecycleEvent(
                    epoch: lifecycleEpoch,
                    payload: .authResult(
                        success: false,
                        replayCount: nil,
                        replayTruncated: nil,
                        historyReset: nil,
                        failureReason: .rejected
                    ),
                    generation: generation
                )
            }
            let resolution = await applyAuthFailure(generation: generation, error: error)
            guard resolution.shouldProcess else { return }
            logger.info("state -> failed (server error auth_failed) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            await transportSessionCoordinator.applyDisconnect(
                shouldNotify: false,
                reason: error.localizedDescription
            )
        case "token_revoked":
            let error = Error.tokenRevoked(message)
            if let lifecycleEpoch {
                emitLifecycleEvent(
                    epoch: lifecycleEpoch,
                    payload: .authResult(
                        success: false,
                        replayCount: nil,
                        replayTruncated: nil,
                        historyReset: nil,
                        failureReason: .tokenRevoked
                    ),
                    generation: generation
                )
            }
            let resolution = await applyAuthFailure(generation: generation, error: error)
            guard resolution.shouldProcess else { return }
            logger.info("state -> failed (server error token_revoked) error=\(error.localizedDescription, privacy: .public)")
            updateState(.failed(error))
            await transportSessionCoordinator.applyDisconnect(
                shouldNotify: false,
                reason: error.localizedDescription
            )
        case "session_replaced":
            let error = Error.sessionReplaced
            if let lifecycleEpoch {
                emitLifecycleEvent(
                    epoch: lifecycleEpoch,
                    payload: .authResult(
                        success: false,
                        replayCount: nil,
                        replayTruncated: nil,
                        historyReset: nil,
                        failureReason: .sessionReplaced
                    ),
                    generation: generation
                )
            }
            logger.info("state -> failed (server error session_replaced)")
            _ = await applyAuthFailure(generation: generation, error: error)
            updateState(.failed(error))
            await transportSessionCoordinator.applyDisconnect(
                shouldNotify: false,
                reason: error.localizedDescription
            )
        case "invalid_message", "payload_too_large", "invalid_channel":
            let invalidLastMessageId = payload.code == "invalid_message"
                && isInvalidLastMessageIdMessage(payload.message)
            if invalidLastMessageId {
                clearReplayCursors()
                if let lifecycleEpoch {
                    emitLifecycleEvent(
                        epoch: lifecycleEpoch,
                        payload: .authResult(
                            success: false,
                            replayCount: nil,
                            replayTruncated: nil,
                            historyReset: nil,
                            failureReason: .invalidLastMessageId
                        ),
                        generation: generation
                    )
                } else {
                    _ = await applyAuthFailure(
                        generation: generation,
                        error: Error.authFailed("Invalid lastMessageId")
                    )
                }
            }
            logger.info("message-level error without messageId code=\(payload.code, privacy: .public)")
            if !pendingMessages.isEmpty {
                for (messageId, pending) in pendingMessages {
                    pending.retryTask?.cancel()
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
        knownSessionKeys = Set(normalizeSessionKeys(payload.sessionKeys ?? payload.sessions?.map(\.sessionKey) ?? []))
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
        let validKeys = Set(payload.streams.map(\.sessionKey))
        knownSessionKeys = validKeys
        if replayCursorBySessionKey.keys.contains(where: { !validKeys.contains($0) }) {
            replayCursorBySessionKey = replayCursorBySessionKey.filter { validKeys.contains($0.key) }
            persistReplayCursorSnapshot()
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
        knownSessionKeys.remove(payload.sessionKey)
        setReplayCursor(nil, for: payload.sessionKey)
        emitServiceEvent(.streamDeleted(sessionKey: payload.sessionKey))
    }

    private func handleStreamReadState(data: Data) {
        guard let payload = try? decoder.decode(StreamReadStatePayload.self, from: data) else {
            logger.warning("Failed to decode stream_read_state payload")
            return
        }
        emitServiceEvent(
            .streamReadStateUpdated(
                sessionKey: payload.sessionKey,
                lastReadMessageId: payload.lastReadMessageId
            )
        )
    }

    private func handleStreamTailState(data: Data) {
        guard let payload = try? decoder.decode(StreamTailStatePayload.self, from: data) else {
            logger.warning("Failed to decode stream_tail_state payload")
            return
        }
        emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: payload.sessionKey,
                tailState: payload.tailState
            )
        )
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

    private func emitLifecycleEvent(
        epoch: Int,
        payload: LifecycleTransportEvent.Payload,
        generation: UUID? = nil
    ) {
        let _ = generation
        lifecycleTransportEventBroadcaster.send(.init(epoch: epoch, payload: payload))
    }

    private func authFailureReason(from rawReason: String?) -> AuthFailureReason? {
        let normalized = (rawReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "session_replaced":
            return .sessionReplaced
        case "token_revoked":
            return .tokenRevoked
        case "auth_failed", "rejected", "device_not_approved":
            return .rejected
        case "protocol_mismatch":
            return .protocolMismatch
        default:
            return nil
        }
    }

    private func isInvalidLastMessageIdMessage(_ message: String?) -> Bool {
        let normalized = (message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        return normalized == "invalidlastmessageid"
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

    private func handleSocketClose(closeInfo: WebSocketCloseInfo?, generation: UUID, lifecycleEpoch: Int?) async {
        cancelAuthTimeout()
        let resolution = await transportSessionCoordinator.applySocketClose(
            generation: generation,
            closeInfo: closeInfo
        )
        guard resolution.shouldProcess else {
            logger.debug("ignoring stale lifecycle socket close")
            return
        }

        // Notify the UI about each pending message that failed to send
        // This removes the optimistic placeholders so users know messages weren't delivered
        for (messageId, pending) in pendingMessages {
            pending.retryTask?.cancel()
            emitServiceEvent(.messageError(
                messageId: messageId,
                code: "connection_lost",
                message: nil
            ))
        }
        pendingMessages.removeAll()

        if let rejectionError = resolution.rejectionError {
            let closeCode = String(describing: closeInfo?.code)
            let closeReason = closeInfo?.reason ?? "nil"
            logger.info(
                "state -> failed (socket close policy violation) notify=\(resolution.shouldNotifyDisconnect, privacy: .public) code=\(closeCode, privacy: .public) reason=\(closeReason, privacy: .public)"
            )
            updateState(.failed(rejectionError))
            if resolution.shouldNotifyDisconnect {
                emitServiceEvent(
                    .connectionInterrupted(
                        reason: rejectionError.errorDescription ?? resolution.pendingDisconnectReason
                    )
                )
            }
            if let lifecycleEpoch {
                emitLifecycleEvent(
                    epoch: lifecycleEpoch,
                    payload: .transportClosed(reason: .error),
                    generation: generation
                )
            }
        } else {
            logger.info("state -> disconnected (socket close) notify=\(resolution.shouldNotifyDisconnect, privacy: .public)")
            updateState(.disconnected)
            if resolution.shouldNotifyDisconnect {
                emitServiceEvent(.connectionInterrupted(reason: resolution.pendingDisconnectReason))
            }
            if let lifecycleEpoch {
                let reason: TransportCloseReason = {
                    if closeInfo?.code == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue { return .clean }
                    if closeInfo?.reason?.lowercased().contains("keepalive") == true { return .keepaliveTimeout }
                    return .error
                }()
                emitLifecycleEvent(
                    epoch: lifecycleEpoch,
                    payload: .transportClosed(reason: reason),
                    generation: generation
                )
            }
        }
    }

    private func teardownConnection() async throws {
        cancelAuthTimeout()
        await transportSessionCoordinator.applyDisconnect(shouldNotify: false)
    }

    private func cancelAuthTimeout() {
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
    }

    private func resolveAuthContinuation(with result: Result<Void, Swift.Error>) async {
        cancelAuthTimeout()
        await transportSessionCoordinator.resolveAuthContinuation(with: result)
    }

    private func applyAuthSuccess(generation: UUID) async -> TransportSessionCoordinator.AuthResultResolution {
        cancelAuthTimeout()
        return await transportSessionCoordinator.applyAuthSuccess(generation: generation)
    }

    private func applyAuthFailure(
        generation: UUID,
        error: Swift.Error
    ) async -> TransportSessionCoordinator.FailureResolution {
        cancelAuthTimeout()
        return await transportSessionCoordinator.applyAuthFailure(generation: generation, error: error)
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

    private func awaitAuthResult(
        client: any WebSocketClient,
        generation: UUID,
        token: String,
        forcedLastMessageId: String?
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            Task { [weak self] in
                guard let self else {
                    continuation.resume(throwing: Error.notConnected)
                    return
                }
                let installed = await self.transportSessionCoordinator.installAuthContinuation(
                    continuation,
                    generation: generation
                )
                guard installed else { return }
                self.cancelAuthTimeout()
                let authTimeout = self.authTimeout
                self.authTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(forDuration: authTimeout)
                    } catch {
                        return
                    }
                    await self?.resolveAuthContinuation(with: .failure(Error.authTimeout))
                }
                do {
                    let replayCursorSnapshot = self.replayCursorSnapshot()
                    let candidateLastMessageId = forcedLastMessageId ?? self.resolveAuthLastMessageId(
                        replayCursorSnapshot: replayCursorSnapshot,
                        knownSessionKeys: self.knownSessionKeys
                    )
                    let lastMessageId = self.normalizeServerEventID(candidateLastMessageId)
                    try await self.sendAuth(client: client, token: token, lastMessageId: lastMessageId)
                } catch {
                    await self.resolveAuthContinuation(with: .failure(error))
                }
            }
        }
    }

    private func replayCursorDefaultsKey() -> String {
        let rawUserId = userIdProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userComponent = rawUserId.isEmpty ? "anon" : rawUserId
        return "clawline.replayCursorBySession.v1.\(userComponent).\(deviceId)"
    }

    private func restoreReplayCursorSnapshot() -> [String: String] {
        guard let data = replayCursorDefaults.data(forKey: replayCursorDefaultsKey()) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var sanitized: [String: String] = [:]
        for (rawKey, rawCursor) in decoded {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let cursor = normalizeServerEventID(rawCursor) else { continue }
            sanitized[key] = cursor
        }
        return sanitized
    }

    private func persistReplayCursorSnapshot() {
        guard let data = try? JSONEncoder().encode(replayCursorBySessionKey) else { return }
        replayCursorDefaults.set(data, forKey: replayCursorDefaultsKey())
    }

    private func resolveAuthLastMessageId(
        replayCursorSnapshot: [String: String],
        knownSessionKeys: Set<String>
    ) -> String? {
        let normalizedKnownKeys = knownSessionKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedKnownKeys.isEmpty else {
            return nil
        }
        guard normalizedKnownKeys.allSatisfy({
            guard let candidate = replayCursorSnapshot[$0] else { return false }
            return normalizeServerEventID(candidate) != nil
        }) else {
            return nil
        }
        return replayCursorSnapshot.values.compactMap(normalizeServerEventID).max()
    }
    private func normalizeServerEventID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.serverEventIDPrefix) else { return nil }
        return trimmed
    }
}

private final class StandaloneProviderTransportService: ProviderChatService, DirectChatConnecting {
    func connect(token: String, lastMessageId: String?) async throws {
        let admission = await transportSessionCoordinator.prepareStandaloneConnect(
            token: token,
            lastMessageId: lastMessageId
        )
        if admission.shouldReuseConnected {
            return
        }
        if let generation = admission.generation {
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.performStandaloneConnect(token: token, lastMessageId: lastMessageId)
                } catch {
                    await self.transportSessionCoordinator.applyDisconnect(
                        shouldNotify: false,
                        reason: error.localizedDescription
                    )
                }
            }
            _ = await transportSessionCoordinator.attachAttemptTask(task, generation: generation)
        }
        try await transportSessionCoordinator.waitForStandaloneAttemptToFinish()
    }
}

final class ProviderDirectChatClient: DirectChatConnecting {
    private let service: StandaloneProviderTransportService

    init(connector: any WebSocketConnecting,
         deviceId: String,
         baseURLProvider: @escaping () -> URL? = { ProviderBaseURLStore.baseURL },
         userIdProvider: @escaping () -> String? = { nil },
         authTokenProvider: @escaping @Sendable () async -> String? = { nil },
         streamAPIClient: StreamAPIClient? = nil,
         encoder: JSONEncoder = JSONEncoder(),
         decoder: JSONDecoder = JSONDecoder()) {
        self.service = StandaloneProviderTransportService(
            connector: connector,
            deviceId: deviceId,
            transportOwnerMode: .standalone,
            baseURLProvider: baseURLProvider,
            userIdProvider: userIdProvider,
            authTokenProvider: authTokenProvider,
            streamAPIClient: streamAPIClient,
            encoder: encoder,
            decoder: decoder
        )
    }

    var incomingMessages: AsyncStream<Message> { service.incomingMessages }
    var connectionState: AsyncStream<ConnectionState> { service.connectionState }
    var serviceEvents: AsyncStream<ChatServiceEvent> { service.serviceEvents }

    func connect(token: String, lastMessageId: String?) async throws {
        try await service.connect(token: token, lastMessageId: lastMessageId)
    }

    func disconnect() {
        service.disconnect()
    }

    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?
    ) async throws {
        try await service.send(
            id: id,
            content: content,
            attachments: attachments,
            sessionKey: sessionKey
        )
    }
}
