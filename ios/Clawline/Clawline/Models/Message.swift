//
//  Message.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

enum ChatStream: String, Codable, CaseIterable, Equatable {
    case personal
    case admin

    var displayName: String {
        switch self {
        case .personal:
            return "Personal"
        case .admin:
            return "DM"
        }
    }
}

struct ChatUserInfo: Equatable {
    let userId: String
    let isAdmin: Bool
}

struct Message: Identifiable, Equatable, Codable {
    let id: String
    let llmVisibleMessageId: String?
    let role: Role
    let content: String
    let timestamp: Date
    var streaming: Bool
    let attachments: [Attachment]
    let deviceId: String?
    let sessionKey: String
    let sender: String?
    let clientMessageId: String?
    let replyToMessageId: String?
    let replyToClientMessageId: String?
    var deliveryState: DeliveryState

    init(id: String,
         llmVisibleMessageId: String? = nil,
         role: Role,
         content: String,
         timestamp: Date,
         streaming: Bool,
         attachments: [Attachment],
         deviceId: String?,
         sessionKey: String,
         sender: String? = nil,
         clientMessageId: String? = nil,
         replyToMessageId: String? = nil,
         replyToClientMessageId: String? = nil,
         deliveryState: DeliveryState = .normal) {
        self.id = id
        self.llmVisibleMessageId = llmVisibleMessageId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.streaming = streaming
        self.attachments = attachments
        self.deviceId = deviceId
        self.sessionKey = sessionKey
        self.sender = sender
        self.clientMessageId = clientMessageId
        self.replyToMessageId = replyToMessageId
        self.replyToClientMessageId = replyToClientMessageId
        self.deliveryState = deliveryState
    }

    var stream: ChatStream {
        SessionKey.stream(for: sessionKey)
    }

    var hasStableReferenceIdentity: Bool {
        llmVisibleMessageId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var displayName: String {
        switch role {
        case .user:
            return "You"
        case .assistant:
            if let sender {
                let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
                // Servers sometimes send `sender: "assistant"` as a role marker. Treat it as missing
                // so we fall back to the generic label unless a real display name is provided.
                if !trimmed.isEmpty, trimmed.lowercased() != Message.Role.assistant.rawValue {
                    return trimmed
                }
            }
            return "Assistant"
        }
    }

    enum Role: String, Codable {
        case user
        case assistant
    }

    enum DeliveryState: String, Codable {
        case normal
        case canceled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case llmVisibleMessageId
        case role
        case content
        case timestamp
        case streaming
        case attachments
        case deviceId
        case sessionKey
        case sender
        case clientMessageId
        case replyToMessageId
        case replyToClientMessageId
        case deliveryState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        llmVisibleMessageId = try container.decodeIfPresent(String.self, forKey: .llmVisibleMessageId)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        streaming = try container.decode(Bool.self, forKey: .streaming)
        attachments = try container.decode([Attachment].self, forKey: .attachments)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        sender = try container.decodeIfPresent(String.self, forKey: .sender)
        clientMessageId = try container.decodeIfPresent(String.self, forKey: .clientMessageId)
        replyToMessageId = try container.decodeIfPresent(String.self, forKey: .replyToMessageId)
        replyToClientMessageId = try container.decodeIfPresent(String.self, forKey: .replyToClientMessageId)
        deliveryState = try container.decodeIfPresent(DeliveryState.self, forKey: .deliveryState) ?? .normal
    }
}

struct PendingMessageReference: Identifiable, Equatable, Codable {
    let id: UUID
    let sessionKey: String
    let llmVisibleMessageId: String?
    let messageRole: Message.Role
    let createdAt: Date
    let clientMessageId: String?
    let preview: String

    init(id: UUID = UUID(), message: Message) {
        self.id = id
        self.sessionKey = message.sessionKey
        self.llmVisibleMessageId = message.llmVisibleMessageId
        self.messageRole = message.role
        self.createdAt = message.timestamp
        self.clientMessageId = message.clientMessageId
        self.preview = String(message.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.previewLimit))
    }

    static let previewLimit = 240

    var tokenLabel: String {
        guard !preview.isEmpty else { return "Reply" }
        if preview.count <= 48 {
            return preview
        }
        return "\(String(preview.prefix(48)))…"
    }
}
