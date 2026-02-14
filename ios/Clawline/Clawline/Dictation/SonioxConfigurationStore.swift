//
//  SonioxConfigurationStore.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import Foundation

enum SonioxKeyVerificationStatus: String, Sendable {
    case missing
    case unverified
    case validating
    case invalid
    case validated

    var inlineStatusText: String? {
        switch self {
        case .invalid:
            return "Invalid"
        case .validated:
            return "Validated"
        case .missing, .unverified, .validating:
            return nil
        }
    }
}

enum SonioxConfigurationStore {
    private static let apiKeyDefaultsKey = "soniox.apiKey"
    private static let apiKeyEnvironmentKey = "CLAWLINE_SONIOX_API_KEY"
    private static let keyStatusDefaultsKey = "soniox.apiKeyStatus"
    static let keyManagementURL = URL(string: "https://soniox.com/console")!

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

    static var editableAPIKey: String {
        UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? ""
    }

    static var keyStatus: SonioxKeyVerificationStatus {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return .missing }
        guard let raw = UserDefaults.standard.string(forKey: keyStatusDefaultsKey),
              let status = SonioxKeyVerificationStatus(rawValue: raw) else {
            return .unverified
        }
        if status == .missing {
            return .unverified
        }
        return status
    }

    static var ctaTitle: String {
        editableAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Get Key" : "Verify"
    }

    static func setKeyStatus(_ status: SonioxKeyVerificationStatus) {
        UserDefaults.standard.set(status.rawValue, forKey: keyStatusDefaultsKey)
    }

    static func setAPIKey(_ value: String?) {
        let previous = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
            UserDefaults.standard.set(SonioxKeyVerificationStatus.missing.rawValue, forKey: keyStatusDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: apiKeyDefaultsKey)
            if trimmed != previous {
                UserDefaults.standard.set(SonioxKeyVerificationStatus.unverified.rawValue, forKey: keyStatusDefaultsKey)
            } else if UserDefaults.standard.string(forKey: keyStatusDefaultsKey) == nil {
                UserDefaults.standard.set(SonioxKeyVerificationStatus.unverified.rawValue, forKey: keyStatusDefaultsKey)
            }
        }
    }
}
