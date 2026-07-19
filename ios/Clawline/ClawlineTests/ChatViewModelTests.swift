import Foundation
import Observation
import UIKit
import Testing
@testable import Clawline

private let personalSessionKey = SessionKey.clawlineMain(userId: "user")
private let adminSessionKey = SessionKey.admin

@MainActor
private final class HapticCounter {
    var count = 0
}

@MainActor
private final class ObservationFlag {
    var value = false
}

@Suite(.serialized)
struct ChatViewModelTests {
    @Test("T1673 Personal footer status follows the concrete runtime session")
    @MainActor
    func personalFooterStatusFollowsConcreteRuntimeSession() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let runtimeSessionKey = "agent:main:clawline:user:s_runtime"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.sessionStatusBySessionKey[runtimeSessionKey] = makeSessionStatus(
            sessionKey: runtimeSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.6-sol",
            thinkingLevel: "high",
            authMode: "oauth",
            fastMode: true,
            queueDepth: 0
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.t1673.personalConcreteAuthority")
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Prove runtime authority")
        #expect(viewModel.send())

        for _ in 0..<50 {
            if chatService.lastSentId != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let clientMessageID = try #require(chatService.lastSentId)
        chatService.resetFetchedSessionStatusKeys()
        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: runtimeSessionKey,
                    runId: "run_t1673",
                    messageId: clientMessageID,
                    seq: 1,
                    state: "running",
                    summary: "Working"
                )
            )
        )

        for _ in 0..<100 {
            if viewModel.sessionStatus(for: personalSessionKey)?.sessionKey == runtimeSessionKey { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(chatService.fetchedSessionStatusKeys.contains(runtimeSessionKey))
        #expect(!chatService.fetchedSessionStatusKeys.contains(personalSessionKey))
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.sessionKey == runtimeSessionKey)
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.display.model == "gpt-5.6-sol")

        let fetchCountAfterBinding = chatService.fetchSessionStatusCallCount
        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: runtimeSessionKey,
                    runId: "run_t1673",
                    messageId: clientMessageID,
                    seq: 2,
                    state: "running",
                    summary: "Still working"
                )
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(chatService.fetchSessionStatusCallCount == fetchCountAfterBinding)

        viewModel.applySessionControl(
            sessionKey: personalSessionKey,
            action: .setFastMode,
            enabled: true
        )
        for _ in 0..<50 {
            if chatService.lastSessionControl?.sessionKey == runtimeSessionKey { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chatService.lastSessionControl?.sessionKey == runtimeSessionKey)

        chatService.emitServiceEvent(.messageAcked(id: clientMessageID))
        let newerRuntimeSessionKey = "agent:main:clawline:user:s_newer"
        chatService.sessionStatusBySessionKey[newerRuntimeSessionKey] = makeSessionStatus(
            sessionKey: newerRuntimeSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.7",
            thinkingLevel: "medium",
            authMode: "oauth",
            fastMode: false,
            queueDepth: 0
        )
        viewModel.inputContent = NSAttributedString(string: "Use the newer runtime")
        #expect(viewModel.send())
        for _ in 0..<50 {
            if chatService.lastSentId != clientMessageID { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let newerClientMessageID = try #require(chatService.lastSentId)
        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: newerRuntimeSessionKey,
                    runId: "run_t1673_newer",
                    messageId: newerClientMessageID,
                    seq: 1,
                    state: "running",
                    summary: "Working"
                )
            )
        )
        for _ in 0..<100 {
            if viewModel.sessionStatus(for: personalSessionKey)?.sessionKey == newerRuntimeSessionKey { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: runtimeSessionKey,
                    runId: "run_t1673",
                    messageId: clientMessageID,
                    seq: 2,
                    state: "completed"
                )
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.sessionKey == newerRuntimeSessionKey)
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.display.model == "gpt-5.7")
    }

    @Test("T307 cross-chat mention sends to destination only")
    @MainActor
    func crossChatMentionSendRoutesToDestinationOnly() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let destinationSessionKey = "agent:main:clawline:user:s_destination"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: destinationSessionKey, displayName: "Side", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "medium",
            queueDepth: 0
        )
        chatService.sessionStatusBySessionKey[destinationSessionKey] = makeSessionStatus(
            sessionKey: destinationSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "medium",
            queueDepth: 1
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.t105.serverEchoCanonicalSession")
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        chatService.resetFetchedSessionStatusKeys()
        viewModel.inputContent = NSAttributedString(string: "route this")

        let dispatched = viewModel.sendCrossChatMention(to: destinationSessionKey)

        #expect(dispatched)
        for _ in 0..<50 {
            if chatService.lastSessionKey == destinationSessionKey { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chatService.lastSessionKey == destinationSessionKey)
        #expect(chatService.lastSentContent == "route this")
        #expect(viewModel.messages.isEmpty)
        #expect(!chatService.fetchedSessionStatusKeys.contains(destinationSessionKey))
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.run.state != .running)
    }

    @Test("T307 cross-chat mention sends only content after chip")
    @MainActor
    func crossChatMentionSendUsesOnlyContentAfterChip() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let destinationSessionKey = "agent:main:clawline:user:s_destination"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: destinationSessionKey, displayName: "Side", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.crossChatMentionSendUsesOnlyContentAfterChip")
        await viewModel.activate(origin: "test.t105.retryAppendsNewClientIdAtTail")
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        let content = NSMutableAttributedString(string: "do not route ")
        content.append(
            NSAttributedString(
                attachment: CrossChatMentionTextAttachment(
                    destinationChatId: destinationSessionKey,
                    displayName: "Side"
                )
            )
        )
        content.append(NSAttributedString(string: " route this"))
        viewModel.inputContent = content

        let dispatched = viewModel.sendCrossChatMention(to: destinationSessionKey)

        #expect(dispatched)
        for _ in 0..<50 {
            if chatService.lastSessionKey == destinationSessionKey { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chatService.lastSessionKey == destinationSessionKey)
        #expect(chatService.lastSentContent == "route this")
        #expect(viewModel.messages.isEmpty)
    }

    @Test("T307 queued cross-chat mention clears composer to prevent current-chat leak")
    @MainActor
    func queuedCrossChatMentionClearsComposerToPreventCurrentChatLeak() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let destinationSessionKey = "agent:main:clawline:user:s_waiting"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: destinationSessionKey, displayName: "Waiting", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        try await Task.sleep(for: .milliseconds(20))
        viewModel.inputContent = NSAttributedString(string: "queue this")

        let dispatched = viewModel.sendCrossChatMention(to: destinationSessionKey)
        viewModel.send()
        try await Task.sleep(for: .milliseconds(20))

        #expect(dispatched)
        #expect(viewModel.inputContent.string.isEmpty)
        #expect(chatService.lastSentContent == nil)
        #expect(viewModel.messages.isEmpty)
    }

    @Test("T307/V307-28 navigation dismisses target notification and preserves unrelated content")
    @MainActor
    func notificationNavigationDismissesTargetNotificationAndPreservesUnrelatedContent() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceSessionKey = "agent:main:clawline:user:s_source"
        let otherSessionKey = "agent:main:clawline:user:s_other"
        let overflowSessionKeys = (0..<12).map { "agent:main:clawline:user:s_overflow_\($0)" }
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: sourceSessionKey, displayName: "Source", kind: "custom", orderIndex: 1, isBuiltIn: false),
            makeStreamSession(sessionKey: otherSessionKey, displayName: "Other", kind: "custom", orderIndex: 2, isBuiltIn: false),
        ] + overflowSessionKeys.enumerated().map { index, sessionKey in
            makeStreamSession(
                sessionKey: sessionKey,
                displayName: "Overflow \(index)",
                kind: "custom",
                orderIndex: index + 3,
                isBuiltIn: false
            )
        }
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.notificationNavigationDismissesTargetNotificationAndPreservesUnrelatedContent")
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setConnected(chatService: chatService, viewModel: viewModel)
        for _ in 0..<50 {
            if viewModel.stream(for: sourceSessionKey) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(viewModel.stream(for: sourceSessionKey))

        let userPayload = #"{"type":"message","id":"u_other","role":"user","content":"user echo","timestamp":9000,"streaming":false,"sessionKey":"\#(sourceSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(userPayload.utf8))))
        let firstPayload = #"{"type":"message","id":"s_first","role":"assistant","content":"older","timestamp":10000,"streaming":false,"sessionKey":"\#(sourceSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(firstPayload.utf8))))
        let secondPayload = #"{"type":"message","id":"s_second","role":"assistant","content":"newer","timestamp":11000,"streaming":false,"sessionKey":"\#(sourceSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(secondPayload.utf8))))
        let otherPayload = #"{"type":"message","id":"s_other_notification","role":"assistant","content":"unrelated","timestamp":12000,"streaming":false,"sessionKey":"\#(otherSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(otherPayload.utf8))))
        for (index, sessionKey) in overflowSessionKeys.enumerated() {
            let payload = #"{"type":"message","id":"s_overflow_\#(index)","role":"assistant","content":"overflow \#(index)","timestamp":\#(13000 + index),"streaming":false,"sessionKey":"\#(sessionKey)","attachments":[]}"#
            chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))
        }

        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubbles.count == 2 + overflowSessionKeys.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubbles.count == 2 + overflowSessionKeys.count)
        let sourceBubble = try #require(
            viewModel.crossChatNotificationBubbles.first { $0.sourceChatId == sourceSessionKey }
        )
        #expect(sourceBubble.entries.map(\.content) == ["newer", "older"])
        #expect(sourceBubble.entries.map(\.appendSeparatorTimestamp) == [
            Date(timeIntervalSince1970: 11),
            nil
        ])
        let unrelatedBubble = try #require(
            viewModel.crossChatNotificationBubbles.first { $0.sourceChatId == otherSessionKey }
        )
        #expect(unrelatedBubble.entries.map(\.content) == ["unrelated"])

        viewModel.requestStreamSwitch(
            to: sourceSessionKey,
            source: .programmatic
        )
        #expect(viewModel.uiSelectedSessionKey == sourceSessionKey)
        #expect(!viewModel.crossChatNotificationBubbles.map(\.sourceChatId).contains(sourceSessionKey))
        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId).contains(otherSessionKey))
        #expect(Set(viewModel.crossChatNotificationBubbles.map(\.sourceChatId)).isSuperset(of: Set(overflowSessionKeys)))
        #expect(viewModel.crossChatNotificationBubbles.first { $0.sourceChatId == otherSessionKey }?.entries.map(\.content) == ["unrelated"])
    }

    @Test("T307 assistant notifications dismiss when source disappears from stream snapshot")
    @MainActor
    func assistantNotificationsDismissWhenSourceDisappearsFromStreamSnapshot() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceSessionKey = "agent:main:clawline:user:s_removed"
        let personalStream = makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true)
        let sourceStream = makeStreamSession(sessionKey: sourceSessionKey, displayName: "Source", kind: "custom", orderIndex: 1, isBuiltIn: false)
        let chatService = TestChatService()
        chatService.streams = [personalStream, sourceStream]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot([personalStream, sourceStream]))
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emit(
            Message(
                id: "s_removed",
                role: .assistant,
                content: "removed source",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceSessionKey
            )
        )
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        chatService.emitServiceEvent(.streamSnapshot([personalStream]))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] == nil)

        chatService.emit(
            Message(
                id: "s_removed_late",
                role: .assistant,
                content: "late removed source",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceSessionKey
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] == nil)
    }

    @Test("T1355 popup interaction defers notification additions and removals until dismissal")
    @MainActor
    func popupInteractionDefersNotificationAdditionsAndRemovalsUntilDismissal() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceA = "agent:main:clawline:user:s_popup_a"
        let sourceB = "agent:main:clawline:user:s_popup_b"
        let sourceC = "agent:main:clawline:user:s_popup_c"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: sourceA, displayName: "Popup A", kind: "custom", orderIndex: 1, isBuiltIn: false, trackingMode: .adopted),
            makeStreamSession(sessionKey: sourceB, displayName: "Popup B", kind: "custom", orderIndex: 2, isBuiltIn: false, trackingMode: .adopted),
            makeStreamSession(sessionKey: sourceC, displayName: "Popup C", kind: "custom", orderIndex: 3, isBuiltIn: false, trackingMode: .adopted)
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.t1355.popupInteraction")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setConnected(chatService: chatService, viewModel: viewModel)
        try emitServerMessage(
            Message(
                id: "s_popup_a_1",
                role: .assistant,
                content: "first visible notification",
                timestamp: Date(timeIntervalSince1970: 20),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceA
            ),
            via: chatService
        )
        try emitServerMessage(
            Message(
                id: "s_popup_b_1",
                role: .assistant,
                content: "interacted notification",
                timestamp: Date(timeIntervalSince1970: 10),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceB
            ),
            via: chatService
        )
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubbles.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceA, sourceB])

        viewModel.beginCrossChatNotificationPopupInteraction(sourceChatId: sourceB)
        try emitServerMessage(
            Message(
                id: "s_popup_c_1",
                role: .assistant,
                content: "newer queued notification",
                timestamp: Date(timeIntervalSince1970: 30),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceC
            ),
            via: chatService
        )
        viewModel.dismissCrossChatNotification(sourceChatId: sourceA)
        try await Task.sleep(for: .milliseconds(20))

        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceA, sourceB])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceB]?.entries.map(\.content) == ["interacted notification"])

        viewModel.endCrossChatNotificationPopupInteraction(sourceChatId: sourceB)
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceC, sourceB] { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceC, sourceB])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceC]?.entries.map(\.content) == ["newer queued notification"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceB]?.entries.map(\.content) == ["interacted notification"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceA] == nil)
    }

    @Test("T1355 T1213 batch commit waits for popup dismissal before consuming epoch")
    @MainActor
    func popupInteractionDefersReplayBatchCommitUntilDismissal() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceA = "agent:main:clawline:user:s_popup_batch_a"
        let sourceB = "agent:main:clawline:user:s_popup_batch_b"
        let sourceC = "agent:main:clawline:user:s_popup_batch_c"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: sourceA, displayName: "Popup Batch A", kind: "custom", orderIndex: 1, isBuiltIn: false, trackingMode: .adopted),
            makeStreamSession(sessionKey: sourceB, displayName: "Popup Batch B", kind: "custom", orderIndex: 2, isBuiltIn: false, trackingMode: .adopted),
            makeStreamSession(sessionKey: sourceC, displayName: "Popup Batch C", kind: "custom", orderIndex: 3, isBuiltIn: false, trackingMode: .adopted)
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.t1355.popupReplayBatch")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: sourceA) != nil,
               viewModel.stream(for: sourceB) != nil,
               viewModel.stream(for: sourceC) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        try emitServerMessage(
            Message(
                id: "s_popup_batch_a_1",
                role: .assistant,
                content: "dismissed while frozen",
                timestamp: Date(timeIntervalSince1970: 20),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceA
            ),
            via: chatService
        )
        try emitServerMessage(
            Message(
                id: "s_popup_batch_b_1",
                role: .assistant,
                content: "interacted notification",
                timestamp: Date(timeIntervalSince1970: 10),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceB
            ),
            via: chatService
        )
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubbles.count == 2 { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceA, sourceB])

        viewModel.beginCrossChatNotificationPopupInteraction(sourceChatId: sourceB)
        let replayEpoch = try #require(chatService.lastStartedEpoch)
        try emitServerMessage(
            Message(
                id: "s_popup_batch_c_1",
                role: .assistant,
                content: "replayed while popup open",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceC
            ),
            via: chatService,
            epoch: replayEpoch
        )
        chatService.emitLifecycleEvent(.init(epoch: replayEpoch, payload: .syncComplete))
        viewModel.dismissCrossChatNotification(sourceChatId: sourceA)
        try await Task.sleep(forDuration: .milliseconds(40))

        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceA, sourceB])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceC] == nil)

        viewModel.endCrossChatNotificationPopupInteraction(sourceChatId: sourceB)
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceC, sourceB] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceC, sourceB])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceC]?.entries.map(\.content) == ["replayed while popup open"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceB]?.entries.map(\.content) == ["interacted notification"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceA] == nil)
    }

    @Test("T307 dismissing notification clears source unread dot through read-state")
    @MainActor
    func dismissingNotificationClearsSourceUnreadDot() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceSessionKey = "agent:main:clawline:user:s_read_notification"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: sourceSessionKey, displayName: "Source", kind: "custom", orderIndex: 1, isBuiltIn: false)
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emitServiceEvent(.streamReadStateUpdated(sessionKey: sourceSessionKey, lastReadMessageId: "s_old_read"))
        chatService.emit(
            Message(
                id: "s_notification_unread",
                role: .assistant,
                content: "unread source notification",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceSessionKey
            )
        )

        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] != nil,
               viewModel.streamDotState(for: sourceSessionKey) == .unread {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.streamDotState(for: sourceSessionKey) == .unread)

        chatService.lastPublishedReadState = nil
        viewModel.dismissCrossChatNotification(sourceChatId: sourceSessionKey)
        for _ in 0..<50 {
            if chatService.lastPublishedReadState?.lastReadMessageId == "s_notification_unread" { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] == nil)
        #expect(chatService.lastPublishedReadState?.sessionKey == sourceSessionKey)
        #expect(chatService.lastPublishedReadState?.lastReadMessageId == "s_notification_unread")
        #expect(viewModel.lastReadMessageIdBySession[sourceSessionKey] == "s_notification_unread")
        #expect(viewModel.streamDotState(for: sourceSessionKey) == .inactive)
    }

    @Test("T307 overflowing notification preserves active reply draft")
    @MainActor
    func overflowingNotificationClosesReplyDraft() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let streams = [makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true)]
            + (0..<11).map { index in
                makeStreamSession(
                    sessionKey: "agent:main:clawline:user:s_overflow_\(index)",
                    displayName: "Overflow \(index)",
                    kind: "custom",
                    orderIndex: index + 1,
                    isBuiltIn: false
                )
            }
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setConnected(chatService: chatService, viewModel: viewModel)

        for index in 0..<10 {
            chatService.emit(
                Message(
                    id: "s_overflow_\(index)",
                    role: .assistant,
                    content: "message \(index)",
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    streaming: false,
                    attachments: [],
                    deviceId: nil,
                    sessionKey: "agent:main:clawline:user:s_overflow_\(index)"
                )
            )
        }
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubbles.count == 10 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let oldestVisible = "agent:main:clawline:user:s_overflow_0"
        viewModel.openCrossChatNotificationReply(sourceChatId: oldestVisible)
        viewModel.setCrossChatNotificationReplyDraft(sourceChatId: oldestVisible, draft: "draft")
        viewModel.closeOverflowingCrossChatNotificationReplies(visibleSourceChatIds: [oldestVisible])
        let replyingBubble = try #require(viewModel.crossChatNotificationBubblesBySourceChatId[oldestVisible])
        #expect(replyingBubble.isReplying)
        #expect(replyingBubble.replyDraft == "draft")

        chatService.emit(
            Message(
                id: "s_overflow_10",
                role: .assistant,
                content: "message 10",
                timestamp: Date(timeIntervalSince1970: 10),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: "agent:main:clawline:user:s_overflow_10"
            )
        )

        for _ in 0..<50 {
            let bubble = viewModel.crossChatNotificationBubblesBySourceChatId[oldestVisible]
            if bubble?.isReplying == true, bubble?.replyDraft == "draft" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let overflowed = try #require(viewModel.crossChatNotificationBubblesBySourceChatId[oldestVisible])
        #expect(overflowed.isReplying)
        #expect(overflowed.replyDraft == "draft")
    }

    @Test("T307 notification reply locks duplicate taps and dismisses after accepted send")
    @MainActor
    func notificationReplyClosesOnlyAfterSuccessfulSend() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceSessionKey = "agent:main:clawline:user:s_reply"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: sourceSessionKey, displayName: "Source", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "medium",
            queueDepth: 0
        )
        chatService.sessionStatusBySessionKey[sourceSessionKey] = makeSessionStatus(
            sessionKey: sourceSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "medium",
            queueDepth: 1
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.notificationReplyClosesOnlyAfterSuccessfulSend")
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        let assistantPayload = #"{"type":"message","id":"s_reply","role":"assistant","content":"reply target","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(sourceSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(assistantPayload.utf8))))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey])

        viewModel.openCrossChatNotificationReply(sourceChatId: sourceSessionKey)
        viewModel.setCrossChatNotificationReplyDraft(sourceChatId: sourceSessionKey, draft: "reply draft")
        chatService.resetFetchedSessionStatusKeys()
        chatService.emitServiceEvent(.sessionProvisioningAvailable(false))
        for _ in 0..<50 {
            if viewModel.canImmediatelySendCrossChatNotificationReply(sourceChatId: sourceSessionKey) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.connectionState == .connected)
        #expect(viewModel.stream(for: sourceSessionKey) != nil)
        #expect(viewModel.isSendingCrossChatNotificationReply(sourceChatId: sourceSessionKey) == false)
        #expect(viewModel.canImmediatelySendCrossChatNotificationReply(sourceChatId: sourceSessionKey))
        chatService.sendDelay = .milliseconds(300)
        viewModel.sendCrossChatNotificationReply(sourceChatId: sourceSessionKey)
        for _ in 0..<50 {
            if chatService.lastSentId != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let replyMessageId = try #require(chatService.lastSentId)
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] != nil)
        #expect(viewModel.isSendingCrossChatNotificationReply(sourceChatId: sourceSessionKey))
        #expect(viewModel.canImmediatelySendCrossChatNotificationReply(sourceChatId: sourceSessionKey) == false)
        viewModel.sendCrossChatNotificationReply(sourceChatId: sourceSessionKey)
        try await Task.sleep(for: .milliseconds(40))
        #expect(chatService.sentIds == [replyMessageId])

        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] == nil)
        #expect(viewModel.isSendingCrossChatNotificationReply(sourceChatId: sourceSessionKey) == false)
        viewModel.sendCrossChatNotificationReply(sourceChatId: sourceSessionKey)
        try await Task.sleep(for: .milliseconds(20))
        #expect(chatService.sentIds == [replyMessageId])

        for _ in 0..<50 {
            if !viewModel.isSendingCrossChatNotificationReply(sourceChatId: sourceSessionKey) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chatService.lastSentContent == "reply draft")
        #expect(chatService.lastSessionKey == sourceSessionKey)
        chatService.emitServiceEvent(.messageAcked(id: replyMessageId))
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: sourceSessionKey)?.run.state == .running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chatService.fetchedSessionStatusKeys.contains(sourceSessionKey))
        #expect(viewModel.sessionStatus(for: sourceSessionKey)?.run.state == .running)
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.run.state != .running)
    }

    @Test("T307 notification reply action toggles reply mode without dismissing")
    @MainActor
    func notificationReplyActionTogglesReplyMode() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceSessionKey = "agent:main:clawline:user:s_toggle"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: sourceSessionKey, displayName: "Source", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(streams))
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emit(
            Message(
                id: "s_toggle",
                role: .assistant,
                content: "toggle target",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sourceSessionKey
            )
        )
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.toggleCrossChatNotificationReply(sourceChatId: sourceSessionKey)
        viewModel.setCrossChatNotificationReplyDraft(sourceChatId: sourceSessionKey, draft: "discard me")
        var bubble = try #require(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey])
        #expect(bubble.isReplying)
        #expect(bubble.replyDraft == "discard me")

        viewModel.toggleCrossChatNotificationReply(sourceChatId: sourceSessionKey)
        bubble = try #require(viewModel.crossChatNotificationBubblesBySourceChatId[sourceSessionKey])
        #expect(bubble.isReplying == false)
        #expect(bubble.replyDraft.isEmpty)
    }

    @Test("Records last server message id for reconnects")
    @MainActor
    func recordsLastServerMessageId() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        // Ensure the async streams are initialized so emitted values are buffered if observation
        // tasks haven't started iterating yet.
        _ = chatService.incomingMessages
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()

        chatService.emit(
            Message(
                id: "s_snapshot",
                role: .assistant,
                content: "Hello",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey,
                )
        )

        var snapshot: (token: String?, lastMessageId: String?) = (nil, nil)
        for _ in 0..<50 {
            snapshot = await MainActor.run { viewModel.debugConnectionSnapshot() }
            if snapshot.lastMessageId == "s_snapshot" { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(snapshot.lastMessageId == "s_snapshot")
    }

    @Test("Streaming updates replace existing message instead of duplicating")
    @MainActor
    func streamingMessagesUpdateInPlace() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        // Ensure the async streams are initialized so emitted values are buffered if observation
        // tasks haven't started iterating yet.
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()

        let sessionKey = personalSessionKey
        let messageId = "s_stream"
        chatService.emit(
            Message(
                id: messageId,
                role: .assistant,
                content: "Partial",
                timestamp: Date(),
                streaming: true,
                attachments: [],
                deviceId: nil,
                sessionKey: sessionKey,
                )
        )

        var firstCount = 0
        for _ in 0..<50 {
            firstCount = await MainActor.run { viewModel.messages.count }
            if firstCount == 1 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(firstCount == 1)

        chatService.emit(
            Message(
                id: messageId,
                role: .assistant,
                content: "Final",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: sessionKey,
                )
        )

        // The view model processes incoming messages on an async task; avoid a brittle fixed sleep.
        var finalState: [Message] = []
        for _ in 0..<50 {
            finalState = await MainActor.run { viewModel.messages }
            if finalState.count == 1,
               finalState.first?.content == "Final",
               finalState.first?.streaming == false {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(finalState.count == 1)
        #expect(finalState.first?.content == "Final")
        #expect(finalState.first?.streaming == false)
    }

    @Test("Live agent progress updates reducer state and clears on assistant final")
    @MainActor
    func liveAgentProgressUpdatesAndClears() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 2,
                    state: "running",
                    event: AgentProgressItem(
                        kind: "item",
                        phase: "start",
                        status: "running",
                        title: "Reading files",
                        name: nil,
                        summary: "Less specific summary",
                        progressText: "Reading files"
                    )
                )
            )
        )

        for _ in 0..<50 {
            if viewModel.liveProgressSummary(for: personalSessionKey) == "Reading files" { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Reading files")
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .toolActivity)

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 1,
                    state: "running",
                    summary: "Stale update"
                )
            )
        )
        try await Task.sleep(forDuration: .milliseconds(20))
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Reading files")

        chatService.emitServiceEvent(
            .promptTurnState(
                PromptTurnStateEvent(
                    type: "event",
                    event: "prompt_turn_state",
                    payload: .init(
                        messageId: "c_accepted",
                        sessionKey: personalSessionKey,
                        state: "accepted",
                        terminalState: nil,
                        correlationId: "corr_stage",
                        clawlineMessageRowId: nil,
                        error: nil
                    )
                )
            )
        )
        try await Task.sleep(forDuration: .milliseconds(20))
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .toolActivity)
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Reading files")

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 3,
                    state: "running",
                    event: AgentProgressItem(
                        kind: "stage",
                        phase: "pre_model",
                        status: "running",
                        title: "Preparing prompt",
                        name: nil,
                        summary: nil,
                        progressText: nil
                    )
                )
            )
        )
        for _ in 0..<50 {
            if viewModel.liveProgress(for: personalSessionKey)?.stage == .preModel { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .preModel)
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Preparing prompt")

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 4,
                    state: "running",
                    event: AgentProgressItem(
                        kind: "model",
                        phase: "active",
                        status: "running",
                        title: "Generating response",
                        name: nil,
                        summary: nil,
                        progressText: nil
                    )
                )
            )
        )
        for _ in 0..<50 {
            if viewModel.liveProgress(for: personalSessionKey)?.stage == .modelActive { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .modelActive)
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Generating response")

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 5,
                    state: "running",
                    event: AgentProgressItem(
                        kind: "command-output",
                        phase: "start",
                        status: "running",
                        title: "Running command",
                        name: "exec",
                        summary: nil,
                        progressText: nil
                    )
                )
            )
        )
        for _ in 0..<50 {
            if viewModel.liveProgressSummary(for: personalSessionKey) == "Running command" { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .toolActivity)
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Running command")

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 6,
                    state: "running",
                    summary: "Unsupported generic progress"
                )
            )
        )
        try await Task.sleep(forDuration: .milliseconds(20))
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .toolActivity)
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Running command")

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 7,
                    state: "running",
                    event: AgentProgressItem(
                        kind: "stage",
                        phase: "completion_handoff",
                        status: "running",
                        title: "Finishing response",
                        name: nil,
                        summary: nil,
                        progressText: nil
                    )
                )
            )
        )
        for _ in 0..<50 {
            if viewModel.liveProgress(for: personalSessionKey)?.stage == .completionHandoff { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .completionHandoff)
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Finishing response")

        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: personalSessionKey,
                    runId: "run_1",
                    messageId: "c_1",
                    seq: 8,
                    state: "done"
                )
            )
        )
        for _ in 0..<50 {
            if viewModel.liveProgress(for: personalSessionKey) == nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.liveProgress(for: personalSessionKey) == nil)

        chatService.emit(
            Message(
                id: "s_final",
                role: .assistant,
                content: "Final",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey,
                replyToClientMessageId: "c_1"
            )
        )
        for _ in 0..<50 {
            if viewModel.liveProgress(for: personalSessionKey) == nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.liveProgress(for: personalSessionKey) == nil)
    }

    @Test("Prompt stage indicator is scoped to the selected stream")
    @MainActor
    func promptStageIndicatorIsScopedToSelectedStream() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        let otherSessionKey = "agent:main:clawline:user:s_other_progress"
        chatService.emitServiceEvent(
            .agentProgress(
                AgentProgressEvent(
                    version: 1,
                    sessionKey: otherSessionKey,
                    runId: "run_other",
                    messageId: "c_other",
                    seq: 1,
                    state: "running",
                    event: AgentProgressItem(
                        kind: "stage",
                        phase: "pre_model",
                        status: "running",
                        title: "Preparing prompt",
                        name: nil,
                        summary: nil,
                        progressText: nil
                    )
                )
            )
        )
        for _ in 0..<50 {
            if viewModel.shouldShowPromptStageIndicator(in: otherSessionKey) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.shouldShowPromptStageIndicator(in: otherSessionKey))
        #expect(!viewModel.shouldShowPromptStageIndicator(in: personalSessionKey))
        #expect(viewModel.liveProgress(for: personalSessionKey) == nil)
    }

    @Test("Lifecycle replay advances service-owned per-stream cursor after apply")
    @MainActor
    func lifecycleReplayAdvancesServiceReplayCursor() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.lifecycleReplayCursor")

        for _ in 0..<50 {
            if viewModel.debugObservationStartupCount() > 0, chatService.connectCallCount > 0 { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let payload = #"{"type":"message","id":"s_replay_final","role":"assistant","content":"Replay final","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(personalSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))

        var cursor: String?
        for _ in 0..<50 {
            cursor = chatService.replayCursorSnapshot()[personalSessionKey]
            if cursor == "s_replay_final" { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(cursor == "s_replay_final")
    }

    @Test("T1213 lifecycle replay commits notification snapshot only at terminal boundary")
    @MainActor
    func lifecycleReplayCommitsNotificationsOnlyAtTerminalBoundary() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let sourceA = "agent:main:clawline:user:s_replay_a"
        let sourceB = "agent:main:clawline:user:s_replay_b"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: sourceA, displayName: "Replay A", kind: "custom", orderIndex: 1, isBuiltIn: false),
            makeStreamSession(sessionKey: sourceB, displayName: "Replay B", kind: "custom", orderIndex: 2, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 3
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.replayBatch")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: sourceA) != nil, viewModel.stream(for: sourceB) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let first = #"{"type":"message","id":"s_replay_a_1","role":"assistant","content":"Replay A 1","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(sourceA)","attachments":[]}"#
        let second = #"{"type":"message","id":"s_replay_b_1","role":"assistant","content":"Replay B 1","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(sourceB)","attachments":[]}"#
        let third = #"{"type":"message","id":"s_replay_a_2","role":"assistant","content":"Replay A 2","timestamp":1700000000002,"streaming":false,"sessionKey":"\#(sourceA)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(first.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(second.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(third.utf8))))
        try await Task.sleep(forDuration: .milliseconds(50))

        #expect(viewModel.crossChatNotificationBubbles.isEmpty)
        #expect(viewModel.messages(for: sourceA).map(\.id) == ["s_replay_a_1", "s_replay_a_2"])
        #expect(viewModel.messages(for: sourceB).map(\.id) == ["s_replay_b_1"])

        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubbles.count == 2 { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubbles.map(\.sourceChatId) == [sourceA, sourceB])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceA]?.entries.map(\.content) == ["Replay A 2", "Replay A 1"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[sourceB]?.entries.map(\.content) == ["Replay B 1"])
    }

    @Test("T1751 stream_history_cleared drops the local store, cache, and replay cursor for the stream")
    @MainActor
    func streamHistoryClearedDropsLocalStore() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_history_clear"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Cleared", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1751.historyClear")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let message = #"{"type":"message","id":"s_history_1","role":"assistant","content":"Before clear","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(message.utf8))))
        for _ in 0..<50 {
            if !viewModel.messages(for: source).isEmpty { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.messages(for: source).map(\.id) == ["s_history_1"])

        // Seed a replay cursor so the drop is observable (the gateway's barrier
        // means replay must restart from scratch for this stream).
        chatService.setReplayCursor("s_history_1", for: source)
        #expect(chatService.replayCursorSnapshot()[source] == "s_history_1")

        chatService.emitServiceEvent(.streamHistoryCleared(sessionKey: source))
        for _ in 0..<50 {
            if viewModel.messages(for: source).isEmpty { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.messages(for: source).isEmpty)
        #expect(chatService.replayCursorSnapshot()[source] == nil)
    }

    @Test("R1 regression: history clear discards an in-flight cache restore instead of resurrecting pre-barrier history")
    @MainActor
    func streamHistoryClearedDiscardsInFlightRestore() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_restore_race"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Race", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.r1.restoreRace")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        // Plant a pre-barrier cache file on disk, exactly where the app's
        // persist pipeline writes it. A large payload keeps the restore's
        // decode in flight long enough for the barrier to land first; even if
        // timing collapses, the post-fix assertions still hold (the barrier
        // ordering deletes the file before a later restore can read it).
        let cacheDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clawline", isDirectory: true)
            .appendingPathComponent("MessageCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cacheURL = cacheDirectory.appendingPathComponent(
            source.replacingOccurrences(of: ":", with: "-").appending(".json")
        )
        let preBarrier = (0..<500).map { index in
            Message(
                id: "s_pre_barrier_\(index)",
                role: .assistant,
                content: "Pre-barrier message \(index) that must never come back after the clear.",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: source
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(preBarrier).write(to: cacheURL, options: [.atomic])

        // Begin a forced restore (detached disk read + decode), then land the
        // barrier while it is in flight.
        viewModel.setShowOnlyUserMessagesMode(true, for: source)
        chatService.emitServiceEvent(.streamHistoryCleared(sessionKey: source))

        try await Task.sleep(forDuration: .milliseconds(800))
        #expect(viewModel.messages(for: source).isEmpty)
        #expect(chatService.replayCursorSnapshot()[source] == nil)
    }

    @Test("R1 regression: a pending debounced persist does not recreate the message cache after a history clear")
    @MainActor
    func streamHistoryClearedOutlivesPendingPersist() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_persist_race"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Persist Race", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.r1.persistRace")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        // Deliver a message (arms the 500ms persist debounce), then clear the
        // history before the debounce can flush.
        let message = #"{"type":"message","id":"s_persist_1","role":"assistant","content":"Doomed","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(message.utf8))))
        for _ in 0..<50 {
            if !viewModel.messages(for: source).isEmpty { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        chatService.emitServiceEvent(.streamHistoryCleared(sessionKey: source))

        // Wait past the debounce window plus the serialized IO queue drain: no
        // write may recreate the cache file after the barrier's delete.
        try await Task.sleep(forDuration: .milliseconds(900))
        let cacheURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clawline", isDirectory: true)
            .appendingPathComponent("MessageCache", isDirectory: true)
            .appendingPathComponent(source.replacingOccurrences(of: ":", with: "-").appending(".json"))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
        #expect(viewModel.messages(for: source).isEmpty)
        #expect(chatService.replayCursorSnapshot()[source] == nil)
    }

    @Test("R2 regression: provenance presentation (the sizing source) is built from the stripped body on tightbeam")
    @MainActor
    func provenancePresentationBuildsFromStrippedBody() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.r2.strippedPresentation")
        // Production invariant: the service property and the event always
        // carry the same value (the property is set before the event fires).
        chatService.serverFeatures = ["tightbeam"]
        chatService.emitServiceEvent(.serverFeatures(["tightbeam"]))
        for _ in 0..<50 {
            if viewModel.isTightbeamServer { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.isTightbeamServer)

        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        func markdownText(_ presentation: MessagePresentation) -> String {
            presentation.parts.compactMap { part -> String? in
                if case let .markdown(text) = part { return text }
                return nil
            }.joined(separator: "\n")
        }

        // A stamped wake message presents from the stripped body: the stamp
        // line contributes nothing to what sizing measures.
        let stamped = Message(
            id: "m_provenance_stamped",
            role: .user,
            content: "[from user:mike]\nshort body",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey,
            sender: "user:mike"
        )
        let stampedText = markdownText(viewModel.presentation(for: stamped, metrics: metrics))
        #expect(stampedText.contains("[from user:mike]") == false)
        #expect(stampedText.contains("short body"))

        // Anti-forgery: a first line that fails the sender cross-check stays
        // in the measured/rendered body verbatim.
        let forged = Message(
            id: "m_provenance_forged",
            role: .user,
            content: "[from agent:notetaker]\nshort body",
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey,
            sender: "user:mike"
        )
        let forgedText = markdownText(viewModel.presentation(for: forged, metrics: metrics))
        #expect(forgedText.contains("[from agent:notetaker]"))

        // A device-typed message (no sender) keeps a literal stamp-shaped
        // first line even on tightbeam.
        let typed = Message(
            id: "m_provenance_typed",
            role: .user,
            content: "[from user:mike]\ntyped literal",
            timestamp: Date(timeIntervalSince1970: 1_700_000_002),
            streaming: false,
            attachments: [],
            deviceId: "device-1",
            sessionKey: personalSessionKey
        )
        let typedText = markdownText(viewModel.presentation(for: typed, metrics: metrics))
        #expect(typedText.contains("[from user:mike]"))
    }

    @Test("R3 regression: a placement-carrying create reaches the service verbatim — no silent drop")
    @MainActor
    func placementCreateReachesServiceVerbatim() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.r3.placement")
        let outcome = await viewModel.createStream(
            displayName: "Placed",
            harness: "claude",
            model: "sonnet",
            host: "eezo",
            archetype: "default"
        )
        if case .failed(let message) = outcome {
            Issue.record("placement create unexpectedly failed: \(message)")
        }
        let placement = try #require(chatService.lastCreatePlacement)
        #expect(placement.harness == "claude")
        #expect(placement.model == "sonnet")
        #expect(placement.host == "eezo")
        #expect(placement.archetype == "default")
    }

    @Test("Gate regression: tightbeam gate converges from the service's pulled features even when the serverFeatures event is never observed")
    @MainActor
    func tightbeamGateConvergesFromPulledFeatures() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        // The authed link already carries the feature set (as after an auth
        // that completed before the view model subscribed to serviceEvents);
        // no .serverFeatures event is ever emitted in this scenario.
        chatService.serverFeatures = ["tightbeam"]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.gate.pulledFeatures")
        #expect(viewModel.isTightbeamServer == false)

        chatService.emitConnectionState(.connected)
        for _ in 0..<50 {
            if viewModel.isTightbeamServer { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.isTightbeamServer)
    }

    @Test("Read replayed assistant content does not resurrect cross-chat notification")
    @MainActor
    func readReplayedAssistantContentDoesNotResurrectCrossChatNotification() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_read_boundary"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Read", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 2
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.readReplayNoResurrect")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        chatService.emitServiceEvent(.streamReadStateUpdated(sessionKey: source, lastReadMessageId: "s_replay_read_2"))
        chatService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: source,
                tailState: StreamTailState(lastMessageId: "s_replay_read_2", lastMessageRole: .assistant)
            )
        )
        for _ in 0..<50 {
            if viewModel.lastReadMessageIdBySession[source] == "s_replay_read_2" { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let first = #"{"type":"message","id":"s_replay_read_1","role":"assistant","content":"Already read first","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        let second = #"{"type":"message","id":"s_replay_read_2","role":"assistant","content":"Already read second","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(first.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(second.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        try await Task.sleep(forDuration: .milliseconds(50))

        #expect(viewModel.messages(for: source).map(\.id) == ["s_replay_read_1", "s_replay_read_2"])
        #expect(viewModel.streamDotStateBySession[source] == .inactive)
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)
    }

    @Test("Dismissed replayed assistant content stays dismissed until newer assistant content")
    @MainActor
    func dismissedReplayedAssistantContentStaysDismissedUntilNewerAssistantContent() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_dismiss_boundary"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Dismiss", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let firstViewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )

        await firstViewModel.activate(origin: "test.dismissReplayBoundary.first")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        let dismissed = #"{"type":"message","id":"s_replay_dismissed","role":"assistant","content":"Dismissed before restart","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(dismissed.utf8))))
        for _ in 0..<50 {
            if firstViewModel.crossChatNotificationBubblesBySourceChatId[source] != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        firstViewModel.dismissCrossChatNotification(sourceChatId: source)
        for _ in 0..<50 {
            if firstViewModel.lastReadMessageIdBySession[source] == "s_replay_dismissed" { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(firstViewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)
        firstViewModel.prepareForReplacement()

        let replayService = TestChatService()
        replayService.streams = streams
        replayService.startReplayCount = 2
        replayService.emitSyncCompleteOnStart = false
        let secondViewModel = ChatViewModel(
            auth: auth,
            chatService: replayService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { secondViewModel.prepareForReplacement() }

        await secondViewModel.activate(origin: "test.dismissReplayBoundary.second")
        replayService.emitServiceEvent(.streamSnapshot(streams))
        replayService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: source,
                tailState: StreamTailState(lastMessageId: "s_replay_dismissed", lastMessageRole: .assistant)
            )
        )
        for _ in 0..<50 {
            if secondViewModel.lastReadMessageIdBySession[source] == "s_replay_dismissed" { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        replayService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(dismissed.utf8))))
        try await Task.sleep(forDuration: .milliseconds(30))
        #expect(secondViewModel.streamDotStateBySession[source] == .inactive)
        #expect(secondViewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)

        let newer = #"{"type":"message","id":"s_replay_newer","role":"assistant","content":"New after dismiss","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        replayService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(newer.utf8))))
        replayService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        replayService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: source,
                tailState: StreamTailState(lastMessageId: "s_replay_newer", lastMessageRole: .assistant)
            )
        )
        for _ in 0..<50 {
            if secondViewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["New after dismiss"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(secondViewModel.messages(for: source).map(\.id) == ["s_replay_dismissed", "s_replay_newer"])
        #expect(secondViewModel.streamDotStateBySession[source] == .unread)
        #expect(secondViewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["New after dismiss"])
    }

    @Test("T1171 same assistant message id can notify when content changes after dismissal")
    @MainActor
    func sameAssistantMessageIdCanNotifyWhenContentChangesAfterDismissal() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_t1171_changed_content"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Changed Content", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1171.changedContent")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let original = #"{"type":"message","id":"s_t1171_changed","role":"assistant","content":"Original content","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(original.utf8))))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Original content"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Original content"])

        viewModel.dismissCrossChatNotification(sourceChatId: source)
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)

        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(forDuration: .milliseconds(2100))
        viewModel.handleSceneActiveStateChanged(isActive: true)
        for _ in 0..<50 {
            if chatService.connectCallCount >= 2 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .serverMessage(data: Data(original.utf8))))
        try await Task.sleep(forDuration: .milliseconds(30))
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)

        let changed = #"{"type":"message","id":"s_t1171_changed","role":"assistant","content":"Changed content","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .serverMessage(data: Data(changed.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .syncComplete))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Changed content"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.id) == ["s_t1171_changed"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Changed content"])
    }

    @Test("T1213 replay failure discards pending notification snapshot")
    @MainActor
    func replayFailureDiscardsPendingNotifications() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_failed"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Failed", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 2
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.replayFailure")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        let payload = #"{"type":"message","id":"s_replay_failed_1","role":"assistant","content":"Pending only","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(40))
        #expect(viewModel.crossChatNotificationBubbles.isEmpty)

        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .transportClosed(reason: .error)))
        try await Task.sleep(forDuration: .milliseconds(40))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        try await Task.sleep(forDuration: .milliseconds(40))

        #expect(viewModel.crossChatNotificationBubbles.isEmpty)
    }

    @Test("T1213 pending source can notify when no longer current at terminal boundary")
    @MainActor
    func replayCommitAllowsSourceNoLongerCurrentAtTerminalBoundary() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_visible_then_hidden"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Source", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.commitEligibility")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        viewModel.requestStreamSwitch(to: source, source: .programmatic)
        #expect(viewModel.uiSelectedSessionKey == source)

        let payload = #"{"type":"message","id":"s_replay_terminal_current","role":"assistant","content":"Eligible at commit","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(40))
        #expect(viewModel.crossChatNotificationBubbles.isEmpty)

        viewModel.requestStreamSwitch(to: personalSessionKey, source: .programmatic)
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Eligible at commit"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Eligible at commit"])
    }

    @Test("T1213 commit suppresses pending source that is current at terminal boundary")
    @MainActor
    func replayCommitSuppressesSourceCurrentAtTerminalBoundary() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_hidden_then_visible"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Source", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.commitSuppressesCurrent")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let payload = #"{"type":"message","id":"s_replay_terminal_suppressed","role":"assistant","content":"Suppress at commit","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(40))
        #expect(viewModel.crossChatNotificationBubbles.isEmpty)

        viewModel.requestStreamSwitch(to: source, source: .programmatic)
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        try await Task.sleep(forDuration: .milliseconds(40))

        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)
    }

    @Test("T1213 navigation during pending replay does not drop terminal eligible notification")
    @MainActor
    func replayNavigationDuringPendingDoesNotDropTerminalEligibleNotification() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_pending_navigation"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Nav", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.pendingNavigation")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let payload = #"{"type":"message","id":"s_replay_pending_navigation","role":"assistant","content":"Survives navigation","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(40))
        #expect(viewModel.crossChatNotificationBubbles.isEmpty)

        viewModel.requestStreamSwitch(to: source, source: .programmatic)
        viewModel.requestStreamSwitch(to: personalSessionKey, source: .programmatic)
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Survives navigation"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Survives navigation"])
    }

    @Test("T1213 navigation into pending source suppresses stale replay notification")
    @MainActor
    func replayNavigationIntoPendingSourceSuppressesStaleNotification() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_navigation_into"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Nav In", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.navigationIntoPending")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let committedPayload = #"{"type":"message","id":"s_nav_into_committed","role":"assistant","content":"Committed before replay","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(committedPayload.utf8))))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before replay"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before replay"])

        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(forDuration: .milliseconds(2100))
        viewModel.handleSceneActiveStateChanged(isActive: true)
        for _ in 0..<50 {
            if chatService.connectCallCount >= 2 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let replayPayload = #"{"type":"message","id":"s_nav_into_replay","role":"assistant","content":"Buffered before navigation","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .serverMessage(data: Data(replayPayload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(30))
        viewModel.requestStreamSwitch(to: source, source: .programmatic)
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)

        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .syncComplete))
        try await Task.sleep(forDuration: .milliseconds(40))

        #expect(viewModel.messages(for: source).map(\.id).contains("s_nav_into_replay"))
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)
    }

    @Test("T1213 navigation dismissal during replay survives leaving source before commit")
    @MainActor
    func replayNavigationDismissalSurvivesLeavingSourceBeforeCommit() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_navigation_leave"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Nav Leave", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.navigationDismissalLeaveBeforeCommit")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let committedPayload = #"{"type":"message","id":"s_nav_leave_committed","role":"assistant","content":"Committed before replay","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(committedPayload.utf8))))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before replay"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before replay"])

        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(forDuration: .milliseconds(2100))
        viewModel.handleSceneActiveStateChanged(isActive: true)
        for _ in 0..<50 {
            if chatService.connectCallCount >= 2 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let replayPayload = #"{"type":"message","id":"s_nav_leave_replay","role":"assistant","content":"Buffered before navigation","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .serverMessage(data: Data(replayPayload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(30))
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before replay"])

        viewModel.requestStreamSwitch(to: source, source: .programmatic)
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)
        viewModel.requestStreamSwitch(to: personalSessionKey, source: .programmatic)

        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .syncComplete))
        try await Task.sleep(forDuration: .milliseconds(40))

        #expect(viewModel.messages(for: source).map(\.id).contains("s_nav_leave_replay"))
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)
    }

    @Test("T1213 replayed streaming partial does not commit as notification")
    @MainActor
    func replayedStreamingPartialDoesNotCommitNotification() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_partial"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Partial", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.streamingPartial")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let payload = #"{"type":"message","id":"s_replay_partial","role":"assistant","content":"Partial only","timestamp":1700000000000,"streaming":true,"sessionKey":"\#(source)","attachments":[],"replyToMessageId":"s_prompt"}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(40))
        #expect(viewModel.crossChatNotificationBubbles.isEmpty)

        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        try await Task.sleep(forDuration: .milliseconds(40))

        #expect(viewModel.messages(for: source).isEmpty)
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)
    }

    @Test("T1213 duplicate replay message updates one pending notification entry")
    @MainActor
    func duplicateReplayMessageUpdatesOnePendingNotificationEntry() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_replay_duplicate"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Replay Duplicate", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        chatService.startReplayCount = 2
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.duplicateReplay")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let first = #"{"type":"message","id":"s_replay_duplicate","role":"assistant","content":"First content","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        let second = #"{"type":"message","id":"s_replay_duplicate","role":"assistant","content":"Updated content","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(first.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(second.utf8))))
        try await Task.sleep(forDuration: .milliseconds(40))
        #expect(viewModel.crossChatNotificationBubbles.isEmpty)

        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Updated content"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.id) == ["s_replay_duplicate"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Updated content"])
    }

    @Test("T1213 coordinator waits for explicit truncation terminal boundary")
    func notificationCoordinatorWaitsForTruncationBoundary() {
        var coordinator = NotificationBatchCommitCoordinator()
        let source = "agent:main:clawline:user:s_truncation_unit"
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.begin(epoch: 9, waitsForTruncationBoundary: true)
        coordinator.collectPendingCandidate(
            NotificationBatchCommitCoordinator.Candidate(
                messageId: "s_truncation_unit",
                sourceChatId: source,
                role: .assistant,
                content: "Commit only after truncation",
                timestamp: timestamp,
                streaming: false,
                sourceTitle: "Truncation Unit",
                notificationSequence: nil
            ),
            epoch: 9
        )

        let completedOnly = coordinator.commitIfReady(
            epoch: 9,
            reachedTruncationBoundary: false,
            committedSnapshot: [:],
            isEligible: { _ in true }
        )
        #expect(completedOnly == nil)

        let truncated = coordinator.commitIfReady(
            epoch: 9,
            reachedTruncationBoundary: true,
            committedSnapshot: [:],
            isEligible: { _ in true }
        )
        #expect(truncated?[source]?.entries.map(\.content) == ["Commit only after truncation"])
    }

    @Test("T1213 coordinator scoped batch ignores unrelated sources")
    func notificationCoordinatorScopedBatchIgnoresUnrelatedSources() {
        var coordinator = NotificationBatchCommitCoordinator()
        let scoped = "agent:main:clawline:user:s_scoped"
        let unrelated = "agent:main:clawline:user:s_unrelated"
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.begin(epoch: 11, scope: [scoped], waitsForTruncationBoundary: false)
        #expect(coordinator.contains(epoch: 11, sourceChatId: scoped))
        #expect(!coordinator.contains(epoch: 11, sourceChatId: unrelated))

        coordinator.collectPendingCandidate(
            NotificationBatchCommitCoordinator.Candidate(
                messageId: "s_scoped",
                sourceChatId: scoped,
                role: .assistant,
                content: "Scoped",
                timestamp: timestamp,
                streaming: false,
                sourceTitle: "Scoped",
                notificationSequence: nil
            ),
            epoch: 11
        )
        coordinator.collectPendingCandidate(
            NotificationBatchCommitCoordinator.Candidate(
                messageId: "s_unrelated",
                sourceChatId: unrelated,
                role: .assistant,
                content: "Unrelated",
                timestamp: timestamp,
                streaming: false,
                sourceTitle: "Unrelated",
                notificationSequence: nil
            ),
            epoch: 11
        )

        let committed = coordinator.commitIfReady(
            epoch: 11,
            reachedTruncationBoundary: false,
            committedSnapshot: [:],
            isEligible: { _ in true }
        )
        #expect(committed?[scoped]?.entries.map(\.content) == ["Scoped"])
        #expect(committed?[unrelated] == nil)
    }

    @Test("T1213 history reset dismissal keeps only later replay notifications")
    @MainActor
    func historyResetDismissalKeepsOnlyLaterReplayNotifications() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let source = "agent:main:clawline:user:s_reset_notification_dismiss"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: source, displayName: "Reset Source", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let chatService = TestChatService()
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.t1213.historyResetDismissal")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.stream(for: source) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let committedPayload = #"{"type":"message","id":"s_reset_committed","role":"assistant","content":"Committed before reset","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(committedPayload.utf8))))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before reset"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before reset"])

        chatService.startHistoryReset = true
        chatService.startReplayCount = 2
        chatService.emitSyncCompleteOnStart = false
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(forDuration: .milliseconds(2100))
        viewModel.handleSceneActiveStateChanged(isActive: true)
        for _ in 0..<50 {
            if chatService.connectCallCount >= 2 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let dismissedReplayPayload = #"{"type":"message","id":"s_reset_replay_dismissed","role":"assistant","content":"Buffered before dismiss","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .serverMessage(data: Data(dismissedReplayPayload.utf8))))
        try await Task.sleep(forDuration: .milliseconds(30))
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Committed before reset"])

        viewModel.dismissCrossChatNotification(sourceChatId: source)
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source] == nil)

        let survivingReplayPayload = #"{"type":"message","id":"s_reset_replay_survives","role":"assistant","content":"Buffered after dismiss","timestamp":1700000000002,"streaming":false,"sessionKey":"\#(source)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .serverMessage(data: Data(survivingReplayPayload.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .syncComplete))
        for _ in 0..<50 {
            if viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Buffered after dismiss"] { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(viewModel.messages(for: source).map(\.id) == ["s_reset_replay_dismissed", "s_reset_replay_survives"])
        #expect(viewModel.crossChatNotificationBubblesBySourceChatId[source]?.entries.map(\.content) == ["Buffered after dismiss"])
    }

    @Test("History reset preserves cursor-backed active stream with empty replay window")
    @MainActor
    func historyResetPreservesCursorBackedActiveStreamWithEmptyReplayWindow() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_reset_side"
        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Side", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        chatService.streams = streams
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.historyResetPreservesCursorBackedActiveStream")
        chatService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if viewModel.activeSessionKey == personalSessionKey,
               viewModel.orderedSessionKeys.contains(customKey) {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let activePayload = #"{"type":"message","id":"s_active_before_sleep","role":"assistant","content":"Still here","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(personalSessionKey)","attachments":[]}"#
        let staleSidePayload = #"{"type":"message","id":"s_side_stale","role":"assistant","content":"Old side","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(customKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(activePayload.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(staleSidePayload.utf8))))
        for _ in 0..<50 {
            if viewModel.messages.contains(where: { $0.id == "s_active_before_sleep" }),
               chatService.replayCursorSnapshot()[personalSessionKey] == "s_active_before_sleep" {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.messages.map(\.id).contains("s_active_before_sleep"))
        #expect(chatService.replayCursorSnapshot()[personalSessionKey] == "s_active_before_sleep")
        chatService.setReplayCursor(nil, for: customKey)

        chatService.startHistoryReset = true
        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(forDuration: .milliseconds(2100))
        viewModel.handleSceneActiveStateChanged(isActive: true)

        for _ in 0..<50 {
            if chatService.connectCallCount >= 2 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        let replaySidePayload = #"{"type":"message","id":"s_side_replay","role":"assistant","content":"Side replay","timestamp":1700000000002,"streaming":false,"sessionKey":"\#(customKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .serverMessage(data: Data(replaySidePayload.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 2, payload: .syncComplete))

        for _ in 0..<50 {
            if viewModel.messages.map(\.id).contains("s_active_before_sleep"),
               viewModel.messages(for: customKey).map(\.id) == ["s_side_replay"] {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.activeSessionKey == personalSessionKey)
        #expect(viewModel.messages.map(\.id).contains("s_active_before_sleep"))
        #expect(viewModel.messages(for: customKey).map(\.id) == ["s_side_replay"])
        #expect(chatService.replayCursorSnapshot()[personalSessionKey] == nil)
        #expect(chatService.replayCursorSnapshot()[customKey] == "s_side_replay")
    }

    @Test("Cache restore seeds missing cursor without replacing a live cursor")
    @MainActor
    func cacheRestoreSeedsMissingCursorOnly() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        chatService.setReplayCursor("s_live_final", for: personalSessionKey)
        await viewModel.onAppear()

        for _ in 0..<50 {
            if chatService.replayCursorSnapshot()[personalSessionKey] == "s_live_final" { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        #expect(chatService.replayCursorSnapshot()[personalSessionKey] == "s_live_final")
    }

    @Test("Server echoes with matching device id replace placeholder")
    @MainActor
    func userEchoWithoutDeviceIdDoesNotDuplicate() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Hello!")
        viewModel.send()

        try await Task.sleep(forDuration: .milliseconds(10))
        let placeholderId = try #require(await MainActor.run { viewModel.messages.first?.id })
        #expect(placeholderId.hasPrefix("c_"))

        chatService.emit(
            Message(
                id: "s_user_echo",
                role: .user,
                content: "Hello!",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: "device",
                sessionKey: personalSessionKey,
                clientMessageId: placeholderId
            )
        )

        try await Task.sleep(forDuration: .milliseconds(10))
        let messages = await MainActor.run { viewModel.messages }
        #expect(messages.count == 1)
        #expect(messages.first?.id == "s_user_echo")
    }

    @Test("T105: server echo can canonicalize pending placeholder session")
    @MainActor
    func serverEchoCanonicalSessionMovesPendingPlaceholderThroughSeam() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let canonicalSessionKey = "agent:main:clawline:user:s_canonical"
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: canonicalSessionKey, displayName: "Canonical", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.setActiveSessionKeyForTesting(personalSessionKey)
        viewModel.inputContent = NSAttributedString(string: "Canonicalize me")
        viewModel.send()
        try await Task.sleep(forDuration: .milliseconds(10))

        let placeholderId = try #require(viewModel.messages(for: personalSessionKey).first?.id)
        #expect(placeholderId.hasPrefix("c_"))

        chatService.emit(
            Message(
                id: "s_user_canonical",
                role: .user,
                content: "Canonicalize me",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: "device",
                sessionKey: canonicalSessionKey,
                clientMessageId: placeholderId
            )
        )
        try await Task.sleep(forDuration: .milliseconds(10))

        #expect(viewModel.messages(for: personalSessionKey).isEmpty)
        #expect(viewModel.messages(for: canonicalSessionKey).map(\.id) == ["s_user_canonical"])
    }

    @Test("Message reference token sends structured identity without quoted prompt text")
    @MainActor
    func messageReferenceSendsStructuredIdentity() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        let referenced = Message(
            id: "s_ref",
            llmVisibleMessageId: "llm_ref",
            role: .assistant,
            content: "Do not paste this into the prompt",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:s_ref",
            clientMessageId: "c_ref"
        )
        let resetBeforeReference = viewModel.inputResetToken
        let selection = viewModel.referenceMessageInPrompt(referenced, selectionRange: NSRange(location: 0, length: 0))
        #expect(viewModel.inputResetToken == resetBeforeReference + 1)
        viewModel.inputContent = NSAttributedString(string: "Summarize the selected context")
        _ = viewModel.referenceMessageInPrompt(referenced, selectionRange: selection)
        viewModel.send()

        try await Task.sleep(forDuration: .milliseconds(10))
        #expect(chatService.lastSentContent == "Summarize the selected context")
        #expect(chatService.lastSentContent?.contains("Do not paste") == false)
        let reference = try #require(chatService.lastSentReferences.first)
        #expect(reference.kind == "reply")
        #expect(reference.llmVisibleMessageId == "llm_ref")
        #expect(reference.role == .assistant)
        #expect(reference.preview == "Do not paste this into the prompt")

        let payload = ClientMessagePayload(
            id: "c_payload",
            content: "Prompt",
            attachments: [],
            sessionKey: personalSessionKey,
            references: [reference]
        )
        let encoded = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let references = try #require(object["references"] as? [[String: Any]])
        #expect(references.first?["llmVisibleMessageId"] as? String == "llm_ref")
        #expect(references.first?["preview"] as? String == "Do not paste this into the prompt")
    }

    @Test("Reply reference resolves echoed client-visible identity for transcript indicator")
    @MainActor
    func replyReferenceResolvesEchoedClientVisibleIdentityForTranscriptIndicator() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.replyReferenceResolvesEchoedClientVisibleIdentityForTranscriptIndicator")
        await viewModel.onAppear()
        let personalStream = makeStreamSession(
            sessionKey: personalSessionKey,
            displayName: "Personal",
            kind: "main",
            orderIndex: 0,
            isBuiltIn: true
        )
        chatService.streams = [personalStream]
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        chatService.emitServiceEvent(
            .sessionInfo(
                SessionInfo(
                    userId: "user",
                    isAdmin: false,
                    dmScope: "dm",
                    sessionKeys: [personalSessionKey]
                )
            )
        )
        viewModel.setActiveSessionKeyForTesting(personalSessionKey)
        for _ in 0..<50 {
            if viewModel.activeSessionKey == personalSessionKey {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let referenced = Message(
            id: "s_reference_echo",
            llmVisibleMessageId: "llm_reference_echo",
            role: .assistant,
            content: "This is a very long referenced message that should truncate in the outgoing bubble chip.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey,
            clientMessageId: "c_reference_echo"
        )
        try emitServerMessage(referenced, via: chatService)
        try await Task.sleep(for: .milliseconds(10))

        let replied = Message(
            id: "s_reply_echo",
            role: .user,
            content: "Got it.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_200),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey,
            replyToClientMessageId: "c_reference_echo"
        )

        let replyReference = viewModel.replyReference(for: replied)
        let tokenLabel = try #require(replyReference?.tokenLabel)
        #expect(replyReference?.sessionKey == personalSessionKey)
        #expect(replyReference?.llmVisibleMessageId == "llm_reference_echo")
        #expect(replyReference?.clientMessageId == "c_reference_echo")
        #expect(tokenLabel.hasSuffix("…"))
        #expect(tokenLabel.contains("This is a very long referenced message"))
        #expect(tokenLabel.contains("assistant:") == false)
        #expect(tokenLabel.contains("user:") == false)
        #expect(tokenLabel.contains("tool:") == false)
    }

    @Test("Accepted reply send echoes reply token metadata onto the outgoing user bubble")
    @MainActor
    func acceptedReplySendEchoesReplyTokenMetadataOntoOutgoingBubble() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.acceptedReplySendEchoesReplyTokenMetadataOntoOutgoingBubble")
        await viewModel.onAppear()
        let personalStream = makeStreamSession(
            sessionKey: personalSessionKey,
            displayName: "Personal",
            kind: "main",
            orderIndex: 0,
            isBuiltIn: true
        )
        chatService.streams = [personalStream]
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        chatService.emitServiceEvent(
            .sessionInfo(
                SessionInfo(
                    userId: "user",
                    isAdmin: false,
                    dmScope: "dm",
                    sessionKeys: [personalSessionKey]
                )
            )
        )
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.setActiveSessionKeyForTesting(personalSessionKey)
        for _ in 0..<50 {
            if viewModel.activeSessionKey == personalSessionKey {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let referenced = Message(
            id: "s_reply_target",
            llmVisibleMessageId: "llm_reply_target",
            role: .assistant,
            content: "The reply target that should be echoed in the outgoing bubble.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_300),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey,
            clientMessageId: "c_reply_target"
        )
        try emitServerMessage(referenced, via: chatService)
        try await Task.sleep(for: .milliseconds(10))

        viewModel.inputContent = NSAttributedString(string: "Replying now")
        _ = viewModel.referenceMessageInPrompt(referenced, selectionRange: NSRange(location: 0, length: 0))
        viewModel.send()

        try await Task.sleep(for: .milliseconds(10))
        let optimisticOutgoing = try #require(await MainActor.run { viewModel.messages.last })
        #expect(optimisticOutgoing.role == .user)
        #expect(optimisticOutgoing.replyToMessageId == "llm_reply_target")
        #expect(optimisticOutgoing.replyToClientMessageId == referenced.clientMessageId)

        try emitServerMessage(
            Message(
                id: "s_reply_echo",
                role: .user,
                content: "Replying now",
                timestamp: Date(timeIntervalSince1970: 1_700_000_350),
                streaming: false,
                attachments: [],
                deviceId: "device",
                sessionKey: personalSessionKey,
                clientMessageId: optimisticOutgoing.id
            ),
            via: chatService
        )
        try await Task.sleep(for: .milliseconds(10))

        let outgoing = try #require(await MainActor.run { viewModel.messages.last })
        #expect(outgoing.role == .user)
        #expect(outgoing.replyToMessageId == "llm_reply_target")
        #expect(outgoing.replyToClientMessageId == referenced.clientMessageId)
        let outgoingReplyReference = viewModel.replyReference(for: outgoing)
        #expect(outgoingReplyReference?.llmVisibleMessageId == "llm_reply_target")
        #expect(outgoingReplyReference?.clientMessageId == referenced.clientMessageId)
        #expect(outgoingReplyReference?.tokenLabel.contains("assistant:") == false)
    }

    @Test("Composer exposes modified Return as local newline key commands")
    @MainActor
    func composerModifiedReturnKeyCommands() {
        let textView = PastableTextView()
        let commands = textView.keyCommands ?? []
        #expect(commands.contains { $0.input == "\r" && $0.modifierFlags == [.shift] })
        #expect(commands.contains { $0.input == "\r" && $0.modifierFlags == [.control] })
    }

    @Test("Interactive callback fallback echoes are suppressed from visible messages")
    @MainActor
    func interactiveCallbackFallbackEchoesAreSuppressed() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emit(
            Message(
                id: "s_callback_1",
                role: .user,
                content: #"[Interactive: "Quick Survey"] action=submit - {"name":"Flynn"}"#,
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: "device",
                sessionKey: personalSessionKey
            )
        )

        for _ in 0..<50 {
            if viewModel.debugConnectionSnapshot().lastMessageId == "s_callback_1" { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.debugConnectionSnapshot().lastMessageId == "s_callback_1")
    }

    @Test("Message-level errors annotate placeholders and show toast")
    @MainActor
    func messageErrorsMarkFailedMessages() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Broken message")
        viewModel.send()

        try await Task.sleep(forDuration: .milliseconds(10))
        guard let messageId = chatService.lastSentId else {
            Issue.record("Expected chat service to capture sent message id")
            return
        }

        chatService.emitServiceEvent(.messageError(messageId: messageId, code: "invalid_message", message: "bad content"))
        // Service events are delivered via async stream; allow time for ordering with other connection toasts.
        for _ in 0..<50 {
            let messages = await MainActor.run { toastManager.debugMessages }
            if messages.contains("bad content") {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let failure = viewModel.failureMessage(for: messageId)
        #expect(failure == "bad content")
        let messages = await MainActor.run { toastManager.debugMessages }
        #expect(messages.contains("bad content"))
    }

    @Test("Pending send shows pending indicator until server ack")
    @MainActor
    func pendingSendShowsPendingIndicatorUntilAck() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Still pending")
        viewModel.send()

        for _ in 0..<50 {
            if let messageId = chatService.lastSentId,
               viewModel.sendIndicatorState(for: messageId) == .pending {
                return
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        Issue.record("Expected pending send indicator before server ack")
    }

    @Test("Prompt turn accepted clears send indicator and shows prompt stage")
    @MainActor
    func promptTurnAcceptedClearsSendIndicatorAndShowsPromptStage() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Accepted by prompt turn")
        viewModel.send()

        let messageId = try await requireLastSentId(chatService)
        for _ in 0..<50 {
            if viewModel.sendIndicatorState(for: messageId) == .pending { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.sendIndicatorState(for: messageId) == .pending)

        chatService.emitServiceEvent(
            .promptTurnState(
                PromptTurnStateEvent(
                    type: "event",
                    event: "prompt_turn_state",
                    payload: .init(
                        messageId: messageId,
                        sessionKey: personalSessionKey,
                        state: "accepted",
                        terminalState: nil,
                        correlationId: "corr_prompt_accept",
                        clawlineMessageRowId: 1,
                        error: nil
                    )
                )
            )
        )

        for _ in 0..<50 {
            if viewModel.sendIndicatorState(for: messageId) == nil,
               viewModel.liveProgress(for: personalSessionKey)?.stage == .acceptedWaiting {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.sendIndicatorState(for: messageId) == nil)
        #expect(viewModel.liveProgress(for: personalSessionKey)?.stage == .acceptedWaiting)
        #expect(viewModel.liveProgressSummary(for: personalSessionKey) == "Accepted by provider")
        #expect(viewModel.shouldShowPromptStageIndicator(in: personalSessionKey))
    }

    @Test("Canceled prompt remains visible as terminal ghost and does not send")
    @MainActor
    func canceledPromptRemainsVisibleAsTerminalGhostAndDoesNotSend() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let uploadService = TestUploadService()
        uploadService.uploadDelay = .milliseconds(300)
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: uploadService,
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let attachment = makePendingAttachment(dataSize: 512_000, mimeType: "application/pdf")
        viewModel.attachmentData[attachment.id] = attachment
        viewModel.inputContent = makeAttributedContent(with: [attachment.id])

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.send()

        for _ in 0..<50 {
            if viewModel.isSending, viewModel.messages.count == 1 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let canceledId = try #require(viewModel.messages.first?.id)
        #expect(viewModel.sendIndicatorState(for: canceledId) == .pending)
        #expect(viewModel.canCancelSend == true)
        let task = viewModel.sendTask
        viewModel.cancelSend()
        await task?.value

        #expect(chatService.sentIds.isEmpty)
        #expect(chatService.lastSentId == nil)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.id == canceledId)
        #expect(viewModel.messages.first?.deliveryState == .canceled)
        #expect(viewModel.sendIndicatorState(for: canceledId) == nil)
        #expect(viewModel.failureMessage(for: canceledId) == nil)
    }

    @Test("Cancel after transport send starts does not mark prompt canceled")
    @MainActor
    func cancelAfterTransportSendStartsDoesNotMarkPromptCanceled() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.sendDelay = .milliseconds(300)
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Already sent")
        viewModel.send()

        let messageId = try await requireLastSentId(chatService)
        #expect(viewModel.canCancelSend == false)
        viewModel.cancelSend()

        #expect(viewModel.messages.first?.id == messageId)
        #expect(viewModel.messages.first?.deliveryState == .normal)
        #expect(viewModel.sendIndicatorState(for: messageId) == .pending)

        chatService.emitServiceEvent(.messageAcked(id: messageId))
        for _ in 0..<50 {
            if viewModel.sendIndicatorState(for: messageId) == nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.messages.first?.deliveryState == .normal)
        #expect(viewModel.sendIndicatorState(for: messageId) == nil)
    }

    @Test("Server ack clears pending indicator and shields accepted send from later errors")
    @MainActor
    func serverAckClearsPendingIndicatorAndShieldsAcceptedSend() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Accepted")
        viewModel.send()

        let messageId = try await requireLastSentId(chatService)
        chatService.emitServiceEvent(.messageAcked(id: messageId))
        for _ in 0..<50 {
            if viewModel.sendIndicatorState(for: messageId) == nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.sendIndicatorState(for: messageId) == nil)

        chatService.emitServiceEvent(.messageError(messageId: messageId, code: "invalid_message", message: "late reject"))
        chatService.emitServiceEvent(.messageError(messageId: nil, code: "payload_too_large", message: nil))
        try await Task.sleep(forDuration: .milliseconds(40))

        #expect(viewModel.sendIndicatorState(for: messageId) == nil)
        #expect(viewModel.failureMessage(for: messageId) == nil)
    }

    @Test("Prompt turn failed state marks accepted send failed immediately")
    @MainActor
    func promptTurnFailedStateMarksAcceptedSendFailedImmediately() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Accepted then failed")
        viewModel.send()

        let messageId = try await requireLastSentId(chatService)
        chatService.emitServiceEvent(.messageAcked(id: messageId))
        for _ in 0..<50 {
            if viewModel.sendIndicatorState(for: messageId) == nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        chatService.emitServiceEvent(
            .promptTurnState(
                PromptTurnStateEvent(
                    type: "event",
                    event: "prompt_turn_state",
                    payload: .init(
                        messageId: messageId,
                        sessionKey: personalSessionKey,
                        state: "failed",
                        terminalState: "failed",
                        correlationId: "corr_1",
                        clawlineMessageRowId: 1,
                        error: "clawline.promptTurn.noDelivery"
                    )
                )
            )
        )
        for _ in 0..<50 {
            if viewModel.sendIndicatorState(for: messageId) == .failed("clawline.promptTurn.noDelivery") {
                return
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        Issue.record("Expected accepted send to show prompt-turn failure without waiting for reload")
    }

    @Test("Accepted replayed user message without final reply does not show failed indicator")
    @MainActor
    func acceptedReplayedUserMessageWithoutFinalReplyDoesNotShowFailedIndicator() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.startReplayCount = 1
        chatService.emitSyncCompleteOnStart = false
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.acceptedReplayWithoutFinal")
        for _ in 0..<50 {
            if chatService.connectCallCount > 0 { break }
            try await Task.sleep(forDuration: .milliseconds(10))
        }

        let payload = #"{"type":"message","id":"s_user_accepted","role":"user","content":"Accepted but no final yet","timestamp":1700000000000,"streaming":false,"deviceId":"device","sessionKey":"\#(personalSessionKey)","attachments":[],"clientMessageId":"c_accepted"}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(payload.utf8))))
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .syncComplete))

        for _ in 0..<50 {
            if viewModel.messages.contains(where: { $0.id == "s_user_accepted" }) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.messages.map(\.id).contains("s_user_accepted"))
        #expect(viewModel.sendIndicatorState(for: "s_user_accepted") == nil)
        #expect(viewModel.failureMessage(for: "s_user_accepted") == nil)
    }

    @Test("True send failure shows resend indicator and retry becomes pending")
    @MainActor
    func trueSendFailureShowsResendAndRetryBecomesPending() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Retry source")
        viewModel.send()

        let failedId = try await requireLastSentId(chatService)
        chatService.emitServiceEvent(.messageError(messageId: failedId, code: "invalid_message", message: "bad"))
        for _ in 0..<50 {
            if case .failed("bad") = viewModel.sendIndicatorState(for: failedId) {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.sendIndicatorState(for: failedId) == .failed("bad"))

        viewModel.resendFailedMessage(messageId: failedId)
        for _ in 0..<50 {
            if viewModel.messages.count == 1,
               let replacement = viewModel.messages.first,
               replacement.id != failedId,
               viewModel.sendIndicatorState(for: replacement.id) == .pending {
                return
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        Issue.record("Expected retry replacement bubble to become pending")
    }

    @Test("Unscoped payload_too_large errors mark pending placeholders and show clear toast")
    @MainActor
    func unscopedPayloadTooLargeErrorsMarkPendingPlaceholders() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Large message pending")
        viewModel.send()

        try await Task.sleep(forDuration: .milliseconds(10))
        guard let messageId = chatService.lastSentId else {
            Issue.record("Expected chat service to capture sent message id")
            return
        }

        chatService.emitServiceEvent(.messageError(messageId: nil, code: "payload_too_large", message: nil))
        for _ in 0..<50 {
            if viewModel.failureMessage(for: messageId) != nil {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.failureMessage(for: messageId) == "That message is too large to send.")
        #expect(viewModel.messages.contains(where: { $0.id == messageId }))
        #expect(viewModel.isSending == false)
        let messages = await MainActor.run { toastManager.debugMessages }
        #expect(messages.contains("That message is too large to send."))
    }

    @Test("Oversized text is blocked before optimistic send and surfaces a clear toast")
    @MainActor
    func oversizedTextIsRejectedBeforeSend() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        let oversized = String(repeating: "a", count: 65_537)
        viewModel.inputContent = NSAttributedString(string: oversized)

        viewModel.send()

        #expect(chatService.lastSentId == nil)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isSending == false)
        #expect(viewModel.inputContent.string == oversized)
        let messages = await MainActor.run { toastManager.debugMessages }
        #expect(messages.contains("That message is too large to send."))
    }

    @Test("Current prompt cancellation calls typed control API for active cancellable run")
    @MainActor
    func currentPromptCancellationCallsTypedControlAPIForActiveCancellableRun() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true)
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0,
            canCancelCurrentRun: true
        )
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        viewModel.inputContent = NSAttributedString(string: "draft")
        for _ in 0..<50 {
            if viewModel.canCancelCurrentPrompt { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        viewModel.requestCurrentPromptCancellation()
        for _ in 0..<50 {
            if chatService.cancelCurrentRunCallCount == 1 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(chatService.cancelCurrentRunCallCount == 1)
        #expect(chatService.lastCancelledSessionKey == personalSessionKey)
        #expect(chatService.lastSentId == nil)
        #expect(chatService.lastSentContent == nil)
        #expect(viewModel.inputContent.string == "draft")
        #expect(toastManager.debugMessages.contains("Prompt cancellation requested."))
    }

    @Test("Visible typing prompt cancellation follows in-flight run state")
    @MainActor
    func visibleTypingPromptCancellationRequiresActiveTypingState() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0,
            canCancelCurrentRun: true
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.visibleTypingPromptCancellationRequiresActiveTypingState")
        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.canCancelCurrentPrompt == true)
        #expect(viewModel.canCancelCurrentPrompt(in: personalSessionKey) == true)
        #expect(viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) == true)
        #expect(viewModel.shouldShowTypingIndicator(in: personalSessionKey) == true)

        chatService.emitServiceEvent(.typingStateChanged(isTyping: true, sessionKey: personalSessionKey))
        for _ in 0..<50 {
            if viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) == true)

        chatService.emitServiceEvent(.typingStateChanged(isTyping: false, sessionKey: personalSessionKey))
        try await Task.sleep(forDuration: .milliseconds(20))
        #expect(viewModel.canCancelCurrentPrompt(in: personalSessionKey) == true)
        #expect(viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) == true)
        #expect(viewModel.shouldShowTypingIndicator(in: personalSessionKey) == true)
    }

    @Test("Typing indicator morph targets only the newly inserted assistant message once")
    @MainActor
    func typingIndicatorMorphTargetIsNewAssistantMessageAndOneShot() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.typingIndicatorMorphTargetIsNewAssistantMessageAndOneShot")
        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)

        let priorMessage = Message(
            id: "s_prior",
            role: .assistant,
            content: "already here",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
        chatService.emit(priorMessage)
        for _ in 0..<50 {
            if viewModel.messages(for: personalSessionKey).contains(where: { $0.id == priorMessage.id }) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.shouldMorphTypingIndicator == false)

        chatService.emitServiceEvent(.typingStateChanged(isTyping: true, sessionKey: personalSessionKey))
        for _ in 0..<50 {
            if viewModel.shouldShowTypingIndicator(in: personalSessionKey) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let newMessage = Message(
            id: "s_new",
            role: .assistant,
            content: "new answer",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey
        )
        chatService.emit(newMessage)
        for _ in 0..<50 {
            if viewModel.typingIndicatorMorphTargetMessageId(in: personalSessionKey) == newMessage.id { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.shouldMorphTypingIndicator)
        #expect(viewModel.typingIndicatorMorphTargetMessageId(in: personalSessionKey) == newMessage.id)
        #expect(
            TypingIndicatorMorph.shouldMorph(
                wasShowingTypingIndicator: true,
                targetMessageId: viewModel.typingIndicatorMorphTargetMessageId(in: personalSessionKey),
                insertedIds: [priorMessage.id]
            ) == false
        )
        #expect(
            TypingIndicatorMorph.shouldMorph(
                wasShowingTypingIndicator: true,
                targetMessageId: viewModel.typingIndicatorMorphTargetMessageId(in: personalSessionKey),
                insertedIds: [newMessage.id]
            )
        )

        viewModel.consumeTypingIndicatorMorphTargetMessageId(newMessage.id, in: personalSessionKey)
        #expect(viewModel.shouldMorphTypingIndicator == false)
        #expect(viewModel.typingIndicatorMorphTargetMessageId(in: personalSessionKey) == nil)
    }

    @Test("Current prompt cancellation targets visible stream during pager switch debounce")
    @MainActor
    func currentPromptCancellationTargetsVisibleStreamDuringPagerSwitchDebounce() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let researchSessionKey = "agent:main:clawline:user:s_research"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: researchSessionKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0,
            canCancelCurrentRun: true
        )
        chatService.sessionStatusBySessionKey[researchSessionKey] = makeSessionStatus(
            sessionKey: researchSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0,
            canCancelCurrentRun: true
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil,
               viewModel.sessionStatus(for: researchSessionKey) != nil {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        viewModel.setActiveSessionKeyForTesting(personalSessionKey)
        viewModel.requestStreamSwitch(to: researchSessionKey, source: .pager)

        viewModel.requestCurrentPromptCancellation()
        for _ in 0..<50 {
            if chatService.cancelCurrentRunCallCount == 1 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(chatService.cancelCurrentRunCallCount == 1)
        #expect(chatService.lastCancelledSessionKey == researchSessionKey)
    }

    @Test("Current prompt cancellation with explicit session does not fall back to another stream")
    @MainActor
    func currentPromptCancellationWithExplicitSessionDoesNotFallBackToAnotherStream() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let researchSessionKey = "agent:main:clawline:user:s_research"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: researchSessionKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0,
            canCancelCurrentRun: true
        )
        chatService.sessionStatusBySessionKey[researchSessionKey] = makeSessionStatus(
            sessionKey: researchSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil,
               viewModel.sessionStatus(for: researchSessionKey) != nil {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.canCancelCurrentPrompt == true)
        #expect(viewModel.canCancelCurrentPrompt(in: researchSessionKey) == false)
        viewModel.requestCurrentPromptCancellation(sessionKey: researchSessionKey)
        try await Task.sleep(forDuration: .milliseconds(20))

        #expect(chatService.cancelCurrentRunCallCount == 0)
    }

    @Test("Current prompt cancellation reports unsupported typed control response")
    @MainActor
    func currentPromptCancellationReportsUnsupportedTypedControlResponse() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0,
            canCancelCurrentRun: true
        )
        chatService.sessionControlResponse = SessionControlResponse(
            ok: false,
            sessionKey: personalSessionKey,
            action: "cancel_current_run",
            code: "unsupported",
            message: "The current Clawline provider dispatch path does not expose a per-session abort seam.",
            status: nil,
            capabilities: nil
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        chatService.emitServiceEvent(.typingStateChanged(isTyping: true, sessionKey: personalSessionKey))
        for _ in 0..<50 {
            if viewModel.canCancelCurrentPrompt { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        viewModel.requestCurrentPromptCancellation()
        for _ in 0..<50 {
            if toastManager.debugMessages.contains("The current Clawline provider dispatch path does not expose a per-session abort seam.") {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(chatService.cancelCurrentRunCallCount == 1)
        #expect(toastManager.debugMessages.contains("The current Clawline provider dispatch path does not expose a per-session abort seam."))
    }

    @Test("Current prompt cancellation remains available while typing when provider reports cancel unsupported")
    @MainActor
    func currentPromptCancellationRemainsAvailableWhileTypingWhenProviderReportsCancelUnsupported() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        chatService.sessionControlResponse = SessionControlResponse(
            ok: false,
            sessionKey: personalSessionKey,
            action: "cancel_current_run",
            code: "unsupported",
            message: "The current Clawline provider dispatch path does not expose a per-session abort seam.",
            status: nil,
            capabilities: nil
        )
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        chatService.emitServiceEvent(.typingStateChanged(isTyping: true, sessionKey: personalSessionKey))
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.canCancelCurrentPrompt == true)
        #expect(viewModel.canCancelCurrentPrompt(in: personalSessionKey) == true)
        viewModel.requestCurrentPromptCancellation()
        for _ in 0..<50 {
            if chatService.cancelCurrentRunCallCount == 1 { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(chatService.cancelCurrentRunCallCount == 1)
        #expect(chatService.lastCancelledSessionKey == personalSessionKey)
    }

    @Test("Connection interruptions update send button state without passive toast")
    @MainActor
    func connectionInterruptionTriggersAlert() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true)
        ]
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await Task.sleep(forDuration: .milliseconds(20))
        chatService.emitConnectionState(.connected)
        for _ in 0..<200 {
            let state = await MainActor.run { viewModel.sendButtonConnectionState }
            if state == .connected { break }
            try await Task.sleep(forDuration: .milliseconds(25))
        }

        chatService.emitServiceEvent(.connectionInterrupted(reason: "Connection lost"))
        var state: SendButtonConnectionState?
        for _ in 0..<200 {
            state = await MainActor.run { viewModel.sendButtonConnectionState }
            if state == .reconnecting { break }
            try await Task.sleep(forDuration: .milliseconds(25))
        }

        #expect(state == .reconnecting)
        #expect(toastManager.debugMessages.isEmpty)
    }

    @Test("Passive connection_lost message errors do not show toasts")
    @MainActor
    func passiveConnectionLostErrorsStaySilent() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Pending")
        viewModel.send()
        try await Task.sleep(forDuration: .milliseconds(10))

        guard let messageId = chatService.lastSentId else {
            Issue.record("Expected a sent message id")
            return
        }

        chatService.emitServiceEvent(.messageError(messageId: messageId, code: "connection_lost", message: nil))
        for _ in 0..<50 {
            if viewModel.failureMessage(for: messageId) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.failureMessage(for: messageId) == "Message not delivered — connection lost.")
        #expect(toastManager.debugMessages.isEmpty)
    }

    @Test("Network-lost send failure leaves send button non-green")
    @MainActor
    func networkLostSendFailureLeavesSendButtonNonGreen() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.networkLostSendFailure")
        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Pending")
        #expect(viewModel.sendButtonConnectionState == .connected)
        #expect(viewModel.canSend)

        chatService.sendError = URLError(.networkConnectionLost)
        viewModel.send()

        for _ in 0..<100 {
            if toastManager.debugMessages.contains("The network connection was lost."),
               viewModel.sendButtonConnectionState == .reconnecting {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(toastManager.debugMessages.contains("The network connection was lost."))
        #expect(viewModel.sendButtonConnectionState == .reconnecting)
        #expect(!viewModel.canSend)
    }

    @Test("Provider disconnected state alone leaves send button non-green")
    @MainActor
    func providerDisconnectedStateAloneLeavesSendButtonNonGreen() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.providerDisconnectedStateAlone")
        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Pending")
        #expect(viewModel.sendButtonConnectionState == .connected)
        #expect(viewModel.canSend)

        chatService.emitProviderConnectionStateOnly(.disconnected)

        for _ in 0..<100 {
            if viewModel.sendButtonConnectionState == .reconnecting {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.sendButtonConnectionState == .reconnecting)
        #expect(!viewModel.canSend)
    }

    @Test("Disconnected transport maps to disconnected send-button state")
    @MainActor
    func disconnectedMapsToDisconnectedSendButtonState() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emitConnectionState(.disconnected)

        var state: SendButtonConnectionState?
        for _ in 0..<100 {
            state = await MainActor.run { viewModel.sendButtonConnectionState }
            if state == .disconnected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state == .disconnected)
    }

    @Test("Manual reconnect triggers immediate connect attempt")
    @MainActor
    func manualReconnectIsImmediate() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        let initialConnectCalls = chatService.connectCallCount
        chatService.emitConnectionState(.disconnected)
        try await Task.sleep(for: .milliseconds(30))
        viewModel.reconnect()

        for _ in 0..<40 {
            if chatService.connectCallCount > initialConnectCalls { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.connectCallCount > initialConnectCalls)
    }

    @Test("Cancelled reconnect delay does not trigger an extra reconnect attempt")
    @MainActor
    func cancelledReconnectDelayDoesNotTriggerExtraReconnect() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        for _ in 0..<50 {
            if chatService.connectCallCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let baselineConnectCalls = chatService.connectCallCount
        chatService.emitConnectionState(.disconnected)
        try await Task.sleep(for: .milliseconds(30))
        viewModel.reconnect()

        for _ in 0..<80 {
            if chatService.connectCallCount >= baselineConnectCalls + 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let connectCallsAfterImmediateReconnect = chatService.connectCallCount
        #expect(connectCallsAfterImmediateReconnect == baselineConnectCalls + 1)

        try await Task.sleep(for: .milliseconds(2300))
        #expect(chatService.connectCallCount == connectCallsAfterImmediateReconnect)
    }

    @Test("Persist debounce cancellation does not flush cache early")
    @MainActor
    func persistDebounceCancellationDoesNotFlushEarly() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        func cacheURL(for sessionKey: String) -> URL? {
            guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let directoryURL = baseURL
                .appendingPathComponent("Clawline", isDirectory: true)
                .appendingPathComponent("MessageCache", isDirectory: true)
            let filename = sessionKey
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            return directoryURL.appendingPathComponent("\(filename.isEmpty ? "session" : filename).json")
        }

        guard let cacheURL = cacheURL(for: personalSessionKey) else {
            Issue.record("Expected cache URL for personal session")
            return
        }
        try? FileManager.default.removeItem(at: cacheURL)

        await viewModel.onAppear()
        chatService.emit(
            Message(
                id: "s_cache_1",
                role: .assistant,
                content: "one",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )
        try await Task.sleep(for: .milliseconds(50))
        chatService.emit(
            Message(
                id: "s_cache_2",
                role: .assistant,
                content: "two",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )

        try await Task.sleep(for: .milliseconds(120))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)

        var persisted = false
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                persisted = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(persisted)
    }

    @Test("canSend becomes true when attachments exist even without text")
    @MainActor
    func canSendWithAttachmentOnly() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let attachment = makePendingAttachment(dataSize: 512, mimeType: "image/png")
        viewModel.attachmentData[attachment.id] = attachment
        viewModel.inputContent = makeAttributedContent(with: [attachment.id])
        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)

        #expect(viewModel.canSend)
    }

    @Test("Doc §5: Memory warnings flush presentation cache")
    @MainActor
    func memoryWarningClearsPresentationCache() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let message = Message(
            id: "table-msg",
            role: .assistant,
            content: """
            | Foo | Bar |
            | --- | --- |
            | A | B |
            """,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: personalSessionKey,
        )

        await viewModel.onAppear()
        let chatService = TestChatService()
        chatService.emit(message)
        try await Task.sleep(forDuration: .milliseconds(10))

        let metrics = ChatFlowTheme.Metrics(isCompact: true)
        let cachedMessage = await MainActor.run { viewModel.messages.first ?? message }
        _ = viewModel.presentation(for: cachedMessage, metrics: metrics)

        let cacheCount = await MainActor.run { viewModel.debugPresentationCacheSize() }
        #expect(cacheCount == 1)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(forDuration: .milliseconds(10))

        let flushedCache = await MainActor.run { viewModel.debugPresentationCacheSize() }
        let flushedStates = await MainActor.run { viewModel.debugTableParseStateSize() }
        #expect(flushedCache == 0)
        #expect(flushedStates == 0)
    }

    @Test("send uploads attachments that require persistence")
    @MainActor
    func sendProcessesAttachments() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let uploadService = TestUploadService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: uploadService,
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let inlineAttachment = makePendingAttachment(dataSize: 1024, mimeType: "image/png")
        let fileAttachment = makePendingAttachment(dataSize: 512_000, mimeType: "application/pdf")

        viewModel.attachmentData[inlineAttachment.id] = inlineAttachment
        viewModel.attachmentData[fileAttachment.id] = fileAttachment

        viewModel.inputContent = makeAttributedContent(with: [inlineAttachment.id, fileAttachment.id])

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.send()
        try await viewModel.sendTask?.value

        #expect(uploadService.uploadedPayloads.count == 1)
        #expect(chatService.lastSentAttachments.count == 2)
        guard chatService.lastSentAttachments.count == 2 else {
            Issue.record("Expected send to produce two wire attachments")
            return
        }

        let first = chatService.lastSentAttachments[0]
        let second = chatService.lastSentAttachments[1]

        let attachments = [first, second]
        let hasInline = attachments.contains { attachment in
            if case .image = attachment { return true }
            return false
        }
        let hasAsset = attachments.contains { attachment in
            if case .asset(let assetId) = attachment { return assetId.hasPrefix("asset_") }
            return false
        }
        #expect(hasInline)
        #expect(hasAsset)

        #expect(viewModel.attachmentData.isEmpty)
        #expect(viewModel.inputContent.string.isEmpty)
    }

    @Test("T157 image preparer downscales oversized image bytes")
    @MainActor
    func imagePreparerDownscalesOversizedImageBytes() throws {
        let originalData = makeLargeJPEGData()
        #expect(originalData.count > PendingAttachment.modelAwareMaxImageRawByteLimit)

        let prepared = try ImageAttachmentPreparer.prepareForModel(data: originalData, mimeType: "image/jpeg")

        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.data.count <= PendingAttachment.modelAwareMaxImageRawByteLimit)
        #expect(prepared.data.count < originalData.count)
    }

    @Test("T157 image preparer leaves bounded image bytes unchanged")
    @MainActor
    func imagePreparerLeavesBoundedImageBytesUnchanged() throws {
        let originalData = makeSmallJPEGData()
        #expect(originalData.count <= PendingAttachment.modelAwareMaxImageRawByteLimit)

        let prepared = try ImageAttachmentPreparer.prepareForModel(data: originalData, mimeType: "image/jpeg")

        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.data == originalData)
    }

    @Test("T157 prepared image bytes fit inline transport attachment")
    @MainActor
    func preparedImageBytesFitInlineTransportAttachment() throws {
        let oversized = makeLargeJPEGData()
        let prepared = try ImageAttachmentPreparer.prepareForModel(data: oversized, mimeType: "image/jpeg")
        let wireAttachment = WireAttachment.image(mimeType: prepared.mimeType, data: prepared.data)

        guard case .image(let mimeType, let data) = wireAttachment else {
            Issue.record("Expected prepared image transport attachment")
            return
        }
        #expect(mimeType == "image/jpeg")
        #expect(data.count <= PendingAttachment.modelAwareMaxImageRawByteLimit)
        #expect(data.count < oversized.count)
    }

    @Test("two immediate sends dispatch one outbound message")
    @MainActor
    func immediateDoubleSendDispatchesOnce() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let uploadService = TestUploadService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: uploadService,
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        viewModel.inputContent = NSAttributedString(string: "Send once")

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.send()
        let firstSendTask = viewModel.sendTask
        viewModel.send()
        let secondSendTask = viewModel.sendTask
        try await firstSendTask?.value
        try await secondSendTask?.value

        #expect(chatService.sendCallCount == 1)
        #expect(chatService.lastSentContent == "Send once")
    }

    @Test("send during attachment staging gap does not prune and retries cleanly after token insertion")
    @MainActor
    func sendDuringAttachmentStagingGapDefersThenSucceeds() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(
                sessionKey: personalSessionKey,
                displayName: "Personal",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true
            )
        ]
        _ = chatService.incomingMessages
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let uploadService = TestUploadService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: uploadService,
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(personalSessionKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        viewModel.setActiveSessionKeyForTesting(personalSessionKey)
        chatService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "dm",
                sessionKeys: [personalSessionKey]
            )
        ))
        for _ in 0..<50 {
            if viewModel.sendButtonConnectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.sendButtonConnectionState == .connected)

        let staged = makePendingAttachment(dataSize: 1024, mimeType: "image/png")
        viewModel.stageAttachments([staged])
        #expect(viewModel.attachmentData[staged.id] != nil)

        // Trigger didSet prune path while staging gap exists (no attachment token yet).
        viewModel.inputContent = NSAttributedString(string: "hello")
        #expect(viewModel.attachmentData[staged.id] != nil)

        viewModel.send()
        try await Task.sleep(for: .milliseconds(20))
        #expect(chatService.lastSentId == nil)
        #expect(toastManager.debugMessages.contains("Finishing attachment…"))
        #expect(viewModel.attachmentData[staged.id] != nil)

        viewModel.inputContent = makeAttributedContent(with: [staged.id])
        try await Task.sleep(for: .milliseconds(20))
        viewModel.send()
        try await viewModel.sendTask?.value

        #expect(chatService.lastSentId != nil)
        #expect(chatService.lastSentAttachments.count == 1)
        let hasAttachment = chatService.lastSentAttachments.contains { attachment in
            switch attachment {
            case .image:
                return true
            case .asset:
                return true
            }
        }
        #expect(hasAttachment)
        #expect(viewModel.attachmentData.isEmpty)
    }

    @Test("Asset-backed interactive HTML document hydrates for inline render path")
    @MainActor
    func assetBackedInteractiveHTMLHydratesForInlineRenderPath() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let uploadService = TestUploadService()
        let descriptor = InteractiveHTMLDescriptor(
            version: 1,
            html: "<html><body><button>Run</button></body></html>",
            metadata: .init(title: "Asset card", height: .auto, maxHeight: 320, backgroundColor: nil)
        )
        let descriptorData = try JSONEncoder().encode(descriptor)
        uploadService.downloadPayloads["asset_html_1"] = descriptorData

        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: uploadService,
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emit(
            Message(
                id: "s_html_asset",
                role: .assistant,
                content: "Interactive card",
                timestamp: Date(),
                streaming: false,
                attachments: [
                    Attachment(
                        id: "att_html_asset",
                        type: .document,
                        mimeType: "\(InteractiveHTMLDescriptor.mimeType); charset=utf-8",
                        data: nil,
                        assetId: "asset_html_1"
                    )
                ],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )

        var resolvedMessage: Message?
        for _ in 0..<60 {
            let current = viewModel.messages.first(where: { $0.id == "s_html_asset" })
            if let current, current.attachments.first?.data == descriptorData {
                resolvedMessage = current
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(uploadService.downloadedAssetIds.contains("asset_html_1"))
        guard let resolvedMessage else {
            Issue.record("Expected asset-backed interactive HTML attachment to hydrate data")
            return
        }

        let presentation = viewModel.presentation(
            for: resolvedMessage,
            metrics: ChatFlowTheme.Metrics(isCompact: true)
        )
        #expect(presentation.parts.contains(where: { part in
            if case .interactiveHTML(let decoded) = part {
                return decoded.metadata?.title == "Asset card"
            }
            return false
        }))
        #expect(!presentation.parts.contains(where: { part in
            if case .file(let attachment) = part {
                return attachment.id == "att_html_asset"
            }
            return false
        }))
    }

    @Test("removing attachments from the attributed string prunes stored data")
    @MainActor
    func prunesOrphanedAttachments() {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let pending = makePendingAttachment(dataSize: 1024, mimeType: "image/png")
        viewModel.attachmentData[pending.id] = pending
        viewModel.inputContent = makeAttributedContent(with: [pending.id])
        #expect(viewModel.attachmentData.count == 1)

        viewModel.inputContent = NSAttributedString(string: "hello")
        #expect(viewModel.attachmentData.isEmpty)
    }
    
    @Test("Outbound sends respect active session selection")
    @MainActor
    func sendUsesActiveSessionKey() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        auth.updateAdminStatus(true)
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: adminSessionKey, displayName: "Admin", kind: "global_dm", orderIndex: 1, isBuiltIn: true),
        ]
        // Ensure async streams are initialized so early emits buffer reliably.
        _ = chatService.incomingMessages
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(adminSessionKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        chatService.emit(
            Message(
                id: "s_admin_seed",
                role: .assistant,
                content: "Admin seed",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: adminSessionKey
            )
        )
        try await Task.sleep(for: .milliseconds(30))

        viewModel.setActiveSessionKeyForTesting(adminSessionKey)
        #expect(viewModel.activeSessionKey == adminSessionKey)
        chatService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: true,
                dmScope: "global_dm",
                sessionKeys: [personalSessionKey, adminSessionKey]
            )
        ))

        for _ in 0..<50 {
            if viewModel.sendButtonConnectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.sendButtonConnectionState == .connected)

        viewModel.inputContent = NSAttributedString(string: "Admin ping")
        viewModel.send()
        for _ in 0..<50 {
            if chatService.lastSessionKey == adminSessionKey { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastSessionKey == adminSessionKey)
    }

    @Test("Send waits for server session provisioning before dispatch")
    @MainActor
    func sendWaitsForSessionProvisioning() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.sendWaitsForSessionProvisioning")
        await viewModel.onAppear()
        chatService.emitConnectionState(.connected)
        for _ in 0..<50 {
            if viewModel.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        try await Task.sleep(for: .milliseconds(20))

        viewModel.inputContent = NSAttributedString(string: "Wait for provisioning")
        viewModel.send()
        viewModel.send()
        try await Task.sleep(for: .milliseconds(40))
        #expect(chatService.lastSentId == nil)
        #expect(toastManager.debugMessages.contains("Connecting to stream…") == false)

        chatService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "dm",
                sessionKeys: [personalSessionKey]
            )
        ))

        for _ in 0..<50 {
            if chatService.lastSentId != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chatService.lastSessionKey == personalSessionKey)
        #expect(chatService.sentIds.count == 1)
    }

    @Test("Resend keeps replacement bubble if retry send fails immediately")
    @MainActor
    func resendFailureRetainsReplacementBubble() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Retry me")
        viewModel.send()
        try await Task.sleep(forDuration: .milliseconds(10))

        guard let originalId = chatService.lastSentId else {
            Issue.record("Expected sent message id")
            return
        }
        chatService.emitServiceEvent(.messageError(messageId: originalId, code: "invalid_message", message: "bad"))
        for _ in 0..<50 {
            if viewModel.failureMessage(for: originalId) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        chatService.sendError = ProviderChatService.Error.notConnected
        viewModel.resendFailedMessage(messageId: originalId)
        for _ in 0..<50 {
            if !viewModel.isSending { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        let messages = viewModel.messages
        #expect(messages.count == 1)
        guard let replacement = messages.first else {
            Issue.record("Expected replacement bubble")
            return
        }
        #expect(replacement.id != originalId)
        #expect(replacement.content == "Retry me")
        #expect(viewModel.failureMessage(for: replacement.id) != nil)
    }

    @Test("T105: retry uses a new client id at the tail")
    @MainActor
    func retryAppendsNewClientIdAtTailThroughSeam() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        viewModel.inputContent = NSAttributedString(string: "Retry at tail")
        viewModel.send()
        try await Task.sleep(forDuration: .milliseconds(10))

        guard let originalId = chatService.lastSentId else {
            Issue.record("Expected sent message id")
            return
        }
        chatService.emitServiceEvent(.messageError(messageId: originalId, code: "invalid_message", message: "bad"))
        for _ in 0..<50 {
            if viewModel.failureMessage(for: originalId) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        viewModel.debugUpsertMessage(
            makeTestMessage(id: "s_retry_tail", content: "tail", sessionKey: personalSessionKey),
            isServer: true
        )

        viewModel.resendFailedMessage(messageId: originalId)
        let ids = viewModel.messages.map(\.id)
        #expect(!ids.contains(originalId))
        #expect(ids.dropLast().last == "s_retry_tail")
        #expect(ids.last?.hasPrefix("c_") == true)
        #expect(ids.last != originalId)
    }

    @Test("Send blocks stale synthetic session keys after provisioning")
    @MainActor
    func sendBlocksStaleSyntheticSessionKey() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitConnectionState(.connected)
        for _ in 0..<50 {
            if viewModel.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let staleKey = "agent:main:clawline:user:s_deadbeef"
        chatService.emit(
            Message(
                id: "s_seed_stale",
                role: .assistant,
                content: "stale seed",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: staleKey
            )
        )
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(staleKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        viewModel.setActiveSessionKeyForTesting(staleKey)

        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        try await Task.sleep(for: .milliseconds(20))
        chatService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "dm",
                sessionKeys: [personalSessionKey]
            )
        ))
        try await Task.sleep(for: .milliseconds(20))

        viewModel.inputContent = NSAttributedString(string: "Do not send stale")
        viewModel.send()
        try await Task.sleep(for: .milliseconds(40))

        #expect(chatService.lastSentId == nil)
        #expect(toastManager.debugMessages.contains("This stream is unavailable. Switch streams and try again."))
    }

    @Test("Pending send keeps target session while stream switching")
    @MainActor
    func pendingSendKeepsTargetSessionDuringSwitch() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitConnectionState(.connected)
        for _ in 0..<50 {
            if viewModel.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let customKey = "agent:main:clawline:user:s_abcd1234"
        chatService.emit(
            Message(
                id: "s_seed_custom",
                role: .assistant,
                content: "custom seed",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: customKey
            )
        )
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(customKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        viewModel.setActiveSessionKeyForTesting(customKey)
        #expect(viewModel.activeSessionKey == customKey)

        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        try await Task.sleep(for: .milliseconds(20))

        viewModel.inputContent = NSAttributedString(string: "queued while provisioning")
        viewModel.send()
        try await Task.sleep(for: .milliseconds(30))
        #expect(chatService.lastSentId == nil)

        viewModel.setActiveSessionKeyForTesting(personalSessionKey)
        #expect(viewModel.activeSessionKey == personalSessionKey)

        chatService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "dm",
                sessionKeys: [personalSessionKey, customKey]
            )
        ))

        for _ in 0..<50 {
            if chatService.lastSentId != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chatService.lastSessionKey == customKey)
    }

    @Test("Incoming messages route to matching stream")
    @MainActor
    func incomingMessagesRoutePerStream() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        auth.updateAdminStatus(true)
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: adminSessionKey, displayName: "Admin", kind: "global_dm", orderIndex: 1, isBuiltIn: true),
        ]
        _ = chatService.incomingMessages
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(adminSessionKey) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        viewModel.setActiveSessionKeyForTesting(adminSessionKey)
        #expect(viewModel.activeSessionKey == adminSessionKey)

        let adminMessage = Message(
            id: "s_admin",
            role: .assistant,
            content: "Admin hello",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: adminSessionKey
        )

        chatService.emit(adminMessage)
        try await Task.sleep(for: .milliseconds(10))

        var routedMessages: [Message] = []
        for _ in 0..<50 {
            routedMessages = await MainActor.run { viewModel.messages(for: adminSessionKey) }
            if routedMessages.first?.id == "s_admin" {
                break
            }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(routedMessages.count == 1)
        #expect(routedMessages.first?.id == "s_admin")
    }

    @Test("Assistant incoming append fires light haptic when chat is visible and app is foreground")
    @MainActor
    func assistantIncomingAppendFiresHapticWhenVisibleAndForeground() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        _ = chatService.incomingMessages
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let hapticCounter = HapticCounter()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService(),
            assistantIncomingHaptic: {
                hapticCounter.count += 1
            }
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emit(
            Message(
                id: "s_haptic_visible",
                role: .assistant,
                content: "hello",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )

        for _ in 0..<50 {
            if hapticCounter.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(hapticCounter.count == 1)
    }

    @Test("Assistant incoming append does not fire haptic when app is backgrounded")
    @MainActor
    func assistantIncomingAppendDoesNotFireHapticInBackground() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        _ = chatService.incomingMessages
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let hapticCounter = HapticCounter()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService(),
            assistantIncomingHaptic: {
                hapticCounter.count += 1
            }
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        viewModel.handleSceneActiveStateChanged(isActive: false)
        chatService.emit(
            Message(
                id: "s_haptic_background",
                role: .assistant,
                content: "hello",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )

        try await Task.sleep(for: .milliseconds(40))
        #expect(hapticCounter.count == 0)
    }

    @Test("Assistant incoming haptic is debounced to one event per second")
    @MainActor
    func assistantIncomingHapticIsDebounced() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        _ = chatService.incomingMessages
        _ = chatService.connectionState
        _ = chatService.serviceEvents
        let hapticCounter = HapticCounter()
        var now = Date()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService(),
            nowProvider: { now },
            assistantIncomingHaptic: {
                hapticCounter.count += 1
            }
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()

        chatService.emit(
            Message(
                id: "s_haptic_1",
                role: .assistant,
                content: "one",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )
        for _ in 0..<50 {
            if hapticCounter.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(hapticCounter.count == 1)

        now = now.addingTimeInterval(0.2)
        chatService.emit(
            Message(
                id: "s_haptic_2",
                role: .assistant,
                content: "two",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )
        try await Task.sleep(for: .milliseconds(40))
        #expect(hapticCounter.count == 1)

        now = now.addingTimeInterval(1.0)
        chatService.emit(
            Message(
                id: "s_haptic_3",
                role: .assistant,
                content: "three",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: personalSessionKey
            )
        )
        for _ in 0..<50 {
            if hapticCounter.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(hapticCounter.count == 2)
    }

    @Test("Stream snapshot replaces metadata and falls back when active is removed")
    @MainActor
    func streamSnapshotReplacementFallback() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: adminSessionKey, displayName: "Admin", kind: "global_dm", orderIndex: 1, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(adminSessionKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        viewModel.setActiveSessionKeyForTesting(adminSessionKey)
        #expect(viewModel.activeSessionKey == adminSessionKey)

        chatService.emitServiceEvent(.streamSnapshot([
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]))
        try await Task.sleep(for: .milliseconds(40))

        #expect(viewModel.orderedSessionKeys == [personalSessionKey])
        #expect(viewModel.activeSessionKey == personalSessionKey)
    }

    @Test("Relaunch restores previously active non-default stream")
    @MainActor
    func relaunchRestoresPreviouslyActiveStream() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")

        let streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: adminSessionKey, displayName: "Admin", kind: "global_dm", orderIndex: 1, isBuiltIn: true),
        ]

        let firstService = TestChatService()
        firstService.streams = streams
        let firstViewModel = ChatViewModel(
            auth: auth,
            chatService: firstService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )

        await firstViewModel.onAppear()
        firstService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if firstViewModel.orderedSessionKeys.contains(adminSessionKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        firstViewModel.setActiveSessionKeyForTesting(adminSessionKey)
        #expect(firstViewModel.activeSessionKey == adminSessionKey)
        #expect(UserDefaults.standard.string(forKey: "clawline.lastSessionKey.user") == adminSessionKey)
        firstViewModel.onDisappear()

        let secondService = TestChatService()
        secondService.streams = streams
        let secondViewModel = ChatViewModel(
            auth: auth,
            chatService: secondService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { secondViewModel.onDisappear() }

        await secondViewModel.onAppear()
        secondService.emitServiceEvent(.streamSnapshot(streams))
        for _ in 0..<50 {
            if secondViewModel.activeSessionKey == adminSessionKey { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(secondViewModel.activeSessionKey == adminSessionKey)
    }

    @Test("Relaunch prunes cached stream missing from next server snapshot")
    @MainActor
    func relaunchPrunesCachedStreamMissingFromSnapshot() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let staleKey = "agent:main:clawline:user:s_stale1234"

        let firstService = TestChatService()
        firstService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: staleKey, displayName: "Parallelism", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let firstViewModel = ChatViewModel(
            auth: auth,
            chatService: firstService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )

        await firstViewModel.onAppear()
        firstService.emitServiceEvent(.streamSnapshot(firstService.streams))
        for _ in 0..<50 {
            if firstViewModel.stream(for: staleKey) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(firstViewModel.stream(for: staleKey) != nil)
        firstViewModel.onDisappear()

        let secondService = TestChatService()
        secondService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let secondViewModel = ChatViewModel(
            auth: auth,
            chatService: secondService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { secondViewModel.onDisappear() }

        await secondViewModel.onAppear()
        #expect(secondViewModel.stream(for: staleKey) != nil) // Restored from cache before reconciliation.

        secondService.emitServiceEvent(.streamSnapshot(secondService.streams))
        for _ in 0..<50 {
            if secondViewModel.stream(for: staleKey) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(secondViewModel.stream(for: staleKey) == nil)
        #expect(secondViewModel.orderedSessionKeys == [personalSessionKey])
    }

    @Test("Replay message does not resurrect stream pruned by snapshot")
    @MainActor
    func replayDoesNotResurrectPrunedStream() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let staleKey = "agent:main:clawline:user:s_stale1234"

        let firstService = TestChatService()
        firstService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: staleKey, displayName: "Parallelism", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let firstViewModel = ChatViewModel(
            auth: auth,
            chatService: firstService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )

        await firstViewModel.onAppear()
        firstService.emitServiceEvent(.streamSnapshot(firstService.streams))
        for _ in 0..<50 {
            if firstViewModel.stream(for: staleKey) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(firstViewModel.stream(for: staleKey) != nil)
        firstViewModel.onDisappear()

        let secondService = TestChatService()
        secondService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let secondViewModel = ChatViewModel(
            auth: auth,
            chatService: secondService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { secondViewModel.onDisappear() }

        await secondViewModel.onAppear()
        #expect(secondViewModel.stream(for: staleKey) != nil)

        secondService.emitServiceEvent(.streamSnapshot(secondService.streams))
        for _ in 0..<50 {
            if secondViewModel.stream(for: staleKey) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(secondViewModel.stream(for: staleKey) == nil)

        secondService.emit(
            Message(
                id: "s_stale_replay",
                role: .assistant,
                content: "stale replay",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: staleKey
            )
        )
        try await Task.sleep(for: .milliseconds(40))

        #expect(secondViewModel.stream(for: staleKey) == nil)
        #expect(secondViewModel.messages(for: staleKey).isEmpty)
        #expect(secondViewModel.orderedSessionKeys == [personalSessionKey])
    }

    @Test("Incremental stream events update metadata")
    @MainActor
    func incrementalStreamEvents() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        let customKey = "agent:main:clawline:user:s_deadbeef"
        chatService.emitServiceEvent(.streamCreated(
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false)
        ))
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(customKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.orderedSessionKeys.contains(customKey))

        chatService.emitServiceEvent(.streamUpdated(
            makeStreamSession(sessionKey: customKey, displayName: "Research v2", kind: "custom", orderIndex: 1, isBuiltIn: false)
        ))
        var displayName: String?
        for _ in 0..<50 {
            displayName = await MainActor.run { viewModel.stream(for: customKey)?.displayName }
            if displayName == "Research v2" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(displayName == "Research v2")
    }

    @Test("Provider tail plus read state produce user-tail classification in one place")
    @MainActor
    func streamTailStateAndReadStateProduceUserTail() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_deadbeef"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        chatService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: customKey,
                tailState: StreamTailState(lastMessageId: "s_remote_tail", lastMessageRole: .user)
            )
        )
        chatService.emitServiceEvent(
            .streamReadStateUpdated(sessionKey: customKey, lastReadMessageId: "s_remote_tail")
        )
        for _ in 0..<50 {
            if viewModel.streamDotState(for: customKey) == .userTail { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.streamDotState(for: customKey) == .userTail)
    }

    @Test("Popup row dot-state reads invalidate when provider tail state changes")
    @MainActor
    func popupRowDotStateReadInvalidatesWhenTailStateChanges() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_popup_live"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        let invalidation = ObservationFlag()
        let dotStateLookup = StreamDotStateLookup { sessionKey in
            viewModel.streamDotState(for: sessionKey)
        }
        withObservationTracking {
            _ = dotStateLookup(customKey)
        } onChange: {
            Task { @MainActor in
                invalidation.value = true
            }
        }

        chatService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: customKey,
                tailState: StreamTailState(lastMessageId: "s_popup_tail", lastMessageRole: .user)
            )
        )

        for _ in 0..<50 {
            if invalidation.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(invalidation.value)
        #expect(dotStateLookup(customKey) == .userTail)
    }

    @Test("User-tail classification does not require a matching read cursor")
    @MainActor
    func streamTailStateWithoutReadCursorStillProducesUserTail() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_user_tail"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        chatService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: customKey,
                tailState: StreamTailState(lastMessageId: "s_remote_tail", lastMessageRole: .user)
            )
        )

        for _ in 0..<50 {
            if viewModel.streamDotState(for: customKey) == .userTail { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.streamDotState(for: customKey) == .userTail)
    }

    @Test("Tail snapshot clears yellow classification when the server removes that stream state")
    @MainActor
    func streamTailStateSnapshotClearsMissingStreams() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_snapshot_clear"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        chatService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: customKey,
                tailState: StreamTailState(lastMessageId: "s_remote_tail", lastMessageRole: .user)
            )
        )
        chatService.emitServiceEvent(.streamReadStateUpdated(sessionKey: customKey, lastReadMessageId: "s_remote_tail"))
        for _ in 0..<50 {
            if viewModel.streamDotState(for: customKey) == .userTail { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.streamDotState(for: customKey) == .userTail)

        chatService.emitServiceEvent(.streamTailStateSnapshot([:]))
        for _ in 0..<50 {
            if viewModel.streamDotStateBySession[customKey] == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.streamDotStateBySession[customKey] == nil)
        #expect(viewModel.streamDotState(for: customKey) == .inactive)
    }

    @Test("Activating a stream publishes provider read-state for its latest server message")
    @MainActor
    func activatingStreamPublishesReadState() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_c0ffee"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        chatService.emit(
            Message(
                id: "s_publish_read_target",
                role: .assistant,
                content: "hello",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: customKey
            )
        )
        try await Task.sleep(for: .milliseconds(30))

        viewModel.setActiveSessionKeyForTesting(customKey)
        for _ in 0..<50 {
            if chatService.lastPublishedReadState?.lastReadMessageId == "s_publish_read_target" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastPublishedReadState?.sessionKey == customKey)
        #expect(chatService.lastPublishedReadState?.lastReadMessageId == "s_publish_read_target")
        #expect(viewModel.lastReadMessageIdBySession[customKey] == "s_publish_read_target")
    }

    @Test("Activating stream prefers provider tail over stale local transcript")
    @MainActor
    func activatingStreamPrefersProviderTailOverStaleLocalTranscript() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_stale_cache"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        chatService.emit(
            Message(
                id: "s_stale_cached_tail",
                role: .assistant,
                content: "cached",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: customKey
            )
        )
        chatService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: customKey,
                tailState: StreamTailState(lastMessageId: "s_provider_tail", lastMessageRole: .assistant)
            )
        )
        try await Task.sleep(for: .milliseconds(30))

        chatService.lastPublishedReadState = nil
        viewModel.setActiveSessionKeyForTesting(customKey)

        for _ in 0..<50 {
            if chatService.lastPublishedReadState?.lastReadMessageId == "s_provider_tail" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastPublishedReadState?.sessionKey == customKey)
        #expect(chatService.lastPublishedReadState?.lastReadMessageId == "s_provider_tail")
        #expect(viewModel.lastReadMessageIdBySession[customKey] == "s_provider_tail")
    }

    @Test("Active stream assistant arrivals publish updated read-state immediately")
    @MainActor
    func activeStreamIncomingAssistantPublishesReadState() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_active_publish"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        viewModel.setActiveSessionKeyForTesting(customKey)
        chatService.lastPublishedReadState = nil

        chatService.emit(
            Message(
                id: "s_active_publish_target",
                role: .assistant,
                content: "hello",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: customKey
            )
        )

        for _ in 0..<50 {
            if chatService.lastPublishedReadState?.lastReadMessageId == "s_active_publish_target" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastPublishedReadState?.sessionKey == customKey)
        #expect(chatService.lastPublishedReadState?.lastReadMessageId == "s_active_publish_target")
        #expect(viewModel.lastReadMessageIdBySession[customKey] == "s_active_publish_target")
    }

    @Test("Activating unread stream uses server tail state when local transcript is not loaded")
    @MainActor
    func activatingUnreadStreamWithoutLocalTranscriptPublishesTailReadState() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_tail_fallback"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        chatService.emitServiceEvent(
            .streamTailStateUpdated(
                sessionKey: customKey,
                tailState: StreamTailState(lastMessageId: "s_server_tail", lastMessageRole: .assistant)
            )
        )
        chatService.emitServiceEvent(.streamReadStateUpdated(sessionKey: customKey, lastReadMessageId: "s_old_read"))
        for _ in 0..<50 {
            if viewModel.streamDotState(for: customKey) == .unread { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.streamDotState(for: customKey) == .unread)

        chatService.lastPublishedReadState = nil
        viewModel.setActiveSessionKeyForTesting(customKey)

        for _ in 0..<50 {
            if chatService.lastPublishedReadState?.lastReadMessageId == "s_server_tail" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastPublishedReadState?.sessionKey == customKey)
        #expect(chatService.lastPublishedReadState?.lastReadMessageId == "s_server_tail")
        #expect(viewModel.lastReadMessageIdBySession[customKey] == "s_server_tail")
        #expect(viewModel.streamDotState(for: customKey) == .inactive)
    }

    @Test("Track adopts untracked session and preserves it across snapshots")
    @MainActor
    func trackAdoptsUntrackedSessionAcrossSnapshots() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let adoptedKey = "agent:main:clawline:user:s_trackme"
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: adoptedKey,
                displayName: "Tracked Session",
                updatedAt: Date()
            )
        ]

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.untrackedSessionCandidates.map(\.sessionKey) == [adoptedKey] { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.untrackedSessionCandidates.map(\.sessionKey) == [adoptedKey])
        #expect(await viewModel.trackSession(sessionKey: adoptedKey))
        for _ in 0..<50 {
            if viewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.isAdoptedStream(sessionKey: adoptedKey))
        #expect(viewModel.canUntrackStream(sessionKey: adoptedKey))
        #expect(!viewModel.canDeleteStream(sessionKey: adoptedKey))
        #expect(chatService.adoptStreamCallCount == 1)
        #expect(chatService.lastAdoptedSessionKey == adoptedKey)

        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.stream(for: adoptedKey) != nil, viewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.stream(for: adoptedKey) != nil)
        #expect(viewModel.isAdoptedStream(sessionKey: adoptedKey))
    }

    @Test("Adopted gateway session remains sendable when session info stays stream-only")
    @MainActor
    func adoptedGatewaySessionSendBypassesStreamOnlySessionInfo() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let adoptedKey = "agent:main:openclaw:user:s_trackme"
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: adoptedKey,
                displayName: "Tracked Session",
                updatedAt: Date()
            )
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitConnectionState(.connected)
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.untrackedSessionCandidates.map(\.sessionKey) == [adoptedKey] { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await viewModel.trackSession(sessionKey: adoptedKey))
        viewModel.setActiveSessionKeyForTesting(adoptedKey)

        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        chatService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "main",
                sessionKeys: [personalSessionKey]
            )
        ))

        viewModel.inputContent = NSAttributedString(string: "hello adopted")
        viewModel.send()
        for _ in 0..<50 {
            if chatService.lastSentId != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastSessionKey == adoptedKey)
        #expect(!toastManager.debugMessages.contains("This stream is unavailable. Switch streams and try again."))
    }

    @Test("Non-admin users do not fetch or expose Track candidates")
    @MainActor
    func nonAdminUsersDoNotFetchOrExposeTrackCandidates() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        auth.isAdmin = false
        let chatService = TestChatService()
        let toastManager = ToastManager()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: "agent:main:openclaw:user:s_trackme",
                displayName: "Tracked Session",
                updatedAt: Date()
            )
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(50))

        #expect(!viewModel.canUseTrackFeature)
        #expect(viewModel.untrackedSessionCandidates.isEmpty)
        #expect(chatService.fetchTrackableSessionsCallCount == 0)
        #expect(!toastManager.debugMessages.contains(where: { $0.contains("Could not load Track candidates.") }))
    }

    @Test("Track candidates load from provider trackable sessions endpoint")
    @MainActor
    func trackCandidatesLoadFromProviderEndpoint() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let agentSessionKey = "agent:main:openclaw:user:s_tracklocal"
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: agentSessionKey,
                displayName: "OpenClaw Session",
                updatedAt: Date()
            )
        ]

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if viewModel.untrackedSessionCandidates.map(\.sessionKey).contains(agentSessionKey) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.untrackedSessionCandidates.map(\.sessionKey).contains(agentSessionKey))
        #expect(viewModel.canTrackSession(sessionKey: agentSessionKey))
        #expect(await viewModel.trackSession(sessionKey: agentSessionKey))
        #expect(viewModel.isAdoptedStream(sessionKey: agentSessionKey))
    }

    @Test("Session status is fetched for the visible stream")
    @MainActor
    func sessionStatusFetchedForVisibleStream() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "anthropic",
            model: "claude-sonnet-4.6",
            thinkingLevel: "high",
            queueDepth: 1
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let status = viewModel.sessionStatus(for: personalSessionKey)
        #expect(chatService.fetchSessionStatusCallCount > 0)
        #expect(status?.run.state == .running)
        #expect(status?.run.queueDepth == 1)
        #expect(status?.display.provider == "anthropic")
        #expect(status?.display.model == "claude-sonnet-4.6")
        #expect(status?.display.thinkingLevel == "high")
    }

    @Test("Session status refresh keeps incoming auth mode when preserving sticky fields")
    @MainActor
    func sessionStatusRefreshKeepsIncomingAuthModeWhenPreservingStickyFields() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            queueDepth: 0
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.display.thinkingLevel == "high" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: nil,
            authMode: "oauth",
            queueDepth: 0
        )
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.display.authMode == "oauth" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let status = viewModel.sessionStatus(for: personalSessionKey)
        #expect(status?.display.authMode == "oauth")
        #expect(status?.display.thinkingLevel == "high")
    }

    @Test("Selected-session OAuth usage clears windows on authoritative binding failure")
    @MainActor
    func selectedSessionOAuthUsageClearsWindowsOnAuthoritativeBindingFailure() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let freshUsage = SessionStatus.Display.CodexUsage(
            freshness: .fresh,
            fetchedAt: 1_784_000_000_000,
            windows: [
                .init(label: .fiveHour, remainingPercent: 64, resetAt: 1_784_003_600_000),
                .init(label: .week, remainingPercent: 28, resetAt: 1_784_604_800_000),
            ],
            unavailableReason: nil
        )
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.6",
            thinkingLevel: "high",
            authMode: "oauth",
            fastMode: true,
            codexUsage: freshUsage,
            queueDepth: 0
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.t1673.oauthBindingFailure")
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.display.codexUsage?.freshness == .fresh {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let fetchCount = chatService.fetchSessionStatusCallCount
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.6",
            thinkingLevel: "high",
            authMode: "oauth",
            fastMode: true,
            codexUsage: .init(
                freshness: .unavailable,
                fetchedAt: nil,
                windows: [],
                unavailableReason: .accountBindingUnavailable
            ),
            queueDepth: 0
        )
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > fetchCount,
               viewModel.sessionStatus(for: personalSessionKey)?.display.codexUsage?.freshness == .unavailable {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let status = try #require(viewModel.sessionStatus(for: personalSessionKey))
        let usage = try #require(status.display.codexUsage)
        #expect(usage.freshness == .unavailable)
        #expect(usage.windows.isEmpty)
        #expect(usage.unavailableReason == .accountBindingUnavailable)
        #expect(SessionMetadataFooterCell.footerText(for: status)?.hasSuffix(
            "OAUTH  ·  Usage unavailable"
        ) == true)
    }

    @Test("Session control applies typed provider response without chat text")
    @MainActor
    func sessionControlAppliesTypedProviderResponse() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let updatedStatus = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "low",
            fastMode: true,
            queueDepth: 0
        )
        chatService.sessionControlResponse = SessionControlResponse(
            ok: true,
            sessionKey: personalSessionKey,
            action: SessionControlAction.setFastMode.rawValue,
            code: nil,
            message: nil,
            status: updatedStatus,
            capabilities: updatedStatus.capabilities
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        viewModel.applySessionControl(
            sessionKey: personalSessionKey,
            action: .setFastMode,
            enabled: true
        )

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.display.fastMode == true {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastSessionControl?.sessionKey == personalSessionKey)
        #expect(chatService.lastSessionControl?.action == .setFastMode)
        #expect(chatService.lastSessionControl?.enabled == true)
        #expect(chatService.lastSentId == nil)
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.display.fastMode == true)
    }

    @Test("Session control treats ok response without status as success and refreshes")
    @MainActor
    func sessionControlTreatsOkResponseWithoutStatusAsSuccessAndRefreshes() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        chatService.sessionControlResponse = SessionControlResponse(
            ok: true,
            sessionKey: personalSessionKey,
            action: SessionControlAction.setFastMode.rawValue,
            code: nil,
            message: nil,
            status: nil,
            capabilities: nil
        )
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "medium",
            fastMode: true,
            queueDepth: 0
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        viewModel.applySessionControl(
            sessionKey: personalSessionKey,
            action: .setFastMode,
            enabled: true
        )

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.display.fastMode == true {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.lastSessionControl?.action == .setFastMode)
        #expect(chatService.fetchSessionStatusCallCount > 0)
        #expect(viewModel.sessionStatus(for: personalSessionKey)?.display.fastMode == true)
        #expect(toastManager.debugMessages.isEmpty)
    }

    @Test("Session status keeps sticky display metadata until real values arrive")
    @MainActor
    func sessionStatusKeepsStickyDisplayMetadataUntilRealValuesArrive() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "low",
            fastMode: true,
            queueDepth: 1
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.sessionStatusLatestPartial")
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.display.model == "gpt-5.5" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let firstFetchCount = chatService.fetchSessionStatusCallCount
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: nil,
            model: nil,
            thinkingLevel: nil,
            fastMode: nil,
            queueDepth: 0
        )
        let assistantPayload = #"{"type":"message","id":"s_assistant_final","role":"assistant","content":"done","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(personalSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(assistantPayload.utf8))))

        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > firstFetchCount,
               viewModel.sessionStatus(for: personalSessionKey)?.run.state == .idle {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let status = viewModel.sessionStatus(for: personalSessionKey)
        #expect(status?.run.state == .idle)
        #expect(status?.run.queueDepth == 0)
        #expect(status?.display.provider == nil)
        #expect(status?.display.model == "gpt-5.5")
        #expect(status?.display.thinkingLevel == "low")
        #expect(status?.display.fastMode == true)

        let secondFetchCount = chatService.fetchSessionStatusCallCount
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: nil,
            model: "gpt-5.4",
            thinkingLevel: "high",
            fastMode: false,
            queueDepth: 0
        )
        let updatedAssistantPayload = #"{"type":"message","id":"s_assistant_final_2","role":"assistant","content":"done again","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(personalSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(updatedAssistantPayload.utf8))))

        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > secondFetchCount,
               viewModel.sessionStatus(for: personalSessionKey)?.display.model == "gpt-5.4" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let updatedStatus = viewModel.sessionStatus(for: personalSessionKey)
        #expect(updatedStatus?.display.model == "gpt-5.4")
        #expect(updatedStatus?.display.thinkingLevel == "high")
        #expect(updatedStatus?.display.fastMode == false)

        let reasoningFetchCount = chatService.fetchSessionStatusCallCount
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: nil,
            model: nil,
            reasoningLevel: "medium",
            thinkingLevel: nil,
            fastMode: nil,
            queueDepth: 0
        )
        let reasoningAssistantPayload = #"{"type":"message","id":"s_assistant_final_3","role":"assistant","content":"done three","timestamp":1700000000002,"streaming":false,"sessionKey":"\#(personalSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(reasoningAssistantPayload.utf8))))

        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > reasoningFetchCount,
               viewModel.sessionStatus(for: personalSessionKey)?.display.reasoningLevel == "medium" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let reasoningStatus = viewModel.sessionStatus(for: personalSessionKey)
        #expect(reasoningStatus?.display.model == "gpt-5.4")
        #expect(reasoningStatus?.display.thinkingLevel == nil)
        #expect(reasoningStatus?.display.reasoningLevel == "medium")
        #expect(reasoningStatus?.display.fastMode == false)
    }

    @Test("Session status sticky display metadata is keyed per stream")
    @MainActor
    func sessionStatusStickyDisplayMetadataIsKeyedPerStream() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let researchSessionKey = "agent:main:clawline:user:s_research"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: researchSessionKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "low",
            fastMode: true,
            queueDepth: 1
        )
        chatService.sessionStatusBySessionKey[researchSessionKey] = makeSessionStatus(
            sessionKey: researchSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.4",
            thinkingLevel: "high",
            fastMode: false,
            queueDepth: 1
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.sessionStatusPerStreamSticky")
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.display.model == "gpt-5.5" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let researchSeedFetchCount = chatService.fetchSessionStatusCallCount
        let researchSeedPayload = #"{"type":"message","id":"s_research_seed","role":"assistant","content":"seed","timestamp":1700000000000,"streaming":false,"sessionKey":"\#(researchSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(researchSeedPayload.utf8))))

        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > researchSeedFetchCount,
               viewModel.sessionStatus(for: researchSessionKey)?.display.model == "gpt-5.4" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: nil,
            model: nil,
            thinkingLevel: nil,
            fastMode: nil,
            queueDepth: 0
        )
        let personalMissingFetchCount = chatService.fetchSessionStatusCallCount
        let personalMissingPayload = #"{"type":"message","id":"s_personal_missing","role":"assistant","content":"done","timestamp":1700000000001,"streaming":false,"sessionKey":"\#(personalSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(personalMissingPayload.utf8))))

        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > personalMissingFetchCount,
               viewModel.sessionStatus(for: personalSessionKey)?.run.state == .idle {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let personalStatus = viewModel.sessionStatus(for: personalSessionKey)
        let researchStatusAfterPersonalRefresh = viewModel.sessionStatus(for: researchSessionKey)
        #expect(personalStatus?.display.model == "gpt-5.5")
        #expect(personalStatus?.display.thinkingLevel == "low")
        #expect(personalStatus?.display.fastMode == true)
        #expect(researchStatusAfterPersonalRefresh?.display.model == "gpt-5.4")
        #expect(researchStatusAfterPersonalRefresh?.display.thinkingLevel == "high")
        #expect(researchStatusAfterPersonalRefresh?.display.fastMode == false)

        chatService.sessionStatusBySessionKey[researchSessionKey] = makeSessionStatus(
            sessionKey: researchSessionKey,
            state: .idle,
            provider: nil,
            model: "gpt-5.3",
            reasoningLevel: "medium",
            thinkingLevel: nil,
            fastMode: true,
            queueDepth: 0
        )
        let researchUpdateFetchCount = chatService.fetchSessionStatusCallCount
        let researchUpdatePayload = #"{"type":"message","id":"s_research_update","role":"assistant","content":"updated","timestamp":1700000000002,"streaming":false,"sessionKey":"\#(researchSessionKey)","attachments":[]}"#
        chatService.emitLifecycleEvent(.init(epoch: 1, payload: .serverMessage(data: Data(researchUpdatePayload.utf8))))

        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > researchUpdateFetchCount,
               viewModel.sessionStatus(for: researchSessionKey)?.display.model == "gpt-5.3" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let personalStatusAfterResearchUpdate = viewModel.sessionStatus(for: personalSessionKey)
        let researchUpdatedStatus = viewModel.sessionStatus(for: researchSessionKey)
        #expect(personalStatusAfterResearchUpdate?.display.model == "gpt-5.5")
        #expect(personalStatusAfterResearchUpdate?.display.thinkingLevel == "low")
        #expect(personalStatusAfterResearchUpdate?.display.fastMode == true)
        #expect(researchUpdatedStatus?.display.model == "gpt-5.3")
        #expect(researchUpdatedStatus?.display.thinkingLevel == nil)
        #expect(researchUpdatedStatus?.display.reasoningLevel == "medium")
        #expect(researchUpdatedStatus?.display.fastMode == true)
    }

    @Test("Session status refreshes after terminal message error")
    @MainActor
    func sessionStatusRefreshesAfterTerminalMessageError() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .running,
            provider: "openai",
            model: "gpt-5.5",
            thinkingLevel: "high",
            fastMode: true,
            queueDepth: 1
        )
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.sessionStatusTerminalError")
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey)?.run.state == .running {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let firstFetchCount = chatService.fetchSessionStatusCallCount
        chatService.sessionStatusBySessionKey[personalSessionKey] = makeSessionStatus(
            sessionKey: personalSessionKey,
            state: .idle,
            provider: nil,
            model: nil,
            thinkingLevel: nil,
            fastMode: nil,
            queueDepth: 0
        )
        chatService.emitServiceEvent(.messageError(messageId: nil, code: "connection_lost", message: nil))

        for _ in 0..<50 {
            if chatService.fetchSessionStatusCallCount > firstFetchCount,
               viewModel.sessionStatus(for: personalSessionKey)?.run.state == .idle {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let status = viewModel.sessionStatus(for: personalSessionKey)
        #expect(status?.run.state == .idle)
        #expect(status?.display.model == "gpt-5.5")
        #expect(status?.display.thinkingLevel == "high")
        #expect(status?.display.fastMode == true)
    }

    @Test("Track candidates can be refreshed on demand")
    @MainActor
    func trackCandidatesRefreshOnDemand() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        auth.updateAdminStatus(true)
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let agentSessionKey = "agent:main:openclaw:user:s_manualrefresh"
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: agentSessionKey,
                displayName: "Manual Refresh Session",
                updatedAt: Date()
            )
        ]

        viewModel.refreshTrackableSessionsOnDemand()

        for _ in 0..<50 {
            if viewModel.untrackedSessionCandidates.map(\.sessionKey).contains(agentSessionKey) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.fetchTrackableSessionsCallCount == 1)
        #expect(viewModel.untrackedSessionCandidates.map(\.sessionKey).contains(agentSessionKey))
    }

    @Test("Initial trackable sessions load failure is surfaced")
    @MainActor
    func initialTrackableSessionsLoadFailureIsSurfaced() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        chatService.fetchTrackableSessionsError = StreamAPIError(
            code: "trackable_fetch_failed",
            message: "trackable session load failed",
            statusCode: 500
        )
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        for _ in 0..<50 {
            if toastManager.debugMessages.contains("Could not load Track candidates. trackable session load failed") {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(toastManager.debugMessages.contains("Could not load Track candidates. trackable session load failed"))
        #expect(viewModel.untrackedSessionCandidates.isEmpty)
    }

    @Test("Adopted delete removes Clawline linkage without deleting preserved messages")
    @MainActor
    func untrackRemovesLocalLinkOnly() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let adoptedKey = "agent:main:clawline:user:s_untrack"
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: adoptedKey,
                displayName: "Adoptable Session",
                updatedAt: Date()
            )
        ]

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.untrackedSessionCandidates.map(\.sessionKey) == [adoptedKey] { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await viewModel.trackSession(sessionKey: adoptedKey))
        for _ in 0..<50 {
            if viewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        chatService.emit(
            Message(
                id: "s_adopted_1",
                role: .assistant,
                content: "Preserve me",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: adoptedKey
            )
        )
        for _ in 0..<50 {
            if viewModel.messages(for: adoptedKey).last?.content == "Preserve me" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!viewModel.canDeleteStream(sessionKey: adoptedKey))
        #expect(await viewModel.deleteStream(sessionKey: adoptedKey))
        #expect(viewModel.stream(for: adoptedKey) == nil)
        #expect(viewModel.messages(for: adoptedKey).last?.content == "Preserve me")
        #expect(toastManager.toast?.message == "Session untracked.")
        #expect(toastManager.toast?.actionTitle == "Undo")
        #expect(chatService.deleteStreamCallCount == 1)
        #expect(chatService.lastDeletedSessionKey == adoptedKey)

        chatService.emitServiceEvent(.streamDeleted(sessionKey: adoptedKey))

        #expect(viewModel.messages(for: adoptedKey).last?.content == "Preserve me")
    }

    @Test("Undo after adopted delete restores session linkage through track")
    @MainActor
    func untrackUndoRestoresAdoptedSession() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let adoptedKey = "agent:main:clawline:user:s_undo"
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: adoptedKey,
                displayName: "Undo Session",
                updatedAt: Date()
            )
        ]

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.untrackedSessionCandidates.map(\.sessionKey) == [adoptedKey] { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await viewModel.trackSession(sessionKey: adoptedKey))
        for _ in 0..<50 {
            if viewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await viewModel.deleteStream(sessionKey: adoptedKey))
        #expect(viewModel.stream(for: adoptedKey) == nil)
        #expect(toastManager.toast?.actionTitle == "Undo")

        toastManager.performAction()

        for _ in 0..<50 {
            if viewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.isAdoptedStream(sessionKey: adoptedKey))
        #expect(viewModel.stream(for: adoptedKey)?.displayName == "Undo Session")
        #expect(toastManager.toast == nil)
        #expect(chatService.adoptStreamCallCount == 2)
    }

    @Test("Adopted sessions remain renameable while delete stays unavailable")
    @MainActor
    func adoptedSessionsCanBeRenamedWithoutDelete() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.renameReturnedTrackingMode = .serverManaged
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let adoptedKey = "agent:main:clawline:user:s_rename"
        chatService.trackableSessions = [
            TrackableSession(
                sessionKey: adoptedKey,
                displayName: "Rename Me",
                updatedAt: Date()
            )
        ]

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.untrackedSessionCandidates.map(\.sessionKey) == [adoptedKey] { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await viewModel.trackSession(sessionKey: adoptedKey))
        for _ in 0..<50 {
            if viewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.canRenameStream(sessionKey: adoptedKey))
        #expect(!viewModel.canDeleteStream(sessionKey: adoptedKey))
        #expect(viewModel.canUntrackStream(sessionKey: adoptedKey))
        let renamed = await viewModel.renameStream(sessionKey: adoptedKey, displayName: "Renamed")

        #expect(renamed)
        #expect(chatService.renameStreamCallCount == 1)
        #expect(viewModel.stream(for: adoptedKey)?.displayName == "Renamed")
        #expect(viewModel.isAdoptedStream(sessionKey: adoptedKey))
        #expect(viewModel.canUntrackStream(sessionKey: adoptedKey))
        #expect(!viewModel.canDeleteStream(sessionKey: adoptedKey))
    }

    @Test("Server-adopted streams from provider override websocket snapshot without adopted flag")
    @MainActor
    func adoptedSessionsUseServerAdoptedFlagFromSnapshot() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let adoptedKey = "agent:main:clawline:user:s_snapshot"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            StreamSession(
                sessionKey: adoptedKey,
                displayName: "Snapshot Session",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date(),
                trackingMode: .adopted
            )
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(
            .streamSnapshot([
                makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
                makeStreamSession(sessionKey: adoptedKey, displayName: "Snapshot Session", kind: "custom", orderIndex: 1, isBuiltIn: false),
            ])
        )
        for _ in 0..<50 {
            if viewModel.isAdoptedStream(sessionKey: adoptedKey), chatService.fetchStreamsCallCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.fetchStreamsCallCount > 0)
        #expect(viewModel.isAdoptedStream(sessionKey: adoptedKey))
        #expect(viewModel.canUntrackStream(sessionKey: adoptedKey))
        #expect(!viewModel.canDeleteStream(sessionKey: adoptedKey))
    }

    @Test("Adopted session restores as last saved chat on startup")
    @MainActor
    func adoptedSessionRestoresAsLastSavedChat() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let firstService = TestChatService()
        firstService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let firstViewModel = ChatViewModel(
            auth: auth,
            chatService: firstService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )

        let adoptedKey = "agent:main:clawline:user:s_restore"

        await firstViewModel.onAppear()
        firstService.emitServiceEvent(.streamSnapshot(firstService.streams))
        firstService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "dm",
                sessionKeys: [personalSessionKey, adoptedKey]
            )
        ))
        for _ in 0..<50 {
            if firstViewModel.untrackedSessionCandidates.map(\.sessionKey) == [adoptedKey] { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await firstViewModel.trackSession(sessionKey: adoptedKey))
        for _ in 0..<50 {
            if firstViewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        firstViewModel.setActiveSessionKeyForTesting(adoptedKey)
        #expect(firstViewModel.activeSessionKey == adoptedKey)
        try await Task.sleep(for: .milliseconds(80))
        firstViewModel.onDisappear()

        let secondService = TestChatService()
        secondService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let secondViewModel = ChatViewModel(
            auth: auth,
            chatService: secondService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { secondViewModel.onDisappear() }

        await secondViewModel.onAppear()
        secondService.emitServiceEvent(.streamSnapshot(secondService.streams))
        secondService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "dm",
                sessionKeys: [personalSessionKey, adoptedKey]
            )
        ))
        for _ in 0..<50 {
            if secondViewModel.activeSessionKey == adoptedKey, secondViewModel.isAdoptedStream(sessionKey: adoptedKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(secondViewModel.activeSessionKey == adoptedKey)
        #expect(secondViewModel.isAdoptedStream(sessionKey: adoptedKey))
    }

    @Test("Deleting active stream falls back to main stream")
    @MainActor
    func deletingActiveStreamFallsBack() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let customKey = "agent:main:clawline:user:s_ff00ff00"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(customKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        viewModel.setActiveSessionKeyForTesting(customKey)
        #expect(viewModel.activeSessionKey == customKey)

        chatService.emitServiceEvent(.streamDeleted(sessionKey: customKey))
        try await Task.sleep(for: .milliseconds(30))

        #expect(viewModel.activeSessionKey == personalSessionKey)
        #expect(viewModel.stream(for: customKey) == nil)
    }

    @Test("Snapshot removes child stream omitted by server")
    @MainActor
    func snapshotRemovesChildStreamOmittedByServer() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        let customKey = "agent:main:clawline:user:s_11223344"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Research", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        chatService.emit(
            Message(
                id: "s_custom_1",
                role: .assistant,
                content: "Cached custom content",
                timestamp: Date(),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: customKey
            )
        )
        try await Task.sleep(for: .milliseconds(30))

        chatService.emitServiceEvent(.streamSnapshot([
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]))
        try await Task.sleep(for: .milliseconds(40))

        #expect(viewModel.stream(for: customKey) == nil)
    }

    @Test("Create and delete child stream remains consistent")
    @MainActor
    func createDeleteChildStreamFlow() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        let created = await viewModel.createStream(displayName: "Research Flow")
        #expect(created)
        let customKeys = viewModel.orderedSessionKeys.filter { $0 != personalSessionKey }
        #expect(customKeys.count == 1)
        guard let customKey = customKeys.first else { return }

        #expect(viewModel.canDeleteStream(sessionKey: customKey))
        let deleted = await viewModel.deleteStream(sessionKey: customKey)
        #expect(deleted)
        #expect(viewModel.stream(for: customKey) == nil)
        #expect(viewModel.activeSessionKey == personalSessionKey)
    }

    @Test("Create failure can reconcile later via socket streamCreated event")
    @MainActor
    func createFailureLaterSocketReconcile() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        chatService.createStreamError = StreamAPIError(code: "timeout", message: "timeout", statusCode: 504)
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        try await Task.sleep(for: .milliseconds(30))

        let created = await viewModel.createStream(displayName: "Late Create")
        #expect(!created)

        let customKey = "agent:main:clawline:user:s_reconciled"
        chatService.emitServiceEvent(.streamCreated(
            makeStreamSession(sessionKey: customKey, displayName: "Late Create", kind: "custom", orderIndex: 2, isBuiltIn: false)
        ))
        for _ in 0..<50 {
            if viewModel.stream(for: customKey) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.stream(for: customKey) != nil)
    }

    @Test("Delete failure can reconcile later via socket streamDeleted event")
    @MainActor
    func deleteFailureLaterSocketReconcile() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let customKey = "agent:main:clawline:user:s_delayed"
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
            makeStreamSession(sessionKey: customKey, displayName: "Delayed Delete", kind: "custom", orderIndex: 1, isBuiltIn: false),
        ]
        chatService.deleteStreamError = StreamAPIError(code: "timeout", message: "timeout", statusCode: 504)
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.stream(for: customKey) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.stream(for: customKey) != nil)

        let deleted = await viewModel.deleteStream(sessionKey: customKey)
        #expect(!deleted)
        #expect(viewModel.stream(for: customKey) != nil)

        chatService.emitServiceEvent(.streamDeleted(sessionKey: customKey))
        for _ in 0..<50 {
            if viewModel.stream(for: customKey) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.stream(for: customKey) == nil)
    }

    @Test("Delete non-active stream retries through active connection when initially not connected")
    @MainActor
    func deleteNonActiveStreamRetriesThroughActiveConnection() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))

        let created = await viewModel.createStream(displayName: "Retry Delete")
        #expect(created)
        let customKeys = viewModel.orderedSessionKeys.filter { $0 != personalSessionKey }
        #expect(customKeys.count == 1)
        guard let customKey = customKeys.first else { return }

        chatService.deleteStreamErrorSequence = [ProviderChatService.Error.notConnected]

        let connectCountBeforeDelete = chatService.connectCallCount
        let deleted = await viewModel.deleteStream(sessionKey: customKey)

        #expect(deleted)
        #expect(viewModel.stream(for: customKey) == nil)
        #expect(chatService.deleteStreamCallCount == 2)
        #expect(chatService.lastDeletedSessionKey == customKey)
        #expect(chatService.connectCallCount > connectCountBeforeDelete)
    }

    @Test("user_info event updates admin state")
    @MainActor
    func userInfoEventUpdatesAdminState() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let toastManager = ToastManager()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: toastManager,
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear() }

        await viewModel.onAppear()

        chatService.emitServiceEvent(.userInfo(ChatUserInfo(userId: "user", isAdmin: true)))
        for _ in 0..<50 {
            if auth.isAdmin { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(auth.isAdmin)

        chatService.emitServiceEvent(.userInfo(ChatUserInfo(userId: "user", isAdmin: false)))
        for _ in 0..<50 {
            if auth.isAdmin == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(auth.isAdmin == false)
    }

    @Test("activate is idempotent and initializes lifecycle observers once")
    @MainActor
    func activateInitializesObservationOnce() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await viewModel.activate(origin: "test.concurrent.1") }
            group.addTask { await viewModel.activate(origin: "test.concurrent.2") }
            group.addTask { await MainActor.run { viewModel.handleSceneDidBecomeActive() } }
            group.addTask {
                NotificationCenter.default.post(name: Notification.Name("AuthStateDidChange"), object: nil)
            }
        }

        for _ in 0..<50 {
            if viewModel.debugObservationStartupCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.debugObservationStartupCount() == 1)
    }

    @Test("Transient view disappearance does not tear down lifecycle observation")
    @MainActor
    func transientDisappearPreservesLifecycleObservation() async throws {
        resetChatPersistence()
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.prepareForReplacement() }

        await viewModel.activate(origin: "test.transientDisappear")
        for _ in 0..<50 {
            if viewModel.debugObservationStartupCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.debugObservationStartupCount() == 1)

        viewModel.onDisappear(origin: "test.transient")
        chatService.emitConnectionState(.connected)

        var becameConnected = false
        for _ in 0..<100 {
            if viewModel.sendButtonConnectionState == .connected {
                becameConnected = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(becameConnected)
        #expect(viewModel.debugObservationStartupCount() == 1)
    }

    @Test("T105: direct message-store writes stay inside mutation seam")
    func messageStreamDirectWritesStayInsideSeam() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClawlineTests
            .deletingLastPathComponent() // Clawline
            .appendingPathComponent("Clawline/ViewModels/ChatViewModel.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let seamStart = lines.firstIndex(where: { $0.contains("// MARK: - Message Stream Mutation Seam") }),
              let seamEnd = lines[seamStart...].firstIndex(where: { $0.contains("private func handleLifecycleOutput") }) else {
            Issue.record("Unable to locate T105 message stream mutation seam in ChatViewModel.swift")
            return
        }

        let directMutationPatterns = [
            "sessionMessages\\[[^\\]]+\\]\\s*=",
            "sessionMessages\\.removeValue",
            "sessionMessages\\.removeAll\\(",
            "sessionMessages\\s*=\\s*\\[:\\]"
        ]
        let regexes = try directMutationPatterns.map { pattern in
            try NSRegularExpression(pattern: pattern)
        }

        for (idx, line) in lines.enumerated() {
            let isInsideSeam = idx >= seamStart && idx < seamEnd
            let range = NSRange(location: 0, length: (line as NSString).length)
            for (pattern, regex) in zip(directMutationPatterns, regexes) {
                if regex.firstMatch(in: line, range: range) != nil {
                    #expect(isInsideSeam, "Direct message-store mutation pattern '\(pattern)' escaped T105 seam at line \(idx + 1)")
                }
            }
        }

        #expect(!contents.contains("private func setMessages("))
        #expect(!contents.contains("private func appendMessage("))
        #expect(!contents.contains("private func ensureSessionStorage("))
    }

    @Test("T105: server payload overwrites non-server duplicate id")
    @MainActor
    func messageStreamSeamServerWinsDuplicateId() async throws {
        resetChatPersistence()
        let viewModel = makeSeamTestViewModel()
        defer { viewModel.onDisappear() }

        let messageId = "m_duplicate"
        viewModel.debugUpsertMessage(makeTestMessage(id: messageId, content: "local", sessionKey: personalSessionKey))
        viewModel.debugUpsertMessage(
            makeTestMessage(id: messageId, content: "server", sessionKey: personalSessionKey),
            isServer: true
        )

        let messages = viewModel.messages(for: personalSessionKey)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "server")
    }

    @Test("T105: cache restore is gap-fill only")
    @MainActor
    func messageStreamSeamCacheGapFillOnly() async throws {
        resetChatPersistence()
        let viewModel = makeSeamTestViewModel()
        defer { viewModel.onDisappear() }

        viewModel.debugUpsertMessage(makeTestMessage(id: "s_1", content: "live", sessionKey: personalSessionKey), isServer: true)
        viewModel.debugUpsertMessage(makeTestMessage(id: "s_1", content: "stale-cache", sessionKey: personalSessionKey), isCache: true)
        viewModel.debugUpsertMessage(makeTestMessage(id: "s_2", content: "cache-gap", sessionKey: personalSessionKey), isCache: true)

        let messages = viewModel.messages(for: personalSessionKey)
        #expect(messages.map(\.id) == ["s_1", "s_2"])
        #expect(messages.first?.content == "live")
    }

    @Test("T105: duplicate ids are scoped per session")
    @MainActor
    func messageStreamSeamDuplicateIdsAreSessionScoped() async throws {
        resetChatPersistence()
        let viewModel = makeSeamTestViewModel()
        defer { viewModel.onDisappear() }

        let otherSessionKey = "agent:main:clawline:user:s_other"
        viewModel.debugUpsertMessage(makeTestMessage(id: "s_shared", content: "one", sessionKey: personalSessionKey), isServer: true)
        viewModel.debugUpsertMessage(makeTestMessage(id: "s_shared", content: "two", sessionKey: otherSessionKey), isServer: true)

        #expect(viewModel.messages(for: personalSessionKey).map(\.content) == ["one"])
        #expect(viewModel.messages(for: otherSessionKey).map(\.content) == ["two"])
    }

    @Test("T105: clearSessionMessages preserves entry while removeSession removes it")
    @MainActor
    func messageStreamSeamClearVsRemoveSession() async throws {
        resetChatPersistence()
        let chatService = TestChatService()
        let viewModel = makeSeamTestViewModel(chatService: chatService)
        defer { viewModel.onDisappear() }

        let sessionKey = "agent:main:clawline:user:s_clear_remove"
        chatService.setReplayCursor("s_msg", for: sessionKey)
        viewModel.debugUpsertMessage(makeTestMessage(id: "s_msg", content: "payload", sessionKey: sessionKey), isServer: true)
        #expect(viewModel.debugSessionMessageEntryExists(sessionKey))

        viewModel.debugClearSessionMessages(sessionKey)
        #expect(viewModel.debugSessionMessageEntryExists(sessionKey))
        #expect(viewModel.messages(for: sessionKey).isEmpty)
        #expect(chatService.replayCursorSnapshot()[sessionKey] == "s_msg")

        viewModel.debugRemoveSessionMessages(sessionKey)
        #expect(viewModel.debugSessionMessageEntryExists(sessionKey) == false)
        #expect(chatService.replayCursorSnapshot()[sessionKey] == nil)
    }

    @Test("T105: canSend requires active session provisioning")
    @MainActor
    func canSendRequiresActiveSessionProvisioning() async throws {
        resetChatPersistence()
        let chatService = TestChatService()
        chatService.streams = [
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true)
        ]
        let viewModel = makeSeamTestViewModel(chatService: chatService)
        defer { viewModel.onDisappear() }

        await viewModel.activate(origin: "test.t105.canSendProvisioning")
        await viewModel.onAppear()
        try await setConnected(chatService: chatService, viewModel: viewModel)
        chatService.emitServiceEvent(.streamSnapshot(chatService.streams))
        for _ in 0..<50 {
            if viewModel.orderedSessionKeys.contains(personalSessionKey) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        viewModel.setActiveSessionKeyForTesting(personalSessionKey)
        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        viewModel.inputContent = NSAttributedString(string: "blocked until provisioned")
        try await Task.sleep(for: .milliseconds(20))
        #expect(!viewModel.canSend)

        chatService.emitServiceEvent(.sessionInfo(
            SessionInfo(
                userId: "user",
                isAdmin: false,
                dmScope: "dm",
                sessionKeys: [personalSessionKey]
            )
        ))
        try await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.canSend)
    }

    @Test("T105: logout atomically clears message state and dependent cursors")
    @MainActor
    func messageStreamSeamLogoutAtomicClear() async throws {
        resetChatPersistence()
        let chatService = TestChatService()
        let viewModel = makeSeamTestViewModel(chatService: chatService)
        defer { viewModel.onDisappear() }

        let secondarySessionKey = "agent:main:clawline:user:s_logout_secondary"
        viewModel.debugUpsertMessage(makeTestMessage(id: "s_primary", content: "primary", sessionKey: personalSessionKey), isServer: true)
        viewModel.debugUpsertMessage(makeTestMessage(id: "s_secondary", content: "secondary", sessionKey: secondarySessionKey), isServer: true)
        viewModel.logout()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.activeSessionKey.isEmpty)
        #expect(viewModel.uiSelectedSessionKey.isEmpty)
        #expect(viewModel.lastReadMessageIdBySession.isEmpty)
        #expect(viewModel.streamTailStateBySession.isEmpty)
        #expect(viewModel.streamDotStateBySession.isEmpty)
        #expect(viewModel.debugSessionMessageEntryExists(personalSessionKey) == false)
        #expect(viewModel.debugSessionMessageEntryExists(secondarySessionKey) == false)
        #expect(chatService.replayCursorSnapshot().isEmpty)
    }
}

@MainActor
final class TestAuthManager: AuthManaging {
    var isAuthenticated: Bool = false
    var currentUserId: String?
    var token: String?
    var isAdmin: Bool = false

    func storeCredentials(token: String, userId: String) {
        self.token = token
        self.currentUserId = userId
        isAuthenticated = true
    }

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false
        isAdmin = false
    }

    func updateAdminStatus(_ isAdmin: Bool) {
        self.isAdmin = isAdmin
    }

    func refreshAdminStatusFromToken() {}
}
final class TestChatService: ChatServicing {
    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var eventContinuation: AsyncStream<ChatServiceEvent>.Continuation?
    private var lifecycleContinuation: AsyncStream<LifecycleTransportEvent>.Continuation?
    private var bufferedMessages: [Message] = []
    private var bufferedEvents: [ChatServiceEvent] = []
    private var replayCursorBySessionKey: [String: String] = [:]
    private(set) var lastSentAttachments: [WireAttachment] = []
    private(set) var lastSentId: String?
    private(set) var lastSentContent: String?
    private(set) var lastSessionKey: String?
    private(set) var sentIds: [String] = []
    private(set) var lastSentReferences: [MessageReferenceContext] = []
    private(set) var sendCallCount: Int = 0
    var lastPublishedReadState: (sessionKey: String, lastReadMessageId: String)?
    private(set) var connectCallCount: Int = 0
    var isTransportReadyForSend: Bool = false
    var sendError: Swift.Error?
    var sendDelay: Duration?
    var createStreamError: Error?
    var lastCreatePlacement: (harness: String?, model: String?, host: String?, archetype: String?)?
    var deleteStreamError: Error?
    var deleteStreamErrorSequence: [Error] = []
    var fetchTrackableSessionsError: Error?
    var fetchOrgOptionsError: Error?
    var orgOptions = OrgOptions.empty
    private(set) var fetchOrgOptionsCallCount: Int = 0
    var streams: [StreamSession] = []
    var trackableSessions: [TrackableSession] = []
    var sessionStatusBySessionKey: [String: SessionStatus] = [:]
    var sessionControlResponse: SessionControlResponse? = SessionControlResponse(
        ok: true,
        sessionKey: personalSessionKey,
        action: SessionControlAction.cancelCurrentRun.rawValue,
        code: nil,
        message: nil,
        status: nil,
        capabilities: nil
    )
    private(set) var lastSessionControl: (sessionKey: String, action: SessionControlAction, value: String?, enabled: Bool?)?
    private(set) var fetchStreamsCallCount: Int = 0
    private(set) var fetchTrackableSessionsCallCount: Int = 0
    private(set) var fetchSessionStatusCallCount: Int = 0
    private(set) var fetchedSessionStatusKeys: [String] = []
    private(set) var cancelCurrentRunCallCount: Int = 0
    private(set) var lastCancelledSessionKey: String?
    private(set) var lastStartedEpoch: Int?
    private(set) var deleteStreamCallCount: Int = 0
    private(set) var lastDeletedSessionKey: String?
    private(set) var renameStreamCallCount: Int = 0
    private(set) var adoptStreamCallCount: Int = 0
    private(set) var lastAdoptedSessionKey: String?
    var adoptStreamReturnedTrackingMode: StreamSession.TrackingMode = .adopted
    var renameReturnedTrackingMode: StreamSession.TrackingMode?
    var startReplayCount: Int = 0
    var startReplayTruncated = false
    var startHistoryReset = false
    var emitSyncCompleteOnStart: Bool = true

    private(set) lazy var incomingMessages: AsyncStream<Message> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
            bufferedMessages.forEach { continuation.yield($0) }
            bufferedMessages.removeAll()
        }
    }()

    var serverFeatures: [String] = []
    private(set) lazy var connectionState: AsyncStream<ConnectionState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(.disconnected)
        }
    }()

    private(set) lazy var serviceEvents: AsyncStream<ChatServiceEvent> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
            bufferedEvents.forEach { continuation.yield($0) }
            bufferedEvents.removeAll()
        }
    }()

    private(set) lazy var lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent> = {
        AsyncStream { continuation in
            self.lifecycleContinuation = continuation
        }
    }()

    func connect(token: String, lastMessageId: String?) async throws {
        _ = lastMessageId
        connectCallCount += 1
        isTransportReadyForSend = true
        stateContinuation?.yield(.connected)
    }

    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {
        _ = lastMessageId
        _ = token
        connectCallCount += 1
        lastStartedEpoch = epoch
        lifecycleContinuation?.yield(.init(epoch: epoch, payload: .transportOpened))
        lifecycleContinuation?.yield(
            .init(
                epoch: epoch,
                payload: .authResult(
                    success: true,
                    replayCount: startReplayCount,
                    replayTruncated: startReplayTruncated,
                    historyReset: startHistoryReset,
                    failureReason: nil
                )
            )
        )
        if emitSyncCompleteOnStart {
            lifecycleContinuation?.yield(.init(epoch: epoch, payload: .syncComplete))
        }
    }

    func stopConnectionAttempt() {}

    func disconnect() {
        isTransportReadyForSend = false
        stateContinuation?.yield(.disconnected)
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

    func send(id: String,
              content: String,
              attachments: [WireAttachment],
              sessionKey: String?,
              references: [MessageReferenceContext]) async throws {
        sendCallCount += 1
        if let sendError {
            throw sendError
        }
        lastSentId = id
        lastSentContent = content
        lastSentAttachments = attachments
        lastSessionKey = sessionKey
        sentIds.append(id)
        lastSentReferences = references
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
        }
    }

    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {
        // No-op for tests.
    }

    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {
        lastPublishedReadState = (sessionKey, lastReadMessageId)
    }

    func emit(_ message: Message) {
        if message.id.hasPrefix("s_"), !message.streaming {
            replayCursorBySessionKey[message.sessionKey] = message.id
        }
        if let continuation = messageContinuation {
            continuation.yield(message)
        } else {
            bufferedMessages.append(message)
        }
    }

    func emitLifecycleEvent(_ event: LifecycleTransportEvent) {
        lifecycleContinuation?.yield(event)
    }

    func emitConnectionState(_ state: ConnectionState) {
        isTransportReadyForSend = (state == .connected)
        stateContinuation?.yield(state)
        switch state {
        case .connected:
            lifecycleContinuation?.yield(.init(epoch: 1, payload: .transportOpened))
            lifecycleContinuation?.yield(
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
            lifecycleContinuation?.yield(.init(epoch: 1, payload: .syncComplete))
        case .disconnected:
            lifecycleContinuation?.yield(.init(epoch: 1, payload: .transportClosed(reason: .error)))
        default:
            break
        }
    }

    func emitProviderConnectionStateOnly(_ state: ConnectionState) {
        isTransportReadyForSend = (state == .connected)
        stateContinuation?.yield(state)
    }

    func emitServiceEvent(_ event: ChatServiceEvent) {
        if let continuation = eventContinuation {
            continuation.yield(event)
        } else {
            bufferedEvents.append(event)
        }
    }

    func fetchStreams() async throws -> [StreamSession] {
        fetchStreamsCallCount += 1
        return streams
    }

    func fetchTrackableSessions() async throws -> [TrackableSession] {
        fetchTrackableSessionsCallCount += 1
        if let fetchTrackableSessionsError { throw fetchTrackableSessionsError }
        return trackableSessions
    }

    func fetchOrgOptions() async throws -> OrgOptions {
        fetchOrgOptionsCallCount += 1
        if let fetchOrgOptionsError { throw fetchOrgOptionsError }
        return orgOptions
    }

    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus {
        fetchSessionStatusCallCount += 1
        fetchedSessionStatusKeys.append(sessionKey)
        if let status = sessionStatusBySessionKey[sessionKey] {
            return status
        }
        throw StreamAPIError(code: "stream_not_found", message: "not found", statusCode: 404)
    }

    func resetFetchedSessionStatusKeys() {
        fetchedSessionStatusKeys.removeAll()
    }

    func applySessionControl(
        sessionKey: String,
        action: SessionControlAction,
        value: String?,
        enabled: Bool?
    ) async throws -> SessionControlResponse {
        cancelCurrentRunCallCount += action == .cancelCurrentRun ? 1 : 0
        lastCancelledSessionKey = action == .cancelCurrentRun ? sessionKey : lastCancelledSessionKey
        lastSessionControl = (sessionKey, action, value, enabled)
        if let sessionControlResponse {
            return sessionControlResponse
        }
        throw StreamAPIError(code: "unsupported", message: "unsupported", statusCode: 400)
    }

    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        if let createStreamError { throw createStreamError }
        let stream = StreamSession(
            sessionKey: "agent:main:clawline:user:s_\(UUID().uuidString.prefix(8).lowercased())",
            displayName: displayName,
            kind: "custom",
            orderIndex: streams.count,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        streams.append(stream)
        return stream
    }

    func createStream(
        displayName: String,
        idempotencyKey: String,
        harness: String?,
        model: String?,
        host: String?,
        archetype: String?
    ) async throws -> StreamSession {
        lastCreatePlacement = (harness, model, host, archetype)
        return try await createStream(displayName: displayName, idempotencyKey: idempotencyKey)
    }

    func adoptStream(sessionKey: String) async throws -> StreamSession {
        adoptStreamCallCount += 1
        lastAdoptedSessionKey = sessionKey
        if let existing = streams.first(where: { $0.sessionKey == sessionKey }) {
            return existing
        }
        let stream = StreamSession(
            sessionKey: sessionKey,
            displayName: trackableSessions.first(where: { $0.sessionKey == sessionKey })?.displayName ?? sessionKey,
            kind: "custom",
            orderIndex: streams.count,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date(),
            trackingMode: adoptStreamReturnedTrackingMode
        )
        streams.append(stream)
        return stream
    }

    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        renameStreamCallCount += 1
        if let index = streams.firstIndex(where: { $0.sessionKey == sessionKey }) {
            var stream = streams[index]
            stream.displayName = displayName
            if let renameReturnedTrackingMode {
                stream.trackingMode = renameReturnedTrackingMode
            }
            streams[index] = stream
            return stream
        }
        throw StreamAPIError(code: "stream_not_found", message: "not found", statusCode: 404)
    }

    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String {
        deleteStreamCallCount += 1
        lastDeletedSessionKey = sessionKey
        if !deleteStreamErrorSequence.isEmpty {
            let error = deleteStreamErrorSequence.removeFirst()
            throw error
        }
        if let deleteStreamError { throw deleteStreamError }
        streams.removeAll { $0.sessionKey == sessionKey }
        return sessionKey
    }
}

@MainActor
private func resetViewModelForTest(_ viewModel: ChatViewModel, auth: TestAuthManager) async {
    let wasAdmin = auth.isAdmin
    viewModel.onDisappear()
    viewModel.logout()
    auth.storeCredentials(token: "jwt", userId: "user")
    auth.updateAdminStatus(wasAdmin)
    await viewModel.onAppear()
}

@MainActor
private func makeSeamTestViewModel(chatService: TestChatService = TestChatService()) -> ChatViewModel {
    let auth = TestAuthManager()
    auth.storeCredentials(token: "jwt", userId: "user")
    return ChatViewModel(
        auth: auth,
        chatService: chatService,
        settings: SettingsManager(),
        device: TestDevice(),
        uploadService: TestUploadService(),
        toastManager: ToastManager(),
        salientHighlightService: SalientHighlightService()
    )
}

private func makeTestMessage(id: String, content: String, sessionKey: String) -> Message {
    Message(
        id: id,
        role: .assistant,
        content: content,
        timestamp: Date(),
        streaming: false,
        attachments: [],
        deviceId: nil,
        sessionKey: sessionKey
    )
}

@MainActor
private func setConnected(chatService: TestChatService, viewModel: ChatViewModel) async throws {
    chatService.emitConnectionState(.connected)
    for _ in 0..<50 {
        if viewModel.connectionState == .connected { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func setReadyToSend(chatService: TestChatService, viewModel: ChatViewModel) async throws {
    try await setConnected(chatService: chatService, viewModel: viewModel)
    let sessionKeys = Array(
        Set([personalSessionKey, viewModel.activeSessionKey, viewModel.uiSelectedSessionKey] + viewModel.orderedSessionKeys)
            .filter { !$0.isEmpty }
    )
    chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
    chatService.emitServiceEvent(.sessionInfo(
        SessionInfo(
            userId: "user",
            isAdmin: false,
            dmScope: "dm",
            sessionKeys: sessionKeys
        )
    ))
    try await Task.sleep(for: .milliseconds(20))
}

@MainActor
private func emitServerMessage(_ message: Message, via chatService: TestChatService, epoch: Int = 1) throws {
    let payload = ServerMessagePayload(
        id: message.id,
        llmVisibleMessageId: message.llmVisibleMessageId,
        role: message.role,
        sender: message.sender,
        content: message.content,
        timestamp: message.timestamp,
        streaming: message.streaming,
        deviceId: message.deviceId,
        sessionKey: message.sessionKey,
        attachments: message.attachments,
        clientMessageId: message.clientMessageId,
        replyToMessageId: message.replyToMessageId,
        replyToClientMessageId: message.replyToClientMessageId
    )
    let data = try JSONEncoder().encode(payload)
    chatService.emitLifecycleEvent(.init(epoch: epoch, payload: .serverMessage(data: data)))
}

private func requireLastSentId(_ chatService: TestChatService) async throws -> String {
    for _ in 0..<50 {
        if let id = chatService.lastSentId {
            return id
        }
        try await Task.sleep(forDuration: .milliseconds(20))
    }
    return try #require(chatService.lastSentId)
}

@MainActor
private func resetChatPersistence() {
    // ChatViewModel restores per-session message caches and cursors from disk/UserDefaults.
    // Tests must start from a clean slate to avoid cross-test pollution.
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys {
        if key.hasPrefix("clawline.lastServerMessageId.")
            || key.hasPrefix("clawline.lastReadMessageId.")
            || key.hasPrefix("clawline.suppressedCrossChatNotificationEntryKeys.")
            || key.hasPrefix("clawline.replayCursorBySession.v1.")
            || key.hasPrefix("clawline.lastStream")
            || key.hasPrefix("clawline.lastSessionKey")
            || key.hasPrefix("clawline.scrollState.v1.") {
            defaults.removeObject(forKey: key)
        }
    }

    let fileManager = FileManager.default
    guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return
    }
    let directoryURL = baseURL
        .appendingPathComponent("Clawline", isDirectory: true)
        .appendingPathComponent("MessageCache", isDirectory: true)
    try? fileManager.removeItem(at: directoryURL)
    let streamDirectoryURL = baseURL
        .appendingPathComponent("Clawline", isDirectory: true)
        .appendingPathComponent("StreamCache", isDirectory: true)
    try? fileManager.removeItem(at: streamDirectoryURL)
}

@MainActor
private final class TestUploadService: UploadServicing {
    private(set) var uploadedPayloads: [(data: Data, mimeType: String, filename: String?)] = []
    var downloadPayloads: [String: Data] = [:]
    private(set) var downloadedAssetIds: [String] = []
    var uploadDelay: Duration?

    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
        if let uploadDelay {
            try await Task.sleep(for: uploadDelay)
        }
        uploadedPayloads.append((data, mimeType, filename))
        return "asset_\(uploadedPayloads.count - 1)"
    }

    func download(assetId: String) async throws -> Data {
        downloadedAssetIds.append(assetId)
        return downloadPayloads[assetId] ?? Data()
    }
}

// MARK: - Test Helpers

private func makePendingAttachment(dataSize: Int, mimeType: String) -> PendingAttachment {
    let data = Data(repeating: 0xAB, count: dataSize)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
    let image = renderer.image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    return PendingAttachment(
        id: UUID(),
        data: data,
        thumbnail: image,
        mimeType: mimeType,
        filename: nil
    )
}

private func makeSmallJPEGData() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
    let image = renderer.image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    return image.jpegData(compressionQuality: 1) ?? Data()
}

private func makeLargeJPEGData(width: Int = 2_200, height: Int = 2_200) -> Data {
    var seed: UInt32 = 0x157
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
        seed = seed &* 1_664_525 &+ 1_013_904_223
        pixels[index + 1] = UInt8(truncatingIfNeeded: seed >> 16)
        seed = seed &* 1_664_525 &+ 1_013_904_223
        pixels[index + 2] = UInt8(truncatingIfNeeded: seed >> 16)
        pixels[index + 3] = 255
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let data = Data(pixels)
    let provider = CGDataProvider(data: data as CFData)
    let cgImage = provider.flatMap {
        CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: $0,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    return cgImage.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 1) } ?? Data()
}

private func makeAttributedContent(with ids: [UUID]) -> NSAttributedString {
    let mutable = NSMutableAttributedString()
    ids.forEach { id in
        let image = UIImage(systemName: "photo") ?? UIImage()
        let attachment = PendingTextAttachment(id: id, thumbnail: image, accessibilityLabel: "Attachment")
        mutable.append(NSAttributedString(attachment: attachment))
    }
    return mutable
}

private func makeStreamSession(
    sessionKey: String,
    displayName: String,
    kind: String,
    orderIndex: Int,
    isBuiltIn: Bool,
    trackingMode: StreamSession.TrackingMode = .serverManaged
) -> StreamSession {
    StreamSession(
        sessionKey: sessionKey,
        displayName: displayName,
        kind: kind,
        orderIndex: orderIndex,
        isBuiltIn: isBuiltIn,
        createdAt: Date(),
        updatedAt: Date(),
        trackingMode: trackingMode
    )
}

private func makeSessionStatus(
    sessionKey: String,
    state: SessionStatus.Run.State,
    provider: String?,
    model: String?,
    reasoningLevel: String? = nil,
    thinkingLevel: String?,
    authMode: String? = nil,
    fastMode: Bool? = nil,
    codexUsage: SessionStatus.Display.CodexUsage? = nil,
    queueDepth: Int,
    canCancelCurrentRun: Bool = false
) -> SessionStatus {
    SessionStatus(
        sessionKey: sessionKey,
        display: .init(
            model: model,
            fallbackModels: nil,
            provider: provider,
            harness: nil,
            authMode: authMode,
            reasoningLevel: reasoningLevel,
            thinkingLevel: thinkingLevel,
            fastMode: fastMode,
            mode: nil,
            verbosity: nil,
            codexUsage: codexUsage
        ),
        run: .init(
            state: state,
            runId: state == .running ? "run_1" : nil,
            messageId: state == .running ? "c_1" : nil,
            startedAt: state == .running ? 1_700_000_000_000 : nil,
            queueDepth: queueDepth
        ),
        context: .init(available: false, compaction: nil),
        approval: .init(state: nil),
        capabilities: .init(
            cancelCurrentRun: .init(
                supported: canCancelCurrentRun,
                reason: canCancelCurrentRun ? nil : "provider_control_not_available"
            ),
            setModel: .init(supported: false, reason: "provider_control_not_available"),
            setThinking: .init(supported: true, reason: nil),
            setReasoning: .init(supported: false, reason: "provider_control_not_available"),
            setFastMode: .init(supported: true, reason: nil),
            setMode: .init(supported: false, reason: "provider_control_not_available"),
            setVerbosity: .init(supported: false, reason: "provider_control_not_available"),
            canCancelCurrentRun: nil,
            canChangeModel: nil,
            canChangeReasoning: nil,
            canChangeFastMode: nil,
            canChangeVerbosity: nil,
            readOnlyStatus: nil
        ),
        modelCatalog: nil
    )
}

struct TestDevice: DeviceIdentifying {
    let deviceId: String = "device"
}
