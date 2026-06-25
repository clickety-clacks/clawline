import XCTest
@testable import Clawline

final class TranscriptServerTailOrderingXCTests: XCTestCase {
    func testLatestServerMessageUsesTimestampNotVisualOrder() {
        let assistantForPromptA = transcriptMessage(
            id: "s_assistant_a",
            role: .assistant,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let laterServerUserPrompt = transcriptMessage(
            id: "s_prompt_b",
            role: .user,
            timestamp: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(
            TranscriptServerTailOrdering.latestServerMessageId(from: [assistantForPromptA, laterServerUserPrompt]),
            laterServerUserPrompt.id
        )
    }

    func testLatestServerMessageIgnoresLocalAndSyntheticNoReplyMessages() {
        let localPrompt = transcriptMessage(
            id: "c_prompt",
            role: .user,
            timestamp: Date(timeIntervalSince1970: 30)
        )
        let noReply = transcriptMessage(
            id: "s_no_reply_1",
            role: .assistant,
            timestamp: Date(timeIntervalSince1970: 40)
        )
        let serverAssistant = transcriptMessage(
            id: "s_assistant",
            role: .assistant,
            timestamp: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(
            TranscriptServerTailOrdering.latestServerMessageId(from: [serverAssistant, localPrompt, noReply]),
            serverAssistant.id
        )
    }

    private func transcriptMessage(id: String, role: Message.Role, timestamp: Date) -> Message {
        Message(
            id: id,
            role: role,
            content: id,
            timestamp: timestamp,
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:main"
        )
    }
}
