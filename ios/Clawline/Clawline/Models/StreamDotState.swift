import Foundation

enum StreamDotState: String, Codable, Equatable {
    case unread
    case userTail
    case inactive
}

struct StreamDotStateLookup {
    private let resolve: (String) -> StreamDotState

    init(_ resolve: @escaping (String) -> StreamDotState) {
        self.resolve = resolve
    }

    func callAsFunction(_ sessionKey: String) -> StreamDotState {
        resolve(sessionKey)
    }
}

struct StreamTailState: Codable, Equatable {
    let lastMessageId: String
    let lastMessageRole: Message.Role
}
