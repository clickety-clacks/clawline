//
//  StubConnectionService.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation

final class StubConnectionService: ConnectionServicing {
    var approvalDelay: TimeInterval = 3.0
    var shouldSucceed: Bool = true

    func requestPairing(serverURL: URL, claimedName: String, deviceId: String) async throws -> PairingResult {
        try await Task.sleep(for: .seconds(approvalDelay))

        if shouldSucceed {
            let fakeToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.stub.\(deviceId)"
            return .success(token: fakeToken, userId: claimedName.lowercased())
        }

        return .denied(reason: "Admin rejected pairing request")
    }
}
