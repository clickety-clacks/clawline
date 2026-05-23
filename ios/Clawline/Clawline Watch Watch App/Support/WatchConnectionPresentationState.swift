import Foundation
import Observation
import SwiftUI

struct WatchRouteChipPresentation {
    let label: String
    let systemImage: String
    let color: Color
}

@MainActor
@Observable
final class WatchConnectionPresentationState {
    enum PendingSendOrigin {
        case text
        case voice
    }

    struct Snapshot {
        let hasProviderCredentials: Bool
        let transportState: WatchProviderTransportState
        let voiceState: WatchVoiceSession.VoiceState
        let transcript: String
        let voiceError: String?
        let voiceInputAvailable: Bool
        let streamLoadState: WatchChannelManager.StreamLoadState
        let streams: [StreamSession]
        let currentSessionKey: String?
    }

    private(set) var routeChip: WatchRouteChipPresentation
    private(set) var statusText = "No Connection"
    private(set) var voiceInputAvailable = false
    private(set) var channelDisplayName = "Loading channels…"
    private(set) var hasProviderCredentials = false

    private weak var credentialStore: WatchCredentialStore?
    private weak var transport: WatchProviderTransport?
    private weak var voiceSession: WatchVoiceSession?
    private weak var channelManager: WatchChannelManager?
    private weak var conversationStore: WatchConversationStore?

    private var didBind = false
    private var connectionInterruptionReason: String?
    private var transientStatusText: String?
    private var transientStatusTask: Task<Void, Never>?
    private var pendingSendOrigins: [String: PendingSendOrigin] = [:]
    private var latestSnapshot: Snapshot?

    init() {
        routeChip = WatchConnectionPresentationState.routeChip(for: .disconnected)
    }

    func bind(
        credentialStore: WatchCredentialStore,
        transport: WatchProviderTransport,
        voiceSession: WatchVoiceSession,
        channelManager: WatchChannelManager,
        conversationStore: WatchConversationStore
    ) {
        guard !didBind else { return }
        didBind = true

        self.credentialStore = credentialStore
        self.transport = transport
        self.voiceSession = voiceSession
        self.channelManager = channelManager
        self.conversationStore = conversationStore

        startObservationTracking()
        observeTransportEvents(transport: transport, voiceSession: voiceSession)
    }

    func sendVoiceTranscript(_ transcript: String) async {
        await sendMessage(transcript, origin: .voice)
    }

    func sendTextMessage(_ text: String) async {
        await sendMessage(text, origin: .text)
    }

    func apply(snapshot: Snapshot) {
        latestSnapshot = snapshot
        refreshPresentation()
    }

    func presentTextSendFailure(code: String, message: String?) {
        showTransientStatus(Self.userFacingSendFailureMessage(code: code, fallback: message))
    }

    nonisolated static func userFacingSendFailureMessage(code: String, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty {
            return fallback
        }

        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queue_failed", "queue_full":
            return "Message couldn't be queued. Try again."
        case "buffer_full":
            return "Message dropped while reconnecting."
        case "expired":
            return "Buffered message expired."
        case "connection_lost":
            return "Message not delivered — connection lost."
        default:
            return "Message failed (\(code))."
        }
    }

    nonisolated static func channelDisplayName(
        streamLoadState: WatchChannelManager.StreamLoadState,
        streams: [StreamSession],
        currentSessionKey: String?
    ) -> String {
        switch streamLoadState {
        case .idle, .loading:
            return "Loading channels…"
        case .failed:
            return "Loading channels…"
        case .loaded:
            break
        }

        guard !streams.isEmpty else { return "No channels" }

        if let currentSessionKey,
           let stream = streams.first(where: { $0.sessionKey == currentSessionKey }) {
            return stream.displayName
        }

        return streams.first?.displayName ?? "No channels"
    }

    private func sendMessage(_ rawText: String, origin: PendingSendOrigin) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let transport,
              let channelManager else { return }

        transientStatusTask?.cancel()
        transientStatusTask = nil
        transientStatusText = nil
        refreshPresentation()

        let messageId = "c_\(UUID().uuidString)"
        let sessionKey = channelManager.engineSessionKey ?? channelManager.currentSessionKey
        pendingSendOrigins[messageId] = origin

        do {
            try await transport.send(
                id: messageId,
                content: text,
                attachments: [],
                sessionKey: sessionKey
            )
            conversationStore?.recordOutgoing(content: text, sessionKey: sessionKey)
        } catch {
            pendingSendOrigins.removeValue(forKey: messageId)
            handleImmediateSendFailure(error, origin: origin)
        }
    }

    private func startObservationTracking() {
        guard let credentialStore,
              let transport,
              let voiceSession,
              let channelManager else {
            return
        }

        withObservationTracking {
            apply(
                snapshot: Snapshot(
                    hasProviderCredentials: credentialStore.hasProviderCredentials,
                    transportState: transport.transportState,
                    voiceState: voiceSession.voiceState,
                    transcript: voiceSession.transcript,
                    voiceError: voiceSession.errorMessage,
                    voiceInputAvailable: voiceSession.canUseVoice,
                    streamLoadState: channelManager.streamLoadState,
                    streams: channelManager.streams,
                    currentSessionKey: channelManager.currentSessionKey
                )
            )
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor [self] in
                self.startObservationTracking()
            }
        }
    }

    private func observeTransportEvents(
        transport: WatchProviderTransport,
        voiceSession: WatchVoiceSession
    ) {
        Task { [weak self] in
            guard let self else { return }
            for await event in transport.serviceEvents {
                await MainActor.run {
                    self.handle(event: event, voiceSession: voiceSession)
                }
            }
        }
    }

    private func handle(event: ChatServiceEvent, voiceSession: WatchVoiceSession) {
        switch event {
        case .messageAcked(let id):
            pendingSendOrigins.removeValue(forKey: id)
        case .messageError(let messageId, let code, let message):
            let userFacing = Self.userFacingSendFailureMessage(code: code, fallback: message)

            if let messageId,
               let origin = pendingSendOrigins.removeValue(forKey: messageId) {
                let error = Self.userFacingError(message: userFacing)
                switch origin {
                case .text:
                    showTransientStatus(userFacing)
                case .voice:
                    voiceSession.handleSendFailure(error: error)
                }
                return
            }

            if code == "queue_failed" || code == "queue_full" {
                showTransientStatus(userFacing)
            }
        case .connectionInterrupted(let reason):
            if let reason, !reason.isEmpty {
                connectionInterruptionReason = reason
                refreshPresentation()
            }
        default:
            break
        }
    }

    private func handleImmediateSendFailure(_ error: Error, origin: PendingSendOrigin) {
        let userFacing = Self.userFacingMessage(for: error)

        switch origin {
        case .text:
            showTransientStatus(userFacing)
        case .voice:
            voiceSession?.handleSendFailure(error: Self.userFacingError(message: userFacing))
        }
    }

    private func showTransientStatus(_ message: String) {
        transientStatusTask?.cancel()
        transientStatusText = message
        refreshPresentation()

        transientStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.transientStatusText = nil
                self?.refreshPresentation()
            }
        }
    }

    private func refreshPresentation() {
        guard let latestSnapshot else { return }

        hasProviderCredentials = latestSnapshot.hasProviderCredentials
        voiceInputAvailable = latestSnapshot.voiceInputAvailable
        routeChip = Self.routeChip(for: latestSnapshot.transportState)
        channelDisplayName = Self.channelDisplayName(
            streamLoadState: latestSnapshot.streamLoadState,
            streams: latestSnapshot.streams,
            currentSessionKey: latestSnapshot.currentSessionKey
        )

        if latestSnapshot.transportState != .disconnected {
            connectionInterruptionReason = nil
        }

        statusText = Self.statusText(
            snapshot: latestSnapshot,
            connectionInterruptionReason: connectionInterruptionReason,
            transientStatusText: transientStatusText
        )
    }

    nonisolated private static func routeChip(for state: WatchProviderTransportState) -> WatchRouteChipPresentation {
        switch state {
        case .direct:
            return WatchRouteChipPresentation(label: "Direct", systemImage: "circle.fill", color: .green)
        case .probing:
            return WatchRouteChipPresentation(label: "Reconnecting…", systemImage: "circle.dotted", color: .yellow)
        case .relay:
            return WatchRouteChipPresentation(label: "Via iPhone", systemImage: "arrow.left.arrow.right", color: .blue)
        case .disconnected:
            return WatchRouteChipPresentation(label: "No Connection", systemImage: "circle", color: .red)
        }
    }

    nonisolated private static func statusText(
        snapshot: Snapshot,
        connectionInterruptionReason: String?,
        transientStatusText: String?
    ) -> String {
        guard snapshot.hasProviderCredentials else {
            return "Open Clawline on iPhone to pair"
        }

        switch snapshot.voiceState {
        case .idle:
            if let transientStatusText, !transientStatusText.isEmpty {
                return transientStatusText
            }

            switch snapshot.transportState {
            case .direct:
                return snapshot.voiceInputAvailable ? "Tap or hold to talk" : "Voice unavailable — text only"
            case .probing:
                return "Reconnecting..."
            case .relay:
                return snapshot.voiceInputAvailable ? "Tap or hold to talk" : "Text only via iPhone"
            case .disconnected:
                return connectionInterruptionReason ?? "No Connection"
            }
        case .listening:
            return snapshot.transcript.isEmpty ? "Listening..." : snapshot.transcript
        case .finalizing:
            return "Finalizing..."
        case .sending:
            return "Sending..."
        case .speaking:
            return "Speaking..."
        case .error:
            if let voiceError = snapshot.voiceError, !voiceError.isEmpty {
                return voiceError
            }
            if let transientStatusText, !transientStatusText.isEmpty {
                return transientStatusText
            }
            return "Error"
        }
    }

    nonisolated private static func userFacingMessage(for error: Error) -> String {
        if let relayError = error as? RelayProtocolError {
            switch relayError {
            case .server(let code, let message):
                return userFacingSendFailureMessage(code: code, fallback: message)
            default:
                return relayError.localizedDescription
            }
        }

        return error.localizedDescription
    }

    nonisolated private static func userFacingError(message: String) -> NSError {
        NSError(
            domain: "co.clicketyclacks.Clawline.WatchPresentation",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
