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
        #expect(mockSocket.sentTexts.contains { $0.contains("\"type\":\"auth\"") })
        #expect(mockSocket.sentTexts.allSatisfy { !$0.contains("\"lastMessageId\"") })
        #expect(mockSocket.sentTexts.contains { $0.contains("\"clientFeatures\":[\"terminal_bubbles_v1\"]") })
        #expect(message?.content == "Hi")
    }

    @Test("Chat auth sends per-stream replay cursors without legacy cursor")
    func chatAuthSendsReplayCursorMap() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_replay_map",
            baseURLProvider: { baseURL }
        )
        defer { service.clearReplayCursors() }

        let mainKey = "agent:main:clawline:user:main"
        let sideKey = "agent:main:clawline:user:side"
        service.setReplayCursor("s_main_final", for: mainKey)
        service.setReplayCursor("s_side_final", for: sideKey)

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: "s_main_final")

        let auth = try #require(mockSocket.sentTexts.first(where: { $0.contains("\"type\":\"auth\"") }))
        let payload = try jsonObject(auth)
        #expect(payload["lastMessageId"] == nil)
        let replayCursors = try #require(payload["replayCursorsBySessionKey"] as? [String: Any])
        #expect(replayCursors[mainKey] as? String == "s_main_final")
        #expect(replayCursors[sideKey] as? String == "s_side_final")
    }

    @Test("Streaming partials do not advance replay cursors but finals do")
    func streamingPartialsDoNotAdvanceReplayCursors() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_stream_cursor",
            baseURLProvider: { baseURL }
        )
        defer { service.clearReplayCursors() }

        let sessionKey = "agent:main:clawline:user:main"
        var iterator = service.incomingMessages.makeAsyncIterator()
        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        mockSocket.enqueue(text: #"{ "type": "message", "id": "s_shared_reply", "role": "assistant", "content": "Partial", "timestamp": 1700000000000, "streaming": true, "sessionKey": "agent:main:clawline:user:main", "attachments": [] }"#)
        _ = await iterator.next()
        #expect(service.replayCursorSnapshot()[sessionKey] == nil)

        mockSocket.enqueue(text: #"{ "type": "message", "id": "s_shared_reply", "role": "assistant", "content": "Final", "timestamp": 1700000001000, "streaming": false, "sessionKey": "agent:main:clawline:user:main", "attachments": [] }"#)
        _ = await iterator.next()
        #expect(service.replayCursorSnapshot()[sessionKey] == "s_shared_reply")
    }

    @Test("Cache restore seeding cannot overwrite an advanced replay cursor")
    func cacheSeedDoesNotOverwriteAdvancedCursor() {
        let service = ProviderChatService(
            connector: MockWebSocketConnector(client: MockWebSocketClient()),
            deviceId: "device_seed_cursor",
            baseURLProvider: { URL(string: "https://example.com")! }
        )
        defer { service.clearReplayCursors() }

        let mainKey = "agent:main:clawline:user:main"
        let sideKey = "agent:main:clawline:user:side"
        service.setReplayCursor("s_live_final", for: mainKey)
        service.seedReplayCursorIfMissing("s_cache_old", for: mainKey)
        service.seedReplayCursorIfMissing("s_side_cache", for: sideKey)

        #expect(service.replayCursorSnapshot()[mainKey] == "s_live_final")
        #expect(service.replayCursorSnapshot()[sideKey] == "s_side_cache")
    }

    @Test("Chat connect reports adopted session keys during auth")
    @MainActor
    func chatConnectReportsAdoptedSessionKeysDuringAuth() async throws {
        SessionRegistry.shared.replace(with: [])
        defer { SessionRegistry.shared.replace(with: []) }

        let adoptedKey = "agent:main:openclaw:user:s_trackme"
        SessionRegistry.shared.upsert(
            StreamSession(
                sessionKey: adoptedKey,
                displayName: "Tracked Session",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date(),
                trackingMode: .adopted
            )
        )
        SessionRegistry.shared.upsert(
            StreamSession(
                sessionKey: "agent:main:clawline:user:main",
                displayName: "Personal",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: Date(),
                updatedAt: Date(),
                trackingMode: .serverManaged
            )
        )

        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            adoptedSessionKeysProvider: { SessionRegistry.shared.adoptedSessionKeys() }
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        #expect(
            mockSocket.sentTexts.contains {
                $0.contains("\"type\":\"auth\"")
                    && $0.contains("\"adoptedSessionKeys\":[\"agent:main:openclaw:user:s_trackme\"]")
            }
        )
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

    @Test("Publish read state serializes payload")
    func publishReadStateSerializesPayload() async throws {
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
        try await service.publishReadState(
            sessionKey: "agent:main:clawline:user:main",
            lastReadMessageId: "s_read_1"
        )

        #expect(mockSocket.sentTexts.contains {
            $0.contains("\"type\":\"stream_read\"")
                && $0.contains("\"sessionKey\":\"agent:main:clawline:user:main\"")
                && $0.contains("\"lastReadMessageId\":\"s_read_1\"")
        })
    }

    @Test("Unknown read-state cursor rejection does not fail pending messages")
    func unknownReadStateCursorRejectionDoesNotFailPendingMessages() async throws {
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
            try await Task.sleep(forDuration: .milliseconds(10))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        try await service.send(
            id: "c_pending",
            content: "Hello",
            attachments: [],
            sessionKey: nil
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "error", "code": "invalid_message", "message": "Unknown lastReadMessageId" }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "ack", "id": "c_pending" }"#)
        }

        for _ in 0..<20 {
            guard let event = await eventIterator.next() else { continue }
            switch event {
            case .messageError(_, let code, let message):
                Issue.record("Unexpected message error from read-state rejection: \(code) \(message ?? "")")
                return
            case .messageAcked(let id) where id == "c_pending":
                return
            default:
                continue
            }
        }

        Issue.record("Expected pending message ack")
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

    @Test("Chat service emits read-state snapshot from auth result")
    func chatReadStateSnapshotEvent() async throws {
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
            mockSocket.enqueue(
                text: #"{ "type": "auth_result", "success": true, "streamReadStates": { "agent:main:clawline:user:main": "s_read_1" } }"#
            )
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        var snapshot: [String: String] = [:]
        for _ in 0..<20 {
            guard let event = await eventIterator.next() else { continue }
            if case .streamReadStateSnapshot(let states) = event {
                snapshot = states
                break
            }
        }

        #expect(snapshot["agent:main:clawline:user:main"] == "s_read_1")
    }

    @Test("Chat service emits tail-state snapshot from auth result")
    func chatTailStateSnapshotEvent() async throws {
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
            mockSocket.enqueue(
                text: #"{ "type": "auth_result", "success": true, "streamTailStates": { "agent:main:clawline:user:main": { "lastMessageId": "s_tail_1", "lastMessageRole": "user" } } }"#
            )
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        var snapshot: [String: StreamTailState] = [:]
        for _ in 0..<20 {
            guard let event = await eventIterator.next() else { continue }
            if case .streamTailStateSnapshot(let states) = event {
                snapshot = states
                break
            }
        }

        #expect(snapshot["agent:main:clawline:user:main"] == StreamTailState(lastMessageId: "s_tail_1", lastMessageRole: .user))
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

    @Test("Trackable sessions fetch is authorized during initial stream snapshot")
    func trackableSessionsFetchDuringInitialSnapshot() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/trackable-sessions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
            let data = #"""
            {
              "sessions": [
                {
                  "sessionKey": "agent:main:clawline:user:s_trackable",
                  "displayName": "Trackable Session",
                  "updatedAt": 1700000000000
                }
              ]
            }
            """#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let streamAPIClient = StreamAPIClient(baseURLProvider: { baseURL }, session: urlSession)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            streamAPIClient: streamAPIClient
        )

        var eventIterator = service.serviceEvents.makeAsyncIterator()
        let fetchTask = Task {
            while let event = await eventIterator.next() {
                if case .streamSnapshot = event {
                    return try await service.fetchTrackableSessions()
                }
            }
            return [TrackableSession]()
        }

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "stream_snapshot", "streams": [{ "sessionKey": "agent:main:clawline:user:main", "displayName": "Personal", "kind": "main", "orderIndex": 0, "isBuiltIn": true, "createdAt": 1700000000000, "updatedAt": 1700000000000 }] }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        let sessions = try await fetchTask.value

        #expect(sessions.map(\.sessionKey) == ["agent:main:clawline:user:s_trackable"])
    }

    @Test("Fetch streams decodes adopted flag and defaults missing field to false")
    func fetchStreamsDecodesAdoptedFlag() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/streams")
            let data = #"""
            {
              "streams": [
                {
                  "sessionKey": "agent:main:clawline:user:s_adopted",
                  "displayName": "Adopted Session",
                  "kind": "custom",
                  "orderIndex": 1,
                  "isBuiltIn": false,
                  "createdAt": 1700000000000,
                  "updatedAt": 1700000000000,
                  "adopted": true
                },
                {
                  "sessionKey": "agent:main:clawline:user:s_regular",
                  "displayName": "Regular Session",
                  "kind": "custom",
                  "orderIndex": 2,
                  "isBuiltIn": false,
                  "createdAt": 1700000000000,
                  "updatedAt": 1700000000000
                }
              ]
            }
            """#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let streamAPIClient = StreamAPIClient(baseURLProvider: { baseURL }, session: urlSession)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            authTokenProvider: { "jwt" },
            streamAPIClient: streamAPIClient
        )

        let streams = try await service.fetchStreams()

        #expect(streams.count == 2)
        #expect(streams[0].adopted)
        #expect(!streams[1].adopted)
    }

    @Test("Fetch session status uses provider status endpoint and decodes capabilities")
    func fetchSessionStatusUsesProviderEndpoint() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let sessionKey = "agent:main:clawline:user:s_status"
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/session-status")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(queryItems?.first(where: { $0.name == "sessionKey" })?.value == sessionKey)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
            let data = #"""
            {
              "sessionKey": "agent:main:clawline:user:s_status",
              "display": {
                "model": "claude-sonnet-4.6",
                "fallbackModels": null,
                "provider": "anthropic",
                "harness": null,
                "reasoningLevel": null,
                "thinkingLevel": "high",
                "fastMode": true,
                "mode": null,
                "verbosity": null
              },
              "run": {
                "state": "running",
                "runId": "run_1",
                "messageId": "c_1",
                "startedAt": 1700000000000,
                "queueDepth": 2
              },
              "context": {
                "available": false,
                "compaction": null
              },
              "approval": {
                "state": null
              },
              "capabilities": {
                "cancelCurrentRun": { "supported": false, "reason": "provider_control_not_available" },
                "setModel": { "supported": false, "reason": "provider_control_not_available" },
                "setReasoning": { "supported": false, "reason": "provider_control_not_available" },
                "setMode": { "supported": false, "reason": "provider_control_not_available" },
                "setVerbosity": { "supported": false, "reason": "provider_control_not_available" }
              },
              "modelCatalog": {
                "available": true,
                "models": [
                  {
                    "id": "gpt-5.5",
                    "provider": "openai",
                    "ref": "openai/gpt-5.5",
                    "name": "GPT-5.5",
                    "alias": null
                  },
                  {
                    "id": "claude-sonnet-4-6",
                    "provider": "anthropic",
                    "ref": "anthropic/claude-sonnet-4-6",
                    "name": "Claude Sonnet 4.6",
                    "alias": "Sonnet"
                  }
                ]
              }
            }
            """#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let streamAPIClient = StreamAPIClient(baseURLProvider: { baseURL }, session: urlSession)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            authTokenProvider: { "jwt" },
            streamAPIClient: streamAPIClient
        )

        let status = try await service.fetchSessionStatus(sessionKey: sessionKey)

        #expect(status.sessionKey == sessionKey)
        #expect(status.display.provider == "anthropic")
        #expect(status.display.model == "claude-sonnet-4.6")
        #expect(status.display.thinkingLevel == "high")
        #expect(status.display.fastMode == true)
        #expect(status.run.state == .running)
        #expect(status.run.queueDepth == 2)
        #expect(status.capabilities.cancelCurrentRun?.supported == false)
        #expect(status.modelCatalog?.available == true)
        #expect(status.modelCatalog?.models.map(\.ref) == [
            "openai/gpt-5.5",
            "anthropic/claude-sonnet-4-6"
        ])
        #expect(status.modelCatalog?.models[1].alias == "Sonnet")
    }

    @Test("Session control posts typed provider actions")
    func sessionControlPostsTypedProviderActions() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let sessionKey = "agent:main:clawline:user:s_status"
        defer { HTTPStubURLProtocol.requestHandler = nil }
        var requestBodies: [[String: Any]] = []
        HTTPStubURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/session-control")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
            let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            requestBodies.append(body ?? [:])
            let action = body?["action"] as? String
            let data: Data
            if action == "cancel_current_run" {
                #expect(body?["sessionKey"] as? String == sessionKey)
                #expect(body?["content"] == nil)
                data = #"""
                {
                  "ok": false,
                  "sessionKey": "agent:main:clawline:user:s_status",
                  "action": "cancel_current_run",
                  "code": "unsupported",
                  "message": "The current Clawline provider dispatch path does not expose a per-session abort seam.",
                  "capabilities": {
                    "cancelCurrentRun": { "supported": false, "reason": "provider_abort_seam_not_available" },
                    "setModel": { "supported": false, "reason": "model_catalog_control_not_available" },
                    "setReasoning": { "supported": true, "reason": null },
                    "setMode": { "supported": true, "reason": null },
                    "setVerbosity": { "supported": true, "reason": null }
                  }
                }
                """#.data(using: .utf8) ?? Data()
            } else {
                #expect(action == "set_fast_mode")
                #expect(body?["sessionKey"] as? String == sessionKey)
                #expect(body?["fastMode"] as? Bool == true)
                #expect(body?["content"] == nil)
                data = #"""
                {
                  "ok": true,
                  "sessionKey": "agent:main:clawline:user:s_status",
                  "action": "set_fast_mode",
                  "status": {
                    "sessionKey": "agent:main:clawline:user:s_status",
                    "display": {
                      "model": "gpt-5.5",
                      "fallbackModels": null,
                      "provider": "openai",
                      "harness": null,
                      "reasoningLevel": null,
                      "thinkingLevel": "high",
                      "fastMode": true,
                      "mode": "fast",
                      "verbosity": null
                    },
                    "run": {
                      "state": "idle",
                      "runId": null,
                      "messageId": null,
                      "startedAt": null,
                      "queueDepth": 0
                    },
                    "context": {
                      "available": false,
                      "compaction": null
                    },
                    "approval": {
                      "state": null
                    },
                    "capabilities": {
                      "cancelCurrentRun": { "supported": false, "reason": "provider_abort_seam_not_available" },
                      "setModel": { "supported": false, "reason": "model_catalog_control_not_available" },
                      "setThinking": { "supported": true },
                      "setReasoning": { "supported": true },
                      "setFastMode": { "supported": true },
                      "setMode": { "supported": true },
                      "setVerbosity": { "supported": true }
                    }
                  },
                  "capabilities": {
                    "cancelCurrentRun": { "supported": false, "reason": "provider_abort_seam_not_available" },
                    "setModel": { "supported": false, "reason": "model_catalog_control_not_available" },
                    "setThinking": { "supported": true },
                    "setReasoning": { "supported": true },
                    "setFastMode": { "supported": true },
                    "setMode": { "supported": true },
                    "setVerbosity": { "supported": true }
                  }
                }
                """#.data(using: .utf8) ?? Data()
            }
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let streamAPIClient = StreamAPIClient(baseURLProvider: { baseURL }, session: urlSession)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            authTokenProvider: { "jwt" },
            streamAPIClient: streamAPIClient
        )

        let cancelResponse = try await service.applySessionControl(
            sessionKey: sessionKey,
            action: .cancelCurrentRun,
            value: nil,
            enabled: nil
        )
        let fastModeResponse = try await service.applySessionControl(
            sessionKey: sessionKey,
            action: .setFastMode,
            value: nil,
            enabled: true
        )

        #expect(requestBodies.count == 2)
        #expect(requestBodies.first?["action"] as? String == "cancel_current_run")
        #expect(requestBodies.first?["fastMode"] == nil)
        #expect(requestBodies.last?["action"] as? String == "set_fast_mode")
        #expect(requestBodies.last?["fastMode"] as? Bool == true)
        #expect(cancelResponse.ok == false)
        #expect(cancelResponse.sessionKey == sessionKey)
        #expect(cancelResponse.action == "cancel_current_run")
        #expect(cancelResponse.code == "unsupported")
        #expect(cancelResponse.capabilities?.cancelCurrentRun?.supported == false)
        #expect(fastModeResponse.ok)
        #expect(fastModeResponse.status?.display.fastMode == true)
        #expect(fastModeResponse.capabilities?.setModel?.reason == "model_catalog_control_not_available")
    }

    @Test("Adopt stream request posts session key to provider")
    func adoptStreamPostsSessionKeyToProvider() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/streams/adopt")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            #expect(body?["sessionKey"] as? String == "agent:main:openclaw:user:s_trackable")
            let data = #"""
            {
              "stream": {
                "sessionKey": "agent:main:openclaw:user:s_trackable",
                "displayName": "Trackable Session",
                "kind": "custom",
                "orderIndex": 3,
                "isBuiltIn": false,
                "createdAt": 1700000000000,
                "updatedAt": 1700000000000,
                "adopted": true
              }
            }
            """#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let streamAPIClient = StreamAPIClient(baseURLProvider: { baseURL }, session: urlSession)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            authTokenProvider: { "jwt" },
            streamAPIClient: streamAPIClient
        )

        let stream = try await service.adoptStream(sessionKey: "agent:main:openclaw:user:s_trackable")

        #expect(stream.sessionKey == "agent:main:openclaw:user:s_trackable")
        #expect(stream.displayName == "Trackable Session")
        #expect(stream.adopted)
    }

    @Test("Adopt stream emits streamCreated service event")
    func adoptStreamEmitsCreatedEvent() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            let data = #"""
            {
              "stream": {
                "sessionKey": "agent:main:openclaw:user:s_trackable",
                "displayName": "Trackable Session",
                "kind": "custom",
                "orderIndex": 3,
                "isBuiltIn": false,
                "createdAt": 1700000000000,
                "updatedAt": 1700000000000,
                "adopted": true
              }
            }
            """#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let streamAPIClient = StreamAPIClient(baseURLProvider: { baseURL }, session: urlSession)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            authTokenProvider: { "jwt" },
            streamAPIClient: streamAPIClient
        )

        var eventIterator = service.serviceEvents.makeAsyncIterator()
        let stream = try await service.adoptStream(sessionKey: "agent:main:openclaw:user:s_trackable")
        let event = await eventIterator.next()

        guard case .streamCreated(let createdStream)? = event else {
            Issue.record("Expected streamCreated event after adopt")
            return
        }

        #expect(createdStream.sessionKey == stream.sessionKey)
        #expect(createdStream.displayName == stream.displayName)
        #expect(createdStream.adopted)
    }

    @Test("Delete stream emits streamDeleted service event")
    func deleteStreamEmitsDeletedEvent() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            let data = #"""
            {
              "sessionKey": "agent:main:openclaw:user:s_trackable"
            }
            """#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let streamAPIClient = StreamAPIClient(baseURLProvider: { baseURL }, session: urlSession)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            authTokenProvider: { "jwt" },
            streamAPIClient: streamAPIClient
        )

        var eventIterator = service.serviceEvents.makeAsyncIterator()
        let deletedKey = try await service.deleteStream(
            sessionKey: "agent:main:openclaw:user:s_trackable",
            idempotencyKey: nil
        )
        let event = await eventIterator.next()

        guard case .streamDeleted(let emittedKey)? = event else {
            Issue.record("Expected streamDeleted event after delete")
            return
        }

        #expect(emittedKey == deletedKey)
    }

    @Test("Chat service emits incremental read-state updates")
    func chatIncrementalReadStateEvents() async throws {
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
            mockSocket.enqueue(
                text: #"{ "type": "stream_read_state", "sessionKey": "agent:main:clawline:user:s_abcd1234", "lastReadMessageId": "s_read_2" }"#
            )
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        var emitted: (String, String)?
        for _ in 0..<20 {
            guard let event = await eventIterator.next() else { continue }
            if case .streamReadStateUpdated(let sessionKey, let lastReadMessageId) = event {
                emitted = (sessionKey, lastReadMessageId)
                break
            }
        }

        #expect(emitted?.0 == "agent:main:clawline:user:s_abcd1234")
        #expect(emitted?.1 == "s_read_2")
    }

    @Test("Chat service emits incremental tail-state updates")
    func chatIncrementalTailStateEvents() async throws {
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
            mockSocket.enqueue(
                text: #"{ "type": "stream_tail_state", "sessionKey": "agent:main:clawline:user:s_abcd1234", "lastMessageId": "s_tail_2", "lastMessageRole": "user" }"#
            )
        }

        try await service.connect(token: "jwt", lastMessageId: nil)

        var emitted: (String, StreamTailState)?
        for _ in 0..<20 {
            guard let event = await eventIterator.next() else { continue }
            if case .streamTailStateUpdated(let sessionKey, let tailState) = event {
                emitted = (sessionKey, tailState)
                break
            }
        }

        #expect(emitted?.0 == "agent:main:clawline:user:s_abcd1234")
        #expect(emitted?.1 == StreamTailState(lastMessageId: "s_tail_2", lastMessageRole: .user))
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

private final class HTTPStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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

private func jsonObject(_ text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8) else {
        throw JSONParseError.invalidUTF8
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
        throw JSONParseError.notDictionary
    }
    return dictionary
}

private enum JSONParseError: Error {
    case invalidUTF8
    case notDictionary
}
