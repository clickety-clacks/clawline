import Foundation
import Testing
import WatchConnectivity
@testable import Clawline_Watch_Watch_App

struct WatchConnectionPresentationStateTests {
    @Test("queue_failed relay send shows queued error copy")
    @MainActor
    func queueFailedRelaySendShowsQueuedError() {
        let state = WatchConnectionPresentationState()

        state.apply(
            snapshot: .init(
                hasProviderCredentials: true,
                transportState: .relay,
                voiceState: .idle,
                transcript: "",
                voiceError: nil,
                voiceInputAvailable: false,
                streamLoadState: .loaded,
                streams: [],
                currentSessionKey: nil
            )
        )

        state.presentTextSendFailure(code: "queue_failed", message: nil)

        #expect(state.statusText == "Message couldn't be queued. Try again.")
    }

    @Test("channel label never falls back to phantom names")
    func channelDisplayNameAvoidsPhantomFallback() {
        #expect(
            WatchConnectionPresentationState.channelDisplayName(
                streamLoadState: .loading,
                streams: [],
                currentSessionKey: nil
            ) == "Loading channels…"
        )
        #expect(
            WatchConnectionPresentationState.channelDisplayName(
                streamLoadState: .loaded,
                streams: [],
                currentSessionKey: nil
            ) == "No channels"
        )
        #expect(
            WatchConnectionPresentationState.channelDisplayName(
                streamLoadState: .failed("No transport available"),
                streams: [],
                currentSessionKey: nil
            ) == "Loading channels…"
        )
        #expect(
            WatchConnectionPresentationState.channelDisplayName(
                streamLoadState: .loaded,
                streams: [
                    StreamSession(
                        sessionKey: "agent:main:main",
                        displayName: "#design",
                        kind: "dm",
                        orderIndex: 0,
                        isBuiltIn: true,
                        createdAt: .now,
                        updatedAt: .now
                    )
                ],
                currentSessionKey: "agent:main:main"
            ) == "#design"
        )
    }

    @Test("ring size follows GeometryReader formula and cap")
    func ringSizeUsesAdaptiveFormula() {
        #expect(WatchShellMetrics.ringDiameter(for: CGSize(width: 160, height: 170)) == 104)
        #expect(WatchShellMetrics.ringDiameter(for: CGSize(width: 260, height: 280)) == 145)
    }

    @Test("watch controls reserve breathing room at the bottom of the unified scroll surface")
    func controlsReserveBottomBreathingRoom() {
        #expect(WatchShellMetrics.controlBottomBreathingRoom > 0)
    }

    @Test("voice-active ring state preserves non-direct transport routes")
    func voiceActiveRingStatePreservesTransportRoute() {
        #expect(
            isSameRingState(
                WatchMainView.ringVisualState(
                    voiceState: .listening,
                    transportState: .direct
                ),
                .activeDirect
            )
        )
        #expect(
            isSameRingState(
                WatchMainView.ringVisualState(
                    voiceState: .finalizing,
                    transportState: .relay
                ),
                .activeRelay
            )
        )
        #expect(
            isSameRingState(
                WatchMainView.ringVisualState(
                    voiceState: .speaking,
                    transportState: .probing
                ),
                .connecting
            )
        )
        #expect(
            isSameRingState(
                WatchMainView.ringVisualState(
                    voiceState: .listening,
                    transportState: .disconnected
                ),
                .disconnected
            )
        )
    }

    @Test("conversation preview keeps only the newest ten messages")
    @MainActor
    func conversationPreviewCapsAtTenMessages() {
        let store = WatchConversationStore()

        for index in 0..<12 {
            store.recordOutgoing(content: "message \(index)", sessionKey: "session")
        }

        let visible = store.visibleEntries(for: "session")
        #expect(visible.count == 10)
        #expect(visible.first?.content == "message 2")
        #expect(visible.last?.content == "message 11")
    }

    @Test("conversation preview also caps by total characters")
    @MainActor
    func conversationPreviewCapsAtFiveHundredCharacters() {
        let store = WatchConversationStore()

        store.recordOutgoing(content: String(repeating: "a", count: 240), sessionKey: "session")
        store.recordOutgoing(content: String(repeating: "b", count: 240), sessionKey: "session")
        store.recordOutgoing(content: String(repeating: "c", count: 240), sessionKey: "session")

        let visible = store.visibleEntries(for: "session")
        #expect(visible.count == 2)
        #expect(visible.first?.content == String(repeating: "b", count: 240))
        #expect(visible.last?.content == String(repeating: "c", count: 240))
    }

    @Test("conversation preview truncates a single newest oversized message")
    @MainActor
    func conversationPreviewCapsSingleNewestMessage() {
        let store = WatchConversationStore()

        store.recordOutgoing(content: String(repeating: "x", count: 720), sessionKey: "session")

        let visible = store.visibleEntries(for: "session")
        #expect(visible.count == 1)
        #expect(visible.first?.content == String(repeating: "x", count: 500))
    }

    private func isSameRingState(_ lhs: WatchRingVisualState, _ rhs: WatchRingVisualState) -> Bool {
        switch (lhs, rhs) {
        case (.connectedDirect, .connectedDirect),
             (.connectedRelay, .connectedRelay),
             (.connecting, .connecting),
             (.disconnected, .disconnected),
             (.activeDirect, .activeDirect),
             (.activeRelay, .activeRelay):
            return true
        default:
            return false
        }
    }

    @Test("channel load failures are surfaced instead of infinite loading")
    @MainActor
    func shellMessageSurfacesChannelFailures() {
        #expect(
            WatchMainView.shellMessage(
                hasProviderCredentials: true,
                transportState: .relay,
                statusText: "Tap or hold to talk",
                streamLoadState: .failed("No transport available"),
                streams: [],
                stream: nil
            ) == "No transport available"
        )
    }

    @Test("transport outages are surfaced in shell copy")
    @MainActor
    func shellMessageSurfacesTransportOutages() {
        #expect(
            WatchMainView.shellMessage(
                hasProviderCredentials: true,
                transportState: .probing,
                statusText: "Reconnecting...",
                streamLoadState: .loaded,
                streams: [],
                stream: nil
            ) == "Reconnecting..."
        )
        #expect(
            WatchMainView.shellMessage(
                hasProviderCredentials: true,
                transportState: .disconnected,
                statusText: "No Connection",
                streamLoadState: .loaded,
                streams: [],
                stream: nil
            ) == "No Connection"
        )
    }

    @Test("voice errors remain visible on active loaded channel pages")
    @MainActor
    func shellMessageSurfacesVoiceErrorOnActiveChannelPage() {
        let stream = StreamSession(
            sessionKey: "agent:main:main",
            displayName: "#watch",
            kind: "dm",
            orderIndex: 0,
            isBuiltIn: true,
            createdAt: .now,
            updatedAt: .now
        )

        #expect(
            WatchMainView.shellMessage(
                hasProviderCredentials: true,
                transportState: .relay,
                statusText: "Couldn't start Soniox dictation. Try again.",
                voiceState: .error,
                streamLoadState: .loaded,
                streams: [stream],
                stream: stream
            ) == "Couldn't start Soniox dictation. Try again."
        )
    }


    @Test("Soniox availability is based on credentials, not Watch direct-network path")
    @MainActor
    func sonioxAvailabilityDoesNotRequireDirectNetworkPath() {
        let credentials = WatchCredentialStore(keychain: WatchKeychainStore(service: "WatchTests.sonioxAvailability", accessGroup: nil))
        credentials.clear()
        credentials.debugApplyMockCredentials()
        let voiceSession = WatchVoiceSession(credentialStore: credentials)

        #expect(voiceSession.canUseVoice)
    }

    @Test("empty iPhone Soniox payload clears existing Watch voice credential")
    @MainActor
    func emptySonioxPayloadClearsExistingWatchVoiceCredential() {
        let credentials = WatchCredentialStore(keychain: WatchKeychainStore(service: "WatchTests.sonioxClear", accessGroup: nil))
        credentials.clear()
        credentials.apply(userInfo: ["sonioxApiKey": "watch-soniox-key"])
        #expect(credentials.sonioxApiKey == "watch-soniox-key")

        credentials.apply(userInfo: ["sonioxApiKey": "  "])

        #expect(credentials.sonioxApiKey == nil)
        #expect(!WatchVoiceSession(credentialStore: credentials).canUseVoice)
    }

    @Test("missing Soniox credential produces Clawline voice error instead of system input")
    @MainActor
    func missingSonioxCredentialShowsVoiceError() {
        let credentials = WatchCredentialStore(keychain: WatchKeychainStore(service: "WatchTests.sonioxMissingError", accessGroup: nil))
        credentials.clear()
        let voiceSession = WatchVoiceSession(
            credentialStore: credentials,
            audioSessionConfigurator: {}
        )

        voiceSession.startTap()

        #expect(voiceSession.voiceState == .error)
        #expect(voiceSession.errorMessage == "Soniox key is not synced to Watch yet. Open Clawline on iPhone and check voice settings.")
    }

    @Test("Soniox start failure remains visible and hides raw diagnostics")
    @MainActor
    func sonioxStartFailureShowsHumanReadablePersistentError() async throws {
        let credentials = WatchCredentialStore(keychain: WatchKeychainStore(service: "WatchTests.sonioxStartFailure", accessGroup: nil))
        credentials.clear()
        credentials.apply(userInfo: ["sonioxApiKey": "watch-soniox-key"])
        let client = FailingWatchVoiceStreamingClient(
            error: NSError(
                domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "socket exploded while bootstrapping"]
            )
        )
        let voiceSession = WatchVoiceSession(
            credentialStore: credentials,
            sonioxClient: client,
            audioSessionConfigurator: {}
        )

        voiceSession.startTap()
        try await Task.sleep(for: .milliseconds(50))

        #expect(voiceSession.voiceState == .error)
        #expect(voiceSession.errorMessage == "Couldn't connect to Soniox. Check Watch Wi-Fi or cellular and try again.")
        #expect(voiceSession.errorMessage?.contains("socket exploded") == false)
        #expect(client.startCallCount == 1)
        #expect(client.stopCallCount > 0)
    }

    @Test("Soniox error response frames are routed to voice error handling")
    func sonioxErrorFramesAreNotAcceptedAsEmptyTranscripts() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Services/SonioxStreamingClient.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(source.contains("case errorCode = \"error_code\""))
        #expect(source.contains("case errorMessage = \"error_message\""))
        #expect(source.contains("if payload.hasError"))
        #expect(source.contains("onError?(ClientError.serverError(code: payload.errorCode, message: payload.errorMessage))"))
        #expect(source.contains("stop()\n            return"))
    }

    @Test("voice send failure preserves presentation error instead of relabeling as relay")
    @MainActor
    func voiceSendFailurePreservesPresentationError() async throws {
        let credentials = WatchCredentialStore(keychain: WatchKeychainStore(service: "WatchTests.voiceSendFailure", accessGroup: nil))
        credentials.clear()
        credentials.apply(userInfo: ["sonioxApiKey": "watch-soniox-key"])
        let client = SuccessfulWatchVoiceStreamingClient(finalTranscript: "send this")
        let voiceSession = WatchVoiceSession(
            credentialStore: credentials,
            sonioxClient: client,
            audioSessionConfigurator: {}
        )

        voiceSession.startTap()
        try await Task.sleep(for: .milliseconds(50))
        voiceSession.stop()
        try await Task.sleep(for: .milliseconds(50))

        voiceSession.handleSendFailure(
            error: NSError(
                domain: "WatchPresentation",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Message not delivered - connection lost."]
            )
        )

        #expect(voiceSession.voiceState == .error)
        #expect(voiceSession.errorMessage == "Message not delivered - connection lost.")
    }

    @Test("configured Soniox keeps mic tap on Clawline voice even when direct network monitor is false")
    func configuredSonioxDoesNotFallThroughToSystemTextInputWhenDirectNetworkIsFalse() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Services/WatchVoiceSession.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(source.contains("credentialStore.sonioxApiKey?.isEmpty == false"))
        #expect(!source.contains("credentialStore.sonioxApiKey?.isEmpty == false && hasDirectInternet"))
    }

    @Test("tap action does not force text entry just because transport is disconnected")
    func tapActionDoesNotPreferTextEntryWhenVoiceIsAvailable() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Views/WatchMainView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(!source.contains("transport.transportState == .disconnected || !presentationState.voiceInputAvailable"))
        #expect(!source.contains("Task { await requestTextInput() }"))
        #expect(source.contains("case .idle, .error:\n            voiceSession.startTap()"))
        #expect(source.contains("holdVoiceActive = true\n        voiceSession.startHold()"))
    }

    @Test("relay transport outages are buffered while server send errors remain terminal")
    @MainActor
    func relaySendFailureClassificationBuffersOnlyRecoverableTransportLoss() {
        #expect(WatchProviderTransport.shouldBufferRelaySendFailure(WatchProviderTransport.TransportError.notConnected))
        #expect(WatchProviderTransport.shouldBufferRelaySendFailure(RelayProtocolError.notConnected))
        #expect(WatchProviderTransport.shouldBufferRelaySendFailure(RelayProtocolError.server(code: "not_connected", message: "Reconnecting")))
        #expect(!WatchProviderTransport.shouldBufferRelaySendFailure(RelayProtocolError.server(code: "send_failed", message: "Rejected")))
        #expect(!WatchProviderTransport.shouldBufferRelaySendFailure(WatchProviderTransport.TransportError.authFailed("No token")))
        #expect(!WatchProviderTransport.shouldBufferRelaySendFailure(CocoaError(.coderInvalidValue)))
        #expect(WatchProviderTransport.shouldTreatRelayRequestErrorAsConnectivityLoss(NSError(domain: WCErrorDomain, code: WCError.Code.notReachable.rawValue)))
        #expect(WatchProviderTransport.shouldTreatRelayRequestErrorAsConnectivityLoss(NSError(domain: WCErrorDomain, code: WCError.Code.deliveryFailed.rawValue)))
        #expect(!WatchProviderTransport.shouldTreatRelayRequestErrorAsConnectivityLoss(NSError(domain: WCErrorDomain, code: WCError.Code.payloadUnsupportedTypes.rawValue)))
    }

    @Test("phone reachability recovery uses relay fallback while probing or disconnected")
    func phoneReachabilityRecoverySwitchesBackToRelayFallback() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Services/WatchProviderTransport.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(source.contains("private func switchToRelayFallback()"))
        #expect(source.contains("private func scheduleRelayBufferRetry()"))
        #expect(source.contains("scheduleRelayBufferRetry()"))
        #expect(source.contains("throw RelayProtocolError.notConnected"))
        #expect(source.contains("if transportState == .disconnected {\n            if isPhoneReachable {\n                switchToRelayFallback()"))
        #expect(source.contains("if transportState == .probing {\n            if isPhoneReachable {\n                switchToRelayFallback()"))
    }

    @Test("recoverable relay send failures remain on relay retry path")
    func recoverableRelaySendFailuresStayOnRelayRetryPath() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Services/WatchProviderTransport.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)
        let functionRange = try #require(source.range(of: "private func sendRelayRequest"))
        let sendRelayRequest = source[functionRange.lowerBound..<source.endIndex]

        #expect(!sendRelayRequest.contains("enterProbing(reason: \"relay unavailable\")"))
        #expect(!sendRelayRequest.contains("enterProbing(reason: \"relay request failed\")"))
        #expect(source.contains("buffer(message)\n                    scheduleRelayBufferRetry()\n                    return"))
    }

    @Test("relay reachability debounce does not apply canceled states")
    func relayReachabilityDebounceDoesNotApplyCanceledStates() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Services/WatchProviderTransport.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(source.contains("catch is CancellationError {\n                return\n            }"))
        #expect(!source.contains("reachabilityDebounceTask = Task { [weak self] in\n            try? await Task.sleep(for: .seconds(1))"))
    }

    @Test("direct internet monitor does not terminate active Soniox voice")
    func directInternetMonitorDoesNotTerminateActiveSonioxVoice() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Services/WatchVoiceSession.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)
        let functionRange = try #require(source.range(of: "private func handleDirectInternetChange"))
        let handler = source[functionRange.lowerBound..<source.endIndex]

        #expect(handler.contains("hasDirectInternet = available"))
        #expect(!handler.contains("finalizeAndSend(forceIdleAfterSend: true)"))
        #expect(!handler.contains("cancelCurrentSpeech(clearQueue: true)"))
    }

}

private final class FailingWatchVoiceStreamingClient: WatchVoiceStreaming {
    var onTranscriptUpdate: ((SonioxStreamingClient.TranscriptUpdate) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((Error) -> Void)?

    private let error: Error
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    init(error: Error) {
        self.error = error
    }

    func start(apiKey: String, clientReferenceID: String) async throws {
        startCallCount += 1
        throw error
    }

    func finalize(timeoutNanoseconds: UInt64) async -> String {
        ""
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class SuccessfulWatchVoiceStreamingClient: WatchVoiceStreaming {
    var onTranscriptUpdate: ((SonioxStreamingClient.TranscriptUpdate) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((Error) -> Void)?

    private let finalTranscript: String

    init(finalTranscript: String) {
        self.finalTranscript = finalTranscript
    }

    func start(apiKey: String, clientReferenceID: String) async throws {}

    func finalize(timeoutNanoseconds: UInt64) async -> String {
        finalTranscript
    }

    func stop() {}
}
