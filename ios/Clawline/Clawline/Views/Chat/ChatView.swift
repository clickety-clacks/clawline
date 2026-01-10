//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit

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
// You might think to use @FocusState or keyboard notifications to detect keyboard state.
// DON'T. Here's why:
//
// State-based keyboard detection (@FocusState, UIResponder.keyboardWillChangeFrameNotification)
// updates ASYNCHRONOUSLY from SwiftUI's layout-based keyboard avoidance. This causes a
// visible padding jump on BOTH single-line and multiline TextFields:
//
//   1. User taps text field
//   2. SwiftUI's layout system adjusts safe areas and moves content (IMMEDIATE, same frame)
//   3. @FocusState or keyboard notification updates state (DELAYED, different frame)
//   4. Our padding depends on state, so it's still 26pt while view has already moved
//   5. Eventually state updates, padding changes to 12pt
//   6. Visible jump as padding corrects itself
//
// The core issue: SwiftUI's keyboard avoidance operates at the LAYOUT level, but @FocusState
// and keyboard notifications operate at the STATE level. These are not synchronized.
//
// ## The Solution: Safe Area Insets as Source of Truth
// Instead of relying on state-based detection, we track safe area inset changes via
// GeometryReader. When the keyboard appears, SwiftUI increases safeAreaInsets.bottom.
// Crucially, this change happens in the SAME LAYOUT PASS as the keyboard animation,
// so our padding update is perfectly synchronized.
//
// We capture the baseline safe area on appear (~34pt for home indicator on Face ID
// devices) and treat "keyboard visible" as safeAreaInsets.bottom > baseline + threshold.
//
// ## What NOT to Change
// - DO NOT replace isKeyboardVisible with @FocusState - it will break (async with layout)
// - DO NOT replace isKeyboardVisible with keyboard notifications - it will break (async with layout)
// - DO NOT remove the GeometryReader - it's essential for tracking safe area
// - DO NOT change the threshold (10pt) without testing on physical device
//
// ## Why This Works
// Safe area insets are part of SwiftUI's layout system. When the keyboard appears:
// - SwiftUI adjusts safeAreaInsets.bottom in the layout pass
// - Our onChange(of: geometry.safeAreaInsets.bottom) fires in the SAME pass
// - bottomPadding updates synchronously with keyboard avoidance
// - No jump because everything happens in one frame
//
// If you need to modify keyboard handling, READ scratch/keyboard-fix-iterations.md first.
// It documents 6 failed approaches so you don't repeat them.

struct ChatView: View {
    @State private var viewModel: ChatViewModel

    // Note: isInputFocused is used by MessageInputBar for TextField focus binding.
    // DO NOT use this for keyboard detection - see comment block above for why.
    @FocusState private var isInputFocused: Bool

    // Safe area inset tracking for keyboard detection.
    // baselineSafeAreaBottom: The safe area when keyboard is hidden (home indicator, ~34pt)
    // currentSafeAreaBottom: The current safe area (increases when keyboard appears)
    // This approach works because safe area changes are synchronized with keyboard animation.
    @State private var baselineSafeAreaBottom: CGFloat = 0
    @State private var currentSafeAreaBottom: CGFloat = 0

    init(auth: any AuthManaging, chatService: any ChatServicing, settings: SettingsManager) {
        _viewModel = State(initialValue: ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: settings
        ))
    }

    // Device corner radius for concentric alignment.
    // Face ID devices have ~50pt corner radius, home button devices have 0.
    private var deviceCornerRadius: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    private let inputBarHeight: CGFloat = 48

    // Concentric padding formula: deviceCornerRadius - elementRadius
    // For 48pt height element, radius = 24pt. So 50pt - 24pt = 26pt.
    // This aligns the input bar's corners concentrically with the device bezel.
    private var concentricPadding: CGFloat {
        max(deviceCornerRadius - (inputBarHeight / 2), 8)
    }

    // Keyboard detection via safe area insets.
    // When keyboard appears, safeAreaInsets.bottom increases significantly (keyboard height).
    // The 10pt threshold prevents false positives from minor safe area fluctuations.
    // DO NOT replace this with @FocusState or keyboard notifications - see header comment.
    private var isKeyboardVisible: Bool {
        currentSafeAreaBottom > baselineSafeAreaBottom + 10
    }

    // Bottom padding switches based on keyboard visibility:
    // - Keyboard hidden: Use concentric padding (26pt) for visual alignment with device corners
    // - Keyboard visible: Use 12pt for comfortable spacing above keyboard
    private var bottomPadding: CGFloat {
        isKeyboardVisible ? 12 : concentricPadding
    }

    var body: some View {
        // GeometryReader is REQUIRED for safe area inset tracking.
        // This is how we detect keyboard state reliably - DO NOT REMOVE.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                messageList
                    .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    if let error = viewModel.error {
                        errorBanner(error)
                    }

                    MessageInputBar(
                        text: $viewModel.messageInput,
                        isSending: viewModel.isSending,
                        isInputFocused: $isInputFocused,
                        onSend: { Task { await viewModel.send() } },
                        onAdd: { },
                        bottomPadding: bottomPadding
                    )
                }
            }
            // Track safe area changes - this fires when keyboard appears/disappears.
            // The update happens in the same frame as keyboard animation, ensuring
            // our padding change is perfectly synchronized with the keyboard.
            .onChange(of: geometry.safeAreaInsets.bottom) { _, newValue in
                currentSafeAreaBottom = newValue
            }
            .onAppear {
                // Capture baseline safe area BEFORE keyboard ever appears.
                // On Face ID devices, this is ~34pt (home indicator area).
                // We compare against this to detect when keyboard adds to safe area.
                baselineSafeAreaBottom = geometry.safeAreaInsets.bottom
                currentSafeAreaBottom = geometry.safeAreaInsets.bottom
            }
        }
        // Allow content to extend into the bottom safe area for concentric alignment.
        // We handle safe area manually via bottomPadding.
        .ignoresSafeArea(.container, edges: .bottom)
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
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

private final class PreviewChatService: ChatServicing {
    var incomingMessages: AsyncStream<Message> {
        AsyncStream { _ in }
    }
    var connectionState: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }
    func connect(token: String) async throws {}
    func disconnect() {}
    func send(content: String, attachments: [Attachment]) async throws {}
}

#Preview("Empty Chat") {
    ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager()
    )
}

#Preview("With Messages") {
    ChatView(
        auth: PreviewAuthManager(),
        chatService: PreviewChatService(),
        settings: SettingsManager()
    )
}
