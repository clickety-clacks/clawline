//
//  PairingViewModel.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class PairingViewModel {
    var state: PairingState = .idle
    var nameInput: String = ""

    private let auth: any AuthManaging
    private let connection: any ConnectionServicing
    private let deviceId: String

    init(auth: any AuthManaging, connection: any ConnectionServicing, device: any DeviceIdentifying) {
        self.auth = auth
        self.connection = connection
        self.deviceId = device.deviceId
    }

    func submitName() async {
        guard !nameInput.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .error("Name cannot be empty")
            return
        }

        state = .waitingForApproval(code: nil)

        do {
            let result = try await connection.requestPairing(claimedName: nameInput, deviceId: deviceId)
            switch result {
            case .success(let token, let userId):
                auth.storeCredentials(token: token, userId: userId)
                state = .success
            case .denied(let reason):
                state = .error(reason)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
