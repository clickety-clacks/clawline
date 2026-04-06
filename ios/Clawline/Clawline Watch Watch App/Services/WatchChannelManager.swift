import Foundation
import Observation

@MainActor
@Observable
final class WatchChannelManager {
    private(set) var streams: [StreamSession] = []
    private(set) var currentSessionKey: String?
    private(set) var streamDotStateBySession: [String: StreamDotState] = [:]

    private(set) var engineSessionKey: String?
    private var lastServerMessageIdBySession: [String: String] = [:]
    private var lastReadMessageIdBySession: [String: String] = [:]
    private var streamTailStateBySession: [String: StreamTailState] = [:]
    private weak var transport: WatchProviderTransport?
    private var debounceTask: Task<Void, Never>?

    func bind(transport: WatchProviderTransport) {
        self.transport = transport
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
                    if message.id.hasPrefix("s_") {
                        self.lastServerMessageIdBySession[message.sessionKey] = message.id
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
                self?.markSessionRead(nextKey)
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
                self?.markSessionRead(sessionKey)
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
            lastServerMessageIdBySession.removeValue(forKey: sessionKey)
            lastReadMessageIdBySession.removeValue(forKey: sessionKey)
            streamTailStateBySession.removeValue(forKey: sessionKey)
            streamDotStateBySession.removeValue(forKey: sessionKey)
            applyStreamSnapshot(updated)
        case .streamReadStateSnapshot(let snapshot):
            applyStreamReadStateSnapshot(snapshot)
        case .streamReadStateUpdated(let sessionKey, let lastReadMessageId):
            applyStreamReadStateUpdate(sessionKey: sessionKey, lastReadMessageId: lastReadMessageId)
        case .streamTailStateSnapshot(let snapshot):
            applyStreamTailStateSnapshot(snapshot)
        case .streamTailStateUpdated(let sessionKey, let tailState):
            applyStreamTailStateUpdate(sessionKey: sessionKey, tailState: tailState)
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
            streamDotStateBySession.removeAll()
            lastServerMessageIdBySession.removeAll()
            lastReadMessageIdBySession.removeAll()
            streamTailStateBySession.removeAll()
            return
        }

        if let currentSessionKey,
           streams.contains(where: { $0.sessionKey == currentSessionKey }) {
            return
        }

        let firstKey = streams[0].sessionKey
        currentSessionKey = firstKey
        engineSessionKey = firstKey
    }

    private func markSessionRead(_ sessionKey: String) {
        guard let lastReadMessageId = lastServerMessageIdBySession[sessionKey] else { return }
        Task { [weak transport] in
            try? await transport?.publishReadState(sessionKey: sessionKey, lastReadMessageId: lastReadMessageId)
        }
    }

    private func applyStreamReadStateSnapshot(_ snapshot: [String: String]) {
        lastReadMessageIdBySession = snapshot
        for sessionKey in Set(snapshot.keys).union(streamTailStateBySession.keys) {
            recomputeStreamDotState(for: sessionKey)
        }
        for sessionKey in Set(streamDotStateBySession.keys).subtracting(snapshot.keys).subtracting(streamTailStateBySession.keys) {
            streamDotStateBySession.removeValue(forKey: sessionKey)
        }
    }

    private func applyStreamReadStateUpdate(sessionKey: String, lastReadMessageId: String) {
        lastReadMessageIdBySession[sessionKey] = lastReadMessageId
        recomputeStreamDotState(for: sessionKey)
    }

    private func applyStreamTailStateSnapshot(_ snapshot: [String: StreamTailState]) {
        streamTailStateBySession = snapshot
        for sessionKey in Set(snapshot.keys).union(lastReadMessageIdBySession.keys) {
            recomputeStreamDotState(for: sessionKey)
        }
        for sessionKey in Set(streamDotStateBySession.keys).subtracting(snapshot.keys).subtracting(lastReadMessageIdBySession.keys) {
            streamDotStateBySession.removeValue(forKey: sessionKey)
        }
    }

    private func applyStreamTailStateUpdate(sessionKey: String, tailState: StreamTailState) {
        streamTailStateBySession[sessionKey] = tailState
        recomputeStreamDotState(for: sessionKey)
    }

    private func recomputeStreamDotState(for sessionKey: String) {
        guard let tailState = streamTailStateBySession[sessionKey] else {
            streamDotStateBySession.removeValue(forKey: sessionKey)
            return
        }
        let dotState: StreamDotState
        if tailState.lastMessageRole == .user {
            dotState = .userTail
        } else if lastReadMessageIdBySession[sessionKey] != tailState.lastMessageId {
            dotState = .unread
        } else {
            dotState = .inactive
        }
        streamDotStateBySession[sessionKey] = dotState
    }
}
