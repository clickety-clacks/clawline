# Clawline - Shared Development Guide

This file contains project-specific instructions shared by all AI assistants.

## Project Overview

Clawline is a native mobile chat app for communicating with Clawd assistants. It connects to a Clawdbot gateway via a custom WebSocket-based "Clawline provider."

**Platforms:** iOS, watchOS (Swift, SwiftUI)

**Key docs:**
- `docs/architecture.md` - Protocol spec, pairing flow, message formats
- `scratch/auth-flow-implementation.md` - Current implementation spec

## Xcode Build

Prefer XcodeBuildMCP if available. Otherwise:

```bash
# List iOS simulators
xcrun simctl list devices | grep -A 20 "iOS"

# Build for simulator
xcodebuild -project ios/Clawline/Clawline.xcodeproj -scheme Clawline \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Build and test
xcodebuild -project ios/Clawline/Clawline.xcodeproj -scheme Clawline \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

### Device Deployment

```bash
# 1) List devices
mcp__XcodeBuildMCP__list_devices

# 2) Build
xcodebuild -project ios/Clawline/Clawline.xcodeproj -scheme Clawline \
  -destination 'id=DEVICE-UDID' -configuration Debug build

# 3) Find app
find ~/Library/Developer/Xcode/DerivedData/Clawline-*/Build/Products/Debug-iphoneos \
  -name "*.app" -type d | head -1

# 4) Install & launch via MCP
```

## Architecture: Protocol-Based DI + Modern Swift Concurrency

**CRITICAL**: No singletons. All services are protocol-based and injected for testability.

### Modern Concurrency Rules

1. **Use `@Observable` (iOS 17+)**, NOT `ObservableObject` + `@Published`
2. **Use `AsyncStream`** for service → ViewModel data flow
3. **Only use Combine** for multicast, complex operators, or backpressure
4. **Be consistent** - don't mix paradigms (no AsyncStream + @Published)

### Core Protocols

| Protocol | Purpose |
|----------|---------|
| `AuthManaging` | Auth state, token storage |
| `ConnectionServicing` | WebSocket connection, pairing flow |
| `ChatServicing` | Message streaming via AsyncStream |

### Injection Pattern

```swift
import Observation

// Dependencies created at app root
@main
struct ClawlineApp: App {
    @State private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
        }
    }
}

// ViewModels use @Observable, take dependencies via init
@Observable
@MainActor
final class PairingViewModel {
    var state: PairingState = .idle
    var nameInput = ""

    private let auth: any AuthManaging
    private let connection: any ConnectionServicing

    init(auth: any AuthManaging, connection: any ConnectionServicing) {
        self.auth = auth
        self.connection = connection
    }
}

// Services expose AsyncStream for async data
protocol ChatServicing {
    var incomingMessages: AsyncStream<Message> { get }
    func send(content: String) async throws
}
```

### Testing

```swift
func testPairingSuccess() async {
    let mockAuth = MockAuthManager()
    let mockConnection = MockConnectionService(result: .success(...))
    let vm = PairingViewModel(auth: mockAuth, connection: mockConnection)

    await vm.submitName()
    XCTAssertTrue(mockAuth.isAuthenticated)
}
```

## Project Structure

```
ios/Clawline/Clawline/
├── ClawlineApp.swift
├── Models/
│   ├── Message.swift
│   └── PairingState.swift
├── Protocols/
│   ├── AuthManaging.swift
│   ├── ConnectionServicing.swift
│   └── ChatServicing.swift
├── Services/
│   ├── AuthManager.swift
│   ├── ChatService.swift
│   └── StubConnectionService.swift
├── ViewModels/
│   ├── PairingViewModel.swift
│   └── ChatViewModel.swift
└── Views/
    ├── RootView.swift
    ├── Pairing/
    └── Chat/
```
