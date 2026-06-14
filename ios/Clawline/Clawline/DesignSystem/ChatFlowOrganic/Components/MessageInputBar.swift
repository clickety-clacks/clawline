//
//  MessageInputBar.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import Foundation
import Observation
import OSLog
import Combine

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessageInputBar")

// The input bar is hosted in a pinned UIKit container, so parent value changes do not always
// rebuild its content closure. Keep the send button state in a stable observable store.
@Observable
@MainActor
final class SendButtonConnectionStateStore {
    var value: SendButtonConnectionState

    init(value: SendButtonConnectionState = .disconnected) {
        self.value = value
    }
}

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
    enum SendButtonBubbleVisualState: Equatable {
        case ghost
        case active
        case reconnecting
        case error
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Binding var content: NSAttributedString
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    var placeholderText: String = "Message"
    var fontScaleChangeSequence: Int = 0
    var resetToken: Int
    let canSend: Bool
    let isSending: Bool
    let isStagingAttachments: Bool
    let connectionStateStore: SendButtonConnectionStateStore
    let focusTrigger: Int
    let dismissTrigger: Int
    let isTextFieldFocused: Bool
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    /// Keyboard visibility state owned by parent view to survive geometry changes.
    let isKeyboardVisible: Bool
    @Binding var isAttachmentMenuPresented: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onReconnect: () -> Void
    let onAdd: () -> Void
    let attachmentMenuContent: () -> AnyView
    let onFocusChange: (Bool) -> Void
    let onRequestFocus: () -> Void
    var onRequestDirectFocus: (() -> Void)?
    var onTextEditActivity: (() -> Void)?
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

    private var inputCornerRadius: CGFloat {
        isSingleLine ? inputHeight / 2 : 22
    }

    private var trailingTextPadding: CGFloat { 20 }

    private var connectionAlertHint: String? {
        switch connectionState {
        case .reconnecting:
            return "Waiting for connection to return."
        case .disconnected:
            return "Connection lost. Try again soon."
        case .connected:
            return nil
        }
    }

    private var isReconnecting: Bool {
        connectionState == .reconnecting
    }

    private var isDisconnected: Bool {
        connectionState == .disconnected
    }

    private var hasSubmittableDraft: Bool {
        !content.isEffectivelyEmpty
    }

    private var sendButtonWidth: CGFloat {
        metrics.inputBarHeight
    }

    private var canSendNow: Bool {
        !isSending && canSend && connectionState == .connected
    }

    static func shouldDispatchEditorSubmitIntent(
        isSending: Bool,
        hasSubmittableDraft: Bool
    ) -> Bool {
        !isSending && hasSubmittableDraft
    }

    static func shouldRequestFocusOnEditorTap(isKeyboardVisible: Bool) -> Bool {
        !isKeyboardVisible
    }

    static func reconnectBubbleScale(phase: CGFloat) -> CGFloat {
        let clampedPhase = min(1, max(0, phase))
        return 0.75 + (0.25 * clampedPhase)
    }

    static func sendButtonBubbleVisualState(
        isSending: Bool,
        canSend: Bool,
        isStagingAttachments: Bool,
        connectionState: SendButtonConnectionState
    ) -> SendButtonBubbleVisualState {
        switch connectionState {
        case .connected:
            return (isSending || canSend || sendButtonShowsPreparingSpinner(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )) ? .active : .ghost
        case .reconnecting:
            return .reconnecting
        case .disconnected:
            return .error
        }
    }

    static func sendButtonShowsPreparingSpinner(
        isSending: Bool,
        canSend: Bool,
        isStagingAttachments: Bool,
        connectionState: SendButtonConnectionState
    ) -> Bool {
        connectionState == .connected && isStagingAttachments && !isSending && !canSend
    }

    static func sendButtonShowsPrimaryIcon(
        isSending: Bool,
        canSend: Bool,
        isStagingAttachments: Bool,
        connectionState: SendButtonConnectionState
    ) -> Bool {
        !isSending && !sendButtonShowsPreparingSpinner(
            isSending: isSending,
            canSend: canSend,
            isStagingAttachments: isStagingAttachments,
            connectionState: connectionState
        )
    }

    static func sendButtonPrimarySymbolName(connectionState: SendButtonConnectionState) -> String {
        connectionState == .disconnected ? "arrow.clockwise" : "paperplane.fill"
    }

    static func sendButtonBubbleScale(
        state: SendButtonBubbleVisualState,
        reconnectPhase: Double = 0
    ) -> Double {
        switch state {
        case .ghost:
            return 0
        case .active, .error:
            return 1
        case .reconnecting:
            return Double(reconnectBubbleScale(phase: CGFloat(reconnectPhase)))
        }
    }

    private var containerPadding: CGFloat {
        ChatFlowTheme.Metrics(isCompact: isCompact).inputBarPaddingHorizontal
    }

    static func chromeWidth(
        isCompact: Bool,
        bottomSafeAreaInset: CGFloat,
        isFieldFocused: Bool
    ) -> CGFloat {
        let themeMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let metrics = MessageInputBarMetrics(
            horizontalSizeClass: isCompact ? .compact : .regular,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: 0,
            isFieldFocused: isFieldFocused
        )
        return (themeMetrics.inputBarPaddingHorizontal * 2)
            + metrics.inputBarHeight
            + metrics.inputBarHeight
            + (MessageInputBarMetrics.elementSpacing * 2)
    }

    static func maxBarWidth(
        isCompact: Bool,
        bottomSafeAreaInset: CGFloat,
        isFieldFocused: Bool
    ) -> CGFloat? {
        guard !isCompact else { return nil }
        let bodyFont = UIFont.clawline(.bodyText)
        let textWidth = ChatFlowTheme.maxLineWidth(bodyFont: bodyFont)
        return textWidth + chromeWidth(
            isCompact: isCompact,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isFieldFocused: isFieldFocused
        )
    }

    static func renderedInputFieldWidthCap(
        containerWidth: CGFloat,
        isCompact: Bool,
        bottomSafeAreaInset: CGFloat,
        isFieldFocused: Bool
    ) -> CGFloat {
        let resolvedBarWidth = min(
            containerWidth,
            maxBarWidth(
                isCompact: isCompact,
                bottomSafeAreaInset: bottomSafeAreaInset,
                isFieldFocused: isFieldFocused
            ) ?? containerWidth
        )
        return max(
            0,
            resolvedBarWidth - chromeWidth(
                isCompact: isCompact,
                bottomSafeAreaInset: bottomSafeAreaInset,
                isFieldFocused: isFieldFocused
            )
        )
    }

    private func refreshMaxBarWidth() {
        cachedMaxBarWidth = Self.maxBarWidth(
            isCompact: isCompact,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isFieldFocused: isKeyboardVisible
        )
    }

    // #61: On visionOS, keep the input bar in dark mode regardless of the global theme toggle.
    // The rest of the UI still respects `settings.appearanceMode`.
    private var isLightModeForInputBar: Bool {
#if os(visionOS)
        return false
#else
        return colorScheme == .light
#endif
    }

    private var connectionState: SendButtonConnectionState {
        connectionStateStore.value
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

    private var inputBorderColor: Color {
#if os(visionOS)
        return visionOSBorderColor
#else
        return ChatFlowTheme.ink(colorScheme).opacity(0.16)
#endif
    }

    private var placeholderColor: Color {
#if os(visionOS)
        return isLightModeForInputBar
            ? ChatFlowTheme.ink(.light).opacity(0.6)
            : ChatFlowTheme.ink(.dark).opacity(0.6)
#else
        return .secondary
#endif
    }

    private var inputTintColor: Color {
#if os(visionOS)
        return isLightModeForInputBar ? ChatFlowTheme.ink(.light) : ChatFlowTheme.ink(.dark)
#else
        return .primary
#endif
    }

    private var editorTintUIColor: UIColor {
#if os(visionOS)
        return UIColor(inputTintColor)
#else
        return UIColor(ChatFlowTheme.sage(colorScheme))
#endif
    }

    static func disabledSendButtonBackingColor(
        colorScheme: ColorScheme,
        drawsDisabledBacking: Bool = true
    ) -> Color? {
        guard drawsDisabledBacking else { return nil }
        return colorScheme == .light
            ? Color(red: 0.925, green: 0.922, blue: 0.890)
            : nil
    }

    static let sendButtonColoredBackingBlurRadius: CGFloat = 7

    private func handleEditorSubmitIntent() {
        guard Self.shouldDispatchEditorSubmitIntent(
            isSending: isSending,
            hasSubmittableDraft: hasSubmittableDraft
        ) else { return }
        onSend()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
        }
        .padding(.horizontal, containerPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(maxWidth: cachedMaxBarWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            logger.info("Input bar tap gesture")
        })
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

    private var inputRow: some View {
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
            .popover(
                isPresented: $isAttachmentMenuPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                attachmentMenuContent()
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(.clear)
            }

            // Text field - glass capsule/rounded rect
            ZStack(alignment: .leading) {
                RichTextEditor(
                    attributedText: $content,
                    calculatedHeight: $editorHeight,
                    selectionRange: $selectionRange,
                    pendingInsertions: $pendingInsertions,
                    fontScaleChangeSequence: fontScaleChangeSequence,
                    resetToken: resetToken,
                    focusTrigger: focusTrigger,
                    dismissTrigger: dismissTrigger,
                    isEditable: true,
                    isKeyboardVisible: isKeyboardVisible,
                    isExternalEditingActive: false,
                    tintColor: editorTintUIColor,
                    textColor: {
#if os(visionOS)
                        // #61: Input bar is forced dark on visionOS; ensure typed text is visible.
                        return .white
#else
                        return .label
#endif
                    }(),
                    onFocusChange: onFocusChange,
                    onTextEditActivity: onTextEditActivity,
                    onSubmit: handleEditorSubmitIntent,
                    onPasteImages: onPasteImages,
                    trailingPadding: trailingTextPadding
                )
                .opacity(isSending ? 0.5 : 1)

                if content.length == 0 {
                    Text(placeholderText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(placeholderColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, 20)
                        .padding(.trailing, trailingTextPadding)
                }
            }
            .tint(inputTintColor)
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
#if os(visionOS)
            .background(.regularMaterial, in: inputShape)
#else
            .glassEffect(.regular, in: inputShape)
#endif
            .overlay {
                inputShape
                    .stroke(inputBorderColor, lineWidth: 1)
            }

            MessageSendControl(
                isSending: isSending,
                isStagingAttachments: isStagingAttachments,
                canSend: canSendNow,
                connectionState: connectionState,
                sendButtonSize: sendButtonWidth,
                inputBarColorScheme: inputBarColorScheme,
                uiColorScheme: colorScheme,
                visionOSBorderColor: visionOSBorderColor,
                connectionAlertHint: connectionAlertHint,
                onSend: onSend,
                onCancel: onCancel,
                onReconnect: onReconnect
            )
        }
    }

    struct MessageSendControl: View {
        let isSending: Bool
        let isStagingAttachments: Bool
        let canSend: Bool
        let connectionState: SendButtonConnectionState
        let sendButtonSize: CGFloat
        let inputBarColorScheme: ColorScheme
        let uiColorScheme: ColorScheme
        let visionOSBorderColor: Color
        let connectionAlertHint: String?
        let onSend: () -> Void
        let onCancel: () -> Void
        let onReconnect: () -> Void

        private var isReconnecting: Bool { connectionState == .reconnecting }
        private var isDisconnected: Bool { connectionState == .disconnected }
        private var sendActionEnabled: Bool { isSending || canSend || isDisconnected }
        private var sendIconColor: Color { .white }
        private let reconnectPulseDuration: TimeInterval = 0.8
        private var drawsDisabledSendButtonBacking: Bool {
#if os(visionOS)
            false
#else
            true
#endif
        }
        private var isPreparingSpinnerVisible: Bool {
            MessageInputBar.sendButtonShowsPreparingSpinner(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )
        }
        private var showsPrimaryIcon: Bool {
            MessageInputBar.sendButtonShowsPrimaryIcon(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )
        }

        private var bubbleVisualState: MessageInputBar.SendButtonBubbleVisualState {
            MessageInputBar.sendButtonBubbleVisualState(
                isSending: isSending,
                canSend: canSend,
                isStagingAttachments: isStagingAttachments,
                connectionState: connectionState
            )
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

        private func reconnectPulsePhase(at date: Date) -> Double {
            let phase = date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: reconnectPulseDuration) / reconnectPulseDuration
            return 0.5 - 0.5 * cos(phase * 2 * .pi)
        }

        private func bubbleScale(at date: Date) -> Double {
            MessageInputBar.sendButtonBubbleScale(
                state: bubbleVisualState,
                reconnectPhase: reconnectPulsePhase(at: date)
            )
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
                ZStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(sendIconColor)
                        .scaleEffect(0.9)
                        .opacity(isPreparingSpinnerVisible ? 1 : 0)
                        .scaleEffect(isPreparingSpinnerVisible ? 1 : 0.7)

                    Image(systemName: "stop.fill")
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(sendIconColor)
                        .opacity(isSending && !isReconnecting && !isPreparingSpinnerVisible ? 1 : 0)
                        .scaleEffect(isSending && !isReconnecting && !isPreparingSpinnerVisible ? 1 : 0.7)

                    Image(systemName: MessageInputBar.sendButtonPrimarySymbolName(connectionState: connectionState))
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(sendIconColor)
                        .opacity(showsPrimaryIcon ? 1 : 0)
                        .scaleEffect(showsPrimaryIcon ? 1 : 0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .frame(width: sendButtonSize, height: sendButtonSize)
            .background {
                if bubbleVisualState == .ghost,
                   let backingColor = MessageInputBar.disabledSendButtonBackingColor(
                    colorScheme: uiColorScheme,
                    drawsDisabledBacking: drawsDisabledSendButtonBacking
                   ) {
                    Circle()
                        .fill(backingColor)
                        .frame(width: sendButtonSize, height: sendButtonSize)
                        .blur(radius: MessageInputBar.sendButtonColoredBackingBlurRadius)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isReconnecting)) { context in
                    Circle()
                        .fill(bubbleColor)
                        .frame(width: sendButtonSize, height: sendButtonSize)
                        .scaleEffect(bubbleScale(at: context.date))
                        .blur(radius: MessageInputBar.sendButtonColoredBackingBlurRadius)
                }
            }
#if os(visionOS)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(visionOSBorderColor, lineWidth: 1))
#else
            .glassEffect(.regular.interactive(), in: Circle())
#endif
            .buttonStyle(.plain)
#if os(visionOS)
            .tint(sendIconColor)
            .foregroundStyle(sendIconColor)
#endif
            .allowsHitTesting(sendActionEnabled && !isReconnecting)
            .accessibilityLabel(
                isReconnecting ? "Reconnecting" :
                    (isPreparingSpinnerVisible ? "Staging attachments" :
                        (isDisconnected ? "Disconnected. Tap to reconnect." : "Send message"))
            )
            .accessibilityHint(connectionAlertHint ?? "")
            .accessibilityIdentifier("send_button")
            .id("send-button")
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: isSending)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: canSend)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: connectionState)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: bubbleVisualState)
        }
    }

    private func requestComposeFocus() {
        if let onRequestDirectFocus {
            onRequestDirectFocus()
        } else {
            onFocusChange(true)
            onRequestFocus()
        }
    }

}

#Preview("Message Input") {
    @Previewable @State var content = NSAttributedString(string: "Hello")
    @Previewable @State var selection = NSRange(location: 5, length: 0)
    @Previewable @State var connectionStateStore = SendButtonConnectionStateStore(value: .connected)
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                content: $content,
                selectionRange: $selection,
                pendingInsertions: .constant([]),
                placeholderText: "Message",
                resetToken: 0,
                canSend: true,
                isSending: false,
                isStagingAttachments: false,
                connectionStateStore: connectionStateStore,
                focusTrigger: 0,
                dismissTrigger: 0,
                isTextFieldFocused: false,
                bottomSafeAreaInset: 34,
                isKeyboardVisible: false,
                isAttachmentMenuPresented: .constant(false),
                onSend: {},
                onCancel: {},
                onReconnect: {},
                onAdd: {},
                attachmentMenuContent: { AnyView(EmptyView()) },
                onFocusChange: { _ in },
                onRequestFocus: {},
                onPasteImages: nil,
                isCompact: true
            )
        }
}
