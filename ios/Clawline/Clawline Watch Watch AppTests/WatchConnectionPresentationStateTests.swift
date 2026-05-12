import Foundation
import Testing
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
        #expect(WatchShellMetrics.controlBottomBreathingRoom >= WatchShellMetrics.verticalPadding)
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


    @Test("Soniox availability is based on credentials, not Watch direct-network path")
    @MainActor
    func sonioxAvailabilityDoesNotRequireDirectNetworkPath() {
        let credentials = WatchCredentialStore(keychain: WatchKeychainStore(service: "WatchTests.sonioxAvailability", accessGroup: nil))
        credentials.clear()
        credentials.debugApplyMockCredentials()
        let voiceSession = WatchVoiceSession(credentialStore: credentials)

        #expect(voiceSession.canUseVoice)
    }

    @Test("tap action does not force text entry just because transport is disconnected")
    func tapActionDoesNotPreferTextEntryWhenVoiceIsAvailable() throws {
        let sourcePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline Watch Watch App/Views/WatchMainView.swift")
        let source = try String(contentsOf: sourcePath, encoding: .utf8)

        #expect(!source.contains("transport.transportState == .disconnected || !presentationState.voiceInputAvailable"))
        #expect(source.contains("if presentationState.voiceInputAvailable {\n                voiceSession.startTap()"))
    }

}
