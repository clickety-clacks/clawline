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
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        let key = "clawline.deviceId"
        if let override = environment["CLAWLINE_DEVICE_ID"],
           UUID(uuidString: override) != nil {
            storage.set(override, forKey: key)
            deviceId = override
            return
        }

        if let existing = storage.string(forKey: key) {
            deviceId = existing
        } else {
            let newId = UUID().uuidString
            storage.set(newId, forKey: key)
            deviceId = newId
        }
    }
}
