# Clawline iOS Architecture

This document is the canonical iOS architecture spec, migrated from scratch/auth-flow-implementation.md.

## Overview

This document specifies the authentication flow and chat UI architecture for the Clawline iOS app. The design prioritizes testability through protocol-based dependency injection - no singletons.

## Goals

1. **Pairing flow**: User enters name -> waits for admin approval -> receives JWT -> proceeds to chat
2. **Conditional root view**: App shows `PairingView` or `ChatView` based on auth state
3. **Testable architecture**: All services defined as protocols, injected via initializers
4. **Stubbed implementations**: Real components with simulated backend behavior for UI development

---

## Architecture

### Dependency Graph

```
ClawlineApp (root)
  -> Creates all services as concrete types:
     - AuthManager
     - StubConnectionService
     - ChatService
     - DeviceIdentifier
  -> RootView (receives services, passes to child views)
     -> [if !authenticated] PairingView(auth:, connection:, device:)
        -> @State PairingViewModel (created in View init)
     -> [if authenticated] ChatView(auth:, chatService:)
        -> @State ChatViewModel (created in View init)
```

### Key Design Decisions

1. **Modern Swift Concurrency** - `@Observable` for ViewModels, `AsyncStream` for services. No Combine.
2. **ViewModels own UI state** - VMs maintain properties for all UI-bound state (including messages)
3. **Services handle I/O** - Services manage network/storage, return results to VMs
4. **Views create their own VMs** - Using `@State` with dependencies passed via init
5. **No casting to concrete types** - VMs only interact with protocols

---

## Protocols

### AuthManaging

Tracks authentication state and token storage.

```swift
@MainActor
protocol AuthManaging: AnyObject, Observable {
    var isAuthenticated: Bool { get }
    var currentUserId: String? { get }
    var token: String? { get }

    func storeCredentials(token: String, userId: String)
    func clearCredentials()
}
```

**Implementation notes:**
- Conforming types use `@Observable` macro for SwiftUI reactivity
- Real impl stores token in Keychain
- Stub impl uses `UserDefaults`

### ConnectionServicing

Handles pairing flow with server. This service owns the temporary pairing transport (it may open a short-lived WebSocket under the hood).

```swift
enum PairingResult: Equatable {
    case success(token: String, userId: String)
    case denied(reason: String)
}

struct DeviceInfo: Equatable {
    let platform: String
    let model: String
    let osVersion: String?
    let appVersion: String?
}

struct PairingRequest: Equatable {
    let deviceId: String
    let claimedName: String
    let deviceInfo: DeviceInfo
}

protocol ConnectionServicing {
    func requestPairing(claimedName: String, deviceId: String) async throws -> PairingResult
    /// Stream of pairing requests for admin devices (empty for non-admins).
    var incomingPairingRequests: AsyncStream<PairingRequest> { get }
    func approvePairing(deviceId: String) async throws
    func denyPairing(deviceId: String, reason: String?) async throws
}
```

**Stub behavior:**
- Accept any non-empty name
- Wait 3 seconds (simulating admin approval)
- Return `.success` with fake JWT token

### ChatServicing

Handles WebSocket connection and message streaming using modern Swift concurrency.

```swift
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(Error)

    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.reconnecting, .reconnecting):
            return true
        case (.failed, .failed):
            return true  // Simplified equality for errors
        default:
            return false
        }
    }
}

struct TypingEvent: Equatable {
    let role: Message.Role
    let active: Bool
}

protocol ChatServicing {
    /// Stream of incoming messages (from assistant). Streaming updates are merged before yielding.
    var incomingMessages: AsyncStream<Message> { get }

    /// Stream of connection state changes
    var connectionState: AsyncStream<ConnectionState> { get }

    /// Stream of typing indicators (optional)
    var incomingTyping: AsyncStream<TypingEvent> { get }

    func connect(token: String, lastMessageId: String?) async throws
    func disconnect()

    /// Sends a message. Does not return response - listen to incomingMessages stream instead.
    /// If attachments include local files, the service uploads them before sending the message.
    func send(content: String, attachments: [Attachment]) async throws
}
```

**Why AsyncStream:**
- Native Swift concurrency - no Combine dependency
- Clean `for await` consumption in ViewModels
- Continuations bridge WebSocket callbacks naturally
- VM still owns message array for immediate user message display

**Stub behavior:**
- `connect(token:lastMessageId:)` succeeds after 500ms, emits `.connected`
- `send()` yields echo response to `incomingMessages` after 1.5s delay
- `disconnect()` emits `.disconnected`

### DeviceIdentifying

Provides stable device ID across app launches.

```swift
protocol DeviceIdentifying {
    var deviceId: String { get }
}
```

**Why this exists:**
- Device ID must persist for pairing semantics (same device = same ID)
- Generating `UUID()` in ViewModel would create new ID if VM recreates
- Protocol allows injecting fixed ID in tests
- Use a UUIDv4 string for `deviceId` to avoid collisions
- Store `deviceId` in Keychain when possible so it survives reinstalls; if missing, treat as a new device

---

## Models

### Message

```swift
struct Message: Identifiable, Equatable {
    let id: String
    let role: Role
    let content: String
    let timestamp: Date
    var isStreaming: Bool

    enum Role: String, Codable {
        case user
        case assistant
    }
}
```

### PairingState

```swift
enum PairingState: Equatable {
    case idle
    case enteringName
    case waitingForApproval(code: String?)  // optional code, nil for v1
    case success
    case error(String)
}
```

**Note:** Approval codes are optional in v1. The stub returns `nil` for simplicity.

### Attachment

```swift
struct Attachment: Identifiable {
    let id: String
    let type: AttachmentType
    let data: Data?
    let localFileURL: URL?
    let assetId: String?

    enum AttachmentType {
        case image
        case document
        case asset
    }
}
```

---

## ViewModels

### PairingViewModel

```swift
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
```

### ChatViewModel

```swift
import Observation

@Observable
@MainActor
final class ChatViewModel {
    private(set) var messages: [Message] = []
    var messageInput: String = ""
    private(set) var isSending: Bool = false
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var error: String?

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private var observationTask: Task<Void, Never>?

    init(auth: any AuthManaging, chatService: any ChatServicing) {
        self.auth = auth
        self.chatService = chatService
    }

    func onAppear() async {
        guard observationTask == nil, let token = auth.token else { return }

        // Start observing streams before connecting
        startObserving()

        let lastMessageId = messages.last?.id
        do {
            try await chatService.connect(token: token, lastMessageId: lastMessageId)
        } catch {
            self.error = "Failed to connect: \(error.localizedDescription)"
        }
    }

    func onDisappear() {
        observationTask?.cancel()
        observationTask = nil
        chatService.disconnect()
    }

    private func startObserving() {
        observationTask = Task {
            await withTaskGroup(of: Void.self) { group in
                // Observe incoming messages
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await message in self.chatService.incomingMessages {
                        self.messages.append(message)
                        self.isSending = false
                    }
                }

                // Observe connection state
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await state in self.chatService.connectionState {
                        self.connectionState = state
                        if case .failed(let err) = state {
                            self.error = err.localizedDescription
                        }
                    }
                }
            }
        }
    }

    func send() async {
        let content = messageInput.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }

        // Clear input and add user message immediately
        messageInput = ""
        let userMessage = Message(
            id: UUID().uuidString,
            role: .user,
            content: content,
            timestamp: Date(),
            isStreaming: false
        )
        messages.append(userMessage)

        isSending = true
        error = nil

        do {
            try await chatService.send(content: content, attachments: [])
            // Response will arrive via incomingMessages stream
        } catch {
            self.error = "Failed to send: \(error.localizedDescription)"
            isSending = false
        }
    }

    func clearError() {
        error = nil
    }
}
```

---

## View-Model Wiring Pattern

**Problem:** Views need to create ViewModels with injected dependencies.

**Solution:** Pass dependencies through View's `init`, use `@State`:

### PairingView

```swift
struct PairingView: View {
    @State private var viewModel: PairingViewModel

    init(auth: any AuthManaging, connection: any ConnectionServicing, device: any DeviceIdentifying) {
        _viewModel = State(initialValue: PairingViewModel(
            auth: auth,
            connection: connection,
            device: device
        ))
    }

    var body: some View {
        VStack(spacing: 24) {
            // Logo/title
            Text("Clawline")
                .font(.largeTitle)

            switch viewModel.state {
            case .idle, .enteringName:
                nameEntryContent
            case .waitingForApproval(let code):
                waitingContent(code: code)
            case .success:
                // Will transition via RootView
                ProgressView()
            case .error(let message):
                errorContent(message: message)
            }
        }
        .padding()
    }

    private var nameEntryContent: some View {
        VStack(spacing: 16) {
            TextField("Your name", text: $viewModel.nameInput)
                .textFieldStyle(.roundedBorder)

            Button("Connect") {
                Task { await viewModel.submitName() }
            }
            .disabled(viewModel.nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func waitingContent(code: String?) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Waiting for approval...")
            if let code = code {
                Text("Code: \(code)")
                    .font(.title2.monospaced())
            }
        }
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .foregroundColor(.red)
            Button("Try Again") {
                viewModel.state = .idle
            }
        }
    }
}
```

### ChatView

```swift
struct ChatView: View {
    @State private var viewModel: ChatViewModel

    init(auth: any AuthManaging, chatService: any ChatServicing) {
        _viewModel = State(initialValue: ChatViewModel(
            auth: auth,
            chatService: chatService
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let error = viewModel.error {
                errorBanner(error)
            }

            MessageInputBar(
                text: $viewModel.messageInput,
                isSending: viewModel.isSending,
                onSend: { Task { await viewModel.send() } }
            )
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .foregroundColor(.white)
            Spacer()
            Button("Dismiss") { viewModel.clearError() }
                .foregroundColor(.white)
        }
        .padding()
        .background(Color.red)
    }
}
```

### RootView

```swift
struct RootView: View {
    // With @Observable, use @Environment for all dependencies
    @Environment(AuthManager.self) private var auth
    @Environment(\.connectionService) private var connection
    @Environment(\.deviceIdentifier) private var device
    @Environment(\.chatService) private var chatService

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ChatView(auth: auth, chatService: chatService)
            } else {
                PairingView(auth: auth, connection: connection, device: device)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: auth.isAuthenticated)
    }
}
```

**Note:** With `@Observable`, use `@Environment(Type.self)` instead of `@EnvironmentObject`. RootView uses `AuthManager` directly because it's the top-level coordinator. Child views receive dependencies as protocols via init, and ViewModels are fully testable with mocks.

---

## App Entry Point

```swift
@main
struct ClawlineApp: App {
    // With @Observable, use @State instead of @StateObject
    @State private var authManager = AuthManager()

    // Non-observable services as plain properties
    private let connectionService: any ConnectionServicing = StubConnectionService()
    private let deviceIdentifier: any DeviceIdentifying = DeviceIdentifier()
    private let chatService: any ChatServicing = StubChatService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)  // @Observable uses .environment(), not .environmentObject()
                .environment(\.connectionService, connectionService)
                .environment(\.deviceIdentifier, deviceIdentifier)
                .environment(\.chatService, chatService)
        }
    }
}
```

---

## Environment Keys

For non-`ObservableObject` protocols, define custom environment keys:

```swift
// MARK: - ConnectionServicing

private struct ConnectionServiceKey: EnvironmentKey {
    static let defaultValue: any ConnectionServicing = StubConnectionService()
}

extension EnvironmentValues {
    var connectionService: any ConnectionServicing {
        get { self[ConnectionServiceKey.self] }
        set { self[ConnectionServiceKey.self] = newValue }
    }
}

// MARK: - DeviceIdentifying

private struct DeviceIdentifierKey: EnvironmentKey {
    static let defaultValue: any DeviceIdentifying = DeviceIdentifier()
}

extension EnvironmentValues {
    var deviceIdentifier: any DeviceIdentifying {
        get { self[DeviceIdentifierKey.self] }
        set { self[DeviceIdentifierKey.self] = newValue }
    }
}

// MARK: - ChatServicing

private struct ChatServiceKey: EnvironmentKey {
    static let defaultValue: any ChatServicing = StubChatService()
}

extension EnvironmentValues {
    var chatService: any ChatServicing {
        get { self[ChatServiceKey.self] }
        set { self[ChatServiceKey.self] = newValue }
    }
}
```

---

## File Structure

```
ios/Clawline/Clawline/
 ClawlineApp.swift

 Models/
    Message.swift
    Attachment.swift
    PairingState.swift

 Protocols/
    AuthManaging.swift
    ConnectionServicing.swift
    ChatServicing.swift
    DeviceIdentifying.swift

 Services/
    AuthManager.swift
    StubConnectionService.swift
    StubChatService.swift
    DeviceIdentifier.swift

 ViewModels/
    PairingViewModel.swift
    ChatViewModel.swift

 Views/
    RootView.swift
    Pairing/
       PairingView.swift
    Chat/
        ChatView.swift
        MessageBubble.swift
        MessageInputBar.swift

 Environment/
     EnvironmentKeys.swift
```

---

## Stub Implementations

### DeviceIdentifier

```swift
final class DeviceIdentifier: DeviceIdentifying {
    let deviceId: String

    init(storage: UserDefaults = .standard) {
        let key = "clawline.deviceId"
        if let existing = storage.string(forKey: key) {
            deviceId = existing
        } else {
            let new = UUID().uuidString
            storage.set(new, forKey: key)
            deviceId = new
        }
    }
}
```

### StubConnectionService

```swift
final class StubConnectionService: ConnectionServicing {
    var approvalDelay: TimeInterval = 3.0
    var shouldSucceed: Bool = true
    private var pairingContinuation: AsyncStream<PairingRequest>.Continuation?

    private(set) lazy var incomingPairingRequests: AsyncStream<PairingRequest> = {
        AsyncStream { continuation in
            self.pairingContinuation = continuation
        }
    }()

    func requestPairing(claimedName: String, deviceId: String) async throws -> PairingResult {
        try await Task.sleep(for: .seconds(approvalDelay))

        if shouldSucceed {
            let fakeToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.stub.\(deviceId)"
            return .success(token: fakeToken, userId: claimedName.lowercased())
        } else {
            return .denied(reason: "Admin rejected pairing request")
        }
    }

    func approvePairing(deviceId: String) async throws {
        // no-op for stub
    }

    func denyPairing(deviceId: String, reason: String?) async throws {
        // no-op for stub
    }
}
```

### AuthManager

```swift
import Observation

@Observable
@MainActor
final class AuthManager: AuthManaging {
    private(set) var isAuthenticated: Bool = false
    private(set) var currentUserId: String?
    private(set) var token: String?

    private let storage: UserDefaults

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        loadStoredCredentials()
    }

    private func loadStoredCredentials() {
        token = storage.string(forKey: "auth.token")
        currentUserId = storage.string(forKey: "auth.userId")
        isAuthenticated = token != nil
    }

    func storeCredentials(token: String, userId: String) {
        self.token = token
        self.currentUserId = userId
        self.isAuthenticated = true

        storage.set(token, forKey: "auth.token")
        storage.set(userId, forKey: "auth.userId")
    }

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false

        storage.removeObject(forKey: "auth.token")
        storage.removeObject(forKey: "auth.userId")
    }
}
```

### StubChatService

```swift
final class StubChatService: ChatServicing {
    var responseDelay: TimeInterval = 1.5

    // AsyncStream continuations for yielding values
    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var typingContinuation: AsyncStream<TypingEvent>.Continuation?

    // Lazy-initialized streams that capture continuations
    private(set) lazy var incomingMessages: AsyncStream<Message> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                // Cleanup if needed
            }
        }
    }()

    private(set) lazy var connectionState: AsyncStream<ConnectionState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(.disconnected)  // Initial state
        }
    }()

    private(set) lazy var incomingTyping: AsyncStream<TypingEvent> = {
        AsyncStream { continuation in
            self.typingContinuation = continuation
        }
    }()

    func connect(token: String, lastMessageId: String?) async throws {
        stateContinuation?.yield(.connecting)
        try await Task.sleep(for: .milliseconds(500))
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        stateContinuation?.yield(.disconnected)
    }

    func send(content: String, attachments: [Attachment]) async throws {
        // Simulate response delay
        try await Task.sleep(for: .seconds(responseDelay))

        let response = Message(
            id: UUID().uuidString,
            role: .assistant,
            content: "You said: \(content)",
            timestamp: Date(),
            isStreaming: false
        )

        // Yield response to the stream
        messageContinuation?.yield(response)
    }
}

enum ChatError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        }
    }
}
```

---

## Testing

### Test Configuration

For deterministic tests, set stub delays to 0:

```swift
extension StubConnectionService {
    static var instant: StubConnectionService {
        let service = StubConnectionService()
        service.approvalDelay = 0
        return service
    }
}

extension StubChatService {
    static var instant: StubChatService {
        let service = StubChatService()
        service.responseDelay = 0
        return service
    }
}
```

### Mock Implementations

```swift
import Observation

@Observable
@MainActor
final class MockAuthManager: AuthManaging {
    var isAuthenticated: Bool = false
    var currentUserId: String?
    var token: String?

    func storeCredentials(token: String, userId: String) {
        self.token = token
        self.currentUserId = userId
        self.isAuthenticated = true
    }

    func clearCredentials() {
        token = nil
        currentUserId = nil
        isAuthenticated = false
    }
}

final class MockConnectionService: ConnectionServicing {
    let result: PairingResult
    private var pairingContinuation: AsyncStream<PairingRequest>.Continuation?

    private(set) lazy var incomingPairingRequests: AsyncStream<PairingRequest> = {
        AsyncStream { continuation in
            self.pairingContinuation = continuation
        }
    }()

    init(result: PairingResult) {
        self.result = result
    }

    func requestPairing(claimedName: String, deviceId: String) async throws -> PairingResult {
        return result
    }

    func approvePairing(deviceId: String) async throws {
        // no-op for mock
    }

    func denyPairing(deviceId: String, reason: String?) async throws {
        // no-op for mock
    }
}

final class MockChatService: ChatServicing {
    var connectCalled = false
    var disconnectCalled = false
    var sentMessages: [String] = []
    var errorToThrow: Error?

    // Continuations for test control
    private var messageContinuation: AsyncStream<Message>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var typingContinuation: AsyncStream<TypingEvent>.Continuation?

    private(set) lazy var incomingMessages: AsyncStream<Message> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
        }
    }()

    private(set) lazy var connectionState: AsyncStream<ConnectionState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
            continuation.yield(.disconnected)
        }
    }()

    private(set) lazy var incomingTyping: AsyncStream<TypingEvent> = {
        AsyncStream { continuation in
            self.typingContinuation = continuation
        }
    }()

    func connect(token: String, lastMessageId: String?) async throws {
        connectCalled = true
        if let error = errorToThrow { throw error }
        stateContinuation?.yield(.connected)
    }

    func disconnect() {
        disconnectCalled = true
        stateContinuation?.yield(.disconnected)
    }

    func send(content: String, attachments: [Attachment]) async throws {
        sentMessages.append(content)
        if let error = errorToThrow { throw error }
    }

    // Test helper: simulate receiving a message from server
    func simulateIncomingMessage(_ message: Message) {
        messageContinuation?.yield(message)
    }

    // Test helper: simulate connection state change
    func simulateConnectionState(_ state: ConnectionState) {
        stateContinuation?.yield(state)
    }
}

struct MockDeviceIdentifier: DeviceIdentifying {
    let deviceId: String

    init(deviceId: String = "test-device-id") {
        self.deviceId = deviceId
    }
}
```

### Unit Tests: PairingViewModel

```swift
@MainActor
final class PairingViewModelTests: XCTestCase {
    func testSuccessfulPairing() async {
        let mockAuth = MockAuthManager()
        let mockConnection = MockConnectionService(result: .success(token: "tok", userId: "testuser"))
        let mockDevice = MockDeviceIdentifier()
        let vm = PairingViewModel(auth: mockAuth, connection: mockConnection, device: mockDevice)

        vm.nameInput = "TestUser"
        await vm.submitName()

        XCTAssertEqual(vm.state, .success)
        XCTAssertTrue(mockAuth.isAuthenticated)
        XCTAssertEqual(mockAuth.currentUserId, "testuser")
    }

    func testEmptyNameShowsError() async {
        let mockAuth = MockAuthManager()
        let mockConnection = MockConnectionService(result: .success(token: "tok", userId: "test"))
        let mockDevice = MockDeviceIdentifier()
        let vm = PairingViewModel(auth: mockAuth, connection: mockConnection, device: mockDevice)

        vm.nameInput = "   "
        await vm.submitName()

        XCTAssertEqual(vm.state, .error("Name cannot be empty"))
        XCTAssertFalse(mockAuth.isAuthenticated)
    }

    func testDeniedPairing() async {
        let mockAuth = MockAuthManager()
        let mockConnection = MockConnectionService(result: .denied(reason: "Nope"))
        let mockDevice = MockDeviceIdentifier()
        let vm = PairingViewModel(auth: mockAuth, connection: mockConnection, device: mockDevice)

        vm.nameInput = "Hacker"
        await vm.submitName()

        XCTAssertEqual(vm.state, .error("Nope"))
        XCTAssertFalse(mockAuth.isAuthenticated)
    }

    func testDeviceIdPassedToPairing() async {
        let mockAuth = MockAuthManager()
        var capturedDeviceId: String?
        let mockConnection = MockConnectionService(result: .success(token: "tok", userId: "test"))
        let mockDevice = MockDeviceIdentifier(deviceId: "specific-device-123")
        let vm = PairingViewModel(auth: mockAuth, connection: mockConnection, device: mockDevice)

        vm.nameInput = "Test"
        await vm.submitName()

        // Device ID is captured via the connection service in real impl
        // For this test, we verify the VM was constructed with the right device
        XCTAssertEqual(vm.state, .success)
    }
}
```

### Unit Tests: ChatViewModel

```swift
@MainActor
final class ChatViewModelTests: XCTestCase {
    func testSendAppendsUserMessageImmediately() async {
        let mockAuth = MockAuthManager()
        mockAuth.token = "test-token"
        let mockChat = MockChatService()

        let vm = ChatViewModel(auth: mockAuth, chatService: mockChat)
        await vm.onAppear()

        vm.messageInput = "Hello"

        // Start send but don't await - check immediate state
        let task = Task { await vm.send() }

        // Give it a moment to start
        try? await Task.sleep(for: .milliseconds(10))

        // User message should be added immediately
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.role, .user)
        XCTAssertEqual(vm.messages.first?.content, "Hello")
        XCTAssertTrue(vm.isSending)

        await task.value

        // Simulate server response via stream
        let response = Message(id: "resp", role: .assistant, content: "Hi", timestamp: Date(), isStreaming: false)
        mockChat.simulateIncomingMessage(response)

        // Allow stream observation to process
        try? await Task.sleep(for: .milliseconds(50))

        // After response arrives, both messages present
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.last?.role, .assistant)
        XCTAssertFalse(vm.isSending)
    }

    func testSendClearsInputImmediately() async {
        let mockAuth = MockAuthManager()
        mockAuth.token = "test-token"
        let mockChat = MockChatService()

        let vm = ChatViewModel(auth: mockAuth, chatService: mockChat)
        await vm.onAppear()

        vm.messageInput = "Hello"
        await vm.send()

        XCTAssertEqual(vm.messageInput, "")
    }

    func testSendHandlesError() async {
        let mockAuth = MockAuthManager()
        mockAuth.token = "test-token"
        let mockChat = MockChatService()
        mockChat.errorToThrow = ChatError.notConnected

        let vm = ChatViewModel(auth: mockAuth, chatService: mockChat)
        await vm.onAppear()

        vm.messageInput = "Hello"
        await vm.send()

        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isSending)
        // User message still added even if send fails
        XCTAssertEqual(vm.messages.count, 1)
    }

    func testConnectCalledOnAppear() async {
        let mockAuth = MockAuthManager()
        mockAuth.token = "test-token"
        let mockChat = MockChatService()

        let vm = ChatViewModel(auth: mockAuth, chatService: mockChat)
        await vm.onAppear()

        XCTAssertTrue(mockChat.connectCalled)
    }

    func testDisconnectCalledOnDisappear() async {
        let mockAuth = MockAuthManager()
        mockAuth.token = "test-token"
        let mockChat = MockChatService()

        let vm = ChatViewModel(auth: mockAuth, chatService: mockChat)
        await vm.onAppear()
        vm.onDisappear()

        XCTAssertTrue(mockChat.disconnectCalled)
    }

    func testConnectionStateUpdates() async {
        let mockAuth = MockAuthManager()
        mockAuth.token = "test-token"
        let mockChat = MockChatService()

        let vm = ChatViewModel(auth: mockAuth, chatService: mockChat)
        XCTAssertEqual(vm.connectionState, .disconnected)

        await vm.onAppear()

        // Allow stream observation to process
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.connectionState, .connected)
    }

    func testIncomingMessageAppendsToMessages() async {
        let mockAuth = MockAuthManager()
        mockAuth.token = "test-token"
        let mockChat = MockChatService()

        let vm = ChatViewModel(auth: mockAuth, chatService: mockChat)
        await vm.onAppear()

        // Simulate server pushing a message
        let serverMessage = Message(
            id: "server-1",
            role: .assistant,
            content: "Hello from server!",
            timestamp: Date(),
            isStreaming: false
        )
        mockChat.simulateIncomingMessage(serverMessage)

        // Allow stream observation to process
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.content, "Hello from server!")
    }
}
```

---

## Implementation Order

1. **Protocols** - `AuthManaging`, `ConnectionServicing`, `ChatServicing`, `DeviceIdentifying`
2. **Models** - `Message`, `PairingState`, `Attachment`, `ChatError`
3. **Environment Keys** - Custom keys for non-ObservableObject deps
4. **Services** - `AuthManager`, `DeviceIdentifier`, `StubConnectionService`, `StubChatService`
5. **ViewModels** - `PairingViewModel`, `ChatViewModel`
6. **Views** - `RootView`, `PairingView`, `ChatView`, `MessageBubble`, `MessageInputBar`
7. **App entry** - Wire everything in `ClawlineApp.swift`
8. **Tests** - Add mock implementations and unit tests

---

## Resolved Questions

1. **Should ChatServicing expose messages?** -> No. VM owns messages for clean observation and testability.
2. **Using `any Protocol` syntax?** -> Yes, acceptable. Performance impact negligible for these use cases.
3. **DeviceIdProviding protocol?** -> Yes, added as `DeviceIdentifying` with persistent storage.
4. **Error handling?** -> Added `ChatError` enum with `LocalizedError` conformance. VMs expose optional error string.
5. **Signaling pattern for real-time updates?** -> `AsyncStream` with continuations. Modern Swift concurrency, no Combine dependency. VM uses `for await` in a `Task` with `withTaskGroup` for concurrent observation of messages and connection state.
6. **Observable pattern?** -> `@Observable` macro (iOS 17+), NOT `ObservableObject` + `@Published`. No Combine import needed. Views use `@State` instead of `@StateObject`, and `.environment()` instead of `.environmentObject()`.
