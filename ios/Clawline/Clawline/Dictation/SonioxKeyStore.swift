//
//  SonioxKeyStore.swift
//  Clawline
//
//  Created by Codex on 2/24/26.
//

import Foundation
import Observation

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

    init(verifier: any SonioxKeyVerifying = SonioxKeyVerifier()) {
        self.verifier = verifier
        self.apiKey = SonioxConfigurationStore.editableAPIKey
        self.editableKey = SonioxConfigurationStore.editableAPIKey
        self.keyStatus = SonioxConfigurationStore.keyStatus
    }

    var hasKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isReady: Bool {
        hasKey
    }

    var ctaTitle: String {
        hasKey ? "Verify" : "Get Key"
    }

    var statusText: String? {
        keyStatus.inlineStatusText
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
    }
}
