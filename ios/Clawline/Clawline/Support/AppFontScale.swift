//
//  AppFontScale.swift
//  Clawline
//

import CoreGraphics
import Foundation

enum AppFontScale {
    nonisolated static let storageKey = "appFontScale"
    nonisolated static let defaultValue: CGFloat = 1.0
    nonisolated static let step: CGFloat = 0.1
    nonisolated static let minimum: CGFloat = 0.8
    nonisolated static let maximum: CGFloat = 1.6
    nonisolated static let platformBasePointDelta: CGFloat = {
#if targetEnvironment(macCatalyst)
        4.0
#else
        0.0
#endif
    }()

    nonisolated static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    nonisolated static func persistedValue(defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultValue
        }
        return clamp(CGFloat(defaults.double(forKey: storageKey)))
    }

    nonisolated static func persist(_ value: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: storageKey)
    }

    nonisolated static func scaledPointSize(
        for basePointSize: CGFloat,
        defaults: UserDefaults = .standard
    ) -> CGFloat {
        (basePointSize + platformBasePointDelta) * persistedValue(defaults: defaults)
    }

    nonisolated static func toastMessage(for value: CGFloat) -> String {
        "Font scale \(Int((clamp(value) * 100).rounded()))%"
    }
}
