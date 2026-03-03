import Foundation
import Observation

@MainActor
@Observable
final class WatchChannelManager {
    private(set) var streams: [StreamSession] = []
    private(set) var currentSessionKey: String?
    private(set) var unreadSessionKeys: Set<String> = []

    private(set) var engineSessionKey: String?
    private var debounceTask: Task<Void, Never>?

    func bind(transport: WatchProviderTransport) {
        Task { [weak self] in
            guard let self else { return }
            for await event in transport.serviceEvents {
                await MainActor.run {
                    self.apply(event: event)
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await message in transport.incomingMessages {
                await MainActor.run {
                    if message.role == .assistant, message.sessionKey != self.engineSessionKey {
                        self.unreadSessionKeys.insert(message.sessionKey)
                    }
                }
            }
        }

        Task {
            if let fetched = try? await transport.fetchStreams() {
                await MainActor.run {
                    applyStreamSnapshot(fetched)
                }
            }
        }
    }

    func switchBy(delta: Int) {
        guard !streams.isEmpty else { return }

        let activeKey = currentSessionKey ?? streams.first?.sessionKey
        guard let activeKey,
              let currentIndex = streams.firstIndex(where: { $0.sessionKey == activeKey }) else {
            return
        }

        let nextIndex = min(max(currentIndex + delta, 0), streams.count - 1)
        let nextKey = streams[nextIndex].sessionKey
        currentSessionKey = nextKey

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                self?.engineSessionKey = nextKey
                self?.unreadSessionKeys.remove(nextKey)
            }
        }
    }

    func setCurrentSessionKey(_ sessionKey: String) {
        currentSessionKey = sessionKey
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                self?.engineSessionKey = sessionKey
                self?.unreadSessionKeys.remove(sessionKey)
            }
        }
    }

    func currentChannelName() -> String {
        guard let key = currentSessionKey,
              let stream = streams.first(where: { $0.sessionKey == key }) else {
            return "general"
        }
        return stream.displayName
    }

    private func apply(event: ChatServiceEvent) {
        switch event {
        case .streamSnapshot(let snapshot):
            applyStreamSnapshot(snapshot)
        case .streamCreated(let stream):
            var updated = streams
            updated.append(stream)
            applyStreamSnapshot(updated)
        case .streamUpdated(let stream):
            var updated = streams
            if let index = updated.firstIndex(where: { $0.sessionKey == stream.sessionKey }) {
                updated[index] = stream
            }
            applyStreamSnapshot(updated)
        case .streamDeleted(let sessionKey):
            var updated = streams
            updated.removeAll { $0.sessionKey == sessionKey }
            applyStreamSnapshot(updated)
        default:
            break
        }
    }

    private func applyStreamSnapshot(_ snapshot: [StreamSession]) {
        streams = snapshot.sorted { lhs, rhs in
            if lhs.orderIndex == rhs.orderIndex {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.orderIndex < rhs.orderIndex
        }

        guard !streams.isEmpty else {
            currentSessionKey = nil
            engineSessionKey = nil
            unreadSessionKeys.removeAll()
            return
        }

        if let currentSessionKey,
           streams.contains(where: { $0.sessionKey == currentSessionKey }) {
            return
        }

        let firstKey = streams[0].sessionKey
        currentSessionKey = firstKey
        engineSessionKey = firstKey
        unreadSessionKeys.remove(firstKey)
    }
}
