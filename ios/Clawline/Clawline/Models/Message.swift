//
//  Message.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

struct Message: Identifiable, Equatable {
    let id: String
    let role: Role
    let content: String
    let timestamp: Date
    var isStreaming: Bool

    enum Role: String, Codable {
        case user
        case assistant
    }
}
