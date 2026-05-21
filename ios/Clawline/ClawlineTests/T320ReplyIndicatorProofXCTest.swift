import Foundation
import XCTest
import UIKit
@testable import Clawline

private let t320PersonalSessionKey = SessionKey.clawlineMain(userId: "user")

@MainActor
final class T320ReplyIndicatorProofXCTest: XCTestCase {
    func testReplyReferenceResolvesEchoedClientVisibleIdentityForTranscriptIndicator() async throws {
        let context = try await makeReplyProofContext()
        let referenced = Message(
            id: "s_reference_echo",
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
        _ = await waitForCondition("referenced transcript message to appear") {
            context.viewModel.messages.contains(where: { $0.id == referenced.id })
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

        let resolvedReplyReference = try XCTUnwrap(context.viewModel.replyReference(for: replied))

        XCTAssertEqual(resolvedReplyReference.sessionKey, t320PersonalSessionKey)
        XCTAssertEqual(resolvedReplyReference.messageId, referenced.id)
        XCTAssertEqual(resolvedReplyReference.clientMessageId, "c_reference_echo")
        XCTAssertTrue(resolvedReplyReference.tokenLabel.hasSuffix("…"))
        XCTAssertTrue(resolvedReplyReference.tokenLabel.contains("This is a very long referenced message"))
        XCTAssertEqual(resolvedReplyReference.tokenLabel.contains("assistant:"), false)
        XCTAssertEqual(resolvedReplyReference.tokenLabel.contains("user:"), false)
        XCTAssertEqual(resolvedReplyReference.tokenLabel.contains("tool:"), false)
    }

    func testAcceptedReplySendEchoesReplyTokenMetadataOntoOutgoingBubble() async throws {
        let context = try await makeReplyProofContext()
        let referenced = Message(
            id: "s_reply_target",
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
        _ = await waitForCondition("referenced reply target to appear") {
            context.viewModel.messages.contains(where: { $0.id == referenced.id })
        }

        context.viewModel.inputContent = NSAttributedString(string: "Replying now")
        _ = context.viewModel.referenceMessageInPrompt(referenced, selectionRange: NSRange(location: 0, length: 0))
        context.viewModel.send()

        _ = await waitForCondition("optimistic outgoing reply bubble to appear") {
            context.viewModel.messages.last?.role == .user
        }

        let optimisticOutgoing = await MainActor.run { context.viewModel.messages.last }
        guard let optimisticOutgoing else {
            return XCTFail("Expected optimistic outgoing message bubble")
        }
        XCTAssertEqual(optimisticOutgoing.role, Message.Role.user)
        XCTAssertEqual(optimisticOutgoing.replyToMessageId, referenced.id)
        XCTAssertEqual(optimisticOutgoing.replyToClientMessageId, referenced.clientMessageId)

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
                clientMessageId: optimisticOutgoing.id
            ),
            via: context.chatService
        )
        _ = await waitForCondition("server echoed outgoing reply bubble") {
            context.viewModel.messages.last?.id == "s_reply_echo"
        }

        let outgoing = await MainActor.run { context.viewModel.messages.last }
        guard let outgoing else {
            return XCTFail("Expected echoed outgoing message bubble")
        }
        XCTAssertEqual(outgoing.role, Message.Role.user)
        XCTAssertEqual(outgoing.replyToMessageId, referenced.id)
        XCTAssertEqual(outgoing.replyToClientMessageId, referenced.clientMessageId)

        let outgoingReplyReference = context.viewModel.replyReference(for: outgoing)
        XCTAssertEqual(outgoingReplyReference?.messageId, referenced.id)
        XCTAssertEqual(outgoingReplyReference?.clientMessageId, referenced.clientMessageId)
        XCTAssertEqual(outgoingReplyReference?.tokenLabel.contains("assistant:"), false)
    }
}

@MainActor
private func makeReplyProofContext() async throws -> (chatService: TestChatService, viewModel: ChatViewModel) {
    resetReplyProofPersistence()
    ChatViewModel.resetConnectionOwnershipForTesting()
    let auth = TestAuthManager()
    auth.storeCredentials(token: "jwt", userId: "user")
    let chatService = TestChatService()
    _ = chatService.incomingMessages
    _ = chatService.connectionState
    _ = chatService.serviceEvents
    let viewModel = ChatViewModel(
        auth: auth,
        chatService: chatService,
        settings: SettingsManager(),
        device: TestDevice(),
        uploadService: T320ProofUploadService(),
        toastManager: ToastManager(),
        salientHighlightService: SalientHighlightService()
    )

    await viewModel.activate(origin: "test.t320ReplyIndicatorProof")
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
    for _ in 0..<50 {
        if viewModel.orderedSessionKeys.contains(t320PersonalSessionKey) {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    try await setReadyToSend(chatService: chatService, viewModel: viewModel)
    viewModel.setActiveSessionKeyForTesting(t320PersonalSessionKey)
    for _ in 0..<50 {
        if viewModel.activeSessionKey == t320PersonalSessionKey {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
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

@MainActor
private func waitForCondition(
    _ description: String,
    timeoutMillis: UInt64 = 500,
    pollMillis: UInt64 = 10,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let iterations = max(1, Int(timeoutMillis / pollMillis))
    for _ in 0..<iterations {
        if await MainActor.run(body: condition) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(pollMillis))
    }
    XCTFail("Timed out waiting for \(description)")
    return false
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
