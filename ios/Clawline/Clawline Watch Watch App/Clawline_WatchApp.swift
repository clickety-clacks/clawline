import SwiftUI
import WatchConnectivity

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

        if WCSession.isSupported() {
            let delegate = WatchWCSessionDelegate(credentialStore: credentialStore, transport: transport)
            self.wcSessionDelegate = delegate
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        } else {
            self.wcSessionDelegate = nil
        }
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
