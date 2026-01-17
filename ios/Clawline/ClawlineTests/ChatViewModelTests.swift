import Foundation
import UIKit
import Testing
@testable import Clawline

struct ChatViewModelTests {
    @Test("Records last server message id for reconnects")
    @MainActor
    func recordsLastServerMessageId() async throws {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager()
        )

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
                channelType: .personal
            )
        )

        try await Task.sleep(for: .milliseconds(10))

        let snapshot = await MainActor.run { viewModel.debugConnectionSnapshot() }
        #expect(snapshot.lastMessageId == "s_snapshot")
    }

    @Test("Streaming updates replace existing message instead of duplicating")
    @MainActor
    func streamingMessagesUpdateInPlace() async throws {
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
            toastManager: toastManager
        )

        await viewModel.onAppear()

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
                channelType: .personal
            )
        )

        try await Task.sleep(for: .milliseconds(10))
        let firstCount = await MainActor.run { viewModel.messages.count }
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
                channelType: .personal
            )
        )

        try await Task.sleep(for: .milliseconds(10))
        let finalState = await MainActor.run { viewModel.messages }
        #expect(finalState.count == 1)
        #expect(finalState.first?.content == "Final")
        #expect(finalState.first?.streaming == false)
    }

    @Test("Server echoes without device id still replace placeholder")
    @MainActor
    func userEchoWithoutDeviceIdDoesNotDuplicate() async throws {
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
            toastManager: toastManager
        )

        await viewModel.onAppear()
        viewModel.inputContent = NSAttributedString(string: "Hello!")
        viewModel.send()

        try await Task.sleep(for: .milliseconds(10))
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
                deviceId: nil
            )
        )

        try await Task.sleep(for: .milliseconds(10))
        let messages = await MainActor.run { viewModel.messages }
        #expect(messages.count == 1)
        #expect(messages.first?.id == "s_user_echo")
    }

    @Test("Message-level errors annotate placeholders and show toast")
    @MainActor
    func messageErrorsMarkFailedMessages() async throws {
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
            toastManager: toastManager
        )

        await viewModel.onAppear()
        viewModel.inputContent = NSAttributedString(string: "Broken message")
        viewModel.send()

        try await Task.sleep(for: .milliseconds(10))
        guard let messageId = chatService.lastSentId else {
            Issue.record("Expected chat service to capture sent message id")
            return
        }

        chatService.emitServiceEvent(.messageError(messageId: messageId, code: "invalid_message", message: "bad content"))
        try await Task.sleep(for: .milliseconds(10))

        let failure = viewModel.failureMessage(for: messageId)
        #expect(failure == "bad content")
        let lastMessage = await MainActor.run { toastManager.debugLastMessage() }
        #expect(lastMessage == "bad content")
    }

    @Test("Connection interruptions surface alert state")
    @MainActor
    func connectionInterruptionTriggersAlert() async throws {
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
            connectionAlertGracePeriod: .milliseconds(500)
        )

        await viewModel.onAppear()
        chatService.emitConnectionState(.connected)
        try await Task.sleep(for: .milliseconds(10))

        chatService.emitServiceEvent(.connectionInterrupted(reason: "Connection lost"))
        try await Task.sleep(for: .milliseconds(10))

        let alert = await MainActor.run { viewModel.debugConnectionAlert() }
        #expect(alert == .caution)
        let lastMessage = await MainActor.run { toastManager.debugLastMessage() }
        #expect(lastMessage == "Connection lost")
    }

    @Test("canSend becomes true when attachments exist even without text")
    @MainActor
    func canSendWithAttachmentOnly() {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager()
        )

        let attachment = makePendingAttachment(dataSize: 512, mimeType: "image/png")
        viewModel.attachmentData[attachment.id] = attachment
        viewModel.inputContent = makeAttributedContent(with: [attachment.id])

        #expect(viewModel.canSend)
    }

    @Test("send uploads attachments that require persistence")
    @MainActor
    func sendProcessesAttachments() async throws {
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
            toastManager: ToastManager()
        )

        let inlineAttachment = makePendingAttachment(dataSize: 1024, mimeType: "image/png")
        let fileAttachment = makePendingAttachment(dataSize: 512_000, mimeType: "application/pdf")

        viewModel.attachmentData[inlineAttachment.id] = inlineAttachment
        viewModel.attachmentData[fileAttachment.id] = fileAttachment

        viewModel.inputContent = makeAttributedContent(with: [inlineAttachment.id, fileAttachment.id])

        viewModel.send()
        try await viewModel.sendTask?.value

        #expect(uploadService.uploadedPayloads.count == 2)
        #expect(chatService.lastSentAttachments.count == 2)

        let first = chatService.lastSentAttachments[0]
        let second = chatService.lastSentAttachments[1]

        for attachment in [first, second] {
            switch attachment {
            case .asset(let assetId):
                #expect(assetId.hasPrefix("asset_"))
            default:
                Issue.record("Expected asset attachment")
            }
        }

        #expect(viewModel.attachmentData.isEmpty)
        #expect(viewModel.inputContent.string.isEmpty)
    }

    @Test("removing attachments from the attributed string prunes stored data")
    @MainActor
    func prunesOrphanedAttachments() {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager()
        )

        let pending = makePendingAttachment(dataSize: 1024, mimeType: "image/png")
        viewModel.attachmentData[pending.id] = pending
        viewModel.inputContent = makeAttributedContent(with: [pending.id])
        #expect(viewModel.attachmentData.count == 1)

        viewModel.inputContent = NSAttributedString(string: "hello")
        #expect(viewModel.attachmentData.isEmpty)
    }
    
    @Test("Outbound sends respect active channel selection")
    @MainActor
    func sendUsesActiveChannelType() async throws {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        auth.updateAdminStatus(true)
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager()
        )

        viewModel.setActiveChannel(.admin)
        viewModel.inputContent = NSAttributedString(string: "Admin ping")
        viewModel.send()
        try await Task.sleep(for: .milliseconds(10))

        #expect(chatService.lastChannelType == .admin)
    }

    @Test("Incoming messages route to matching channel")
    @MainActor
    func incomingMessagesRoutePerChannel() async throws {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        auth.updateAdminStatus(true)
        let chatService = TestChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: TestUploadService(),
            toastManager: ToastManager()
        )

        await viewModel.onAppear()

        let adminMessage = Message(
            id: "s_admin",
            role: .assistant,
            content: "Admin hello",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            channelType: .admin
        )

        chatService.emit(adminMessage)
        try await Task.sleep(for: .milliseconds(10))

        #expect(viewModel.messages.isEmpty)
        viewModel.setActiveChannel(.admin)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.id == "s_admin")
    }

    @Test("user_info event updates admin state and surfaces toast")
    @MainActor
    func userInfoEventUpdatesAdminState() async throws {
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
            toastManager: toastManager
        )

        await viewModel.onAppear()

        chatService.emitServiceEvent(.userInfo(ChatUserInfo(userId: "user", isAdmin: true)))
        try await Task.sleep(for: .milliseconds(10))

        #expect(auth.isAdmin)
        let unlockToast = await MainActor.run { toastManager.debugLastMessage() }
        #expect(unlockToast == "Admin channel unlocked")

        chatService.emitServiceEvent(.userInfo(ChatUserInfo(userId: "user", isAdmin: false)))
        try await Task.sleep(for: .milliseconds(10))
        #expect(auth.isAdmin == false)
        let revokeToast = await MainActor.run { toastManager.debugLastMessage() }
        #expect(revokeToast == "Admin access revoked")
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
}

private final class TestChatService: ChatServicing {
    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var eventContinuation: AsyncStream<ChatServiceEvent>.Continuation?
    private var bufferedMessages: [Message] = []
    private(set) var lastSentAttachments: [WireAttachment] = []
    private(set) var lastSentId: String?
    private(set) var lastChannelType: ChatChannelType?

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
        }
    }()

    func connect(token: String, lastMessageId: String?) async throws {
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(id: String, content: String, attachments: [WireAttachment], channelType: ChatChannelType) async throws {
        lastSentId = id
        lastSentAttachments = attachments
        lastChannelType = channelType
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
        eventContinuation?.yield(event)
    }
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

private struct TestDevice: DeviceIdentifying {
    let deviceId: String = "device"
}
