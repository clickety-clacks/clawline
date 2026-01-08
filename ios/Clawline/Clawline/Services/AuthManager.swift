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

    private let storage: UserDefaults

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        loadStoredCredentials()
    }

    private func loadStoredCredentials() {
        token = storage.string(forKey: "auth.token")
        currentUserId = storage.string(forKey: "auth.userId")
        isAuthenticated = token != nil
    }

    func storeCredentials(token: String, userId: String) {
        self.token = token
        currentUserId = userId
        isAuthenticated = true

        storage.set(token, forKey: "auth.token")
        storage.set(userId, forKey: "auth.userId")
    }

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false

        storage.removeObject(forKey: "auth.token")
        storage.removeObject(forKey: "auth.userId")
    }
}
