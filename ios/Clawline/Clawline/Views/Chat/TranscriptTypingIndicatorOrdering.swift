import Foundation

enum TranscriptTypingIndicatorOrdering {
    static func itemIds(
        messageItems: [String],
        messages: [Message],
        typingIndicatorItemId: String,
        activePromptMessageId: String?
    ) -> [String] {
        guard let insertionIndex = insertionIndex(
            messageItems: messageItems,
            messages: messages,
            activePromptMessageId: activePromptMessageId
        ) else {
            return messageItems + [typingIndicatorItemId]
        }

        var itemIds = messageItems
        itemIds.insert(typingIndicatorItemId, at: insertionIndex)
        return itemIds
    }

    private static func insertionIndex(
        messageItems: [String],
        messages: [Message],
        activePromptMessageId: String?
    ) -> Int? {
        guard let activePromptMessageId = activePromptMessageId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activePromptMessageId.isEmpty,
              let activeMessageIndex = messages.firstIndex(where: {
                  $0.id == activePromptMessageId || $0.clientMessageId == activePromptMessageId
              }) else {
            return nil
        }

        var anchorMessageId = messages[activeMessageIndex].id
        for message in messages[(activeMessageIndex + 1)...] {
            if message.role == .user {
                break
            }
            anchorMessageId = message.id
        }

        guard let anchorItemIndex = messageItems.firstIndex(of: anchorMessageId) else {
            return nil
        }
        return messageItems.index(after: anchorItemIndex)
    }
}
