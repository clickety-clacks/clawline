//
//  StubChatService.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

final class StubChatService: ChatServicing {
    var responseDelay: TimeInterval = 1.5
    private var streams: [StreamSession] = []
    private var replayCursorBySessionKey: [String: String] = [:]
    private var latestConnectionState: ConnectionState = .disconnected

    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var serviceEventContinuation: AsyncStream<ChatServiceEvent>.Continuation?
    private var lifecycleContinuation: AsyncStream<LifecycleTransportEvent>.Continuation?

    private(set) lazy var incomingMessages: AsyncStream<Message> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // No cleanup needed for stub.
            }
        }
    }()

    private(set) lazy var connectionState: AsyncStream<ConnectionState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(.disconnected)
        }
    }()

    private(set) lazy var serviceEvents: AsyncStream<ChatServiceEvent> = {
        AsyncStream { continuation in
            self.serviceEventContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // No cleanup needed for stub.
            }
        }
    }()

    private(set) lazy var lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent> = {
        AsyncStream { continuation in
            self.lifecycleContinuation = continuation
        }
    }()

    var isTransportReadyForSend: Bool {
        latestConnectionState == .connected
    }

    func connect(token: String, lastMessageId: String?) async throws {
        _ = lastMessageId
        stateContinuation?.yield(.connecting)
        latestConnectionState = .connecting
        try await Task.sleep(forDuration: .milliseconds(500))
        if streams.isEmpty {
            let now = Date()
            streams = [
                StreamSession(
                    sessionKey: "agent:main:clawline:preview:main",
                    displayName: "Personal",
                    kind: "main",
                    orderIndex: 0,
                    isBuiltIn: true,
                    createdAt: now,
                    updatedAt: now
                )
            ]
        }
        serviceEventContinuation?.yield(.streamSnapshot(streams))
        stateContinuation?.yield(.connected)
        latestConnectionState = .connected
    }

    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {
        _ = lastMessageId
        Task {
            do {
                try await connect(token: token, lastMessageId: nil)
                lifecycleContinuation?.yield(.init(
                    epoch: epoch,
                    payload: .authResult(success: true, replayCount: 0, replayTruncated: false, historyReset: false, failureReason: nil)
                ))
                lifecycleContinuation?.yield(.init(epoch: epoch, payload: .syncComplete))
            } catch {
                lifecycleContinuation?.yield(.init(epoch: epoch, payload: .transportClosed(reason: .error)))
            }
        }
    }

    func stopConnectionAttempt() {
        disconnect()
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
        latestConnectionState = .disconnected
    }

    func replayCursorSnapshot() -> [String: String] {
        replayCursorBySessionKey
    }

    func setReplayCursor(_ cursor: String?, for sessionKey: String) {
        if let cursor, !cursor.isEmpty {
            replayCursorBySessionKey[sessionKey] = cursor
        } else {
            replayCursorBySessionKey.removeValue(forKey: sessionKey)
        }
    }

    func seedReplayCursorIfMissing(_ cursor: String?, for sessionKey: String) {
        guard replayCursorBySessionKey[sessionKey] == nil else { return }
        if let cursor, !cursor.isEmpty {
            replayCursorBySessionKey[sessionKey] = cursor
        }
    }

    func clearReplayCursors() {
        replayCursorBySessionKey.removeAll()
    }

    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?
    ) async throws {
        try await Task.sleep(for: .seconds(responseDelay))
        serviceEventContinuation?.yield(.messageAcked(id: id))

        let resolvedSessionKey = sessionKey ?? "local:personal"
        let response = Message(
            id: UUID().uuidString,
            role: .assistant,
            content: "You said: \(content)",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: resolvedSessionKey
        )

        messageContinuation?.yield(response)
    }

    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {
        // No-op for stub.
    }

    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {
        // No-op for stub.
    }

    func fetchStreams() async throws -> [StreamSession] {
        streams
    }

    func fetchTrackableSessions() async throws -> [TrackableSession] {
        []
    }

    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus {
        throw ProviderChatService.Error.notConnected
    }

    func applySessionControl(
        sessionKey: String,
        action: SessionControlAction,
        value: String?,
        enabled: Bool?
    ) async throws -> SessionControlResponse {
        throw ProviderChatService.Error.notConnected
    }

    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        let now = Date()
        let stream = StreamSession(
            sessionKey: "agent:main:clawline:preview:s_\(UUID().uuidString.prefix(8).lowercased())",
            displayName: displayName,
            kind: "custom",
            orderIndex: streams.count,
            isBuiltIn: false,
            createdAt: now,
            updatedAt: now
        )
        streams.append(stream)
        serviceEventContinuation?.yield(.streamCreated(stream))
        return stream
    }

    func adoptStream(sessionKey: String) async throws -> StreamSession {
        let now = Date()
        let stream = StreamSession(
            sessionKey: sessionKey,
            displayName: "Adopted Session",
            kind: "custom",
            orderIndex: streams.count,
            isBuiltIn: false,
            createdAt: now,
            updatedAt: now,
            trackingMode: .adopted
        )
        streams.append(stream)
        serviceEventContinuation?.yield(.streamCreated(stream))
        return stream
    }

    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        guard let index = streams.firstIndex(where: { $0.sessionKey == sessionKey }) else {
            throw StreamAPIError(code: "stream_not_found", message: "Stream not found", statusCode: 404)
        }
        var stream = streams[index]
        stream.displayName = displayName
        streams[index] = stream
        serviceEventContinuation?.yield(.streamUpdated(stream))
        return stream
    }

    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String {
        guard let index = streams.firstIndex(where: { $0.sessionKey == sessionKey }) else {
            throw StreamAPIError(code: "stream_not_found", message: "Stream not found", statusCode: 404)
        }
        streams.remove(at: index)
        serviceEventContinuation?.yield(.streamDeleted(sessionKey: sessionKey))
        return sessionKey
    }

    func emitServiceEvent(_ event: ChatServiceEvent) {
        serviceEventContinuation?.yield(event)
    }
}
