import Foundation
import Testing
@testable import Clawline

@Suite(.serialized)
struct ProviderTLSSessionIsolationTests {
    @Test("Factory returns distinct sessions and delegates for websocket, upload, and asset download")
    func factoryReturnsDistinctSessionsPerRole() {
        let sessionSpy = SessionBuilderSpy()
        let factory = ProviderTLSSessionFactory(
            policyProvider: { ProviderTLSPolicy(trustSelfSignedCertificates: true, pinnedLeafCertificateSHA256: nil) },
            notificationCenter: NotificationCenter(),
            sessionBuilder: sessionSpy.makeSession(configuration:delegate:)
        )

        let webSocket = factory.makeSession(for: .webSocket(connectTimeout: 20, resourceTimeout: 360))
        let upload = factory.makeSession(for: .upload)
        let assetDownload = factory.makeSession(for: .assetDownload)

        #expect(ObjectIdentifier(webSocket.session) != ObjectIdentifier(upload.session))
        #expect(ObjectIdentifier(webSocket.session) != ObjectIdentifier(assetDownload.session))
        #expect(ObjectIdentifier(upload.session) != ObjectIdentifier(assetDownload.session))
        #expect(webSocket.generation == upload.generation)
        #expect(upload.generation == assetDownload.generation)
        #expect(sessionSpy.delegates.count == 3)
        #expect(sessionSpy.delegates[0] is ProviderWebSocketTLSSessionDelegate)
        #expect(sessionSpy.delegates[1] is ProviderHTTPTLSSessionDelegate)
        #expect(sessionSpy.delegates[2] is ProviderHTTPTLSSessionDelegate)
        #expect(ObjectIdentifier(sessionSpy.delegates[1]) != ObjectIdentifier(sessionSpy.delegates[2]))
    }

    @Test("Same effective TLS policy write does not rotate generation")
    func sameEffectivePolicyWriteDoesNotRotateGeneration() {
        let originalTrust = ProviderTLSSettingsStore.trustSelfSignedCertificates
        let originalPinned = ProviderTLSSettingsStore.pinnedLeafCertificateSHA256
        defer {
            ProviderTLSSettingsStore.trustSelfSignedCertificates = originalTrust
            ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = originalPinned
        }

        ProviderTLSSettingsStore.trustSelfSignedCertificates = true
        ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = nil

        let factory = ProviderTLSSessionFactory()
        let baselineGeneration = factory.currentGeneration

        ProviderTLSSettingsStore.trustSelfSignedCertificates = true
        #expect(factory.currentGeneration == baselineGeneration)

        let fingerprint = String(repeating: "a1", count: 32)
        ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = fingerprint
        #expect(factory.currentGeneration == baselineGeneration + 1)

        ProviderTLSSettingsStore.pinnedLeafCertificateSHA256 = fingerprint.uppercased()
        #expect(factory.currentGeneration == baselineGeneration + 1)
    }

    @Test("Upload and asset download rotate independently after policy change")
    @MainActor
    func uploadAndAssetDownloadRotateIndependentlyAfterPolicyChange() async throws {
        let factory = TestTLSSessionFactory()
        let auth = TestAuthManager(token: "jwt")
        let service = UploadService(
            auth: auth,
            baseURLProvider: { URL(string: "https://example.com")! },
            tlsSessionFactory: factory
        )

        TestURLProtocol.requestHandler = { request in
            if request.url?.path == "/upload" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"assetId":"asset_1","mimeType":"image/png"}"#.utf8))
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("image-data".utf8))
        }
        defer { TestURLProtocol.requestHandler = nil }

        _ = try await service.upload(data: Data("hello".utf8), mimeType: "image/png", filename: "image.png")
        _ = try await service.upload(data: Data("hello".utf8), mimeType: "image/png", filename: "image.png")
        _ = try await service.download(assetId: "asset_1")
        _ = try await service.download(assetId: "asset_1")

        #expect(factory.makeCalls.filter { $0 == .upload }.count == 1)
        #expect(factory.makeCalls.filter { $0 == .assetDownload }.count == 1)

        factory.emitPolicyChange()

        _ = try await service.upload(data: Data("hello".utf8), mimeType: "image/png", filename: "image.png")
        _ = try await service.download(assetId: "asset_1")

        #expect(factory.makeCalls.filter { $0 == .upload }.count == 2)
        #expect(factory.makeCalls.filter { $0 == .assetDownload }.count == 2)
    }

    @Test("Websocket connector cancels active task and reconnects with a fresh session after policy change")
    func webSocketConnectorReusesFreshSessionAfterPolicyChange() async throws {
        let factory = TestTLSSessionFactory()
        let taskSpy = WebSocketTaskFactorySpy()
        let connector = URLSessionWebSocketConnector(
            connectTimeout: 20,
            resourceTimeout: 360,
            tlsSessionFactory: factory,
            webSocketTaskFactory: taskSpy.makeTask(session:request:)
        )
        let url = URL(string: "wss://example.com/ws")!

        let firstClient = try await connector.connect(to: url)

        #expect(factory.makeCalls.filter {
            if case .webSocket = $0 { return true }
            return false
        }.count == 1)
        #expect(taskSpy.tasks.count == 1)

        let firstSession = taskSpy.sessions[0]
        let firstTask = taskSpy.tasks[0]

        factory.emitPolicyChange()

        #expect(firstTask.cancelCount == 1)

        _ = try await connector.connect(to: url)

        #expect(factory.makeCalls.filter {
            if case .webSocket = $0 { return true }
            return false
        }.count == 2)
        #expect(taskSpy.sessions.count == 2)
        #expect(ObjectIdentifier(firstSession) != ObjectIdentifier(taskSpy.sessions[1]))
        firstClient.close(with: .normalClosure)
    }

    @Test("Websocket connector refreshes a cached session at task start when TLS generation has advanced")
    func webSocketConnectorRefreshesCachedSessionAtTaskStartWhenGenerationAdvances() async throws {
        let factory = TestTLSSessionFactory()
        let taskSpy = WebSocketTaskFactorySpy()
        let connector = URLSessionWebSocketConnector(
            connectTimeout: 20,
            resourceTimeout: 360,
            tlsSessionFactory: factory,
            webSocketTaskFactory: taskSpy.makeTask(session:request:)
        )
        let url = URL(string: "wss://example.com/ws")!

        let firstClient = try await connector.connect(to: url)
        factory.advanceGenerationBeforeNextTaskStart(for: .webSocket(connectTimeout: 20, resourceTimeout: 360))

        _ = try await connector.connect(to: url)

        #expect(factory.taskStartCalls.filter {
            if case .webSocket = $0 { return true }
            return false
        }.count == 2)
        #expect(factory.makeCalls.filter {
            if case .webSocket = $0 { return true }
            return false
        }.count == 2)
        #expect(taskSpy.sessions.count == 2)
        #expect(ObjectIdentifier(taskSpy.sessions[0]) != ObjectIdentifier(taskSpy.sessions[1]))
        firstClient.close(with: .normalClosure)
    }

    @Test("Upload and asset download refresh cached sessions at task start when TLS generation advances")
    @MainActor
    func uploadAndAssetDownloadRefreshCachedSessionsAtTaskStartWhenGenerationAdvances() async throws {
        let factory = TestTLSSessionFactory()
        let taskSpy = HTTPTaskFactorySpy()
        let auth = TestAuthManager(token: "jwt")
        let service = UploadService(
            auth: auth,
            baseURLProvider: { URL(string: "https://example.com")! },
            tlsSessionFactory: factory,
            dataTaskFactory: taskSpy.makeTask(session:request:completion:)
        )

        _ = try await service.upload(data: Data("hello".utf8), mimeType: "image/png", filename: "image.png")
        _ = try await service.download(assetId: "asset_1")

        factory.advanceGenerationBeforeNextTaskStart(for: .upload)
        factory.advanceGenerationBeforeNextTaskStart(for: .assetDownload)

        _ = try await service.upload(data: Data("hello".utf8), mimeType: "image/png", filename: "image.png")
        _ = try await service.download(assetId: "asset_1")

        #expect(factory.taskStartCalls.filter { $0 == .upload }.count == 2)
        #expect(factory.taskStartCalls.filter { $0 == .assetDownload }.count == 2)
        #expect(factory.makeCalls.filter { $0 == .upload }.count == 2)
        #expect(factory.makeCalls.filter { $0 == .assetDownload }.count == 2)
        #expect(taskSpy.sessions.count == 4)
        #expect(ObjectIdentifier(taskSpy.sessions[0]) != ObjectIdentifier(taskSpy.sessions[2]))
        #expect(ObjectIdentifier(taskSpy.sessions[1]) != ObjectIdentifier(taskSpy.sessions[3]))
    }
}

private final class SessionBuilderSpy {
    private(set) var delegates: [URLSessionDelegate] = []

    func makeSession(configuration: URLSessionConfiguration, delegate: URLSessionDelegate) -> URLSession {
        delegates.append(delegate)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

private final class TestTLSSessionFactory: ProviderTLSSessionFactoring {
    private(set) var currentGeneration = 0
    private(set) var makeCalls: [ProviderTLSSessionRole] = []
    private(set) var taskStartCalls: [ProviderTLSSessionRole] = []

    private var observers: [UUID: (Int) -> Void] = [:]
    private var rolesAdvancingAtTaskStart: [ProviderTLSSessionRole] = []

    func makeSession(for role: ProviderTLSSessionRole) -> ProviderTLSSessionHandle {
        makeCalls.append(role)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return ProviderTLSSessionHandle(session: session, generation: currentGeneration)
    }

    func withTaskStartBoundary<T>(
        for role: ProviderTLSSessionRole,
        current: ProviderTLSSessionHandle?,
        _ body: (_ handle: ProviderTLSSessionHandle, _ staleSession: URLSession?) throws -> T
    ) rethrows -> T {
        taskStartCalls.append(role)
        if let index = rolesAdvancingAtTaskStart.firstIndex(of: role) {
            rolesAdvancingAtTaskStart.remove(at: index)
            currentGeneration += 1
        }

        if let current, current.generation == currentGeneration {
            return try body(current, nil)
        }

        let handle = makeSession(for: role)
        return try body(handle, current?.session)
    }

    func addPolicyChangeObserver(_ observer: @escaping (Int) -> Void) -> ProviderTLSPolicyChangeObservation {
        let observation = ProviderTLSPolicyChangeObservation(id: UUID())
        observers[observation.id] = observer
        return observation
    }

    func removePolicyChangeObserver(_ observation: ProviderTLSPolicyChangeObservation) {
        observers.removeValue(forKey: observation.id)
    }

    func emitPolicyChange() {
        currentGeneration += 1
        let generation = currentGeneration
        observers.values.forEach { $0(generation) }
    }

    func advanceGenerationBeforeNextTaskStart(for role: ProviderTLSSessionRole) {
        rolesAdvancingAtTaskStart.append(role)
    }
}

private final class WebSocketTaskFactorySpy {
    private(set) var sessions: [URLSession] = []
    private(set) var tasks: [TestWebSocketTask] = []

    func makeTask(session: URLSession, request: URLRequest) -> any ProviderWebSocketTasking {
        sessions.append(session)
        let task = TestWebSocketTask(request: request)
        tasks.append(task)
        return task
    }
}

private final class TestWebSocketTask: ProviderWebSocketTasking {
    let request: URLRequest
    private let stream: AsyncStream<URLSessionWebSocketTask.Message>
    private let continuation: AsyncStream<URLSessionWebSocketTask.Message>.Continuation

    private(set) var resumeCount = 0
    private(set) var cancelCount = 0
    private(set) var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var closeReason: Data?

    init(request: URLRequest) {
        self.request = request
        var continuation: AsyncStream<URLSessionWebSocketTask.Message>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func resume() {
        resumeCount += 1
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = stream.makeAsyncIterator()
        guard let message = await iterator.next() else {
            throw CancellationError()
        }
        return message
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCount += 1
        self.closeCode = closeCode
        self.closeReason = reason
        continuation.finish()
    }
}

private final class HTTPTaskFactorySpy {
    private(set) var sessions: [URLSession] = []

    func makeTask(
        session: URLSession,
        request: URLRequest,
        completion: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> any ProviderHTTPTasking {
        sessions.append(session)
        let response: URLResponse
        let data: Data

        if request.url?.path == "/upload" {
            response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            data = Data(#"{"assetId":"asset_1","mimeType":"image/png"}"#.utf8)
        } else {
            response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            data = Data("image-data".utf8)
        }

        return TestHTTPTask {
            completion(data, response, nil)
        }
    }
}

private final class TestHTTPTask: ProviderHTTPTasking {
    private let onResume: () -> Void
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0

    init(onResume: @escaping () -> Void) {
        self.onResume = onResume
    }

    func resume() {
        resumeCount += 1
        onResume()
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class TestAuthManager: AuthManaging {
    var isAuthenticated: Bool { token != nil }
    var currentUserId: String? = "user"
    var token: String?
    var isAdmin = false

    init(token: String?) {
        self.token = token
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
    }
}

private final class TestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
