import XCTest
@testable import Clawline

@MainActor
final class T1379DaySeparatorChronologyXCTests: XCTestCase {
    func testLateOlderMessagesStayBeforeCurrentDayTranscriptMessages() {
        let viewModel = makeViewModel()
        defer { viewModel.onDisappear() }

        viewModel.debugUpsertMessage(message(id: "s_today_0008", content: "today 12:08", timestamp: today0008), isServer: true)
        viewModel.debugUpsertMessage(message(id: "s_today_0009", content: "today 12:09", timestamp: today0009), isServer: true)
        viewModel.debugUpsertMessage(message(id: "s_june_19", content: "June 19", timestamp: june19), isServer: true)

        XCTAssertEqual(
            viewModel.messages(for: sessionKey).map(\.id),
            ["s_june_19", "s_today_0008", "s_today_0009"]
        )
    }

    func testLateOlderMessagesDoNotBreakAssistantReplyAdjacency() {
        let viewModel = makeViewModel()
        defer { viewModel.onDisappear() }

        viewModel.debugUpsertMessage(message(id: "c_prompt_a", role: .user, content: "A", timestamp: today0008))
        viewModel.debugUpsertMessage(message(id: "c_prompt_b", role: .user, content: "B", timestamp: today0009))
        viewModel.debugUpsertMessage(
            message(
                id: "s_assistant_a",
                role: .assistant,
                content: "assistant A",
                timestamp: today0010,
                replyToClientMessageId: "c_prompt_a"
            ),
            isServer: true
        )
        viewModel.debugUpsertMessage(message(id: "s_june_19", content: "June 19", timestamp: june19), isServer: true)

        XCTAssertEqual(
            viewModel.messages(for: sessionKey).map(\.id),
            ["s_june_19", "c_prompt_a", "s_assistant_a", "c_prompt_b"]
        )
    }

    func testDateSeparatorsAttachToChronologicallyOrderedDayGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_750_600_000)
        let messages = [
            message(id: "s_june_19", content: "June 19", timestamp: june19),
            message(id: "s_today_0008", content: "today 12:08", timestamp: today0008),
            message(id: "s_today_0009", content: "today 12:09", timestamp: today0009)
        ]

        let result = MessageFlowCollectionViewController.snapshotDateSeparatorItems(
            from: messages,
            now: now,
            calendar: calendar
        )
        let todaySeparator = DateSeparatorCell.itemID(before: "s_today_0008")

        XCTAssertEqual(
            result.items,
            ["s_june_19", todaySeparator, "s_today_0008", "s_today_0009"]
        )
        XCTAssertNotNil(result.separatorTextByItemID[todaySeparator])
    }

    private var sessionKey: String {
        SessionKey.clawlineMain(userId: "user")
    }

    private var june19: Date { Date(timeIntervalSince1970: 1_750_395_600) }
    private var today0008: Date { Date(timeIntervalSince1970: 1_750_562_880) }
    private var today0009: Date { Date(timeIntervalSince1970: 1_750_562_940) }
    private var today0010: Date { Date(timeIntervalSince1970: 1_750_563_000) }

    private func makeViewModel() -> ChatViewModel {
        let auth = TestAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user")
        return ChatViewModel(
            auth: auth,
            chatService: TestChatService(),
            settings: SettingsManager(),
            device: TestDevice(),
            uploadService: T1379UploadStub(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
    }

    private func message(
        id: String,
        role: Message.Role = .assistant,
        content: String,
        timestamp: Date,
        replyToClientMessageId: String? = nil
    ) -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: sessionKey,
            replyToClientMessageId: replyToClientMessageId
        )
    }
}

private struct T1379UploadStub: UploadServicing {
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
