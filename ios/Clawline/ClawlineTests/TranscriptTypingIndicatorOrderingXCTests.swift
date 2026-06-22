import XCTest
@testable import Clawline

final class TranscriptTypingIndicatorOrderingXCTests: XCTestCase {
    func testTypingIndicatorFollowsActiveAssistantTurnBeforeQueuedPrompt() {
        let promptA = transcriptMessage(id: "c_prompt_a", role: .user)
        let assistantC = transcriptMessage(id: "s_assistant_c", role: .assistant)
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)

        XCTAssertEqual(
            TranscriptTypingIndicatorOrdering.itemIds(
                messageItems: [promptA.id, assistantC.id, promptB.id],
                messages: [promptA, assistantC, promptB],
                typingIndicatorItemId: "typing",
                activePromptMessageId: promptA.id
            ),
            [promptA.id, assistantC.id, "typing", promptB.id]
        )

        let assistantD = transcriptMessage(id: "s_assistant_d", role: .assistant)
        XCTAssertEqual(
            TranscriptTypingIndicatorOrdering.itemIds(
                messageItems: [promptA.id, assistantC.id, assistantD.id, promptB.id],
                messages: [promptA, assistantC, assistantD, promptB],
                typingIndicatorItemId: "typing",
                activePromptMessageId: promptA.id
            ),
            [promptA.id, assistantC.id, assistantD.id, "typing", promptB.id]
        )
    }

    func testTerminalActiveTurnMovesTypingIndicatorToNextWaitingPrompt() {
        let promptA = transcriptMessage(id: "c_prompt_a", role: .user)
        let assistantC = transcriptMessage(id: "s_assistant_c", role: .assistant)
        let assistantD = transcriptMessage(id: "s_assistant_d", role: .assistant)
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)

        XCTAssertEqual(
            TranscriptTypingIndicatorOrdering.itemIds(
                messageItems: [promptA.id, assistantC.id, assistantD.id, promptB.id],
                messages: [promptA, assistantC, assistantD, promptB],
                typingIndicatorItemId: "typing",
                activePromptMessageId: promptB.id
            ),
            [promptA.id, assistantC.id, assistantD.id, promptB.id, "typing"]
        )

        let assistantE = transcriptMessage(id: "s_assistant_e", role: .assistant)
        XCTAssertEqual(
            TranscriptTypingIndicatorOrdering.itemIds(
                messageItems: [promptA.id, assistantC.id, assistantD.id, promptB.id, assistantE.id],
                messages: [promptA, assistantC, assistantD, promptB, assistantE],
                typingIndicatorItemId: "typing",
                activePromptMessageId: promptB.id
            ),
            [promptA.id, assistantC.id, assistantD.id, promptB.id, assistantE.id, "typing"]
        )
    }

    func testStaleLowerOrderQueuedEventsDoNotMoveTypingIndicator() {
        let promptA = transcriptMessage(id: "c_prompt_a", role: .user)
        let assistantC = transcriptMessage(id: "s_assistant_c", role: .assistant)
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)

        XCTAssertEqual(
            TranscriptTypingIndicatorOrdering.itemIds(
                messageItems: [promptA.id, assistantC.id, promptB.id],
                messages: [promptA, assistantC, promptB],
                typingIndicatorItemId: "typing",
                activePromptMessageId: promptA.id
            ),
            [promptA.id, assistantC.id, "typing", promptB.id]
        )
    }

    func testQueuedPromptStaysBehindActiveTurnUntilItBecomesActive() {
        let promptA = transcriptMessage(id: "c_prompt_a", role: .user)
        let assistantC = transcriptMessage(id: "s_assistant_c", role: .assistant)
        let assistantD = transcriptMessage(id: "s_assistant_d", role: .assistant)
        let promptB = transcriptMessage(id: "c_prompt_b", role: .user)
        let assistantE = transcriptMessage(id: "s_assistant_e", role: .assistant)

        XCTAssertEqual(
            orderedIds(messages: [promptA, assistantC, promptB], activePrompt: promptA),
            [promptA.id, assistantC.id, "typing", promptB.id]
        )
        XCTAssertEqual(
            orderedIds(messages: [promptA, assistantC, assistantD, promptB], activePrompt: promptA),
            [promptA.id, assistantC.id, assistantD.id, "typing", promptB.id]
        )
        XCTAssertEqual(
            orderedIds(messages: [promptA, assistantC, assistantD, promptB], activePrompt: promptB),
            [promptA.id, assistantC.id, assistantD.id, promptB.id, "typing"]
        )
        XCTAssertEqual(
            orderedIds(messages: [promptA, assistantC, assistantD, promptB, assistantE], activePrompt: promptB),
            [promptA.id, assistantC.id, assistantD.id, promptB.id, assistantE.id, "typing"]
        )
    }

    private func orderedIds(messages: [Message], activePrompt: Message) -> [String] {
        TranscriptTypingIndicatorOrdering.itemIds(
            messageItems: messages.map(\.id),
            messages: messages,
            typingIndicatorItemId: "typing",
            activePromptMessageId: activePrompt.id
        )
    }

    private func transcriptMessage(id: String, role: Message.Role) -> Message {
        Message(
            id: id,
            role: role,
            content: id,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: "agent:main:clawline:user:main"
        )
    }
}
