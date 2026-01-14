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
// The @FocusState here works ONLY because we immediately report changes via onFocusChange
// callback to the parent. The parent's @State survives; ours does not.
//
// See ChatView.swift header comment for the full explanation of why this is necessary.
// Working solution tagged: `working-keyboard-behaviors`
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// Input bar with concentric corner alignment.
/// Calculates padding to align element corners with device bezel corners.
///
/// ## State Ownership
/// This view is inside `.safeAreaInset` which causes view recreation on geometry changes.
/// State that must survive keyboard show/hide is owned by the PARENT (ChatView), not here.
/// Focus changes are reported via `onFocusChange` callback.
struct MessageInputBar: View {
    @Binding var text: String
    let isSending: Bool
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    /// Keyboard visibility state owned by parent view to survive geometry changes.
    let isKeyboardVisible: Bool
    let onSend: () -> Void
    let onAdd: () -> Void
    let onFocusChange: (Bool) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    // ⚠️ This @FocusState DOES get reset when view recreates, but that's OK because:
    // 1. We immediately report changes to parent via onFocusChange callback
    // 2. Parent's @State survives the recreation
    // 3. The callback fires BEFORE the view fully recreates
    // DO NOT try to use this state directly for positioning - use parent's state instead.
    @FocusState private var fieldFocused: Bool

    private var metrics: MessageInputBarMetrics {
        MessageInputBarMetrics(
            horizontalSizeClass: horizontalSizeClass,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: deviceCornerRadius,
            isFieldFocused: fieldFocused
        )
    }

    // NOTE: Concentric offset is now applied in ChatView where @State lives.
    // This ensures offset updates when keyboard state changes (safeAreaInset content
    // doesn't re-render on parent state change otherwise).

    // swiftlint:disable:next unused_declaration
    private var motionState: MessageInputMotionState {
        MessageInputMotionState(reduceMotionEnabled: accessibilityReduceMotion)
    }

    // Device corner radius: ~50pt for Face ID devices, 0pt for home button devices
    private var deviceCornerRadius: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    var body: some View {
        HStack(spacing: MessageInputBarMetrics.elementSpacing) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: metrics.addButtonSize, height: metrics.addButtonSize)
            .glassEffect(.regular.interactive(), in: Circle())

            HStack(spacing: 8) {
                TextField("Message", text: $text)
                    .textFieldStyle(.plain)
                    .padding(.leading, metrics.inputBarHeight / 2)
                    .submitLabel(.send)
                    .onSubmit(onSend)
                    .focused($fieldFocused)
                    // ⚠️ CRITICAL: This onChange reports focus to parent IMMEDIATELY.
                    // Parent (ChatView) owns the state that survives view recreation.
                    // DO NOT try to use fieldFocused directly for positioning calculations.
                    .onChange(of: fieldFocused) { _, newValue in
                        onFocusChange(newValue)
                    }

                Button(action: onSend) {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .frame(width: metrics.sendButtonSize, height: metrics.sendButtonSize)
                .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.trailing, metrics.sendButtonPadding)
            }
            .frame(height: metrics.inputBarHeight)
            .glassEffect(.regular, in: Capsule())
        }
        .padding(.horizontal, metrics.concentricPadding)
        .padding(.bottom, metrics.bottomPadding)
        // NOTE: Offset is now applied in ChatView where @State lives - see ChatView.swift
        // This ensures the offset updates when keyboard state changes (safeAreaInset content
        // doesn't re-render on parent state change otherwise).
    }

    // swiftlint:disable:next unused_declaration
    private var causticsConfiguration: BackgroundEffectConfiguration {
        BackgroundEffectConfiguration(
            effectType: .caustics,
            color1: CodableColor(color: Color(red: 1.0, green: 0.98, blue: 0.94)),
            color2: CodableColor(color: Color(red: 1.0, green: 0.98, blue: 0.94)),
            color3: CodableColor(color: Color(red: 1.0, green: 0.98, blue: 0.94)),
            intensity: 0.15,
            speed: 0.35,
            scale: 2.4,
            isEnabled: true
        )
    }
}

// MARK: - Caustics Overlay (currently unused, may reintroduce)

private struct GlassCausticsOverlay<S: Shape>: View {
    let configuration: BackgroundEffectConfiguration
    let shape: S
    let isEnabled: Bool

    var body: some View {
        Group {
            if isEnabled {
                shape
                    .fill(Color.white.opacity(0.12))
                    .backgroundEffect(configuration)
                    .blendMode(.screen)
                    .opacity(0.4)
            } else {
                shape.fill(Color.clear)
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("Empty") {
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                text: .constant(""),
                isSending: false,
                bottomSafeAreaInset: 34, // Simulates home indicator (keyboard hidden)
                isKeyboardVisible: false,
                onSend: {},
                onAdd: {},
                onFocusChange: { _ in }
            )
        }
}

#Preview("With Text") {
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                text: .constant("Hello there!"),
                isSending: false,
                bottomSafeAreaInset: 34, // Simulates home indicator (keyboard hidden)
                isKeyboardVisible: false,
                onSend: {},
                onAdd: {},
                onFocusChange: { _ in }
            )
        }
}

#Preview("Sending") {
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                text: .constant("Sending message..."),
                isSending: true,
                bottomSafeAreaInset: 34, // Simulates home indicator (keyboard hidden)
                isKeyboardVisible: false,
                onSend: {},
                onAdd: {},
                onFocusChange: { _ in }
            )
        }
}
