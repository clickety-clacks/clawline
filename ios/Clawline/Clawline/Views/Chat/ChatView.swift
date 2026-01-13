//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

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
                // MessageInputBar handles its own offset for concentric alignment.
                // Pass raw safe area inset for keyboard detection.
                MessageInputBar(
                    text: $viewModel.messageInput,
                    isSending: viewModel.isSending,
                    bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                    onSend: { Task { await viewModel.send() } },
                    onAdd: { },
                    onFocusChange: { focused in isInputFocused = focused }
                )
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
