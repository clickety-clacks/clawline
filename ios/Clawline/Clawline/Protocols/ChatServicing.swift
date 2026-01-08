//
//  ChatServicing.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

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

protocol ChatServicing {
    var incomingMessages: AsyncStream<Message> { get }
    var connectionState: AsyncStream<ConnectionState> { get }

    func connect(token: String) async throws
    func disconnect()
    func send(content: String, attachments: [Attachment]) async throws
}
