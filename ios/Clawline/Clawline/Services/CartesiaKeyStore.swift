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
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { keychain.removeValue(forKey: "cartesiaApiKey") }
            else { keychain.setString(trimmed, forKey: "cartesiaApiKey") }
            NotificationCenter.default.post(name: .cartesiaApiKeyDidChange, object: self)
        }
    }

    var selectedVoiceId: String? {
        get { keychain.getString("cartesiaVoiceId") }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { keychain.removeValue(forKey: "cartesiaVoiceId") }
            else { keychain.setString(trimmed, forKey: "cartesiaVoiceId") }
            NotificationCenter.default.post(name: .cartesiaVoiceIdDidChange, object: self)
        }
    }

    var editableAPIKey: String {
        get { apiKey ?? "" }
        set { apiKey = newValue }
    }

    var editableVoiceId: String {
        get { selectedVoiceId ?? "" }
        set { selectedVoiceId = newValue }
    }

    var apiKeyForCredentialSync: String? {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var voiceIdForCredentialSync: String? {
        selectedVoiceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(keychain: KeychainSecureStore) {
        self.keychain = keychain
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
