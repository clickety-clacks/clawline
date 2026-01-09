//
//  SettingsManager.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import SwiftUI
import Observation

@Observable
@MainActor
final class SettingsManager {
    var plasmaConfig: PlasmaConfiguration {
        didSet { save() }
    }

    var isSettingsPresented: Bool = false

    private static let plasmaConfigKey = "plasmaConfiguration"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.plasmaConfigKey),
           let config = try? JSONDecoder().decode(PlasmaConfiguration.self, from: data) {
            self.plasmaConfig = config
        } else {
            self.plasmaConfig = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plasmaConfig) {
            UserDefaults.standard.set(data, forKey: Self.plasmaConfigKey)
        }
    }

    func resetToDefaults() {
        plasmaConfig = .default
    }

    func toggleSettings() {
        isSettingsPresented.toggle()
    }
}

// MARK: - Environment Key

private struct SettingsManagerKey: EnvironmentKey {
    static let defaultValue: SettingsManager = SettingsManager()
}

extension EnvironmentValues {
    var settingsManager: SettingsManager {
        get { self[SettingsManagerKey.self] }
        set { self[SettingsManagerKey.self] = newValue }
    }
}
