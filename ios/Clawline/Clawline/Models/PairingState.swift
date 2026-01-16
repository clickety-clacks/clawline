//
//  PairingState.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

enum PairingState: Equatable {
    case idle
    case enteringName
    case enteringAddress
    case waitingForApproval(code: String?, stalled: Bool)
    case success
    case error(String)
}
