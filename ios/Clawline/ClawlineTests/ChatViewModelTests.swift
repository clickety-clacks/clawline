import Foundation
import UIKit
import Testing
@testable import Clawline

private let personalSessionKey = SessionKey.clawlineMain(userId: "user")
private let adminSessionKey = SessionKey.admin

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

        await resetViewModelForTest(viewModel, auth: auth)
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

        viewModel.setActiveSessionKey(adminSessionKey)
        #expect(viewModel.activeSessionKey == adminSessionKey)
        viewModel.inputContent = NSAttributedString(string: "Admin ping")
        chatService.emitConnectionState(.connected)
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
        for _ in 0..<5 {
            viewModel.send()
            for _ in 0..<25 {
                if chatService.lastSessionKey == adminSessionKey { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if chatService.lastSessionKey == adminSessionKey { break }
            // Reassert connected/provisioned state before another retry.
            chatService.emitConnectionState(.connected)
            chatService.emitServiceEvent(.sessionInfo(
                SessionInfo(
                    userId: "user",
                    isAdmin: true,
                    dmScope: "global_dm",
                    sessionKeys: [personalSessionKey, adminSessionKey]
                )
            ))
            viewModel.inputContent = NSAttributedString(string: "Admin ping")
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
        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        try await Task.sleep(for: .milliseconds(20))

        viewModel.inputContent = NSAttributedString(string: "Wait for provisioning")
        viewModel.send()
        try await Task.sleep(for: .milliseconds(40))
        #expect(chatService.lastSentId == nil)

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
        viewModel.setActiveSessionKey(staleKey)

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
        viewModel.setActiveSessionKey(customKey)
        #expect(viewModel.activeSessionKey == customKey)

        chatService.emitServiceEvent(.sessionProvisioningAvailable(true))
        try await Task.sleep(for: .milliseconds(20))

        viewModel.inputContent = NSAttributedString(string: "queued while provisioning")
        viewModel.send()
        try await Task.sleep(for: .milliseconds(30))
        #expect(chatService.lastSentId == nil)

        viewModel.setActiveSessionKey(personalSessionKey)
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

        viewModel.setActiveSessionKey(adminSessionKey)
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
        viewModel.setActiveSessionKey(adminSessionKey)
        #expect(viewModel.activeSessionKey == adminSessionKey)

        chatService.emitServiceEvent(.streamSnapshot([
            makeStreamSession(sessionKey: personalSessionKey, displayName: "Personal", kind: "main", orderIndex: 0, isBuiltIn: true),
        ]))
        try await Task.sleep(for: .milliseconds(40))

        #expect(viewModel.orderedSessionKeys == [personalSessionKey])
        #expect(viewModel.activeSessionKey == personalSessionKey)
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
        viewModel.setActiveSessionKey(customKey)
        #expect(viewModel.activeSessionKey == customKey)

        chatService.emitServiceEvent(.streamDeleted(sessionKey: customKey))
        try await Task.sleep(for: .milliseconds(30))

        #expect(viewModel.activeSessionKey == personalSessionKey)
        #expect(viewModel.stream(for: customKey) == nil)
    }

    @Test("Synthetic child stream remains deletable when snapshot omits it")
    @MainActor
    func syntheticChildStreamStillDeletable() async throws {
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

        #expect(viewModel.stream(for: customKey) != nil)
        #expect(viewModel.canDeleteStream(sessionKey: customKey))

        let deleted = await viewModel.deleteStream(sessionKey: customKey)
        #expect(deleted)
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
    private var bufferedMessages: [Message] = []
    private var bufferedEvents: [ChatServiceEvent] = []
    private(set) var lastSentAttachments: [WireAttachment] = []
    private(set) var lastSentId: String?
    private(set) var lastSessionKey: String?
    var createStreamError: Error?
    var deleteStreamError: Error?
    var streams: [StreamSession] = []

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

    func connect(token: String, lastMessageId: String?) async throws {
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {
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

    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
        uploadedPayloads.append((data, mimeType, filename))
        return "asset_\(uploadedPayloads.count - 1)"
    }

    func download(assetId: String) async throws -> Data {
        Data()
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
