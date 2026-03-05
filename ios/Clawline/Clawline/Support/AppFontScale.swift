//
//  AppFontScale.swift
//  Clawline
//

import CoreGraphics
import Foundation

enum AppFontScale {
    static let storageKey = "appFontScale"
    static let defaultValue: CGFloat = 1.0
    static let step: CGFloat = 0.1
    static let minimum: CGFloat = 0.8
    static let maximum: CGFloat = 1.6

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    static func persistedValue(defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultValue
        }
        return clamp(CGFloat(defaults.double(forKey: storageKey)))
    }

    static func persist(_ value: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(value)), forKey: storageKey)
    }

    static func toastMessage(for value: CGFloat) -> String {
        "Font scale \(Int((clamp(value) * 100).rounded()))%"
    }
}
