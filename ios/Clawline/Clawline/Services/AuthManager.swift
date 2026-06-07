//
//  AuthManager.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation

extension Notification.Name {
    static let authStateDidChange = Notification.Name("AuthStateDidChange")
}

@Observable
@MainActor
final class AuthManager: AuthManaging {
    private(set) var isAuthenticated: Bool = false
    private(set) var currentUserId: String?
    private(set) var token: String?
    private(set) var isAdmin: Bool = false

    private let storage: UserDefaults
    private let secureStore: SecureStoring

    private enum StorageKeys {
        static let token = "auth.token"
        static let userId = "auth.userId"
        static let isAdmin = "auth.isAdmin"
    }

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        self.secureStore = KeychainSecureStore()
        loadStoredCredentials()
    }

    init(storage: UserDefaults, secureStore: SecureStoring) {
        self.storage = storage
        self.secureStore = secureStore
        loadStoredCredentials()
    }

    private func loadStoredCredentials() {
        // Prefer Keychain (shared across processes), but migrate from UserDefaults.
        token = secureStore.getString(StorageKeys.token) ?? storage.string(forKey: StorageKeys.token)
        currentUserId = secureStore.getString(StorageKeys.userId) ?? storage.string(forKey: StorageKeys.userId)
        if let adminString = secureStore.getString(StorageKeys.isAdmin) {
            isAdmin = (adminString == "1")
        } else {
            isAdmin = storage.object(forKey: StorageKeys.isAdmin) as? Bool ?? false
        }

        if let token { secureStore.setString(token, forKey: StorageKeys.token) }
        if let currentUserId { secureStore.setString(currentUserId, forKey: StorageKeys.userId) }
        secureStore.setString(isAdmin ? "1" : "0", forKey: StorageKeys.isAdmin)

        isAuthenticated = token != nil
    }

    func storeCredentials(token: String, userId: String) {
        self.token = token
        currentUserId = userId
        isAuthenticated = true
        let decodedAdmin = decodeIsAdmin(from: token) ?? false
        isAdmin = decodedAdmin

        storage.set(token, forKey: StorageKeys.token)
        storage.set(userId, forKey: StorageKeys.userId)
        storage.set(decodedAdmin, forKey: StorageKeys.isAdmin)
        secureStore.setString(token, forKey: StorageKeys.token)
        secureStore.setString(userId, forKey: StorageKeys.userId)
        secureStore.setString(decodedAdmin ? "1" : "0", forKey: StorageKeys.isAdmin)
        NotificationCenter.default.post(name: .authStateDidChange, object: self)
    }

    func updateAdminStatus(_ isAdmin: Bool) {
        guard self.isAdmin != isAdmin else { return }
        self.isAdmin = isAdmin
        storage.set(isAdmin, forKey: StorageKeys.isAdmin)
        secureStore.setString(isAdmin ? "1" : "0", forKey: StorageKeys.isAdmin)
    }

    func refreshAdminStatusFromToken() {
        guard let token, let decoded = decodeIsAdmin(from: token) else { return }
        updateAdminStatus(decoded)
    }

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false
        isAdmin = false

        storage.removeObject(forKey: StorageKeys.token)
        storage.removeObject(forKey: StorageKeys.userId)
        storage.removeObject(forKey: StorageKeys.isAdmin)
        secureStore.removeValue(forKey: StorageKeys.token)
        secureStore.removeValue(forKey: StorageKeys.userId)
        secureStore.removeValue(forKey: StorageKeys.isAdmin)
        NotificationCenter.default.post(name: .authStateDidChange, object: self)
    }

    private struct JWTClaims: Decodable {
        let isAdmin: Bool?
        let is_admin: Bool?
        let admin: Bool?
    }

    private func decodeIsAdmin(from token: String) -> Bool? {
        guard let payloadData = decodePayloadData(from: token),
              let claims = try? JSONDecoder().decode(JWTClaims.self, from: payloadData) else {
            return nil
        }
        return claims.isAdmin ?? claims.is_admin ?? claims.admin
    }

    private func decodePayloadData(from token: String) -> Data? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: payload)
    }
}
