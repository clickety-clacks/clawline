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

    static func clearBaseURL() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .providerBaseURLDidChange, object: nil)
    }

}

struct ProviderTLSPolicy: Equatable {
    let trustSelfSignedCertificates: Bool
    let pinnedLeafCertificateSHA256: String?
}

enum ProviderTLSSettingsStore {
    private static let trustSelfSignedKey = "provider.tls.trustSelfSignedCertificates"
    private static let pinnedFingerprintKey = "provider.tls.pinnedLeafCertificateSHA256"

    static var trustSelfSignedCertificates: Bool {
        get {
            if UserDefaults.standard.object(forKey: trustSelfSignedKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: trustSelfSignedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: trustSelfSignedKey)
        }
    }

    static var pinnedLeafCertificateSHA256: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: pinnedFingerprintKey)
            return normalizeFingerprint(raw)
        }
        set {
            let normalized = normalizeFingerprint(newValue)
            if let normalized {
                UserDefaults.standard.set(normalized, forKey: pinnedFingerprintKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pinnedFingerprintKey)
            }
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

enum ProviderHTTPURLResolver {
    static func uploadURL(fromAPIBase apiBase: URL) -> URL {
        apiBase.appendingPathComponent("upload")
    }

    static func downloadURL(fromAPIBase apiBase: URL, assetId: String) throws -> URL {
        guard !assetId.isEmpty else {
            throw AttachmentError.invalidData
        }
        guard var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else {
            throw AttachmentError.invalidData
        }
        guard let encodedAssetId = encodePathComponent(assetId) else {
            throw AttachmentError.invalidData
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = "\(basePath)/download/\(encodedAssetId)"
        guard let url = components.url else {
            throw AttachmentError.invalidData
        }
        return url
    }

    static func apiBaseURL(from baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              !isLocalHTTPHost(host) else {
            return baseURL
        }

        components.scheme = "https"
        if host.lowercased() == "100.85.66.60" {
            components.host = "tars.tail4105e8.ts.net"
        }
        if components.port == 18800 {
            components.port = 19443
        }
        return components.url ?? baseURL
    }

    /// Ordered transport candidates for provider HTTP APIs: the HTTPS-mapped
    /// front first when one applies, then the direct provider base URL.
    /// Installs must not require the HTTPS front; callers fall back to the
    /// next candidate on transport failure or a front gap response.
    static func apiBaseURLCandidates(from baseURL: URL) -> [URL] {
        let preferred = apiBaseURL(from: baseURL)
        guard preferred != baseURL else { return [baseURL] }
        return [preferred, baseURL]
    }

    /// A gap response comes from an HTTPS front that does not forward the
    /// requested route (or cannot reach the provider), as opposed to a real
    /// provider API error, which is always a JSON envelope
    /// (`{"error":{...}}` or `{"type":"error",...}`).
    static func isTransportGapResponse(statusCode: Int, data: Data) -> Bool {
        switch statusCode {
        case 502, 503, 504:
            return true
        case 404, 405:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return true
            }
            return object["error"] == nil && object["type"] == nil
        default:
            return false
        }
    }

    private static func isLocalHTTPHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost"
            || normalized == "0.0.0.0"
            || normalized == "::1"
            || normalized.hasSuffix(".local")
            || normalized.hasPrefix("127.")
    }

    private static func encodePathComponent(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
