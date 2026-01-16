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

    @State private var editorHeight: CGFloat = 48

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

    var body: some View {
        HStack(spacing: MessageInputBarMetrics.elementSpacing) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
            }
            .accessibilityLabel("Add attachment")
            .frame(width: metrics.addButtonSize, height: metrics.addButtonSize)
            .glassEffect(.regular.interactive(), in: Circle())
            .disabled(isSending)

            ZStack(alignment: .topLeading) {
                RichTextEditor(
                    attributedText: $content,
                    calculatedHeight: $editorHeight,
                    selectionRange: $selectionRange,
                    focusTrigger: focusTrigger,
                    isEditable: !isSending,
                    onFocusChange: onFocusChange
                )
                .opacity(isSending ? 0.5 : 1)

                if content.length == 0 {
                    Text("Message")
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                        .padding(.top, 14)
                }
            }
            .frame(height: inputHeight)
            .glassEffect(.regular, in: Capsule())

            let buttonShape: AnyShape = isSending ? AnyShape(Capsule()) : AnyShape(Circle())

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
            .frame(width: isSending ? 88 : metrics.sendButtonSize, height: metrics.sendButtonSize)
            .disabled(!isSending && !canSend)
            .glassEffect(.regular.interactive(), in: buttonShape)
            .overlay {
                if let alertColor = connectionAlertColor, !isSending {
                    Circle()
                        .fill(alertColor.opacity(0.35))
                }
            }
            .opacity(connectionAlertColor == nil ? 1 : 0.65)
            .accessibilityHint(connectionAlertHint ?? "")
        }
        .padding(.horizontal, metrics.concentricPadding)
        .padding(.bottom, metrics.bottomPadding)
        .padding(.trailing, metrics.sendButtonPadding)
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
