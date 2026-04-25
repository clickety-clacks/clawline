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
            AppFontScale.useActiveValue(AppFontScale.persistedValue())
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()
        #expect(settings.fontScale == AppFontScale.defaultValue)
        #expect(AppFontScale.currentValue() == settings.fontScale)

        settings.increaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue + AppFontScale.step)
        #expect(AppFontScale.currentValue() == settings.fontScale)
        #expect(settings.consumePendingFontScaleToastMessage() == "Font scale 110%")

        settings.decreaseFontScale()
        #expect(settings.fontScale == AppFontScale.defaultValue)
        #expect(AppFontScale.currentValue() == settings.fontScale)
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
            AppFontScale.useActiveValue(AppFontScale.persistedValue())
        }
        defaults.removeObject(forKey: AppFontScale.storageKey)

        let settings = SettingsManager()

        for _ in 0..<30 {
            settings.increaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.maximum)
        #expect(AppFontScale.currentValue() == AppFontScale.maximum)

        for _ in 0..<60 {
            settings.decreaseFontScale()
        }
        #expect(settings.fontScale == AppFontScale.minimum)
        #expect(AppFontScale.currentValue() == AppFontScale.minimum)
    }

    @Test("T180: placeholder text includes channel name and session key")
    func placeholderTextIncludesSessionKey() {
        #expect(
            ChatViewModel.placeholderText(
                displayName: "Main",
                sessionKey: "agent:main:clawline:flynn:main"
            ) == "Main — agent:main:clawline:flynn:main"
        )
        #expect(ChatViewModel.placeholderText(displayName: "Main", sessionKey: "") == "Main")
    }

    @Test("T001: Clawline personal terminal streams allow built-in and custom suffixes")
    func sessionKeyAllowsPersonalTerminalStreamSuffixes() {
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:main"))
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:dm"))
        #expect(SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_abcd1234"))
        #expect(SessionKey.isClawlinePersonalDM("agent:aux:clawline:flynn:s_abcd1234"))
    }

    @Test("T001: Clawline personal terminal streams reject invalid suffixes")
    func sessionKeyRejectsInvalidPersonalTerminalStreamSuffixes() {
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:global_dm"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_deadbee"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline:flynn:s_deadbeez"))
        #expect(!SessionKey.isClawlinePersonalDM("agent:main:clawline::main"))
        #expect(!SessionKey.isClawlinePersonalDM("server:main"))
    }

    @Test("T201: RootView keeps iOS system-follow by scoping preferredColorScheme to visionOS")
    func rootViewScopesPreferredColorSchemeToVisionOS() throws {
        let rootViewPath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Clawline/Views/RootView.swift")
        let source = try String(contentsOf: rootViewPath, encoding: .utf8)
        let pattern = #"#if os\(visionOS\)[\s\S]*?\.preferredColorScheme\(settings\.preferredColorScheme\)[\s\S]*?#endif"#
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let regex = try NSRegularExpression(pattern: pattern)

        #expect(regex.firstMatch(in: source, range: range) != nil)
    }
}
