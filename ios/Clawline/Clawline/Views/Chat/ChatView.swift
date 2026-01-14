//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ChatView")

// MARK: - ⚠️⚠️⚠️ CRITICAL: DO NOT MODIFY WITHOUT READING ⚠️⚠️⚠️
//
// This file contains a non-obvious keyboard positioning fix that took 7+ iterations to solve.
// If you are an AI agent or developer planning to modify keyboard/focus/state handling here,
// STOP and read this entire comment block first.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE PROBLEM
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// MessageInputBar needs to reposition when keyboard appears:
// - Keyboard HIDDEN: Concentric alignment with device corners (~26pt from edges)
// - Keyboard VISIBLE: Positioned above keyboard with smaller gap
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHY "OBVIOUS" SOLUTIONS FAIL
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// SwiftUI ties @State, @FocusState, and onChange to a view's IDENTITY. When identity changes,
// ALL state resets silently. Views inside .safeAreaInset get RECREATED when geometry changes
// (like keyboard appearing), which resets their state.
//
// THESE APPROACHES WERE TRIED AND FAILED:
//
// 1. @FocusState in MessageInputBar
//    → View recreated on keyboard appear → @FocusState resets → onChange never fires
//
// 2. @State in MessageInputBar for keyboard tracking
//    → Same problem: view recreation resets state
//
// 3. UIKit keyboard notifications in MessageInputBar
//    → onReceive fires, but @State mutation is lost when view recreates
//
// 4. Passing computed Bool from parent
//    → .safeAreaInset content doesn't re-render on parent state change
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE SOLUTION (DO NOT CHANGE WITHOUT UNDERSTANDING)
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. @State isInputFocused lives HERE in ChatView (stable parent, survives geometry changes)
// 2. MessageInputBar reports focus via callback: onFocusChange: { isInputFocused = $0 }
// 3. Offset modifier applied HERE in ChatView (modifiers on .safeAreaInset content DO update)
//
// KEY INSIGHT: .safeAreaInset content body doesn't re-render on parent state change,
// BUT modifiers applied TO that content from the parent DO update.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// IF YOU MUST MODIFY THIS CODE
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. Understand SwiftUI view identity and state lifetime
// 2. Understand why .safeAreaInset causes view recreation
// 3. Test on device with keyboard show/hide cycling
// 4. Verify concentric alignment visually (equal padding on all sides when keyboard hidden)
// 5. The working solution is tagged: `working-keyboard-behaviors`
//
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct ChatView: View {
    @State private var viewModel: ChatViewModel

    // ⚠️ CRITICAL: This state MUST live here in ChatView, NOT in MessageInputBar.
    // MessageInputBar is inside .safeAreaInset and gets recreated on geometry changes.
    // State in recreated views resets silently. See header comment for full explanation.
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
            // ═══════════════════════════════════════════════════════════════════════════════
            // ⚠️ CRITICAL SECTION - READ HEADER COMMENT BEFORE MODIFYING ⚠️
            // ═══════════════════════════════════════════════════════════════════════════════
            //
            // This .safeAreaInset block is where the keyboard positioning fix is implemented.
            // The content inside gets RECREATED when geometry changes (keyboard show/hide).
            //
            // WHY THE OFFSET IS APPLIED HERE (not in MessageInputBar):
            // - MessageInputBar's body won't re-render when parent state changes
            // - BUT modifiers applied TO MessageInputBar from here DO update
            // - So we calculate offset here using parent's @State isInputFocused
            //
            // WHY onFocusChange CALLBACK (not @FocusState in MessageInputBar):
            // - @FocusState in MessageInputBar resets when view recreates
            // - Callback allows MessageInputBar to report focus to stable parent
            // - Parent's @State survives the geometry change
            //
            .safeAreaInset(edge: .bottom) {
                // Positive offset pushes bar DOWN into safe area for concentric alignment.
                // When focused (keyboard visible), offset is 0 (bar sits above keyboard).
                let rawOffset = calculateConcentricOffset(bottomInset: geometry.safeAreaInsets.bottom)
                let concentricOffset = isInputFocused ? 0 : rawOffset

                MessageInputBar(
                    text: $viewModel.messageInput,
                    isSending: viewModel.isSending,
                    bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                    isKeyboardVisible: isInputFocused,
                    onSend: { Task { await viewModel.send() } },
                    onAdd: { },
                    // ⚠️ This callback is how focus state survives view recreation.
                    // DO NOT replace with @Binding or try to use @FocusState directly.
                    onFocusChange: { focused in isInputFocused = focused }
                )
                // ⚠️ Offset MUST be applied here, not inside MessageInputBar.
                // See header comment for why.
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
