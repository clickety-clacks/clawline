//
//  SonioxKeyStore.swift
//  Clawline
//

import Foundation
import Observation

@Observable
final class SonioxKeyStore {
    private let keychain: KeychainSecureStore

    var apiKey: String? {
        get { keychain.getString("sonioxApiKey") }
        set {
            if let value = newValue { keychain.setString(value, forKey: "sonioxApiKey") }
            else { keychain.removeValue(forKey: "sonioxApiKey") }
            // Post AFTER the write, so observers read the new value
            NotificationCenter.default.post(name: .sonioxApiKeyDidChange, object: self)
        }
    }

    init(keychain: KeychainSecureStore) {
        self.keychain = keychain
    }
}
