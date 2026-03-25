import SwiftUI
import WatchKit

struct WatchMainView: View {
    @Environment(WatchProviderTransport.self) private var transport
    @Environment(WatchVoiceSession.self) private var voiceSession
    @Environment(WatchChannelManager.self) private var channelManager
    @Environment(WatchConnectionPresentationState.self) private var presentationState

    @State private var activeGesture = ActiveGesture()
    @State private var holdTask: Task<Void, Never>?

    @State private var showTextInputSheet = false
    @State private var textInput = ""

    var body: some View {
        Group {
            if presentationState.hasProviderCredentials {
                content
            } else {
                pairingPrompt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .safeAreaInset(edge: .top, spacing: 4) {
            HStack {
                RouteIndicatorChip(presentation: presentationState.routeChip)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
        .task { observeIncomingResponses() }
        .onChange(of: transport.transportState) { _, newValue in
            voiceSession.routeChanged(to: newValue)
            WKInterfaceDevice.current().play(.click)
        }
        .sheet(isPresented: $showTextInputSheet) {
            VStack(spacing: 10) {
                Text("Text only")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                TextField("Dictate or type", text: $textInput)

                Button("Send") {
                    let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    Task { await presentationState.sendTextMessage(text) }
                    textInput = ""
                    showTextInputSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var content: some View {
        GeometryReader { proxy in
            let availableSize = proxy.size
            let ringDiameter = WatchShellMetrics.ringDiameter(for: availableSize)
            let ringFrame = CGRect(
                x: (availableSize.width - ringDiameter) / 2,
                y: 0,
                width: ringDiameter,
                height: ringDiameter
            )

            VStack(spacing: 8) {
                ZStack {
                    WaveformRingView(audioLevel: voiceSession.audioLevel, isActive: isVoiceActive)
                        .frame(width: ringDiameter, height: ringDiameter)

                    Image(systemName: centerIcon)
                        .font(.system(size: ringDiameter * 0.34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(
                            width: max(44, ringDiameter * 0.4),
                            height: max(44, ringDiameter * 0.4)
                        )
                }

                Text(presentationState.statusText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)

                WatchStreamDotsView(
                    sessionKeys: channelManager.streams.map(\.sessionKey),
                    activeSessionKey: channelManager.currentSessionKey,
                    unreadSessionKeys: channelManager.unreadSessionKeys
                )

                Text(presentationState.channelDisplayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(interactionGesture(ringFrame: ringFrame))
        }
    }

    private var pairingPrompt: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("Open Clawline")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text("on iPhone to pair")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var centerIcon: String {
        switch voiceSession.voiceState {
        case .listening, .finalizing, .speaking:
            return "stop.fill"
        case .sending:
            return "hourglass"
        case .idle, .error:
            return "mic.fill"
        }
    }

    private var isVoiceActive: Bool {
        switch voiceSession.voiceState {
        case .listening, .finalizing, .speaking:
            return true
        case .sending, .idle, .error:
            return false
        }
    }

    private func interactionGesture(ringFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !activeGesture.isActive {
                    activeGesture = ActiveGesture(
                        isActive: true,
                        startedInRing: ringFrame.contains(value.startLocation)
                    )
                    armHoldIfNeeded()
                }

                guard !activeGesture.holdStarted,
                      WatchGestureArbitration.shouldPreemptHold(translation: value.translation) else {
                    return
                }

                activeGesture.swipePreemptedHold = true
                cancelHold()
            }
            .onEnded { value in
                defer { resetGesture() }

                if let delta = WatchGestureArbitration.swipeDelta(for: value.translation),
                   activeGesture.swipePreemptedHold {
                    channelManager.switchBy(delta: delta)
                    WKInterfaceDevice.current().play(.click)
                    return
                }

                if activeGesture.holdStarted {
                    voiceSession.releaseHold()
                    return
                }

                if activeGesture.startedInRing {
                    handleTapAction()
                }
            }
    }

    private func handleTapAction() {
        switch voiceSession.voiceState {
        case .speaking:
            voiceSession.bargeIn()
        case .idle, .error:
            if transport.transportState == .disconnected || !presentationState.voiceInputAvailable {
                showTextInputSheet = true
            } else {
                voiceSession.startTap()
            }
        case .listening, .finalizing:
            voiceSession.stop()
        case .sending:
            break
        }
    }

    private func observeIncomingResponses() {
        Task {
            for await message in transport.incomingMessages {
                guard message.role == .assistant else { continue }

                if let activeSession = channelManager.engineSessionKey,
                   activeSession != message.sessionKey {
                    continue
                }

                await MainActor.run {
                    voiceSession.handleResponse(text: message.content)
                }
            }
        }
    }

    private func armHoldIfNeeded() {
        guard activeGesture.startedInRing else { return }
        cancelHold()
        holdTask = Task { [weak voiceSession] in
            try? await Task.sleep(for: .seconds(WatchGestureArbitration.holdDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard activeGesture.startedInRing,
                      !activeGesture.swipePreemptedHold,
                      !activeGesture.holdStarted else {
                    return
                }

                activeGesture.holdStarted = true
                if transport.transportState == .disconnected || !presentationState.voiceInputAvailable {
                    showTextInputSheet = true
                } else {
                    voiceSession?.startHold()
                }
            }
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }

    private func resetGesture() {
        cancelHold()
        activeGesture = ActiveGesture()
    }
}

private struct ActiveGesture {
    var isActive = false
    var startedInRing = false
    var swipePreemptedHold = false
    var holdStarted = false
}
