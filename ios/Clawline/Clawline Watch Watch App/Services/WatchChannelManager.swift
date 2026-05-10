import Foundation
import Observation

@MainActor
@Observable
final class WatchChannelManager {
    private static var isDebugScenarioEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
#if WATCH_UI_SCENARIO_DIRECT || WATCH_UI_SCENARIO_RELAY || WATCH_UI_SCENARIO_RECONNECTING || WATCH_UI_SCENARIO_DISCONNECTED
        return true
#else
        return processInfo.environment["WATCH_UI_TEST_SCENARIO"]?.isEmpty == false
            || processInfo.arguments.contains("-WATCH_UI_TEST_SCENARIO")
            || processInfo.arguments.contains { $0.hasPrefix("WATCH_UI_TEST_SCENARIO=") }
#endif
    }
    enum StreamLoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var streams: [StreamSession] = []
    private(set) var currentSessionKey: String?
    private(set) var unreadSessionKeys: Set<String> = []
    private(set) var streamLoadState: StreamLoadState = .idle

    private(set) var engineSessionKey: String?
    private var debounceTask: Task<Void, Never>?
    private weak var transport: WatchProviderTransport?
    private var didBind = false

    var currentStream: StreamSession? {
        guard let currentSessionKey else { return nil }
        return streams.first(where: { $0.sessionKey == currentSessionKey })
    }

    func bind(transport: WatchProviderTransport) {
        guard !didBind else { return }
        didBind = true
        self.transport = transport

        guard !Self.isDebugScenarioEnabled else { return }

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
            await reloadStreams()
        }
    }

    func reloadStreams() async {
        guard let transport else { return }
        let previousState = streamLoadState
        streamLoadState = .loading

        do {
            let fetched = try await transport.fetchStreams()
            applyStreamSnapshot(fetched)
        } catch {
            if case .loaded = previousState {
                streamLoadState = .loaded
                return
            }
            streamLoadState = .failed(error.localizedDescription)
        }
    }

    func retryLoadingIfNeeded(for transportState: WatchProviderTransportState) {
        guard transportState == .direct || transportState == .relay else { return }

        switch streamLoadState {
        case .idle, .failed:
            Task { await reloadStreams() }
        case .loading, .loaded:
            break
        }
    }

    func setCurrentSessionKey(_ sessionKey: String) {
        currentSessionKey = sessionKey
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            await MainActor.run {
                self?.engineSessionKey = sessionKey
                self?.unreadSessionKeys.remove(sessionKey)
            }
        }
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
        streamLoadState = .loaded
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

#if DEBUG
    func debugSeed(streams: [StreamSession], currentSessionKey: String?) {
        streamLoadState = .loaded
        self.streams = streams
        self.currentSessionKey = currentSessionKey ?? streams.first?.sessionKey
        self.engineSessionKey = self.currentSessionKey
        unreadSessionKeys = []
    }
#endif
}
