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

## Architecture: Protocol-Based DI

**CRITICAL**: No singletons. All services are protocol-based and injected for testability.

### Core Protocols

| Protocol | Purpose |
|----------|---------|
| `AuthManaging` | Auth state, token storage |
| `ConnectionServicing` | WebSocket connection, pairing flow |
| `ChatServicing` | Message list, sending |

### Injection Pattern

```swift
// Dependencies created at app root
@main
struct ClawlineApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
        }
    }
}

// ViewModels take dependencies via init
@MainActor
final class PairingViewModel: ObservableObject {
    private let auth: any AuthManaging
    private let connection: any ConnectionServicing

    init(auth: any AuthManaging, connection: any ConnectionServicing) {
        self.auth = auth
        self.connection = connection
    }
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
