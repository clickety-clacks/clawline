//
//  DeviceIdentifier.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

final class DeviceIdentifier: DeviceIdentifying {
    let deviceId: String

    init(storage: UserDefaults = .standard,
         secureStore: SecureStoring = KeychainSecureStore(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        let key = "clawline.deviceId"
        if let override = environment["CLAWLINE_DEVICE_ID"],
           UUID(uuidString: override) != nil {
            storage.set(override, forKey: key)
            secureStore.setString(override, forKey: key)
            deviceId = override
            return
        }

        if let existing = secureStore.getString(key), UUID(uuidString: existing) != nil {
            deviceId = existing
            return
        }

        if let existing = storage.string(forKey: key), UUID(uuidString: existing) != nil {
            secureStore.setString(existing, forKey: key) // migrate
            deviceId = existing
            return
        }

        let newId = UUID().uuidString
        storage.set(newId, forKey: key)
        secureStore.setString(newId, forKey: key)
        deviceId = newId
    }

    nonisolated deinit {}
}
