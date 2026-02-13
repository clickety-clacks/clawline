//
//  SonioxConfigurationStore.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation

enum SonioxConfigurationStore {
    private static let apiKeyDefaultsKey = "soniox.apiKey"
    private static let apiKeyEnvironmentKey = "CLAWLINE_SONIOX_API_KEY"

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment[apiKeyEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }

        if let stored = UserDefaults.standard.string(forKey: apiKeyDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }

        return nil
    }

    static var isConfigured: Bool {
        apiKey != nil
    }

    static func setAPIKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: apiKeyDefaultsKey)
        }
    }
}
