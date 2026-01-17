//
//  AuthManager.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class AuthManager: AuthManaging {
    private(set) var isAuthenticated: Bool = false
    private(set) var currentUserId: String?
    private(set) var token: String?
    private(set) var isAdmin: Bool = false

    private let storage: UserDefaults

    private enum StorageKeys {
        static let token = "auth.token"
        static let userId = "auth.userId"
        static let isAdmin = "auth.isAdmin"
    }

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        loadStoredCredentials()
    }

    private func loadStoredCredentials() {
        token = storage.string(forKey: StorageKeys.token)
        currentUserId = storage.string(forKey: StorageKeys.userId)
        isAdmin = storage.object(forKey: StorageKeys.isAdmin) as? Bool ?? false
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
    }

    func updateAdminStatus(_ isAdmin: Bool) {
        guard self.isAdmin != isAdmin else { return }
        self.isAdmin = isAdmin
        storage.set(isAdmin, forKey: StorageKeys.isAdmin)
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
