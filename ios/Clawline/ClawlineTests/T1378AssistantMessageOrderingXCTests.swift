import XCTest
@testable import Clawline

@MainActor
final class T1378AssistantMessageOrderingXCTests: XCTestCase {
    func testCompletedAssistantRepliesStayBeforeLaterUnprocessedPrompts() {
        let viewModel = makeViewModel()
        defer { viewModel.onDisappear() }

        viewModel.debugUpsertMessage(message(id: "c_prompt_a", role: .user, content: "A"))
        viewModel.debugUpsertMessage(message(id: "c_prompt_b", role: .user, content: "B"))
        viewModel.debugUpsertMessage(message(id: "c_prompt_c", role: .user, content: "C"))

        viewModel.debugUpsertMessage(
            message(
                id: "s_assistant_c",
                role: .assistant,
                content: "assistant C",
                replyToClientMessageId: "c_prompt_a"
            ),
            isServer: true
        )
        XCTAssertEqual(
            viewModel.messages(for: sessionKey).map(\.id),
            ["c_prompt_a", "s_assistant_c", "c_prompt_b", "c_prompt_c"]
        )

        viewModel.debugUpsertMessage(
            message(
                id: "s_assistant_d",
                role: .assistant,
                content: "assistant D",
                replyToClientMessageId: "c_prompt_a"
            ),
            isServer: true
        )
        XCTAssertEqual(
            viewModel.messages(for: sessionKey).map(\.id),
            ["c_prompt_a", "s_assistant_c", "s_assistant_d", "c_prompt_b", "c_prompt_c"]
        )
    }

    private var sessionKey: String {
        SessionKey.clawlineMain(userId: "user")
    }

    private func makeViewModel() -> ChatViewModel {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        return ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: UploadStub(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
    }

    private func message(
        id: String,
        role: Message.Role,
        content: String,
        replyToClientMessageId: String? = nil
    ) -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: sessionKey,
            replyToClientMessageId: replyToClientMessageId
        )
    }
}

private struct UploadStub: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
        _ = data
        _ = mimeType
        _ = filename
        return "asset"
    }

    func download(assetId: String) async throws -> Data {
        _ = assetId
        return Data()
    }
}
