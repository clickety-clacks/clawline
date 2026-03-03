//
//  KeychainSecureStore.swift
//  Clawline
//

import Foundation
import Security

final class KeychainSecureStore: SecureStoring {
    private let service: String
    private let accessGroup: String?

    nonisolated init(service: String = "co.clicketyclacks.Clawline", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func getString(_ key: String) -> String? {
        guard let data = getData(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        setData(data, forKey: key)
    }

    func removeValue(forKey key: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Internals

    private func getData(_ key: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func setData(_ data: Data, forKey key: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available after first unlock; keep stable across background launches.
            // Use kSecAttrAccessibleAfterFirstUnlock (not ThisDeviceOnly) when sharing
            // across an app group so Watch can read the item on the same device pair.
            kSecAttrAccessible as String: accessGroup != nil
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            return
        }

        var addQuery = query
        for (k, v) in attributes { addQuery[k] = v }
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

