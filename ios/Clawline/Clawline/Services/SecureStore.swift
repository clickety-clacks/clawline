//
//  SecureStore.swift
//  Clawline
//
//  Minimal Keychain wrapper + testable abstraction for storing small secrets
//  (deviceId, auth token, userId, admin bit).
//

import Foundation

protocol SecureStoring {
    func getString(_ key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func removeValue(forKey key: String)
}

final class InMemorySecureStore: SecureStoring {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    nonisolated deinit {}

    func getString(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func setString(_ value: String, forKey key: String) {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }

    func removeValue(forKey key: String) {
        lock.lock()
        storage.removeValue(forKey: key)
        lock.unlock()
    }
}
