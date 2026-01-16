//
//  MessageInputBar.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit
import os.log

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
    @Binding var content: NSAttributedString
    @Binding var selectionRange: NSRange
    let canSend: Bool
    let isSending: Bool
    let connectionAlert: ConnectionAlertSeverity?
    let focusTrigger: Int
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    /// Keyboard visibility state owned by parent view to survive geometry changes.
    let isKeyboardVisible: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onAdd: () -> Void
    let onFocusChange: (Bool) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var editorHeight: CGFloat = 44

    private var metrics: MessageInputBarMetrics {
        MessageInputBarMetrics(
            horizontalSizeClass: horizontalSizeClass,
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
        max(editorHeight, metrics.inputBarHeight)
    }

    private var connectionAlertColor: Color? {
        switch connectionAlert {
        case .caution:
            return Color.yellow
        case .critical:
            return Color.red
        case nil:
            return nil
        }
    }

    private var connectionAlertMessage: String? {
        switch connectionAlert {
        case .caution:
            return "Reconnecting…"
        case .critical:
            return "Disconnected"
        case nil:
            return nil
        }
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

    private var connectionAlertHint: String? {
        switch connectionAlert {
        case .caution:
            return "Waiting for connection to return."
        case .critical:
            return "Connection lost. Try again soon."
        case nil:
            return nil
        }
    }

    private var sendButtonShape: AnyShape {
        isSending ? AnyShape(Capsule()) : AnyShape(Circle())
    }

    private var sendButtonBackground: Color {
        if isSending {
            return Color(.systemGray5)
        }
        if !canSend {
            return Color(.systemGray4)
        }
        return Color.accentColor
    }

    private var sendButtonForeground: Color {
        if isSending {
            return Color.primary
        }
        return Color.white
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: MessageInputBarMetrics.elementSpacing) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
            }
            .accessibilityLabel("Add attachment")
            .frame(width: metrics.addButtonSize, height: metrics.addButtonSize)
            .glassEffect(.regular.interactive(), in: Circle())
            .disabled(isSending)

            ZStack(alignment: .leading) {
                RichTextEditor(
                    attributedText: $content,
                    calculatedHeight: $editorHeight,
                    selectionRange: $selectionRange,
                    focusTrigger: focusTrigger,
                    isEditable: !isSending,
                    onFocusChange: onFocusChange,
                    trailingPadding: metrics.editorTrailingInset(isSending: isSending)
                )
                .opacity(isSending ? 0.5 : 1)

                if content.length == 0 {
                    Text("Message")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.leading, 20)
                }

                if let alertMessage = connectionAlertMessage,
                   let alertColor = connectionAlertColor {
                    RoundedRectangle(cornerRadius: isSingleLine ? inputHeight / 2 : 22, style: .continuous)
                        .fill(alertColor.opacity(0.08))
                        .allowsHitTesting(false)

                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 14, weight: .semibold))
                        Text(alertMessage)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .foregroundColor(alertColor)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: inputHeight)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .glassEffect(.regular, in: inputShape)
            .overlay {
                if let alertColor = connectionAlertColor {
                    inputShape
                        .stroke(alertColor.opacity(0.4), lineWidth: 1)
                }
            }
        }
        .padding(.horizontal, metrics.concentricPadding)
        .padding(.bottom, metrics.bottomPadding)
        .overlay(alignment: .bottomTrailing) {
            Button(action: isSending ? onCancel : onSend) {
                if isSending {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: isSending ? 92 : metrics.sendButtonSize, height: metrics.sendButtonSize)
            .background(sendButtonShape.fill(sendButtonBackground))
            .foregroundStyle(sendButtonForeground)
            .disabled(!isSending && !canSend)
            .opacity(connectionAlertColor == nil ? 1 : 0.65)
            .padding(.trailing, 10)
            .padding(.bottom, 8)
            .accessibilityHint(connectionAlertHint ?? "")
        }
    }
}

#Preview("Message Input") {
    @Previewable @State var content = NSAttributedString(string: "Hello")
    @Previewable @State var selection = NSRange(location: 5, length: 0)
    return Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                content: $content,
                selectionRange: $selection,
                canSend: true,
                isSending: false,
                connectionAlert: nil,
                focusTrigger: 0,
                bottomSafeAreaInset: 34,
                isKeyboardVisible: false,
                onSend: {},
                onCancel: {},
                onAdd: {},
                onFocusChange: { _ in }
            )
        }
}
