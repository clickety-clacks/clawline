//
//  ProviderBaseURLStore.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

enum ProviderBaseURLStore {
    private static let key = "provider.baseURL"

    static var baseURL: URL? {
        guard let value = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        return URL(string: value)
    }

    static func setBaseURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: key)
        NotificationCenter.default.post(name: .providerBaseURLDidChange, object: nil)
    }
}

struct ProviderTLSPolicy: Equatable {
    let trustSelfSignedCertificates: Bool
    let pinnedLeafCertificateSHA256: String?
}

extension Notification.Name {
    static let providerTLSPolicyDidChange = Notification.Name("co.clicketyclacks.Clawline.providerTLSPolicyDidChange")
}

enum ProviderTLSSettingsStore {
    private static let trustSelfSignedKey = "provider.tls.trustSelfSignedCertificates"
    private static let pinnedFingerprintKey = "provider.tls.pinnedLeafCertificateSHA256"
    private static var policyGenerationStorage: UInt64 = 0

    static var policyGeneration: UInt64 {
        policyGenerationStorage
    }

    static var trustSelfSignedCertificates: Bool {
        get {
            if UserDefaults.standard.object(forKey: trustSelfSignedKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: trustSelfSignedKey)
        }
        set {
            let oldPolicy = policy
            UserDefaults.standard.set(newValue, forKey: trustSelfSignedKey)
            publishPolicyChangeIfNeeded(from: oldPolicy)
        }
    }

    static var pinnedLeafCertificateSHA256: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: pinnedFingerprintKey)
            return normalizeFingerprint(raw)
        }
        set {
            let oldPolicy = policy
            let normalized = normalizeFingerprint(newValue)
            if let normalized {
                UserDefaults.standard.set(normalized, forKey: pinnedFingerprintKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pinnedFingerprintKey)
            }
            publishPolicyChangeIfNeeded(from: oldPolicy)
        }
    }

    static var policy: ProviderTLSPolicy {
        ProviderTLSPolicy(
            trustSelfSignedCertificates: trustSelfSignedCertificates,
            pinnedLeafCertificateSHA256: pinnedLeafCertificateSHA256
        )
    }

    private static func normalizeFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isHexDigit }
        guard normalized.count == 64 else { return nil }
        return normalized
    }

    private static func publishPolicyChangeIfNeeded(from oldPolicy: ProviderTLSPolicy) {
        let newPolicy = policy
        guard newPolicy != oldPolicy else { return }
        policyGenerationStorage &+= 1
        NotificationCenter.default.post(
            name: .providerTLSPolicyDidChange,
            object: nil,
            userInfo: ["generation": policyGenerationStorage]
        )
    }
}

enum ProviderWebSocketURLBuilder {
    static func candidateURLs(from baseURL: URL, defaultPath: String) -> [URL] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return []
        }

        let path = components.path
        if path.isEmpty || path == "/" {
            components.path = defaultPath
        } else if !path.hasSuffix(defaultPath) {
            if path.hasSuffix("/") {
                components.path = path + String(defaultPath.dropFirst())
            } else {
                components.path = path + defaultPath
            }
        }

        let schemes = ["wss", "ws"]
        var urls: [URL] = []
        var seen = Set<String>()
        for scheme in schemes {
            components.scheme = scheme
            guard let url = components.url else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }
}
