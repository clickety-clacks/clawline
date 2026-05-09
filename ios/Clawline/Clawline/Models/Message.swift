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

    init(id: String,
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
         replyToClientMessageId: String? = nil) {
        self.id = id
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
    }

    var stream: ChatStream {
        SessionKey.stream(for: sessionKey)
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
}
