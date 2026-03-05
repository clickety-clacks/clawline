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
    private static let validServerEventID = "s_11111111-1111-1111-1111-111111111111"

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

        async let connectResult = service.connect(token: "jwt", lastMessageId: Self.validServerEventID)
        try await connectResult

        let message = await iterator.next()

        #expect(connector.connectedURL?.absoluteString == "wss://example.com/ws")
        #expect(mockSocket.sentTexts.contains {
            $0.contains("\"type\":\"auth\"") && $0.contains("\"lastMessageId\":\"\(Self.validServerEventID)\"")
        })
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

    // T140: deleteStream must fail fast with notConnected when authToken is nil (not authenticated).
    // Previously, the nil token was passed through to StreamAPIClient which omitted the Authorization
    // header, causing the server to return 401 "Missing authorization" — confusing the user.
    @Test("T140: deleteStream fails with notConnected when not authenticated")
    func deleteStreamFailsNotConnectedWhenUnauthenticated() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )
        // Do NOT connect — authToken remains nil.
        do {
            _ = try await service.deleteStream(sessionKey: "agent:main:clawline:user:s_abcd1234", idempotencyKey: nil)
            Issue.record("Expected notConnected error, but deleteStream succeeded")
        } catch let error as ProviderChatService.Error {
            switch error {
            case .notConnected:
                break // ✓ expected
            default:
                Issue.record("Expected notConnected, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Lifecycle attempt emits coordinator epoch on transport and auth events")
    func lifecycleAttemptUsesProvidedEpoch() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        var iterator = service.lifecycleTransportEvents.makeAsyncIterator()
        let epoch = 42

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true, "replayCount": 0, "replayTruncated": false, "historyReset": false }"#)
        }

        service.startConnectionAttempt(epoch: epoch, lastMessageId: Self.validServerEventID, token: "jwt")

        var openedEvent: LifecycleTransportEvent?
        var authEvent: LifecycleTransportEvent?

        for _ in 0..<4 {
            guard let event = await iterator.next() else { continue }
            switch event.payload {
            case .transportOpened:
                openedEvent = event
            case .authResult:
                authEvent = event
            default:
                break
            }
            if openedEvent != nil, authEvent != nil { break }
        }

        #expect(openedEvent?.epoch == epoch)
        #expect(authEvent?.epoch == epoch)
    }

    @Test("Lifecycle attempts echo the epoch received for each attempt")
    func lifecycleAttemptsEchoReceivedEpoch() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        var iterator = service.lifecycleTransportEvents.makeAsyncIterator()
        let firstEpoch = 7
        let secondEpoch = 19

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true, "replayCount": 0, "replayTruncated": false, "historyReset": false }"#)
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "auth_result", "success": true, "replayCount": 0, "replayTruncated": false, "historyReset": false }"#)
        }

        service.startConnectionAttempt(epoch: firstEpoch, lastMessageId: nil, token: "jwt")
        var firstAuthEpoch: Int?
        for _ in 0..<4 {
            guard let event = await iterator.next() else { continue }
            if case .authResult = event.payload {
                firstAuthEpoch = event.epoch
                break
            }
        }

        service.startConnectionAttempt(epoch: secondEpoch, lastMessageId: nil, token: "jwt")
        var secondAuthEpoch: Int?
        for _ in 0..<4 {
            guard let event = await iterator.next() else { continue }
            if case .authResult = event.payload {
                secondAuthEpoch = event.epoch
                break
            }
        }

        #expect(firstAuthEpoch == firstEpoch)
        #expect(secondAuthEpoch == secondEpoch)
    }

    @Test("Invalid lifecycle lastMessageId clears replay cursors and emits recoverable auth failure")
    func invalidLifecycleLastMessageIdClearsReplayCursors() async throws {
        let mockSocket = MockWebSocketClient()
        let connector = MockWebSocketConnector(client: mockSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )
        service.setReplayCursor(Self.validServerEventID, for: "agent:main:main")

        var iterator = service.lifecycleTransportEvents.makeAsyncIterator()

        Task {
            try await Task.sleep(forDuration: .milliseconds(20))
            mockSocket.enqueue(text: #"{ "type": "error", "code": "invalid_message", "message": "Invalid lastMessageId" }"#)
        }

        service.startConnectionAttempt(epoch: 5, lastMessageId: Self.validServerEventID, token: "jwt")

        var sawRecoverableFailure = false
        for _ in 0..<6 {
            guard let event = await iterator.next() else { continue }
            if case .authResult(let success, _, _, _, let failureReason) = event.payload,
               success == false,
               failureReason == .invalidLastMessageId {
                sawRecoverableFailure = true
                break
            }
        }

        #expect(sawRecoverableFailure)
        #expect(service.replayCursorSnapshot().isEmpty)
    }

    @Test("Stale fallback close cannot knock coordinator out of authenticating for active attempt")
    func staleFallbackCloseDoesNotMoveCoordinatorOutOfAuthenticating() async throws {
        let firstSocket = FailingLifecycleWebSocketClient()
        let secondSocket = AuthResultLifecycleWebSocketClient(
            authResultText: #"{ "type": "auth_result", "success": true, "replayCount": 0, "replayTruncated": false, "historyReset": false }"#,
            authResultDelay: .milliseconds(80)
        )
        let connector = LifecycleFallbackRaceConnector(first: firstSocket, second: secondSocket)
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderChatService(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        let coordinator = ConnectionLifecycleCoordinator(startAttempt: { _, _, _ in }, stopAttempt: {})
        let outputRecorder = LifecycleOutputRecorder()

        let outputs = await coordinator.outputs
        let outputTask = Task {
            var iterator = outputs.makeAsyncIterator()
            while let output = await iterator.next() {
                await outputRecorder.append(output)
            }
        }

        let forwardTask = Task {
            var iterator = service.lifecycleTransportEvents.makeAsyncIterator()
            while let event = await iterator.next() {
                await coordinator.handleTransportEvent(event)
            }
        }

        await coordinator.setAuthToken("jwt")
        await coordinator.viewAppeared()
        await coordinator.startIfNeeded()
        try await Task.sleep(forDuration: .milliseconds(10))
        service.startConnectionAttempt(epoch: 1, lastMessageId: nil, token: "jwt")

        var reachedLive = false
        for _ in 0..<60 {
            if await coordinator.phase == .live {
                reachedLive = true
                break
            }
            try await Task.sleep(forDuration: .milliseconds(25))
        }

        #expect(reachedLive)

        let transitions = await outputRecorder.phaseTransitions()
        #expect(!transitions.contains { transition in
            transition.from == .authenticating
                && transition.to == .recovering
                && transition.epoch == 1
        })

        service.disconnect()
        forwardTask.cancel()
        outputTask.cancel()
    }

    @Test("Late auth success after transport close keeps same epoch and reaches live")
    func authSuccessAfterRecoveringRaceReachesLive() async {
        let coordinator = ConnectionLifecycleCoordinator(startAttempt: { _, _, _ in }, stopAttempt: {})
        await coordinator.setAuthToken("jwt")
        await coordinator.viewAppeared()
        await coordinator.startIfNeeded()

        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportOpened))
        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportClosed(reason: .error)))
        await coordinator.handleTransportEvent(
            .init(
                epoch: 1,
                payload: .authResult(
                    success: true,
                    replayCount: 0,
                    replayTruncated: false,
                    historyReset: false,
                    failureReason: nil
                )
            )
        )

        #expect(await coordinator.phase == .live)
    }

    @Test("History reset auth does not trigger immediate timeout failure")
    func historyResetAuthDoesNotImmediatelyFail() async throws {
        let coordinator = ConnectionLifecycleCoordinator(startAttempt: { _, _, _ in }, stopAttempt: {})
        await coordinator.setAuthToken("jwt")
        await coordinator.viewAppeared()
        await coordinator.startIfNeeded()

        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportOpened))
        await coordinator.handleTransportEvent(
            .init(
                epoch: 1,
                payload: .authResult(
                    success: true,
                    replayCount: 27,
                    replayTruncated: false,
                    historyReset: true,
                    failureReason: nil
                )
            )
        )

        try await Task.sleep(forDuration: .milliseconds(100))
        #expect(await coordinator.phase == .authenticating)
    }

    @Test("Invalid lastMessageId failure retries once with cleared cursor, then fails")
    func invalidLastMessageIdRetriesOnceThenFails() async throws {
        let capture = StartAttemptCapture()
        let coordinator = ConnectionLifecycleCoordinator(
            startAttempt: { epoch, lastMessageId, _ in
                capture.append(epoch: epoch, lastMessageId: lastMessageId)
            },
            stopAttempt: {}
        )

        await coordinator.seedCanonicalCursor(Self.validServerEventID)
        await coordinator.setAuthToken("jwt")
        await coordinator.viewAppeared()
        await coordinator.startIfNeeded()

        #expect(capture.snapshot().count == 1)
        #expect(capture.snapshot()[0].epoch == 1)
        #expect(capture.snapshot()[0].lastMessageId == Self.validServerEventID)

        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportOpened))
        await coordinator.handleTransportEvent(
            .init(
                epoch: 1,
                payload: .authResult(
                    success: false,
                    replayCount: nil,
                    replayTruncated: nil,
                    historyReset: nil,
                    failureReason: .invalidLastMessageId
                )
            )
        )

        for _ in 0..<40 where capture.snapshot().count < 2 {
            try await Task.sleep(forDuration: .milliseconds(5))
        }

        #expect(capture.snapshot().count == 2)
        #expect(capture.snapshot()[1].epoch == 2)
        #expect(capture.snapshot()[1].lastMessageId == nil)

        await coordinator.handleTransportEvent(.init(epoch: 2, payload: .transportOpened))
        await coordinator.handleTransportEvent(
            .init(
                epoch: 2,
                payload: .authResult(
                    success: false,
                    replayCount: nil,
                    replayTruncated: nil,
                    historyReset: nil,
                    failureReason: .invalidLastMessageId
                )
            )
        )

        #expect(await coordinator.phase == .failed)
    }

    @Test("authChanged waits for viewAppeared and does not auto-retry from failed")
    func authChangedRequiresViewAppearedAndSkipsFailedAutoRetry() async {
        let capture = StartAttemptCapture()
        let coordinator = ConnectionLifecycleCoordinator(
            startAttempt: { epoch, lastMessageId, _ in
                capture.append(epoch: epoch, lastMessageId: lastMessageId)
            },
            stopAttempt: {}
        )

        await coordinator.authChanged(token: "jwt")
        #expect(capture.snapshot().isEmpty)
        #expect(await coordinator.phase == .idle)

        await coordinator.viewAppeared()
        #expect(capture.snapshot().count == 1)
        #expect(await coordinator.phase == .connecting)

        await coordinator.handleTransportEvent(.init(epoch: 1, payload: .transportOpened))
        await coordinator.handleTransportEvent(
            .init(
                epoch: 1,
                payload: .authResult(
                    success: false,
                    replayCount: nil,
                    replayTruncated: nil,
                    historyReset: nil,
                    failureReason: .rejected
                )
            )
        )
        #expect(await coordinator.phase == .failed)

        await coordinator.authChanged(token: "jwt_refreshed")
        #expect(await coordinator.phase == .failed)
        #expect(capture.snapshot().count == 1)
    }

    @Test("viewAppeared and sceneActivated honor token presence and idle-phase gating")
    func startupSignalsHonorTokenAndPhaseGates() async {
        let capture = StartAttemptCapture()
        let coordinator = ConnectionLifecycleCoordinator(
            startAttempt: { epoch, lastMessageId, _ in
                capture.append(epoch: epoch, lastMessageId: lastMessageId)
            },
            stopAttempt: {}
        )

        await coordinator.viewAppeared()
        await coordinator.sceneActivated()
        #expect(capture.snapshot().isEmpty)

        await coordinator.setAuthToken("jwt")
        await coordinator.sceneActivated()
        #expect(capture.snapshot().isEmpty)
        #expect(await coordinator.phase == .idle)

        await coordinator.viewAppeared()
        #expect(capture.snapshot().count == 1)
        #expect(await coordinator.phase == .connecting)

        await coordinator.sceneActivated()
        #expect(capture.snapshot().count == 1)
    }

    @Test("Startup signal burst results in one connect attempt")
    func startupSignalBurstStartsOnce() async {
        let capture = StartAttemptCapture()
        let coordinator = ConnectionLifecycleCoordinator(
            startAttempt: { epoch, lastMessageId, _ in
                capture.append(epoch: epoch, lastMessageId: lastMessageId)
            },
            stopAttempt: {}
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.authChanged(token: "jwt") }
            group.addTask { await coordinator.viewAppeared() }
            group.addTask { await coordinator.sceneActivated() }
        }

        let attempts = capture.snapshot()
        #expect(attempts.count == 1)
        #expect(attempts.first?.epoch == 1)
        #expect(await coordinator.phase == .connecting)
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

private actor LifecycleOutputRecorder {
    struct PhaseTransitionRecord: Equatable {
        let from: ConnectionLifecyclePhase
        let to: ConnectionLifecyclePhase
        let epoch: Int
    }

    private var transitions: [PhaseTransitionRecord] = []

    func append(_ output: ConnectionLifecycleOutput) {
        guard case .phaseTransition(let from, let to, let epoch, _) = output else { return }
        transitions.append(.init(from: from, to: to, epoch: epoch))
    }

    func phaseTransitions() -> [PhaseTransitionRecord] {
        transitions
    }
}

private final class LifecycleFallbackRaceConnector: WebSocketConnecting {
    private let first: FailingLifecycleWebSocketClient
    private let second: AuthResultLifecycleWebSocketClient
    private var attemptCount = 0

    init(first: FailingLifecycleWebSocketClient, second: AuthResultLifecycleWebSocketClient) {
        self.first = first
        self.second = second
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        attemptCount += 1
        if attemptCount == 1 {
            return first
        }
        if attemptCount == 2 {
            first.finishAsStaleClose(after: .milliseconds(20))
            return second
        }
        return second
    }
}

private final class FailingLifecycleWebSocketClient: WebSocketClient {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var lastCloseInfo: WebSocketCloseInfo?

    init() {
        var continuation: AsyncStream<String>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var incomingTextMessages: AsyncStream<String> { stream }

    func send(text: String) async throws {
        throw URLError(.cannotConnectToHost)
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {
        lastCloseInfo = WebSocketCloseInfo(code: Int((code ?? .normalClosure).rawValue), reason: nil)
        continuation.finish()
    }

    func finishAsStaleClose(after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(forDuration: delay)
            guard let self else { return }
            self.lastCloseInfo = WebSocketCloseInfo(code: 1006, reason: "stale_fallback_close")
            self.continuation.finish()
        }
    }
}

private final class AuthResultLifecycleWebSocketClient: WebSocketClient {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let authResultText: String
    private let authResultDelay: Duration
    private(set) var lastCloseInfo: WebSocketCloseInfo?

    init(authResultText: String, authResultDelay: Duration) {
        self.authResultText = authResultText
        self.authResultDelay = authResultDelay
        var continuation: AsyncStream<String>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var incomingTextMessages: AsyncStream<String> { stream }

    func send(text: String) async throws {
        guard text.contains(#""type":"auth""#) else { return }
        let authResultText = self.authResultText
        let authResultDelay = self.authResultDelay
        let continuation = self.continuation
        Task {
            try? await Task.sleep(forDuration: authResultDelay)
            continuation.yield(authResultText)
        }
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {
        lastCloseInfo = WebSocketCloseInfo(code: Int((code ?? .normalClosure).rawValue), reason: nil)
        continuation.finish()
    }
}

private final class StartAttemptCapture {
    struct Attempt: Equatable {
        let epoch: Int
        let lastMessageId: String?
    }

    private var attempts: [Attempt] = []
    private let lock = NSLock()

    func append(epoch: Int, lastMessageId: String?) {
        lock.lock()
        attempts.append(.init(epoch: epoch, lastMessageId: lastMessageId))
        lock.unlock()
    }

    func snapshot() -> [Attempt] {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }
}
