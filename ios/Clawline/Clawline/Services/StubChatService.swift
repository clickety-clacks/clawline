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
    private var latestConnectionState: ConnectionState = .disconnected

    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var serviceEventContinuation: AsyncStream<ChatServiceEvent>.Continuation?

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

    func disconnect() {
        stateContinuation?.yield(.disconnected)
        latestConnectionState = .disconnected
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

    func fetchStreams() async throws -> [StreamSession] {
        streams
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
