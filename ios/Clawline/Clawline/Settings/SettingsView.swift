//
//  SettingsView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Bindable var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var rulePendingDeletion: TextLinkURLTemplateRule?

    private var previewBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.1, green: 0.12, blue: 0.15)
            : Color(uiColor: .systemGray6)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable Effect", isOn: $settings.effectConfig.isEnabled)

                    if settings.effectConfig.isEnabled {
                        Picker("Effect Type", selection: $settings.effectConfig.effectType) {
                            ForEach(ShaderEffectType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                    }
                } header: {
                    Text("Background Effect")
                }

                Section {
                    SonioxKeyConfigurationRow(
                        keyText: $settings.sonioxAPIKey,
                        status: settings.sonioxKeyStatus,
                        actionTitle: settings.sonioxCTATitle,
                        onAction: {
                            Task {
                                _ = await settings.handleSonioxPrimaryAction { url in
                                    openURL(url)
                                }
                            }
                        },
                        placeholder: "soniox.apiKey"
                    )
                } header: {
                    Text("Voice Dictation")
                }

                Section {
                    TextField("cartesia.apiKey", text: $settings.cartesiaAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
#if !os(visionOS)
                        .keyboardType(.asciiCapable)
#endif
                        .font(.system(.subheadline, design: .monospaced))

                    TextField("cartesia.voiceId", text: $settings.cartesiaVoiceId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
#if !os(visionOS)
                        .keyboardType(.asciiCapable)
#endif
                        .font(.system(.subheadline, design: .monospaced))
                } header: {
                    Text("Voice Playback")
                }

                Section {
                    Toggle("Trust self-signed certificates", isOn: $settings.trustSelfSignedCertificates)
                    TextField("Pinned cert SHA-256 (optional)", text: $settings.pinnedLeafCertificateSHA256)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                } header: {
                    Text("Server TLS")
                } footer: {
                    Text("When enabled, Clawline accepts self-signed TLS certificates for provider WebSocket connections. Add a SHA-256 leaf certificate fingerprint to pin a specific cert.")
                }

                Section {
                    ForEach($settings.textLinkURLTemplateRules) { $rule in
                        TextLinkURLTemplateRuleRow(
                            rule: $rule,
                            onDelete: {
                                rulePendingDeletion = rule
                            }
                        )
                    }

                    Button {
                        settings.addTextLinkURLTemplateRule()
                    } label: {
                        Label("Add Text Link Rule", systemImage: "plus")
                    }
                } header: {
                    Text("Text Link Rules")
                } footer: {
                    Text("Use regex patterns and URL templates such as https://tars.tail4105e8.ts.net:19443/tracker.html?id={match}.")
                }

#if DEBUG
                Section {
                    Toggle("Show lifecycle debug overlay", isOn: $settings.isLifecycleDebugOverlayEnabled)
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Controls on-screen lifecycle/image-send diagnostics overlay visibility.")
                }
#endif

                if settings.effectConfig.isEnabled {
                    Section {
                        ColorPicker("Color 1", selection: color1Binding)
                        if settings.effectConfig.effectType == .plasma {
                            ColorPicker("Color 2", selection: color2Binding)
                            ColorPicker("Color 3", selection: color3Binding)
                        }
                    } header: {
                        Text("Colors")
                    } footer: {
                        if settings.effectConfig.effectType == .caustics {
                            Text("Warm whites simulate sunlight through water.")
                        } else {
                            Text("Off-white pastels work best for a subtle color flow.")
                        }
                    }

                    Section {
                        VStack(alignment: .leading) {
                            Text("Intensity: \(settings.effectConfig.intensity, specifier: "%.2f")")
                            Slider(value: $settings.effectConfig.intensity, in: 0...0.5)
                        }

                        VStack(alignment: .leading) {
                            Text("Speed: \(settings.effectConfig.speed, specifier: "%.2f")")
                            Slider(value: $settings.effectConfig.speed, in: 0.1...1.0)
                        }

                        VStack(alignment: .leading) {
                            Text("Scale: \(settings.effectConfig.scale, specifier: "%.1f")")
                            Slider(value: $settings.effectConfig.scale, in: 0.1...10)
                        }
                    } header: {
                        Text("Animation")
                    }

                    Section {
                        Button("Reset to Defaults") {
                            settings.resetToDefaults()
                        }
                    }
                }

                Section {
                    previewCard
                } header: {
                    Text("Preview")
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete text link rule?",
                isPresented: deleteConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Delete Rule", role: .destructive) {
                    if let rulePendingDeletion {
                        settings.deleteTextLinkURLTemplateRule(id: rulePendingDeletion.id)
                    }
                    rulePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    rulePendingDeletion = nil
                }
            } message: {
                let pattern = rulePendingDeletion?.pattern ?? ""
                Text("This removes the rule for \(pattern.isEmpty ? "empty pattern" : pattern).")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // Color bindings that convert between CodableColor and Color
    private var color1Binding: Binding<Color> {
        Binding(
            get: { settings.effectConfig.color1.color },
            set: { settings.effectConfig.color1 = CodableColor(color: $0) }
        )
    }

    private var color2Binding: Binding<Color> {
        Binding(
            get: { settings.effectConfig.color2.color },
            set: { settings.effectConfig.color2 = CodableColor(color: $0) }
        )
    }

    private var color3Binding: Binding<Color> {
        Binding(
            get: { settings.effectConfig.color3.color },
            set: { settings.effectConfig.color3 = CodableColor(color: $0) }
        )
    }

    private var previewCard: some View {
        ZStack {
            // Background matching actual app background
            previewBackgroundColor
                .backgroundEffect(settings.effectConfig)

            // Glass element on top
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .padding(16)
                .overlay {
                    Text("Glass Preview")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { rulePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    rulePendingDeletion = nil
                }
            }
        )
    }
}

#Preview {
    SettingsView(settings: SettingsManager())
}

private struct TextLinkURLTemplateRuleRow: View {
    @Binding var rule: TextLinkURLTemplateRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Toggle("Enabled", isOn: $rule.enabled)
                Spacer(minLength: 8)
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle")
                        .imageScale(.large)
                        .accessibilityLabel("Delete text link rule")
                }
                .buttonStyle(.borderless)
            }

            TextField("Regex pattern", text: $rule.pattern)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
#if !os(visionOS)
                .keyboardType(.asciiCapable)
#endif
                .font(.system(.subheadline, design: .monospaced))

            TextField("URL template", text: $rule.urlTemplate)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
#if !os(visionOS)
                .keyboardType(.URL)
#endif
                .font(.system(.subheadline, design: .monospaced))

            Picker("Display URL", selection: $rule.displayMode) {
                ForEach(TextLinkResolvedURLDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            if let validationMessage = TextLinkURLTemplateRules.validationMessage(for: rule) {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SonioxKeyConfigurationRow: View {
    @Binding var keyText: String
    let status: SonioxKeyVerificationStatus
    let actionTitle: String
    let onAction: () -> Void
    var placeholder: String = "Soniox API Key"

    @Environment(\.colorScheme) private var colorScheme

    private var statusColor: Color {
        switch status {
        case .invalid:
            return ChatFlowTheme.connectionDisconnected(colorScheme)
        case .validated:
            return ChatFlowTheme.sage(colorScheme)
        case .missing, .unverified, .validating:
            return ChatFlowTheme.stone(colorScheme)
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
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(ChatFlowTheme.ink(colorScheme))
                    .padding(.init(top: 10, leading: 14, bottom: 10, trailing: 14))
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ChatFlowTheme.ink(colorScheme).opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ChatFlowTheme.ink(colorScheme).opacity(0.12), lineWidth: 1)
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
                    .background(ChatFlowTheme.sage(colorScheme), in: Capsule())
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
