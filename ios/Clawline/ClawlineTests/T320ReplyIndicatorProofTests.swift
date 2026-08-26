import Foundation
import Testing
import UIKit
@testable import Clawline

private let t320PersonalSessionKey = SessionKey.clawlineMain(userId: "user")

@Suite(.serialized)
@MainActor
struct T320ReplyIndicatorProofTests {
    @Test("Reply reference resolves echoed client-visible identity for transcript indicator")
    func replyReferenceResolvesEchoedClientVisibleIdentityForTranscriptIndicator() async throws {
        let context = try await makeReplyProofContext()
        let referenced = Message(
            id: "s_reference_echo",
            llmVisibleMessageId: "llm_reference_echo",
            role: .assistant,
            content: "This is a very long referenced message that should truncate in the outgoing bubble chip.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: t320PersonalSessionKey,
            clientMessageId: "c_reference_echo"
        )

        try emitServerMessage(referenced, via: context.chatService)
        for _ in 0..<50 {
            let hasReferenced = await MainActor.run {
                context.viewModel.messages.contains(where: { $0.id == referenced.id })
            }
            if hasReferenced {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let replied = Message(
            id: "s_reply_echo",
            role: .user,
            content: "Got it.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_200),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: t320PersonalSessionKey,
            replyToClientMessageId: "c_reference_echo"
        )
        let resolvedReplyReference = try #require(context.viewModel.replyReference(for: replied))

        let tokenLabel = try #require(resolvedReplyReference.tokenLabel)
        #expect(resolvedReplyReference.sessionKey == t320PersonalSessionKey)
        #expect(resolvedReplyReference.llmVisibleMessageId == "llm_reference_echo")
        #expect(resolvedReplyReference.clientMessageId == "c_reference_echo")
        #expect(tokenLabel.hasSuffix("…"))
        #expect(tokenLabel.contains("This is a very long referenced message"))
        #expect(tokenLabel.contains("assistant:") == false)
        #expect(tokenLabel.contains("user:") == false)
        #expect(tokenLabel.contains("tool:") == false)
    }

    @Test("Accepted reply send echoes reply token metadata onto the outgoing user bubble")
    func acceptedReplySendEchoesReplyTokenMetadataOntoOutgoingBubble() async throws {
        let context = try await makeReplyProofContext()
        let referenced = Message(
            id: "s_reply_target",
            llmVisibleMessageId: "llm_reply_target",
            role: .assistant,
            content: "The reply target that should be echoed in the outgoing bubble.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_300),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: t320PersonalSessionKey,
            clientMessageId: "c_reply_target"
        )

        try emitServerMessage(referenced, via: context.chatService)
        for _ in 0..<50 {
            let hasReferenced = await MainActor.run {
                context.viewModel.messages.contains(where: { $0.id == referenced.id })
            }
            if hasReferenced {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        context.viewModel.inputContent = NSAttributedString(string: "Replying now")
        _ = context.viewModel.referenceMessageInPrompt(referenced, selectionRange: NSRange(location: 0, length: 0))
        context.viewModel.send()

        for _ in 0..<50 {
            let hasOutgoing = await MainActor.run { context.viewModel.messages.first != nil }
            if hasOutgoing {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let visibleOutgoing = try #require(await MainActor.run { context.viewModel.messages.first })
        #expect(visibleOutgoing.role == .user)
        #expect(visibleOutgoing.replyToMessageId == "llm_reply_target")
        #expect(visibleOutgoing.replyToClientMessageId == referenced.clientMessageId)

        try emitServerMessage(
            Message(
                id: "s_reply_echo",
                role: .user,
                content: "Replying now",
                timestamp: Date(timeIntervalSince1970: 1_700_000_350),
                streaming: false,
                attachments: [],
                deviceId: "device",
                sessionKey: t320PersonalSessionKey,
                clientMessageId: visibleOutgoing.id
            ),
            via: context.chatService
        )
        for _ in 0..<50 {
            let isEchoed = await MainActor.run { context.viewModel.messages.first?.id == "s_reply_echo" }
            if isEchoed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let outgoing = try #require(await MainActor.run { context.viewModel.messages.first })
        #expect(outgoing.role == .user)
        #expect(outgoing.replyToMessageId == "llm_reply_target")
        #expect(outgoing.replyToClientMessageId == referenced.clientMessageId)
        let outgoingReplyReference = context.viewModel.replyReference(for: outgoing)
        #expect(outgoingReplyReference?.llmVisibleMessageId == "llm_reply_target")
        #expect(outgoingReplyReference?.clientMessageId == referenced.clientMessageId)
        #expect(outgoingReplyReference?.tokenLabel.contains("assistant:") == false)
    }

}

@MainActor
private func makeReplyProofContext() async throws -> (chatService: TestChatService, viewModel: ChatViewModel) {
    resetReplyProofPersistence()
    let auth = TestAuthManager()
    auth.storeCredentials(token: "jwt", userId: "user")
    let chatService = TestChatService()
    let viewModel = ChatViewModel(
        auth: auth,
        chatService: chatService,
        settings: SettingsManager(),
        device: TestDevice(),
        uploadService: T320ProofUploadService(),
        toastManager: ToastManager(),
        salientHighlightService: SalientHighlightService()
    )

    await viewModel.onAppear()
    let personalStream = makeStreamSession(
        sessionKey: t320PersonalSessionKey,
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
                sessionKeys: [t320PersonalSessionKey]
            )
        )
    )
    try await setReadyToSend(chatService: chatService, viewModel: viewModel)
    viewModel.setActiveStream(.personal)
    return (chatService, viewModel)
}

@MainActor
private func resetReplyProofPersistence() {
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
private func setReadyToSend(chatService: TestChatService, viewModel: ChatViewModel) async throws {
    chatService.emitConnectionState(.connected)
    for _ in 0..<50 {
        if viewModel.connectionState == .connected { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    chatService.emitServiceEvent(.sessionProvisioningAvailable(false))
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

@MainActor
private final class T320ProofUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
        "asset_0"
    }

    func download(assetId: String) async throws -> Data {
        Data()
    }
}
