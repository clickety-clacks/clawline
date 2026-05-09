//
//  ProviderWireModels.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

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


struct StreamReadStatePayload: Codable, Equatable {
    let type: String
    let sessionKey: String
    let lastReadMessageId: String
}

struct StreamTailStatePayload: Codable, Equatable {
    let type: String
    let sessionKey: String
    let lastMessageId: String
    let lastMessageRole: Message.Role

    var tailState: StreamTailState {
        StreamTailState(lastMessageId: lastMessageId, lastMessageRole: lastMessageRole)
    }
}

struct ClientStreamReadPayload: Codable, Equatable {
    let type: String
    let sessionKey: String
    let lastReadMessageId: String

    init(sessionKey: String, lastReadMessageId: String, type: String = "stream_read") {
        self.type = type
        self.sessionKey = sessionKey
        self.lastReadMessageId = lastReadMessageId
    }
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
    let clientMessageId: String?
    let replyToMessageId: String?
    let replyToClientMessageId: String?

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
        case clientMessageId
        case replyToMessageId
        case replyToClientMessageId
    }

    // Support multiple server metadata shapes for "who is speaking" without hardcoding names.
    // Some servers historically send `sender: "assistant"` which is a role marker, not a display name.
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
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected `from` to be a String or Object"
                )
            )
        }

        var resolvedName: String? {
            switch self {
            case .string(let value):
                return value
            case .object(let obj):
                return obj.displayName ?? obj.name ?? obj.id
            }
        }

        var resolvedRole: Message.Role? {
            switch self {
            case .string:
                return nil
            case .object(let obj):
                guard let raw = obj.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !raw.isEmpty else { return nil }
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
         attachments: [Attachment],
         clientMessageId: String? = nil,
         replyToMessageId: String? = nil,
         replyToClientMessageId: String? = nil) {
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
        self.clientMessageId = clientMessageId
        self.replyToMessageId = replyToMessageId
        self.replyToClientMessageId = replyToClientMessageId
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
        clientMessageId = try container.decodeIfPresent(String.self, forKey: .clientMessageId)
        replyToMessageId = try container.decodeIfPresent(String.self, forKey: .replyToMessageId)
        replyToClientMessageId = try container.decodeIfPresent(String.self, forKey: .replyToClientMessageId)
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
        try container.encodeIfPresent(clientMessageId, forKey: .clientMessageId)
        try container.encodeIfPresent(replyToMessageId, forKey: .replyToMessageId)
        try container.encodeIfPresent(replyToClientMessageId, forKey: .replyToClientMessageId)
    }
}

struct ClientMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let content: String
    let attachments: [WireAttachment]
    let sessionKey: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case content
        case attachments
        case sessionKey
    }

    init(id: String, content: String, attachments: [WireAttachment], sessionKey: String?, type: String = "message") {
        self.type = type
        self.id = id
        self.content = content
        self.attachments = attachments
        self.sessionKey = sessionKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "message"
        self.id = try container.decode(String.self, forKey: .id)
        self.content = try container.decode(String.self, forKey: .content)
        self.attachments = try container.decodeIfPresent([WireAttachment].self, forKey: .attachments) ?? []
        self.sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(sessionKey, forKey: .sessionKey)
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
            sender: payload.sender,
            clientMessageId: payload.clientMessageId,
            replyToMessageId: payload.replyToMessageId,
            replyToClientMessageId: payload.replyToClientMessageId
        )
    }

    func toClientPayload() -> ClientMessagePayload {
        let wireAttachments: [WireAttachment] = attachments.compactMap { attachment in
            if let assetId = attachment.assetId {
                return .asset(assetId: assetId)
            }
            if let data = attachment.data, let mimeType = attachment.mimeType {
                return .image(mimeType: mimeType, data: data)
            }
            return nil
        }
        return ClientMessagePayload(
            id: id,
            content: content,
            attachments: wireAttachments,
            sessionKey: sessionKey
        )
    }
}
