//
//  ConnectionServicing.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

enum PairingResult: Equatable {
    case success(token: String, userId: String)
    case denied(reason: String)
}

protocol ConnectionServicing {
    func requestPairing(claimedName: String, deviceId: String) async throws -> PairingResult
}
