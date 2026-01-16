//
//  PairingViewModel.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation
import OSLog

private let pairingLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "PairingViewModel")

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
        if case .waitingForApproval(_, let stalled) = state,
           !stalled,
           pairingTask != nil {
            pairingLogger.debug("submitAddress ignored: pairing already in progress")
            return
        }

        pairingLogger.debug("submitAddress called (name: \(self.nameInput, privacy: .public), address: \(self.addressInput, privacy: .public))")
        guard let serverURL = normalizedWebSocketURL(from: addressInput) else {
            pairingLogger.error("submitAddress failed: invalid server URL from input \(self.addressInput, privacy: .public)")
            state = .error("Invalid server address")
            return
        }

        if let baseURL = providerBaseURL(from: serverURL) {
            ProviderBaseURLStore.setBaseURL(baseURL)
        }

        state = .waitingForApproval(code: nil, stalled: false)
        isNavigatingForward = true
        currentPage = 2

        // Cancel any existing task and start a new one
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pairingTask = nil }
            do {
                let result = try await self.connection.requestPairing(
                    serverURL: serverURL,
                    claimedName: self.nameInput,
                    deviceId: self.deviceId
                )

                // Check if cancelled before processing result
                guard !Task.isCancelled else { return }

                switch result {
                case .success(let token, let userId):
                    pairingLogger.debug("submitAddress success with userId \(userId, privacy: .public)")
                    self.auth.storeCredentials(token: token, userId: userId)
                    self.state = .success
                case .denied(let reason):
                    pairingLogger.warning("submitAddress denied: \(reason, privacy: .public)")
                    self.state = .error(reason)
                }
            } catch {
                // Don't show error if task was cancelled
                guard !Task.isCancelled else { return }
                if isPendingSocketClosure(error: error) {
                    pairingLogger.warning("submitAddress stalled while waiting: \(error.localizedDescription, privacy: .public)")
                    let code: String?
                    if case .waitingForApproval(let existingCode, _) = self.state {
                        code = existingCode
                    } else {
                        code = nil
                    }
                    self.state = .waitingForApproval(code: code, stalled: true)
                } else {
                    pairingLogger.error("submitAddress caught error: \(error.localizedDescription, privacy: .public)")
                    self.state = .error(error.localizedDescription)
                }
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

    func retryPendingPairing() {
        guard case .waitingForApproval(_, _) = state else { return }
        submitAddress()
    }

    func retryPendingIfNeeded() {
        guard case .waitingForApproval(_, let stalled) = state, stalled else { return }
        submitAddress()
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
    /// and normalizes it to a ws://…/ws (or wss://) URL, defaulting port 18800 and path /ws.
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
            components.port = 18800
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

    private func isPendingSocketClosure(error: Error) -> Bool {
        guard case .waitingForApproval(_, _) = state else { return false }
        if let providerError = error as? ProviderConnectionService.Error {
            switch providerError {
            case .socketClosed, .timeout:
                return true
            default:
                break
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .timedOut:
                return true
            default:
                break
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain &&
            error._code == CocoaError.fileReadUnknown.rawValue {
            return true
        }
        return true
    }
}
