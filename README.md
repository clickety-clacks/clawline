# Clawline

A native iOS chat app for communicating with your [OpenClaw](https://github.com/openclaw/openclaw) assistant.

![Platform](https://img.shields.io/badge/platform-iOS%2026+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<!-- TODO: Add screenshot or demo GIF -->
<!-- ![Clawline Demo](docs/assets/demo.gif) -->

## What is OpenClaw?

[OpenClaw](https://github.com/openclaw/openclaw) is a personal AI assistant platform. Clawline gives you a dedicated mobile interface to chat with your OpenClaw instance — with slick native animations and media support.

## Features

- Native SwiftUI interface with smooth animations
- Real-time WebSocket messaging
- Media attachments (images, documents)
- Markdown rendering in messages
- Typing indicators
- Dark mode support
- Token-based authentication

## Requirements

- **Xcode**: 26.0 or later
- **iOS**: 26.0 or later (iPhone and iPad)
- **Swift**: 5.0
- **macOS**: Sequoia 15.0+ (for development)

## Getting Started

### Prerequisites

1. Install Xcode from the Mac App Store or [Apple Developer](https://developer.apple.com/xcode/)
2. Clone this repository:
   ```bash
   git clone https://github.com/clicketyclackety/clawline.git
   cd clawline
   ```

### Building the iOS App

1. Open the Xcode project:
   ```bash
   open ios/Clawline/Clawline.xcodeproj
   ```

2. Select your target device or simulator

3. Build and run (⌘R)

### Connecting to a Provider

Clawline connects to an OpenClaw provider via WebSocket. To pair:

1. Launch the app
2. Enter your provider URL (e.g., `https://your-openclaw-instance.example.com`)
3. Complete the pairing flow with your provider's approval

## Project Structure

```
clawline/
├── ios/Clawline/           # iOS app (Swift/SwiftUI)
│   ├── Clawline/
│   │   ├── Models/         # Data models (Message, Attachment, etc.)
│   │   ├── Views/          # SwiftUI views
│   │   ├── ViewModels/     # Observable view models
│   │   ├── Services/       # Chat service, upload service
│   │   ├── Networking/     # WebSocket client
│   │   ├── DesignSystem/   # Theme, components, flow layout
│   │   └── Protocols/      # Service protocols for DI
│   └── ClawlineTests/      # Unit tests
├── src/                    # Standalone React/Vite web client
├── dist/                   # Built web client output after npm run build
├── docs/                   # Protocol docs, design notes, SOPs
└── shared/                 # Assets, icons, API specs
```

## Architecture

### Design Principles

- **Client-specific implementations**: iOS stays native Swift/SwiftUI; the browser client is a standalone React/Vite app, not a cross-platform shell.
- **Protocol-oriented**: Shared provider contracts keep clients aligned while each platform owns its UI/runtime shape.
- **Reactive**: SwiftUI observation on iOS; React state/store ownership on web.
- **Offline-resilient**: Automatic reconnection with exponential backoff.

### Key Components

| Component | Description |
|-----------|-------------|
| `ChatViewModel` | Main state container for chat UI |
| `ProviderChatService` | WebSocket connection and message handling |
| `MessageFlowCollectionView` | UIKit collection view with flow layout |
| `MessageBubble` | SwiftUI bubble with markdown support |
| `ChatFlowTheme` | Typography, colors, and layout metrics |

### Communication Protocol

Clawline uses a WebSocket-based protocol with JSON messages:

- `auth` — Authentication with token
- `message` — Chat messages (user/assistant)
- `ack` — Message delivery confirmation
- `event` — Activity signals (typing indicators)
- `error` — Error responses

See [docs/architecture.md](docs/architecture.md) and [docs/ios-provider-connection.md](docs/ios-provider-connection.md) for the current protocol details.

## Web Client

This repository also contains the standalone React/Vite web client in `src/` with its build output in `dist/`.

```bash
npm install
npm run build
npm run preview -- --host 0.0.0.0 --port 4173
```

The web client is a separate browser app service. It should not be installed under OpenClaw or served from the Clawline provider `/www` route on port `18800`; it connects to the provider API/WebSocket instead. See [docs/sop/clawline-web-hosting.md](docs/sop/clawline-web-hosting.md).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding standards, and contribution guidelines.

### Development Model

**Trunk-based development** — all work lands on `main` directly.

- Coding agents each get an isolated git worktree (clean from `HEAD`), each on its own branch
- Agents commit in their worktree and push to `origin/main` as they work
- Conflicts stay small because everyone integrates continuously
- `~/src/clawline/` remains the canonical deployer baseline; create agent worktrees under `~/src/worktrees/` (for example: `git worktree add ~/src/worktrees/clawline-{agent-name} -b {agent-name}`) and tear them down with `git worktree remove`

Legacy note: workspaces created before 2026-02-14 used `cp -r`, so old `~/src/clawline-{name}/` directories may still exist as full repo copies (not worktrees). If you are in one, do not panic. Commit/push unstaged changes only when they are your own work; if they were inherited from a different agent, do not commit them and flag the owner to resolve. Then continue with worktree-based flow.

### Stability & Tags

`main` is always moving and may contain unverified work. **Tags mark stable points.**

- **`main` HEAD** = latest code (may be incomplete or untested on device)
- **Latest tag** = last verified-good build, tested on device

To get stable code:
```bash
# Latest tagged release
git checkout $(git describe --tags --abbrev=0)
```

Tags are created after on-device verification: `git tag v{YYYY-MM-DD}` (or a descriptive name).

### Running Tests

```bash
cd ios/Clawline
xcodebuild test -scheme Clawline -destination 'platform=iOS Simulator,name=iPhone 16'
```

## License

MIT — see [LICENSE](LICENSE) for details.

## Acknowledgments

- Design inspired by modern chat interfaces
