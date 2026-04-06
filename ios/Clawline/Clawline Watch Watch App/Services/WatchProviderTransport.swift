import Foundation
import Observation
import WatchConnectivity
import Network

@MainActor
@Observable
final class WatchProviderTransport: ChatServicing {
    enum TransportError: Swift.Error, LocalizedError {
        case missingCredentials
        case notConnected
        case authFailed(String)
        case malformedReply
        case unsupported

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Open Clawline on iPhone to pair"
            case .notConnected:
                return "No transport available"
            case .authFailed(let reason):
                return "Auth failed: \(reason)"
            case .malformedReply:
                return "Malformed relay reply"
            case .unsupported:
                return "Unsupported operation"
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
        let id: String
        let features: [String]?
    }

    private struct AuthResultPayload: Decodable {
        let type: String
        let success: Bool
        let userId: String?
        let isAdmin: Bool?
        let dmScope: String?
        let features: [String]?
        let sessionKeys: [String]?
        let streamReadStates: [String: String]?
        let streamTailStates: [String: StreamTailState]?
        let reason: String?
    }

    private struct Envelope: Decodable {
        let type: String
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

    private struct SessionInfoPayload: Decodable {
        let type: String
        let userId: String?
        let isAdmin: Bool?
        let dmScope: String?
        let sessionKeys: [String]?
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

    private struct EventEnvelope: Decodable {
        let type: String
        let event: String
    }

    private struct BufferedMessage {
        let id: String
        let content: String
        let attachments: [WireAttachment]
        let sessionKey: String?
        let createdAt: Date
    }

    private let credentialStore: WatchCredentialStore
    private let streamAPIClient = WatchStreamAPIClient()
    private let urlSession = URLSession(configuration: .default)
    private let directNetworkMonitor = DirectNetworkMonitor()

    private let messageBroadcaster = AsyncStreamBroadcaster<Message>()
    private let stateBroadcaster = AsyncStreamBroadcaster<ConnectionState>()
    private let eventBroadcaster = AsyncStreamBroadcaster<ChatServiceEvent>()

    var incomingMessages: AsyncStream<Message> { messageBroadcaster.stream() }
    var connectionState: AsyncStream<ConnectionState> { stateBroadcaster.stream(initial: mappedConnectionState()) }
    var serviceEvents: AsyncStream<ChatServiceEvent> { eventBroadcaster.stream() }

    private(set) var transportState: WatchProviderTransportState = .disconnected {
        didSet {
            guard oldValue != transportState else { return }
            stateBroadcaster.send(mappedConnectionState())
            if transportState == .relay {
                notifyRelayActivated()
            } else if oldValue == .relay {
                notifyRelayDeactivated()
            }
        }
    }

    private(set) var pendingBufferCount: Int = 0

    private var websocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var relayProbeTask: Task<Void, Never>?
    private var probingTask: Task<Void, Never>?
    private var reachabilityDebounceTask: Task<Void, Never>?

    private var isPhoneReachable: Bool = false
    private var isDirectNetworkReachable: Bool = true
    private var pendingMessages: [BufferedMessage] = []
    private var authContinuation: CheckedContinuation<Void, Swift.Error>?

    private let deviceId = "watch_\(UUID().uuidString)"

    init(credentialStore: WatchCredentialStore) {
        self.credentialStore = credentialStore
        self.credentialStore.onCredentialsChanged = { [weak self] in
            Task { @MainActor in
                self?.handleCredentialUpdate()
            }
        }

        isDirectNetworkReachable = directNetworkMonitor.isReachable
        directNetworkMonitor.onChange = { [weak self] reachable in
            Task { @MainActor in
                self?.handleDirectNetworkChange(reachable)
            }
        }

        Task { [weak self] in
            await self?.start()
        }
    }

    func connect(token: String, lastMessageId: String?) async throws {
        _ = token
        _ = lastMessageId
        try await ensureDirectConnected()
    }

    func disconnect() {
        teardownDirectConnection()
        transportState = .disconnected
    }

    func fetchTrackableSessions() async throws -> [TrackableSession] {
        []
    }

    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {
        let message = BufferedMessage(
            id: id,
            content: content,
            attachments: attachments,
            sessionKey: sessionKey,
            createdAt: Date()
        )

        switch transportState {
        case .direct:
            do {
                try await sendDirect(message)
            } catch {
                enterProbing(reason: "send failure")
                buffer(message)
                throw error
            }
        case .relay:
            do {
                let _: [String: Any] = try await sendRelayRequest(
                    type: RelayMessageType.chatSend,
                    payload: [
                        "id": id,
                        "content": content,
                        "attachments": try JSONEncoder().encodeToDictionary(attachments),
                        "sessionKey": sessionKey as Any
                    ]
                )
                eventBroadcaster.send(.messageAcked(id: id))
            } catch {
                buffer(message)
                throw error
            }
        case .probing, .disconnected:
            buffer(message)
        }
    }

    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {
        switch transportState {
        case .direct:
            guard let websocketTask else { throw TransportError.notConnected }
            let payload: [String: Any] = [
                "type": "interactive-callback",
                "messageId": sourceMessageId,
                "payload": [
                    "action": action,
                    "data": data?.anyValue as Any
                ]
            ]
            let text = try payload.toJSONString()
            try await websocketTask.send(.string(text))
        case .relay:
            _ = try await sendRelayRequest(
                type: RelayMessageType.chatCallback,
                payload: [
                    "sourceMessageId": sourceMessageId,
                    "action": action,
                    "data": data?.anyValue as Any
                ]
            )
        case .probing, .disconnected:
            throw TransportError.notConnected
        }
    }


    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {
        switch transportState {
        case .direct:
            guard let websocketTask else { throw TransportError.notConnected }
            let payload: [String: Any] = [
                "type": "stream_read",
                "sessionKey": sessionKey,
                "lastReadMessageId": lastReadMessageId
            ]
            let text = try payload.toJSONString()
            try await websocketTask.send(.string(text))
        case .relay:
            _ = try await sendRelayRequest(
                type: RelayMessageType.streamRead,
                payload: [
                    "sessionKey": sessionKey,
                    "lastReadMessageId": lastReadMessageId
                ]
            )
        case .probing, .disconnected:
            throw TransportError.notConnected
        }
    }

    func fetchStreams() async throws -> [StreamSession] {
        if transportState == .relay {
            let response = try await sendRelayRequest(type: RelayMessageType.streamsFetch, payload: [:])
            guard let payload = response["payload"] as? [String: Any],
                  let streamsRaw = payload["streams"] else {
                throw TransportError.malformedReply
            }
            return try decodeJSONValue(streamsRaw, as: [StreamSession].self)
        }

        guard let baseURL = credentialStore.providerBaseURL else {
            throw TransportError.missingCredentials
        }

        return try await streamAPIClient.fetchStreams(baseURL: baseURL, token: credentialStore.providerToken)
    }

    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        if transportState == .relay {
            let response = try await sendRelayRequest(
                type: RelayMessageType.streamsCreate,
                payload: ["displayName": displayName, "idempotencyKey": idempotencyKey]
            )
            guard let payload = response["payload"] as? [String: Any],
                  let streamRaw = payload["stream"] else {
                throw TransportError.malformedReply
            }
            return try decodeJSONValue(streamRaw, as: StreamSession.self)
        }

        guard let baseURL = credentialStore.providerBaseURL else {
            throw TransportError.missingCredentials
        }

        return try await streamAPIClient.createStream(
            baseURL: baseURL,
            displayName: displayName,
            idempotencyKey: idempotencyKey,
            token: credentialStore.providerToken
        )
    }

    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        if transportState == .relay {
            let response = try await sendRelayRequest(
                type: RelayMessageType.streamsRename,
                payload: ["sessionKey": sessionKey, "displayName": displayName]
            )
            guard let payload = response["payload"] as? [String: Any],
                  let streamRaw = payload["stream"] else {
                throw TransportError.malformedReply
            }
            return try decodeJSONValue(streamRaw, as: StreamSession.self)
        }

        guard let baseURL = credentialStore.providerBaseURL else {
            throw TransportError.missingCredentials
        }

        return try await streamAPIClient.renameStream(
            baseURL: baseURL,
            sessionKey: sessionKey,
            displayName: displayName,
            token: credentialStore.providerToken
        )
    }

    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String {
        if transportState == .relay {
            let response = try await sendRelayRequest(
                type: RelayMessageType.streamsDelete,
                payload: ["sessionKey": sessionKey, "idempotencyKey": idempotencyKey as Any]
            )
            guard let payload = response["payload"] as? [String: Any],
                  let deleted = payload["deletedKey"] as? String else {
                throw TransportError.malformedReply
            }
            return deleted
        }

        guard let baseURL = credentialStore.providerBaseURL else {
            throw TransportError.missingCredentials
        }

        return try await streamAPIClient.deleteStream(
            baseURL: baseURL,
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey,
            token: credentialStore.providerToken
        )
    }

    func handleRelayPush(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case RelayMessageType.chatIncoming:
            guard let payload = message["payload"] as? [String: Any],
                  let serialized = payload["json"] as? String,
                  let data = serialized.data(using: .utf8),
                  let serverPayload = try? JSONDecoder().decode(ServerMessagePayload.self, from: data),
                  let sessionKey = serverPayload.sessionKey else {
                return
            }
            messageBroadcaster.send(Message(payload: serverPayload, sessionKey: sessionKey))
        case RelayMessageType.event:
            guard let payload = message["payload"] as? [String: Any],
                  let serialized = payload["json"] as? String,
                  let data = serialized.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(RelayEventEnvelope.self, from: data),
                  let event = envelope.toEvent() else {
                return
            }
            eventBroadcaster.send(event)
        default:
            break
        }
    }

    func setPhoneReachable(_ reachable: Bool) {
        reachabilityDebounceTask?.cancel()
        reachabilityDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                self?.isPhoneReachable = reachable
                self?.handleReachabilityChange()
            }
        }
    }

    private func start() async {
        await reconnectForBestTransport()
    }

    private func handleCredentialUpdate() {
        Task { [weak self] in
            await self?.reconnectForBestTransport()
        }
    }

    private func handleReachabilityChange() {
        if transportState == .disconnected {
            enterProbing(reason: "reachability changed")
        }
        if transportState == .probing {
            return
        }
        if transportState == .relay {
            if !isPhoneReachable {
                enterProbing(reason: "phone unreachable during relay")
            }
            return
        }
        if transportState == .direct, websocketTask == nil {
            enterProbing(reason: "direct socket lost")
        }
    }

    private func handleDirectNetworkChange(_ reachable: Bool) {
        guard isDirectNetworkReachable != reachable else { return }
        isDirectNetworkReachable = reachable

        if transportState == .disconnected, reachable {
            enterProbing(reason: "network regained")
        }
    }

    private func reconnectForBestTransport() async {
        guard credentialStore.hasProviderCredentials else {
            teardownDirectConnection()
            transportState = .disconnected
            return
        }

        do {
            try await ensureDirectConnected()
            transportState = .direct
            flushBufferedMessages()
            startPingLoop()
            return
        } catch {
            enterProbing(reason: "initial connect failed")
        }
    }

    private func ensureDirectConnected() async throws {
        guard credentialStore.hasProviderCredentials,
              let baseURL = credentialStore.providerBaseURL,
              let token = credentialStore.providerToken else {
            throw TransportError.missingCredentials
        }

        if transportState == .direct, websocketTask != nil {
            return
        }

        let candidateURLs = ProviderWebSocketURLBuilder.candidateURLs(from: baseURL, defaultPath: "/ws")
        guard !candidateURLs.isEmpty else {
            throw TransportError.notConnected
        }

        stateBroadcaster.send(.connecting)

        var lastError: Error = TransportError.notConnected
        for url in candidateURLs {
            do {
                try await connectDirect(url: url, token: token)
                transportState = .direct
                return
            } catch {
                lastError = error
                teardownDirectConnection()
            }
        }

        throw lastError
    }

    private func connectDirect(url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")

        let task = urlSession.webSocketTask(with: request)
        websocketTask = task
        task.resume()

        startReceiveLoop(task)

        let payload = AuthPayload(
            token: token,
            deviceId: deviceId,
            lastMessageId: nil,
            clientFeatures: ["terminal_bubbles_v1"],
            client: ClientDescriptor(id: "openclaw-watch", features: ["terminal_bubbles_v1"])
        )

        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransportError.notConnected
        }

        try await task.send(.string(text))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.waitForAuthResult()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw TransportError.authFailed("Timeout")
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func enterProbing(reason: String) {
        _ = reason
        guard transportState != .probing else { return }
        transportState = .probing
        teardownDirectConnection()

        probingTask?.cancel()
        probingTask = Task { [weak self] in
            guard let self else { return }
            let backoffs: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]
            for delay in backoffs {
                if Task.isCancelled { return }
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                do {
                    try await self.ensureDirectConnected()
                    await MainActor.run {
                        self.transportState = .direct
                        self.flushBufferedMessages()
                        self.startPingLoop()
                    }
                    return
                } catch {
                    continue
                }
            }

            await MainActor.run {
                if self.isPhoneReachable {
                    self.transportState = .relay
                    self.startRelayProbeLoop()
                    self.flushBufferedMessages()
                } else {
                    self.transportState = .disconnected
                }
            }
        }
    }

    private func startRelayProbeLoop() {
        relayProbeTask?.cancel()
        relayProbeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                do {
                    try await self.ensureDirectConnected()
                    await MainActor.run {
                        self.transportState = .direct
                        self.stopRelayProbeLoop()
                        self.flushBufferedMessages()
                        self.startPingLoop()
                    }
                    break
                } catch {
                    continue
                }
            }
        }
    }

    private func stopRelayProbeLoop() {
        relayProbeTask?.cancel()
        relayProbeTask = nil
    }

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                do {
                    try await self.ping(timeout: .seconds(5))
                } catch {
                    await MainActor.run {
                        self.enterProbing(reason: "ping timeout")
                    }
                    break
                }
            }
        }
    }

    private func ping(timeout: Duration) async throws {
        guard let websocketTask else {
            throw TransportError.notConnected
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                    websocketTask.sendPing { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.notConnected
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    let text: String?
                    switch message {
                    case .string(let value):
                        text = value
                    case .data(let value):
                        text = String(data: value, encoding: .utf8)
                    @unknown default:
                        text = nil
                    }

                    if let text {
                        await MainActor.run {
                            self.handleIncoming(text: text)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.resolveAuthContinuation(with: .failure(error))
                        if self.transportState == .direct {
                            self.enterProbing(reason: "socket closed")
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleIncoming(text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return
        }

        switch envelope.type {
        case "auth_result":
            handleAuthResult(data)
        case "message":
            handleServerMessage(data)
        case "ack":
            if let ack = try? JSONDecoder().decode(AckPayload.self, from: data) {
                eventBroadcaster.send(.messageAcked(id: ack.id))
            }
        case "error":
            handleServerError(data)
        case "user_info":
            if let payload = try? JSONDecoder().decode(UserInfoPayload.self, from: data) {
                eventBroadcaster.send(.userInfo(ChatUserInfo(userId: payload.userId, isAdmin: payload.isAdmin)))
            }
        case "typing":
            if let payload = try? JSONDecoder().decode(TypingEventPayload.self, from: data),
               let sessionKey = payload.sessionKey {
                eventBroadcaster.send(.typingStateChanged(isTyping: payload.active, sessionKey: sessionKey))
            }
        case "session_info":
            if let payload = try? JSONDecoder().decode(SessionInfoPayload.self, from: data) {
                eventBroadcaster.send(
                    .sessionInfo(
                        SessionInfo(
                            userId: payload.userId,
                            isAdmin: payload.isAdmin,
                            dmScope: payload.dmScope,
                            sessionKeys: payload.sessionKeys ?? []
                        )
                    )
                )
            }
        case "stream_snapshot":
            if let payload = try? JSONDecoder().decode(StreamSnapshotPayload.self, from: data) {
                eventBroadcaster.send(.streamSnapshot(payload.streams))
            }
        case "stream_created":
            if let payload = try? JSONDecoder().decode(StreamMutationPayload.self, from: data) {
                eventBroadcaster.send(.streamCreated(payload.stream))
            }
        case "stream_updated":
            if let payload = try? JSONDecoder().decode(StreamMutationPayload.self, from: data) {
                eventBroadcaster.send(.streamUpdated(payload.stream))
            }
        case "stream_deleted":
            if let payload = try? JSONDecoder().decode(StreamDeletedPayload.self, from: data) {
                eventBroadcaster.send(.streamDeleted(sessionKey: payload.sessionKey))
            }
        case "stream_read_state":
            if let payload = try? JSONDecoder().decode(StreamReadStatePayload.self, from: data) {
                eventBroadcaster.send(
                    .streamReadStateUpdated(
                        sessionKey: payload.sessionKey,
                        lastReadMessageId: payload.lastReadMessageId
                    )
                )
            }
        case "stream_tail_state":
            if let payload = try? JSONDecoder().decode(StreamTailStatePayload.self, from: data) {
                eventBroadcaster.send(
                    .streamTailStateUpdated(
                        sessionKey: payload.sessionKey,
                        tailState: payload.tailState
                    )
                )
            }
        case "event":
            if let payload = try? JSONDecoder().decode(EventEnvelope.self, from: data), payload.event == "activity",
               let activity = try? JSONDecoder().decode(ActivityEventPayload.self, from: data),
               let sessionKey = activity.payload.sessionKey {
                eventBroadcaster.send(.typingStateChanged(isTyping: activity.payload.isActive, sessionKey: sessionKey))
            }
        default:
            break
        }
    }

    private func handleAuthResult(_ data: Data) {
        guard let result = try? JSONDecoder().decode(AuthResultPayload.self, from: data) else {
            return
        }

        if result.success {
            resolveAuthContinuation(with: .success(()))
            transportState = .direct
            if let sessionKeys = result.sessionKeys {
                eventBroadcaster.send(
                    .sessionInfo(
                        SessionInfo(
                            userId: result.userId,
                            isAdmin: result.isAdmin,
                            dmScope: result.dmScope,
                            sessionKeys: sessionKeys
                        )
                    )
                )
            }
            if let streamReadStates = result.streamReadStates {
                eventBroadcaster.send(.streamReadStateSnapshot(streamReadStates))
            }
            if let streamTailStates = result.streamTailStates {
                eventBroadcaster.send(.streamTailStateSnapshot(streamTailStates))
            }
            if let userId = result.userId, let isAdmin = result.isAdmin {
                eventBroadcaster.send(.userInfo(ChatUserInfo(userId: userId, isAdmin: isAdmin)))
            }
        } else {
            resolveAuthContinuation(with: .failure(TransportError.authFailed(result.reason ?? "Unknown")))
        }
    }

    private func handleServerMessage(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(ServerMessagePayload.self, from: data),
              let sessionKey = payload.sessionKey else {
            return
        }
        messageBroadcaster.send(Message(payload: payload, sessionKey: sessionKey))
    }

    private func handleServerError(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else { return }

        if let messageId = payload.messageId {
            eventBroadcaster.send(.messageError(messageId: messageId, code: payload.code, message: payload.message))
            return
        }

        if payload.code == "auth_failed" || payload.code == "token_revoked" {
            resolveAuthContinuation(with: .failure(TransportError.authFailed(payload.message ?? payload.code)))
            teardownDirectConnection()
            Task { [weak self] in
                await self?.attemptAuthRefreshAfterFailure(reason: payload.message ?? payload.code)
            }
            return
        }

        eventBroadcaster.send(.connectionInterrupted(reason: payload.message ?? payload.code))
    }

    private func attemptAuthRefreshAfterFailure(reason: String) async {
        guard isPhoneReachable else {
            transportState = .disconnected
            eventBroadcaster.send(.connectionInterrupted(reason: "Re-open Clawline on iPhone"))
            return
        }

        do {
            let response = try await sendRelayRequest(type: RelayMessageType.authRefresh, payload: [:])
            guard let payload = response["payload"] as? [String: Any] else {
                throw TransportError.malformedReply
            }

            credentialStore.apply(userInfo: payload)

            if credentialStore.hasProviderCredentials {
                enterProbing(reason: "auth refresh")
            } else {
                transportState = .disconnected
                eventBroadcaster.send(.connectionInterrupted(reason: "Re-open Clawline on iPhone"))
            }
        } catch {
            transportState = .disconnected
            eventBroadcaster.send(.connectionInterrupted(reason: reason))
        }
    }

    private func teardownDirectConnection() {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        websocketTask?.cancel(with: .normalClosure, reason: nil)
        websocketTask = nil

        resolveAuthContinuation(with: .failure(TransportError.notConnected))
    }

    private func sendDirect(_ message: BufferedMessage) async throws {
        guard let websocketTask else {
            throw TransportError.notConnected
        }
        let payload = ClientMessagePayload(
            id: message.id,
            content: message.content,
            attachments: message.attachments,
            sessionKey: message.sessionKey
        )
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransportError.notConnected
        }
        try await websocketTask.send(.string(text))
    }

    private func buffer(_ message: BufferedMessage) {
        pendingMessages.append(message)

        if pendingMessages.count > 20 {
            let overflow = pendingMessages.count - 20
            let dropped = Array(pendingMessages.prefix(overflow))
            pendingMessages.removeFirst(overflow)
            for droppedMessage in dropped {
                eventBroadcaster.send(
                    .messageError(
                        messageId: droppedMessage.id,
                        code: "buffer_full",
                        message: "Message dropped while reconnecting"
                    )
                )
            }
        }

        pendingBufferCount = pendingMessages.count
    }

    private func waitForAuthResult() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            authContinuation = continuation
        }
    }

    private func flushBufferedMessages() {
        guard !pendingMessages.isEmpty else { return }

        let now = Date()
        let valid = pendingMessages.filter { now.timeIntervalSince($0.createdAt) <= 60 }
        let expired = pendingMessages.filter { now.timeIntervalSince($0.createdAt) > 60 }
        pendingMessages.removeAll()
        pendingBufferCount = 0

        for message in expired {
            eventBroadcaster.send(.messageError(messageId: message.id, code: "expired", message: "Buffered message expired"))
        }

        for message in valid {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.send(id: message.id, content: message.content, attachments: message.attachments, sessionKey: message.sessionKey)
                } catch {
                    await MainActor.run {
                        self.eventBroadcaster.send(
                            .messageError(
                                messageId: message.id,
                                code: "send_failed",
                                message: error.localizedDescription
                            )
                        )
                    }
                }
            }
        }
    }

    private func resolveAuthContinuation(with result: Result<Void, Swift.Error>) {
        guard let authContinuation else { return }
        self.authContinuation = nil
        switch result {
        case .success:
            authContinuation.resume()
        case .failure(let error):
            authContinuation.resume(throwing: error)
        }
    }

    private func mappedConnectionState() -> ConnectionState {
        switch transportState {
        case .direct:
            return .connected
        case .probing:
            return .reconnecting
        case .relay:
            return .connected
        case .disconnected:
            return .disconnected
        }
    }

    private func notifyRelayActivated() {
        Task {
            _ = try? await sendRelayRequest(type: RelayMessageType.relayActivated, payload: [:], expectsReply: false)
        }
        startRelayProbeLoop()
    }

    private func notifyRelayDeactivated() {
        Task {
            _ = try? await sendRelayRequest(type: RelayMessageType.relayDeactivated, payload: [:], expectsReply: false)
        }
        stopRelayProbeLoop()
    }

    private func sendRelayRequest(
        type: String,
        payload: [String: Any],
        expectsReply: Bool = true
    ) async throws -> [String: Any] {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            throw TransportError.notConnected
        }

        let requestId = "req_\(UUID().uuidString)"
        let message: [String: Any] = [
            "type": type,
            "requestId": requestId,
            "payload": payload
        ]

        if !expectsReply {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
            return [:]
        }

        let response: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message) { reply in
                continuation.resume(returning: reply)
            } errorHandler: { error in
                continuation.resume(throwing: error)
            }
        }

        if let errorPayload = response["error"] as? [String: Any],
           let code = errorPayload["code"] as? String {
            let message = (errorPayload["message"] as? String) ?? "Relay error"
            throw RelayProtocolError.server(code: code, message: message)
        }

        return response
    }

    private func decodeJSONValue<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private enum ProviderWebSocketURLBuilder {
    static func candidateURLs(from baseURL: URL, defaultPath: String) -> [URL] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return []
        }

        let path = components.path
        if path.isEmpty || path == "/" {
            components.path = defaultPath
        } else if !path.hasSuffix(defaultPath) {
            if path.hasSuffix("/") {
                components.path = path + String(defaultPath.dropFirst())
            } else {
                components.path = path + defaultPath
            }
        }

        let schemes = ["wss", "ws"]
        var urls: [URL] = []
        var seen = Set<String>()
        for scheme in schemes {
            components.scheme = scheme
            guard let url = components.url else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }
}

private extension JSONEncoder {
    func encodeToDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

private extension Dictionary where Key == String, Value == Any {
    func toJSONString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: self, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayProtocolError.malformed
        }
        return text
    }
}

private final class DirectNetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "co.clicketyclacks.clawline.watch.transport.network")

    private(set) var isReachable: Bool = true
    var onChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied &&
                (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.cellular))
            guard reachable != self.isReachable else { return }
            self.isReachable = reachable
            self.onChange?(reachable)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private extension JSONValue {
    var anyValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.anyValue)
        case .object(let object):
            return object.mapValues { $0.anyValue }
        }
    }
}
