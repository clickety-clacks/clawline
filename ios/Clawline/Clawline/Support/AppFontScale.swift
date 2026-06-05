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
#if targetEnvironment(macCatalyst)
    private nonisolated static let activeValueStore = ActiveValueStore()
#endif

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
        let clamped = clamp(value)
        defaults.set(Double(clamped), forKey: storageKey)
#if targetEnvironment(macCatalyst)
        if defaults === UserDefaults.standard {
            useActiveValue(clamped)
        }
#endif
    }

    nonisolated static func useActiveValue(_ value: CGFloat) {
#if targetEnvironment(macCatalyst)
        activeValueStore.set(clamp(value))
#endif
    }

    nonisolated static func currentValue(defaults: UserDefaults = .standard) -> CGFloat {
#if targetEnvironment(macCatalyst)
        if defaults !== UserDefaults.standard {
            return persistedValue(defaults: defaults)
        }
        return activeValueStore.get() ?? persistedValue(defaults: defaults)
#else
        persistedValue(defaults: defaults)
#endif
    }

    nonisolated static func scaledPointSize(
        for basePointSize: CGFloat,
        defaults: UserDefaults = .standard
    ) -> CGFloat {
        (basePointSize + platformBasePointDelta) * currentValue(defaults: defaults)
    }

    nonisolated static func toastMessage(for value: CGFloat) -> String {
        "Font scale \(Int((clamp(value) * 100).rounded()))%"
    }

#if targetEnvironment(macCatalyst)
    private final class ActiveValueStore: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var value: CGFloat?

        nonisolated func set(_ value: CGFloat) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        nonisolated func get() -> CGFloat? {
            lock.lock()
            let value = self.value
            lock.unlock()
            return value
        }
    }
#endif
}
