import Foundation

enum TranscriptServerTailOrdering {
    nonisolated static func latestServerMessageId(from messages: [Message]) -> String? {
        messages.enumerated()
            .filter { isReplayCursorEvent($0.element) }
            .max { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }?
            .element
            .id
    }

    private nonisolated static func isReplayCursorEvent(_ message: Message) -> Bool {
        normalizedServerEventID(message.id) != nil && !message.streaming
    }

    private nonisolated static func normalizedServerEventID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("s_"), trimmed.count > 2 else { return nil }
        guard !trimmed.hasPrefix("s_no_reply_") else { return nil }
        return trimmed
    }
}
