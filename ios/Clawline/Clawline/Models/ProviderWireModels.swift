//
//  ProviderWireModels.swift
//  Clawline
//
//  Created by Codex on 1/12/26.
//

import Foundation

struct ServerMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let role: Message.Role
    let content: String
    let timestamp: Date
    let streaming: Bool
    let deviceId: String?
    let attachments: [Attachment]
    let channelType: ChatChannelType

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case role
        case content
        case timestamp
        case streaming
        case deviceId
        case attachments
        case channelType
    }

    init(type: String = "message",
         id: String,
         role: Message.Role,
         content: String,
         timestamp: Date,
         streaming: Bool,
         deviceId: String?,
         attachments: [Attachment],
         channelType: ChatChannelType = .personal) {
        self.type = type
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.streaming = streaming
        self.deviceId = deviceId
        self.attachments = attachments
        self.channelType = channelType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Message.Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        let milliseconds = try container.decode(Double.self, forKey: .timestamp)
        timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
        streaming = try container.decode(Bool.self, forKey: .streaming)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        channelType = (try? container.decode(ChatChannelType.self, forKey: .channelType)) ?? .personal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp.timeIntervalSince1970 * 1000, forKey: .timestamp)
        try container.encode(streaming, forKey: .streaming)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(channelType, forKey: .channelType)
    }
}

struct ClientMessagePayload: Codable, Equatable {
    let type: String
    let id: String
    let content: String
    let attachments: [WireAttachment]
    let channelType: ChatChannelType

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case content
        case attachments
        case channelType
    }

    init(id: String, content: String, attachments: [WireAttachment], channelType: ChatChannelType, type: String = "message") {
        self.type = type
        self.id = id
        self.content = content
        self.attachments = attachments
        self.channelType = channelType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "message"
        self.id = try container.decode(String.self, forKey: .id)
        self.content = try container.decode(String.self, forKey: .content)
        self.attachments = try container.decodeIfPresent([WireAttachment].self, forKey: .attachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(attachments, forKey: .attachments)
    }
}

extension Message {
    init(payload: ServerMessagePayload) {
        self.init(
            id: payload.id,
            role: payload.role,
            content: payload.content,
            timestamp: payload.timestamp,
            streaming: payload.streaming,
            attachments: payload.attachments,
            deviceId: payload.deviceId,
            channelType: payload.channelType
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
        return ClientMessagePayload(id: id, content: content, attachments: wireAttachments, channelType: channelType)
    }
}
