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

    var dictationCausticsBrightness: Double {
        didSet { saveDictationCausticsSettings() }
    }

    var dictationCausticsScale: Double {
        didSet { saveDictationCausticsSettings() }
    }

    var dictationCausticsSharpness: Double {
        didSet { saveDictationCausticsSettings() }
    }

    var dictationCausticsColor1: CodableColor {
        didSet { saveDictationCausticsSettings() }
    }

    var trustSelfSignedCertificates: Bool {
        didSet { saveTrustSelfSignedCertificates() }
    }

    var pinnedLeafCertificateSHA256: String {
        didSet { savePinnedLeafCertificateSHA256() }
    }

    private(set) var sonioxKeyStatus: SonioxKeyVerificationStatus {
        didSet { SonioxConfigurationStore.setKeyStatus(sonioxKeyStatus) }
    }

    var isSettingsPresented: Bool = false

    private static let effectConfigKey = "backgroundEffectConfiguration"
    private static let appearanceModeKey = "appearanceMode"
    private static let dictationCausticsBaselineSpeedKey = "dictation.caustics.baselineSpeed"
    private static let dictationCausticsMaxSpeedKey = "dictation.caustics.maxSpeed"
    private static let dictationCausticsBrightnessKey = "dictation.caustics.brightness"
    private static let dictationCausticsScaleKey = "dictation.caustics.scale"
    private static let dictationCausticsSharpnessKey = "dictation.caustics.sharpness"
    private static let dictationCausticsColor1Key = "dictation.caustics.color1"
    static let defaultDictationCausticsBaselineSpeed: Double = 0.600
    static let defaultDictationCausticsMaxSpeed: Double = 2.140
    static let defaultDictationCausticsBrightness: Double = 0.373
    static let defaultDictationCausticsScale: Double = 5.000
    static let defaultDictationCausticsSharpness: Double = 1.065
    static let defaultDictationCausticsColor1 = CodableColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.000)
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
        self.dictationCausticsBrightness = UserDefaults.standard.object(forKey: Self.dictationCausticsBrightnessKey) as? Double
            ?? Self.defaultDictationCausticsBrightness
        self.dictationCausticsScale = UserDefaults.standard.object(forKey: Self.dictationCausticsScaleKey) as? Double
            ?? Self.defaultDictationCausticsScale
        self.dictationCausticsSharpness = UserDefaults.standard.object(forKey: Self.dictationCausticsSharpnessKey) as? Double
            ?? Self.defaultDictationCausticsSharpness
        self.dictationCausticsColor1 = Self.loadCodableColor(
            forKey: Self.dictationCausticsColor1Key,
            fallback: Self.defaultDictationCausticsColor1
        )
        self.trustSelfSignedCertificates = ProviderTLSSettingsStore.trustSelfSignedCertificates
        self.pinnedLeafCertificateSHA256 = ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 ?? ""
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
        UserDefaults.standard.set(dictationCausticsBrightness, forKey: Self.dictationCausticsBrightnessKey)
        UserDefaults.standard.set(dictationCausticsScale, forKey: Self.dictationCausticsScaleKey)
        UserDefaults.standard.set(dictationCausticsSharpness, forKey: Self.dictationCausticsSharpnessKey)
        if let data = try? JSONEncoder().encode(dictationCausticsColor1) {
            UserDefaults.standard.set(data, forKey: Self.dictationCausticsColor1Key)
        }
    }

    private func saveTrustSelfSignedCertificates() {
        ProviderTLSSettingsStore.trustSelfSignedCertificates = trustSelfSignedCertificates
    }

    private func savePinnedLeafCertificateSHA256() {
        ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = pinnedLeafCertificateSHA256
    }

    func resetToDefaults() {
        effectConfig = .default
        appearanceMode = .dark
        dictationCausticsBaselineSpeed = Self.defaultDictationCausticsBaselineSpeed
        dictationCausticsMaxSpeed = Self.defaultDictationCausticsMaxSpeed
        dictationCausticsBrightness = Self.defaultDictationCausticsBrightness
        dictationCausticsScale = Self.defaultDictationCausticsScale
        dictationCausticsSharpness = Self.defaultDictationCausticsSharpness
        dictationCausticsColor1 = Self.defaultDictationCausticsColor1
        trustSelfSignedCertificates = true
        pinnedLeafCertificateSHA256 = ""
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

    private static func loadCodableColor(forKey key: String, fallback: CodableColor) -> CodableColor {
        guard let data = UserDefaults.standard.data(forKey: key),
              let color = try? JSONDecoder().decode(CodableColor.self, from: data) else {
            return fallback
        }
        return color
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
