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
    var nameInput: String = "" {
        didSet { persistNameInput() }
    }
    var addressInput: String = "" {
        didSet { persistAddressInput() }
    }

    /// Current page index for the horizontal scroll (0 = name, 1 = address, 2 = waiting)
    var currentPage: Int = 0

    /// Direction of the last page transition (true = forward/right, false = backward/left)
    var isNavigatingForward: Bool = true

    private let auth: any AuthManaging
    private let connection: any ConnectionServicing
    private let deviceId: String
    private let storage: UserDefaults
    private var pairingTask: Task<Void, Never>?

    init(auth: any AuthManaging,
         connection: any ConnectionServicing,
         device: any DeviceIdentifying,
         storage: UserDefaults = .standard) {
        self.auth = auth
        self.connection = connection
        self.deviceId = device.deviceId
        self.storage = storage
        self.nameInput = storage.string(forKey: StorageKeys.savedName) ?? ""
        self.addressInput = storage.string(forKey: StorageKeys.savedAddress) ?? ""
    }

    var isNameValid: Bool {
        !nameInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isAddressValid: Bool {
        normalizedWebSocketURL(from: addressInput) != nil
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
        guard let serverURL = normalizedWebSocketURL(from: addressInput) else {
            state = .error("Invalid server address")
            return
        }

        if let baseURL = providerBaseURL(from: serverURL) {
            ProviderBaseURLStore.setBaseURL(baseURL)
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

    /// Dismiss error and return to address input for retry
    func dismissError() {
        state = .enteringAddress
        isNavigatingForward = false
        currentPage = 1
    }

    private func providerBaseURL(from websocketURL: URL) -> URL? {
        guard var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            break
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Accepts very forgiving input (host, host:port, http/https/ws/wss URLs, with/without path)
    /// and normalizes it to a ws://…/ws (or wss://) URL, defaulting port 18792 and path /ws.
    private func normalizedWebSocketURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try to parse; if no scheme supplied, prepend ws:// to allow host:port/path parsing
        let initialString = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: initialString) else { return nil }

        // Normalize scheme
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            components.scheme = "ws"
        }

        // Default port
        if components.port == nil {
            components.port = 18792
        }

        // Ensure host exists
        guard components.host?.isEmpty == false else { return nil }

        // Normalize path to /ws
        let path = components.path
        if path.isEmpty || path == "/" {
            components.path = "/ws"
        } else if !path.hasSuffix("/ws") {
            components.path = path.hasSuffix("/") ? path + "ws" : path + "/ws"
        }

        // Strip query/fragment (not used by provider)
        components.query = nil
        components.fragment = nil

        return components.url
    }

    private func persistNameInput() {
        storage.set(nameInput, forKey: StorageKeys.savedName)
    }

    private func persistAddressInput() {
        storage.set(addressInput, forKey: StorageKeys.savedAddress)
    }

    private enum StorageKeys {
        static let savedName = "pairing.nameInput"
        static let savedAddress = "pairing.addressInput"
    }
}
