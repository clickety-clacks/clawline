//
//  CartesiaKeyStore.swift
//  Clawline
//

import Foundation
import Observation

@Observable
final class CartesiaKeyStore {
    private let keychain: KeychainSecureStore

    var apiKey: String? {
        get { keychain.getString("cartesiaApiKey") }
        set {
            if let value = newValue { keychain.setString(value, forKey: "cartesiaApiKey") }
            else { keychain.removeValue(forKey: "cartesiaApiKey") }
            NotificationCenter.default.post(name: .cartesiaApiKeyDidChange, object: self)
        }
    }

    var selectedVoiceId: String? {
        get { keychain.getString("cartesiaVoiceId") }
        set {
            if let value = newValue { keychain.setString(value, forKey: "cartesiaVoiceId") }
            else { keychain.removeValue(forKey: "cartesiaVoiceId") }
            NotificationCenter.default.post(name: .cartesiaVoiceIdDidChange, object: self)
        }
    }

    init(keychain: KeychainSecureStore) {
        self.keychain = keychain
    }
}
