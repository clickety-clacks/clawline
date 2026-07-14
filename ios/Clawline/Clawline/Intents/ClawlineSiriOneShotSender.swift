import Foundation

protocol ClawlineSiriChatServicing: AnyObject {
    var serviceEvents: AsyncStream<ChatServiceEvent> { get }

    func connect(token: String, lastMessageId: String?) async throws
    func disconnect()
    func fetchStreams() async throws -> [StreamSession]
    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?,
        references: [MessageReferenceContext]
    ) async throws
}

extension ProviderChatService: ClawlineSiriChatServicing {}

@MainActor
protocol ClawlineSiriMessageSending {
    func send(
        to reference: ClawlineSiriSessionReference,
        content: String
    ) async throws -> ClawlineSiriSendReceipt
}

struct ClawlineSiriSendReceipt: Equatable {
    let messageID: String
    let session: StreamSession
    let content: String
    let acknowledgedAt: Date
}

enum ClawlineSiriSendError: Error, LocalizedError, Equatable {
    case notPaired
    case emptyText
    case destinationNotFound
    case destinationAmbiguous
    case unsupportedPayload
    case providerRejected(code: String, message: String?)
    case providerUnavailable
    case acknowledgementTimedOut

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Clawline isn’t paired."
        case .emptyText:
            return "The message must contain text."
        case .destinationNotFound:
            return "That Clawline chat is unavailable."
        case .destinationAmbiguous:
            return "More than one Clawline chat has that name."
        case .unsupportedPayload:
            return "Clawline supports text-only Siri messages."
        case .providerRejected(_, let message):
            return message ?? "The provider rejected the message."
        case .providerUnavailable:
            return "Clawline can’t reach the provider."
        case .acknowledgementTimedOut:
            return "The provider didn’t acknowledge the message in time."
        }
    }
}

struct ClawlineSiriTextPayload: Equatable {
    let content: String?
    let recipientCount: Int
    let hasSubject: Bool
    let hasAttachments: Bool
    let hasAudioMessage: Bool
    let hasLocations: Bool
    let hasLinks: Bool
    let hasScheduledDate: Bool

    func validatedContent() throws -> String {
        guard recipientCount == 1 else {
            throw ClawlineSiriSendError.unsupportedPayload
        }
        guard !hasSubject,
              !hasAttachments,
              !hasAudioMessage,
              !hasLocations,
              !hasLinks,
              !hasScheduledDate else {
            throw ClawlineSiriSendError.unsupportedPayload
        }
        guard let content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClawlineSiriSendError.emptyText
        }
        return content
    }
}

@MainActor
struct ClawlineSiriOneShotSender: ClawlineSiriMessageSending {
    typealias ServiceFactory = @MainActor () throws -> (
        service: any ClawlineSiriChatServicing,
        token: String
    )

    private let makeService: ServiceFactory
    private let resolver: ClawlineSiriSessionResolver
    private let acknowledgementTimeout: Duration
    private let makeMessageID: () -> String
    private let now: () -> Date

    init(
        makeService: @escaping ServiceFactory,
        resolver: ClawlineSiriSessionResolver = .init(),
        acknowledgementTimeout: Duration = .seconds(3),
        makeMessageID: @escaping () -> String = { "c_\(UUID().uuidString)" },
        now: @escaping () -> Date = Date.init
    ) {
        self.makeService = makeService
        self.resolver = resolver
        self.acknowledgementTimeout = acknowledgementTimeout
        self.makeMessageID = makeMessageID
        self.now = now
    }

    func availableSessions() async throws -> [StreamSession] {
        let dependency = try makeService()
        defer { dependency.service.disconnect() }
        return try await dependency.service.fetchStreams()
    }

    func resolveLive(
        _ reference: ClawlineSiriSessionReference
    ) async throws -> StreamSession {
        let sessions = try await availableSessions()
        return try resolvedSession(reference, sessions: sessions)
    }

    func send(
        to reference: ClawlineSiriSessionReference,
        content: String
    ) async throws -> ClawlineSiriSendReceipt {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClawlineSiriSendError.emptyText
        }

        let dependency = try makeService()
        defer { dependency.service.disconnect() }

        do {
            try await dependency.service.connect(token: dependency.token, lastMessageId: nil)
            let sessions = try await dependency.service.fetchStreams()
            let session = try resolvedSession(reference, sessions: sessions)
            guard !session.sessionKey.isEmpty else {
                throw ClawlineSiriSendError.destinationNotFound
            }

            let messageID = makeMessageID()
            let events = dependency.service.serviceEvents
            try Task.checkCancellation()
            try await dependency.service.send(
                id: messageID,
                content: content,
                attachments: [],
                sessionKey: session.sessionKey,
                references: []
            )
            try Task.checkCancellation()
            try await waitForAcknowledgement(
                messageID: messageID,
                events: events,
                timeout: acknowledgementTimeout
            )

            return ClawlineSiriSendReceipt(
                messageID: messageID,
                session: session,
                content: content,
                acknowledgedAt: now()
            )
        } catch let error as ClawlineSiriSendError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClawlineSiriSendError.providerUnavailable
        }
    }

    private func resolvedSession(
        _ reference: ClawlineSiriSessionReference,
        sessions: [StreamSession]
    ) throws -> StreamSession {
        switch resolver.resolve(reference, sessions: sessions) {
        case .resolved(let session):
            return session
        case .notFound:
            throw ClawlineSiriSendError.destinationNotFound
        case .ambiguous:
            throw ClawlineSiriSendError.destinationAmbiguous
        }
    }
}

struct ClawlineSiriIntentPayload: Equatable {
    let destinationIDs: [String]
    let content: String?
    let hasSubject: Bool
    let hasAttachments: Bool
    let hasAudioMessage: Bool
    let hasLocations: Bool
    let hasLinks: Bool
    let hasScheduledDate: Bool
}

@MainActor
struct ClawlineSiriSendIntentOperation {
    private let sender: any ClawlineSiriMessageSending

    init(sender: any ClawlineSiriMessageSending) {
        self.sender = sender
    }

    func send(_ payload: ClawlineSiriIntentPayload) async throws -> ClawlineSiriSendReceipt {
        let content = try ClawlineSiriTextPayload(
            content: payload.content,
            recipientCount: payload.destinationIDs.count,
            hasSubject: payload.hasSubject,
            hasAttachments: payload.hasAttachments,
            hasAudioMessage: payload.hasAudioMessage,
            hasLocations: payload.hasLocations,
            hasLinks: payload.hasLinks,
            hasScheduledDate: payload.hasScheduledDate
        ).validatedContent()
        guard let destinationID = payload.destinationIDs.first else {
            throw ClawlineSiriSendError.unsupportedPayload
        }
        return try await sender.send(
            to: .sessionKey(destinationID),
            content: content
        )
    }
}

@MainActor
enum ClawlineSiriProductionDependencies {
    static func makeSender() -> ClawlineSiriOneShotSender {
        ClawlineSiriOneShotSender(makeService: makeService)
    }

    private static func makeService() throws -> (
        service: any ClawlineSiriChatServicing,
        token: String
    ) {
        let auth = AuthManager()
        guard let token = auth.token,
              auth.currentUserId != nil,
              ProviderBaseURLStore.baseURL != nil else {
            throw ClawlineSiriSendError.notPaired
        }

        let device = DeviceIdentifier()
        let connector = URLSessionWebSocketConnector(
            connectTimeout: 6,
            resourceTimeout: 12
        )
        let service = ProviderChatService(
            connector: connector,
            deviceId: device.deviceId,
            userIdProvider: { auth.currentUserId },
            authTokenProvider: { token },
            adoptedSessionKeysProvider: { SessionRegistry.shared.adoptedSessionKeys() }
        )
        return (service, token)
    }
}

private func waitForAcknowledgement(
    messageID: String,
    events: AsyncStream<ChatServiceEvent>,
    timeout: Duration
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in events {
                switch event {
                case .messageAcked(let acknowledgedID) where acknowledgedID == messageID:
                    return
                case .messageError(let failedID, let code, let message)
                        where failedID == messageID:
                    throw ClawlineSiriSendError.providerRejected(code: code, message: message)
                case .connectionInterrupted:
                    throw ClawlineSiriSendError.providerUnavailable
                default:
                    continue
                }
            }
            try Task.checkCancellation()
            throw ClawlineSiriSendError.providerUnavailable
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ClawlineSiriSendError.acknowledgementTimedOut
        }
        guard let result = try await group.next() else {
            throw ClawlineSiriSendError.providerUnavailable
        }
        group.cancelAll()
        return result
    }
}
