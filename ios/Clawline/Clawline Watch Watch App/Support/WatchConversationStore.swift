import Foundation
import Observation

@MainActor
@Observable
final class WatchConversationStore {
    private static var isDebugScenarioEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.environment["WATCH_UI_TEST_SCENARIO"]?.isEmpty == false
            || processInfo.arguments.contains("-WATCH_UI_TEST_SCENARIO")
            || processInfo.arguments.contains { $0.hasPrefix("WATCH_UI_TEST_SCENARIO=") }
    }
    struct Entry: Identifiable, Equatable {
        let id: String
        let role: Message.Role
        let content: String
        let timestamp: Date

        func clipped(to characterLimit: Int) -> Entry {
            guard content.count > characterLimit else { return self }
            return Entry(
                id: id,
                role: role,
                content: String(content.prefix(characterLimit)),
                timestamp: timestamp
            )
        }
    }

    private static let visibleMessageLimit = 10
    private static let visibleCharacterLimit = 500

    private(set) var entriesBySession: [String: [Entry]] = [:]
    private var didBind = false

    func bind(transport: WatchProviderTransport) {
        guard !didBind else { return }
        didBind = true

        guard !Self.isDebugScenarioEnabled else { return }

        Task { [weak self] in
            guard let self else { return }
            for await message in transport.incomingMessages {
                await MainActor.run {
                    self.recordIncoming(message)
                }
            }
        }
    }

    func recordOutgoing(content: String, sessionKey: String?) {
        guard let sessionKey else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        append(
            Entry(
                id: "local_\(UUID().uuidString)",
                role: .user,
                content: trimmed,
                timestamp: Date()
            ),
            sessionKey: sessionKey
        )
    }

    func visibleEntries(for sessionKey: String?) -> [Entry] {
        guard let sessionKey else { return [] }
        let entries = entriesBySession[sessionKey] ?? []
        return trimmed(entries: entries)
    }

    private func recordIncoming(_ message: Message) {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        append(
            Entry(
                id: message.id,
                role: message.role,
                content: trimmed,
                timestamp: message.timestamp
            ),
            sessionKey: message.sessionKey
        )
    }

    private func append(_ entry: Entry, sessionKey: String) {
        var entries = entriesBySession[sessionKey] ?? []
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        if entries.count > 40 {
            entries.removeFirst(entries.count - 40)
        }
        entriesBySession[sessionKey] = entries
    }

    private func trimmed(entries: [Entry]) -> [Entry] {
        let lastTen = Array(entries.suffix(Self.visibleMessageLimit))
        var kept: [Entry] = []
        var totalCharacters = 0

        for entry in lastTen.reversed() {
            let count = entry.content.count
            let remainingCharacters = Self.visibleCharacterLimit - totalCharacters
            guard remainingCharacters > 0 else { break }

            if count > remainingCharacters {
                if kept.isEmpty {
                    kept.append(entry.clipped(to: remainingCharacters))
                }
                break
            }

            kept.append(entry)
            totalCharacters += count
        }

        return kept.reversed()
    }

#if DEBUG
    func debugSeed(entries: [Entry], sessionKey: String) {
        entriesBySession[sessionKey] = entries
    }
#endif
}
