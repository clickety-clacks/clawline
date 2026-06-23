import Foundation

enum TranscriptReplyAdjacencyOrdering {
    nonisolated static func insertionIndex(for message: Message, in messages: [Message]) -> Int? {
        guard message.role == .assistant else { return nil }
        let replyIds = [
            message.replyToClientMessageId,
            message.replyToMessageId
        ].compactMap(normalizedMessageReferenceID)
        guard !replyIds.isEmpty,
              let promptIndex = messages.firstIndex(where: { existing in
                  replyIds.contains(existing.id) ||
                      existing.clientMessageId.map { replyIds.contains($0) } == true
              }) else {
            return nil
        }

        var insertionIndex = messages.index(after: promptIndex)
        while insertionIndex < messages.endIndex,
              messages[insertionIndex].role != .user {
            insertionIndex = messages.index(after: insertionIndex)
        }
        return insertionIndex
    }

    private nonisolated static func normalizedMessageReferenceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
