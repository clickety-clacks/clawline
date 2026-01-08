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
struct MessageInputBar: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void
    let onAdd: () -> Void

    // Element sizes
    private let addButtonSize: CGFloat = 48
    private let inputBarHeight: CGFloat = 48
    private let sendButtonSize: CGFloat = 32

    // Device corner radius: ~50pt for Face ID devices, 0pt for home button devices
    private var deviceCornerRadius: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    // Concentric padding formula: deviceCornerRadius - elementRadius
    // For 48pt Circle/Capsule elements, radius = 24pt
    private var concentricPadding: CGFloat {
        max(deviceCornerRadius - (inputBarHeight / 2), 8)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: addButtonSize, height: addButtonSize)
            .glassEffect(.regular.interactive(), in: Circle())

            HStack(spacing: 8) {
                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.leading, inputBarHeight / 2)
                    .lineLimit(1...4)

                Button(action: onSend) {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .frame(width: sendButtonSize, height: sendButtonSize)
                .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .glassEffect(.regular.interactive(), in: Circle())
                .padding(.trailing, (inputBarHeight - sendButtonSize) / 2)
            }
            .frame(height: inputBarHeight)
            .glassEffect(.regular, in: Capsule())
        }
        // Equal padding on horizontal and bottom for concentricity
        .padding(.horizontal, concentricPadding)
        .padding(.bottom, concentricPadding)
    }
}

#Preview("Empty") {
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                text: .constant(""),
                isSending: false,
                onSend: {},
                onAdd: {}
            )
        }
}

#Preview("With Text") {
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                text: .constant("Hello there!"),
                isSending: false,
                onSend: {},
                onAdd: {}
            )
        }
}

#Preview("Sending") {
    Color.clear
        .safeAreaInset(edge: .bottom) {
            MessageInputBar(
                text: .constant("Sending message..."),
                isSending: true,
                onSend: {},
                onAdd: {}
            )
        }
}
