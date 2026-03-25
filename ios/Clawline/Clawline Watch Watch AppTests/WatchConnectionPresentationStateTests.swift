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
                streamListLoaded: true,
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
                streamListLoaded: false,
                streams: [],
                currentSessionKey: nil
            ) == "Loading channels…"
        )
        #expect(
            WatchConnectionPresentationState.channelDisplayName(
                streamListLoaded: true,
                streams: [],
                currentSessionKey: nil
            ) == "No channels"
        )
        #expect(
            WatchConnectionPresentationState.channelDisplayName(
                streamListLoaded: true,
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

    @Test("horizontal swipe arbitration preempts hold at 10pt")
    func swipeArbitrationUsesSpecThreshold() {
        #expect(WatchGestureArbitration.shouldPreemptHold(translation: CGSize(width: 9, height: 0)) == false)
        #expect(WatchGestureArbitration.shouldPreemptHold(translation: CGSize(width: 10, height: 0)) == true)
        #expect(WatchGestureArbitration.swipeDelta(for: CGSize(width: -12, height: 2)) == 1)
        #expect(WatchGestureArbitration.swipeDelta(for: CGSize(width: 12, height: 1)) == -1)
    }
}
