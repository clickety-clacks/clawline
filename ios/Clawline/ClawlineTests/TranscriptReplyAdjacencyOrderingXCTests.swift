import XCTest
@testable import Clawline

final class TranscriptReplyAdjacencyOrderingXCTests: XCTestCase {
    func testAssistantReplyInsertsBeforeQueuedUserPrompt() {
        let promptA = transcriptMessage(id: "c_prompt_a", role: .user)
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)
        let assistantC = transcriptMessage(
            id: "s_assistant_c",
            role: .assistant,
            replyToClientMessageId: promptA.id
        )

        XCTAssertEqual(
            TranscriptReplyAdjacencyOrdering.insertionIndex(for: assistantC, in: [promptA, promptB]),
            1
        )
    }

    func testAssistantReplyContinuesActiveReplyRunBeforeQueuedPrompt() {
        let promptA = transcriptMessage(id: "c_prompt_a", role: .user)
        let assistantC = transcriptMessage(
            id: "s_assistant_c",
            role: .assistant,
            replyToClientMessageId: promptA.id
        )
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)
        let assistantD = transcriptMessage(
            id: "s_assistant_d",
            role: .assistant,
            replyToClientMessageId: promptA.id
        )

        XCTAssertEqual(
            TranscriptReplyAdjacencyOrdering.insertionIndex(for: assistantD, in: [promptA, assistantC, promptB]),
            2
        )
    }

    func testAssistantReplyCanAnchorToServerReplyReference() {
        let promptA = transcriptMessage(id: "s_prompt_a", role: .user, clientMessageId: "c_prompt_a")
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)
        let assistantC = transcriptMessage(
            id: "s_assistant_c",
            role: .assistant,
            replyToMessageId: promptA.id
        )

        XCTAssertEqual(
            TranscriptReplyAdjacencyOrdering.insertionIndex(for: assistantC, in: [promptA, promptB]),
            1
        )
    }

    func testNonReplyAssistantKeepsTailAppendFallback() {
        let promptA = transcriptMessage(id: "c_prompt_a", role: .user)
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)
        let assistant = transcriptMessage(id: "s_assistant", role: .assistant)

        XCTAssertNil(TranscriptReplyAdjacencyOrdering.insertionIndex(for: assistant, in: [promptA, promptB]))
    }

    private func transcriptMessage(
        id: String,
        role: Message.Role,
        clientMessageId: String? = nil,
        replyToMessageId: String? = nil,
        replyToClientMessageId: String? = nil
    ) -> Message {
        Message(
            id: id,
            role: role,
            content: id,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:main",
            clientMessageId: clientMessageId,
            replyToMessageId: replyToMessageId,
            replyToClientMessageId: replyToClientMessageId
        )
    }
}
