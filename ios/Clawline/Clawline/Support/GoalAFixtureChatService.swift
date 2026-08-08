//
//  GoalAFixtureChatService.swift
//  Clawline
//
//  Cycle-3 Goal A, DEBUG-only sim verification hook (orchestrator direction,
//  2026-08-07): no live gateway is reachable on eezo, so this drives the
//  REAL app (not a Swift Testing fixture, not an Xcode-canvas preview) with
//  message data shaped exactly like the real wire (same Message/
//  MessageProvenance shapes MessageKindClassifierTests validates against),
//  so the actual MessageFlowCollectionView renders substrate/marker rows
//  end-to-end and can be screenshotted as verification evidence. Gated
//  behind #if DEBUG and a launch argument; never reachable in a Release
//  build or without explicitly opting in.
//

#if DEBUG
import Foundation

final class GoalAFixtureChatService: ChatServicing {
    static let sessionKey = "agent:main:clawline:mike:main s_goalA_fixture"

    private let messagesContinuation: AsyncStream<Message>.Continuation
    let incomingMessages: AsyncStream<Message>
    private let serviceEventsContinuation: AsyncStream<ChatServiceEvent>.Continuation
    let serviceEvents: AsyncStream<ChatServiceEvent>

    var serverFeatures: [String] { [] }
    var connectionState: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }
    var lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent> {
        AsyncStream { _ in }
    }
    var isTransportReadyForSend: Bool { true }

    init() {
        var messagesContinuation: AsyncStream<Message>.Continuation!
        incomingMessages = AsyncStream { messagesContinuation = $0 }
        self.messagesContinuation = messagesContinuation

        var serviceEventsContinuation: AsyncStream<ChatServiceEvent>.Continuation!
        serviceEvents = AsyncStream { serviceEventsContinuation = $0 }
        self.serviceEventsContinuation = serviceEventsContinuation

        Task { [weak self] in
            await self?.emitFixtureTranscript()
        }
    }

    func connect(token: String, lastMessageId: String?) async throws {}
    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {}
    func stopConnectionAttempt() {}
    func disconnect() {}
    func replayCursorSnapshot() -> [String: String] { [:] }
    func setReplayCursor(_ cursor: String?, for sessionKey: String) {}
    func seedReplayCursorIfMissing(_ cursor: String?, for sessionKey: String) {}
    func clearReplayCursors() {}
    func send(id: String,
              content: String,
              attachments: [WireAttachment],
              sessionKey: String?,
              references: [MessageReferenceContext]) async throws {}
    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {}
    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {}
    func fetchStreams() async throws -> [StreamSession] {
        [
            StreamSession(
                sessionKey: Self.sessionKey,
                displayName: "Goal A fixture verification",
                kind: "personal",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]
    }
    func fetchTrackableSessions() async throws -> [TrackableSession] { [] }
    func fetchOrgOptions() async throws -> OrgOptions { OrgOptions.empty }
    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus {
        throw ProviderChatService.Error.notConnected
    }
    func applySessionControl(
        sessionKey: String,
        action: SessionControlAction,
        value: String?,
        enabled: Bool?
    ) async throws -> SessionControlResponse {
        throw ProviderChatService.Error.notConnected
    }
    func adoptStream(sessionKey: String) async throws -> StreamSession {
        throw ProviderChatService.Error.notConnected
    }
    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        throw ProviderChatService.Error.notConnected
    }
    func createStream(
        displayName: String,
        idempotencyKey: String,
        harness: String?,
        model: String?,
        host: String?,
        archetype: String?
    ) async throws -> StreamSession {
        throw ProviderChatService.Error.notConnected
    }
    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        throw ProviderChatService.Error.notConnected
    }
    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String {
        throw ProviderChatService.Error.notConnected
    }

    /// Real wire shapes throughout (role=.user, sender prefix, exact
    /// `[from <sender>]` first-line stamp -- the same convention
    /// MessageKindClassifierTests / MessageProvenanceTests validate),
    /// timed with real delays so the collection view's normal
    /// insert/animate path runs, not a single frozen batch. Two
    /// consecutive substrate rows early (run-collapse), a .sessionInfo
    /// firing partway through (marker-divider anchor), then one more
    /// substrate row after it -- covering ghost rows, run-collapse, AND
    /// the marker boundary in one real transcript.
    private func emitFixtureTranscript() async {
        func send(_ message: Message) {
            messagesContinuation.yield(message)
        }
        func wait(_ nanoseconds: UInt64 = 250_000_000) async -> Bool {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                return true
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
        }

        send(fixtureMessage(
            role: .user, sender: nil,
            content: "Ship the substrate ghost rows when you get a chance."
        ))
        guard await wait() else { return }
        send(fixtureMessage(
            role: .assistant, sender: nil,
            content: "On it -- starting with the classifier seam, then the rendering."
        ))
        guard await wait() else { return }
        send(fixtureMessage(
            role: .user, sender: "process:tightbeam",
            content: "check-in: the design assignment has an open obligation and no filing this turn -- file progress, or schedule a wake."
        ))
        guard await wait() else { return }
        send(fixtureMessage(
            role: .user, sender: "process:tightbeam",
            content: "effort nudge: this looks mechanical -- consider a lower effort bracket."
        ))
        guard await wait() else { return }

        serviceEventsContinuation.yield(.sessionInfo(SessionInfo(
            userId: "mike",
            isAdmin: true,
            dmScope: nil,
            sessionKeys: [Self.sessionKey]
        )))
        guard await wait() else { return }

        send(fixtureMessage(
            role: .user, sender: "process:tightbeam",
            content: "escalation: helper session missed two check-ins; waking its supervisor."
        ))
        guard await wait() else { return }
        send(fixtureMessage(
            role: .assistant, sender: nil,
            content: "Substrate rendering is done and verified -- 18/18 tests passing, real build and sim boot confirmed."
        ))
    }

    private func fixtureMessage(role: Message.Role, sender: String?, content: String) -> Message {
        let stampedContent = sender.map { "[from \($0)]\n\(content)" } ?? content
        return Message(
            id: "m_fixture_\(UUID().uuidString.prefix(8))",
            role: role,
            content: stampedContent,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: sender == nil && role == .user ? "device-fixture" : nil,
            sessionKey: Self.sessionKey,
            sender: sender
        )
    }
}
#endif
