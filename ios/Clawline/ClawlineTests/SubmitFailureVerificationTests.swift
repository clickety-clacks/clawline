import Foundation
import Testing
@testable import Clawline

@MainActor
@Suite(.serialized)
struct SubmitFailureVerificationTests {
    @Test("Send stays blocked until transport is actually ready")
    func sendRequiresActualTransportReadiness() async throws {
        resetSubmitFailureVerificationPersistence()

        let auth = VerificationAuthManager()
        auth.storeCredentials(token: "jwt", userId: "user-transport-ready")
        let chatService = VerificationChatService()
        let viewModel = ChatViewModel(
            auth: auth,
            chatService: chatService,
            settings: SettingsManager(
                cartesiaKeyStore: CartesiaKeyStore(keychain: KeychainSecureStore())
            ),
            device: VerificationDevice(),
            uploadService: VerificationUploadService(),
            toastManager: ToastManager(),
            salientHighlightService: SalientHighlightService()
        )
        defer { viewModel.onDisappear(origin: "SubmitFailureVerificationTests") }

        await viewModel.activate(origin: "SubmitFailureVerificationTests")
        await viewModel.onAppear(origin: "SubmitFailureVerificationTests")
        viewModel.inputContent = NSAttributedString(string: "probe")

        for _ in 0..<100 {
            if chatService.startConnectionAttemptCallCount > 0,
               viewModel.sendButtonConnectionState != .reconnecting {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(chatService.startConnectionAttemptCallCount == 1)
        #expect(chatService.isTransportReadyForSend == false)
        #expect(viewModel.sendButtonConnectionState == .disconnected)
        #expect(viewModel.canSend == false)
    }

    @Test("Concurrent standalone callers join one direct connect attempt")
    func concurrentStandaloneCallersJoinOneDirectConnectAttempt() async throws {
        let connector = VerificationOverlapConnector(
            connectDelay: .milliseconds(80),
            authResultDelay: .milliseconds(20)
        )
        let baseURL = URL(string: "https://example.com")!
        let service = ProviderDirectChatClient(
            connector: connector,
            deviceId: "device_123",
            baseURLProvider: { baseURL }
        )

        async let firstConnect: Void = service.connect(token: "jwt", lastMessageId: nil)
        try await Task.sleep(forDuration: .milliseconds(10))
        async let secondConnect: Void = service.connect(token: "jwt", lastMessageId: nil)
        try await firstConnect
        try await secondConnect

        #expect(connector.connectCallCount == 1)
        #expect(connector.clients.count == 1)
        #expect(
            connector.clients.first?.sentTexts.filter { $0.contains(#""type":"auth""#) }.count == 1
        )
    }
}

@MainActor
private final class VerificationAuthManager: AuthManaging {
    var isAuthenticated: Bool = false
    var currentUserId: String?
    var token: String?
    var isAdmin: Bool = false

    func storeCredentials(token: String, userId: String) {
        self.token = token
        self.currentUserId = userId
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

private struct VerificationDevice: DeviceIdentifying {
    let deviceId = "device"
}

@MainActor
private final class VerificationUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String {
        let _ = data
        let _ = mimeType
        let _ = filename
        return "asset_0"
    }

    func download(assetId: String) async throws -> Data {
        let _ = assetId
        return Data()
    }
}

@MainActor
private final class VerificationChatService: ChatServicing {
    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var eventContinuation: AsyncStream<ChatServiceEvent>.Continuation?
    private var lifecycleContinuation: AsyncStream<LifecycleTransportEvent>.Continuation?

    private(set) var startConnectionAttemptCallCount = 0
    private var replayCursorBySessionKey: [String: String] = [:]
    var isTransportReadyForSend = false

    lazy var incomingMessages: AsyncStream<Message> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
        }
    }()

    lazy var connectionState: AsyncStream<ConnectionState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(.disconnected)
        }
    }()

    lazy var serviceEvents: AsyncStream<ChatServiceEvent> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }()

    lazy var lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent> = {
        AsyncStream { continuation in
            self.lifecycleContinuation = continuation
        }
    }()

    func connect(token: String, lastMessageId: String?) async throws {
        let _ = token
        let _ = lastMessageId
        isTransportReadyForSend = true
        stateContinuation?.yield(.connected)
    }

    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {
        let _ = lastMessageId
        let _ = token
        startConnectionAttemptCallCount += 1
        lifecycleContinuation?.yield(.init(epoch: epoch, payload: .transportOpened))
        lifecycleContinuation?.yield(
            .init(
                epoch: epoch,
                payload: .authResult(
                    success: true,
                    replayCount: 0,
                    replayTruncated: false,
                    historyReset: false,
                    failureReason: nil
                )
            )
        )
    }

    func stopConnectionAttempt() {}

    func disconnect() {
        isTransportReadyForSend = false
        stateContinuation?.yield(.disconnected)
    }

    func replayCursorSnapshot() -> [String: String] {
        replayCursorBySessionKey
    }

    func setReplayCursor(_ cursor: String?, for sessionKey: String) {
        if let cursor {
            replayCursorBySessionKey[sessionKey] = cursor
        } else {
            replayCursorBySessionKey.removeValue(forKey: sessionKey)
        }
    }

    func seedReplayCursorIfMissing(_ cursor: String?, for sessionKey: String) {
        guard replayCursorBySessionKey[sessionKey] == nil, let cursor else { return }
        replayCursorBySessionKey[sessionKey] = cursor
    }

    func clearReplayCursors() {
        replayCursorBySessionKey.removeAll()
    }

    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {
        try await send(
            id: id,
            content: content,
            attachments: attachments,
            sessionKey: sessionKey,
            references: []
        )
    }

    func send(
        id: String,
        content: String,
        attachments: [WireAttachment],
        sessionKey: String?,
        references: [MessageReferenceContext]
    ) async throws {
        let _ = id
        let _ = content
        let _ = attachments
        let _ = sessionKey
        let _ = references
        if !isTransportReadyForSend {
            throw ProviderChatService.Error.notConnected
        }
    }

    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {
        let _ = sourceMessageId
        let _ = action
        let _ = data
    }

    func fetchStreams() async throws -> [StreamSession] { [] }
    func fetchTrackableSessions() async throws -> [TrackableSession] { [] }
    func fetchOrgOptions() async throws -> OrgOptions { OrgOptions() }
    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus {
        let _ = sessionKey
        throw ProviderChatService.Error.notConnected
    }

    func applySessionControl(
        sessionKey: String,
        action: SessionControlAction,
        value: String?,
        enabled: Bool?
    ) async throws -> SessionControlResponse {
        let _ = sessionKey
        let _ = action
        let _ = value
        let _ = enabled
        throw ProviderChatService.Error.notConnected
    }

    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        let _ = displayName
        let _ = idempotencyKey
        throw ProviderChatService.Error.notConnected
    }

    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        let _ = sessionKey
        let _ = displayName
        throw ProviderChatService.Error.notConnected
    }

    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String {
        let _ = sessionKey
        let _ = idempotencyKey
        throw ProviderChatService.Error.notConnected
    }

    func adoptStream(sessionKey: String) async throws -> StreamSession {
        let _ = sessionKey
        throw ProviderChatService.Error.notConnected
    }

    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {}
}

@MainActor
private final class VerificationOverlapConnector: WebSocketConnecting {
    private let connectDelay: Duration
    private let authResultDelay: Duration
    private(set) var connectCallCount = 0
    private(set) var clients: [VerificationAutoAuthClient] = []

    init(connectDelay: Duration, authResultDelay: Duration) {
        self.connectDelay = connectDelay
        self.authResultDelay = authResultDelay
    }

    func connect(to url: URL) async throws -> any WebSocketClient {
        let _ = url
        connectCallCount += 1
        try await Task.sleep(forDuration: connectDelay)
        let client = VerificationAutoAuthClient(authResultDelay: authResultDelay)
        clients.append(client)
        return client
    }
}

@MainActor
private final class VerificationAutoAuthClient: WebSocketClient {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let authResultDelay: Duration

    private(set) var sentTexts: [String] = []
    private(set) var lastCloseInfo: WebSocketCloseInfo?

    init(authResultDelay: Duration) {
        self.authResultDelay = authResultDelay
        var continuation: AsyncStream<String>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var incomingTextMessages: AsyncStream<String> { stream }

    func send(text: String) async throws {
        sentTexts.append(text)
        guard text.contains(#""type":"auth""#) else { return }
        let continuation = self.continuation
        let delay = authResultDelay
        Task { @MainActor in
            try? await Task.sleep(forDuration: delay)
            continuation.yield(#"{ "type": "auth_result", "success": true, "replayCount": 0, "replayTruncated": false, "historyReset": false }"#)
        }
    }

    func close(with code: URLSessionWebSocketTask.CloseCode?) {
        lastCloseInfo = WebSocketCloseInfo(code: Int((code ?? .normalClosure).rawValue), reason: nil)
        continuation.finish()
    }
}

@MainActor
private func resetSubmitFailureVerificationPersistence() {
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys {
        if key.hasPrefix("clawline.lastServerMessageId.")
            || key.hasPrefix("clawline.lastStream")
            || key.hasPrefix("clawline.lastSessionKey")
            || key.hasPrefix("clawline.scrollState.v1.") {
            defaults.removeObject(forKey: key)
        }
    }

    let fileManager = FileManager.default
    guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return
    }
    let directoryURL = baseURL
        .appendingPathComponent("Clawline", isDirectory: true)
        .appendingPathComponent("MessageCache", isDirectory: true)
    try? fileManager.removeItem(at: directoryURL)
    let streamDirectoryURL = baseURL
        .appendingPathComponent("Clawline", isDirectory: true)
        .appendingPathComponent("StreamCache", isDirectory: true)
    try? fileManager.removeItem(at: streamDirectoryURL)
}
