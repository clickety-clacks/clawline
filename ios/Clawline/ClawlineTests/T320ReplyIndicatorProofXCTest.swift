import Foundation
import XCTest
import UIKit
@testable import Clawline

private let t320PersonalSessionKey = SessionKey.clawlineMain(userId: "user")

@MainActor
final class T320ReplyIndicatorProofXCTest: XCTestCase {
    func testTitleBarTapMenuButtonExposesReplyAction() {
        let message = Message(
            id: "s_title_menu",
            role: .assistant,
            content: "Message with a title-area menu.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: t320PersonalSessionKey
        )
        let bubble = makeConfiguredBubble(message: message)
        let button = findSubview(in: bubble) {
            $0.accessibilityIdentifier == "message_bubble_header_menu_button"
        } as? UIButton
        let menuTitles = button?.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []

        XCTAssertEqual(button?.showsMenuAsPrimaryAction, true)
        XCTAssertTrue(menuTitles.contains("Reply…"))
        XCTAssertFalse(menuTitles.contains("Reference message"))
        XCTAssertFalse(menuTitles.contains("Quote message"))
    }

    func testInsertIntoPromptActionKeepsTargetedUserMessageWhenBubbleIsReused() throws {
        let message = Message(
            id: "s_insert_target",
            role: .user,
            content: "Insert this user text.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_050),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: t320PersonalSessionKey
        )
        var insertedMessage: Message?
        let bubble = makeConfiguredBubble(message: message) { insertedMessage = $0 }
        let button = try XCTUnwrap(findSubview(in: bubble) {
            $0.accessibilityIdentifier == "message_bubble_header_menu_button"
        } as? UIButton)
        let insertAction = try XCTUnwrap(button.menu?.children.compactMap { $0 as? UIAction }.first {
            $0.title == "Insert into prompt"
        })

        bubble.prepareForReuse()
        insertAction.performWithSender(nil, target: nil)

        XCTAssertEqual(insertedMessage?.id, message.id)
        XCTAssertEqual(insertedMessage?.content, message.content)
    }

    func testReplyReferenceResolvesEchoedClientVisibleIdentityForTranscriptIndicator() async throws {
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
        XCTAssertEqual(resolvedReplyReference.llmVisibleMessageId, "llm_reference_echo")
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
        XCTAssertEqual(optimisticOutgoing.replyToMessageId, "llm_reply_target")
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
        XCTAssertEqual(outgoing.replyToMessageId, "llm_reply_target")
        XCTAssertEqual(outgoing.replyToClientMessageId, referenced.clientMessageId)

        let outgoingReplyReference = context.viewModel.replyReference(for: outgoing)
        XCTAssertEqual(outgoingReplyReference?.llmVisibleMessageId, "llm_reply_target")
        XCTAssertEqual(outgoingReplyReference?.clientMessageId, referenced.clientMessageId)
        XCTAssertEqual(outgoingReplyReference?.tokenLabel.contains("assistant:"), false)
    }

    func testRemovingReferenceTokenBeforeSubmitRemovesOutgoingContext() async throws {
        let context = try await makeReplyProofContext()
        let referenced = Message(
            id: "s_removed_reference",
            role: .assistant,
            content: "This reference should be removed before send.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_400),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: t320PersonalSessionKey,
            clientMessageId: "c_removed_reference"
        )

        try emitServerMessage(referenced, via: context.chatService)
        _ = await waitForCondition("removed reference target to appear") {
            context.viewModel.messages.contains(where: { $0.id == referenced.id })
        }

        context.viewModel.inputContent = NSAttributedString(string: "Reply without reference")
        _ = context.viewModel.referenceMessageInPrompt(referenced, selectionRange: NSRange(location: 0, length: 0))
        context.viewModel.inputContent = NSAttributedString(string: "Reply without reference")
        context.viewModel.send()

        _ = await waitForCondition("send without reference context") {
            context.chatService.lastSentContent == "Reply without reference"
        }

        XCTAssertTrue(context.chatService.lastSentReferences.isEmpty)
        let outgoing = await MainActor.run { context.viewModel.messages.last }
        XCTAssertNil(outgoing?.replyToMessageId)
        XCTAssertNil(outgoing?.replyToClientMessageId)
    }

}

@MainActor
private func makeConfiguredBubble(
    message: Message,
    onInsertIntoPrompt: ((Message) -> Void)? = nil
) -> MessageBubbleUIKitView {
    let metrics = ChatFlowTheme.Metrics(isCompact: true)
    var streamingState = StreamingTableParseState()
    let presentation = MessagePresentationBuilder.build(
        from: message,
        metrics: metrics,
        streamingState: &streamingState
    )
    let bubble = MessageBubbleUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 1))

    bubble.configure(
        message: message,
        presentation: presentation,
        sizeClass: .short,
        metrics: metrics,
        maxWidth: 320,
        bubbleSizingV2: nil,
        showsHeader: true,
        paddingScale: 1,
        minWidthOverride: 120,
        maxWidthOverride: 320,
        useContinuousCorners: true,
        isDark: false,
        onRequestExpand: nil,
        onRequestLayout: nil,
        onInteractiveCallback: nil,
        onInsertIntoPrompt: onInsertIntoPrompt,
        onReferenceMessage: nil,
        replyReference: nil,
        salientHighlightService: nil
    )
    let measured = bubble.systemLayoutSizeFitting(
        CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
    bubble.frame = CGRect(origin: .zero, size: measured)
    bubble.layoutIfNeeded()
    return bubble
}

@MainActor
private func findSubview(in root: UIView, where predicate: (UIView) -> Bool) -> UIView? {
    if predicate(root) {
        return root
    }
    for subview in root.subviews {
        if let found = findSubview(in: subview, where: predicate) {
            return found
        }
    }
    return nil
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
