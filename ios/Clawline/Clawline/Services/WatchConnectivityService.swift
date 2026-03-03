//
//  WatchConnectivityService.swift
//  Clawline
//

#if os(iOS)
import Foundation
import WatchConnectivity
import UIKit
import OSLog
import Observation

@Observable
final class WatchConnectivityService: NSObject, WatchConnectivityServicing {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "WatchConnectivity")

    private(set) var isWatchPaired: Bool = false
    private(set) var isWatchReachable: Bool = false

    private var relayActive: Bool = false
    private var incomingMessageTask: Task<Void, Never>?
    private var serviceEventsTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Injected — same instances the iOS app uses
    private let authManager: any AuthManaging
    private let sonioxKeyStore: SonioxKeyStore
    private let cartesiaKeyStore: CartesiaKeyStore
    private let chatService: any ChatServicing

    init(
        authManager: some AuthManaging,
        sonioxKeyStore: SonioxKeyStore,
        cartesiaKeyStore: CartesiaKeyStore,
        chatService: some ChatServicing
    ) {
        self.authManager = authManager
        self.sonioxKeyStore = sonioxKeyStore
        self.cartesiaKeyStore = cartesiaKeyStore
        self.chatService = chatService
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Activation

    func activate() {
        guard WCSession.isSupported() else { return }
        guard WCSession.default.activationState == .notActivated else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        // Register credential change observers
        let names: [Notification.Name] = [
            .authStateDidChange,
            .sonioxApiKeyDidChange,
            .cartesiaApiKeyDidChange,
            .cartesiaVoiceIdDidChange,
            .providerBaseURLDidChange
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleCredentialChange),
                name: name,
                object: nil
            )
        }
    }

    // MARK: - Credential Sync

    func syncCredentials() {
        guard WCSession.default.isPaired else { return }
        guard let token = authManager.token,
              let userId = authManager.currentUserId,
              let providerURL = ProviderBaseURLStore.baseURL?.absoluteString
        else { return }

        var userInfo: [String: Any] = [
            "type": "credential_push",
            "token": token,
            "userId": userId,
            "providerBaseURL": providerURL,
            "pushedAt": Date().timeIntervalSince1970 * 1000
        ]
        if let key = sonioxKeyStore.apiKey { userInfo["sonioxApiKey"] = key }
        if let key = cartesiaKeyStore.apiKey { userInfo["cartesiaApiKey"] = key }
        if let id = cartesiaKeyStore.selectedVoiceId { userInfo["cartesiaVoiceId"] = id }

        // Update application context so Watch can recover credentials on activation
        // even if transferUserInfo queue was never delivered (fresh install, reinstall, etc.)
        try? WCSession.default.updateApplicationContext(userInfo)
        WCSession.default.transferUserInfo(userInfo)
    }

    @objc private func handleCredentialChange() {
        syncCredentials()
    }

    // MARK: - Relay Management

    private func activateRelay() {
        relayActive = true
        startBackgroundTask()

        // Restart observation tasks (idempotent per C7)
        incomingMessageTask?.cancel()
        incomingMessageTask = Task { [weak self] in
            guard let self else { return }
            for await message in chatService.incomingMessages {
                guard relayActive, WCSession.default.isReachable else { continue }
                pushIncomingMessage(message)
            }
        }

        serviceEventsTask?.cancel()
        serviceEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in chatService.serviceEvents {
                guard relayActive, WCSession.default.isReachable else { continue }
                pushEvent(event)
            }
        }
    }

    private func deactivateRelay() {
        relayActive = false  // Set synchronously before any async cleanup (C8)
        incomingMessageTask?.cancel()
        incomingMessageTask = nil
        serviceEventsTask?.cancel()
        serviceEventsTask = nil
        endBackgroundTask()
    }

    // MARK: - Push to Watch

    private func pushIncomingMessage(_ message: Message) {
        guard let json = serializeMessage(message) else { return }
        let msg: [String: Any] = [
            "type": "chat.incoming",
            "requestId": "push_\(UUID().uuidString)",
            "payload": ["json": json]
        ]
        WCSession.default.sendMessage(msg, replyHandler: nil) { [weak self] error in
            // Log but do not retry — Watch transport handles lost messages (C12)
            self?.logger.warning("chat.incoming push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pushEvent(_ event: ChatServiceEvent) {
        guard let json = serializeEvent(event) else { return }
        let msg: [String: Any] = [
            "type": "event",
            "requestId": "push_\(UUID().uuidString)",
            "payload": ["json": json]
        ]
        WCSession.default.sendMessage(msg, replyHandler: nil) { [weak self] error in
            self?.logger.warning("event push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Background Task

    private func startBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClawlineWatchRelay") {
            // Expiration handler (~30s after app enters background)
            self.relayActive = false
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Message Dispatch

    private func handleMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let type = message["type"] as? String else {
            replyHandler(["error": ["code": "malformed", "message": "Missing type field"]])
            return
        }
        let requestId = message["requestId"] as? String ?? ""
        let payload = message["payload"] as? [String: Any] ?? [:]

        switch type {
        case "relay.activated":
            // Received via didReceiveMessage:replyHandler: — treat as idempotent activate
            activateRelay()
            replyHandler(["type": "relay.activate.ack", "requestId": requestId, "payload": [:]])

        case "relay.deactivated":
            deactivateRelay()
            replyHandler(["type": "relay.deactivate.ack", "requestId": requestId, "payload": [:]])

        case "chat.send":
            handleChatSend(requestId: requestId, payload: payload, replyHandler: replyHandler)

        case "chat.callback":
            handleChatCallback(requestId: requestId, payload: payload, replyHandler: replyHandler)

        case "streams.fetch":
            handleStreamsFetch(requestId: requestId, replyHandler: replyHandler)

        case "streams.create":
            handleStreamsCreate(requestId: requestId, payload: payload, replyHandler: replyHandler)

        case "streams.rename":
            handleStreamsRename(requestId: requestId, payload: payload, replyHandler: replyHandler)

        case "streams.delete":
            handleStreamsDelete(requestId: requestId, payload: payload, replyHandler: replyHandler)

        case "auth.refresh":
            handleAuthRefresh(requestId: requestId, replyHandler: replyHandler)

        default:
            replyHandler(["error": ["code": "unsupported", "message": "Unknown message type: \(type)"]])
        }
    }

    // MARK: - Relay Operation Handlers

    private func handleChatSend(requestId: String, payload: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let content = payload["content"] as? String ?? ""
        let sessionKey = payload["sessionKey"] as? String
        let clientId = payload["id"] as? String ?? UUID().uuidString
        let attachments = decodeAttachments(payload["attachments"])

        Task {
            do {
                try await chatService.send(
                    id: clientId,
                    content: content,
                    attachments: attachments,
                    sessionKey: sessionKey
                )
                replyHandler([
                    "type": "chat.send.ack",
                    "requestId": requestId,
                    "payload": ["acked": true]
                ])
            } catch {
                replyError(for: error, fallbackCode: "send_failed", replyHandler: replyHandler)
            }
        }
    }

    private func handleChatCallback(requestId: String, payload: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let sourceMessageId = payload["sourceMessageId"] as? String,
              let action = payload["action"] as? String else {
            replyHandler(["error": ["code": "malformed", "message": "Missing callback payload fields"]])
            return
        }

        let dataValue = payload["data"].flatMap { JSONValue.from(any: $0) }

        Task {
            do {
                try await chatService.sendInteractiveCallback(
                    sourceMessageId: sourceMessageId,
                    action: action,
                    data: dataValue
                )
                replyHandler([
                    "type": "chat.callback.ack",
                    "requestId": requestId,
                    "payload": ["acked": true]
                ])
            } catch {
                replyError(for: error, fallbackCode: "callback_failed", replyHandler: replyHandler)
            }
        }
    }

    private func handleStreamsFetch(requestId: String, replyHandler: @escaping ([String: Any]) -> Void) {
        Task {
            do {
                let streams = try await chatService.fetchStreams()
                let streamsAny = encodeToAny(streams) ?? []
                replyHandler([
                    "type": "streams.fetch.ack",
                    "requestId": requestId,
                    "payload": ["streams": streamsAny]
                ])
            } catch {
                replyError(for: error, fallbackCode: "fetch_failed", replyHandler: replyHandler)
            }
        }
    }

    private func handleStreamsCreate(requestId: String, payload: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let displayName = payload["displayName"] as? String ?? "New Stream"
        let idempotencyKey = payload["idempotencyKey"] as? String ?? UUID().uuidString

        Task {
            do {
                let stream = try await chatService.createStream(displayName: displayName, idempotencyKey: idempotencyKey)
                let streamAny = encodeToAny(stream) ?? [:]
                replyHandler([
                    "type": "streams.create.ack",
                    "requestId": requestId,
                    "payload": ["stream": streamAny]
                ])
            } catch {
                replyError(for: error, fallbackCode: "create_failed", replyHandler: replyHandler)
            }
        }
    }

    private func handleStreamsRename(requestId: String, payload: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let sessionKey = payload["sessionKey"] as? String ?? ""
        let displayName = payload["displayName"] as? String ?? ""

        Task {
            do {
                let stream = try await chatService.renameStream(sessionKey: sessionKey, displayName: displayName)
                let streamAny = encodeToAny(stream) ?? [:]
                replyHandler([
                    "type": "streams.rename.ack",
                    "requestId": requestId,
                    "payload": ["stream": streamAny]
                ])
            } catch {
                replyError(for: error, fallbackCode: "rename_failed", replyHandler: replyHandler)
            }
        }
    }

    private func handleStreamsDelete(requestId: String, payload: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let sessionKey = payload["sessionKey"] as? String ?? ""

        Task {
            do {
                let deletedKey = try await chatService.deleteStream(sessionKey: sessionKey, idempotencyKey: nil)
                replyHandler([
                    "type": "streams.delete.ack",
                    "requestId": requestId,
                    "payload": ["deletedKey": deletedKey]
                ])
            } catch {
                replyError(for: error, fallbackCode: "delete_failed", replyHandler: replyHandler)
            }
        }
    }

    private func handleAuthRefresh(requestId: String, replyHandler: @escaping ([String: Any]) -> Void) {
        // Re-push current credentials for Watch's queued transfer (C13)
        syncCredentials()

        guard let token = authManager.token, let userId = authManager.currentUserId else {
            replyHandler(["error": ["code": "not_authenticated", "message": "Not authenticated on iPhone"]])
            return
        }

        var payload: [String: Any] = [
            "token": token,
            "userId": userId
        ]
        if let providerBaseURL = ProviderBaseURLStore.baseURL?.absoluteString {
            payload["providerBaseURL"] = providerBaseURL
        }
        if let sonioxApiKey = sonioxKeyStore.apiKey {
            payload["sonioxApiKey"] = sonioxApiKey
        }
        if let cartesiaApiKey = cartesiaKeyStore.apiKey {
            payload["cartesiaApiKey"] = cartesiaApiKey
        }
        if let cartesiaVoiceId = cartesiaKeyStore.selectedVoiceId {
            payload["cartesiaVoiceId"] = cartesiaVoiceId
        }

        replyHandler([
            "type": "auth.refresh.ack",
            "requestId": requestId,
            "payload": payload
        ])
    }

    // MARK: - Serialization Helpers

    /// Wraps Message in a wire-compatible shape that ServerMessagePayload can decode.
    private struct WireMessage: Encodable {
        let type = "message"
        let id: String
        let role: Message.Role
        let sender: String?
        let content: String
        let timestamp: Date
        let streaming: Bool
        let deviceId: String?
        let sessionKey: String
        let attachments: [Attachment]
    }

    private func serializeMessage(_ message: Message) -> String? {
        let wire = WireMessage(
            id: message.id,
            role: message.role,
            sender: message.sender,
            content: message.content,
            timestamp: message.timestamp,
            streaming: message.streaming,
            deviceId: message.deviceId,
            sessionKey: message.sessionKey,
            attachments: message.attachments
        )
        guard let data = try? JSONEncoder().encode(wire) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Serializes a ChatServiceEvent to a JSON string matching RelayEventEnvelope's Codable format.
    private func serializeEvent(_ event: ChatServiceEvent) -> String? {
        var dict: [String: Any] = [:]
        switch event {
        case .messageError(let messageId, let code, let message):
            dict["kind"] = "messageError"
            if let messageId { dict["messageId"] = messageId }
            dict["code"] = code
            if let message { dict["message"] = message }
        case .messageAcked(let id):
            dict["kind"] = "messageAcked"
            dict["id"] = id
        case .connectionInterrupted(let reason):
            dict["kind"] = "connectionInterrupted"
            if let reason { dict["reason"] = reason }
        case .userInfo(let info):
            dict["kind"] = "userInfo"
            dict["userInfo"] = ["userId": info.userId, "isAdmin": info.isAdmin]
        case .typingStateChanged(let isTyping, let sessionKey):
            dict["kind"] = "typingStateChanged"
            dict["isTyping"] = isTyping
            dict["sessionKey"] = sessionKey
        case .streamSnapshot(let streams):
            dict["kind"] = "streamSnapshot"
            if let any = encodeToAny(streams) { dict["streams"] = any }
        case .streamCreated(let stream):
            dict["kind"] = "streamCreated"
            if let any = encodeToAny(stream) { dict["stream"] = any }
        case .streamUpdated(let stream):
            dict["kind"] = "streamUpdated"
            if let any = encodeToAny(stream) { dict["stream"] = any }
        case .streamDeleted(let sessionKey):
            dict["kind"] = "streamDeleted"
            dict["sessionKey"] = sessionKey
        case .sessionProvisioningAvailable(let available):
            dict["kind"] = "sessionProvisioningAvailable"
            dict["available"] = available
        case .sessionInfo(let info):
            dict["kind"] = "sessionInfo"
            var infoDict: [String: Any] = ["sessionKeys": info.sessionKeys]
            if let userId = info.userId { infoDict["userId"] = userId }
            if let isAdmin = info.isAdmin { infoDict["isAdmin"] = isAdmin }
            if let dmScope = info.dmScope { infoDict["dmScope"] = dmScope }
            dict["sessionInfo"] = infoDict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeToAny<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func decodeAttachments(_ rawAttachments: Any?) -> [WireAttachment] {
        guard let rawAttachments,
              JSONSerialization.isValidJSONObject(rawAttachments),
              let data = try? JSONSerialization.data(withJSONObject: rawAttachments),
              let attachments = try? JSONDecoder().decode([WireAttachment].self, from: data) else {
            return []
        }
        return attachments
    }

    private func replyError(for error: Error, fallbackCode: String, replyHandler: @escaping ([String: Any]) -> Void) {
        let code: String
        if let providerError = error as? ProviderChatService.Error {
            switch providerError {
            case .notConnected, .missingBaseURL:
                code = "not_connected"
            case .authFailed, .authTimeout, .tokenRevoked:
                code = "auth_failed"
            default:
                code = fallbackCode
            }
        } else if let chatError = error as? ChatError {
            switch chatError {
            case .notConnected:
                code = "not_connected"
            }
        } else {
            code = fallbackCode
        }

        replyHandler(["error": ["code": code, "message": error.localizedDescription]])
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityService: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isWatchPaired = session.isPaired
            isWatchReachable = session.isReachable
            if activationState == .activated, session.isPaired {
                syncCredentials()
            }
            if let error {
                logger.error("WCSession activation error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // Intermediate state during Watch handoff — no action required
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so the new Watch can take over
        Task { @MainActor in
            WCSession.default.activate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasReachable = isWatchReachable
            isWatchReachable = session.isReachable
            if session.isReachable, !wasReachable {
                syncCredentials()
            }
        }
    }

    /// Fire-and-forget messages from Watch (relay.activated, relay.deactivated).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            guard let self, let type = message["type"] as? String else { return }
            switch type {
            case "relay.activated":
                activateRelay()
            case "relay.deactivated":
                deactivateRelay()
            default:
                logger.warning("Unhandled fire-and-forget type: \(type, privacy: .public)")
            }
        }
    }

    /// Request-reply messages from Watch (chat.send, streams.*, auth.refresh).
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler(["error": ["code": "unavailable", "message": "Service unavailable"]])
                return
            }
            handleMessage(message, replyHandler: replyHandler)
        }
    }

    /// Delivered credential pushes (from iOS to Watch, delivered in background).
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?) {
        if let error {
            Task { @MainActor [weak self] in
                self?.logger.warning("transferUserInfo failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
