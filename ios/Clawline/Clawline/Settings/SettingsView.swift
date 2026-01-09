//
//  SettingsView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable Plasma Effect", isOn: $settings.plasmaConfig.isEnabled)
                } header: {
                    Text("Plasma Effect")
                }

                if settings.plasmaConfig.isEnabled {
                    Section {
                        ColorPicker("Color 1", selection: color1Binding)
                        ColorPicker("Color 2", selection: color2Binding)
                        ColorPicker("Color 3", selection: color3Binding)
                    } header: {
                        Text("Colors")
                    } footer: {
                        Text("Off-white pastels work best for a subtle shine effect.")
                    }

                    Section {
                        VStack(alignment: .leading) {
                            Text("Intensity: \(settings.plasmaConfig.intensity, specifier: "%.2f")")
                            Slider(value: $settings.plasmaConfig.intensity, in: 0...0.5)
                        }

                        VStack(alignment: .leading) {
                            Text("Speed: \(settings.plasmaConfig.speed, specifier: "%.2f")")
                            Slider(value: $settings.plasmaConfig.speed, in: 0.1...1.0)
                        }

                        VStack(alignment: .leading) {
                            Text("Scale: \(settings.plasmaConfig.scale, specifier: "%.1f")")
                            Slider(value: $settings.plasmaConfig.scale, in: 0.1...10)
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
            get: { settings.plasmaConfig.color1.color },
            set: { settings.plasmaConfig.color1 = CodableColor(color: $0) }
        )
    }

    private var color2Binding: Binding<Color> {
        Binding(
            get: { settings.plasmaConfig.color2.color },
            set: { settings.plasmaConfig.color2 = CodableColor(color: $0) }
        )
    }

    private var color3Binding: Binding<Color> {
        Binding(
            get: { settings.plasmaConfig.color3.color },
            set: { settings.plasmaConfig.color3 = CodableColor(color: $0) }
        )
    }

    private var previewCard: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.regularMaterial)
            .frame(height: 100)
            .overlay {
                Text("Glass Preview")
                    .foregroundStyle(.secondary)
            }
            .plasmaEffect(settings.plasmaConfig)
    }
}

#Preview {
    SettingsView(settings: SettingsManager())
}
