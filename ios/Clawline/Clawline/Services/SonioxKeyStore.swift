//
//  SonioxKeyStore.swift
//  Clawline
//

import Foundation
import Observation

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

protocol SonioxKeyVerifying: AnyObject {
    func verify(apiKey: String) async -> Bool
}

final class SonioxKeyVerifier: SonioxKeyVerifying {
    private static let endpointURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private let session: URLSession
    private let timeout: Duration

    init(session: URLSession = URLSession(configuration: .default), timeout: Duration = .seconds(5)) {
        self.session = session
        self.timeout = timeout
    }

    func verify(apiKey: String) async -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: Self.endpointURL)
        request.timeoutInterval = 20
        request.setValue("https://clawline.app", forHTTPHeaderField: "Origin")

        let task = session.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        do {
            let payload = SonioxKeyVerificationConfigPayload(apiKey: trimmed)
            let configData = try JSONEncoder().encode(payload)
            guard let configText = String(data: configData, encoding: .utf8) else {
                return false
            }
            try await task.send(.string(configText))
            try await task.send(.string(#"{"type":"finalize"}"#))
            try await task.send(.data(Data()))
        } catch {
            return false
        }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let message = await receiveMessage(task: task, timeout: .milliseconds(700)) else {
                continue
            }

            let text: String
            switch message {
            case .string(let value):
                text = value
            case .data(let data):
                guard let decoded = String(data: data, encoding: .utf8) else { continue }
                text = decoded
            @unknown default:
                continue
            }

            guard let response = try? JSONDecoder().decode(SonioxKeyVerificationResponseEnvelope.self, from: Data(text.utf8)) else {
                continue
            }

            if let errorCode = response.errorCode, !errorCode.isEmpty {
                return false
            }

            if let errorMessage = response.errorMessage, !errorMessage.isEmpty {
                return false
            }

            if response.finished == true || (response.tokens?.isEmpty == false) {
                return true
            }
        }

        return false
    }

    private func receiveMessage(
        task: URLSessionWebSocketTask,
        timeout: Duration
    ) async -> URLSessionWebSocketTask.Message? {
        await withTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask {
                try? await task.receive()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private struct SonioxKeyVerificationConfigPayload: Encodable {
    let apiKey: String
    let model: String = "stt-rt-preview"
    let audioFormat: String = "s16le"
    let sampleRate: Int = 16_000
    let numChannels: Int = 1
    let languageHints: [String] = ["en"]
    let enableEndpointDetection: Bool = true
    let clientReferenceID: String = UUID().uuidString

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case languageHints = "language_hints"
        case enableEndpointDetection = "enable_endpoint_detection"
        case clientReferenceID = "client_reference_id"
    }
}

private struct SonioxKeyVerificationResponseEnvelope: Decodable {
    struct Token: Decodable {
        let text: String
    }

    let tokens: [Token]?
    let finished: Bool?
    let errorCode: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

@Observable
@MainActor
final class SonioxKeyStore {
    var apiKey: String {
        didSet { handleKeyChanged(from: oldValue, to: apiKey) }
    }

    private(set) var keyStatus: SonioxKeyVerificationStatus {
        didSet { SonioxConfigurationStore.setKeyStatus(keyStatus) }
    }

    var editableKey: String {
        didSet { apiKey = editableKey }
    }

    private let verifier: any SonioxKeyVerifying

    init(verifier: (any SonioxKeyVerifying)? = nil) {
        self.verifier = verifier ?? SonioxKeyVerifier()
        self.apiKey = SonioxConfigurationStore.editableAPIKey
        self.editableKey = SonioxConfigurationStore.editableAPIKey
        self.keyStatus = SonioxConfigurationStore.keyStatus
    }

    var keyForCredentialSync: String? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasKey: Bool {
        keyForCredentialSync != nil
    }

    var ctaTitle: String {
        hasKey ? "Verify" : "Get Key"
    }

    func setKey(_ value: String) {
        editableKey = value
    }

    @discardableResult
    func verify() async -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyStatus = .missing
            SonioxConfigurationStore.setAPIKey(nil)
            NotificationCenter.default.post(name: .sonioxApiKeyDidChange, object: self)
            return false
        }
        keyStatus = .validating
        let isValid = await verifier.verify(apiKey: trimmed)
        keyStatus = isValid ? .validated : .invalid
        return isValid
    }

    private func handleKeyChanged(from oldValue: String, to newValue: String) {
        let oldTrimmed = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        SonioxConfigurationStore.setAPIKey(trimmed.isEmpty ? nil : trimmed)
        if trimmed.isEmpty {
            keyStatus = .missing
        } else if oldTrimmed != trimmed, keyStatus != .validating {
            keyStatus = .unverified
        }
        NotificationCenter.default.post(name: .sonioxApiKeyDidChange, object: self)
    }
}
