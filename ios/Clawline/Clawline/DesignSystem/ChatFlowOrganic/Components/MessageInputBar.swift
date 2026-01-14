//
//  MessageInputBar.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit

/// Input bar with concentric corner alignment.
/// Calculates padding to align element corners with device bezel corners.
///
/// ## Keyboard Detection
/// Takes `bottomSafeAreaInset` (from GeometryReader) and computes keyboard visibility
/// using a threshold. This is CRITICAL for avoiding position jumps - passing a Bool
/// computed from state causes timing issues. The raw inset value is available in the
/// same layout pass as the keyboard animation.
struct MessageInputBar: View {
    @Binding var text: String
    let isSending: Bool
    /// Pass geometry.safeAreaInsets.bottom directly - DO NOT pass a computed Bool.
    let bottomSafeAreaInset: CGFloat
    let onSend: () -> Void
    let onAdd: () -> Void
    let onFocusChange: (Bool) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @FocusState private var fieldFocused: Bool
    @FocusState private var isInputFocused: Bool

    private var metrics: MessageInputBarMetrics {
        MessageInputBarMetrics(
            horizontalSizeClass: horizontalSizeClass,
            bottomSafeAreaInset: bottomSafeAreaInset,
            deviceCornerRadius: deviceCornerRadius
        )
    }

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
                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.leading, metrics.inputBarHeight / 2)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit(onSend)
                    .focused($fieldFocused)
                    .onChange(of: fieldFocused) { _, newValue in
                        onFocusChange(newValue)
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            fieldFocused = true
                            onFocusChange(true)
                        }
                    )

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
        .safeAreaPadding(.bottom, -metrics.concentricOffset)
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
                onSend: {},
                onAdd: {},
                onFocusChange: { _ in }
            )
        }
}
