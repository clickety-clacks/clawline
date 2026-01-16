# Clawline - Shared Development Guide

This file contains project-specific instructions shared by all AI assistants.

## Project Overview

Clawline is a native mobile chat app for communicating with Clawd assistants. It connects directly to a clawd process running the "Clawline provider" plugin (no gateway dependency).

**Platforms:** iOS (Swift, SwiftUI)

**Key docs:**
- `docs/architecture.md` - Protocol spec, pairing flow, message formats
- `docs/ios-architecture.md` - iOS auth flow + UI architecture

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

**CRITICAL: NO SINGLETONS.** No `shared` instances, no static `instance` properties, no global state. All dependencies must be injected via protocols for testability.

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
    private let uploadService: any UploadServicing

    init() {
        self.uploadService = UploadService(auth: authManager)
    }

    var body: some Scene {
        WindowGroup {
            RootView(uploadService: uploadService)
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

## Keyboard Positioning (DO NOT MODIFY WITHOUT UNDERSTANDING)

The keyboard positioning system in ChatView + MessageInputBar took **7+ iterations** to get right. It solves a non-obvious SwiftUI bug where views inside `.safeAreaInset` get recreated on geometry changes, silently resetting all `@State` and `@FocusState`.

**Working solution tags:**
- `working-keyboard-behaviors` - SwiftUI focus-based detection
- `keyboard-behaviors-documented` - Full documentation in code comments

**Key files:**
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift` - Owns keyboard state, applies offset
- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift` - Reports focus via callback

**The pattern:**
1. `@State isInputFocused` lives in ChatView (stable parent)
2. MessageInputBar reports focus changes via `onFocusChange` callback
3. Offset modifier applied in ChatView (modifiers on `.safeAreaInset` content DO update)

**Why "obvious" solutions fail:**
- `@State`/`@FocusState` in MessageInputBar resets when view recreates
- `onChange` in MessageInputBar may never fire (view recreates first)
- `.safeAreaInset` content body doesn't re-render on parent state change

**Before modifying keyboard handling:**
1. Read the header comments in both files
2. Understand SwiftUI view identity and state lifetime
3. Test on device with repeated keyboard show/hide
4. Verify concentric alignment visually

**DO NOT:**
- Move `@State isInputFocused` into MessageInputBar
- Replace the callback with `@Binding` or `@FocusState` propagation
- Apply offset inside MessageInputBar instead of ChatView

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

## Deployment Discipline

- **Never modify deployed artifacts directly.** All code changes (providers, plugins, scripts) must land in this repository first, pass tests, and then be redeployed to any remote host (e.g., `tars.local`). Editing files in `~/.clawd` or similar on the target machine is only acceptable for configuration, not source/binaries.
- Treat remote servers as release targets: rebuild locally (or via CI), copy the new build, and restart the service. This avoids “works on prod” drift and keeps the repo as the single source of truth.
