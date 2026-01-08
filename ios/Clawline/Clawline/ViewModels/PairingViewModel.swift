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
    var addressInput: String = ""

    /// Current page index for the horizontal scroll (0 = name, 1 = address)
    var currentPage: Int = 0

    private let auth: any AuthManaging
    private let connection: any ConnectionServicing
    private let deviceId: String

    init(auth: any AuthManaging, connection: any ConnectionServicing, device: any DeviceIdentifying) {
        self.auth = auth
        self.connection = connection
        self.deviceId = device.deviceId
    }

    var isNameValid: Bool {
        !nameInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isAddressValid: Bool {
        !addressInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Called when user submits their name - scrolls to address page
    func submitName() {
        guard isNameValid else { return }
        state = .enteringAddress
        currentPage = 1
    }

    /// Called when user submits the server address - initiates pairing
    func submitAddress() async {
        guard isAddressValid else {
            state = .error("Server address cannot be empty")
            return
        }

        // Build the WebSocket URL
        let addressString = addressInput.trimmingCharacters(in: .whitespaces)
        let urlString: String
        if addressString.hasPrefix("ws://") || addressString.hasPrefix("wss://") {
            urlString = addressString
        } else {
            // Default to wss:// with default port
            urlString = "wss://\(addressString):18792"
        }

        guard let serverURL = URL(string: urlString) else {
            state = .error("Invalid server address")
            return
        }

        state = .waitingForApproval(code: nil)
        currentPage = 2

        do {
            let result = try await connection.requestPairing(
                serverURL: serverURL,
                claimedName: nameInput,
                deviceId: deviceId
            )
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

    /// Go back to name input page
    func goBackToName() {
        state = .enteringName
        currentPage = 0
    }

    /// Cancel the pairing request and go back to address input
    func cancelPairing() {
        state = .enteringAddress
        currentPage = 1
    }
}
