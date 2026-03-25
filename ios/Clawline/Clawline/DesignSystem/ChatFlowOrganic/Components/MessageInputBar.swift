//
//  MessageInputBar.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import Foundation

// MARK: - ⚠️⚠️⚠️ CRITICAL: READ ChatView.swift HEADER BEFORE MODIFYING ⚠️⚠️⚠️
//
// This view is used inside .safeAreaInset in ChatView. That context has special behavior:
//
// 1. THIS VIEW GETS RECREATED when geometry changes (e.g., keyboard appears)
// 2. Any @State defined HERE will be RESET when that happens
// 3. onChange handlers HERE may NEVER FIRE because the view recreates before they trigger
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHAT THIS MEANS FOR YOU
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// ❌ DO NOT add @State here for keyboard/focus tracking - it will reset
// ❌ DO NOT expect onChange to fire reliably - view may recreate first
// ❌ DO NOT apply positioning offsets here - they won't update on parent state change
//
// ✅ DO use callbacks (like onFocusChange) to report state to parent
// ✅ DO let parent (ChatView) own state that needs to survive geometry changes
// ✅ DO let parent apply offset/positioning modifiers
//
// The @FocusState here was replaced by RichTextEditor focus callbacks that update parent state.
// The parent's @State survives; ours does not.
//
// See ChatView.swift header comment for the full explanation and rescue tag: `working-keyboard-behaviors`.
// ═══════════════════════════════════════════════════════════════════════════════════════════

struct MessageInputBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @Binding var content: NSAttributedString
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    var placeholderText: String = "Message"
    let fontScaleChangeSequence: Int
    var resetToken: Int
    let canSend: Bool
    let isSending: Bool
    let isStagingAttachments: Bool
    let connectionState: SendButtonConnectionState
    let focusTrigger: Int
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    /// Keyboard visibility state owned by parent view to survive geometry changes.
    let isKeyboardVisible: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onReconnect: () -> Void
    let onAdd: () -> Void
    let onFocusChange: (Bool) -> Void
    let onTextEditActivity: () -> Void
    var onPasteImages: (([UIImage]) -> Void)?

    @State private var editorHeight: CGFloat = 44
    @State private var cachedMaxBarWidth: CGFloat?
    let isCompact: Bool

    private var metrics: MessageInputBarMetrics {
        MessageInputBarMetrics(
            horizontalSizeClass: isCompact ? .compact : .regular,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: deviceCornerRadius,
            isFieldFocused: isKeyboardVisible
        )
    }

    private var deviceCornerRadius: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    private var inputHeight: CGFloat {
        if content.length == 0 {
            return metrics.inputBarHeight
        }
        return max(editorHeight, metrics.inputBarHeight)
    }

    private var isSingleLine: Bool {
        editorHeight <= metrics.inputBarHeight + 0.5
    }

    private var inputShape: AnyShape {
        if isSingleLine {
            return AnyShape(Capsule())
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var containerPadding: CGFloat {
        ChatFlowTheme.Metrics(isCompact: isCompact).inputBarPaddingHorizontal
    }

    private func refreshMaxBarWidth() {
        guard !isCompact else {
            cachedMaxBarWidth = nil
            return
        }

        let themeMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let bodyFont = UIFont.clawline(.bodyText)
        let textWidth = ChatFlowTheme.maxLineWidth(bodyFont: bodyFont)
        let chromeWidth = (themeMetrics.inputBarPaddingHorizontal * 2)
            + metrics.inputBarHeight
            + metrics.inputBarHeight
            + (MessageInputBarMetrics.elementSpacing * 2)
        cachedMaxBarWidth = textWidth + chromeWidth
    }

    // #61: On visionOS, keep the input bar in dark mode regardless of the global theme toggle.
    // The rest of the UI still respects `settings.appearanceMode`.
    private var isLightModeForInputBar: Bool {
#if os(visionOS)
        return false
#else
        return settings.appearanceMode == .light
#endif
    }

    private var inputBarColorScheme: ColorScheme {
        isLightModeForInputBar ? .light : .dark
    }

    private var addButtonForeground: Color {
#if os(visionOS)
        return isLightModeForInputBar ? .black : .white
#else
        return .primary
#endif
    }

    private var appearanceIconColor: Color { addButtonForeground }

    private var appearanceIconName: String {
        settings.appearanceMode == .dark ? "moon.stars" : "sun.max"
    }

    private var isLightMode: Bool {
        settings.appearanceMode == .light
    }

    private var visionOSBorderColor: Color {
        isLightModeForInputBar
            ? ChatFlowTheme.ink(.light).opacity(0.95)
            : Color.white.opacity(0.5)
    }

    private var hasSubmittableDraft: Bool {
        !content.isEffectivelyEmpty
    }

    private var editorOpacity: Double {
        isSending ? 0.5 : 1
    }

    static func shouldDispatchEditorSubmitIntent(
        isSending: Bool,
        hasSubmittableDraft: Bool
    ) -> Bool {
        !isSending && hasSubmittableDraft
    }

    static func reconnectBubbleScale(phase: CGFloat) -> CGFloat {
        let clampedPhase = min(1, max(0, phase))
        return 0.75 + (0.25 * clampedPhase)
    }

    private func handleEditorSubmitIntent() {
        guard Self.shouldDispatchEditorSubmitIntent(
            isSending: isSending,
            hasSubmittableDraft: hasSubmittableDraft
        ) else { return }
        onSend()
    }

    var body: some View {
        let _ = fontScaleChangeSequence
        HStack(alignment: .bottom, spacing: MessageInputBarMetrics.elementSpacing) {
#if os(visionOS)
            // Appearance toggle button
            Button(action: {
                settings.toggleAppearanceMode()
            }) {
                Image(systemName: appearanceIconName)
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(appearanceIconColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(visionOSBorderColor, lineWidth: 1)
            }
#else
            .glassEffect(.regular.interactive(), in: Circle())
            .background {
                if isLightMode {
                    Circle()
                        .fill(Color.primary.opacity(0.15))
                }
            }
#endif
            .accessibilityLabel("Toggle appearance")
#endif

            // Add button - send-style for reliable hit testing (left side)
            Button(action: {
                onAdd()
            }) {
                Image(systemName: "plus")
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(addButtonForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle()
                    .stroke(visionOSBorderColor, lineWidth: 1)
            )
#else
            .glassEffect(.regular.interactive(), in: Circle())
#endif
            .accessibilityLabel("Add attachment")
            .disabled(isSending)

            MessageEditorChrome(
                content: $content,
                selectionRange: $selectionRange,
                pendingInsertions: $pendingInsertions,
                editorHeight: $editorHeight,
                fontScaleChangeSequence: fontScaleChangeSequence,
                resetToken: resetToken,
                focusTrigger: focusTrigger,
                inputHeight: inputHeight,
                inputShape: inputShape,
                editorOpacity: editorOpacity,
                onSubmitRequested: handleEditorSubmitIntent,
                onFocusChange: onFocusChange,
                onTextEditActivity: onTextEditActivity,
                onPasteImages: onPasteImages,
                placeholderText: placeholderText,
                isLightModeForInputBar: isLightModeForInputBar,
                visionOSBorderColor: visionOSBorderColor
            )

            MessageSendControl(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState,
                sendButtonSize: metrics.inputBarHeight,
                inputBarColorScheme: inputBarColorScheme,
                uiColorScheme: colorScheme,
                visionOSBorderColor: visionOSBorderColor,
                onSend: onSend,
                onCancel: onCancel,
                onReconnect: onReconnect
            )
        }
        .padding(.horizontal, containerPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(maxWidth: cachedMaxBarWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: content.length) { _, newValue in
            guard newValue == 0 else { return }
            editorHeight = metrics.inputBarHeight
        }
        .onAppear {
            refreshMaxBarWidth()
        }
        .onChange(of: isCompact) { _, _ in
            refreshMaxBarWidth()
        }
        .onChange(of: settings.fontScale) { _, _ in
            refreshMaxBarWidth()
        }
    }
}

private struct MessageEditorChrome: View {
    @Binding var content: NSAttributedString
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    @Binding var editorHeight: CGFloat
    let fontScaleChangeSequence: Int
    let resetToken: Int
    let focusTrigger: Int
    let inputHeight: CGFloat
    let inputShape: AnyShape
    let editorOpacity: Double
    let onSubmitRequested: () -> Void
    let onFocusChange: (Bool) -> Void
    let onTextEditActivity: () -> Void
    var onPasteImages: (([UIImage]) -> Void)?
    let placeholderText: String
    let isLightModeForInputBar: Bool
    let visionOSBorderColor: Color

    // Local single source of truth for editor chrome without introducing a new formal type yet.
    private var chrome: (tintColor: UIColor, textColor: UIColor) {
#if os(visionOS)
        let tint = isLightModeForInputBar ? ChatFlowTheme.ink(.light) : ChatFlowTheme.ink(.dark)
        return (UIColor(tint), .white)
#else
        let tint = isLightModeForInputBar ? ChatFlowTheme.sage(.light) : ChatFlowTheme.sage(.dark)
        return (UIColor(tint), .label)
#endif
    }

    private var placeholderColor: Color {
#if os(visionOS)
        isLightModeForInputBar
            ? ChatFlowTheme.ink(.light).opacity(0.6)
            : ChatFlowTheme.ink(.dark).opacity(0.6)
#else
        .secondary
#endif
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RichTextEditor(
                attributedText: $content,
                calculatedHeight: $editorHeight,
                selectionRange: $selectionRange,
                pendingInsertions: $pendingInsertions,
                fontScaleChangeSequence: fontScaleChangeSequence,
                resetToken: resetToken,
                focusTrigger: focusTrigger,
                isEditable: true,
                tintColor: chrome.tintColor,
                textColor: chrome.textColor,
                onFocusChange: onFocusChange,
                onTextEditActivity: onTextEditActivity,
                onSubmit: {
                    onSubmitRequested()
                },
                onPasteImages: onPasteImages,
                trailingPadding: 20
            )
            .opacity(editorOpacity)

            if content.length == 0 {
                Text(placeholderText)
                    .font(.clawline(.bodyText))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.7)
                    .foregroundColor(placeholderColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.leading, 20)
                    .padding(.trailing, 20)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: inputHeight)
        .frame(maxWidth: .infinity, alignment: .bottom)
#if os(visionOS)
        .background(.regularMaterial, in: inputShape)
#else
        .glassEffect(.regular, in: inputShape)
#endif
        .overlay {
#if os(visionOS)
            inputShape
                .stroke(visionOSBorderColor, lineWidth: 1)
#endif
        }
    }
}

private struct MessageSendControl: View {
    private enum BubbleVisualState: Equatable {
        case ghost
        case active
        case reconnecting
        case error
    }

    let isSending: Bool
    let canSend: Bool
    let isStagingAttachments: Bool
    let connectionState: SendButtonConnectionState
    let sendButtonSize: CGFloat
    let inputBarColorScheme: ColorScheme
    let uiColorScheme: ColorScheme
    let visionOSBorderColor: Color
    let onSend: () -> Void
    let onCancel: () -> Void
    let onReconnect: () -> Void

    private var isReconnecting: Bool { connectionState == .reconnecting }
    private var isDisconnected: Bool { connectionState == .disconnected }
    private var isStagingSendGate: Bool {
        connectionState == .connected && isStagingAttachments && !isSending && !canSend
    }
    private var sendActionEnabled: Bool { isSending || canSend || isDisconnected }
    private var sendIconColor: Color { .white }
    private let reconnectPulseDuration: TimeInterval = 0.8

    private var bubbleVisualState: BubbleVisualState {
        switch connectionState {
        case .connected:
            return (sendActionEnabled || isStagingSendGate) ? .active : .ghost
        case .reconnecting:
            return .reconnecting
        case .disconnected:
            return .error
        }
    }

    private var bubbleColor: Color {
        let activeColor: Color = {
#if os(visionOS)
            ChatFlowTheme.sage(inputBarColorScheme)
#else
            ChatFlowTheme.sage(uiColorScheme)
#endif
        }()
        switch bubbleVisualState {
        case .ghost:
            return activeColor
        case .active:
            return activeColor
        case .reconnecting:
            return ChatFlowTheme.connectionReconnecting(inputBarColorScheme)
        case .error:
            return ChatFlowTheme.connectionDisconnected(inputBarColorScheme)
        }
    }

    private func reconnectPulsePhase(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: reconnectPulseDuration) / reconnectPulseDuration
        return CGFloat(0.5 - 0.5 * cos(phase * 2 * .pi))
    }

    private func bubbleScale(at date: Date) -> CGFloat {
        switch bubbleVisualState {
        case .ghost:
            return 0
        case .active, .error:
            return 1
        case .reconnecting:
            return MessageInputBar.reconnectBubbleScale(phase: reconnectPulsePhase(at: date))
        }
    }

    var body: some View {
        Button(action: {
            if isSending {
                onCancel()
                return
            }
            switch connectionState {
            case .connected:
                onSend()
            case .disconnected:
                onReconnect()
            case .reconnecting:
                break
            }
        }) {
            Group {
                if isStagingSendGate {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(sendIconColor)
                        .scaleEffect(0.9)
                } else {
                    Image(systemName: isDisconnected ? "arrow.clockwise" : "paperplane.fill")
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(sendIconColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .frame(width: sendButtonSize, height: sendButtonSize)
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isReconnecting)) { context in
                Circle()
                    .fill(bubbleColor)
                    .frame(width: sendButtonSize, height: sendButtonSize)
                    .scaleEffect(bubbleScale(at: context.date))
            }
        }
#if os(visionOS)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(visionOSBorderColor, lineWidth: 1))
#else
        .glassEffect(.regular.interactive(), in: Circle())
#endif
        .buttonStyle(.plain)
        .allowsHitTesting(sendActionEnabled && !isReconnecting)
        .accessibilityLabel(
            isReconnecting ? "Reconnecting" :
                (isStagingSendGate ? "Staging attachments" :
                    (isDisconnected ? "Disconnected. Tap to reconnect." : "Send message"))
        )
        .id("send-button")
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: isSending)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: canSend)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: connectionState)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: bubbleVisualState)
    }
}

#Preview("Message Input") {
    @Previewable @State var content = NSAttributedString(string: "Hello")
    @Previewable @State var selection = NSRange(location: 5, length: 0)
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                content: $content,
                selectionRange: $selection,
                pendingInsertions: .constant([]),
                fontScaleChangeSequence: 0,
                resetToken: 0,
                canSend: true,
                isSending: false,
                isStagingAttachments: false,
                connectionState: .connected,
                focusTrigger: 0,
                bottomSafeAreaInset: 34,
                isKeyboardVisible: false,
                onSend: {},
                onCancel: {},
                onReconnect: {},
                onAdd: {},
                onFocusChange: { _ in },
                onTextEditActivity: {},
                onPasteImages: nil,
                isCompact: true
            )
        }
}
