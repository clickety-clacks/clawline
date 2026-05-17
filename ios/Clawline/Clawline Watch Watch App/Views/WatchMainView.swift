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
            .accessibilityIdentifier("watch-main-root")
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
                if !WatchUITestMode.isEnabled {
                    channelManager.retryLoadingIfNeeded(for: transport.transportState)
                    observeIncomingResponses()
                }
            }
            .onChange(of: transport.transportState) { _, newValue in
                if !WatchUITestMode.isEnabled {
                    channelManager.retryLoadingIfNeeded(for: newValue)
                }
                WKInterfaceDevice.current().play(.click)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, !WatchUITestMode.isEnabled else { return }
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

            unifiedScrollSurface(
                stream: stream,
                availableSize: availableSize,
                ringDiameter: ringDiameter,
                shellMessage: shellMessage,
                showsChannelRow: showsChannelRow
            )
        }
    }

    @ViewBuilder
    private func unifiedScrollSurface(
        stream: StreamSession?,
        availableSize: CGSize,
        ringDiameter: CGFloat,
        shellMessage: String?,
        showsChannelRow: Bool
    ) -> some View {
        let entries = conversationStore.visibleEntries(for: stream?.sessionKey)
        let pagedHistory = Self.pagedHistory(from: entries)
        let viewportHeight = max(0, availableSize.height + WatchShellMetrics.pageOverscan)
        let bottomAnchorID = "watch-shell-bottom-\(stream?.sessionKey ?? placeholderPageKey)"

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: WatchShellMetrics.shellSpacing) {
                    ForEach(pagedHistory.historyPages) { page in
                        historyPage(
                            page.entries,
                            stream: stream,
                            height: viewportHeight,
                            ringDiameter: ringDiameter,
                            showsChannelRow: showsChannelRow
                        )
                            .id(page.id)
                    }

                    currentConversationPage(
                        entries: pagedHistory.currentPage?.entries ?? [],
                        stream: stream,
                        height: viewportHeight,
                        ringDiameter: ringDiameter,
                        shellMessage: shellMessage,
                        showsChannelRow: showsChannelRow
                    )
                        .id(bottomAnchorID)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
                .padding(.horizontal, WatchShellMetrics.horizontalPadding)
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom)
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .accessibilityLabel("Unified conversation and microphone surface")
            .accessibilityHint("Swipe to move through conversation history. The microphone stays in the same vertical scroll surface below the newest messages.")
            .accessibilityIdentifier("watch-unified-scroll-surface")
            .task(id: entries.last?.id ?? shellMessage ?? bottomAnchorID) {
                await settleAtNewestPage(proxy: proxy, bottomAnchorID: bottomAnchorID)
            }
        }
    }

    private func settleAtNewestPage(proxy: ScrollViewProxy, bottomAnchorID: String) async {
        await Task.yield()
        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        await Task.yield()
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func currentConversationPage(
        entries: [WatchConversationStore.Entry],
        stream: StreamSession?,
        height: CGFloat,
        ringDiameter: CGFloat,
        shellMessage: String?,
        showsChannelRow: Bool
    ) -> some View {
        VStack(spacing: WatchShellMetrics.shellSpacing) {
            Spacer(minLength: 0)

            ForEach(entries) { entry in
                historyBubble(entry)
            }

            if let shellMessage {
                shellMessageView(shellMessage)
            }

            ringControl(ringDiameter: ringDiameter)

            if showsChannelRow {
                channelRow(for: stream)
            }

            Color.clear
                .frame(height: WatchShellMetrics.controlBottomBreathingRoom)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottom)
    }

    private func historyPage(
        _ entries: [WatchConversationStore.Entry],
        stream: StreamSession?,
        height: CGFloat,
        ringDiameter: CGFloat,
        showsChannelRow: Bool
    ) -> some View {
        VStack(spacing: WatchShellMetrics.shellSpacing) {
            Spacer(minLength: 0)

            ForEach(entries) { entry in
                historyBubble(entry)
            }

            if showsChannelRow {
                channelRow(for: stream)
            }

            Color.clear
                .frame(height: WatchShellMetrics.controlBottomBreathingRoom)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottom)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    static func pagedHistory(from entries: [WatchConversationStore.Entry]) -> WatchPagedHistory {
        let pages = historyPages(from: entries)
        guard let currentPage = pages.last else {
            return WatchPagedHistory(historyPages: [], currentPage: nil)
        }
        return WatchPagedHistory(historyPages: Array(pages.dropLast()), currentPage: currentPage)
    }

    static func historyPages(from entries: [WatchConversationStore.Entry]) -> [WatchHistoryPage] {
        let pageSize = WatchShellMetrics.historyEntriesPerPage
        guard pageSize > 0 else { return [] }

        return stride(from: 0, to: entries.count, by: pageSize).map { start in
            let end = min(start + pageSize, entries.count)
            let pageEntries = Array(entries[start..<end])
            let firstID = pageEntries.first?.id ?? "empty"
            let lastID = pageEntries.last?.id ?? firstID
            return WatchHistoryPage(id: "watch-history-page_\(firstID)_\(lastID)", entries: pageEntries)
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
        Button {} label: {
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
            .frame(width: ringDiameter, height: ringDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            TapGesture().onEnded {
                handleTapAction()
            }
        )
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30, pressing: { isPressing in
            if !isPressing, holdVoiceActive {
                holdVoiceActive = false
                voiceSession.releaseHold()
            }
        }) {
            beginLongPressAction()
        }
        .accessibilityLabel("Microphone")
        .accessibilityHint("Tap to talk or stop. Touch and hold for push to talk.")
        .accessibilityIdentifier("watch-ring-control")
        .accessibilityAction(.default) {
            handleTapAction()
        }
    }

    @ViewBuilder
    private func channelRow(for stream: StreamSession?) -> some View {
        if transport.transportState != .disconnected {
            HStack(spacing: 6) {
                Text(channelRowTitle(for: stream))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)

                routeChipView
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("watch-channel-row")
        }
    }


    @ViewBuilder
    private var routeChipView: some View {
        if let routeIconName {
            Image(systemName: routeIconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(routeAccessibilityLabel)
                .accessibilityIdentifier("watch-route-chip")
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

    private var routeAccessibilityLabel: String {
        switch transport.transportState {
        case .direct:
            return "Direct"
        case .relay:
            return "Via iPhone"
        case .probing:
            return "Reconnecting"
        case .disconnected:
            return "No Connection"
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
            transportState: transport.transportState,
            statusText: presentationState.statusText,
            voiceState: voiceSession.voiceState,
            streamLoadState: channelManager.streamLoadState,
            streams: channelManager.streams,
            stream: stream
        )
    }

    static func shellMessage(
        hasProviderCredentials: Bool,
        transportState: WatchProviderTransportState,
        statusText: String,
        voiceState: WatchVoiceSession.VoiceState = .idle,
        streamLoadState: WatchChannelManager.StreamLoadState,
        streams: [StreamSession],
        stream: StreamSession?
    ) -> String? {
        if !hasProviderCredentials {
            return "Open Clawline on iPhone to pair"
        }

        switch transportState {
        case .probing, .disconnected:
            return statusText
        case .direct, .relay:
            break
        }

        if shouldShowVoiceStatus(voiceState) {
            return statusText
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

    private static func shouldShowVoiceStatus(_ state: WatchVoiceSession.VoiceState) -> Bool {
        switch state {
        case .listening, .finalizing, .sending, .speaking, .error:
            return true
        case .idle:
            return false
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
            voiceSession.startTap()
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
        holdVoiceActive = true
        voiceSession.startHold()
    }
}


struct WatchHistoryPage: Identifiable, Equatable {
    let id: String
    let entries: [WatchConversationStore.Entry]
}

struct WatchPagedHistory: Equatable {
    let historyPages: [WatchHistoryPage]
    let currentPage: WatchHistoryPage?
}


private enum WatchUITestMode {
    static var isEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
#if WATCH_UI_SCENARIO_DIRECT || WATCH_UI_SCENARIO_RELAY || WATCH_UI_SCENARIO_RECONNECTING || WATCH_UI_SCENARIO_DISCONNECTED
        return true
#else
        return processInfo.environment["WATCH_UI_TEST_SCENARIO"]?.isEmpty == false
            || processInfo.arguments.contains("-WATCH_UI_TEST_SCENARIO")
            || processInfo.arguments.contains { $0.hasPrefix("WATCH_UI_TEST_SCENARIO=") }
#endif
    }
}
