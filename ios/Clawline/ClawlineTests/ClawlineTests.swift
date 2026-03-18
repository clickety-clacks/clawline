//
//  ClawlineTests.swift
//  ClawlineTests
//
//  Created by Mike Manzano on 1/7/26.
//

import Foundation
import Testing
@testable import Clawline

struct ClawlineTests {
    @Test("T167: font scale applies platform delta before user multiplier")
    func scaledPointSizeUsesPlatformDeltaAndPersistedScale() {
        let suiteName = "ClawlineTests.T167.scaledPointSizeUsesPlatformDeltaAndPersistedScale"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let basePointSize: CGFloat = 20
        let expectedDefault: CGFloat
#if targetEnvironment(macCatalyst)
        expectedDefault = 24
#else
        expectedDefault = 20
#endif

        #expect(AppFontScale.scaledPointSize(for: basePointSize, defaults: defaults) == expectedDefault)

        AppFontScale.persist(1.5, defaults: defaults)
        #expect(
            AppFontScale.scaledPointSize(for: basePointSize, defaults: defaults)
                == expectedDefault * 1.5
        )
    }

    @Test("T134: font scale shortcuts adjust value and emit toast message")
    @MainActor
    func fontScaleAdjustmentsEmitToast() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppFontScale.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppFontScale.storageKey)
            } else {
                defaults.removeObject(forKey: AppFontScale.storageKey)
            }
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()
        #expect(settings.fontScale == AppFontScale.defaultValue)

        settings.increaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue + AppFontScale.step)
        #expect(settings.consumePendingFontScaleToastMessage() == "Font scale 110%")

        settings.decreaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue)
        #expect(settings.consumePendingFontScaleToastMessage() == "Font scale 100%")
    }

    @Test("T134: app font scale clamps at configured limits")
    @MainActor
    func fontScaleClampsToBounds() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppFontScale.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppFontScale.storageKey)
            } else {
                defaults.removeObject(forKey: AppFontScale.storageKey)
            }
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()

        for _ in 0..<30 {
            settings.increaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.maximum)

        for _ in 0..<60 {
            settings.decreaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.minimum)
    }
}
