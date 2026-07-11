#if T1659_MESSAGES_SCHEMA
import AppIntents
import Foundation
import GeoToolbox
import LinkPresentation
import UniformTypeIdentifiers

@available(iOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
struct ClawlineMessagePersonEntity: AppEntity {
    static let defaultQuery = Query()

    var id: String
    var person: IntentPerson
    let chatDisplayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(chatDisplayName)")
    }

    init(session: StreamSession) {
        self.init(id: session.sessionKey, displayName: session.displayName)
    }

    init(id: String, displayName: String) {
        self.id = id
        self.chatDisplayName = displayName
        self.person = IntentPerson(
            identifier: .applicationDefined(id),
            name: .displayName(displayName),
            handle: nil
        )
    }

    struct Query: EntityStringQuery {
        static var persistentIdentifier: String { "ClawlineMessagePersonQuery" }

        func entities(for identifiers: [ClawlineMessagePersonEntity.ID]) async throws
            -> [ClawlineMessagePersonEntity] {
            let sender = await ClawlineSiriProductionDependencies.makeSender()
            let sessions = try await sender.availableSessions()
            return identifiers.compactMap { identifier in
                guard case .resolved(let session) = ClawlineSiriSessionResolver().resolve(
                    .sessionKey(identifier),
                    sessions: sessions
                ) else {
                    return nil
                }
                return ClawlineMessagePersonEntity(session: session)
            }
        }

        func entities(matching string: String) async throws -> [ClawlineMessagePersonEntity] {
            let sender = await ClawlineSiriProductionDependencies.makeSender()
            let sessions = try await sender.availableSessions()
            switch ClawlineSiriSessionResolver().resolve(
                .spokenDestination(string),
                sessions: sessions
            ) {
            case .resolved(let session):
                return [ClawlineMessagePersonEntity(session: session)]
            case .notFound:
                return []
            case .ambiguous:
                throw ClawlineSiriSendError.destinationAmbiguous
            }
        }
    }
}

@available(iOS 27.0, *)
typealias ClawlineMessageRecipients = [ClawlineMessagePersonEntity]

@available(iOS 27.0, *)
@UnionValue
enum ClawlineMessageDestination {
    case contact(ClawlineMessagePersonEntity)
    case recipients(ClawlineMessageRecipients)

    var persons: [ClawlineMessagePersonEntity] {
        switch self {
        case .contact(let contact):
            return [contact]
        case .recipients(let recipients):
            return recipients
        }
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .messages.conversation)
struct ClawlineConversationEntity: AppEntity {
    static let defaultQuery = Query()

    var id: String
    var recipients: [ClawlineMessagePersonEntity]
    var displayName: String
    var previewText: AttributedString
    var conversationName: String?
    var isRead: Bool
    var attributes: Set<ClawlineConversationAttribute>
    var dateLastActive: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(destination: ClawlineMessagePersonEntity) {
        self.id = destination.id
        self.recipients = [destination]
        self.displayName = destination.chatDisplayName
        self.previewText = AttributedString("")
        self.conversationName = nil
        self.isRead = true
        self.attributes = []
        self.dateLastActive = nil
    }

    struct Query: EntityQuery {
        static var persistentIdentifier: String { "ClawlineConversationQuery" }

        func entities(for identifiers: [ClawlineConversationEntity.ID]) async throws
            -> [ClawlineConversationEntity] {
            []
        }
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
enum ClawlineConversationAttribute: String, AppEnum {
    case favorited

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorited: "Favorited"
    ]
}

@available(iOS 27.0, *)
@AppEntity(schema: .messages.message)
struct ClawlineMessageEntity: AppEntity {
    static let defaultQuery = Query()

    var id: String
    var messageType: ClawlineMessageType
    var author: ClawlineMessagePersonEntity
    var isRead: Bool
    var attributes: Set<ClawlineMessageAttribute>
    var conversation: ClawlineConversationEntity
    var date: Date
    var subject: AttributedString?
    var body: AttributedString?
    var attachments: [IntentFile]
    var audioMessage: IntentFile?
    var customAttachments: [ClawlineCustomAttachment]
    var locations: [PlaceDescriptor]
    var links: [LinkPresentation.LinkMetadata]
    var messageEffect: ClawlineMessageEffect?
    var reaction: ClawlineMessageReaction?
    var referencedMessage: ClawlineMessageEntity?
    var notificationIdentifier: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(body ?? AttributedString(""))",
            subtitle: "\(conversation.displayName)"
        )
    }

    init(receipt: ClawlineSiriSendReceipt) {
        let destination = ClawlineMessagePersonEntity(session: receipt.session)
        self.id = receipt.messageID
        self.messageType = .unspecified
        self.author = ClawlineMessagePersonEntity(
            id: "clawline:local-user",
            displayName: "You"
        )
        self.isRead = false
        self.attributes = []
        self.conversation = ClawlineConversationEntity(destination: destination)
        self.date = receipt.acknowledgedAt
        self.subject = nil
        self.body = AttributedString(receipt.content)
        self.attachments = []
        self.audioMessage = nil
        self.customAttachments = []
        self.locations = []
        self.links = []
        self.messageEffect = nil
        self.reaction = nil
        self.referencedMessage = nil
        self.notificationIdentifier = nil
    }

    struct Query: EntityStringQuery {
        static var persistentIdentifier: String { "ClawlineMessageQuery" }

        func entities(for identifiers: [ClawlineMessageEntity.ID]) async throws
            -> [ClawlineMessageEntity] {
            []
        }

        func entities(matching string: String) async throws -> [ClawlineMessageEntity] {
            []
        }
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
struct ClawlineCustomAttachment: AppEntity {
    static let defaultQuery = Query()

    var id: String
    var sourceName: AttributedString?
    var description: AttributedString?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(description ?? AttributedString(""))")
    }

    struct Query: EntityQuery {
        static var persistentIdentifier: String { "ClawlineCustomAttachmentQuery" }

        func entities(for identifiers: [ClawlineCustomAttachment.ID]) async throws
            -> [ClawlineCustomAttachment] {
            []
        }
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageType)
enum ClawlineMessageType: String, AppEnum {
    case unspecified

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .unspecified: "Unspecified"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
enum ClawlineMessageAttribute: String, AppEnum {
    case favorited

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .favorited: "Favorited"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
enum ClawlineMessageEffect: String, AppEnum {
    case love

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .love: "Love"
    ]
}

@available(iOS 27.0, *)
@UnionValue
enum ClawlineMessageReaction: Sendable {
    case customReaction(ClawlineCustomReaction)
}

@available(iOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
enum ClawlineCustomReaction: String, AppEnum {
    case sticker

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .sticker: "Sticker"
    ]
}

@available(iOS 27.0, *)
@AppIntent(schema: .messages.sendMessage)
struct ClawlineSendMessageIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    var destination: ClawlineMessageDestination
    var subject: AttributedString?
    var content: AttributedString?
    @Parameter(supportedContentTypes: [.image]) var attachments: [IntentFile]
    @Parameter(supportedContentTypes: [.audio]) var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor
    func perform() async throws -> some ReturnsValue<[ClawlineMessageEntity]> {
        let persons = destination.persons
        let payload = ClawlineSiriIntentPayload(
            destinationIDs: persons.map(\.id),
            content: content.map { String($0.characters) },
            hasSubject: subject != nil,
            hasAttachments: !attachments.isEmpty,
            hasAudioMessage: audioMessage != nil,
            hasLocations: !locations.isEmpty,
            hasLinks: !links.isEmpty,
            hasScheduledDate: scheduledDate != nil
        )
        let operation = ClawlineSiriSendIntentOperation(
            sender: ClawlineSiriProductionDependencies.makeSender()
        )
        let receipt = try await operation.send(payload)
        return .result(value: [ClawlineMessageEntity(receipt: receipt)])
    }
}

private enum ClawlineMessagesScaffolding {
    static let unsupported = true
}

@available(iOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
struct ClawlineDraftMessageIntent: AppIntent {
    var destination: ClawlineMessageDestination?
    var subject: AttributedString?
    var content: AttributedString?
    @Parameter(supportedContentTypes: [.image]) var attachments: [IntentFile]
    @Parameter(supportedContentTypes: [.audio]) var audioMessage: IntentFile?
    var locations: [PlaceDescriptor]
    var links: [URL]
    var scheduledDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !ClawlineMessagesScaffolding.unsupported else {
            throw ClawlineSiriSendError.unsupportedPayload
        }
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .messages.setMessageReadStatus)
struct ClawlineSetMessageReadStatusIntent: AppIntent {
    var message: ClawlineMessageEntity
    var isRead: Bool

    func perform() async throws -> some IntentResult {
        guard !ClawlineMessagesScaffolding.unsupported else {
            throw ClawlineSiriSendError.unsupportedPayload
        }
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .messages.editSentMessage)
struct ClawlineEditSentMessageIntent: AppIntent {
    var message: ClawlineMessageEntity
    var content: AttributedString

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !ClawlineMessagesScaffolding.unsupported else {
            throw ClawlineSiriSendError.unsupportedPayload
        }
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .messages.unsendMessage)
struct ClawlineUnsendMessageIntent: AppIntent {
    var message: ClawlineMessageEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !ClawlineMessagesScaffolding.unsupported else {
            throw ClawlineSiriSendError.unsupportedPayload
        }
        return .result()
    }
}
#endif
