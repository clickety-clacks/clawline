//
//  SonioxKeyConfigurationRow.swift
//  Clawline
//
//  Created by Codex on 2/14/26.
//

import SwiftUI

struct SonioxKeyConfigurationRow: View {
    enum Style {
        case settings
        case surface
    }

    @Binding var keyText: String
    let status: SonioxKeyVerificationStatus
    let actionTitle: String
    let onAction: () -> Void
    var placeholder: String = "Soniox API Key"
    var style: Style = .settings
    var colorSchemeOverride: ColorScheme? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var scheme: ColorScheme {
        colorSchemeOverride ?? colorScheme
    }

    private var statusColor: Color {
        switch status {
        case .invalid:
            return ChatFlowTheme.connectionDisconnected(scheme)
        case .validated:
            return ChatFlowTheme.sage(scheme)
        case .missing, .unverified, .validating:
            return ChatFlowTheme.stone(scheme)
        }
    }

    private var fieldCornerRadius: CGFloat {
        style == .surface ? 10 : 12
    }

    private var fieldPadding: EdgeInsets {
        style == .surface
            ? .init(top: 8, leading: 12, bottom: 8, trailing: 12)
            : .init(top: 10, leading: 14, bottom: 10, trailing: 14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $keyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
#if !os(visionOS)
                    .keyboardType(.asciiCapable)
#endif
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(ChatFlowTheme.ink(scheme))
                    .padding(fieldPadding)
                    .background(
                        RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous)
                            .fill(ChatFlowTheme.ink(scheme).opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous)
                            .stroke(ChatFlowTheme.ink(scheme).opacity(0.12), lineWidth: 1)
                    )
                    .textFieldStyle(.plain)

                Button(action: onAction) {
                    Group {
                        if status == .validating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(actionTitle)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ChatFlowTheme.sage(scheme), in: Capsule())
                }
                .buttonStyle(.plain)
                    .disabled(status == .validating)
            }

            if let statusText = status.inlineStatusText, status != .validating {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
    }
}
