import Foundation
import Observation
import Testing
@testable import Clawline

@MainActor
@Suite(.serialized)
struct ProviderTLSSessionIsolationTests {
    @Test("Factory returns distinct sessions for websocket, upload, and asset download")
    func factoryReturnsDistinctSessions() {
        let factory = ProviderTLSSessionFactory()
        let webSocket = factory.makeSession(
            role: .webSocket,
            timeoutIntervalForRequest: 20,
            timeoutIntervalForResource: 360
        ).session
        let upload = factory.makeSession(
            role: .upload,
            timeoutIntervalForRequest: 60,
            timeoutIntervalForResource: 600
        ).session
        let download = factory.makeSession(
            role: .assetDownload,
            timeoutIntervalForRequest: 60,
            timeoutIntervalForResource: 600
        ).session

        #expect(ObjectIdentifier(webSocket) != ObjectIdentifier(upload))
        #expect(ObjectIdentifier(webSocket) != ObjectIdentifier(download))
        #expect(ObjectIdentifier(upload) != ObjectIdentifier(download))
    }

    @Test("No-op TLS policy writes do not rotate upload or asset-download sessions")
    func noOpPolicyWriteDoesNotRotateSessions() async throws {
        try await withProviderTLSPolicyScope {
            let factory = CountingTLSSessionFactory()
            let auth = TLSIsolationAuthManager(token: "jwt")
            let uploadService = UploadService(auth: auth, tlsSessionFactory: factory)
            let assetDownloadService = AssetDownloadService(auth: auth, tlsSessionFactory: factory)

            uploadService.debugPrepareSessionForTesting()
            assetDownloadService.debugPrepareSessionForTesting()
            #expect(factory.makeSessionCallCount(for: .upload) == 1)
            #expect(factory.makeSessionCallCount(for: .assetDownload) == 1)

            let generationBeforeNoOp = ProviderTLSSettingsStore.policyGeneration
            ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = ""
            #expect(ProviderTLSSettingsStore.policyGeneration == generationBeforeNoOp)

            uploadService.debugPrepareSessionForTesting()
            assetDownloadService.debugPrepareSessionForTesting()
            #expect(factory.makeSessionCallCount(for: .upload) == 1)
            #expect(factory.makeSessionCallCount(for: .assetDownload) == 1)
        }
    }

    @Test("Real TLS policy changes rotate upload and asset-download sessions before new work")
    func realPolicyChangeRotatesHTTPSessions() async throws {
        try await withProviderTLSPolicyScope {
            let factory = CountingTLSSessionFactory()
            let auth = TLSIsolationAuthManager(token: "jwt")
            let uploadService = UploadService(auth: auth, tlsSessionFactory: factory)
            let assetDownloadService = AssetDownloadService(auth: auth, tlsSessionFactory: factory)

            uploadService.debugPrepareSessionForTesting()
            assetDownloadService.debugPrepareSessionForTesting()
            #expect(factory.makeSessionCallCount(for: .upload) == 1)
            #expect(factory.makeSessionCallCount(for: .assetDownload) == 1)

            ProviderTLSSettingsStore.trustSelfSignedCertificates = false

            uploadService.debugPrepareSessionForTesting()
            assetDownloadService.debugPrepareSessionForTesting()
            #expect(factory.makeSessionCallCount(for: .upload) == 2)
            #expect(factory.makeSessionCallCount(for: .assetDownload) == 2)
        }
    }

    @Test("Real TLS policy changes force websocket reconnects onto a fresh session")
    func realPolicyChangeRotatesWebSocketSession() async throws {
        try await withProviderTLSPolicyScope {
            let factory = CountingTLSSessionFactory()
            let connector = URLSessionWebSocketConnector(
                tlsSessionFactory: factory,
                connectTimeout: 20,
                resourceTimeout: 360
            )

            _ = try await connector.connect(to: URL(string: "wss://192.0.2.1/ws")!)
            #expect(factory.makeSessionCallCount(for: .webSocket) == 1)
            #expect(connector.debugHasActiveTaskForTesting())

            ProviderTLSSettingsStore.trustSelfSignedCertificates = false

            #expect(!connector.debugHasActiveTaskForTesting())

            _ = try await connector.connect(to: URL(string: "wss://192.0.2.1/ws")!)
            #expect(factory.makeSessionCallCount(for: .webSocket) == 2)
        }
    }

    @Test("Policy-change disconnects trigger websocket lifecycle reconnects on a fresh session")
    func policyChangeReconnectsWebSocketLifecycle() async throws {
        try await withProviderTLSPolicyScope {
            let factory = CountingTLSSessionFactory()
            let connector = URLSessionWebSocketConnector(
                tlsSessionFactory: factory,
                connectTimeout: 20,
                resourceTimeout: 360
            )
            let driver = WebSocketReconnectDriver(
                connector: connector,
                url: URL(string: "wss://192.0.2.1/ws")!
            )
            defer { Task { await driver.stop() } }

            await driver.start()
            for _ in 0..<100 {
                if factory.makeSessionCallCount(for: .webSocket) == 1 { break }
                try await Task.sleep(forDuration: .milliseconds(20))
            }
            #expect(factory.makeSessionCallCount(for: .webSocket) == 1)

            ProviderTLSSettingsStore.trustSelfSignedCertificates = false

            var reconnectCount = 0
            for _ in 0..<150 {
                reconnectCount = await driver.reconnectCount
                if reconnectCount == 1,
                   factory.makeSessionCallCount(for: .webSocket) == 2 {
                    break
                }
                try await Task.sleep(forDuration: .milliseconds(20))
            }

            #expect(reconnectCount == 1)
            #expect(factory.makeSessionCallCount(for: .webSocket) == 2)
        }
    }

    private func withProviderTLSPolicyScope(_ operation: () async throws -> Void) async throws {
        let originalTrust = ProviderTLSSettingsStore.trustSelfSignedCertificates
        let originalPinned = ProviderTLSSettingsStore.pinnedLeafCertificateSHA256
        ProviderTLSSettingsStore.trustSelfSignedCertificates = true
        ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = nil

        defer {
            ProviderTLSSettingsStore.trustSelfSignedCertificates = originalTrust
            ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = originalPinned
        }

        try await operation()
    }
}

@MainActor
private final class CountingTLSSessionFactory: ProviderTLSSessionFactoring {
    var currentGeneration: UInt64 {
        ProviderTLSSettingsStore.policyGeneration
    }

    var policyChangeNotificationName: Notification.Name {
        .providerTLSPolicyDidChange
    }

    private var makeSessionCounts: [ProviderTransportRole: Int] = [:]

    func makeSession(
        role: ProviderTransportRole,
        timeoutIntervalForRequest: TimeInterval,
        timeoutIntervalForResource: TimeInterval
    ) -> ProviderManagedSession {
        makeSessionCounts[role, default: 0] += 1

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = timeoutIntervalForResource
        return ProviderManagedSession(
            session: URLSession(configuration: configuration),
            generation: currentGeneration
        )
    }

    func makeSessionCallCount(for role: ProviderTransportRole) -> Int {
        return makeSessionCounts[role, default: 0]
    }
}

@Observable
private final class TLSIsolationAuthManager: AuthManaging {
    var token: String?
    var currentUserId: String? = "user"
    var isAdmin = false

    init(token: String?) {
        self.token = token
    }

    var isAuthenticated: Bool {
        token != nil
    }

    func storeCredentials(token: String, userId: String) {
        self.token = token
        self.currentUserId = userId
    }

    func updateAdminStatus(_ isAdmin: Bool) {
        self.isAdmin = isAdmin
    }

    func refreshAdminStatusFromToken() {}

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAdmin = false
    }
}

private actor WebSocketReconnectDriver {
    private let connector: URLSessionWebSocketConnector
    private let url: URL
    private var monitorTask: Task<Void, Never>?
    private var currentClient: (any WebSocketClient)?

    private(set) var reconnectCount = 0

    init(connector: URLSessionWebSocketConnector, url: URL) {
        self.connector = connector
        self.url = url
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        currentClient?.close(with: .goingAway)
        currentClient = nil
    }

    private func run() async {
        do {
            let firstClient = try await connector.connect(to: url)
            currentClient = firstClient

            var iterator = firstClient.incomingTextMessages.makeAsyncIterator()
            while !Task.isCancelled, await iterator.next() != nil {}

            guard !Task.isCancelled else { return }

            let secondClient = try await connector.connect(to: url)
            currentClient = secondClient
            reconnectCount = 1
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }
}
