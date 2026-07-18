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
    case agentProgress(AgentProgressEvent)
    case promptTurnState(PromptTurnStateEvent)
    case connectionInterrupted(reason: String?)
    case userInfo(ChatUserInfo)
    case typingStateChanged(isTyping: Bool, sessionKey: String)
    case streamSnapshot([StreamSession])
    case streamCreated(StreamSession)
    case streamUpdated(StreamSession)
    case streamDeleted(sessionKey: String)
    /// Gateway set a session's history barrier (e.g. after a harness swap) and
    /// pushed this to every owner device. On receipt, drop the local message
    /// store/UI and persisted cache for the stream; replay after the barrier
    /// reconverges all devices (spec §T-A).
    case streamHistoryCleared(sessionKey: String)
    case streamReadStateSnapshot([String: String])
    case streamReadStateUpdated(sessionKey: String, lastReadMessageId: String)
    case streamTailStateSnapshot([String: StreamTailState])
    case streamTailStateUpdated(sessionKey: String, tailState: StreamTailState)
    case sessionProvisioningAvailable(Bool)
    /// Feature flags advertised by the server in `auth_result.features`
    /// (e.g. "tightbeam"). Tightbeam-only affordances gate on this set.
    case serverFeatures([String])
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
    func seedReplayCursorIfMissing(_ cursor: String?, for sessionKey: String)
    func clearReplayCursors()
    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?,
        references: [MessageReferenceContext]
    ) async throws

    func sendInteractiveCallback(
        sourceMessageId: String,
        action: String,
        data: JSONValue?
    ) async throws
    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws

    func fetchStreams() async throws -> [StreamSession]
    func fetchTrackableSessions() async throws -> [TrackableSession]
    func fetchOrgOptions() async throws -> OrgOptions
    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus
    func applySessionControl(
        sessionKey: String,
        action: SessionControlAction,
        value: String?,
        enabled: Bool?
    ) async throws -> SessionControlResponse
    func adoptStream(sessionKey: String) async throws -> StreamSession
    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession
    /// T-B placement-aware create: optional harness/model/host/archetype ride
    /// alongside the name-only create. Conformers that do not provision placement
    /// (previews/stubs) inherit the default below, which drops the placement
    /// params and falls back to the name-only create.
    func createStream(
        displayName: String,
        idempotencyKey: String,
        harness: String?,
        model: String?,
        host: String?,
        archetype: String?
    ) async throws -> StreamSession
    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession
    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String
}

extension ChatServicing {
    func createStream(
        displayName: String,
        idempotencyKey: String,
        harness: String?,
        model: String?,
        host: String?,
        archetype: String?
    ) async throws -> StreamSession {
        try await createStream(displayName: displayName, idempotencyKey: idempotencyKey)
    }
}
