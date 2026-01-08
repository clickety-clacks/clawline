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

    /// Current page index for the horizontal scroll (0 = name, 1 = address, 2 = waiting)
    var currentPage: Int = 0

    /// Direction of the last page transition (true = forward/right, false = backward/left)
    var isNavigatingForward: Bool = true

    private let auth: any AuthManaging
    private let connection: any ConnectionServicing
    private let deviceId: String
    private var pairingTask: Task<Void, Never>?

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
        isNavigatingForward = true
        currentPage = 1
    }

    /// Called when user submits the server address - initiates pairing
    func submitAddress() {
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
        isNavigatingForward = true
        currentPage = 2

        // Cancel any existing task and start a new one
        pairingTask?.cancel()
        pairingTask = Task {
            do {
                let result = try await connection.requestPairing(
                    serverURL: serverURL,
                    claimedName: nameInput,
                    deviceId: deviceId
                )

                // Check if cancelled before processing result
                guard !Task.isCancelled else { return }

                switch result {
                case .success(let token, let userId):
                    auth.storeCredentials(token: token, userId: userId)
                    state = .success
                case .denied(let reason):
                    state = .error(reason)
                }
            } catch {
                // Don't show error if task was cancelled
                guard !Task.isCancelled else { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Go back to name input page
    func goBackToName() {
        state = .enteringName
        isNavigatingForward = false
        currentPage = 0
    }

    /// Cancel the pairing request and go back to address input
    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        state = .enteringAddress
        isNavigatingForward = false
        currentPage = 1
    }
}
