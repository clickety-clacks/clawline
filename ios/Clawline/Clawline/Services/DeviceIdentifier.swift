//
//  DeviceIdentifier.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

final class DeviceIdentifier: DeviceIdentifying {
    let deviceId: String

    init(storage: UserDefaults = .standard) {
        let key = "clawline.deviceId"
        if let existing = storage.string(forKey: key) {
            deviceId = existing
        } else {
            let newId = UUID().uuidString
            storage.set(newId, forKey: key)
            deviceId = newId
        }
    }
}
