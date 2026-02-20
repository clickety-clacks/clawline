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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var effectiveColorScheme: ColorScheme {
#if os(visionOS)
        return settings.appearanceMode == .dark ? .dark : .light
#else
        return colorScheme
#endif
    }

    private var previewBackgroundColor: Color {
        effectiveColorScheme == .dark
            ? Color(red: 0.1, green: 0.12, blue: 0.15)
            : Color(uiColor: .systemGray6)
    }

    private var dictationDiagnosticsText: String {
        let baseline = settings.dictationCausticsBaselineSpeed
        let max = settings.dictationCausticsMaxSpeed
        let quietNormalized = 0.0
        let loudNormalized = 1.0
        let quietIntensity = 0.45 + (0.40 * quietNormalized)
        let loudIntensity = 0.45 + (0.40 * loudNormalized)
        let quietScale = 1.5 + (1.1 * quietNormalized)
        let loudScale = 1.5 + (1.1 * loudNormalized)

        return """
        {
          "dictationCaustics": {
            "baselineSpeed": \(String(format: "%.3f", baseline)),
            "maxSpeed": \(String(format: "%.3f", max)),
            "amplitudeNormalization": { "floor": 0.35, "range": 8.65 },
            "intensity": { "formula": "0.45 + (0.40 * normalizedAmplitude)", "quiet": \(String(format: "%.3f", quietIntensity)), "loud": \(String(format: "%.3f", loudIntensity)) },
            "scale": { "formula": "1.5 + (1.1 * normalizedAmplitude)", "quiet": \(String(format: "%.3f", quietScale)), "loud": \(String(format: "%.3f", loudScale)) },
            "overlay": { "baseOpacity": 0.30, "activeOpacity": 0.92, "blendMode": "plusLighter" },
            "colors": [
              { "r": 1.00, "g": 0.96, "b": 0.88 },
              { "r": 0.88, "g": 0.95, "b": 1.00 },
              { "r": 0.94, "g": 0.91, "b": 1.00 }
            ],
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

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Caustics Preview")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 12) {
                            dictationCausticsPreview(amplitude: 0)
                            dictationCausticsPreview(amplitude: 9)
                        }
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading) {
                        Text("Baseline Speed: \(settings.dictationCausticsBaselineSpeed, specifier: "%.2f")")
                        Slider(
                            value: $settings.dictationCausticsBaselineSpeed,
                            in: 0.10...settings.dictationCausticsMaxSpeed
                        )
                    }

                    VStack(alignment: .leading) {
                        Text("Max Speed: \(settings.dictationCausticsMaxSpeed, specifier: "%.2f")")
                        Slider(
                            value: $settings.dictationCausticsMaxSpeed,
                            in: settings.dictationCausticsBaselineSpeed...0.60
                        )
                    }

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

    private func dictationCausticsPreview(amplitude: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return ZStack {
            DictationCausticsUnderlay(
                isActive: true,
                amplitude: amplitude,
                cornerRadius: 14,
                reduceMotionEnabled: accessibilityReduceMotion,
                baselineSpeed: settings.dictationCausticsBaselineSpeed,
                maxSpeed: settings.dictationCausticsMaxSpeed
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
