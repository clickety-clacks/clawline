//
//  ChatError.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

enum ChatError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        }
    }
}
