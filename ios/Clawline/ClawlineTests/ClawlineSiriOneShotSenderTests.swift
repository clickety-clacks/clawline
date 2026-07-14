import Foundation
import Testing
@testable import Clawline

@MainActor
struct ClawlineSiriOneShotSenderTests {
    @Test("One live destination sends once with an explicit key and ends on matching ack")
    func sendsExactlyOnceAndWaitsForMatchingAck() async throws {
        let service = SiriFakeChatService(
            streams: [siriStream("s_target", name: "Target")]
        )
        service.eventsToEmitOnSend = [
            .messageAcked(id: "c_unrelated"),
            .agentProgress(.init(
                type: "agent_progress",
                version: nil,
                sessionKey: "s_target",
                runId: nil,
                messageId: nil,
                seq: nil,
                timestamp: nil,
                state: "running",
                event: nil,
                title: nil,
                name: nil,
                summary: nil,
                progressText: nil
            )),
            .messageAcked(id: "c_expected")
        ]
        let acceptedAt = Date(timeIntervalSince1970: 42)
        let sender = makeSender(service, now: { acceptedAt })

        let receipt = try await sender.send(
            to: .sessionKey("s_target"),
            content: "Keep this text exactly"
        )

        #expect(service.connectCount == 1)
        #expect(service.fetchCount == 1)
        #expect(service.eventSubscriptionCount == 1)
        #expect(service.sendCalls == [
            .init(
                id: "c_expected",
                content: "Keep this text exactly",
                attachmentCount: 0,
                sessionKey: "s_target",
                referenceCount: 0
            )
        ])
        #expect(receipt.messageID == "c_expected")
        #expect(receipt.session.sessionKey == "s_target")
        #expect(receipt.content == "Keep this text exactly")
        #expect(receipt.acknowledgedAt == acceptedAt)
        #expect(service.disconnectCount == 1)
    }

    @Test("A stale exact entity ID fails before provider send")
    func staleDestinationFailsBeforeSend() async {
        let service = SiriFakeChatService(streams: [siriStream("s_live", name: "Live")])
        let sender = makeSender(service)

        await expectSendError(.destinationNotFound) {
            _ = try await sender.send(to: .sessionKey("s_deleted"), content: "Hello")
        }
        #expect(service.sendCalls.isEmpty)
    }

    @Test("An ambiguous display name fails before provider send")
    func ambiguousDestinationFailsBeforeSend() async {
        let service = SiriFakeChatService(streams: [
            siriStream("s_one", name: "Build"),
            siriStream("s_two", name: "Build")
        ])
        let sender = makeSender(service)

        await expectSendError(.destinationAmbiguous) {
            _ = try await sender.send(to: .spokenDestination("build"), content: "Hello")
        }
        #expect(service.sendCalls.isEmpty)
    }

    @Test("Empty text fails before creating a provider dependency")
    func emptyTextFailsBeforeProviderWork() async {
        var factoryCalls = 0
        let sender = ClawlineSiriOneShotSender(makeService: {
            factoryCalls += 1
            return (SiriFakeChatService(streams: []), "token")
        })

        await expectSendError(.emptyText) {
            _ = try await sender.send(to: .sessionKey("s_target"), content: "  \n ")
        }
        #expect(factoryCalls == 0)
    }

    @Test("A correlated provider rejection ends without a second send")
    func providerRejectionEndsTheIntent() async {
        let service = SiriFakeChatService(streams: [siriStream("s_target", name: "Target")])
        service.eventsToEmitOnSend = [
            .messageError(messageId: "c_expected", code: "stream_not_found", message: "gone")
        ]
        let sender = makeSender(service)

        await expectSendError(.providerRejected(code: "stream_not_found", message: "gone")) {
            _ = try await sender.send(to: .sessionKey("s_target"), content: "Hello")
        }
        #expect(service.sendCalls.count == 1)
    }

    @Test("Connection interruption fails without retrying")
    func connectionInterruptionDoesNotRetry() async {
        let service = SiriFakeChatService(streams: [siriStream("s_target", name: "Target")])
        service.eventsToEmitOnSend = [.connectionInterrupted(reason: "network_lost")]
        let sender = makeSender(service)

        await expectSendError(.providerUnavailable) {
            _ = try await sender.send(to: .sessionKey("s_target"), content: "Hello")
        }
        #expect(service.sendCalls.count == 1)
        #expect(service.disconnectCount == 1)
    }

    @Test("Cancellation stops the ack wait and never sends again")
    func cancellationDoesNotRetry() async {
        let service = SiriFakeChatService(streams: [siriStream("s_target", name: "Target")])
        let sender = makeSender(service, acknowledgementTimeout: .seconds(10))
        let task = Task {
            try await sender.send(to: .sessionKey("s_target"), content: "Hello")
        }

        while service.sendCalls.isEmpty {
            await Task.yield()
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        await Task.yield()
        #expect(service.sendCalls.count == 1)
        #expect(service.disconnectCount == 1)
    }

    @Test("Cancellation during live resolution fails before provider send")
    func cancellationBeforeSendFailsClosed() async {
        let service = SiriFakeChatService(streams: [siriStream("s_target", name: "Target")])
        service.suspendsFetch = true
        let sender = makeSender(service, acknowledgementTimeout: .seconds(10))
        let task = Task {
            try await sender.send(to: .sessionKey("s_target"), content: "Hello")
        }

        while service.fetchContinuation == nil {
            await Task.yield()
        }
        task.cancel()
        service.resumeFetch()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(service.sendCalls.isEmpty)
        #expect(service.disconnectCount == 1)
    }

    @Test("Missing acknowledgement times out without retrying")
    func acknowledgementTimeoutDoesNotRetry() async {
        let service = SiriFakeChatService(streams: [siriStream("s_target", name: "Target")])
        let sender = makeSender(service, acknowledgementTimeout: .milliseconds(10))

        await expectSendError(.acknowledgementTimedOut) {
            _ = try await sender.send(to: .sessionKey("s_target"), content: "Hello")
        }
        #expect(service.sendCalls.count == 1)
    }

    @Test("Only one text recipient with no extra fields passes payload validation")
    func validatesTextOnlyPayload() throws {
        let payload = ClawlineSiriTextPayload(
            content: "  preserve spacing  ",
            recipientCount: 1,
            hasSubject: false,
            hasAttachments: false,
            hasAudioMessage: false,
            hasLocations: false,
            hasLinks: false,
            hasScheduledDate: false
        )

        #expect(try payload.validatedContent() == "  preserve spacing  ")
    }

    @Test("Unsupported or non-text payloads fail closed")
    func rejectsUnsupportedPayload() {
        let payloads = [
            ClawlineSiriTextPayload(content: nil, recipientCount: 1, hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 0, hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 2, hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 1, hasSubject: true, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 1, hasSubject: false, hasAttachments: true, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 1, hasSubject: false, hasAttachments: false, hasAudioMessage: true, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 1, hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: true, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 1, hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: true, hasScheduledDate: false),
            ClawlineSiriTextPayload(content: "text", recipientCount: 1, hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: true)
        ]

        for payload in payloads {
            #expect(throws: ClawlineSiriSendError.self) {
                try payload.validatedContent()
            }
        }
    }

    @Test("Intent operation forwards the exact entity ID and text once")
    func intentOperationMapsExactDestination() async throws {
        let sender = SiriCapturingMessageSender()
        let operation = ClawlineSiriSendIntentOperation(sender: sender)
        let payload = ClawlineSiriIntentPayload(
            destinationIDs: ["s_exact"],
            content: " exact text ",
            hasSubject: false,
            hasAttachments: false,
            hasAudioMessage: false,
            hasLocations: false,
            hasLinks: false,
            hasScheduledDate: false
        )

        _ = try await operation.send(payload)

        #expect(sender.calls == [.init(reference: .sessionKey("s_exact"), content: " exact text ")])
    }

    @Test("Intent operation rejects every unsupported Apple payload before sender mutation")
    func intentOperationFailsClosedBeforeSend() async {
        let sender = SiriCapturingMessageSender()
        let operation = ClawlineSiriSendIntentOperation(sender: sender)
        let unsupported = [
            ClawlineSiriIntentPayload(destinationIDs: [], content: "text", hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one", "s_two"], content: "text", hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one"], content: nil, hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one"], content: "text", hasSubject: true, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one"], content: "text", hasSubject: false, hasAttachments: true, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one"], content: "text", hasSubject: false, hasAttachments: false, hasAudioMessage: true, hasLocations: false, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one"], content: "text", hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: true, hasLinks: false, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one"], content: "text", hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: true, hasScheduledDate: false),
            ClawlineSiriIntentPayload(destinationIDs: ["s_one"], content: "text", hasSubject: false, hasAttachments: false, hasAudioMessage: false, hasLocations: false, hasLinks: false, hasScheduledDate: true)
        ]

        for payload in unsupported {
            do {
                _ = try await operation.send(payload)
                Issue.record("Expected unsupported payload failure")
            } catch let error as ClawlineSiriSendError {
                #expect(error == (payload.content == nil ? .emptyText : .unsupportedPayload))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(sender.calls.isEmpty)
    }

    private func makeSender(
        _ service: SiriFakeChatService,
        acknowledgementTimeout: Duration = .seconds(1),
        now: @escaping () -> Date = Date.init
    ) -> ClawlineSiriOneShotSender {
        ClawlineSiriOneShotSender(
            makeService: { (service, "token") },
            acknowledgementTimeout: acknowledgementTimeout,
            makeMessageID: { "c_expected" },
            now: now
        )
    }

    private func expectSendError(
        _ expected: ClawlineSiriSendError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as ClawlineSiriSendError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class SiriCapturingMessageSender: ClawlineSiriMessageSending {
    struct Call: Equatable {
        let reference: ClawlineSiriSessionReference
        let content: String
    }

    var calls: [Call] = []

    func send(
        to reference: ClawlineSiriSessionReference,
        content: String
    ) async throws -> ClawlineSiriSendReceipt {
        calls.append(.init(reference: reference, content: content))
        return ClawlineSiriSendReceipt(
            messageID: "c_captured",
            session: siriStream("s_exact", name: "Exact"),
            content: content,
            acknowledgedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private final class SiriFakeChatService: ClawlineSiriChatServicing {
    struct SendCall: Equatable {
        let id: String
        let content: String
        let attachmentCount: Int
        let sessionKey: String?
        let referenceCount: Int
    }

    var serviceEvents: AsyncStream<ChatServiceEvent> {
        eventSubscriptionCount += 1
        return AsyncStream { continuation = $0 }
    }

    private var continuation: AsyncStream<ChatServiceEvent>.Continuation?
    private let streams: [StreamSession]

    var connectCount = 0
    var disconnectCount = 0
    var eventSubscriptionCount = 0
    var fetchCount = 0
    var sendCalls: [SendCall] = []
    var eventsToEmitOnSend: [ChatServiceEvent] = []
    var suspendsFetch = false
    var fetchContinuation: CheckedContinuation<Void, Never>?

    init(streams: [StreamSession]) {
        self.streams = streams
    }

    func connect(token: String, lastMessageId: String?) async throws {
        connectCount += 1
    }

    func disconnect() {
        disconnectCount += 1
    }

    func fetchStreams() async throws -> [StreamSession] {
        fetchCount += 1
        if suspendsFetch {
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
            }
        }
        return streams
    }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?,
        references: [MessageReferenceContext]
    ) async throws {
        sendCalls.append(.init(
            id: id,
            content: content,
            attachmentCount: attachments.count,
            sessionKey: sessionKey,
            referenceCount: references.count
        ))
        for event in eventsToEmitOnSend {
            continuation?.yield(event)
        }
    }
}

private func siriStream(_ key: String, name: String) -> StreamSession {
    StreamSession(
        sessionKey: key,
        displayName: name,
        kind: "custom",
        orderIndex: 0,
        isBuiltIn: false,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
}
