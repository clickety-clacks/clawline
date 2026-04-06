import Foundation

// MARK: - Core chat contract

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

enum WatchProviderTransportState: Equatable {
    case direct
    case probing
    case relay
    case disconnected
}

struct SessionInfo: Equatable, Codable {
    let userId: String?
    let isAdmin: Bool?
    let dmScope: String?
    let sessionKeys: [String]
}

struct ChatUserInfo: Equatable, Codable {
    let userId: String
    let isAdmin: Bool
}

enum StreamDotState: String, Codable, Equatable {
    case unread
    case userTail
    case inactive
}

struct StreamTailState: Codable, Equatable {
    let lastMessageId: String
    let lastMessageRole: Message.Role
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
    case streamReadStateSnapshot([String: String])
    case streamReadStateUpdated(sessionKey: String, lastReadMessageId: String)
    case streamTailStateSnapshot([String: StreamTailState])
    case streamTailStateUpdated(sessionKey: String, tailState: StreamTailState)
    case sessionProvisioningAvailable(Bool)
    case sessionInfo(SessionInfo)
}

protocol ChatServicing {
    var incomingMessages: AsyncStream<Message> { get }
    var connectionState: AsyncStream<ConnectionState> { get }
    var serviceEvents: AsyncStream<ChatServiceEvent> { get }

    func connect(token: String, lastMessageId: String?) async throws
    func disconnect()
    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws
    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws
    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws

    func fetchStreams() async throws -> [StreamSession]
    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession
    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession
    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String
}

// MARK: - Model types

enum ChatStream: String, Codable, CaseIterable, Equatable {
    case personal
    case admin

    var displayName: String {
        switch self {
        case .personal: return "Personal"
        case .admin: return "DM"
        }
    }
}

enum SessionKey {
    static let admin = "agent:main:main"

    static func stream(for sessionKey: String) -> ChatStream {
        sessionKey == admin ? .admin : .personal
    }
}

struct Message: Identifiable, Equatable, Codable {
    let id: String
    let role: Role
    let content: String
    let timestamp: Date
    var streaming: Bool
    let attachments: [Attachment]
    let deviceId: String?
    let sessionKey: String
    let sender: String?

    enum Role: String, Codable {
        case user
        case assistant
    }

    var stream: ChatStream {
        SessionKey.stream(for: sessionKey)
    }
}

struct StreamSession: Codable, Equatable, Identifiable {
    var id: String { sessionKey }
    let sessionKey: String
    var displayName: String
    let kind: String
    let orderIndex: Int
    let isBuiltIn: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionKey
        case displayName
        case kind
        case orderIndex
        case isBuiltIn
        case createdAt
        case updatedAt
    }

    init(sessionKey: String,
         displayName: String,
         kind: String,
         orderIndex: Int,
         isBuiltIn: Bool,
         createdAt: Date,
         updatedAt: Date) {
        self.sessionKey = sessionKey
        self.displayName = displayName
        self.kind = kind
        self.orderIndex = orderIndex
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(String.self, forKey: .kind)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try container.decodeUnixMillisDate(forKey: .createdAt)
        updatedAt = try container.decodeUnixMillisDate(forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encode(orderIndex, forKey: .orderIndex)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(createdAt.timeIntervalSince1970 * 1000, forKey: .createdAt)
        try container.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
    }
}

private extension KeyedDecodingContainer {
    func decodeUnixMillisDate(forKey key: Key) throws -> Date {
        if let milliseconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let intMilliseconds = try? decode(Int64.self, forKey: key) {
            return Date(timeIntervalSince1970: Double(intMilliseconds) / 1000)
        }
        throw DecodingError.typeMismatch(
            Date.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected unix epoch milliseconds."
            )
        )
    }
}

struct Attachment: Identifiable, Equatable, Codable {
    let id: String
    let type: AttachmentType
    let mimeType: String?
    let data: Data?
    let assetId: String?
    let filename: String?
    let size: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case mimeType
        case data
        case assetId
        case metadata
    }

    private struct AttachmentMetadata: Codable, Equatable {
        let mimeType: String?
        let filename: String?
        let size: Int?
        let width: Int?
        let height: Int?
    }

    init(id: String,
         type: AttachmentType,
         mimeType: String?,
         data: Data?,
         assetId: String?,
         filename: String? = nil,
         size: Int? = nil) {
        self.id = id
        self.type = type
        self.mimeType = mimeType
        self.data = data
        self.assetId = assetId
        self.filename = filename
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedType = try container.decode(AttachmentType.self, forKey: .type)
        let decodedMimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let metadata = try container.decodeIfPresent(AttachmentMetadata.self, forKey: .metadata)
        let decodedData = try container.decodeIfPresent(Data.self, forKey: .data)
        let decodedAssetId = try container.decodeIfPresent(String.self, forKey: .assetId)
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id)

        type = decodedType
        mimeType = decodedMimeType ?? metadata?.mimeType
        data = decodedData
        assetId = decodedAssetId
        filename = metadata?.filename
        size = metadata?.size ?? decodedData?.count

        if let decodedId {
            id = decodedId
        } else if let decodedAssetId {
            id = decodedAssetId
        } else {
            id = UUID().uuidString
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(assetId, forKey: .assetId)
    }
}

enum AttachmentType: String, Codable, Equatable {
    case image
    case asset
    case document
}

enum WireAttachment: Equatable, Codable {
    case image(mimeType: String, data: Data)
    case asset(assetId: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case mimeType
        case data
        case assetId
    }

    private enum Kind: String, Codable {
        case image
        case asset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Kind.self, forKey: .type)
        switch type {
        case .image:
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            let base64String = try container.decode(String.self, forKey: .data)
            guard let data = Data(base64Encoded: base64String) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: container, debugDescription: "Invalid base64")
            }
            self = .image(mimeType: mimeType, data: data)
        case .asset:
            let assetId = try container.decode(String.self, forKey: .assetId)
            self = .asset(assetId: assetId)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let mimeType, let data):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(data.base64EncodedString(), forKey: .data)
        case .asset(let assetId):
            try container.encode(Kind.asset, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        }
    }
}

enum JSONValue: Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - Wire payloads

struct StreamSnapshotPayload: Codable, Equatable {
    let type: String
    let streams: [StreamSession]
}

struct StreamMutationPayload: Codable, Equatable {
    let type: String
    let stream: StreamSession
}

struct StreamDeletedPayload: Codable, Equatable {
    let type: String
    let sessionKey: String
}

struct ServerMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let role: Message.Role
    let sender: String?
    let content: String
    let timestamp: Date
    let streaming: Bool
    let deviceId: String?
    let sessionKey: String?
    let attachments: [Attachment]

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case role
        case sender
        case from
        case name
        case content
        case timestamp
        case streaming
        case deviceId
        case sessionKey
        case attachments
    }

    private enum FromField: Decodable {
        struct FromObject: Decodable {
            let name: String?
            let displayName: String?
            let id: String?
            let role: String?
        }

        case string(String)
        case object(FromObject)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            if let value = try? container.decode(FromObject.self) {
                self = .object(value)
                return
            }
            throw DecodingError.typeMismatch(
                FromField.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid from field")
            )
        }

        var resolvedName: String? {
            switch self {
            case .string(let value): return value
            case .object(let obj): return obj.displayName ?? obj.name ?? obj.id
            }
        }

        var resolvedRole: Message.Role? {
            switch self {
            case .string: return nil
            case .object(let obj):
                guard let raw = obj.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
                    return nil
                }
                return raw == Message.Role.assistant.rawValue ? .assistant : .user
            }
        }
    }

    init(type: String = "message",
         id: String,
         role: Message.Role,
         sender: String? = nil,
         content: String,
         timestamp: Date,
         streaming: Bool,
         deviceId: String?,
         sessionKey: String?,
         attachments: [Attachment]) {
        self.type = type
        self.id = id
        self.role = role
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.streaming = streaming
        self.deviceId = deviceId
        self.sessionKey = sessionKey
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        let legacySender = try container.decodeIfPresent(String.self, forKey: .sender)
        let fromField = try container.decodeIfPresent(FromField.self, forKey: .from)
        let topLevelName = try container.decodeIfPresent(String.self, forKey: .name)
        sender = fromField?.resolvedName ?? topLevelName ?? legacySender
        if let decodedRole = try container.decodeIfPresent(Message.Role.self, forKey: .role) {
            role = decodedRole
        } else if let resolved = fromField?.resolvedRole {
            role = resolved
        } else if let legacySender {
            role = legacySender.lowercased() == Message.Role.assistant.rawValue ? .assistant : .user
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.role,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing role/sender")
            )
        }
        content = try container.decode(String.self, forKey: .content)
        let milliseconds = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
        streaming = try container.decode(Bool.self, forKey: .streaming)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(sender, forKey: .sender)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
        try container.encode(streaming, forKey: .streaming)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(sessionKey, forKey: .sessionKey)
        try container.encode(attachments, forKey: .attachments)
    }
}

struct ClientMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let content: String
    let attachments: [WireAttachment]
    let sessionKey: String?

    init(id: String, content: String, attachments: [WireAttachment], sessionKey: String?, type: String = "message") {
        self.type = type
        self.id = id
        self.content = content
        self.attachments = attachments
        self.sessionKey = sessionKey
    }
}

extension Message {
    init(payload: ServerMessagePayload, sessionKey: String) {
        self.init(
            id: payload.id,
            role: payload.role,
            content: payload.content,
            timestamp: payload.timestamp,
            streaming: payload.streaming,
            attachments: payload.attachments,
            deviceId: payload.deviceId,
            sessionKey: sessionKey,
            sender: payload.sender
        )
    }
}
