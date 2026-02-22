//
//  MessageInputBar.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import OSLog

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessageInputBar")

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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var content: NSAttributedString
    @Binding var selectionRange: NSRange
    @Binding var pendingInsertions: [PendingAttachment]
    let dictation: DictationCoordinator
    var placeholderText: String = "Message"
    var resetToken: Int
    let canSend: Bool
    let isSending: Bool
    let connectionState: SendButtonConnectionState
    let focusTrigger: Int
    let isTextFieldFocused: Bool
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    /// Keyboard visibility state owned by parent view to survive geometry changes.
    let isKeyboardVisible: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onReconnect: () -> Void
    let onAdd: () -> Void
    let onFocusChange: (Bool) -> Void
    let onDictationSurfaceDragActiveChange: (Bool) -> Void
    var onPasteImages: (([UIImage]) -> Void)?

    @State private var editorHeight: CGFloat = 44
    @State private var pushGestureStart: Date?
    @State private var pushCommitReachedAt: Date?
    @State private var pushStartedWalkieTalkie = false
    @State private var pushGestureStartedWithSurfaceOpen = false
    @State private var waveformDidStartWalkie = false
    @State private var surfaceInteractiveProgress: CGFloat = 0
    @State private var pullToSendProgress: CGFloat = 0
    @State private var pullToSendArmed = false
    @State private var micTransientVisible = false
    @State private var micTransientOpacity: Double = 0
    @State private var micTransientOffset: CGFloat = 0
    @State private var micFadeTask: Task<Void, Never>?
    @State private var reconnectPulseOn: Bool = false
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

    private var reduceMotionForDictation: Bool {
        accessibilityReduceMotion || dictation.reduceMotionEnabled
    }

    private var shouldRenderMic: Bool {
        !dictation.isSurfaceOpen
            && !isTextFieldFocused
            && content.length == 0
            && (dictation.micVisible || micTransientVisible)
    }

    private var micTrailingPadding: CGFloat {
        shouldRenderMic ? 52 : 20
    }

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

    private var sendButtonWidth: CGFloat {
        metrics.inputBarHeight
    }

    private var pullToSendStartThreshold: CGFloat { 40 }
    private var pullToSendTriggerThreshold: CGFloat { 62 }
    private var pullToSendEligible: Bool {
        !isSending && canSend && connectionState == .connected
    }

    private var pullToSendLift: CGFloat {
        (16 + 56 * pullToSendProgress) * (pullToSendProgress > 0 ? 1 : 0)
    }

    private var containerPadding: CGFloat {
        ChatFlowTheme.Metrics(isCompact: isCompact).inputBarPaddingHorizontal
    }

    private var maxBarWidth: CGFloat? {
        guard !isCompact else { return nil }
        let themeMetrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let textWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: themeMetrics.bodyFontSize)
        let chromeWidth = (themeMetrics.inputBarPaddingHorizontal * 2)
            + sendButtonWidth
            + metrics.inputBarHeight
            + (MessageInputBarMetrics.elementSpacing * 2)
        return textWidth + chromeWidth
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

    private var inputBorderColor: Color {
#if os(visionOS)
        return visionOSBorderColor
#else
        return ChatFlowTheme.ink(colorScheme).opacity(0.16)
#endif
    }

    private var sendIconColor: Color { .white }

    private var sendBackgroundColor: Color {
        let scheme = inputBarColorScheme
        switch connectionState {
        case .connected:
#if os(visionOS)
            return ChatFlowTheme.sage(scheme)
#else
            return ChatFlowTheme.sage(colorScheme)
#endif
        case .reconnecting:
            return ChatFlowTheme.connectionReconnecting(scheme)
        case .disconnected:
            return ChatFlowTheme.connectionDisconnected(scheme)
        }
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

    private var inputTintUIColor: UIColor {
        UIColor(inputTintColor)
    }

#if DEBUG
    private var dictationDebugVersionText: String? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty else { return nil }
        if let version, !version.isEmpty {
            return "DBG v\(version) b\(build)"
        }
        return "DBG b\(build)"
    }
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: MessageInputBarMetrics.elementSpacing) {
#if os(visionOS)
                // Appearance toggle button
                Button(action: {
                    settings.toggleAppearanceMode()
                }) {
                    Image(systemName: appearanceIconName)
                        .font(.system(size: 18, weight: .semibold))
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
                        .font(.system(size: 18, weight: .semibold))
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

                // Text field - glass capsule/rounded rect
                ZStack(alignment: .leading) {
                    RichTextEditor(
                        attributedText: $content,
                        calculatedHeight: $editorHeight,
                        selectionRange: $selectionRange,
                        pendingInsertions: $pendingInsertions,
                        resetToken: resetToken,
                        focusTrigger: focusTrigger,
                        isEditable: true,
                        tintColor: inputTintUIColor,
                        textColor: {
#if os(visionOS)
                            // #61: Input bar is forced dark on visionOS; ensure typed text is visible.
                            return .white
#else
                            return .label
#endif
                        }(),
                        onFocusChange: onFocusChange,
                        onSubmit: {
                            guard !isSending, canSend else { return }
                            onSend()
                        },
                        onEscape: {
                            dictation.stopFromEscapeKey()
                        },
                        onEscapeLongPress: {
                            dictation.discardFromEscapeLongPress()
                        },
                        onPasteImages: onPasteImages,
                        onTextViewReady: { textView in
                            dictation.setComposeTextView(textView)
                        },
                        trailingPadding: micTrailingPadding
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
                            .padding(.trailing, micTrailingPadding)
                    }

                    if shouldRenderMic {
                        micButton
                            .padding(.trailing, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .opacity(dictation.micVisible ? 1 : micTransientOpacity)
                            .offset(x: dictation.micVisible ? 0 : micTransientOffset)
                            .allowsHitTesting(dictation.micVisible)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .animation(.easeOut(duration: isTextFieldFocused ? 0.7 : 0.35), value: dictation.micVisible)
                    }
                }
                .tint(inputTintColor)
                .frame(height: inputHeight)
                .frame(maxWidth: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .simultaneousGesture(pushToRevealGesture)
#if os(visionOS)
                .background(.regularMaterial, in: inputShape)
#else
                .glassEffect(.regular, in: inputShape)
#endif
                .overlay {
                    inputShape
                        .stroke(inputBorderColor, lineWidth: 1)
                }
                .accessibilityAction(named: Text("Start Sticky Dictation")) {
                    guard dictation.micVisible || dictation.swipeActivationEnabled else { return }
                    dictation.startStickyDictation()
                }
                .accessibilityAction(named: Text("Start Walkie-Talkie Dictation")) {
                    guard dictation.micVisible || dictation.swipeActivationEnabled else { return }
                    dictation.startWalkieTalkieDictation()
                    beginMicFadeOut(fromSwipe: !dictation.micVisible)
                }
                .accessibilityAction(named: Text("Stop Dictation")) {
                    dictation.stopFromVoiceOverAction()
                }
                .accessibilityAction(named: Text("Cancel and Discard Dictation")) {
                    dictation.discardFromVoiceOverAction()
                }

                // Send button - morphs with connection state, keeps frame/anchor stable.
                let sendActionEnabled = isSending || canSend || isDisconnected
                let sendIconOpacity = (sendActionEnabled || isReconnecting) ? 1 : 0.4
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
                        if isReconnecting {
                            Circle()
                                .fill(sendBackgroundColor)
                                .frame(
                                    width: min(12, sendButtonWidth * 0.4),
                                    height: min(12, sendButtonWidth * 0.4)
                                )
                                .opacity(reconnectPulseOn ? 1 : 0.4)
                                .scaleEffect(reconnectPulseOn ? 1.2 : 1.0)
                        } else {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(sendIconColor)
                                .opacity(isSending ? 1 : 0)
                            Image(systemName: isDisconnected ? "arrow.clockwise" : "paperplane.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(sendIconColor)
                                .opacity(isSending ? 0 : 1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .frame(width: sendButtonWidth, height: metrics.inputBarHeight)
#if os(visionOS)
                .background(
                    Circle().fill(
                        isReconnecting
                            ? .clear
                            : sendBackgroundColor.opacity(sendActionEnabled ? 1 : 0.35)
                    )
                )
                .overlay(Circle().stroke(visionOSBorderColor, lineWidth: 1))
#else
                .background(
                    Capsule().fill(
                        isReconnecting
                            ? .clear
                            : sendBackgroundColor.opacity(sendActionEnabled ? 1 : 0.35)
                    )
                )
#endif
                .buttonStyle(.plain)
#if os(visionOS)
                .tint(sendIconColor)
                .foregroundStyle(sendIconColor)
#endif
                .allowsHitTesting(sendActionEnabled && !isReconnecting)
                .opacity(sendIconOpacity)
                .accessibilityLabel(
                    isReconnecting ? "Reconnecting" :
                        (isDisconnected ? "Disconnected. Tap to reconnect." : "Send message")
                )
                .accessibilityHint(connectionAlertHint ?? "")
                .id("send-button")
                .transaction { $0.animation = nil }
                .animation(nil, value: isSending)
                .animation(nil, value: canSend)
                .animation(nil, value: connectionState)
            }

            if dictation.isSurfaceOpen || surfaceInteractiveProgress > 0.001 {
                dictationSurface
                    .opacity(surfaceInteractiveProgress)
                    .frame(height: max(0, 100 * surfaceInteractiveProgress), alignment: .top)
                    .clipped()
            }

        }
        .padding(.horizontal, containerPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(maxWidth: maxBarWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(y: -pullToSendLift)
        .overlay(alignment: .bottom) {
            if pullToSendProgress > 0.001 {
                pullToSendIndicator
                    .frame(height: 40)
                    .scaleEffect(0.85 + 0.15 * pullToSendProgress, anchor: .center)
                    .opacity(min(1, 0.2 + 1.2 * pullToSendProgress))
                    .offset(y: MessageInputBarMetrics.elementSpacing)
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            logger.info("Input bar tap gesture")
        })
#if DEBUG
        .overlay(alignment: .topTrailing) {
            if dictation.isDictationActive,
               let dictationDebugVersionText {
                Text(dictationDebugVersionText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.trailing, containerPadding)
                    .offset(y: -18)
                    .accessibilityIdentifier("dictation-debug-version")
            }
        }
#endif
        .onChange(of: content.length) { _, newValue in
            guard newValue == 0 else { return }
            editorHeight = metrics.inputBarHeight
        }
        .onDisappear {
            micFadeTask?.cancel()
            reconnectPulseOn = false
            onDictationSurfaceDragActiveChange(false)
            resetPullToSendVisualState()
        }
        .onAppear {
            surfaceInteractiveProgress = dictation.isSurfaceOpen ? 1 : 0
            reconnectPulseOn = false
            guard isReconnecting else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                reconnectPulseOn = true
            }
        }
        .onChange(of: dictation.isSurfaceOpen) { _, isOpen in
            if isOpen {
                micFadeTask?.cancel()
                micTransientVisible = false
                micTransientOpacity = 0
                micTransientOffset = 0
            }
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                surfaceInteractiveProgress = isOpen ? 1 : 0
            }
        }
        .onChange(of: connectionState) { _, newValue in
            if newValue == .reconnecting {
                reconnectPulseOn = false
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    reconnectPulseOn = true
                }
            } else {
                reconnectPulseOn = false
            }
        }
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(inputTintColor.opacity(0.9))
            .frame(width: metrics.inputBarHeight, height: metrics.inputBarHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isSending else { return }
                if dictation.isStickyDictationActive {
                    dictation.dismissSurfaceFromUserGesture()
                } else {
                    dictation.beginGesturePrewarm()
                    dictation.startStickyDictation()
                    beginMicFadeOut(fromSwipe: false)
                }
            }
            .accessibilityLabel(dictation.isStickyDictationActive ? "Stop dictation" : "Start dictation")
    }

    private var pushToRevealGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handlePushChanged(value)
            }
            .onEnded { value in
                handlePushEnded(value)
            }
    }

    private func handlePushChanged(_ value: DragGesture.Value) {
        logDictation("DICTATION_UI handlePushChanged")
        let dx = value.translation.width
        let dy = value.translation.height
        let up = max(0, -dy)
        let down = max(0, dy)
        let verticalDominant = max(up, down) >= 1.4 * abs(dx)

        if pushGestureStart == nil {
            pushGestureStart = Date()
            pushCommitReachedAt = nil
            pushStartedWalkieTalkie = false
            pushGestureStartedWithSurfaceOpen = dictation.isSurfaceOpen
            onDictationSurfaceDragActiveChange(true)
            dictation.beginGesturePrewarm()
        }

        if dictation.isSurfaceOpen {
            if verticalDominant {
                if up > 0 {
                    surfaceInteractiveProgress = 1
                    updatePullToSendArming(upDistance: up)
                } else {
                    surfaceInteractiveProgress = max(0, min(1, 1 - (down / 120)))
                    resetPullToSendVisualState()
                }
            }
            return
        }

        guard dictation.swipeActivationEnabled else {
            dictation.cancelGesturePrewarmIfNeeded(trigger: "push_changed_activation_disabled")
            return
        }
        guard up >= 1.4 * abs(dx) else {
            if abs(dx) > up {
                dictation.cancelGesturePrewarmIfNeeded(trigger: "push_changed_horizontal_dominant")
            }
            resetPullToSendVisualState()
            return
        }
        guard up >= 28 else { return }
        surfaceInteractiveProgress = max(0, min(1, up / 120))
        updatePullToSendArming(upDistance: up)

        if pushCommitReachedAt == nil {
            pushCommitReachedAt = Date()
            return
        }

        if let pushCommitReachedAt,
           !pushStartedWalkieTalkie,
           Date().timeIntervalSince(pushCommitReachedAt) >= 0.35 {
            pushStartedWalkieTalkie = true
            dictation.startWalkieTalkieDictation()
            beginMicFadeOut(fromSwipe: false)
        }
    }

    private func handlePushEnded(_ value: DragGesture.Value) {
        logDictation("DICTATION_UI handlePushEnded")
        let shouldSendFromPull = pullToSendArmed && pullToSendEligible
        defer {
            pushGestureStart = nil
            pushCommitReachedAt = nil
            pushStartedWalkieTalkie = false
            pushGestureStartedWithSurfaceOpen = false
            onDictationSurfaceDragActiveChange(false)
            resetPullToSendVisualState()
        }

        let dx = value.translation.width
        let dy = value.translation.height
        let up = max(0, -dy)
        let down = max(0, dy)
        let verticalDominant = max(up, down) >= 1.4 * abs(dx)
        let fastUp = value.predictedEndTranslation.height < -120
        let fastDown = value.predictedEndTranslation.height > 120
        let projectedUp = max(0, -value.predictedEndTranslation.height)
        let projectedDown = max(0, value.predictedEndTranslation.height)

        if shouldSendFromPull {
            let wasWalkie = dictation.isWalkieTalkieActive
            let wasSurfaceOpen = dictation.isSurfaceOpen
            onSend()
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                if wasWalkie {
                    surfaceInteractiveProgress = 0
                } else {
                    surfaceInteractiveProgress = wasSurfaceOpen ? 1 : 0
                }
            }
            return
        }

        if dictation.isSurfaceOpen {
            if dictation.isWalkieTalkieActive {
                if pushGestureStartedWithSurfaceOpen {
                    dictation.endWalkieTalkieIfNeeded()
                    withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                        surfaceInteractiveProgress = 1
                    }
                } else {
                    dictation.dismissSurfaceFromUserGesture()
                    withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                        surfaceInteractiveProgress = 0
                    }
                }
                return
            }
            if verticalDominant && (down >= 32 || fastDown || projectedDown >= 96 || surfaceInteractiveProgress < 0.45) {
                dictation.dismissSurfaceFromUserGesture()
            } else {
                withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                    surfaceInteractiveProgress = 1
                }
            }
            return
        }

        guard dictation.swipeActivationEnabled else {
            dictation.cancelGesturePrewarmIfNeeded(trigger: "push_end_activation_disabled")
            return
        }
        guard verticalDominant else {
            dictation.cancelGesturePrewarmIfNeeded(trigger: "push_end_not_vertical_dominant")
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                surfaceInteractiveProgress = 0
            }
            return
        }
        guard up >= 32 || fastUp || projectedUp >= 96 || surfaceInteractiveProgress >= 0.45 else {
            dictation.cancelGesturePrewarmIfNeeded(trigger: "push_end_threshold_not_met")
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                surfaceInteractiveProgress = 0
            }
            return
        }
        if pushStartedWalkieTalkie {
            dictation.endWalkieTalkieIfNeeded()
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
                surfaceInteractiveProgress = 1
            }
            return
        }

        dictation.startStickyDictation()
        beginMicFadeOut(fromSwipe: false)
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.12)) {
            surfaceInteractiveProgress = 1
        }
    }

    private func updatePullToSendArming(upDistance: CGFloat) {
        let progress = max(0, min(1, (upDistance - pullToSendStartThreshold) / (pullToSendTriggerThreshold - pullToSendStartThreshold)))
        pullToSendProgress = progress
        pullToSendArmed = progress >= 1 && pullToSendEligible
    }

    private func resetPullToSendVisualState() {
        pullToSendProgress = 0
        pullToSendArmed = false
    }

    private var dictationSurface: some View {
        VStack(alignment: .center, spacing: 8) {
            waveformLine
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    dictation.toggleWaveformTapAction()
                }
                .onLongPressGesture(
                    minimumDuration: 0.35,
                    maximumDistance: 24,
                    pressing: { isPressing in
                        guard !isPressing, waveformDidStartWalkie else { return }
                        waveformDidStartWalkie = false
                        dictation.endWalkieTalkieIfNeeded()
                    },
                    perform: {
                        guard dictation.state == .dictatingPaused else { return }
                        waveformDidStartWalkie = true
                        dictation.startWalkieTalkieFromPausedSurface()
                    }
                )

            Text(dictation.state == .dictatingPaused ? "Paused" : "Listening...")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if dictation.state == .error, let message = dictation.errorMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .onAppear {
                        logDictation("DICTATION_ERROR ui_display ts=\(Date().timeIntervalSince1970) message=\(message)")
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 100, alignment: .top)
#if os(visionOS)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#else
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
#endif
    }

    private var pullToSendIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: pullToSendArmed ? "paperplane.fill" : "arrow.up.circle")
                .font(.system(size: 14, weight: .semibold))
            Text(pullToSendArmed ? "Release to send" : "Pull up to send")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(pullToSendArmed ? ChatFlowTheme.adminAccent(colorScheme) : inputTintColor.opacity(0.9))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var waveformLine: some View {
        TimelineView(.periodic(from: .now, by: reduceMotionForDictation ? 0.12 : (1 / 60))) { context in
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let height = max(1, proxy.size.height)
                let midY = height * 0.5
                let t = CGFloat(context.date.timeIntervalSinceReferenceDate)
                let normalizedAudio = max(0, min(1, (dictation.waveformDisplacement - 0.35) / 8.65))
                let pauseMultiplier: CGFloat = dictation.state == .dictatingPaused ? 0.55 : 1.0
                let idleDrift = 0.070 + 0.022 * sin(t * 1.9)
                let audioSwell = dictation.state == .dictatingPaused ? 0 : (1.22 * normalizedAudio)
                let baseAmplitude = (idleDrift + audioSwell) * pauseMultiplier
                let baseLineWidth: CGFloat = dictation.state == .dictatingPaused ? 1.4 : 2.0
                let colorSet: [Color] = [
                    ChatFlowTheme.adminAccent(colorScheme),
                    ChatFlowTheme.sage(colorScheme),
                    ChatFlowTheme.softCoral(colorScheme),
                    ChatFlowTheme.terracotta(colorScheme)
                ]
                let waveConfigs: [(frequency: CGFloat, phaseOffset: CGFloat, speed: CGFloat, amplitudeScale: CGFloat)] = [
                    (1.30, 0.0, 2.0, 1.00),
                    (1.85, 1.1, 2.7, 0.95),
                    (2.45, 2.0, 3.4, 0.86),
                    (3.10, 2.8, 4.0, 0.74)
                ]

                ZStack {
                    ForEach(Array(waveConfigs.enumerated()), id: \.offset) { index, config in
                        let phase = (t * config.speed) + config.phaseOffset
                        let waveAmplitude = min(1.28, max(0.060, baseAmplitude * config.amplitudeScale))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: midY))
                            let step: CGFloat = 2
                            var x: CGFloat = 0
                            while x <= width {
                                let progress = x / width
                                let taper = pow(sin(progress * .pi), 0.95)
                                let y = midY + sin((progress * .pi * 2 * config.frequency) + phase) * height * waveAmplitude * taper
                                path.addLine(to: CGPoint(x: x, y: y))
                                x += step
                            }
                        }
                        .stroke(
                            colorSet[index].opacity(dictation.state == .dictatingPaused ? 0.34 : (0.62 - CGFloat(index) * 0.10)),
                            style: StrokeStyle(
                                lineWidth: baseLineWidth + CGFloat(3 - index) * 0.26,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    }
                }
            }
        }
    }

    private func beginMicFadeOut(fromSwipe: Bool) {
        let animationPlan = DictationMicAffordanceAnimationPlan.make(fromSwipe: fromSwipe)

        micFadeTask?.cancel()
        micTransientVisible = true
        micTransientOpacity = 1
        micTransientOffset = animationPlan.initialOffset

        if let slideDurationMs = animationPlan.slideDurationMs {
            Task { @MainActor in
                // Ensure first frame renders at the right-edge offset before sliding inward.
                await Task.yield()
                withAnimation(.easeOut(duration: Double(slideDurationMs) / 1_000)) {
                    micTransientOffset = 0
                }
            }
        } else {
            micTransientOffset = 0
        }

        micFadeTask = Task { @MainActor in
            if animationPlan.fadeDelayMs > 0 {
                try? await Task.sleep(for: .milliseconds(animationPlan.fadeDelayMs))
            }

            withAnimation(.easeOut(duration: Double(animationPlan.fadeDurationMs) / 1_000)) {
                micTransientOpacity = 0
            }

            let cleanupDelayMs = animationPlan.fadeDurationMs + animationPlan.cleanupTailMs
            try? await Task.sleep(for: .milliseconds(cleanupDelayMs))
            micTransientVisible = false
            micTransientOpacity = 0
            micTransientOffset = 0
        }
    }

    private func logDictation(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print(message)
    }
}

struct DictationMicAffordanceAnimationPlan {
    let initialOffset: CGFloat
    let slideDurationMs: Int?
    let fadeDelayMs: Int
    let fadeDurationMs: Int
    let cleanupTailMs: Int

    static func make(fromSwipe: Bool) -> Self {
        if fromSwipe {
            // Spec: swipe-left retrieval should visibly re-enter from the right over 350ms.
            return Self(
                initialOffset: 28,
                slideDurationMs: 350,
                fadeDelayMs: 350,
                fadeDurationMs: 850,
                cleanupTailMs: 80
            )
        }

        return Self(
            initialOffset: 0,
            slideDurationMs: nil,
            fadeDelayMs: 0,
            fadeDurationMs: 1_200,
            cleanupTailMs: 80
        )
    }
}

#Preview("Message Input") {
    @Previewable @State var content = NSAttributedString(string: "Hello")
    @Previewable @State var selection = NSRange(location: 5, length: 0)
    let draftHost = PreviewDictationDraftHost()
    let dictation = DictationCoordinator(
        bridge: ComposeInputDictationBridge(host: draftHost),
        configuredAPIKey: { nil }
    )
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                content: $content,
                selectionRange: $selection,
                pendingInsertions: .constant([]),
                dictation: dictation,
                resetToken: 0,
                canSend: true,
                isSending: false,
                connectionState: .connected,
                focusTrigger: 0,
                isTextFieldFocused: false,
                bottomSafeAreaInset: 34,
                isKeyboardVisible: false,
                onSend: {},
                onCancel: {},
                onReconnect: {},
                onAdd: {},
                onFocusChange: { _ in },
                onDictationSurfaceDragActiveChange: { _ in },
                onPasteImages: nil,
                isCompact: true
            )
        }
}

@MainActor
private final class PreviewDictationDraftHost: DictationComposeDraftHosting {
    var activeSessionKey: String = "preview"

    func captureComposeDraftSnapshot(for sessionKey: String) -> ComposeDraftSnapshot {
        .empty
    }

    func applyComposeDraftDelta(
        baseSnapshot: ComposeDraftSnapshot,
        previousTranscriptUTF16Length: Int,
        replacementText: NSAttributedString,
        to sessionKey: String,
        moveCursorToEnd: Bool
    ) {}

    func applyComposeDraftSnapshot(_ snapshot: ComposeDraftSnapshot,
                                   to sessionKey: String,
                                   moveCursorToEnd: Bool,
                                   announceEditorReset: Bool) {}
}
