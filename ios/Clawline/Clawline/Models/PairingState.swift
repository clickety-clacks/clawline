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
    case waitingForApproval(code: String?)
    case success
    case error(String)
}
