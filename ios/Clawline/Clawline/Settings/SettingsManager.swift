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

    let sonioxKeyStore: SonioxKeyStore

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

    var fontScale: CGFloat {
        didSet { saveFontScale() }
    }

    var isLifecycleDebugOverlayEnabled: Bool {
        didSet { saveLifecycleDebugOverlayEnabled() }
    }

    private(set) var fontScaleChangeSequence: Int = 0
    private(set) var fontScaleToastSequence: Int = 0
    private var pendingFontScaleToastMessage: String?

    var sonioxAPIKey: String {
        get { sonioxKeyStore.editableKey }
        set { sonioxKeyStore.setKey(newValue) }
    }

    var sonioxKeyStatus: SonioxKeyVerificationStatus {
        sonioxKeyStore.keyStatus
    }

    var isSettingsPresented: Bool = false

    private static let effectConfigKey = "backgroundEffectConfiguration"
    private static let appearanceModeKey = "appearanceMode"
    private static let lifecycleDebugOverlayEnabledKey = "debug.lifecycleOverlayEnabled"
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

    init(sonioxKeyStore: SonioxKeyStore) {
        self.sonioxKeyStore = sonioxKeyStore

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
        let initialFontScale = AppFontScale.persistedValue()
        self.fontScale = initialFontScale
        self.isLifecycleDebugOverlayEnabled = UserDefaults.standard.bool(forKey: Self.lifecycleDebugOverlayEnabledKey)
        AppFontScale.useActiveValue(initialFontScale)
    }

    convenience init() {
        self.init(sonioxKeyStore: SonioxKeyStore())
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

    private func saveFontScale() {
        AppFontScale.persist(fontScale)
    }

    private func saveLifecycleDebugOverlayEnabled() {
        UserDefaults.standard.set(
            isLifecycleDebugOverlayEnabled,
            forKey: Self.lifecycleDebugOverlayEnabledKey
        )
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
        resetFontScale()
        isLifecycleDebugOverlayEnabled = false
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
        sonioxKeyStore.ctaTitle
    }

    func handleSonioxPrimaryAction(openURL: (URL) -> Void) async -> Bool {
        if !sonioxKeyStore.hasKey {
            openURL(SonioxConfigurationStore.keyManagementURL)
            return false
        }
        return await verifySonioxKey()
    }

    @discardableResult
    func verifySonioxKey() async -> Bool {
        guard sonioxKeyStore.hasKey else {
            return false
        }
        return await sonioxKeyStore.verify()
    }

    func increaseFontScale() {
        adjustFontScale(by: AppFontScale.step)
    }

    func decreaseFontScale() {
        adjustFontScale(by: -AppFontScale.step)
    }

    func resetFontScale() {
        applyFontScale(AppFontScale.defaultValue)
    }

    func consumePendingFontScaleToastMessage() -> String? {
        defer { pendingFontScaleToastMessage = nil }
        return pendingFontScaleToastMessage
    }

    private func adjustFontScale(by delta: CGFloat) {
        applyFontScale(fontScale + delta)
    }

    private func applyFontScale(_ value: CGFloat) {
        let next = AppFontScale.clamp(value)
        if next != fontScale {
            AppFontScale.useActiveValue(next)
            fontScale = next
            fontScaleChangeSequence &+= 1
        }
        pendingFontScaleToastMessage = AppFontScale.toastMessage(for: next)
        fontScaleToastSequence &+= 1
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
    @MainActor static let defaultValue: SettingsManager = SettingsManager()
}

extension EnvironmentValues {
    var settingsManager: SettingsManager {
        get { self[SettingsManagerKey.self] }
        set { self[SettingsManagerKey.self] = newValue }
    }
}
