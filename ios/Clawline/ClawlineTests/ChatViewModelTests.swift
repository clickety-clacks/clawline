import Foundation
import UIKit
import Testing
@testable import Clawline

private let personalSessionKey = SessionKey.clawlineMain(userId: "user")
private let adminSessionKey = SessionKey.admin

@MainActor
private final class HapticCounter {
    var count = 0
}

struct ChatViewModelTests {
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

    @Test("Visible typing prompt cancellation requires active typing state")
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

        await viewModel.onAppear()
        try await setReadyToSend(chatService: chatService, viewModel: viewModel)
        for _ in 0..<50 {
            if viewModel.sessionStatus(for: personalSessionKey) != nil { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }

        #expect(viewModel.canCancelCurrentPrompt == true)
        #expect(viewModel.canCancelCurrentPrompt(in: personalSessionKey) == true)
        #expect(viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) == false)

        chatService.emitServiceEvent(.typingStateChanged(isTyping: true, sessionKey: personalSessionKey))
        for _ in 0..<50 {
            if viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) == true)

        chatService.emitServiceEvent(.typingStateChanged(isTyping: false, sessionKey: personalSessionKey))
        for _ in 0..<50 {
            if !viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) { break }
            try await Task.sleep(forDuration: .milliseconds(20))
        }
        #expect(viewModel.canCancelCurrentPrompt(in: personalSessionKey) == true)
        #expect(viewModel.canCancelVisibleTypingPrompt(in: personalSessionKey) == false)
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
}

@MainActor
private final class TestAuthManager: AuthManaging {
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
private final class TestChatService: ChatServicing {
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
    var lastPublishedReadState: (sessionKey: String, lastReadMessageId: String)?
    private(set) var connectCallCount: Int = 0
    var isTransportReadyForSend: Bool = false
    var sendError: Swift.Error?
    var createStreamError: Error?
    var deleteStreamError: Error?
    var deleteStreamErrorSequence: [Error] = []
    var fetchTrackableSessionsError: Error?
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
    private(set) var cancelCurrentRunCallCount: Int = 0
    private(set) var lastCancelledSessionKey: String?
    private(set) var deleteStreamCallCount: Int = 0
    private(set) var lastDeletedSessionKey: String?
    private(set) var renameStreamCallCount: Int = 0
    private(set) var adoptStreamCallCount: Int = 0
    private(set) var lastAdoptedSessionKey: String?
    var adoptStreamReturnedTrackingMode: StreamSession.TrackingMode = .adopted
    var renameReturnedTrackingMode: StreamSession.TrackingMode?
    var startReplayCount: Int = 0
    var startHistoryReset = false
    var emitSyncCompleteOnStart: Bool = true

    private(set) lazy var incomingMessages: AsyncStream<Message> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
            bufferedMessages.forEach { continuation.yield($0) }
            bufferedMessages.removeAll()
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
        lifecycleContinuation?.yield(.init(epoch: epoch, payload: .transportOpened))
        lifecycleContinuation?.yield(
            .init(
                epoch: epoch,
                payload: .authResult(
                    success: true,
                    replayCount: startReplayCount,
                    replayTruncated: false,
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

    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {
        if let sendError {
            throw sendError
        }
        lastSentId = id
        lastSentContent = content
        lastSentAttachments = attachments
        lastSessionKey = sessionKey
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

    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus {
        fetchSessionStatusCallCount += 1
        if let status = sessionStatusBySessionKey[sessionKey] {
            return status
        }
        throw StreamAPIError(code: "stream_not_found", message: "not found", statusCode: 404)
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
    chatService.emitServiceEvent(.sessionProvisioningAvailable(false))
    try await Task.sleep(for: .milliseconds(20))
}

@MainActor
private func resetChatPersistence() {
    // ChatViewModel restores per-session message caches and cursors from disk/UserDefaults.
    // Tests must start from a clean slate to avoid cross-test pollution.
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys {
        if key.hasPrefix("clawline.lastServerMessageId.")
            || key.hasPrefix("clawline.lastReadMessageId.")
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

    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
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
    isBuiltIn: Bool
) -> StreamSession {
    StreamSession(
        sessionKey: sessionKey,
        displayName: displayName,
        kind: kind,
        orderIndex: orderIndex,
        isBuiltIn: isBuiltIn,
        createdAt: Date(),
        updatedAt: Date()
    )
}

private func makeSessionStatus(
    sessionKey: String,
    state: SessionStatus.Run.State,
    provider: String?,
    model: String?,
    reasoningLevel: String? = nil,
    thinkingLevel: String?,
    fastMode: Bool? = nil,
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
            reasoningLevel: reasoningLevel,
            thinkingLevel: thinkingLevel,
            fastMode: fastMode,
            mode: nil,
            verbosity: nil
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

private struct TestDevice: DeviceIdentifying {
    let deviceId: String = "device"
}
