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
            try await Task.sleep(forDuration: .milliseconds(10))
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

    @Test("Pairing request falls back from wss to ws when TLS handshake fails")
    func pairingFallsBackToPlainWebSocket() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = FallbackMockWebSocketConnector(client: mockSocket)
        let service = ProviderConnectionService(connector: connector)
        let serverURL = URL(string: "ws://example.com/ws")!

        Task {
            try await Task.sleep(forDuration: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "pair_result", "success": true, "token": "jwt", "userId": "user_1" }"#)
        }

        let result = try await service.requestPairing(
            serverURL: serverURL,
            claimedName: "Test",
            deviceId: "device_123"
        )

        #expect(connector.connectedURLs.count == 2)
        #expect(connector.connectedURLs.first?.absoluteString == "wss://example.com/ws")
        #expect(connector.connectedURLs.last?.absoluteString == "ws://example.com/ws")
        if case .success(let token, let userId) = result {
            #expect(token == "jwt")
            #expect(userId == "user_1")
        } else {
            Issue.record("Expected pairing success after ws fallback")
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
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "message", "id": "s_1", "role": "assistant", "content": "Hi", "timestamp": 1700000000000, "streaming": false, "sessionKey": "agent:main:main", "attachments": [] }"#)
        }

        async let connectResult = service.connect(token: "jwt", lastMessageId: "s_0")
        try await connectResult

        let message = await iterator.next()

        #expect(connector.connectedURL?.absoluteString == "wss://example.com/ws")
        #expect(mockSocket.sentTexts.contains { $0.contains("\"type\":\"auth\"") && $0.contains("\"lastMessageId\":\"s_0\"") })
        #expect(mockSocket.sentTexts.contains { $0.contains("\"clientFeatures\":[\"terminal_bubbles_v1\"]") })
        #expect(message?.content == "Hi")
    }

    @Test("Chat connect falls back from wss to ws when TLS handshake fails")
    func chatConnectFallsBackToPlainWebSocket() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = FallbackMockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "http://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        #expect(connector.connectedURLs.count == 2)
        #expect(connector.connectedURLs.first?.absoluteString == "wss://example.com/ws")
        #expect(connector.connectedURLs.last?.absoluteString == "ws://example.com/ws")
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
            try await Task.sleep(forDuration: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        try await service.send(
            id: "c_test",
            content: "Hello",
            attachments: [],
            sessionKey: nil
        )

        #expect(mockSocket.sentTexts.contains {
            $0.contains("\"type\":\"message\"")
            && $0.contains("\"content\":\"Hello\"")
        })
    }

    @Test("Chat send does not automatically retry an unacked message")
    func chatSendDoesNotRetryUnackedMessage() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        try await service.send(
            id: "c_single_send",
            content: "Hello once",
            attachments: [],
            sessionKey: nil
        )

        try await Task.sleep(forDuration: .milliseconds(5200))

        let sendCount = mockSocket.sentTexts.filter {
            $0.contains("\"type\":\"message\"") && $0.contains("\"id\":\"c_single_send\"")
        }.count
        #expect(sendCount == 1)
    }

    @Test("Chat send suppresses duplicate client message ids")
    func chatSendSuppressesDuplicateMessageIds() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        try await service.send(
            id: "c_dedup",
            content: "Hello",
            attachments: [],
            sessionKey: nil
        )
        try await service.send(
            id: "c_dedup",
            content: "Hello",
            attachments: [],
            sessionKey: nil
        )

        let sendCount = mockSocket.sentTexts.filter {
            $0.contains("\"type\":\"message\"") && $0.contains("\"id\":\"c_dedup\"")
        }.count
        #expect(sendCount == 1)
    }

    @Test("Retry cancellation does not send message frame after disconnect")
    func retryCancellationDoesNotSendAfterDisconnect() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        try await service.send(
            id: "c_retry_cancel",
            content: "Hello",
            attachments: [],
            sessionKey: nil
        )

        let sentBeforeDisconnect = mockSocket.sentTexts.filter {
            $0.contains("\"type\":\"message\"") && $0.contains("\"id\":\"c_retry_cancel\"")
        }.count
        #expect(sentBeforeDisconnect == 1)

        service.disconnect()
        try await Task.sleep(forDuration: .milliseconds(50))

        let sentAfterDisconnect = mockSocket.sentTexts.filter {
            $0.contains("\"type\":\"message\"") && $0.contains("\"id\":\"c_retry_cancel\"")
        }.count
        #expect(sentAfterDisconnect == sentBeforeDisconnect)
    }

    @Test("Malformed inbound auth/message frames are dropped and valid frames still process")
    func malformedInboundFramesAreDropped() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )
        var messageIterator = service.incomingMessages.makeAsyncIterator()

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: "{ this is not json")
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "message", "id": "s_bad", "role": "assistant", "content": "bad", "streaming": false, "sessionKey": "agent:main:main", "attachments": [] }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "message", "id": "s_good", "role": "assistant", "content": "ok", "timestamp": 1700000000000, "streaming": false, "sessionKey": "agent:main:main", "attachments": [] }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        let message = await messageIterator.next()
        #expect(message?.id == "s_good")
        #expect(message?.content == "ok")
    }

    @Test("Malformed ack frame is dropped and valid ack still emits")
    func malformedAckFrameIsDropped() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )
        var eventIterator = service.serviceEvents.makeAsyncIterator()

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }
        try await service.connect(token: "jwt", lastMessageId: nil)
        try await service.send(
            id: "c_ack_drop",
            content: "Ack me",
            attachments: [],
            sessionKey: nil
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "ack" }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "ack", "id": "c_ack_drop" }"#)
        }

        var acked = false
        for _ in 0..<10 {
            guard let event = await eventIterator.next() else { continue }
            if case .messageAcked(let id) = event, id == "c_ack_drop" {
                acked = true
                break
            }
        }

        #expect(acked)
    }

    @Test("Chat service emits stream snapshot events")
    func chatStreamSnapshotEvent() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        var eventIterator = service.serviceEvents.makeAsyncIterator()
        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "stream_snapshot", "streams": [{ "sessionKey": "agent:main:clawline:user:main", "displayName": "Personal", "kind": "main", "orderIndex": 0, "isBuiltIn": true, "createdAt": 1700000000000, "updatedAt": 1700000000000 }] }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        var snapshot: [StreamSession] = []
        for _ in 0..<20 {
            guard let event = await eventIterator.next() else { continue }
            if case .streamSnapshot(let streams) = event {
                snapshot = streams
                break
            }
        }

        #expect(snapshot.count == 1)
        #expect(snapshot.first?.sessionKey == "agent:main:clawline:user:main")
    }

    @Test("Chat service emits incremental stream events")
    func chatIncrementalStreamEvents() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        var eventIterator = service.serviceEvents.makeAsyncIterator()
        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "stream_created", "stream": { "sessionKey": "agent:main:clawline:user:s_abcd1234", "displayName": "Research", "kind": "custom", "orderIndex": 1, "isBuiltIn": false, "createdAt": 1700000000000, "updatedAt": 1700000000000 } }"#)
            mockSocket.enqueue(text: #"{ "type": "stream_updated", "stream": { "sessionKey": "agent:main:clawline:user:s_abcd1234", "displayName": "Research v2", "kind": "custom", "orderIndex": 1, "isBuiltIn": false, "createdAt": 1700000000000, "updatedAt": 1700000001000 } }"#)
            mockSocket.enqueue(text: #"{ "type": "stream_deleted", "sessionKey": "agent:main:clawline:user:s_abcd1234" }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        var sawCreated = false
        var sawUpdated = false
        var sawDeleted = false
        for _ in 0..<40 {
            guard let event = await eventIterator.next() else { continue }
            switch event {
            case .streamCreated(let stream):
                sawCreated = stream.displayName == "Research"
            case .streamUpdated(let stream):
                sawUpdated = stream.displayName == "Research v2"
            case .streamDeleted(let sessionKey):
                sawDeleted = sessionKey == "agent:main:clawline:user:s_abcd1234"
            default:
                break
            }
            if sawCreated && sawUpdated && sawDeleted {
                break
            }
        }

        #expect(sawCreated)
        #expect(sawUpdated)
        #expect(sawDeleted)
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

private final class FallbackMockWebSocketConnector: WebSocketConnecting {
    let client: MockWebSocketClient
    private(set) var connectedURLs: [URL] = []

    init(client: MockWebSocketClient) {
        self.client = client
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        connectedURLs.append(url)
        if url.scheme == "wss" {
            throw URLError(.secureConnectionFailed)
        }
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
            try await Task.sleep(forDuration: .seconds(60))
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
            try await Task.sleep(forDuration: .seconds(60))
        }
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {}
}
