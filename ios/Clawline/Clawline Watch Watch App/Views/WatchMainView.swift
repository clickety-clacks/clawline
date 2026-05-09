import SwiftUI
import WatchKit

struct WatchMainView: View {
    @Environment(WatchCredentialStore.self) private var credentialStore
    @Environment(WatchProviderTransport.self) private var transport
    @Environment(WatchVoiceSession.self) private var voiceSession
    @Environment(WatchChannelManager.self) private var channelManager
    @Environment(WatchConversationStore.self) private var conversationStore
    @Environment(WatchConnectionPresentationState.self) private var presentationState
    @Environment(\.scenePhase) private var scenePhase

    @State private var holdVoiceActive = false

    private let placeholderPageKey = "__watch_shell_placeholder__"

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                channelManager.bind(transport: transport)
                conversationStore.bind(transport: transport)
                presentationState.bind(
                    credentialStore: credentialStore,
                    transport: transport,
                    voiceSession: voiceSession,
                    channelManager: channelManager,
                    conversationStore: conversationStore
                )
                channelManager.retryLoadingIfNeeded(for: transport.transportState)
                observeIncomingResponses()
            }
            .onChange(of: transport.transportState) { _, newValue in
                channelManager.retryLoadingIfNeeded(for: newValue)
                WKInterfaceDevice.current().play(.click)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                channelManager.retryLoadingIfNeeded(for: transport.transportState)
            }
    }

    private var content: some View {
        TabView(selection: selectedPageKey) {
            if channelManager.streams.isEmpty {
                channelPage(stream: nil)
                    .tag(placeholderPageKey)
            } else {
                ForEach(channelManager.streams) { stream in
                    channelPage(stream: stream)
                        .tag(stream.sessionKey)
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var selectedPageKey: Binding<String> {
        Binding(
            get: {
                channelManager.currentSessionKey ??
                channelManager.streams.first?.sessionKey ??
                placeholderPageKey
            },
            set: { newValue in
                guard newValue != placeholderPageKey else { return }
                channelManager.setCurrentSessionKey(newValue)
            }
        )
    }

    private func channelPage(stream: StreamSession?) -> some View {
        GeometryReader { proxy in
            let availableSize = proxy.size
            let ringDiameter = WatchShellMetrics.ringDiameter(for: availableSize)
            let shellMessage = shellMessage(for: stream)
            let showsChannelRow = transport.transportState != .disconnected

            VStack(spacing: WatchShellMetrics.shellSpacing) {
                historyRevealArea(for: stream?.sessionKey)
                    .frame(maxHeight: .infinity)

                if let shellMessage {
                    shellMessageView(shellMessage)
                }

                ringControl(ringDiameter: ringDiameter)

                if showsChannelRow {
                    channelRow(for: stream)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, WatchShellMetrics.horizontalPadding)
            .padding(.vertical, WatchShellMetrics.verticalPadding)
        }
    }

    @ViewBuilder
    private func historyRevealArea(for sessionKey: String?) -> some View {
        let entries = conversationStore.visibleEntries(for: sessionKey)

        if !entries.isEmpty {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in
                            historyBubble(entry)
                        }

                        Color.clear
                            .frame(height: max(proxy.size.height, 1))
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
            }
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func historyBubble(_ entry: WatchConversationStore.Entry) -> some View {
        HStack {
            if entry.role == .assistant {
                bubbleBody(
                    entry.content,
                    frameAlignment: .leading,
                    textAlignment: .leading,
                    fill: Color.secondary.opacity(0.16)
                )
                Spacer(minLength: 22)
            } else {
                Spacer(minLength: 22)
                bubbleBody(
                    entry.content,
                    frameAlignment: .trailing,
                    textAlignment: .trailing,
                    fill: Color.accentColor.opacity(0.18)
                )
            }
        }
    }

    private func bubbleBody(
        _ text: String,
        frameAlignment: Alignment,
        textAlignment: TextAlignment,
        fill: Color
    ) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .multilineTextAlignment(textAlignment)
            .lineLimit(4)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
            )
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private func ringControl(ringDiameter: CGFloat) -> some View {
        ZStack {
            WaveformRingView(audioLevel: voiceSession.audioLevel, state: ringVisualState)
                .frame(width: ringDiameter, height: ringDiameter)

            Image(systemName: centerIcon)
                .font(.system(size: ringDiameter * 0.34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: max(44, ringDiameter * 0.4),
                    height: max(44, ringDiameter * 0.4)
                )
        }
        .contentShape(Circle())
        .onTapGesture {
            handleTapAction()
        }
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30, pressing: { isPressing in
            if !isPressing, holdVoiceActive {
                holdVoiceActive = false
                voiceSession.releaseHold()
            }
        }) {
            beginLongPressAction()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone")
        .accessibilityHint("Tap to talk or stop. Touch and hold for push to talk.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            handleTapAction()
        }
    }

    @ViewBuilder
    private func channelRow(for stream: StreamSession?) -> some View {
        if transport.transportState != .disconnected {
            HStack(spacing: 8) {
                Text(channelRowTitle(for: stream))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                if let routeIconName {
                    Image(systemName: routeIconName)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var centerIcon: String {
        switch voiceSession.voiceState {
        case .listening, .finalizing:
            return "waveform"
        case .speaking:
            return "speaker.wave.2.fill"
        case .sending:
            return "hourglass"
        case .idle, .error:
            return "mic.fill"
        }
    }

    private var ringVisualState: WatchRingVisualState {
        Self.ringVisualState(
            voiceState: voiceSession.voiceState,
            transportState: transport.transportState
        )
    }

    static func ringVisualState(
        voiceState: WatchVoiceSession.VoiceState,
        transportState: WatchProviderTransportState
    ) -> WatchRingVisualState {
        switch transportState {
        case .direct:
            return Self.isVoiceActive(voiceState) ? .activeDirect : .connectedDirect
        case .relay:
            return Self.isVoiceActive(voiceState) ? .activeRelay : .connectedRelay
        case .probing:
            return .connecting
        case .disconnected:
            return .disconnected
        }
    }

    private static func isVoiceActive(_ state: WatchVoiceSession.VoiceState) -> Bool {
        switch state {
        case .listening, .finalizing, .speaking:
            return true
        case .sending, .idle, .error:
            return false
        }
    }

    private var routeIconName: String? {
        switch transport.transportState {
        case .direct:
            return "wifi"
        case .relay:
            return "iphone"
        case .probing, .disconnected:
            return nil
        }
    }

    private func channelRowTitle(for stream: StreamSession?) -> String {
        if let stream {
            return stream.displayName
        }
        return presentationState.channelDisplayName
    }

    private func shellMessage(for stream: StreamSession?) -> String? {
        Self.shellMessage(
            hasProviderCredentials: presentationState.hasProviderCredentials,
            streamLoadState: channelManager.streamLoadState,
            streams: channelManager.streams,
            stream: stream
        )
    }

    nonisolated static func shellMessage(
        hasProviderCredentials: Bool,
        streamLoadState: WatchChannelManager.StreamLoadState,
        streams: [StreamSession],
        stream: StreamSession?
    ) -> String? {
        if !hasProviderCredentials {
            return "Open Clawline on iPhone to pair"
        }

        switch streamLoadState {
        case .idle, .loading:
            return "Loading channels…"
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unable to load channels" : trimmed
        case .loaded:
            guard stream == nil else { return nil }
            if streams.isEmpty {
                return "No channels"
            }
            return nil
        }
    }

    private func shellMessageView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private func handleTapAction() {
        switch voiceSession.voiceState {
        case .speaking:
            voiceSession.bargeIn()
        case .idle, .error:
            if transport.transportState == .disconnected || !presentationState.voiceInputAvailable {
                Task { await requestTextInput() }
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

                if let activeSession = channelManager.engineSessionKey ?? channelManager.currentSessionKey,
                   activeSession != message.sessionKey {
                    continue
                }

                await MainActor.run {
                    voiceSession.handleResponse(text: message.content)
                }
            }
        }
    }

    private func beginLongPressAction() {
        guard presentationState.voiceInputAvailable else { return }
        holdVoiceActive = true
        voiceSession.startHold()
    }

    @MainActor
    private func requestTextInput() async {
        guard let text = await WatchTextInputPresenter.requestPlainTextInput(),
              !text.isEmpty else { return }
        await presentationState.sendTextMessage(text)
    }
}
