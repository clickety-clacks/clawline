//
//  PairingViewModelTests.swift
//  ClawlineTests
//

import Foundation
import Observation
import Testing
@testable import Clawline

struct PairingViewModelTests {
    @Test("Pairing input without scheme defaults to ws:// and /ws path")
    @MainActor
    func defaultsBareHostToPlainWebSocket() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoreProviderBaseURL = snapshotProviderBaseURL()
        defer { restoreProviderBaseURL() }

        let connection = RecordingConnectionService(result: .failure(MockPairingError.unexpected))
        let viewModel = PairingViewModel(
            auth: MockAuthManager(),
            connection: connection,
            device: MockDeviceIdentifier(),
            storage: defaults
        )

        viewModel.nameInput = "Mike"
        viewModel.submitName()
        viewModel.addressInput = "tars.tail4105e8.ts.net"
        viewModel.submitAddress()

        try await waitFor { connection.requestedURL != nil }
        #expect(connection.requestedURL?.absoluteString == "ws://tars.tail4105e8.ts.net:18800/ws")
    }

    @Test("Non-network pairing errors surface as error state, not stalled")
    @MainActor
    func nonNetworkErrorStaysError() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoreProviderBaseURL = snapshotProviderBaseURL()
        defer { restoreProviderBaseURL() }

        let connection = RecordingConnectionService(result: .failure(MockPairingError.unexpected))
        let viewModel = PairingViewModel(
            auth: MockAuthManager(),
            connection: connection,
            device: MockDeviceIdentifier(),
            storage: defaults
        )

        viewModel.nameInput = "Mike"
        viewModel.submitName()
        viewModel.addressInput = "ws://example.com:18800"
        viewModel.submitAddress()

        try await waitFor {
            if case .error = viewModel.state { return true }
            return false
        }

        switch viewModel.state {
        case .error(let message):
            #expect(message == MockPairingError.unexpected.localizedDescription)
        default:
            Issue.record("Expected error state, got \(viewModel.state)")
        }
    }

    @Test("Timeout/network failures still mark waiting state as stalled")
    @MainActor
    func networkTimeoutBecomesStalledWaiting() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoreProviderBaseURL = snapshotProviderBaseURL()
        defer { restoreProviderBaseURL() }

        let connection = RecordingConnectionService(result: .failure(URLError(.timedOut)))
        let viewModel = PairingViewModel(
            auth: MockAuthManager(),
            connection: connection,
            device: MockDeviceIdentifier(),
            storage: defaults
        )

        viewModel.nameInput = "Mike"
        viewModel.submitName()
        viewModel.addressInput = "ws://example.com:18800"
        viewModel.submitAddress()

        try await waitFor {
            if case .waitingForApproval(_, let stalled) = viewModel.state {
                return stalled
            }
            return false
        }

        switch viewModel.state {
        case .waitingForApproval(_, let stalled):
            #expect(stalled)
        default:
            Issue.record("Expected stalled waiting state, got \(viewModel.state)")
        }
    }
}

private func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "PairingViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func snapshotProviderBaseURL() -> () -> Void {
    let defaults = UserDefaults.standard
    let domainName = Bundle.main.bundleIdentifier ?? ""
    let existing = defaults.persistentDomain(forName: domainName)?["provider.baseURL"] as? String
    return {
        if let existing {
            defaults.set(existing, forKey: "provider.baseURL")
        } else {
            defaults.removeObject(forKey: "provider.baseURL")
        }
    }
}

private func waitFor(
    timeout: Duration = .seconds(1),
    poll: Duration = .milliseconds(10),
    condition: @escaping () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while !condition() {
        if clock.now >= deadline {
            throw MockPairingError.timeout
        }
        try await Task.sleep(forDuration: poll)
    }
}

@MainActor
@Observable
private final class MockAuthManager: AuthManaging {
    var isAuthenticated: Bool = false
    var currentUserId: String?
    var token: String?
    var isAdmin: Bool = false

    func storeCredentials(token: String, userId: String) {
        self.token = token
        currentUserId = userId
        isAuthenticated = true
    }

    func updateAdminStatus(_ isAdmin: Bool) {
        self.isAdmin = isAdmin
    }

    func refreshAdminStatusFromToken() {}

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false
        isAdmin = false
    }
}

private struct MockDeviceIdentifier: DeviceIdentifying {
    let deviceId: String = "pairing-tests-device"
}

private final class RecordingConnectionService: ConnectionServicing {
    private let lock = NSLock()
    private let result: Result<PairingResult, Error>
    private var capturedURL: URL?

    init(result: Result<PairingResult, Error>) {
        self.result = result
    }

    var requestedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedURL
    }

    func requestPairing(serverURL: URL, claimedName: String, deviceId: String) async throws -> PairingResult {
        lock.lock()
        capturedURL = serverURL
        lock.unlock()

        switch result {
        case .success(let pairingResult):
            return pairingResult
        case .failure(let error):
            throw error
        }
    }
}

private enum MockPairingError: Error, LocalizedError {
    case unexpected
    case timeout

    var errorDescription: String? {
        switch self {
        case .unexpected:
            return "Synthetic pairing failure"
        case .timeout:
            return "Timed out waiting for pairing task"
        }
    }
}
