import Foundation
import Observation
import Security

@MainActor
@Observable
final class WatchCredentialStore {
    private enum Keys {
        static let token = "watch.auth.token"
        static let userId = "watch.auth.userId"
        static let providerBaseURL = "watch.provider.baseURL"
        static let sonioxApiKey = "watch.soniox.apiKey"
        static let cartesiaApiKey = "watch.cartesia.apiKey"
        static let cartesiaVoiceId = "watch.cartesia.voiceId"
    }

    private let keychain: WatchKeychainStore

    private(set) var providerToken: String?
    private(set) var userId: String?
    private(set) var providerBaseURL: URL?
    private(set) var sonioxApiKey: String?
    private(set) var cartesiaApiKey: String?
    private(set) var cartesiaVoiceId: String?

    var onCredentialsChanged: (() -> Void)?

    convenience init() {
        self.init(keychain: WatchKeychainStore(accessGroup: "group.co.clicketyclacks.Clawline"))
    }

    init(keychain: WatchKeychainStore) {
        self.keychain = keychain
        self.providerToken = keychain.getString(Keys.token)
        self.userId = keychain.getString(Keys.userId)
        if let rawURL = keychain.getString(Keys.providerBaseURL) {
            self.providerBaseURL = URL(string: rawURL)
        }
        self.sonioxApiKey = keychain.getString(Keys.sonioxApiKey)
        self.cartesiaApiKey = keychain.getString(Keys.cartesiaApiKey)
        self.cartesiaVoiceId = keychain.getString(Keys.cartesiaVoiceId)
    }

    var hasProviderCredentials: Bool {
        providerToken?.isEmpty == false && providerBaseURL != nil
    }

    func apply(userInfo: [String: Any]) {
        var changed = false

        if let token = userInfo["token"] as? String {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = applyCredential(trimmed, current: providerToken, key: Keys.token)
            providerToken = result.value
            if result.changed {
                changed = true
            }
        }

        if let userId = userInfo["userId"] as? String {
            let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = applyCredential(trimmed, current: self.userId, key: Keys.userId)
            self.userId = result.value
            if result.changed {
                changed = true
            }
        }

        if let baseURL = userInfo["providerBaseURL"] as? String {
            let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if providerBaseURL != nil {
                    providerBaseURL = nil
                    keychain.removeValue(forKey: Keys.providerBaseURL)
                    changed = true
                }
            } else if let url = URL(string: trimmed), providerBaseURL != url {
                providerBaseURL = url
                keychain.setString(trimmed, forKey: Keys.providerBaseURL)
                changed = true
            }
        }

        if let soniox = userInfo["sonioxApiKey"] as? String {
            let trimmed = soniox.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = applyCredential(trimmed, current: sonioxApiKey, key: Keys.sonioxApiKey)
            sonioxApiKey = result.value
            if result.changed {
                changed = true
            }
        }

        if let cartesia = userInfo["cartesiaApiKey"] as? String {
            let trimmed = cartesia.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = applyCredential(trimmed, current: cartesiaApiKey, key: Keys.cartesiaApiKey)
            cartesiaApiKey = result.value
            if result.changed {
                changed = true
            }
        }

        if let voiceId = userInfo["cartesiaVoiceId"] as? String {
            let trimmed = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = applyCredential(trimmed, current: cartesiaVoiceId, key: Keys.cartesiaVoiceId)
            cartesiaVoiceId = result.value
            if result.changed {
                changed = true
            }
        }

        if changed {
            onCredentialsChanged?()
        }
    }

    func clear() {
        providerToken = nil
        userId = nil
        providerBaseURL = nil
        sonioxApiKey = nil
        cartesiaApiKey = nil
        cartesiaVoiceId = nil

        keychain.removeValue(forKey: Keys.token)
        keychain.removeValue(forKey: Keys.userId)
        keychain.removeValue(forKey: Keys.providerBaseURL)
        keychain.removeValue(forKey: Keys.sonioxApiKey)
        keychain.removeValue(forKey: Keys.cartesiaApiKey)
        keychain.removeValue(forKey: Keys.cartesiaVoiceId)

        onCredentialsChanged?()
    }

    private func applyCredential(_ value: String, current: String?, key: String) -> (value: String?, changed: Bool) {
        if value.isEmpty {
            guard current != nil else { return (nil, false) }
            keychain.removeValue(forKey: key)
            return (nil, true)
        }

        guard current != value else { return (current, false) }
        keychain.setString(value, forKey: key)
        return (value, true)
    }

#if DEBUG
    func debugApplyMockCredentials() {
        providerToken = "watch-ui-test-token"
        userId = "watch-ui-test-user"
        providerBaseURL = URL(string: "https://example.invalid")
        sonioxApiKey = "watch-ui-test-soniox"
        cartesiaApiKey = "watch-ui-test-cartesia"
        cartesiaVoiceId = "watch-ui-test-voice"
        onCredentialsChanged?()
    }
#endif
}

final class WatchKeychainStore {
    private let service: String
    private let accessGroup: String?

    init(service: String = "co.clicketyclacks.Clawline.watch", accessGroup: String? = "group.co.clicketyclacks.Clawline") {
        self.service = service
        self.accessGroup = accessGroup
    }

    func getString(_ key: String) -> String? {
        guard let data = getData(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ value: String, forKey key: String) {
        setData(Data(value.utf8), forKey: key)
    }

    func removeValue(forKey key: String) {
        var query = baseQuery(forKey: key)
        query[kSecClass as String] = kSecClassGenericPassword
        SecItemDelete(query as CFDictionary)
    }

    private func getData(_ key: String) -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func setData(_ data: Data, forKey key: String) {
        var query = baseQuery(forKey: key)
        query[kSecClass as String] = kSecClassGenericPassword

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            return
        }

        var addQuery = query
        for (k, v) in attributes {
            addQuery[k] = v
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess, accessGroup != nil {
            // Retry without access group if entitlement is missing during local/dev builds.
            var fallback = addQuery
            fallback.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(fallback as CFDictionary, nil)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
