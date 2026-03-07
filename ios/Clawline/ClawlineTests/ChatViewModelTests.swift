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
        let placeholderId = await MainActor.run { viewModel.messages.first?.id }
        #expect(placeholderId?.hasPrefix("c_") == true)

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
    private(set) var lastSessionKey: String?
    private(set) var connectCallCount: Int = 0
    var isTransportReadyForSend: Bool = false
    var sendError: Swift.Error?
    var createStreamError: Error?
    var deleteStreamError: Error?
    var deleteStreamErrorSequence: [Error] = []
    var streams: [StreamSession] = []
    private(set) var deleteStreamCallCount: Int = 0
    private(set) var lastDeletedSessionKey: String?

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

    func connect(token: String, activeSessionKey: String?) async throws {
        _ = activeSessionKey
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
                    replayCount: 0,
                    replayTruncated: false,
                    historyReset: false,
                    failureReason: nil
                )
            )
        )
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

    func clearReplayCursors() {
        replayCursorBySessionKey.removeAll()
    }

    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {
        if let sendError {
            throw sendError
        }
        lastSentId = id
        lastSentAttachments = attachments
        lastSessionKey = sessionKey
    }

    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {
        // No-op for tests.
    }

    func emit(_ message: Message) {
        if let continuation = messageContinuation {
            continuation.yield(message)
        } else {
            bufferedMessages.append(message)
        }
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
        case .disconnected:
            lifecycleContinuation?.yield(.init(epoch: 1, payload: .transportClosed(reason: .error)))
        default:
            break
        }
    }

    func emitServiceEvent(_ event: ChatServiceEvent) {
        if let continuation = eventContinuation {
            continuation.yield(event)
        } else {
            bufferedEvents.append(event)
        }
    }

    func fetchStreams() async throws -> [StreamSession] {
        streams
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

    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        if let index = streams.firstIndex(where: { $0.sessionKey == sessionKey }) {
            var stream = streams[index]
            stream.displayName = displayName
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

private struct TestDevice: DeviceIdentifying {
    let deviceId: String = "device"
}
