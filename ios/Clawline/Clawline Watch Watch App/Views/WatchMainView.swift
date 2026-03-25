import SwiftUI
import WatchKit

struct WatchMainView: View {
    @Environment(WatchCredentialStore.self) private var credentials
    @Environment(WatchProviderTransport.self) private var transport
    @Environment(WatchVoiceSession.self) private var voiceSession
    @Environment(WatchChannelManager.self) private var channelManager

    @State private var didBind = false
    @State private var pressStartTime: Date?
    @State private var holdStarted = false

    @State private var connectionInterruptionReason: String?

    @State private var showTextInputSheet = false
    @State private var textInput = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                RouteIndicatorChip(transportState: transport.transportState)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }

            Group {
                if !credentials.hasProviderCredentials {
                    VStack(spacing: 8) {
                        Text("Open Clawline")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("on iPhone to pair")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    content
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .task {
            guard !didBind else { return }
            didBind = true
            channelManager.bind(transport: transport)
            observeIncomingResponses()
            observeTransportEvents()
        }
        .onChange(of: transport.transportState) { _, newValue in
            voiceSession.routeChanged(to: newValue)
            WKInterfaceDevice.current().play(.click)

            if newValue != .disconnected {
                connectionInterruptionReason = nil
            }
        }
        .sheet(isPresented: $showTextInputSheet) {
            VStack(spacing: 10) {
                Text("Text only")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                TextField("Dictate or type", text: $textInput)

                Button("Send") {
                    let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    sendTextMessage(text)
                    textInput = ""
                    showTextInputSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            ZStack {
                WaveformRingView(audioLevel: voiceSession.audioLevel, isActive: isVoiceActive)
                    .frame(width: 128, height: 128)

                Image(systemName: centerIcon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .contentShape(Circle())
            .gesture(pressGesture)
            .onTapGesture {
                handleTapAction()
            }

            Text(statusLine)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            WatchStreamDotsView(
                sessionKeys: channelManager.streams.map(\.sessionKey),
                activeSessionKey: channelManager.currentSessionKey,
                unreadSessionKeys: channelManager.unreadSessionKeys
            )

            Text(channelManager.currentChannelName())
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .simultaneousGesture(channelSwipeGesture)
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

    private var statusLine: String {
        switch voiceSession.voiceState {
        case .idle:
            switch transport.transportState {
            case .direct:
                return "Tap or hold to talk"
            case .probing:
                return "Reconnecting..."
            case .relay:
                return voiceSession.canUseVoice ? "Via iPhone" : "Voice unavailable — text only via iPhone"
            case .disconnected:
                return connectionInterruptionReason ?? "No Connection"
            }
        case .listening:
            return voiceSession.transcript.isEmpty ? "Listening..." : voiceSession.transcript
        case .finalizing:
            return "Finalizing..."
        case .sending:
            return "Sending..."
        case .speaking:
            return "Speaking..."
        case .error:
            return voiceSession.errorMessage ?? "Error"
        }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if pressStartTime == nil {
                    pressStartTime = Date()
                    holdStarted = false
                }

                guard !holdStarted,
                      let pressStartTime,
                      Date().timeIntervalSince(pressStartTime) >= 0.2 else {
                    return
                }

                holdStarted = true
                if transport.transportState == .disconnected || !voiceSession.canUseVoice {
                    showTextInputSheet = true
                } else {
                    voiceSession.startHold()
                }
            }
            .onEnded { _ in
                defer {
                    pressStartTime = nil
                    holdStarted = false
                }

                if holdStarted {
                    voiceSession.releaseHold()
                }
            }
    }

    private var channelSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard abs(horizontal) > 30, abs(horizontal) > vertical else { return }
                if horizontal < 0 {
                    channelManager.switchBy(delta: 1)
                } else {
                    channelManager.switchBy(delta: -1)
                }
                WKInterfaceDevice.current().play(.click)
            }
    }

    private func handleTapAction() {
        switch voiceSession.voiceState {
        case .speaking:
            voiceSession.bargeIn()
        case .idle, .error:
            if transport.transportState == .disconnected || !voiceSession.canUseVoice {
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

    private func sendTextMessage(_ text: String) {
        let messageId = "c_\(UUID().uuidString)"
        let sessionKey = channelManager.engineSessionKey ?? channelManager.currentSessionKey

        Task {
            do {
                try await transport.send(
                    id: messageId,
                    content: text,
                    attachments: [],
                    sessionKey: sessionKey
                )
            } catch {
                connectionInterruptionReason = error.localizedDescription
            }
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

    private func observeTransportEvents() {
        Task {
            for await event in transport.serviceEvents {
                guard case .connectionInterrupted(let reason) = event,
                      let reason,
                      !reason.isEmpty else {
                    continue
                }

                await MainActor.run {
                    connectionInterruptionReason = reason
                }
            }
        }
    }
}
