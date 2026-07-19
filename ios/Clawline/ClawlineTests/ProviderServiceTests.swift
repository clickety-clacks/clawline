//
//  ProviderServiceTests.swift
//  ClawlineTests
//
//  Created by Codex on 1/12/26.
//

import Foundation
import Testing
@testable import Clawline

@Suite(.serialized)
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
        let service = ProviderDirectChatClient(
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

        async let connectResult: Void = service.connect(token: "jwt", lastMessageId: "s_0")
        try await connectResult

        let message = await iterator.next()

        #expect(connector.connectedURL?.absoluteString == "wss://example.com/ws")
        #expect(mockSocket.sentTexts.contains { $0.contains("\"type\":\"auth\"") })
        #expect(mockSocket.sentTexts.allSatisfy { !$0.contains("\"lastMessageId\"") })
        let auth = try #require(mockSocket.sentTexts.first(where: { $0.contains("\"type\":\"auth\"") }))
        let payload = try jsonObject(auth)
        let clientFeatures = try #require(payload["clientFeatures"] as? [String])
        #expect(clientFeatures.contains("terminal_bubbles_v1"))
        #expect(clientFeatures.contains("live_agent_progress_v1"))
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

    @Test("Agent progress emits service event without advancing replay cursor")
    func agentProgressDoesNotAdvanceReplayCursor() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_progress_cursor",
            baseURLProvider: { URL(string: "https://example.com")! }
        )
        defer { service.clearReplayCursors() }

        let sessionKey = "agent:main:clawline:user:main"
        var iterator = service.serviceEvents.makeAsyncIterator()
        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        mockSocket.enqueue(
            text: #"{ "type": "agent_progress", "version": 1, "sessionKey": "agent:main:clawline:user:main", "runId": "run_1", "messageId": "c_1", "seq": 2, "timestamp": 1700000000000, "state": "running", "event": { "kind": "item", "phase": "start", "status": "running", "title": "Reading files", "summary": "Reading files" } }"#
        )

        var event: ChatServiceEvent?
        while let next = await iterator.next() {
            if case .agentProgress = next {
                event = next
                break
            }
        }
        guard case .agentProgress(let progress) = event else {
            Issue.record("Expected agent progress service event")
            return
        }
        #expect(progress.sessionKey == sessionKey)
        #expect(progress.runId == "run_1")
        #expect(progress.seq == 2)
        #expect(progress.event?.summary == "Reading files")
        #expect(service.replayCursorSnapshot()[sessionKey] == nil)
    }

    @Test("Prompt turn state events emit service events")
    func promptTurnStateEventsEmitServiceEvents() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_prompt_turn_state",
            baseURLProvider: { URL(string: "https://example.com")! }
        )
        var iterator = service.serviceEvents.makeAsyncIterator()
        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await service.connect(token: "jwt", lastMessageId: nil)
        mockSocket.enqueue(
            text: #"{ "type": "event", "event": "prompt_turn_state", "payload": { "messageId": "c_1", "sessionKey": "agent:main:main", "state": "failed", "terminalState": "failed", "correlationId": "corr_1", "clawlineMessageRowId": 42, "error": "clawline.promptTurn.noDelivery" } }"#
        )

        var event: ChatServiceEvent?
        while let next = await iterator.next() {
            if case .promptTurnState = next {
                event = next
                break
            }
        }
        guard case .promptTurnState(let promptTurn) = event else {
            Issue.record("Expected prompt turn state service event")
            return
        }

        #expect(promptTurn.payload.messageId == "c_1")
        #expect(promptTurn.payload.sessionKey == "agent:main:main")
        #expect(promptTurn.payload.state == "failed")
        #expect(promptTurn.payload.error == "clawline.promptTurn.noDelivery")
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
        let adoptedKey = "agent:main:openclaw:user:s_trackme"
        let adoptedSessionKeys = [adoptedKey]

        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL },
            adoptedSessionKeysProvider: { adoptedSessionKeys }
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        service.startConnectionAttempt(epoch: 1, lastMessageId: nil, token: "jwt")
        for _ in 0..<50 {
            if mockSocket.sentTexts.contains(where: { $0.contains("\"type\":\"auth\"") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

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
        let service = ProviderDirectChatClient(
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

    @Test("Managed lifecycle connect falls back to ws when secure transport closes before auth completes")
    @MainActor
    func managedLifecycleConnectFallsBackAfterPreAuthSocketClose() async throws {
        let secureSocket = MockWebSocketClient()
        let fallbackSocket = MockWebSocketClient()
        let connector = AsyncFallbackMockWebSocketConnector(
            secureClient: secureSocket,
            fallbackClient: fallbackSocket
        )
        let baseURL = URL(string: "http://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        let stateMonitor = Task {
            var iterator = service.connectionState.makeAsyncIterator()
            while let state = await iterator.next() {
                if state == .connected {
                    return true
                }
            }
            return false
        }
        defer { stateMonitor.cancel() }

        service.startConnectionAttempt(epoch: 1, lastMessageId: nil, token: "jwt")

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            secureSocket.close(with: .normalClosure)
            try await Task.sleep(forDuration: .milliseconds(20))
            fallbackSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
        }

        try await waitUntil(timeout: .seconds(1)) {
            connector.connectedURLs.count == 2
        }
        let sawConnected = try await waitForTaskValue(timeout: .seconds(1), task: stateMonitor)

        #expect(connector.connectedURLs.first?.absoluteString == "wss://example.com/ws")
        #expect(connector.connectedURLs.last?.absoluteString == "ws://example.com/ws")
        #expect(sawConnected)
    }

    @Test("Chat send serializes message payload")
    func chatSendSerializesPayload() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderDirectChatClient(
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
        let service = ProviderDirectChatClient(
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
        let service = ProviderDirectChatClient(
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
        let service = ProviderDirectChatClient(
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
        let service = ProviderDirectChatClient(
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

    @Test("F1 production: an unexpected socket close clears the service's authoritative tightbeam feature set")
    func socketCloseClearsServerFeatures() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true, "features": ["tightbeam"] }"#)
        }
        try await service.connect(token: "jwt", lastMessageId: nil)
        // Auth established the current-link feature set.
        for _ in 0..<50 {
            if service.serverFeatures == ["tightbeam"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(service.serverFeatures == ["tightbeam"])

        // Unexpected socket close (stream finishes) drives handleSocketClose; the
        // authoritative feature set must be cleared so a delayed .serverFeatures
        // event cannot re-derive a stale ["tightbeam"] and reopen the gate.
        mockSocket.close(with: .normalClosure)
        for _ in 0..<50 {
            if service.serverFeatures.isEmpty { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(service.serverFeatures.isEmpty)
    }

    @Test("B1 regression: under a lifecycle epoch, a history barrier is emitted in-band and NOT duplicated as a service event")
    func historyBarrierIsSingleChannelUnderLifecycle() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )
        let sessionKey = "agent:main:clawline:user:s_barrier"

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var lifecycleClears: [String] = []
            var serviceClears: [String] = []
        }
        let collector = Collector()

        let lifecycleTask = Task {
            for await event in service.lifecycleTransportEvents {
                if case .historyCleared(let key) = event.payload {
                    collector.lock.lock(); collector.lifecycleClears.append(key); collector.lock.unlock()
                }
            }
        }
        let serviceTask = Task {
            for await event in service.serviceEvents {
                if case .streamHistoryCleared(let key) = event {
                    collector.lock.lock(); collector.serviceClears.append(key); collector.lock.unlock()
                }
            }
        }
        defer { lifecycleTask.cancel(); serviceTask.cancel() }

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "stream_history_cleared", "sessionKey": "\#(sessionKey)" }"#)
        }

        // Managed lifecycle mode: inbound frames carry the lifecycle epoch, so the
        // barrier must ride the lifecycle stream and the service-event duplicate
        // must be suppressed (the two emissions are mutually exclusive).
        service.startConnectionAttempt(epoch: 1, lastMessageId: nil, token: "jwt")
        for _ in 0..<50 {
            collector.lock.lock(); let got = !collector.lifecycleClears.isEmpty; collector.lock.unlock()
            if got { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Give any (erroneous) duplicate a chance to arrive before asserting absence.
        try await Task.sleep(forDuration: .milliseconds(60))

        collector.lock.lock()
        let lifecycleClears = collector.lifecycleClears
        let serviceClears = collector.serviceClears
        collector.lock.unlock()

        #expect(lifecycleClears == [sessionKey])
        #expect(serviceClears.isEmpty)
    }

    @Test("Malformed ack frame is dropped and valid ack still emits")
    func malformedAckFrameIsDropped() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderDirectChatClient(
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
        let service = ProviderDirectChatClient(
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
            authTokenProvider: { "jwt" },
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

        service.startConnectionAttempt(epoch: 1, lastMessageId: nil, token: "jwt")
        let sessions = try await fetchTask.value

        #expect(sessions.map(\.sessionKey) == ["agent:main:clawline:user:s_trackable"])
    }

    @Test("Trackable sessions fetch uses HTTPS provider API URL for non-local HTTP base")
    func trackableSessionsFetchUsesHTTPSProviderAPIURLForNonLocalHTTPBase() async throws {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        final class RequestBox: @unchecked Sendable {
            var url: URL?
            var authorization: String?
        }
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            requestBox.url = request.url
            requestBox.authorization = request.value(forHTTPHeaderField: "Authorization")
            let data = #"""
            {
              "sessions": [
                {
                  "sessionKey": "agent:heimdal:main",
                  "displayName": "Heimdal Main",
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

        let sessions = try await streamAPIClient.fetchTrackableSessions(token: "jwt")

        #expect(sessions.map(\.sessionKey) == ["agent:heimdal:main"])
        #expect(requestBox.url?.absoluteString == "https://tars.tail4105e8.ts.net:19443/api/trackable-sessions")
        #expect(requestBox.authorization == "Bearer jwt")
    }

    @Test("Trackable sessions fetch preserves local HTTP provider API URL")
    func trackableSessionsFetchPreservesLocalHTTPProviderAPIURL() async throws {
        let baseURL = URL(string: "http://127.0.0.1:18800")!
        final class RequestBox: @unchecked Sendable {
            var url: URL?
        }
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            requestBox.url = request.url
            let data = #"{ "sessions": [] }"#.data(using: .utf8) ?? Data()
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

        let sessions = try await streamAPIClient.fetchTrackableSessions(token: nil)

        #expect(sessions.isEmpty)
        #expect(requestBox.url?.absoluteString == "http://127.0.0.1:18800/api/trackable-sessions")
    }

    @MainActor
    @Test("Upload uses HTTPS provider API URL for non-local HTTP base")
    func uploadUsesHTTPSProviderAPIURLForNonLocalHTTPBase() async throws {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        final class RequestBox: @unchecked Sendable {
            var url: URL?
            var authorization: String?
        }
        let auth = ProviderServiceTestAuthManager(token: "jwt")
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            requestBox.url = request.url
            requestBox.authorization = request.value(forHTTPHeaderField: "Authorization")
            let data = #"{ "assetId": "asset_1", "mimeType": "image/png" }"#.data(using: .utf8) ?? Data()
            return (
                HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let service = UploadService(
            auth: auth,
            baseURLProvider: { baseURL },
            session: URLSession(configuration: configuration)
        )

        let assetId = try await service.upload(data: Data([0x01]), mimeType: "image/png", filename: "probe.png")

        #expect(assetId == "asset_1")
        #expect(requestBox.url?.absoluteString == "https://tars.tail4105e8.ts.net:19443/upload")
        #expect(requestBox.authorization == "Bearer jwt")
    }

    @MainActor
    @Test("Download uses HTTPS provider API URL for non-local HTTP base")
    func downloadUsesHTTPSProviderAPIURLForNonLocalHTTPBase() async throws {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        final class RequestBox: @unchecked Sendable {
            var url: URL?
            var authorization: String?
        }
        let auth = ProviderServiceTestAuthManager(token: "jwt")
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            requestBox.url = request.url
            requestBox.authorization = request.value(forHTTPHeaderField: "Authorization")
            return (
                HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data([0x02])
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let service = UploadService(
            auth: auth,
            baseURLProvider: { baseURL },
            session: URLSession(configuration: configuration)
        )

        let data = try await service.download(assetId: "asset/with space")

        #expect(data == Data([0x02]))
        #expect(requestBox.url?.absoluteString == "https://tars.tail4105e8.ts.net:19443/download/asset%2Fwith%20space")
        #expect(requestBox.authorization == "Bearer jwt")
    }

    @Test("API base URL candidates prefer HTTPS front then direct HTTP")
    func apiBaseURLCandidatesPreferHTTPSFrontThenDirectHTTP() {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        let candidates = ProviderHTTPURLResolver.apiBaseURLCandidates(from: baseURL)
        #expect(candidates.map(\.absoluteString) == [
            "https://tars.tail4105e8.ts.net:19443",
            "http://100.85.66.60:18800"
        ])

        let localBase = URL(string: "http://127.0.0.1:18800")!
        #expect(ProviderHTTPURLResolver.apiBaseURLCandidates(from: localBase) == [localBase])
    }

    @Test("Transport gap classification separates front gaps from provider errors")
    func transportGapClassificationSeparatesFrontGapsFromProviderErrors() {
        let plainNotFound = Data("not found".utf8)
        let providerEnvelope = Data(#"{"error":{"code":"stream_not_found","message":"Stream not found"}}"#.utf8)
        let uploadEnvelope = Data(#"{"type":"error","code":"auth_failed","message":"Missing authorization"}"#.utf8)

        #expect(ProviderHTTPURLResolver.isTransportGapResponse(statusCode: 404, data: plainNotFound))
        #expect(ProviderHTTPURLResolver.isTransportGapResponse(statusCode: 404, data: Data()))
        #expect(ProviderHTTPURLResolver.isTransportGapResponse(statusCode: 502, data: providerEnvelope))
        #expect(!ProviderHTTPURLResolver.isTransportGapResponse(statusCode: 404, data: providerEnvelope))
        #expect(!ProviderHTTPURLResolver.isTransportGapResponse(statusCode: 404, data: uploadEnvelope))
        #expect(!ProviderHTTPURLResolver.isTransportGapResponse(statusCode: 401, data: plainNotFound))
        #expect(!ProviderHTTPURLResolver.isTransportGapResponse(statusCode: 200, data: plainNotFound))
    }

    @MainActor
    @Test("Stream request falls back to direct HTTP when the HTTPS front omits the route")
    func streamRequestFallsBackToDirectHTTPWhenFrontOmitsRoute() async throws {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        final class RequestBox: @unchecked Sendable {
            var urls: [String] = []
        }
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        let streamsJSON = #"""
        {
          "streams": [
            {
              "sessionKey": "agent:main:clawline:flynn:s_direct",
              "displayName": "Direct",
              "kind": "main",
              "orderIndex": 0,
              "isBuiltIn": true,
              "createdAt": 1700000000000,
              "updatedAt": 1700000000000
            }
          ]
        }
        """#.data(using: .utf8) ?? Data()
        HTTPStubURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""
            requestBox.urls.append(urlString)
            if urlString.hasPrefix("https://tars.tail4105e8.ts.net:19443") {
                return (
                    HTTPURLResponse(
                        url: request.url ?? baseURL,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/plain"]
                    )!,
                    Data("not found".utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                streamsJSON
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let client = StreamAPIClient(baseURLProvider: { baseURL }, session: URLSession(configuration: configuration))

        let streams = try await client.fetchStreams(token: "jwt")

        #expect(streams.map(\.sessionKey) == ["agent:main:clawline:flynn:s_direct"])
        #expect(requestBox.urls == [
            "https://tars.tail4105e8.ts.net:19443/api/streams",
            "http://100.85.66.60:18800/api/streams"
        ])

        // Sticky: the next request should try the proven direct base first.
        let sessions = try await client.fetchStreams(token: "jwt")
        #expect(sessions.count == 1)
        #expect(requestBox.urls.count == 3)
        #expect(requestBox.urls[2] == "http://100.85.66.60:18800/api/streams")
    }

    @MainActor
    @Test("Sticky base does not pin the client to a base that goes bad")
    func stickyBaseDoesNotPinClientToBadBase() async throws {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        final class StubState: @unchecked Sendable {
            var urls: [String] = []
            var directIsHealthy = true
        }
        let state = StubState()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        let streamsJSON = #"""
        {
          "streams": [
            {
              "sessionKey": "agent:main:clawline:flynn:s_recovery",
              "displayName": "Recovery",
              "kind": "main",
              "orderIndex": 0,
              "isBuiltIn": true,
              "createdAt": 1700000000000,
              "updatedAt": 1700000000000
            }
          ]
        }
        """#.data(using: .utf8) ?? Data()
        HTTPStubURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""
            state.urls.append(urlString)
            let isDirect = urlString.hasPrefix("http://100.85.66.60:18800")
            let healthy = isDirect ? state.directIsHealthy : !state.directIsHealthy
            if healthy {
                return (
                    HTTPURLResponse(
                        url: request.url ?? baseURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    streamsJSON
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain"]
                )!,
                Data("not found".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let client = StreamAPIClient(baseURLProvider: { baseURL }, session: URLSession(configuration: configuration))

        // Phase 1: HTTPS front is gapped, direct is healthy -> falls back, sticks direct.
        _ = try await client.fetchStreams(token: "jwt")
        #expect(state.urls.count == 2)

        // Phase 2: direct goes bad, HTTPS front recovers -> ladder must recover, not pin.
        state.directIsHealthy = false
        let streams = try await client.fetchStreams(token: "jwt")
        #expect(streams.count == 1)
        #expect(state.urls.count == 4)
        #expect(state.urls[2] == "http://100.85.66.60:18800/api/streams")
        #expect(state.urls[3] == "https://tars.tail4105e8.ts.net:19443/api/streams")

        // Phase 3: sticky updated to the recovered HTTPS front.
        let again = try await client.fetchStreams(token: "jwt")
        #expect(again.count == 1)
        #expect(state.urls.count == 5)
        #expect(state.urls[4] == "https://tars.tail4105e8.ts.net:19443/api/streams")
    }

    @MainActor
    @Test("Download falls back to direct HTTP when the HTTPS front omits the route")
    func downloadFallsBackToDirectHTTPWhenFrontOmitsRoute() async throws {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        final class RequestBox: @unchecked Sendable {
            var urls: [String] = []
        }
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""
            requestBox.urls.append(urlString)
            if urlString.hasPrefix("https://tars.tail4105e8.ts.net:19443") {
                return (
                    HTTPURLResponse(
                        url: request.url ?? baseURL,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/plain"]
                    )!,
                    Data("not found".utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/octet-stream"]
                )!,
                Data([0xAB, 0xCD])
            )
        }
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let service = UploadService(
            auth: auth,
            baseURLProvider: { baseURL },
            session: URLSession(configuration: configuration)
        )

        let data = try await service.download(assetId: "asset1")

        #expect(data == Data([0xAB, 0xCD]))
        #expect(requestBox.urls == [
            "https://tars.tail4105e8.ts.net:19443/download/asset1",
            "http://100.85.66.60:18800/download/asset1"
        ])
    }

    @MainActor
    @Test("Provider error envelopes do not trigger direct HTTP fallback")
    func providerErrorEnvelopesDoNotTriggerDirectHTTPFallback() async throws {
        let baseURL = URL(string: "http://100.85.66.60:18800")!
        final class RequestBox: @unchecked Sendable {
            var urls: [String] = []
        }
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            requestBox.urls.append(request.url?.absoluteString ?? "")
            return (
                HTTPURLResponse(
                    url: request.url ?? baseURL,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"error":{"code":"stream_not_found","message":"Stream not found"}}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let client = StreamAPIClient(baseURLProvider: { baseURL }, session: URLSession(configuration: configuration))

        do {
            _ = try await client.deleteStream(sessionKey: "agent:x", idempotencyKey: nil, token: "jwt")
            #expect(Bool(false), "Expected StreamAPIError")
        } catch let error as StreamAPIError {
            #expect(error.code == "stream_not_found")
            #expect(error.statusCode == 404)
        }
        #expect(requestBox.urls.count == 1)
        #expect(requestBox.urls[0].hasPrefix("https://tars.tail4105e8.ts.net:19443"))
    }

    @MainActor
    @Test("Upload and download preserve localhost HTTP provider base")
    func uploadAndDownloadPreserveLocalhostHTTPProviderBase() async throws {
        let baseURL = URL(string: "http://localhost:18800")!
        final class RequestBox: @unchecked Sendable {
            var urls: [URL?] = []
        }
        let auth = ProviderServiceTestAuthManager(token: "jwt")
        let requestBox = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            requestBox.urls.append(request.url)
            if request.httpMethod == "POST" {
                let data = #"{ "assetId": "local_asset", "mimeType": "image/png" }"#.data(using: .utf8) ?? Data()
                return (
                    HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    data
                )
            }
            return (
                HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data([0x03])
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        let service = UploadService(
            auth: auth,
            baseURLProvider: { baseURL },
            session: URLSession(configuration: configuration)
        )

        let assetId = try await service.upload(data: Data([0x01]), mimeType: "image/png", filename: nil)
        let data = try await service.download(assetId: "local_asset")

        #expect(assetId == "local_asset")
        #expect(data == Data([0x03]))
        #expect(requestBox.urls.map { $0?.absoluteString } == [
            "http://localhost:18800/upload",
            "http://localhost:18800/download/local_asset"
        ])
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
              "metadataContextGeneration": "generation-status-a",
              "display": {
                "model": "gpt-5.6",
                "fallbackModels": null,
                "provider": "openai",
                "harness": "codex",
                "authMode": "oauth",
                "reasoningLevel": null,
                "thinkingLevel": "high",
                "fastMode": true,
                "mode": null,
                "verbosity": null,
                "codexUsage": {
                  "freshness": "fresh",
                  "fetchedAt": 1784000000000,
                  "windows": [
                    { "label": "5h", "remainingPercent": 64, "resetAt": 1784003600000 },
                    { "label": "Week", "remainingPercent": 28, "resetAt": 1784604800000 }
                  ],
                  "unavailableReason": null
                }
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
        #expect(status.metadataContextGeneration == "generation-status-a")
        #expect(status.display.provider == "openai")
        #expect(status.display.model == "gpt-5.6")
        #expect(status.display.authMode == "oauth")
        #expect(status.display.thinkingLevel == "high")
        #expect(status.display.fastMode == true)
        #expect(status.display.codexUsage?.freshness == .fresh)
        #expect(status.display.codexUsage?.windows.map(\.label) == [.fiveHour, .week])
        #expect(status.display.codexUsage?.windows.map(\.remainingPercent) == [64, 28])
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
            let bodyData = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
                stream.open(); defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                }
                return data
            } ?? Data()
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
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
              "deletedSessionKey": "agent:main:openclaw:user:s_trackable"
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

    @Test("T142: Delete stream uses HTTP control plane without target WebSocket")
    func deleteStreamUsesControlPlaneWithoutTargetWebSocket() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let inactiveSessionKey = "agent:main:openclaw:user:s_inactive_delete"
        var capturedRequest: URLRequest?
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            capturedRequest = request
            let data = #"""
            {
              "deletedSessionKey": "agent:main:openclaw:user:s_inactive_delete"
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

        let deletedKey = try await service.deleteStream(
            sessionKey: inactiveSessionKey,
            idempotencyKey: "req_t142_delete"
        )

        let request = try #require(capturedRequest)
        #expect(deletedKey == inactiveSessionKey)
        #expect(connector.connectedURL == nil)
        #expect(mockSocket.sentTexts.isEmpty)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/streams/agent%3Amain%3Aopenclaw%3Auser%3As_inactive_delete")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        let body = try #require(request.httpBody ?? Self.bodyData(from: request.httpBodyStream))
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(payload?["idempotencyKey"] == "req_t142_delete")
    }

    @Test("T1751 org-options fetch decodes the full shape over the device bearer")
    func orgOptionsFetchDecodesFullShape() async throws {
        let baseURL = URL(string: "http://127.0.0.1:18800")!
        final class RequestBox: @unchecked Sendable {
            var path: String?
            var authorization: String?
        }
        let box = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            box.path = request.url?.path
            box.authorization = request.value(forHTTPHeaderField: "Authorization")
            let data = #"""
            {
              "harnesses": ["claude", "codex"],
              "models": {
                "claude": [{"id": "m1", "ref": "claude-fable-5", "name": "Fable 5", "provider": "anthropic"}],
                "codex": [{"id": "m2", "ref": "gpt-5.6-sol", "name": "Sol", "provider": "openai"}]
              },
              "hosts": ["eezo", "tars"],
              "archetypes": [{"name": "researcher", "where": ["*"], "defaults": {"harness": "claude"}}]
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

        let options = try await streamAPIClient.fetchOrgOptions(token: "jwt")

        #expect(box.path == "/api/org-options")
        #expect(box.authorization == "Bearer jwt")
        #expect(options.harnesses == ["claude", "codex"])
        #expect(options.models["codex"]?.first?.ref == "gpt-5.6-sol")
        #expect(options.hosts == ["eezo", "tars"])
        #expect(options.archetypes.first?.where == ["*"])
    }

    @Test("T1751 set_harness session-control carries the harness and omits the model")
    func setHarnessSessionControlEncodesHarnessWithoutModel() async throws {
        let baseURL = URL(string: "http://127.0.0.1:18800")!
        final class RequestBox: @unchecked Sendable {
            var body: Data?
            var method: String?
            var path: String?
        }
        let box = RequestBox()
        defer { HTTPStubURLProtocol.requestHandler = nil }
        HTTPStubURLProtocol.requestHandler = { request in
            box.method = request.httpMethod
            box.path = request.url?.path
            box.body = request.httpBody ?? Self.bodyData(from: request.httpBodyStream)
            let data = #"""
            { "ok": true, "sessionKey": "agent:main:clawline:user:s_harness", "action": "set_harness" }
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

        let response = try await streamAPIClient.applySessionControl(
            sessionKey: "agent:main:clawline:user:s_harness",
            action: .setHarness,
            value: "codex",
            enabled: nil,
            token: "jwt"
        )

        #expect(response.ok)
        #expect(box.method == "POST")
        #expect(box.path == "/api/session-control")
        let body = try #require(box.body)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(payload?["action"] as? String == "set_harness")
        #expect(payload?["harness"] as? String == "codex")
        #expect(payload?["sessionKey"] as? String == "agent:main:clawline:user:s_harness")
        // Model omitted (encoded null): the gateway picks the target harness default.
        #expect((payload?["model"] as? String) == nil)
    }

    private static func bodyData(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                return nil
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
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
        let service = ProviderDirectChatClient(
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

@MainActor
private final class ProviderServiceTestAuthManager: AuthManaging {
    var isAuthenticated: Bool
    var currentUserId: String?
    var token: String?
    var isAdmin: Bool = false

    init(token: String? = nil, userId: String? = "user_1") {
        self.token = token
        self.currentUserId = userId
        isAuthenticated = token != nil
    }

    func storeCredentials(token: String, userId: String) {
        self.token = token
        currentUserId = userId
        isAuthenticated = true
    }

    func updateAdminStatus(_ isAdmin: Bool) {
        self.isAdmin = isAdmin
    }

    func refreshAdminStatusFromToken() {}

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false
        isAdmin = false
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

private final class AsyncFallbackMockWebSocketConnector: WebSocketConnecting {
    let secureClient: MockWebSocketClient
    let fallbackClient: MockWebSocketClient
    private(set) var connectedURLs: [URL] = []

    init(secureClient: MockWebSocketClient, fallbackClient: MockWebSocketClient) {
        self.secureClient = secureClient
        self.fallbackClient = fallbackClient
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        connectedURLs.append(url)
        if url.scheme == "wss" {
            return secureClient
        }
        return fallbackClient
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

private func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(10),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while !condition() {
        if clock.now >= deadline {
            throw CancellationError()
        }
        try await Task.sleep(forDuration: poll)
    }
}

private func waitForTaskValue<T: Sendable>(
    timeout: Duration,
    task: Task<T, Never>
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(forDuration: timeout)
            throw CancellationError()
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
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
