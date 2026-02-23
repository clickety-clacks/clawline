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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var dictationDiagnosticsText: String {
        let baseline = settings.dictationCausticsBaselineSpeed
        let max = settings.dictationCausticsMaxSpeed
        let brightness = settings.dictationCausticsBrightness
        let scale = settings.dictationCausticsScale
        let sharpness = settings.dictationCausticsSharpness
        let color1 = settings.dictationCausticsColor1

        return """
        {
          "dictationCaustics": {
            "baselineSpeed": \(String(format: "%.3f", baseline)),
            "maxSpeed": \(String(format: "%.3f", max)),
            "brightness": \(String(format: "%.3f", brightness)),
            "scale": \(String(format: "%.3f", scale)),
            "sharpness": \(String(format: "%.3f", sharpness)),
            "amplitudeNormalization": { "floor": 0.35, "range": 8.65 },
            "intensity": { "formula": "brightness", "value": \(String(format: "%.3f", brightness)) },
            "overlay": { "baseOpacity": 0.30, "activeOpacity": 0.92, "blendMode": "plusLighter" },
            "color": { "r": \(String(format: "%.3f", color1.red)), "g": \(String(format: "%.3f", color1.green)), "b": \(String(format: "%.3f", color1.blue)), "a": \(String(format: "%.3f", color1.alpha)) },
            "audioAffects": ["speed"],
            "reduceMotionEnabled": \(accessibilityReduceMotion ? "true" : "false"),
            "reduceMotionSpeeds": { "baseline": 0.12, "max": 0.18 }
          }
        }
        """
    }

    var body: some View {
        NavigationStack {
            Form {
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

                    VStack(alignment: .leading) {
                        Text("Slow Speed: \(settings.dictationCausticsBaselineSpeed, specifier: "%.2f")")
                        Slider(
                            value: $settings.dictationCausticsBaselineSpeed,
                            in: 0.10...settings.dictationCausticsMaxSpeed
                        )
                    }

                    VStack(alignment: .leading) {
                        Text("Fast Speed: \(settings.dictationCausticsMaxSpeed, specifier: "%.2f")")
                        Slider(
                            value: $settings.dictationCausticsMaxSpeed,
                            in: settings.dictationCausticsBaselineSpeed...2.50
                        )
                    }

                    VStack(alignment: .leading) {
                        Text("Brightness: \(settings.dictationCausticsBrightness, specifier: "%.2f")")
                        Slider(value: $settings.dictationCausticsBrightness, in: 0.30...1.20)
                    }

                    VStack(alignment: .leading) {
                        Text("Scale: \(settings.dictationCausticsScale, specifier: "%.2f")")
                        Slider(value: $settings.dictationCausticsScale, in: 0.6...5.0)
                    }

                    VStack(alignment: .leading) {
                        Text("Sharpness: \(settings.dictationCausticsSharpness, specifier: "%.2f")")
                        Slider(value: $settings.dictationCausticsSharpness, in: 0.8...5.0)
                    }

                    ColorPicker("Color", selection: dictationColor1Binding)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Diagnostics")
                            .font(.subheadline.weight(.semibold))
                        ScrollView(.vertical) {
                            Text(dictationDiagnosticsText)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 160, maxHeight: 220)
                    }
                } header: {
                    Text("Voice Dictation")
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

            }
            .safeAreaInset(edge: .top, spacing: 0) {
                dictationPinnedPreview
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var dictationColor1Binding: Binding<Color> {
        Binding(
            get: { settings.dictationCausticsColor1.color },
            set: { settings.dictationCausticsColor1 = CodableColor(color: $0) }
        )
    }

    private var dictationPinnedPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dictation Caustics Preview")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                dictationCausticsPreview(amplitude: 0)
                dictationCausticsPreview(amplitude: 9)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func dictationCausticsPreview(amplitude: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return ZStack {
            DictationCausticsUnderlay(
                isActive: true,
                amplitude: amplitude,
                cornerRadius: 14,
                reduceMotionEnabled: accessibilityReduceMotion,
                baselineSpeed: settings.dictationCausticsBaselineSpeed,
                maxSpeed: settings.dictationCausticsMaxSpeed,
                brightness: settings.dictationCausticsBrightness,
                scale: settings.dictationCausticsScale,
                sharpness: settings.dictationCausticsSharpness,
                color1: settings.dictationCausticsColor1.color
            )
            .clipShape(shape)

            shape
                .fill(.regularMaterial)
                .opacity(0.85)

            Text(amplitude == 0 ? "Quiet" : "Loud")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(height: 74)
        .clipShape(shape)
    }
}

#Preview {
    SettingsView(settings: SettingsManager())
}
