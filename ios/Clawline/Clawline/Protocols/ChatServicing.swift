//
//  ChatServicing.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(Error)

    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.reconnecting, .reconnecting):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
}

enum ChatServiceEvent: Equatable {
    case messageError(messageId: String?, code: String, message: String?)
    case messageAcked(id: String)
    case connectionInterrupted(reason: String?)
    case userInfo(ChatUserInfo)
    case typingStateChanged(isTyping: Bool, sessionKey: String)
    case streamSnapshot([StreamSession])
    case streamCreated(StreamSession)
    case streamUpdated(StreamSession)
    case streamDeleted(sessionKey: String)
    case sessionProvisioningAvailable(Bool)
    /// Server-authoritative session provisioning manifest.
    /// Session keys are the only routing identifiers on the wire (Clawline invariants N3/N7).
    case sessionInfo(SessionInfo)
}

struct SessionInfo: Equatable {
    let userId: String?
    let isAdmin: Bool?
    let dmScope: String?
    let sessionKeys: [String]
}

protocol ChatServicing: AnyObject {
    var incomingMessages: AsyncStream<Message> { get }
    var connectionState: AsyncStream<ConnectionState> { get }
    var serviceEvents: AsyncStream<ChatServiceEvent> { get }
    var lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent> { get }
    var isTransportReadyForSend: Bool { get }

    func connect(token: String, lastMessageId: String?) async throws
    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String)
    func stopConnectionAttempt()
    func disconnect()
    func replayCursorSnapshot() -> [String: String]
    func setReplayCursor(_ cursor: String?, for sessionKey: String)
    func clearReplayCursors()
    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?
    ) async throws

    func sendInteractiveCallback(
        sourceMessageId: String,
        action: String,
        data: JSONValue?
    ) async throws

    func fetchStreams() async throws -> [StreamSession]
    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession
    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession
    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String
}
