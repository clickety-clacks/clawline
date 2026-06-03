import SwiftUI
import WatchConnectivity
import Foundation

@main
struct Clawline_Watch_Watch_AppApp: App {
    @State private var credentialStore: WatchCredentialStore
    @State private var providerTransport: WatchProviderTransport
    @State private var voiceSession: WatchVoiceSession
    @State private var channelManager: WatchChannelManager
    @State private var conversationStore: WatchConversationStore
    @State private var presentationState: WatchConnectionPresentationState

    private let wcSessionDelegate: WatchWCSessionDelegate?

    init() {
        let credentialStore = WatchCredentialStore()
        _credentialStore = State(initialValue: credentialStore)

        let transport = WatchProviderTransport(credentialStore: credentialStore)
        _providerTransport = State(initialValue: transport)

        let voiceSession = WatchVoiceSession(credentialStore: credentialStore)
        _voiceSession = State(initialValue: voiceSession)

        let channelManager = WatchChannelManager()
        _channelManager = State(initialValue: channelManager)
        let conversationStore = WatchConversationStore()
        _conversationStore = State(initialValue: conversationStore)
        let presentationState = WatchConnectionPresentationState()
        _presentationState = State(initialValue: presentationState)

        voiceSession.onTranscriptReady = { transcript in
            Task { @MainActor in
                await presentationState.sendVoiceTranscript(transcript)
            }
        }

#if DEBUG
        if let scenario = WatchUITestScenario.fromEnvironment() {
            scenario.apply(
                credentialStore: credentialStore,
                transport: transport,
                channelManager: channelManager,
                conversationStore: conversationStore
            )
            self.wcSessionDelegate = nil
        } else if WCSession.isSupported() {
            let delegate = WatchWCSessionDelegate(credentialStore: credentialStore, transport: transport)
            self.wcSessionDelegate = delegate
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        } else {
            self.wcSessionDelegate = nil
        }
#else
        if WCSession.isSupported() {
            let delegate = WatchWCSessionDelegate(credentialStore: credentialStore, transport: transport)
            self.wcSessionDelegate = delegate
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        } else {
            self.wcSessionDelegate = nil
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            watchRootView
        }
    }

    @ViewBuilder
    private var watchRootView: some View {
        WatchMainView()
            .environment(credentialStore)
            .environment(providerTransport)
            .environment(voiceSession)
            .environment(channelManager)
            .environment(conversationStore)
            .environment(presentationState)
    }
}


#if DEBUG
private struct WatchUITestScenario {
    let transportState: WatchProviderTransportState
    let streams: [StreamSession]
    let currentSessionKey: String?
    let entries: [WatchConversationStore.Entry]

    static func fromEnvironment() -> WatchUITestScenario? {
        let processInfo = ProcessInfo.processInfo
        let rawScenario = scenarioFromLaunchArguments(processInfo.arguments)
            ?? processInfo.environment["WATCH_UI_TEST_SCENARIO"]
            ?? compileTimeScenario
            ?? nextScenarioForUITestFallback(processInfo: processInfo)
        guard let raw = rawScenario?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let now = Date()
        let session = StreamSession(sessionKey: "watch-ui-test-main", displayName: "Flynn", kind: "dm", orderIndex: 0, isBuiltIn: false, createdAt: now.addingTimeInterval(-3600), updatedAt: now)
        let transcript: [(Message.Role, String)] = [
            (.assistant, "Morning. The watch shell is live and the ring is solid now."),
            (.user, "Good. Show me the recent conversation panel."),
            (.assistant, "Loaded. You can scroll this history without losing the mic control."),
            (.user, "And relay mode?"),
            (.assistant, "Relay keeps the same shell, just routes through iPhone."),
            (.user, "What happens if the route drops?"),
            (.assistant, "The ring switches to reconnecting, then disconnected if it stays down."),
            (.user, "Nice. Keep hold-to-talk reachable."),
            (.assistant, "Yep — tap and hold are both still anchored under the history."),
            (.user, "Perfect. Capture it.")
        ]
        let entries = transcript.enumerated().map { index, item in
            WatchConversationStore.Entry(id: "watch-ui-test_\(index)", role: item.0, content: item.1, timestamp: now.addingTimeInterval(Double(index - transcript.count) * 45))
        }
        switch raw.lowercased() {
        case "direct":
            return WatchUITestScenario(transportState: .direct, streams: [session], currentSessionKey: session.sessionKey, entries: entries)
        case "relay":
            return WatchUITestScenario(transportState: .relay, streams: [session], currentSessionKey: session.sessionKey, entries: entries)
        case "reconnecting":
            return WatchUITestScenario(transportState: .probing, streams: [session], currentSessionKey: session.sessionKey, entries: entries)
        case "disconnected":
            return WatchUITestScenario(transportState: .disconnected, streams: [session], currentSessionKey: session.sessionKey, entries: entries)
        default:
            return nil
        }
    }


    private static var compileTimeScenario: String? {
#if WATCH_UI_SCENARIO_DIRECT
        return "direct"
#elseif WATCH_UI_SCENARIO_RELAY
        return "relay"
#elseif WATCH_UI_SCENARIO_RECONNECTING
        return "reconnecting"
#elseif WATCH_UI_SCENARIO_DISCONNECTED
        return "disconnected"
#else
        return nil
#endif
    }

    private static func nextScenarioForUITestFallback(processInfo: ProcessInfo) -> String? {
        guard processInfo.environment["XCTestConfigurationFilePath"] != nil
            || processInfo.environment.keys.contains(where: { $0.localizedCaseInsensitiveContains("XCTest") }) else {
            return nil
        }

        let defaults = UserDefaults.standard
        let key = "watchUITestScenarioLaunchIndex"
        let scenarios = ["direct", "relay", "reconnecting", "disconnected"]
        let index = defaults.integer(forKey: key)
        defaults.set(index + 1, forKey: key)
        return scenarios[index % scenarios.count]
    }

    private static func scenarioFromLaunchArguments(_ arguments: [String]) -> String? {
        if let index = arguments.indices.reversed().first(where: { arguments[$0] == "-WATCH_UI_TEST_SCENARIO" }), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }

        return arguments.reversed().first { $0.hasPrefix("WATCH_UI_TEST_SCENARIO=") }
            .flatMap { $0.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) }
    }

    func apply(credentialStore: WatchCredentialStore, transport: WatchProviderTransport, channelManager: WatchChannelManager, conversationStore: WatchConversationStore) {
        credentialStore.debugApplyMockCredentials()
        transport.debugSetTransportState(transportState)
        channelManager.debugSeed(streams: streams, currentSessionKey: currentSessionKey)
        if let currentSessionKey {
            conversationStore.debugSeed(entries: entries, sessionKey: currentSessionKey)
        }
    }
}
#endif
