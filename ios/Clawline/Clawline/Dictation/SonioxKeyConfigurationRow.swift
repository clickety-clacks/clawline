//
//  SonioxKeyConfigurationRow.swift
//  Clawline
//
//  Created by Codex on 2/14/26.
//

import SwiftUI

struct SonioxKeyConfigurationRow: View {
    @Binding var keyText: String
    let status: SonioxKeyVerificationStatus
    let actionTitle: String
    let onAction: () -> Void
    var placeholder: String = "Soniox API Key"
    var showsBackground: Bool = false

    private var statusColor: Color {
        switch status {
        case .invalid:
            return .red
        case .validated:
            return .green
        case .missing, .unverified, .validating:
            return .secondary
        }
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
                    .textFieldStyle(.roundedBorder)

                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(status == .validating)
            }

            if status == .validating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let statusText = status.inlineStatusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
        .padding(showsBackground ? 10 : 0)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
        }
    }
}
