import SwiftUI
import WatchConnectivity

@main
struct Clawline_Watch_Watch_AppApp: App {
    @State private var credentialStore: WatchCredentialStore
    @State private var providerTransport: WatchProviderTransport
    @State private var voiceSession: WatchVoiceSession
    @State private var channelManager: WatchChannelManager

    private let wcSessionDelegate: WatchWCSessionDelegate?
    private let voiceMessageTracker: VoiceMessageTracker

    init() {
        let credentialStore = WatchCredentialStore()
        _credentialStore = State(initialValue: credentialStore)

        let transport = WatchProviderTransport(credentialStore: credentialStore)
        _providerTransport = State(initialValue: transport)

        let voiceSession = WatchVoiceSession(credentialStore: credentialStore)
        _voiceSession = State(initialValue: voiceSession)

        let channelManager = WatchChannelManager()
        _channelManager = State(initialValue: channelManager)
        let voiceMessageTracker = VoiceMessageTracker()
        self.voiceMessageTracker = voiceMessageTracker

        voiceSession.onTranscriptReady = { transcript in
            let messageId = "c_\(UUID().uuidString)"
            let sessionKey = channelManager.engineSessionKey ?? channelManager.currentSessionKey

            Task { @MainActor in
                voiceMessageTracker.markPending(messageId)
                do {
                    try await transport.send(id: messageId, content: transcript, attachments: [], sessionKey: sessionKey)
                } catch {
                    voiceMessageTracker.remove(messageId)
                    voiceSession.handleSendFailure(error: error)
                }
            }
        }

        Task { @MainActor in
            for await event in transport.serviceEvents {
                switch event {
                case .messageAcked(let id):
                    voiceMessageTracker.remove(id)
                case .messageError(let messageId, let code, let message):
                    guard let messageId,
                          voiceMessageTracker.consumeIfPending(messageId),
                          code == "expired" || code == "buffer_full" else {
                        continue
                    }

                    let description = message ?? "Message failed while reconnecting"
                    let error = NSError(
                        domain: "co.clicketyclacks.Clawline.WatchProviderTransport",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: description]
                    )
                    voiceSession.handleSendFailure(error: error)
                default:
                    break
                }
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
    }
}

@MainActor
private final class VoiceMessageTracker {
    private var pending = Set<String>()

    func markPending(_ id: String) {
        pending.insert(id)
    }

    func remove(_ id: String) {
        pending.remove(id)
    }

    func consumeIfPending(_ id: String) -> Bool {
        pending.remove(id) != nil
    }
}
