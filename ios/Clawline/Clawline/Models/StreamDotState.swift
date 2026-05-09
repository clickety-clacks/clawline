import Foundation

enum StreamDotState: String, Codable, Equatable {
    case unread
    case userTail
    case inactive
}

struct StreamTailState: Codable, Equatable {
    let lastMessageId: String
    let lastMessageRole: Message.Role
}
