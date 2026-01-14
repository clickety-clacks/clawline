//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ChatView")

// MARK: - ⚠️ IMPORTANT: Keyboard Positioning Fix - READ BEFORE MODIFYING ⚠️
//
// This view contains a non-obvious fix for keyboard positioning. The fix took 7 iterations
// to get right. Full history documented in: scratch/keyboard-fix-iterations.md
//
// ## The Problem
// The MessageInputBar needs different bottom padding depending on keyboard state:
// - Keyboard HIDDEN: 26pt (concentric alignment with device corner radius)
// - Keyboard VISIBLE: 12pt (comfortable gap above keyboard)
//
// ## Why Standard Approaches FAIL
// State-based keyboard detection (@FocusState, keyboardWillChangeFrame) is asynchronous
// relative to SwiftUI’s layout-driven keyboard avoidance and causes visible jumps.
//
// ## The Solution: Safe Area Insets as Source of Truth
// Track safeAreaInsets.bottom; when it grows, the keyboard is on screen. This fires in
// the same layout pass as the keyboard animation, so padding updates are in sync.
//
// If you need to modify keyboard handling, READ scratch/keyboard-fix-iterations.md first.

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var isInputFocused = false
    @State private var isKeyboardVisible = false

    // UIKit keyboard notifications - owned here to survive geometry changes
    private let keyboardWillShow = NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
    private let keyboardWillHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying) {
        _viewModel = State(initialValue: ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: settings,
            device: device
        ))
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass


    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                messageList(topInset: geometry.safeAreaInsets.top + 32)
                    .frame(maxHeight: .infinity)

                if let error = viewModel.error {
                    errorBanner(error)
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Offset applied here in ChatView where @State lives - ensures update on state change.
                // safeAreaInset content doesn't re-render on parent state change otherwise.
                // Offset for concentric alignment with device corner radius.
                // Positive offset pushes bar DOWN into safe area to reduce bottom gap to ~26pt.
                let rawOffset = calculateConcentricOffset(bottomInset: geometry.safeAreaInsets.bottom)
                let concentricOffset = isKeyboardVisible ? 0 : rawOffset

                MessageInputBar(
                    text: $viewModel.messageInput,
                    isSending: viewModel.isSending,
                    bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                    isKeyboardVisible: isKeyboardVisible,
                    onSend: { Task { await viewModel.send() } },
                    onAdd: { },
                    onFocusChange: { focused in isInputFocused = focused }
                )
                .offset(y: concentricOffset)
                .animation(.easeOut(duration: 0.25), value: concentricOffset)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            ChatFlowTheme.pageBackground(colorScheme)
                .ignoresSafeArea()
                .overlay(NoiseOverlayView().ignoresSafeArea())
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onReceive(keyboardWillShow) { _ in
            isKeyboardVisible = true
        }
        .onReceive(keyboardWillHide) { _ in
            isKeyboardVisible = false
        }
    }

    private func messageList(topInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                let isCompact = horizontalSizeClass == .compact
                let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
                let maxWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)

                FlowLayout(
                    itemSpacing: metrics.flowGap,
                    rowSpacing: metrics.flowGap,
                    maxLineWidth: maxWidth,
                    isCompact: isCompact
                ) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(metrics.containerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.top, topInset, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .foregroundColor(.white)
            Spacer()
            Button("Dismiss") { viewModel.clearError() }
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.red)
    }

    /// Calculate concentric offset to align input bar with device corner radius.
    /// Returns ~16pt when keyboard hidden, 0pt when keyboard visible (handled by caller).
    private func calculateConcentricOffset(bottomInset: CGFloat) -> CGFloat {
        // Device corner radius: ~50pt for Face ID devices, 0pt for home button devices
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        let deviceCornerRadius: CGFloat = hasRoundedCorners ? 50 : 0

        let inputBarHeight: CGFloat = 48
        let elementSpacing: CGFloat = 8
        let concentricPadding = max(deviceCornerRadius - (inputBarHeight / 2), 8)

        let minSafeArea: CGFloat = 34
        let maxSafeArea: CGFloat = 100
        let maxOffset = max(minSafeArea - concentricPadding + elementSpacing, 0)
        let t = (bottomInset - minSafeArea) / (maxSafeArea - minSafeArea)
        let clampedT = max(0, min(1, t))
        return maxOffset * (1 - clampedT)
    }
}

// MARK: - Previews

@Observable
private final class PreviewAuthManager: AuthManaging {
    var isAuthenticated = true
    var currentUserId: String? = "preview-user"
    var token: String? = "preview-token"
    func storeCredentials(token: String, userId: String) {}
    func clearCredentials() {}
}

private struct PreviewDevice: DeviceIdentifying {
    let deviceId = "preview-device"
}

private final class PreviewChatService: ChatServicing {
    var incomingMessages: AsyncStream<Message> {
        AsyncStream { _ in }
    }
    var connectionState: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }
    func connect(token: String, lastMessageId: String?) async throws {}
    func disconnect() {}
    func send(id: String, content: String, attachments: [Attachment]) async throws {}
}

#Preview("Empty Chat") {
    let device = PreviewDevice()
    return ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device
    )
}

#Preview("With Messages") {
    let device = PreviewDevice()
    return ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device
    )
}
