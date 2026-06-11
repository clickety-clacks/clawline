//
//  DictationAnalytics.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import CryptoKit
import Foundation
import OSLog

enum DictationMode: String, Sendable {
    case sticky
    case walkieTalkie = "walkie_talkie"
}

protocol DictationAnalyticsTracking {
    func trackStart(mode: DictationMode, sessionKey: String)
    func trackStop(reason: String, durationMs: Int)
    func trackError(errorCode: String?, stage: String)
    func trackSendWhileActive(mode: DictationMode?, sendSuccess: Bool)
    func trackSocketDrop(mode: DictationMode, elapsedMs: Int)
}

final class DictationAnalytics: DictationAnalyticsTracking {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "DictationAnalytics")
    private let secureStore: SecureStoring
    private let saltKey = "dictation.sessionHashSalt"

    init(secureStore: SecureStoring = KeychainSecureStore()) {
        self.secureStore = secureStore
    }

    func trackStart(mode: DictationMode, sessionKey: String) {
        let hashed = sessionKeyHash(sessionKey)
        logger.info("dictation_start mode=\(mode.rawValue, privacy: .public) sessionKeyHash=\(hashed, privacy: .public)")
    }

    func trackStop(reason: String, durationMs: Int) {
        logger.info("dictation_stop reason=\(reason, privacy: .public) durationMs=\(durationMs, privacy: .public)")
    }

    func trackError(errorCode: String?, stage: String) {
        logger.error("dictation_error stage=\(stage, privacy: .public) errorCode=\(errorCode ?? "unknown", privacy: .public)")
    }

    func trackSendWhileActive(mode: DictationMode?, sendSuccess: Bool) {
        logger.info(
            "dictation_send_while_active mode=\(mode?.rawValue ?? "unknown", privacy: .public) sendSuccess=\(sendSuccess, privacy: .public)"
        )
    }

    func trackSocketDrop(mode: DictationMode, elapsedMs: Int) {
        logger.info("dictation_socket_drop mode=\(mode.rawValue, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
    }

    private func sessionKeyHash(_ sessionKey: String) -> String {
        let salt = appSalt()
        let digest = SHA256.hash(data: Data((sessionKey + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appSalt() -> String {
        if let existing = secureStore.getString(saltKey), !existing.isEmpty {
            return existing
        }
        let newSalt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        secureStore.setString(newSalt, forKey: saltKey)
        return newSalt
    }
}
