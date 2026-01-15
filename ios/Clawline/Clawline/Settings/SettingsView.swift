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
}

#Preview {
    SettingsView(settings: SettingsManager())
}
