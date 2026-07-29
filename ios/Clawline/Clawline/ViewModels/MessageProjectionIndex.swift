import Foundation

nonisolated enum MessageProjectionBase: Hashable, Sendable {
    case transcript
    case userOnly
}

nonisolated enum MessageProjectionMutation: Sendable {
    case insert(index: Int, message: Message)
    case replace(index: Int, message: Message)
    case remove(index: Int)
    case replaceAll
}

nonisolated struct MessageProjectionBuildOwnership<Key: Hashable & Sendable>: Sendable {
    private var buildIDByKey: [Key: UUID] = [:]

    mutating func begin(for key: Key) -> UUID {
        let buildID = UUID()
        buildIDByKey[key] = buildID
        return buildID
    }

    mutating func cancel(for key: Key) {
        buildIDByKey.removeValue(forKey: key)
    }

    mutating func finish(for key: Key, buildID: UUID) -> Bool {
        guard buildIDByKey[key] == buildID else { return false }
        buildIDByKey.removeValue(forKey: key)
        return true
    }

    mutating func cancelAll() {
        buildIDByKey.removeAll()
    }
}

nonisolated struct BoundedMessageWindow: Equatable, Sendable {
    let lowerBound: Int
    let upperBound: Int
    let totalCount: Int

    var range: Range<Int> { lowerBound ..< upperBound }
    var reachesTail: Bool { upperBound == totalCount }

    static func tail(totalCount: Int, limit: Int) -> BoundedMessageWindow {
        let total = max(0, totalCount)
        let lower = max(0, total - max(0, limit))
        return BoundedMessageWindow(lowerBound: lower, upperBound: total, totalCount: total)
    }

    static func updating(
        previous: BoundedMessageWindow?,
        totalCount: Int,
        limit: Int,
        followsTail: Bool
    ) -> BoundedMessageWindow {
        let total = max(0, totalCount)
        let boundedLimit = max(0, limit)
        guard total > 0 else { return tail(totalCount: 0, limit: boundedLimit) }
        guard let previous, !followsTail, previous.lowerBound < total else {
            return tail(totalCount: total, limit: boundedLimit)
        }
        let lower = min(previous.lowerBound, max(0, total - 1))
        return BoundedMessageWindow(
            lowerBound: lower,
            upperBound: min(total, lower + boundedLimit),
            totalCount: total
        )
    }

    static func containing(targetIndex: Int, totalCount: Int, limit: Int) -> BoundedMessageWindow {
        let total = max(0, totalCount)
        guard total > 0 else { return tail(totalCount: 0, limit: limit) }
        let boundedLimit = max(0, limit)
        let target = max(0, min(targetIndex, total - 1))
        let lower = max(0, min(target - (boundedLimit / 2), total - boundedLimit))
        return BoundedMessageWindow(
            lowerBound: lower,
            upperBound: min(total, lower + boundedLimit),
            totalCount: total
        )
    }

    func shifted(older: Bool, limit: Int) -> BoundedMessageWindow {
        let boundedLimit = max(0, limit)
        let distance = max(1, boundedLimit / 2)
        let lower = older
            ? max(0, lowerBound - distance)
            : min(max(0, totalCount - boundedLimit), lowerBound + distance)
        return BoundedMessageWindow(
            lowerBound: lower,
            upperBound: min(totalCount, lower + boundedLimit),
            totalCount: totalCount
        )
    }
}

nonisolated struct MessageProjectionSnapshot: Sendable {
    let revision: Int
    let base: MessageProjectionBase
    private let transcript: [Message]
    private let transcriptIndices: [Int]?
    private let transcriptIndexByMessageId: [String: Int]

    init(
        revision: Int,
        base: MessageProjectionBase,
        transcript: [Message],
        transcriptIndices: [Int]?,
        transcriptIndexByMessageId: [String: Int]
    ) {
        self.revision = revision
        self.base = base
        self.transcript = transcript
        self.transcriptIndices = transcriptIndices
        self.transcriptIndexByMessageId = transcriptIndexByMessageId
    }

    var count: Int {
        transcriptIndices?.count ?? transcript.count
    }

    var firstMessageId: String? {
        message(at: 0)?.id
    }

    var lastMessageId: String? {
        guard count > 0 else { return nil }
        return message(at: count - 1)?.id
    }

    func containsTranscriptMessage(id: String) -> Bool {
        transcriptIndexByMessageId[id] != nil
    }

    func projectedIndex(of messageId: String) -> Int? {
        guard let transcriptIndex = transcriptIndexByMessageId[messageId] else { return nil }
        guard let transcriptIndices else { return transcriptIndex }
        return transcriptIndices.binarySearch(for: transcriptIndex)
    }

    func message(at projectedIndex: Int) -> Message? {
        guard projectedIndex >= 0, projectedIndex < count else { return nil }
        let transcriptIndex = transcriptIndices?[projectedIndex] ?? projectedIndex
        return transcript[transcriptIndex]
    }

    func messages(in range: Range<Int>) -> [Message] {
        let lower = max(0, min(range.lowerBound, count))
        let upper = max(lower, min(range.upperBound, count))
        guard lower < upper else { return [] }
        if let transcriptIndices {
            return transcriptIndices[lower ..< upper].map { transcript[$0] }
        }
        return Array(transcript[lower ..< upper])
    }

    /// Returns a bounded suffix for incremental arrival notifications. The
    /// caller uses these IDs only for unread/event bookkeeping; switch-time
    /// work must never scan an unbounded transcript tail.
    func messageIds(after messageId: String?, limit: Int = 100) -> [String] {
        guard let messageId, let index = projectedIndex(of: messageId) else { return [] }
        let next = index + 1
        guard next < count else { return [] }
        let upper = min(count, next + max(0, limit))
        return (next ..< upper).compactMap { message(at: $0)?.id }
    }
}

nonisolated struct MessageProjectionIndex: Sendable {
    private(set) var revision: Int
    private(set) var transcript: [Message]
    private(set) var transcriptIndexByMessageId: [String: Int]
    private(set) var userTranscriptIndices: [Int]

    init(messages: [Message] = [], revision: Int = 0) {
        self.revision = revision
        self.transcript = messages
        self.transcriptIndexByMessageId = Dictionary(
            uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
        )
        self.userTranscriptIndices = messages.indices.filter { messages[$0].role == .user }
    }

    mutating func update(
        messages: [Message],
        revision: Int,
        mutation: MessageProjectionMutation = .replaceAll
    ) {
        switch mutation {
        case let .insert(index, message)
            where index == transcript.endIndex && messages.count == transcript.count + 1:
            transcript.append(message)
            transcriptIndexByMessageId[message.id] = index
            if message.role == .user {
                userTranscriptIndices.append(index)
            }
            self.revision = revision
        case let .replace(index, message)
            where transcript.indices.contains(index) && transcript[index].id == message.id:
            let wasUser = transcript[index].role == .user
            transcript[index] = message
            let isUser = message.role == .user
            if wasUser != isUser {
                if wasUser {
                    userTranscriptIndices.removeAll { $0 == index }
                } else {
                    let insertion = userTranscriptIndices.firstIndex { $0 > index } ?? userTranscriptIndices.endIndex
                    userTranscriptIndices.insert(index, at: insertion)
                }
            }
            self.revision = revision
        case let .remove(index) where messages.count == transcript.count - 1 && transcript.indices.contains(index):
            let removed = transcript[index]
            transcript.remove(at: index)
            transcriptIndexByMessageId.removeValue(forKey: removed.id)
            for offset in index..<transcript.count {
                transcriptIndexByMessageId[transcript[offset].id] = offset
            }
            userTranscriptIndices = userTranscriptIndices.compactMap { value in
                if value == index { return nil }
                return value > index ? value - 1 : value
            }
            self.revision = revision
        case let .insert(index, message) where messages.count == transcript.count + 1 && index <= transcript.endIndex:
            transcript.insert(message, at: index)
            for offset in index..<transcript.count {
                transcriptIndexByMessageId[transcript[offset].id] = offset
            }
            userTranscriptIndices = userTranscriptIndices.map { $0 >= index ? $0 + 1 : $0 }
            if message.role == .user {
                let insertion = userTranscriptIndices.firstIndex { $0 > index } ?? userTranscriptIndices.endIndex
                userTranscriptIndices.insert(index, at: insertion)
            }
            self.revision = revision
        case .insert, .replace, .remove, .replaceAll:
            self = MessageProjectionIndex(messages: messages, revision: revision)
        }
    }

    func snapshot(base: MessageProjectionBase) -> MessageProjectionSnapshot {
        MessageProjectionSnapshot(
            revision: revision,
            base: base,
            transcript: transcript,
            transcriptIndices: base == .userOnly ? userTranscriptIndices : nil,
            transcriptIndexByMessageId: transcriptIndexByMessageId
        )
    }

    func searchInput(base: MessageProjectionBase) -> SearchInput {
        SearchInput(
            revision: revision,
            base: base,
            transcript: transcript,
            baseTranscriptIndices: base == .userOnly ? userTranscriptIndices : nil
        )
    }

    nonisolated struct SearchInput: Sendable {
        let revision: Int
        let base: MessageProjectionBase
        let transcript: [Message]
        let baseTranscriptIndices: [Int]?

        func matchingTranscriptIndices(query: String) -> [Int] {
            if let baseTranscriptIndices {
                return baseTranscriptIndices.filter {
                    transcript[$0].content.localizedStandardContains(query)
                }
            }
            return transcript.indices.filter {
                transcript[$0].content.localizedStandardContains(query)
            }
        }
    }
}

private extension Array where Element == Int {
    nonisolated func binarySearch(for value: Int) -> Int? {
        var lower = 0
        var upper = count
        while lower < upper {
            let midpoint = lower + (upper - lower) / 2
            if self[midpoint] == value { return midpoint }
            if self[midpoint] < value {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return nil
    }
}
