//
//  ProviderServiceTests.swift
//  ClawlineTests
//
//  Created by Codex on 1/12/26.
//

import Foundation
import Testing
@testable import Clawline

struct ProviderServiceTests {
    @Test("Pairing request sends payload and resolves success")
    func pairingSuccess() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let service = ProviderConnectionService(connector: connector)
        let serverURL = URL(string: "wss://example.com/ws")!

        Task {
            try await Task.sleep(for: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "pair_result", "success": true, "token": "jwt", "userId": "user_1" }"#)
        }

        let result = try await service.requestPairing(
            serverURL: serverURL,
            claimedName: "Test",
            deviceId: "device_123"
        )

        #expect(connector.connectedURL == serverURL)
        #expect(mockSocket.sentTexts.contains { $0.contains("\"pair_request\"") })

        switch result {
        case .success(let token, let userId):
            #expect(token == "jwt")
            #expect(userId == "user_1")
        default:
            Issue.record("Expected success result, got \(result)")
        }
    }

    @Test("Pairing request times out when connect never completes")
    func pairingTimesOutWhenConnectHangs() async {
        let connector = HangingWebSocketConnector(mode: .connect)
        let service = ProviderConnectionService(
            connector: connector,
            connectionTimeout: .milliseconds(100),
            pendingTimeout: .milliseconds(150)
        )
        let serverURL = URL(string: "wss://example.com/ws")!

        do {
            _ = try await service.requestPairing(
                serverURL: serverURL,
                claimedName: "Test",
                deviceId: "device_123"
            )
            Issue.record("Expected timeout error but requestPairing succeeded")
        } catch let error as ProviderConnectionService.Error {
            switch error {
            case .timeout:
                break
            default:
                Issue.record("Expected timeout error, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Pairing request times out when send never completes")
    func pairingTimesOutWhenSendHangs() async {
        let connector = HangingWebSocketConnector(mode: .send)
        let service = ProviderConnectionService(
            connector: connector,
            connectionTimeout: .milliseconds(100),
            pendingTimeout: .milliseconds(150)
        )
        let serverURL = URL(string: "wss://example.com/ws")!

        do {
            _ = try await service.requestPairing(
                serverURL: serverURL,
                claimedName: "Test",
                deviceId: "device_123"
            )
            Issue.record("Expected timeout error but requestPairing succeeded")
        } catch let error as ProviderConnectionService.Error {
            switch error {
            case .timeout:
                break
            default:
                Issue.record("Expected timeout error, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Chat connect sends auth payload and yields server messages")
    func chatConnectAndReceive() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        var iterator = service.incomingMessages.makeAsyncIterator()

        // Queue auth result then a message after a short delay.
        Task {
            try await Task.sleep(for: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
            try await Task.sleep(for: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "message", "id": "s_1", "role": "assistant", "content": "Hi", "timestamp": 1700000000000, "streaming": false, "attachments": [] }"#)
        }

        async let connectResult = service.connect(token: "jwt", lastMessageId: "s_0")
        try await connectResult

        let message = await iterator.next()

        #expect(connector.connectedURL?.absoluteString == "wss://example.com/ws")
        #expect(mockSocket.sentTexts.contains { $0.contains("\"type\":\"auth\"") && $0.contains("\"lastMessageId\":\"s_0\"") })
        #expect(message?.content == "Hi")
    }

    @Test("Chat send serializes message payload")
    func chatSendSerializesPayload() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        Task {
            try await Task.sleep(for: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        try await service.send(id: "c_test", content: "Hello", attachments: [])

        #expect(mockSocket.sentTexts.contains { $0.contains("\"type\":\"message\"") && $0.contains("\"content\":\"Hello\"") })
    }
}

// MARK: - Test doubles

private final class MockWebSocketConnector: WebSocketConnecting {
    let client: MockWebSocketClient
    private(set) var connectedURL: URL?

    init(client: MockWebSocketClient) {
        self.client = client
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        connectedURL = url
        return client
    }
}

private final class MockWebSocketClient: WebSocketClient {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    private(set) var sentTexts: [String] = []

    init() {
        var continuation: AsyncStream<String>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var incomingTextMessages: AsyncStream<String> { stream }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {
        continuation.finish()
    }

    func enqueue(text: String) {
        continuation.yield(text)
    }
}

private final class HangingWebSocketConnector: WebSocketConnecting {
    enum Mode {
        case connect
        case send
    }

    private let mode: Mode
    private let client: HangingWebSocketClient

    init(mode: Mode) {
        self.mode = mode
        self.client = HangingWebSocketClient(hangOnSend: mode == .send)
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        if mode == .connect {
            try await Task.sleep(for: .seconds(60))
        }
        return client
    }
}

private final class HangingWebSocketClient: WebSocketClient {
    private let hangOnSend: Bool
    private let stream: AsyncStream<String>

    init(hangOnSend: Bool) {
        self.hangOnSend = hangOnSend
        self.stream = AsyncStream { _ in }
    }

    var incomingTextMessages: AsyncStream<String> { stream }

    func send(text: String) async throws {
        if hangOnSend {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {}
}
