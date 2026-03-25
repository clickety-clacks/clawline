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

    var isSettingsPresented: Bool = false

    private static let effectConfigKey = "backgroundEffectConfiguration"
    private static let appearanceModeKey = "appearanceMode"
    private static let lifecycleDebugOverlayEnabledKey = "debug.lifecycleOverlayEnabled"

    init() {
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

        self.trustSelfSignedCertificates = ProviderTLSSettingsStore.trustSelfSignedCertificates
        self.pinnedLeafCertificateSHA256 = ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 ?? ""
        self.fontScale = AppFontScale.persistedValue()
        self.isLifecycleDebugOverlayEnabled = UserDefaults.standard.bool(forKey: Self.lifecycleDebugOverlayEnabledKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(effectConfig) {
            UserDefaults.standard.set(data, forKey: Self.effectConfigKey)
        }
    }

    private func saveAppearanceMode() {
        UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
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
            fontScale = next
            fontScaleChangeSequence &+= 1
        }
        pendingFontScaleToastMessage = AppFontScale.toastMessage(for: next)
        fontScaleToastSequence &+= 1
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
