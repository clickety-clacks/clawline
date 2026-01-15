//
//  StubChatService.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

final class StubChatService: ChatServicing {
    var responseDelay: TimeInterval = 1.5

    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?

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

    func connect(token: String, lastMessageId: String?) async throws {
        stateContinuation?.yield(.connecting)
        try await Task.sleep(for: .milliseconds(500))
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(id: String, content: String, attachments: [Attachment]) async throws {
        try await Task.sleep(for: .seconds(responseDelay))

        let response = Message(
            id: UUID().uuidString,
            role: .assistant,
            content: "You said: \(content)",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil
        )

        messageContinuation?.yield(response)
    }
}
