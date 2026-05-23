import Foundation

enum RelayMessageType {
    static let chatSend = "chat.send"
    static let chatSendAck = "chat.send.ack"
    static let chatCallback = "chat.callback"
    static let chatIncoming = "chat.incoming"
    static let streamsFetch = "streams.fetch"
    static let streamsCreate = "streams.create"
    static let streamsRename = "streams.rename"
    static let streamsDelete = "streams.delete"
    static let event = "event"
    static let authRefresh = "auth.refresh"
    static let relayActivated = "relay.activated"
    static let relayDeactivated = "relay.deactivated"
}

struct RelayErrorPayload: Codable, Equatable {
    let code: String
    let message: String
}

struct RelayEventEnvelope: Codable, Equatable {
    enum Kind: String, Codable {
        case messageError
        case messageAcked
        case connectionInterrupted
        case userInfo
        case typingStateChanged
        case streamSnapshot
        case streamCreated
        case streamUpdated
        case streamDeleted
        case sessionProvisioningAvailable
        case sessionInfo
    }

    let kind: Kind
    let messageId: String?
    let code: String?
    let message: String?
    let id: String?
    let reason: String?
    let userInfo: ChatUserInfo?
    let isTyping: Bool?
    let sessionKey: String?
    let streams: [StreamSession]?
    let stream: StreamSession?
    let available: Bool?
    let sessionInfo: SessionInfo?

    init(kind: Kind,
         messageId: String? = nil,
         code: String? = nil,
         message: String? = nil,
         id: String? = nil,
         reason: String? = nil,
         userInfo: ChatUserInfo? = nil,
         isTyping: Bool? = nil,
         sessionKey: String? = nil,
         streams: [StreamSession]? = nil,
         stream: StreamSession? = nil,
         available: Bool? = nil,
         sessionInfo: SessionInfo? = nil) {
        self.kind = kind
        self.messageId = messageId
        self.code = code
        self.message = message
        self.id = id
        self.reason = reason
        self.userInfo = userInfo
        self.isTyping = isTyping
        self.sessionKey = sessionKey
        self.streams = streams
        self.stream = stream
        self.available = available
        self.sessionInfo = sessionInfo
    }

    func toEvent() -> ChatServiceEvent? {
        switch kind {
        case .messageError:
            return .messageError(messageId: messageId, code: code ?? "relay_error", message: message)
        case .messageAcked:
            guard let id else { return nil }
            return .messageAcked(id: id)
        case .connectionInterrupted:
            return .connectionInterrupted(reason: reason)
        case .userInfo:
            guard let userInfo else { return nil }
            return .userInfo(userInfo)
        case .typingStateChanged:
            guard let isTyping, let sessionKey else { return nil }
            return .typingStateChanged(isTyping: isTyping, sessionKey: sessionKey)
        case .streamSnapshot:
            return .streamSnapshot(streams ?? [])
        case .streamCreated:
            guard let stream else { return nil }
            return .streamCreated(stream)
        case .streamUpdated:
            guard let stream else { return nil }
            return .streamUpdated(stream)
        case .streamDeleted:
            guard let sessionKey else { return nil }
            return .streamDeleted(sessionKey: sessionKey)
        case .sessionProvisioningAvailable:
            return .sessionProvisioningAvailable(available ?? false)
        case .sessionInfo:
            guard let sessionInfo else { return nil }
            return .sessionInfo(sessionInfo)
        }
    }

    static func from(event: ChatServiceEvent) -> RelayEventEnvelope {
        switch event {
        case .messageError(let messageId, let code, let message):
            return RelayEventEnvelope(kind: .messageError, messageId: messageId, code: code, message: message)
        case .messageAcked(let id):
            return RelayEventEnvelope(kind: .messageAcked, id: id)
        case .connectionInterrupted(let reason):
            return RelayEventEnvelope(kind: .connectionInterrupted, reason: reason)
        case .userInfo(let userInfo):
            return RelayEventEnvelope(kind: .userInfo, userInfo: userInfo)
        case .typingStateChanged(let isTyping, let sessionKey):
            return RelayEventEnvelope(kind: .typingStateChanged, isTyping: isTyping, sessionKey: sessionKey)
        case .streamSnapshot(let streams):
            return RelayEventEnvelope(kind: .streamSnapshot, streams: streams)
        case .streamCreated(let stream):
            return RelayEventEnvelope(kind: .streamCreated, stream: stream)
        case .streamUpdated(let stream):
            return RelayEventEnvelope(kind: .streamUpdated, stream: stream)
        case .streamDeleted(let sessionKey):
            return RelayEventEnvelope(kind: .streamDeleted, sessionKey: sessionKey)
        case .sessionProvisioningAvailable(let available):
            return RelayEventEnvelope(kind: .sessionProvisioningAvailable, available: available)
        case .sessionInfo(let sessionInfo):
            return RelayEventEnvelope(kind: .sessionInfo, sessionInfo: sessionInfo)
        }
    }
}

enum RelayProtocolError: Error, LocalizedError {
    case malformed
    case notConnected
    case unsupported(String)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "Malformed relay payload"
        case .notConnected:
            return "iPhone relay unavailable"
        case .unsupported(let type):
            return "Unsupported relay message type: \(type)"
        case .server(_, let message):
            return message
        }
    }
}
