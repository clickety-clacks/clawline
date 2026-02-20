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
    var effectConfig: BackgroundEffectConfiguration {
        didSet { save() }
    }

    enum AppearanceMode: String, Codable {
        case dark
        case light
    }

    var appearanceMode: AppearanceMode {
        didSet { saveAppearanceMode() }
    }

    var sonioxAPIKey: String {
        didSet { handleSonioxKeyChanged(from: oldValue, to: sonioxAPIKey) }
    }

    var dictationCausticsBaselineSpeed: Double {
        didSet { saveDictationCausticsSettings() }
    }

    var dictationCausticsMaxSpeed: Double {
        didSet { saveDictationCausticsSettings() }
    }

    private(set) var sonioxKeyStatus: SonioxKeyVerificationStatus {
        didSet { SonioxConfigurationStore.setKeyStatus(sonioxKeyStatus) }
    }

    var isSettingsPresented: Bool = false

    private static let effectConfigKey = "backgroundEffectConfiguration"
    private static let appearanceModeKey = "appearanceMode"
    private static let dictationCausticsBaselineSpeedKey = "dictation.caustics.baselineSpeed"
    private static let dictationCausticsMaxSpeedKey = "dictation.caustics.maxSpeed"
    static let defaultDictationCausticsBaselineSpeed: Double = 0.24
    static let defaultDictationCausticsMaxSpeed: Double = 0.34
    private let sonioxVerifier: any SonioxKeyVerifying

    init(sonioxVerifier: any SonioxKeyVerifying = SonioxKeyVerifier()) {
        self.sonioxVerifier = sonioxVerifier
        if let data = UserDefaults.standard.data(forKey: Self.effectConfigKey),
           let config = try? JSONDecoder().decode(BackgroundEffectConfiguration.self, from: data) {
            self.effectConfig = config
        } else {
            self.effectConfig = .default
        }

        if let raw = UserDefaults.standard.string(forKey: Self.appearanceModeKey),
           let mode = AppearanceMode(rawValue: raw) {
            self.appearanceMode = mode
        } else {
            self.appearanceMode = .dark
        }

        self.sonioxAPIKey = SonioxConfigurationStore.editableAPIKey
        self.sonioxKeyStatus = SonioxConfigurationStore.keyStatus
        self.dictationCausticsBaselineSpeed = UserDefaults.standard.object(forKey: Self.dictationCausticsBaselineSpeedKey) as? Double
            ?? Self.defaultDictationCausticsBaselineSpeed
        self.dictationCausticsMaxSpeed = UserDefaults.standard.object(forKey: Self.dictationCausticsMaxSpeedKey) as? Double
            ?? Self.defaultDictationCausticsMaxSpeed
    }

    private func save() {
        if let data = try? JSONEncoder().encode(effectConfig) {
            UserDefaults.standard.set(data, forKey: Self.effectConfigKey)
        }
    }

    private func saveAppearanceMode() {
        UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
    }

    private func saveDictationCausticsSettings() {
        UserDefaults.standard.set(dictationCausticsBaselineSpeed, forKey: Self.dictationCausticsBaselineSpeedKey)
        UserDefaults.standard.set(dictationCausticsMaxSpeed, forKey: Self.dictationCausticsMaxSpeedKey)
    }

    func resetToDefaults() {
        effectConfig = .default
        appearanceMode = .dark
        dictationCausticsBaselineSpeed = Self.defaultDictationCausticsBaselineSpeed
        dictationCausticsMaxSpeed = Self.defaultDictationCausticsMaxSpeed
    }

    func toggleSettings() {
        isSettingsPresented.toggle()
    }

    var preferredColorScheme: ColorScheme {
        appearanceMode == .dark ? .dark : .light
    }

    func toggleAppearanceMode() {
        appearanceMode = appearanceMode == .dark ? .light : .dark
    }

    var sonioxCTATitle: String {
        sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Get Key" : "Verify"
    }

    func handleSonioxPrimaryAction(openURL: (URL) -> Void) async -> Bool {
        let trimmed = sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sonioxKeyStatus = .missing
            SonioxConfigurationStore.setAPIKey(nil)
            openURL(SonioxConfigurationStore.keyManagementURL)
            return false
        }
        return await verifySonioxKey()
    }

    @discardableResult
    func verifySonioxKey() async -> Bool {
        let trimmed = sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sonioxKeyStatus = .missing
            SonioxConfigurationStore.setAPIKey(nil)
            return false
        }

        sonioxKeyStatus = .validating
        let isValid = await sonioxVerifier.verify(apiKey: trimmed)
        sonioxKeyStatus = isValid ? .validated : .invalid
        return isValid
    }

    private func handleSonioxKeyChanged(from oldValue: String, to newValue: String) {
        let oldTrimmed = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        SonioxConfigurationStore.setAPIKey(trimmed.isEmpty ? nil : trimmed)
        if trimmed.isEmpty {
            sonioxKeyStatus = .missing
        } else if oldTrimmed != trimmed, sonioxKeyStatus != .validating {
            sonioxKeyStatus = .unverified
        }
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
