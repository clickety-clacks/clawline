//
//  GoalAFixtureChatService.swift
//  Clawline
//
//  Cycle-3 Goal A, DEBUG-only sim verification hook (orchestrator direction,
//  2026-08-07): no live gateway is reachable on eezo, so this drives the
//  REAL app (not a Swift Testing fixture, not an Xcode-canvas preview) with
//  message data shaped exactly like the real wire (same Message/
//  MessageProvenance shapes MessageKindClassifierTests validates against),
//  so the actual MessageFlowCollectionView renders substrate/agent-compact
//  rows end-to-end and can be screenshotted as verification evidence. No
//  marker rows: the wire carries no marker signal today, so production
//  correctly renders none here either. Gated
//  behind #if DEBUG and a launch argument; never reachable in a Release
//  build or without explicitly opting in.
//

#if DEBUG
import Foundation

final class GoalAFixtureChatService: ChatServicing {
    static let sessionKey = "agent:main:clawline:mike:main s_goalA_fixture"

    // Required by ChatServicing but NOT how messages actually reach the UI:
    // ChatViewModel never subscribes to this stream (grep confirms zero call
    // sites). The real ingestion path is
    // ChatViewModel.handleLifecycleServerMessage(epoch:payload:), fed by
    // `.serverMessage(data:)` on lifecycleTransportEvents below and gated on
    // ConnectionLifecycleCoordinator.phase being .replaying/.live. A fixture
    // that yields Message values here (the previous version of this file)
    // silently loses every message -- this stream simply has no reader.
    private let messagesContinuation: AsyncStream<Message>.Continuation
    let incomingMessages: AsyncStream<Message>
    private let serviceEventsContinuation: AsyncStream<ChatServiceEvent>.Continuation
    let serviceEvents: AsyncStream<ChatServiceEvent>
    // STORED, not computed: a computed AsyncStream property builds a brand
    // new stream (and a fresh, one-shot continuation) on every access. A
    // consumer that reads this property more than once, or after the first
    // read's continuation has already gone out of scope, gets a stream that
    // never yields -- silently starving whatever gates message consumption
    // on connection state. Same stored-continuation-from-init pattern as
    // incomingMessages/serviceEvents above.
    private let connectionStateContinuation: AsyncStream<ConnectionState>.Continuation
    let connectionState: AsyncStream<ConnectionState>
    // Also STORED, same reason. Beyond that: ConnectionLifecycleCoordinator
    // does not read `connectionState` at all -- it drives its
    // connecting -> authenticating -> replaying -> live phase machine purely
    // from THIS stream (transportOpened / authResult / syncComplete), fed
    // from startConnectionAttempt(epoch:...) below. A stub that never yields
    // leaves the coordinator waiting on its 10s connectTimeout forever, and
    // ChatViewModel never starts materializing messages -- the actual cause
    // of the empty-transcript failure this hook exists to avoid.
    private let lifecycleTransportEventsContinuation: AsyncStream<LifecycleTransportEvent>.Continuation
    let lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent>
    /// The epoch ConnectionLifecycleCoordinator dispatched via
    /// startConnectionAttempt(epoch:...). Every `.serverMessage` this
    /// fixture emits must carry it -- handleServerMessage(epoch:data:) drops
    /// anything whose epoch does not match the coordinator's currentEpoch.
    private var connectedEpoch: Int?
    private var hasStartedTranscript = false

    var serverFeatures: [String] { ["tightbeam"] }
    var isTransportReadyForSend: Bool { true }

    init() {
        var messagesContinuation: AsyncStream<Message>.Continuation!
        incomingMessages = AsyncStream { messagesContinuation = $0 }
        self.messagesContinuation = messagesContinuation

        var serviceEventsContinuation: AsyncStream<ChatServiceEvent>.Continuation!
        serviceEvents = AsyncStream { serviceEventsContinuation = $0 }
        self.serviceEventsContinuation = serviceEventsContinuation

        var connectionStateContinuation: AsyncStream<ConnectionState>.Continuation!
        connectionState = AsyncStream { connectionStateContinuation = $0 }
        self.connectionStateContinuation = connectionStateContinuation
        self.connectionStateContinuation.yield(.connected)

        var lifecycleTransportEventsContinuation: AsyncStream<LifecycleTransportEvent>.Continuation!
        lifecycleTransportEvents = AsyncStream { lifecycleTransportEventsContinuation = $0 }
        self.lifecycleTransportEventsContinuation = lifecycleTransportEventsContinuation
    }

    func connect(token: String, lastMessageId: String?) async throws {}

    /// Plays the exact transport handshake ConnectionLifecycleCoordinator
    /// requires to leave `.connecting`: transportOpened -> authResult(0
    /// messages to replay, no history reset) -> syncComplete, all at the
    /// epoch the coordinator itself dispatched. Without this the coordinator
    /// times out at 10s and never reaches .replaying/.live, and every
    /// `.serverMessage` below is silently dropped regardless of content.
    /// Starts the fixture transcript only once this handshake has been
    /// dispatched (not from init()) -- sending messages before the
    /// coordinator has an epoch to accept them under would drop them the
    /// same way skipping the handshake does.
    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {
        connectedEpoch = epoch
        lifecycleTransportEventsContinuation.yield(
            LifecycleTransportEvent(epoch: epoch, payload: .transportOpened)
        )
        lifecycleTransportEventsContinuation.yield(
            LifecycleTransportEvent(
                epoch: epoch,
                payload: .authResult(
                    success: true,
                    replayCount: 0,
                    replayTruncated: false,
                    historyReset: false,
                    failureReason: nil
                )
            )
        )
        lifecycleTransportEventsContinuation.yield(
            LifecycleTransportEvent(epoch: epoch, payload: .syncComplete)
        )
        guard !hasStartedTranscript else { return }
        hasStartedTranscript = true
        Task { [weak self] in
            await self?.emitFixtureTranscript()
        }
    }

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
                kind: "main",
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
    /// insert/animate path runs, not a single frozen batch. Two consecutive
    /// substrate rows early plus a third after a .sessionInfo firing
    /// (run-collapse growing from 2 to 3 members), a substrate row and an
    /// agent-compact line after it -- covering ghost rows, run-collapse,
    /// and the agent-compact seam in one real transcript. No marker
    /// boundary: the wire carries no marker signal today, so production
    /// correctly renders no divider here.
    private func emitFixtureTranscript() async {
        // Real ingestion path (see the messagesContinuation note above): encode
        // each Message as the same ServerMessagePayload/"message" envelope shape
        // ChatViewModel.handleLifecycleServerMessage decodes, and deliver it as
        // a .serverMessage transport event at the connected epoch. Both structs'
        // encode(to:)/init(from:) already agree on the wire shape (including the
        // millisecond-epoch timestamp encoding), so encoding a real
        // ServerMessagePayload value -- not hand-built JSON -- keeps this fixture
        // honest against that contract if it ever changes.
        guard let epoch = connectedEpoch else { return }
        func send(_ message: Message) {
            let payload = ServerMessagePayload(
                type: "message",
                id: message.id,
                llmVisibleMessageId: message.llmVisibleMessageId,
                role: message.role,
                sender: message.sender,
                content: message.content,
                timestamp: message.timestamp,
                streaming: message.streaming,
                deviceId: message.deviceId,
                sessionKey: message.sessionKey,
                attachments: message.attachments,
                clientMessageId: message.clientMessageId,
                replyToMessageId: message.replyToMessageId,
                replyToClientMessageId: message.replyToClientMessageId
            )
            guard let data = try? JSONEncoder().encode(payload) else { return }
            lifecycleTransportEventsContinuation.yield(
                LifecycleTransportEvent(epoch: epoch, payload: .serverMessage(data: data))
            )
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
        guard await wait() else { return }
        send(fixtureMessage(
            role: .user, sender: "agent:coder:gibson",
            content: "Report: marker dividers, segment-anchor, and the agent-compact seam are wired end-to-end. Screenshots attached to the verification artifact."
        ))
        guard await wait() else { return }
        send(fixtureMessage(
            role: .user, sender: "user:mike",
            content: "Review the direct wake rendering before release."
        ))
        guard await wait() else { return }
        send(fixtureMessage(
            role: .user, sender: "process:tightbeam",
            content: "routing complete: this isolated substrate notice keeps its single primary identity."
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
