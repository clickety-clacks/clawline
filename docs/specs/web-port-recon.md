# Clawline Web Port Recon

Date: 2026-03-30
Author: Codex
Status: Recon spec for feasibility study

## Scope and Method

This document is based on direct source inspection of the Clawline iOS/iPad codebase in `/Users/mike/src/clawline`, with emphasis on the main iOS target plus relevant companion targets when they affect architecture or shared behavior.

Primary source footprint inspected:

- Main iOS app target: 103 Swift source files, approximately 34.6k LOC
- Watch target: 16 Swift source files, approximately 4.3k LOC
- Spatial target: 2 Swift source files
- Main unit tests: 20 files
- UI tests: 2 files

Main target module distribution:

- `Views`: 21 files
- `Services`: 20 files
- `Models`: 20 files
- `DesignSystem`: 16 files
- `Protocols`: 7 files
- `Support`: 6 files
- `ViewModels`: 3 files
- `Settings`: 2 files
- `Networking`: 2 files

The dominant complexity is not pairing or raw transport. It is the chat surface: message orchestration, stream/session management, replay/reconnection semantics, message rendering, scroll restoration, rich attachments, and native view behavior.

This spec focuses on porting the full iOS/iPad app experience into a browser-delivered web app, likely React-based. Watch and spatial targets are covered only where they reveal business rules, shared protocol expectations, or future parity considerations.

## Executive Assessment

Porting Clawline to the web is feasible, but this is not a straightforward view rewrite. The portable parts are the product model, pairing/auth semantics, provider protocol behavior, stream/session lifecycle, attachment semantics, and much of the message presentation grammar. The expensive parts are the chat UI runtime, native rendering surfaces, native storage/security integrations, and platform-specific features such as watch relay, Siri intents, Apple Intelligence salience, and SwiftTerm-backed terminals.

Two conclusions matter most:

1. The server contract is portable enough for a web app.
2. The current client architecture is not portable as-is.

The web effort should therefore treat the existing iOS app as a behavioral reference, not as a source layout to imitate directly. A literal port of the `ChatViewModel` plus UIKit/SwiftUI presentation structure would carry over too much client-side coupling.

Rough sizing:

- MVP web client with pairing, auth, chat, streams, attachments, reconnect/replay, markdown/code/table rendering, settings, and basic link previews: 10-14 engineer-weeks
- Near-parity web client including terminal sessions, interactive HTML attachments, advanced unread/scroll behavior, richer keyboard behavior, and production hardening: 20-30 engineer-weeks

Those estimates assume:

- One experienced engineer with product context
- Existing provider APIs remain stable
- No server-side redesign is required
- Design polish is targeted, not pixel-perfect UIKit mimicry

## Current iOS Architecture Overview

### App Entry and Dependency Wiring

The app boots through `ClawlineApp.swift`, which creates and injects the major runtime services into SwiftUI environment values:

- `AuthManager`
- `SettingsManager`
- `DeviceIdentifier`
- `ProviderConnectionService`
- `ProviderChatService`
- `UploadService`
- `WatchConnectivityService`

`ClawlineCoreRuntimeServicesFactory` builds the transport and upload graph. `RootView` then decides whether the user sees pairing or chat, owns the shared `ToastManager`, creates `SalientHighlightService`, and lazily instantiates `ChatViewModel`.

Observations:

- Service construction is centralized at the app root, which is portable in principle.
- Runtime state ownership is split between environment injection, observable services, `NotificationCenter`, persistent stores, and a singleton `SessionRegistry`.
- The app already has a de facto dependency graph, but the chat domain is still too centralized inside `ChatViewModel`.

### State Management Pattern

The state model is a mix of:

- `@Observable` / `@MainActor` model objects
- SwiftUI environment injection
- `AsyncStream`-based event streams from services
- `NotificationCenter` for some command routing
- `UserDefaults` for lightweight persistence
- Keychain for auth/device identity
- JSON files under `Application Support` for message and stream caches
- Global singleton `SessionRegistry.shared` for stream registry concerns

This is not a single, clean state architecture. Instead, it is a layered but mixed system:

- Transport state lives in `ProviderChatService` and `ConnectionLifecycleCoordinator`
- Product state lives mostly in `ChatViewModel`
- Security/session state lives in `AuthManager`
- Theme/settings state lives in `SettingsManager`
- Durable caches live partly in disk JSON and partly in `UserDefaults`

For the web port, this mixed state ownership is the main architectural hazard. The port should preserve behavior while simplifying ownership boundaries.

### Data Flow

At a high level:

1. Pairing collects user name and server address.
2. `ProviderConnectionService` performs pairing over a WebSocket handshake.
3. `AuthManager` persists the returned token, user ID, and admin status.
4. `ProviderChatService` opens the authenticated chat WebSocket.
5. `ConnectionLifecycleCoordinator` manages connection phases, replay, and recovery.
6. `ChatViewModel` consumes transport events and owns all high-level conversation/stream UI state.
7. `MessagePresentation` plus markdown/rendering helpers transform raw messages into presentable parts.
8. SwiftUI/UIKit views render those parts with specialized native surfaces.

This architecture is portable conceptually. The implementation shape is not.

## Major Modules in the iOS App

### Pairing and Auth

Primary files:

- `ViewModels/PairingViewModel.swift`
- `Views/Pairing/PairingView.swift`
- `Services/AuthManager.swift`
- `Services/KeychainSecureStore.swift`
- `Services/ProviderBaseURLStore.swift`
- `Services/DeviceIdentifier.swift`
- `Services/ProviderConnectionService.swift`

Responsibilities:

- Three-step pairing UX
- URL normalization and provider endpoint derivation
- Pairing request/response handshake
- Keychain-backed auth persistence
- Device identity generation/persistence
- Provider TLS preferences and pinning settings

Portability:

- UX flow is portable
- Pairing handshake logic is portable
- Keychain implementation is not portable
- TLS trust/pinning behavior is only partly portable in browsers

### Core Chat Transport

Primary files:

- `Services/ProviderChatService.swift`
- `ViewModels/ConnectionLifecycleCoordinator.swift`
- `Networking/URLSessionWebSocketConnector.swift`
- `Networking/WebSocketClient.swift`
- `Services/StreamAPIClient.swift`

Responsibilities:

- Authenticated WebSocket session
- Replay cursor handling
- Reconnect/recovery lifecycle
- Message send/ack
- Typing and service events
- Stream snapshot/mutation events
- REST stream CRUD and adoption

Portability:

- Protocol logic is highly portable
- Browser TLS policy differences may require server-side cleanup
- AsyncStream broadcast mechanics need a different state/event implementation on web

### Chat Domain Orchestration

Primary file:

- `ViewModels/ChatViewModel.swift`

Responsibilities:

- Message state by session
- Active stream selection
- Optimistic send pipeline
- Attachment staging
- Read/unread markers
- Stream create/rename/delete/adopt/untrack
- Session provisioning state
- Disk cache management
- Scroll/read coupling with active stream state
- Scene lifecycle handling

Assessment:

- This file is the main product brain.
- It is also a god object.
- The web port should treat it as a behavior reference and split it into several domain stores/controllers.

### Message Presentation and Rendering

Primary files:

- `Models/MessagePresentation.swift`
- `Models/UnifiedMarkdownParser.swift`
- `Views/Chat/UnifiedMarkdownRenderer.swift`
- `Services/SalientHighlightService.swift`
- `Views/Chat/SalientHighlightApplier.swift`

Responsibilities:

- Break messages into presentable parts
- Parse markdown/code blocks/tables
- Detect special cases such as single-link and emoji-only messages
- Render attributed text
- Apply salience highlighting on supported devices

Portability:

- Message decomposition rules are portable
- iOS attributed-string rendering is not
- Apple Intelligence salience is not client-portable
- The browser needs its own markdown/render pipeline

### Chat UI Shell and Native Surfaces

Primary files:

- `Views/Chat/ChatView.swift`
- `Views/Chat/MessageFlowCollectionView.swift`
- `Views/Chat/MessageBubbleUIKitView.swift`
- `DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift`
- `DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift`
- `Views/Chat/ExpandedMessageSheet.swift`
- `Views/Chat/StreamManagerSheet.swift`
- `Views/Chat/ChannelToast.swift`

Responsibilities:

- Main chat screen composition
- Keyboard-aware layout
- Virtualized message list behavior
- Scroll restoration
- Bubble rendering
- Stream picker/popover
- Toasts, sheets, and overlays
- Attachment source pickers
- Debug overlay

Assessment:

- This is the most expensive area to port.
- The current implementation is deeply native and heavily optimized around UIKit/SwiftUI behavior.

### Rich Attachment Surfaces

Primary files:

- `Views/Chat/LinkPreviewView.swift`
- `Views/Chat/LinkCardUIKitView.swift`
- `Services/LinkCardMetadataFetcher.swift`
- `Views/Chat/InteractiveHTMLBubbleUIKitView.swift`
- `Views/Chat/TerminalBubbleUIKitView.swift`
- `Services/TerminalSessionService.swift`
- `Services/TerminalSessionConnectionPool.swift`
- `Models/TerminalSessionDescriptor.swift`
- `Models/InteractiveHTMLDescriptor.swift`

Responsibilities:

- In-bubble rich web preview
- OG metadata cards
- Embedded interactive HTML experiences
- Embedded terminal sessions

Assessment:

- Link cards port cleanly
- Full web previews need a new security model
- Interactive HTML and terminal sessions are feasible but materially expensive

### Settings and Theming

Primary files:

- `Settings/SettingsManager.swift`
- `Settings/SettingsView.swift`
- `DesignSystem/ChatFlowOrganic/Theme/ChatFlowTheme.swift`
- `Support/ClawlineTypography.swift`
- `Shaders/BackgroundEffect.swift`

Responsibilities:

- Appearance mode
- Font scaling
- Background effects
- TLS trust/self-signed preferences
- Debug overlay toggle

Portability:

- Theme tokens and settings map well to web
- Metal/SwiftUI shader effects need new implementations
- Certificate trust toggles are not browser-equivalent

### Platform Integrations

Primary files:

- `Intents/SiriSendMessageIntent.swift`
- `Services/WatchConnectivityService.swift`
- watch target services and UI
- spatial target app shell

Responsibilities:

- Siri/App Intent sending
- Watch relay
- Watch auth sync
- Watch-originated sends and callbacks
- Companion-device presence

Assessment:

- These are outside core web scope
- They should not block a web client
- They should be tracked as follow-on ecosystem decisions, not v1 requirements

## Feature Inventory

The inventory below focuses on user-facing behavior and the current iOS implementation approach.

| Feature | Current iOS implementation | Portability and notes |
| --- | --- | --- |
| Pairing flow | `PairingViewModel` + `PairingView`; 3-stage UI with auto-normalized provider address and pending/retry state | Portable; implement as route-based onboarding |
| Auth persistence | `AuthManager` with keychain + `UserDefaults` migration | Browser needs token storage redesign; provisional preference is secure cookies when the chosen topology allows them, else browser-held tokens with explicit risk acceptance |
| Device identity | `DeviceIdentifier` persisted in keychain/defaults | Portable concept; use generated UUID in local storage/IndexedDB |
| Provider URL and TLS settings | `ProviderBaseURLStore`; self-signed trust and fingerprint pinning | Base URL portable; browser cannot truly mirror self-signed trust or cert pinning |
| Root routing | `RootView` switches pairing vs chat | Portable; use router/guarded routes |
| Chat connection | `ProviderChatService` authenticated WebSocket | Portable |
| Replay/recovery lifecycle | `ConnectionLifecycleCoordinator` phases and backoff | Portable, but must be rebuilt explicitly |
| Message send/ack | `ChatViewModel` optimistic send with placeholder reconciliation | Portable and required |
| Slash commands | `/logout`, `/settings`, connection/debug commands interpreted client-side | Portable; good candidate for command palette abstraction |
| Typing indicators | Provider event handling in `ProviderChatService` and `ChatViewModel` | Portable |
| Stream/session switching | `uiSelectedSessionKey` vs `engineActiveSessionKey` split | iOS used this as a native performance optimization. Web should start with URL-owned selection only and add deferred activation only if profiling proves it necessary |
| Stream CRUD | `StreamAPIClient` + `ChatViewModel` + `StreamManagerSheet` | Portable |
| Adopt/untrack sessions | REST APIs plus `SessionRegistry` integration | Portable; should move to explicit domain store |
| Session provisioning state | `session_info`, snapshot handling, send eligibility states | Portable and important |
| Unread/read markers | Active-session reads plus per-session last-read persistence | Portable |
| Message disk cache | JSON files in app support | Replace with IndexedDB |
| Stream metadata cache | JSON files in app support | Replace with IndexedDB or local storage |
| Message list virtualization | Custom UIKit collection view | Reimplement using web virtualization library |
| Scroll restoration | Custom persisted offsets, anchors, unread anchoring | Reimplement; high-risk behavior area |
| Scroll-to-bottom affordance | Native overlay with draggable persisted detent | Portable; web can simplify initial version |
| Message rendering | `MessagePresentation` + markdown renderer + bubble views | Portable concept, new implementation |
| Markdown | Unified parser for mixed streaming markdown | Portable behavior, new parser/render path needed |
| Code blocks | Native text rendering + syntax highlighting support | Portable |
| Tables | Specialized parsing and rendering | Portable |
| Link cards | OG fetch + UIKit card | Portable; provisional preference is server-backed metadata fetch, but preview topology remains an explicit web decision |
| Inline web preview | `WKWebView` preview surface | Partially portable; security-sensitive |
| Images | Inline bubble rendering, paste, picker, upload/download | Portable |
| Documents/files | UIDocumentPicker + file attachment pipeline | Portable via `<input type=file>` and drag/drop |
| Pasted images | `UITextView` interception | Portable via paste event handling |
| Camera capture | Native sheet camera flow | Portable on supported browsers through file capture / media APIs |
| Photos library | `PhotosPicker` | Portable via file picker; no photo-library-native UX parity |
| Expanded message sheet | Dedicated message drill-in sheet | Portable |
| Interactive HTML attachments | `WKWebView` with CSP injection and callback bridge | Feasible with sandboxed iframe; needs new trust model |
| Terminal attachments | `SwiftTerm` + separate WebSocket session service/pool | Feasible with `xterm.js`; expensive |
| Haptics | UIKit feedback generators | Limited browser support; optional |
| Keyboard commands | App commands + text editor key handling | Portable, but browser/browser-OS conflicts must be handled |
| Background visual effects | SwiftUI shader backgrounds | Portable in CSS/WebGL/canvas, but not 1:1 |
| Appearance modes | Settings-backed theme selection | Portable |
| Font scaling | App-level scaling plus Dynamic Type integration | Portable using CSS variables and browser zoom-aware typography |
| Salience highlighting | `FoundationModels` on-device model + cache | Not directly portable in-browser; can be dropped, server-powered, or LLM-backed |
| Siri send intent | `AppIntent` that can send without foregrounding app | Not portable to browser in same form |
| Watch relay | `WatchConnectivityService` plus watch app transport | Not applicable to web v1 |
| Spatial target reuse | Thin reuse of shared app shell | Not relevant to web v1 |

## Platform Dependency Inventory

### Portable or Mostly Portable

- Provider wire protocol and message payloads
- Pairing handshake semantics
- Auth/session model
- Stream/session concepts
- Replay cursor concepts
- Message/attachment models
- Read/unread behavior
- Stream CRUD and adoption rules
- Markdown/table/code/link classification behavior
- Optimistic send and ack reconciliation
- Local caching concepts

### iOS-Only or Deeply Native

- Keychain storage
- `UserDefaults`/`Application Support` storage APIs
- SwiftUI environment and observation model
- UIKit collection view layout logic
- `UITextView`-backed editor behavior
- `keyboardLayoutGuide`
- `PhotosPicker`, `UIDocumentPicker`, native camera sheets
- `WKWebView` and `SFSafariViewController`
- `SwiftTerm`
- UIKit haptics
- `WatchConnectivity`
- `AppIntents`
- `FoundationModels`
- Metal/SwiftUI shader-backed backgrounds

### Browser Constraints that Affect Scope

- Browser TLS trust cannot mirror app-level self-signed certificate acceptance
- Leaf fingerprint pinning is not available to arbitrary web clients
- Token storage is weaker than keychain unless auth moves to cookie-backed web sessions
- Embedded arbitrary HTML must use stricter isolation than the native client
- Embedded terminal UX depends on browser focus and keyboard handling
- Mobile Safari and iPad browser keyboard behavior will differ from native iPad app behavior

## Current Architectural Risks Relevant to a Port

### 1. `ChatViewModel` Is Too Centralized

It owns transport-adjacent state, domain state, cache state, send state, attachment staging, active stream switching, unread/read logic, and screen-lifecycle handling. This is manageable in one native client, but it is the wrong shape for a clean web implementation.

Implication for web:

- Split into multiple stores/controllers
- Keep mutation seams explicit
- Avoid one large React store that recreates the same coupling

### 2. Message List Behavior Is a Product Feature, Not Just UI Plumbing

The iOS implementation spent thousands of lines on:

- staged materialization
- anchor compensation
- unread anchoring
- bottom inset behavior
- scroll restoration
- bubble sizing
- scroll-to-bottom affordances

Implication for web:

- Treat scroll behavior as product-critical
- Prototype the virtualized list early
- Do not leave this for end-stage polish

### 3. Native Rendering Surfaces Hide Real Port Cost

The current app relies on specialized native renderers for:

- rich attributed markdown
- `WKWebView` previews
- interactive HTML
- terminal sessions
- typed input with image interception

Implication for web:

- Rendering parity requires deliberate component and security design
- “Message bubble parity” is a full subsystem, not a component ticket

### 4. TLS and Trust UX Cannot Be Copied Literally

The app supports self-signed cert trust and optional fingerprint pinning. A browser app cannot give the user equivalent per-app trust behavior.

Implication for web:

- Either standardize on valid browser-trusted TLS
- Or introduce a proxy/gateway layer that terminates trusted TLS for the browser

### 5. Singleton and Notification-Based Seams Should Not Be Reproduced

`SessionRegistry.shared` and notification-based command paths are survivable in the current app but are poor portability anchors.

Implication for web:

- Replace them with typed domain stores and explicit actions

## Architecture

This section defines the real seams of the web client. The point is not to name containers. The point is to make clear why the boundaries exist, how they interact, and where future code belongs.

### Seam 1: Browser Deployment Boundary

Why this boundary exists:

- The browser cannot reproduce the iOS trust model. `ProviderBaseURLStore` and `URLSessionWebSocketConnector` can tolerate self-signed certificates and fingerprint pinning; the browser cannot.
- The browser auth surface is also different. A cookie-backed same-origin app, a token-backed direct client, and a gateway-brokered session each imply a different runtime shape.
- Because of that, deployment topology is not infrastructure trivia. It is the outermost architectural seam. Everything inside the app depends on it.

How it relates to the rest of the system:

- `auth-pairing` needs to know how auth is established.
- `transportMachine` needs to know where the main WebSocket actually terminates.
- `attachments`, `stream-management`, and `rich-surfaces` need to know whether they call provider endpoints directly or go through a gateway.
- The UI layer should not encode assumptions about direct-provider access if the deployment model has not been fixed.

Placement rule for future work:

- If a change affects TLS trust, auth cookies/tokens, same-origin assumptions, or WebSocket termination, it belongs at this boundary first.
- No feature module should silently work around unresolved deployment questions.

Deployment decisions that must be fixed or explicitly gated:

- direct browser-to-provider vs same-origin gateway/BFF
- cookie-backed vs token-backed vs gateway-brokered auth
- browser-trusted provider TLS vs trusted gateway termination

Framework implication:

- If the app is a pure browser client, a Vite-based SPA is a good fit.
- If auth, TLS termination, or socket brokering require a server boundary, use a server-capable React framework instead of forcing a pure SPA.

### Seam 2: Browser Runtime Boundary

Why this boundary exists:

- iOS scene lifecycle is not the browser runtime. On web, multiple tabs, visibility state, reload, focus, offline/online, and shared browser storage are architectural facts.
- If this seam is not explicit, implementers will accidentally mix per-tab behavior with shared browser persistence and mis-handle reconnect, reload, and read state.

Chosen runtime model:

- each browser tab is an independent client runtime
- each tab opens its own chat WebSocket, authenticates, replays, and maintains its own in-memory transport and projection state
- multiple tabs are allowed to diverge briefly in unread/read state the same way multiple native devices can diverge today

How it relates to the rest of the system:

- `transportMachine` is tab-local runtime state.
- `chatDomainStore` is tab-local projected state.
- URL-selected session is tab-local and may differ between tabs.
- `settingsStore` and persisted auth material may be shared through browser storage, but live socket and unread state are not coordinated across tabs.

Boundary rules:

- Hidden tabs may remain connected or reconnect on their own according to normal transport rules; there is no cross-tab socket suppression layer.
- Focus changes do not directly mutate read state; explicit read acknowledgement rules do.
- Reconnect always replays from the last committed cursor.
- A second tab is treated as another client instance, not as a subordinate mirror of the first tab.

Placement rule for future work:

- If the feature is about socket lifecycle, replay, unread, or selection inside one browser tab, keep it tab-local.
- If a future feature truly requires cross-tab coordination, justify it as a new browser-specific product requirement rather than assuming it belongs in the baseline client architecture.

### Seam 3: State Ownership Boundary

Why this boundary exists:

- The main failure mode in the iOS app is mixed ownership. `ChatViewModel` became too central because multiple concepts accumulated in one place without sharp mutation seams.
- The web port must fix that structurally, not cosmetically. The purpose of state boundaries is to ensure each product concept has one owner and one write path.

The authoritative ownership model is:

| Product concept | Single authoritative owner | Readers | Allowed mutation paths |
| --- | --- | --- | --- |
| Authenticated user/session presence | `authSessionStore` | router guards, transport machine, settings UI | pairing success, logout, auth refresh |
| Provider base URL and auth transport config | `authSessionStore` | pairing flow, transport machine, upload/terminal adapters | pairing success, settings edit, logout reset |
| Device/browser identity | `authSessionStore` persisted via browser storage adapter | transport machine | first-run generation, explicit reset |
| Transport phase (`idle`, `connecting`, `authenticating`, `replaying`, `live`, `recovering`, `failed`) | `transportMachine` | chat shell, diagnostics UI, send controls | transport reducer transitions only |
| Replay cursor advancement | `transportMachine` | chat projection hydrator, persistence layer | per-tab message commit path |
| Selected session | URL state | chat shell, stream UI, composer | router navigation only |
| Send eligibility / provisioning state | `chatDomainStore` | composer, stream UI, banners | session snapshot handling, stream mutations, server events |
| Stream metadata and ordering | `chatDomainStore` | stream management UI, chat shell, diagnostics | stream snapshot events, CRUD responses, adopt/untrack actions |
| Messages and optimistic send reconciliation | `chatDomainStore` | message list, expanded views, diagnostics | send pipeline, inbound events, replay hydrate, attachment hydrate |
| Read/unread projection | `chatDomainStore` | stream UI, document title/badge | explicit mark-read action, incoming assistant messages, stream switch rules |
| Draft text and staged attachments | chat-route local state | composer, attachment tray | local user input actions |
| Appearance/font/debug preferences | `settingsStore` | all modules | settings UI only |
| Global transient notifications | minimal notification service | app shell | explicit publish calls only |

How it relates to the rest of the system:

- All REST responses, socket events, and persistence hydration must converge through the owner listed above.
- No second mutable owner may be introduced “for convenience.”
- If a module only reads a concept, it does not gain mutation rights over it.

Placement rule for future work:

- Before adding new shared state, decide which existing owner it belongs to.
- If none fit, explain why a new owner is necessary in terms of mutation rights and failure mode, not in terms of “this felt cleaner.”

### Seam 4: Runtime Layers

Why this boundary exists:

- The app has four different kinds of work, and each fails for a different reason:
  - auth/bootstrap
  - live transport and chat projection
  - pure rendering
  - shared preferences
- Putting them in one layer would repeat the iOS mistake. Splitting them by runtime shape is the architecture.

The minimum shared runtime owners are:

- `authSessionStore`
- `transportMachine`
- `chatDomainStore`
- `settingsStore`

What is deliberately not an owner:

- no global `uiStore`
- no global `selectedSession` store
- no parallel `streamStore` and `chatStore` split unless real runtime pressure proves the single chat-domain owner is too broad

How it relates to the rest of the system:

- URL state owns selected session and route-addressable overlays.
- Chat-route local state owns drafts and staged attachments.
- Shared runtime owners own only cross-component, cross-event concepts with real product meaning.

Placement rule for future work:

- If the state only matters inside one route subtree, keep it local.
- If the state only exists to present a URL address, put it in the router.
- If the state is authoritative across events or reconnects within one tab, it belongs in one of the shared runtime owners for that tab.

### Seam 5: Route and Overlay Boundary

Why this boundary exists:

- Route changes mean navigational intent. Overlays mean contextual work that should not eject the user from the conversation.
- Chat apps feel wrong when settings or detail views force full-page navigation away from the active thread without good reason.

How it relates to the rest of the system:

- `/pair` owns first-run and no-session flows.
- `/chat/:sessionKey?` owns the active conversation context.
- Settings opens as a modal or drawer inside chat.
- Stream management and expanded message views may be route-backed overlays if deep-linking is useful, but they should not become separate full-page domains unless product requirements demand it.

Placement rule for future work:

- If the user is changing where they are in the app, use a route.
- If the user is performing contextual work anchored to the current conversation, use an overlay or route-backed overlay.

### Seam 6: Feature Modules

The feature split exists to separate different dependency shapes and mutation rights. A module boundary is real only if the code inside it changes for the same reason, depends on the same runtime inputs, and fails in the same way.

#### `auth-pairing`

Why this boundary exists:

- Everything here establishes or clears identity and provider connectivity before chat can begin.
- It is the only area allowed to create or destroy the authenticated session.
- Its failures are first-run bootstrap failures, not live chat failures.

How it relates to other modules:

- It writes into `authSessionStore`.
- It may start or stop transport indirectly through pairing or logout.
- It does not read or mutate live chat projection, unread state, or rendering rules.

Placement rule:

- If the code establishes identity, provider config, first-run auth recovery, or logout, it belongs here.
- If it assumes chat is already running, it does not.

#### `chat-runtime`

Why this boundary exists:

- This is the live shell. Everything in it reacts to transport phase, session activation, send eligibility, or chat projection changes.
- If the socket drops or replay starts, this whole area cares immediately. Things outside it should not.

How it relates to other modules:

- It reads `transportMachine`, `chatDomainStore`, URL-selected session state, and `settingsStore`.
- It composes `message-rendering`.
- It delegates uploads to `attachments`.
- It opens `stream-management`, `settings-appearance`, and `rich-surfaces`.
- It must not own explicit REST mutation workflows or secondary transports.

Placement rule:

- If the UI exists because chat is live right now, it belongs here.
- If it can render from static data with no awareness of transport or session activation, it belongs elsewhere.

#### `stream-management`

Why this boundary exists:

- This area mutates server state through explicit CRUD/adopt/untrack flows.
- Those flows fail and retry differently from live WebSocket-driven chat.
- Keeping them separate prevents REST mutation logic from contaminating the live chat shell.

How it relates to other modules:

- It reads stream metadata and provisioning state from `chatDomainStore`.
- It dispatches explicit mutation actions through typed HTTP modules, then the results flow back into `chatDomainStore`.
- It can be launched from `chat-runtime`, but `chat-runtime` should not own the workflows.

Placement rule:

- If the code creates, renames, deletes, adopts, untracks, reorders, or explains stream/session sendability, it belongs here.
- If it only reflects the currently active stream in the running chat shell, it belongs in `chat-runtime`.

#### `message-rendering`

Why this boundary exists:

- This is the pure transformation seam: message data in, UI out.
- It has no transport dependency, no mutation rights, and no server side effects.
- That purity is why it should be testable with fixtures alone.

How it relates to other modules:

- It reads normalized message and attachment data from `chatDomainStore`.
- It may consume theme tokens from `settings-appearance`.
- It must not open sockets, call REST endpoints, own uploads, or mutate chat state.

Placement rule:

- If the component should render identically from a static fixture whether the app is live or disconnected, it belongs here.
- If it needs a socket, HTTP mutation, upload progress, or transport awareness, it does not.

#### `attachments`

Why this boundary exists:

- Attachments introduce browser file APIs, paste/drop behavior, upload progress, hydration, and retry semantics.
- Those are side-effect boundaries distinct from both live chat runtime and pure rendering.

How it relates to other modules:

- It reads draft/composer context from `chat-runtime`.
- It dispatches staged attachment and upload completion events into `chatDomainStore`.
- It may call upload HTTP modules.
- It hands already-described attachment data to `message-rendering`.

Placement rule:

- If the code touches file inputs, paste/drop events, upload progress, asset hydration, or attachment retry behavior, it belongs here.
- If it only decides how a hydrated attachment should look, it belongs in `message-rendering`.

#### `rich-surfaces`

Why this boundary exists:

- This module owns features that bring their own runtime or trust boundary: terminal sockets, iframe sandboxing, postMessage bridges, and richer embedded surfaces.
- These are not ordinary message rendering concerns. They have independent lifecycle and security rules.

How it relates to other modules:

- It reads authoritative message and stream context from `chatDomainStore`.
- It may own secondary transports such as terminal connections or isolated iframe bridges.
- It is opened by `chat-runtime`, but `chat-runtime` must not manage its secondary lifecycle or sandbox policy.
- It may reuse primitives from `message-rendering` without inheriting mutation rights.

Placement rule:

- If the feature introduces a new transport, a new sandbox, a new security policy, or a new embedded runtime, it belongs here.
- If it is just another static rendering of normal message content, it belongs in `message-rendering`.

#### `settings-appearance`

Why this boundary exists:

- Settings and appearance are shared preferences, not conversation state.
- They should be editable from the chat shell without becoming part of live chat runtime.
- Their persistence and failure semantics differ from both transport state and message state.

How it relates to other modules:

- It reads and writes `settingsStore`.
- It may be opened from `chat-runtime`, but it should not know about transport internals.
- Other modules may consume theme tokens or preference values, but they must not own the editing workflow.

Placement rule:

- If the code edits shared appearance, font, or debug preferences, it belongs here.
- If it only consumes those values while doing another job, it stays in that other module.

Boundary enforcement rule:

- Ask first which runtime dependency the code reacts to: auth bootstrap, live transport, REST mutation, pure rendering, browser file APIs, secondary transports, or shared preferences.
- Ask second what state it is allowed to mutate.
- Ask third what failure mode defines it.

If those answers point to different modules, the code is spanning too many responsibilities and should be split before it lands.

### Seam 7: Live Transport, Explicit Mutations, and Pure Rendering

Why this boundary exists:

- Clawline has three fundamentally different behaviors that must not blur together:
  - live provider events over WebSocket
  - explicit server mutations over HTTP
  - pure message presentation
- Each of these has different timing, retry, and correctness rules.

How they relate:

- `transportMachine` owns the main socket, phase transitions, replay, and reconnect behavior for one tab.
- `chatDomainStore` projects those live events into user-visible message, stream, and unread state.
- `stream-management` and `attachments` issue explicit HTTP mutations where needed.
- `message-rendering` consumes already-authoritative projected data and renders it without side effects.

Rules:

- React components do not own the main WebSocket lifecycle.
- Provider events enter through reducer/state-machine inputs, not direct component mutation.
- Explicit CRUD or upload flows do not bypass the domain owner just because they start from a button click.
- Rendering code never becomes a side-effect owner just because a message type is “special.”

Placement rule for future work:

- If the code is about ordering, replay, reconnect, or transport correctness inside one tab, it belongs with `transportMachine`.
- If it is about explicit server mutation initiated by the user, it belongs with the responsible feature module and then flows back through the domain owner.
- If it is display only, it belongs in `message-rendering`.

### Seam 8: Persistence Boundary

Why this boundary exists:

- Persistence is not just caching. It is how reload, replay, offline transitions, and optimistic sends remain coherent.
- The app needs durable local state, but persisted state must not become a rival authority to live transport.

How it relates to the rest of the system:

- IndexedDB holds transcript snapshots, stream metadata snapshots, optimistic send journal, and optional attachment metadata.
- `localStorage` holds low-risk preferences and debug flags, not product-critical live chat truth.
- Provisional preference until topology/auth is fixed: if the chosen deployment allows secure cookies, prefer them; otherwise keep browser-held tokens outside general UI state.
- Replay cursor commit and message projection commit happen together so persisted state and live resume stay aligned.

Cache semantics:

- `live`: built from acknowledged transport events
- `hydrated`: restored before live replay completes
- `replaying`: being reconciled with the server
- `stale`: usable for immediate paint but not yet confirmed
- `failed`: restore or sync failed and the app must fall back to live recovery

Placement rule for future work:

- If local state exists only to make reload and recovery coherent, it belongs at this boundary.
- If local state is trying to answer product questions that already have a live owner elsewhere, it does not belong here.

### Seam 9: Accessibility, Security, and Styling as Architectural Constraints

Why this boundary exists:

- These are not post-build checks. They shape how the earlier seams must be implemented.
- Virtualized chat, embedded rich surfaces, and themeable dense UI all become wrong if these constraints are left until the end.

How they relate to the rest of the system:

- Accessibility constrains `chat-runtime`, `message-rendering`, and route/overlay design: keyboard flow, focus order, readable message ordering, font scaling, and announcements must work under virtualization and reconnect flows.
- Embedded-content security constrains `rich-surfaces`, `attachments`, and preview handling: interactive HTML stays inside sandboxed iframes with narrow postMessage bridges; terminal sessions own isolated auth and lifecycle; previews do not inherit ambient credentials casually.
- Styling is not a separate state owner. It is a consumer of `settingsStore` and shared design tokens. The web layer should translate `ChatFlowTheme` and typography roles into CSS variables and scoped component styles without reproducing native layout mechanics literally.

Placement rule for future work:

- If a proposed feature breaks keyboard flow, focus semantics, sandbox guarantees, or token-based theming, the architecture must be changed before the feature ships.
- Accessibility, security, and styling concerns may constrain a module boundary, but they do not justify inventing a parallel owner for the same product state.

## Test Strategy

The migration needs explicit testing layers from the start.

### Protocol and State Correctness

- Fixture tests for pairing/auth/chat payloads derived from current Swift behavior
- Reducer/state-machine tests for transport phase transitions and replay semantics
- Projection tests for unread/read rules, provisioning state, and optimistic send reconciliation

### Browser Runtime Behavior

- Independent-tab tests
- Reload/reconnect tests
- offline/online recovery tests
- duplicate-send prevention tests

### UI and Interaction

- Playwright tests for pair flow, chat send/receive, stream switching, attachment upload, and settings overlay behavior
- Scroll behavior tests for unread anchors, restore-on-reload, and scroll-to-bottom affordance logic
- Accessibility checks for keyboard flow, focus order, announcements, and scalable typography

### Rich Surface and Security

- Terminal lifecycle tests
- Interactive HTML sandbox contract tests
- visual regression or screenshot diff coverage for critical chat surfaces

Testing should follow the ownership model:

- transport bugs are caught at the state-machine layer
- projection bugs are caught at the domain-store layer
- browser/runtime bugs are caught in end-to-end automation

## Migration Strategy

### Phase 0: Contract Capture and Runtime Definition

Before major UI work, capture the behavior that the web client must preserve:

- pairing request/result payloads
- auth payload and token/cookie contract
- message payloads and ack semantics
- typing/service/session/stream event payloads
- replay cursor behavior
- stream CRUD payloads
- terminal session protocol
- upload API assumptions
- chosen browser runtime invariants for independent browser tabs

Deliverables:

- TypeScript protocol models
- fixture payloads captured from Swift behavior
- transport state-machine notes
- browser runtime invariant document

This is the only non-user-facing step in the high-level strategy. The detailed phase plan should still ensure each implementation phase yields a runnable app.

### Phase 1: Runnable Pairing and Text Chat

Build:

- pair flow
- auth bootstrap
- chat shell
- per-tab transport machine
- text send/receive
- basic stream selection
- baseline Playwright coverage

Include from the start:

- keyboard-operable composer
- settings as in-chat overlay, not full navigation
- basic accessibility announcements for connection/send state

### Phase 2: Session Fidelity and Durable Reload

Build:

- replay/recovery
- unread/read projection
- persisted transcript snapshots
- durable reload behavior
- reconnect/offline handling

### Phase 3: Rich Rendering and Common Attachments

Build:

- markdown/code/tables
- image/file attachments
- paste/drop/file-input flows
- link cards
- upload/download pipeline
- visual regression coverage for core message surfaces

### Phase 4: Stream Management and Chat-Surface Maturity

Build:

- create/rename/delete/adopt/untrack stream flows
- improved message list virtualization
- scroll restoration and unread anchors
- mobile Safari/iPad browser tuning
- accessibility pass on chat shell and stream management

### Phase 5: Advanced Rich Surfaces

Build:

- terminal sessions
- interactive HTML attachments
- richer embedded previews
- expanded message surfaces

Gate:

- Only proceed if these are confirmed product requirements.
- Their security constraints must be designed before implementation, not retrofitted after.

### Phase 6: Release Hardening

Build:

- cross-browser compatibility pass
- deeper failure-mode coverage
- production observability
- performance tuning
- final security review

## What Ports Cleanly, What Needs Reimplementation, What Should Be Dropped

### Ports Cleanly

- Pairing UX and logic
- Provider transport protocol
- Stream/session mental model
- Read/unread semantics
- Optimistic send/ack reconciliation
- Message and stream data models
- Most settings semantics
- Markdown/code/table/link/image/file behavior

### Needs Reimplementation

- Entire chat screen layout/runtime
- Message virtualization and scroll restoration
- Rich text editor/composer
- Message renderer and bubble system
- Terminal session rendering
- Interactive HTML rendering
- Persistent cache layer
- Theme/background implementation

### Likely Drop or Defer for v1

- Watch relay
- Siri/App Intent send path
- Apple Intelligence salience highlighting
- Exact native haptics parity
- Exact drag-detent behavior for scroll-to-bottom control
- Full inline web preview parity if security posture is unresolved

## Module-by-Module Complexity and Risk

| Module | Current iOS surface | Web complexity | Risk notes |
| --- | --- | --- | --- |
| Pairing and auth shell | Moderate | Medium | Easy UI, but browser auth model needs a decision |
| Provider WebSocket transport | High | Medium | Protocol is clear, but reconnect/replay semantics must be preserved exactly |
| Connection lifecycle coordinator | High | High | State machine bugs here will feel like data loss or phantom disconnects |
| Chat domain store | Very high | Very high | Current `ChatViewModel` must be decomposed carefully |
| Stream/session management | High | Medium | CRUD is straightforward; provisioning and adopted-session behavior add edge cases |
| Message list virtualization | Very high | Very high | Product-critical UX and one of the riskiest areas |
| Message rendering pipeline | High | High | Markdown, tables, streaming partial content, attachments all need exactness |
| Composer/input | Moderate | Medium | Basic textarea is easy; parity editor behavior is not |
| Attachments upload/download | Moderate | Medium | Browser file APIs are fine; camera/mobile UX requires testing |
| Link cards/previews | Moderate | Medium | Metadata cards are easy; embedded previews/security are harder |
| Interactive HTML attachments | Moderate | High | Main risk is sandboxing and callback bridge design |
| Terminal attachments | High | Very high | Requires xterm.js, separate transport handling, focus/resize/clipboard parity |
| Settings/theme | Low | Low | Straightforward except nonportable TLS settings |
| Background visuals | Low | Medium | Can be approximated without matching the native shader pipeline |
| Salience highlighting | Moderate | Medium | Needs product decision; no direct portable equivalent |
| Watch/Siri/platform extras | Moderate | Low for web v1 | Easy to omit from initial web scope |

## Recommended Product Decisions

### 1. Treat Browser TLS as a Product Constraint, Not a UI Detail

If the provider commonly uses self-signed certificates today, the web app needs an infrastructure answer. The iOS toggle-based trust model cannot be reproduced in-browser.

Recommendation:

- Require browser-trusted TLS for web
- Or add a browser-safe gateway/proxy layer

### 2. Aim for Behavioral Parity, Not Native UI Mimicry

Exact reproduction of the UIKit/SwiftUI chat surface will waste effort. Users need:

- stable streams
- correct reconnect behavior
- good rendering
- dependable message navigation
- usable composition and attachments

They do not need a literal re-creation of iOS keyboard/layout mechanics.

### 3. Defer the Hardest Rich Surfaces Unless They Are Core to Launch

Terminal sessions and interactive HTML are feasible, but they are responsible for a disproportionate amount of engineering and security complexity.

Recommendation:

- Confirm whether they are launch-critical
- If not, make them second-wave features

### 4. Rewrite Client State Boundaries Instead of Porting `ChatViewModel`

The web client should preserve behavior but adopt clearer owners:

- `authSessionStore` for identity and provider configuration
- `transportMachine` for connection and replay phase
- `chatDomainStore` for stream inventory, provisioning state, messages, cursors, and unread projection
- URL state plus route-local state for selected session, drafts, and other contextual UI concerns

This will make the web client easier to reason about and will also clarify future client parity work.

## Open Questions and Decision Points

1. Is the web app expected to match only the iOS/iPad app, or also absorb watch/spatial-adjacent behaviors over time?
2. Which deployment topology is approved: direct browser-to-provider, same-origin gateway/BFF, or another mediated path?
3. Which auth model is approved for the browser: secure cookies, browser-held tokens, or gateway-brokered session auth?
4. Will the web deployment require valid CA-trusted TLS end to end, or is a trusted gateway layer expected?
5. Are terminal session attachments launch-critical?
6. Are interactive HTML attachments launch-critical?
7. Is salience highlighting a must-have feature or a native-only enhancement that can be omitted?
8. Is a responsive mobile-web experience required to replace the iPad app in practice, or is desktop web the primary target?
9. Is offline read access required, or is durable reload plus reconnect sufficient?
10. Should link preview metadata be fetched in-browser or via a server-side preview service?
11. Will interactive HTML be treated as trusted content only, or must the browser client support untrusted embeds?

## Recommended Implementation Order

1. Resolve deployment topology, auth model, and TLS strategy.
2. Freeze and document the provider contract and browser runtime invariants.
3. Build the transport machine and a runnable pair-plus-text-chat slice.
4. Add replay, unread/read projection, and durable reload behavior.
5. Add rich rendering and common attachments.
6. Add stream-management flows and mature the chat surface.
7. Decide whether terminal and interactive HTML belong in the first release.
8. Run dedicated accessibility, browser-runtime, and embedded-content security passes before launch.

## Feasibility Conclusion

Clawline is portable to the web, but it is not a thin UI port. The server-facing protocol and product model are already strong enough to support a browser client. The cost sits in reconstructing the chat runtime with browser-native primitives and in deciding which native-only features deserve true parity.

The cleanest plan is:

- preserve the protocol and product semantics
- redesign the client state boundaries
- build the web app around explicit domain stores
- treat terminal and interactive HTML as gated scope decisions
- require deliberate answers on web auth and TLS before implementation begins

If those decisions are made up front, a React web client is a credible and maintainable next platform for Clawline.

## Implementation Appendix

### Appendix Scope and Source Hierarchy

This appendix is the implementer handoff layer for the web client. It is intentionally narrower than the recon sections above: it captures the behavior that an engineer must preserve, the contracts the engineer can code against, and the places where the current docs and the iOS implementation are not perfectly aligned.

Source order for implementation decisions:

1. `docs/architecture.md`, `docs/provider-architecture.md`, and `docs/implementation_details/*.md` are the product and architecture source of truth.
2. The iOS app is the example implementation and behavioral evidence.
3. If iOS differs from the docs, treat that as a mismatch to resolve explicitly. Do not silently port the iOS behavior.

Mismatch handling rule:

- If the mismatch is between a high-level guide and a newer implementation-details doc, prefer the implementation-details doc.
- If the mismatch is between older docs and both current iOS/provider behavior, treat the older doc as stale and call it out in implementation notes.
- If the mismatch changes user-visible product behavior and no newer doc resolves it, stop and get a product decision.

### Docs-vs-iOS Mismatch Table

This section is intentionally explicit. The web spec must not silently normalize these drifts.

| Area | Docs say | iOS does | Web spec decision |
| --- | --- | --- | --- |
| `stream_snapshot` ordering on auth | `docs/implementation_details/multi-stream.md` requires `stream_snapshot` before replayed messages | `docs/ios-provider-connection.md` is looser on ordering; iOS tolerates stream events arriving independently | The intended contract is still `stream_snapshot` before replay. The web client should code to that contract but remain tolerant of older/out-of-order behavior during migration. |
| Attachment/download contract | Older connection guide still documents large-file `type:"url"` attachments under `/www/media/...` | `WireAttachment.swift`, `Attachment.swift`, `UploadService.swift`, and provider docs use `assetId` plus authenticated `GET /download/:assetId` | Implement `asset` references and authenticated downloads. Treat `url` attachment docs as stale unless provider docs are intentionally reverted. |
| Replay cursor resume shape | Implementation-details docs require sending all per-stream cursors, not just the active cursor | `ProviderChatService.sendAuth` currently sends `lastMessageId` and has `replayCursorsBySessionKey` in the payload type but currently sets it `nil` | The web target should track per-stream cursors locally as the authoritative resume model. On auth/reconnect, send `replayCursorsBySessionKey` when supported and also send the minimum provider-compatible singular cursor when older provider behavior still requires it. |
| Pair pending state | `docs/ios-provider-connection.md` enumerates `pair_result` reasons, but does not foreground the transient pending shape | `ProviderConnectionService` explicitly treats `pair_result.reason == "pair_pending"` as a nonterminal wait state | Web pairing should support transient pending approval state and not misclassify it as a terminal denial. |
| Typing event stream scoping | Older guide examples show `typing` without `sessionKey` | Current iOS payload type accepts optional `sessionKey`, and the UI only surfaces typing when a session key is present | In a multi-stream web client, unscoped typing is ambiguous. Accept it on the wire for compatibility, but do not surface it unless a stream scope is available. |
| `session_info` / provisioning shape | Docs describe provisioning using `sessionKeys` and stream/session info events | Current iOS accepts both `sessionKeys` and `sessions: [{ stream, sessionKey }]` shapes | The web parser should accept both shapes. The normalized internal model remains a single provisioned `sessionKeys[]` list plus stream metadata inventory. |
| Browser connection topology | iOS connection guide assumes direct provider connection | Web architecture may require same-origin gateway/BFF because browser auth and TLS rules differ from native iOS | Treat this as a platform delta. The Phase 1 implementation is blocked on an explicit topology/auth/TLS decision. |

### Product Invariants and Decision Tables

#### Session, stream, and provisioning invariants

| Decision point | Rule | Why it exists |
| --- | --- | --- |
| Stream identity | `sessionKey` is the canonical stream identifier. There is no parallel `streamId` concept in the client. | The provider routes by session key. A second identifier would create drift between UI state and transport state. |
| Stream naming | Built-in streams keep provider-defined suffixes. Custom streams use `s_<8 lowercase hex>`. | This is the existing routing format and collision model. |
| Stream ordering | `orderIndex` gaps after deletes are preserved. The client must not renumber streams locally. | Delete stability matters more than visual contiguity. Renumbering would create write conflicts and false diffs. |
| Provisioning | The client may render unprovisioned stream shells from persisted state, but send is allowed only when the active session exists in `provisionedSessionKeys`. | Rendering history and mutating server state are different rights. |
| Stream deletion | Deletion is explicit client/server mutation, not TTL or archival. | The product does not currently define passive stream expiry. |

#### Connection, replay, and recovery invariants

| Situation | Required behavior | Why it exists |
| --- | --- | --- |
| Any connection phase transition | One transport state machine is the only writer. | Prevents reconnect loops and stale callback acceptance. |
| Reconnect intent while already connecting/authenticating/replaying/live | Ignore it. Do not queue a second reconnect. | Late duplicate intents caused historical reconnect churn. |
| Manual retry during recovery | Cancel backoff, reconnect immediately, reset delay to 1s, do not increment automatic retry count. | Manual retry is a user override, not another automatic failure. |
| Auth resume | Send the most recent processed server event cursor, not only the active stream cursor. | Replay is account-wide and per-stream; a single active cursor is insufficient. |
| Cache restore racing with live replay | Cache is gap-fill only. It must never overwrite or reorder live server state. | Late restores previously clobbered fresh replayed data. |
| History reset from server | Drop any local state beyond what the fresh replay delivered. | Server is authoritative after reset/truncation. |

#### Send, ack, and message reconciliation invariants

| Situation | Required behavior | Why it exists |
| --- | --- | --- |
| Outgoing user send | Create optimistic local message keyed by `c_*` client ID. | Preserves immediate feedback while waiting for provider echo. |
| `ack` received | Keep optimistic item as sending-resolved but do not replace it yet. Final replacement happens on echoed user message. | `ack` means accepted, not yet normalized into canonical timeline form. |
| Echoed user message from same device | Replace the optimistic local message with the echoed `s_*` message in place. | Every device should converge on the same canonical timeline entry. |
| Echoed user message from another device | Append normally. Do not try to reconcile it to a local optimistic item. | Client IDs are only device-local. |
| Retry before `ack` | Resend the same payload with the same client ID. | Provider treats duplicate client IDs as idempotent retries. |
| Retry after failed/missing final assistant output | Append a new outgoing message at the tail with a new client ID. Do not mutate the old failed message in place. | Retry is a new user action in the transcript, not a timeline rewrite. |
| Streaming assistant update | Merge by stable server `id` and update content in place until final `streaming:false` arrives. | Streaming is one message evolving, not repeated appends. |

#### Unread, read, and scroll invariants

| Situation | Required behavior | Why it exists |
| --- | --- | --- |
| Incoming assistant message in non-active stream | Mark stream unread. | Only assistant output in another stream should produce unread. |
| Initial hydrate, replay, or backfill | Must not create unread. | Reload and recovery are not new activity. |
| Selecting a stream | Clear unread and set read cursor to that stream's current tail. | The product is "mark all as read on visit," not per-scroll read tracking. |
| Typing indicator insertion | Does not count as unread. | Typing is transient affordance, not durable content. |
| `firstUnreadMessageId` | Set once when unread begins; keep stable until unread clears. | Prevents bouncing markers during list updates. |
| Viewport crossing of first unread | Crossing the viewport center on the first unread message both flashes and clears unread. | This is the existing read affordance behavior. |
| Scroll-to-bottom, auto-scroll, restore fallback | Use one shared "at bottom" threshold for all three decisions. | Multiple thresholds create contradictory scroll behavior. |

#### Connection state presentation invariants

| Transport phase | UI presentation | Notes |
| --- | --- | --- |
| live | connected | Composer active subject to provisioning rules |
| recovering / reconnecting | reconnecting | No separate heartbeat or "unresponsive" state |
| failed / disconnected | disconnected | Error banner stays removed; state is expressed in send affordance |

### Typed Protocol Appendix

The interfaces below are the implementation target for the browser client. Optional fields are marked with `?`. Where the docs and iOS differ, the interface includes the superset the parser should tolerate and the notes call out which fields are normative versus compatibility-only.

#### Common wire types

```ts
type SessionKey = string;
type DeviceId = string;
type UserId = string;
type ClientMessageId = `c_${string}`;
type ServerEventId = `s_${string}`;
type UnixMillis = number;

type JSONValue =
  | string
  | number
  | boolean
  | null
  | JSONValue[]
  | { [key: string]: JSONValue };

interface DeviceInfoWire {
  platform: string;
  model: string;
}

interface ClientDescriptorWire {
  id: string;
  features?: string[];
}

interface InlineImageAttachmentWire {
  type: "image";
  mimeType: string;
  data: string; // base64
}

interface AssetRefAttachmentWire {
  type: "asset";
  assetId: string;
}

type ClientAttachmentWire = InlineImageAttachmentWire | AssetRefAttachmentWire;

interface AttachmentMetadataWire {
  mimeType?: string;
  filename?: string;
  size?: number;
  width?: number;
  height?: number;
}

interface ServerAttachmentWire {
  id?: string;
  type: "image" | "asset" | "document";
  mimeType?: string;
  data?: string; // base64 when present
  assetId?: string;
  metadata?: AttachmentMetadataWire;
}

interface StreamSessionWire {
  sessionKey: SessionKey;
  displayName: string;
  kind: string;
  orderIndex: number;
  isBuiltIn: boolean;
  createdAt: UnixMillis;
  updatedAt: UnixMillis;
  adopted?: boolean;
  trackingMode?: "serverManaged" | "adopted";
}

interface SessionDescriptorWire {
  stream: string;
  sessionKey: SessionKey;
}
```

#### Main chat WebSocket: client to server

```ts
interface PairRequestEvent {
  type: "pair_request";
  protocolVersion: 1;
  deviceId: DeviceId;
  claimedName: string;
  deviceInfo: DeviceInfoWire;
}

interface PairDecisionEvent {
  type: "pair_decision";
  deviceId: DeviceId;
  approve: boolean;
  userId?: UserId;
}

interface AuthEvent {
  type: "auth";
  protocolVersion: 1;
  token: string;
  deviceId: DeviceId;
  lastMessageId?: ServerEventId | null;
  adoptedSessionKeys?: SessionKey[];
  replayCursorsBySessionKey?: Record<SessionKey, ServerEventId>;
  clientFeatures?: string[];
  client: ClientDescriptorWire;
}

interface OutboundMessageEvent {
  type: "message";
  id: ClientMessageId;
  content: string;
  attachments: ClientAttachmentWire[];
  sessionKey?: SessionKey;
}

interface OutboundTypingEvent {
  type: "typing";
  active: boolean;
  sessionKey?: SessionKey;
}

interface InteractiveCallbackEvent {
  type: "interactive-callback";
  messageId: ServerEventId;
  payload: {
    action: string;
    data?: JSONValue;
  };
}
```

Complex field notes:

| Event | Required fields | Optional/compatibility fields | Notes |
| --- | --- | --- | --- |
| `auth` | `type`, `protocolVersion`, auth credential, `deviceId`, `client.id` | `lastMessageId`, `adoptedSessionKeys`, `replayCursorsBySessionKey`, `client.features`, `clientFeatures` | Client tracks per-stream cursors locally. Send `replayCursorsBySessionKey` whenever the provider accepts it; also send the minimum compatible `lastMessageId` when older provider behavior still depends on a singular cursor. |
| `message` | `type`, `id`, `content`, `attachments` | `sessionKey` only if the provider allows a default session context | The browser client should always send `sessionKey` once multi-stream routing exists. |
| `interactive-callback` | `type`, `messageId`, `payload.action` | `payload.data` | This event is inferable from provider/iOS behavior, but only required if interactive HTML ships. |

Sample payloads:

```json
{
  "type": "pair_request",
  "protocolVersion": 1,
  "deviceId": "9F6A1A72-3FE2-4B89-87D8-95D813B01234",
  "claimedName": "Flynn MacBook",
  "deviceInfo": { "platform": "Web", "model": "Chrome 136" }
}
```

```json
{
  "type": "auth",
  "protocolVersion": 1,
  "token": "<jwt-or-gateway-session-token>",
  "deviceId": "9F6A1A72-3FE2-4B89-87D8-95D813B01234",
  "lastMessageId": "s_8c7d40d1",
  "adoptedSessionKeys": ["agent:main:clawline:flynn:s_91ab23ef"],
  "clientFeatures": ["terminal_bubbles_v1"],
  "client": {
    "id": "co.clicketyclacks.clawline.web",
    "features": ["terminal_bubbles_v1"]
  }
}
```

#### Main chat WebSocket: server to client

```ts
interface PairResultEvent {
  type: "pair_result";
  success: boolean;
  token?: string;
  userId?: UserId;
  reason?: string;
}

interface PairApprovalRequestEvent {
  type: "pair_approval_request";
  deviceId: DeviceId;
  claimedName: string;
  deviceInfo: DeviceInfoWire;
}

interface AuthResultEvent {
  type: "auth_result";
  success: boolean;
  userId?: UserId;
  sessionId?: string;
  isAdmin?: boolean;
  dmScope?: string;
  features?: string[];
  sessionKeys?: SessionKey[];
  sessions?: SessionDescriptorWire[];
  replayCount?: number;
  replayTruncated?: boolean;
  historyReset?: boolean;
  reason?: string;
}

interface ServerMessageEvent {
  type: "message";
  id: ServerEventId;
  role: "user" | "assistant";
  sender?: string;
  from?:
    | string
    | {
        name?: string;
        displayName?: string;
        id?: string;
        role?: string;
      };
  name?: string;
  content: string;
  timestamp: UnixMillis;
  streaming: boolean;
  deviceId?: DeviceId;
  sessionKey?: SessionKey;
  attachments?: ServerAttachmentWire[];
}

interface AckEvent {
  type: "ack";
  id: ClientMessageId;
}

interface ErrorEvent {
  type: "error";
  code: string;
  message?: string;
  messageId?: ClientMessageId;
}

interface UserInfoEvent {
  type: "user_info";
  userId: UserId;
  isAdmin: boolean;
}

interface TypingEvent {
  type: "typing";
  role?: "user" | "assistant";
  active: boolean;
  sessionKey?: SessionKey;
}

interface SessionInfoEvent {
  type: "session_info";
  userId?: UserId;
  isAdmin?: boolean;
  dmScope?: string;
  sessionKeys?: SessionKey[];
  sessions?: SessionDescriptorWire[];
}

interface StreamSnapshotEvent {
  type: "stream_snapshot";
  streams: StreamSessionWire[];
}

interface StreamCreatedEvent {
  type: "stream_created";
  stream: StreamSessionWire;
}

interface StreamUpdatedEvent {
  type: "stream_updated";
  stream: StreamSessionWire;
}

interface StreamDeletedEvent {
  type: "stream_deleted";
  sessionKey: SessionKey;
}

interface ActivityExtensionEvent {
  type: "event";
  event: "activity";
  payload: {
    isActive: boolean;
    sessionKey?: SessionKey;
  };
}
```

Complex field notes:

| Event | Required fields | Optional/compatibility fields | Notes |
| --- | --- | --- | --- |
| `pair_result` | `type`, `success` | `token`, `userId`, `reason` | Treat `reason:"pair_pending"` as a transient waiting state, not a terminal denial. |
| `auth_result` | `type`, `success` | `sessionId`, `features`, `sessionKeys`, `sessions`, replay metadata, `reason` | Accept both `sessionKeys` and `sessions` shapes. `sessionId` is diagnostic only and may be absent in current iOS handling. |
| `message` | `type`, `id`, `content`, `timestamp`, `streaming` | `sender`, `from`, `name`, `deviceId`, `sessionKey`, `attachments` | Parser should accept legacy sender metadata shapes, but the normalized client message model remains `role + sender? + sessionKey + attachments[]`. |
| `typing` | `type`, `active` | `role`, `sessionKey` | Ignore non-assistant roles. In multi-stream UI, do not surface typing without stream scope. |
| `event(activity)` | `type`, `event:"activity"`, `payload.isActive` | `payload.sessionKey` | This is currently consumed by iOS as an activity/typing analogue, but docs under-specify it. Keep it typed and isolated from core chat state. |

Sample payloads:

```json
{
  "type": "message",
  "id": "s_8c7d40d1",
  "role": "assistant",
  "content": "Still streaming",
  "timestamp": 1764133200000,
  "streaming": true,
  "sessionKey": "agent:main:clawline:flynn:main",
  "attachments": []
}
```

```json
{
  "type": "stream_snapshot",
  "streams": [
    {
      "sessionKey": "agent:main:clawline:flynn:main",
      "displayName": "Main",
      "kind": "main",
      "orderIndex": 0,
      "isBuiltIn": true,
      "createdAt": 1764133200000,
      "updatedAt": 1764133200000,
      "adopted": false
    }
  ]
}
```

#### HTTP control-plane surfaces

These are not speculative. They come directly from `StreamAPIClient` and current provider docs.

```ts
interface FetchStreamsResponse {
  streams: StreamSessionWire[];
}

interface FetchTrackableSessionsResponse {
  sessions: {
    sessionKey: SessionKey;
    displayName: string;
    updatedAt: UnixMillis;
    channel?: string;
    lastChannel?: string;
    lastTo?: string;
  }[];
}

interface CreateStreamRequest {
  idempotencyKey: string;
  displayName: string;
}

interface AdoptStreamRequest {
  sessionKey: SessionKey;
}

interface RenameStreamRequest {
  displayName: string;
}

interface DeleteStreamRequest {
  idempotencyKey?: string | null;
}

interface MutateStreamResponse {
  stream: StreamSessionWire;
}

interface DeleteStreamResponse {
  deletedSessionKey: SessionKey;
}
```

Required routes:

| Route | Method | Request | Response |
| --- | --- | --- | --- |
| `/api/streams` | `GET` | authenticated | `FetchStreamsResponse` |
| `/api/trackable-sessions` | `GET` | authenticated | `FetchTrackableSessionsResponse` |
| `/api/streams` | `POST` | `CreateStreamRequest` | `MutateStreamResponse` |
| `/api/streams/adopt` | `POST` | `AdoptStreamRequest` | `MutateStreamResponse` |
| `/api/streams/:sessionKey` | `PATCH` | `RenameStreamRequest` | `MutateStreamResponse` |
| `/api/streams/:sessionKey` | `DELETE` | `DeleteStreamRequest` | `DeleteStreamResponse` |

#### Terminal WebSocket

Only include these event names if the advanced rich-surface phase is in scope. The names below are directly inferable from `TerminalSessionService.swift`.

```ts
interface TerminalAuthEvent {
  type: "terminal_auth";
  protocolVersion: 1;
  authMode: "chat_token" | "terminal_access_token";
  authToken: string;
  deviceId: DeviceId;
  terminalSessionId: string;
  backfillLines: number;
  cols: number;
  rows: number;
}

interface TerminalResizeEvent {
  type: "terminal_resize";
  cols: number;
  rows: number;
}

interface TerminalDetachEvent {
  type: "terminal_detach";
}

interface TerminalCloseEvent {
  type: "terminal_close";
}

interface TerminalReadyEvent {
  type: "terminal_ready";
}

interface TerminalBackfillEndEvent {
  type: "terminal_backfill_end";
}

interface TerminalExitEvent {
  type: "terminal_exit";
  code?: number;
}

interface TerminalDataEnvelopeEvent {
  type: "terminal_data";
  data?: string; // base64 or raw utf8 text depending provider
}

interface TerminalErrorEvent {
  type: "terminal_error";
  message?: string;
}

interface TerminalClosedEvent {
  type: "terminal_closed";
  code?: number;
  message?: string;
  reason?: string;
}
```

Sample payload:

```json
{
  "type": "terminal_auth",
  "protocolVersion": 1,
  "authMode": "chat_token",
  "authToken": "<jwt>",
  "deviceId": "9F6A1A72-3FE2-4B89-87D8-95D813B01234",
  "terminalSessionId": "term_abc123",
  "backfillLines": 2000,
  "cols": 100,
  "rows": 28
}
```

Ordering and idempotency notes:

- `stream_snapshot` should precede replayed messages on auth.
- Replay deduplication is by server event ID (`s_*`), not by client ID.
- `ack` makes a client message accepted but not yet canonical; canonicalization happens on echoed user `message`.
- Resends before `ack` reuse the same client ID and payload.
- Retry after missing final assistant output is a new message at the tail with a new client ID.
- Stream create/update/delete events are authoritative metadata deltas and must not trigger local renumbering.
- Terminal output may arrive as raw text/data frames or as `terminal_data` envelopes. The terminal runtime must accept both.

### Protocol and Event Contracts in Implementer Form

#### Main chat WebSocket: `/ws`

Outbound events the browser client must emit:

| Event | Required fields | Notes |
| --- | --- | --- |
| `pair_request` | `type`, `protocolVersion:1`, `deviceId`, `claimedName`, `deviceInfo` | First-launch bootstrap only. `claimedName` editable, clamped to current byte limit described in docs. |
| `pair_decision` | `type`, `deviceId`, `approve`, `userId` when approving | Admin-only flow. No `ack`. Retry is whole-payload resend. |
| `auth` | `type`, `protocolVersion:1`, auth credential, `deviceId`, most recent processed server cursor | Auth credential shape depends on topology decision: direct token vs gateway-backed session. |
| `message` | `type`, `id:c_*`, `content`, `attachments`, `sessionKey` | Content and attachment limits must be preflighted client-side before send. |
| `typing` | `type`, `active`, `sessionKey` when the provider contract requires stream scoping | Client should rate limit locally to the documented ceiling. |

Inbound events the browser client must consume:

| Event | Required fields / semantics | Client obligation |
| --- | --- | --- |
| `pair_result` | `success`, plus token/session bootstrap data on success or `reason` on failure | Persist auth material, transition to auth, or remain in pairing/approval UI. |
| `pair_approval_request` | pending `deviceId`, `claimedName`, `deviceInfo` | Admin UI only. Surface pending approvals from the main socket event stream. |
| `auth_result` | `success`, `userId`, diagnostic `sessionId`, `isAdmin`, replay metadata | On failure, clear invalid auth and return to pairing. On success, seed admin capability and replay notices. |
| `message` | canonical `s_*` message with `role`, `content`, `timestamp`, `streaming`, `deviceId`, `sessionKey`, optional attachments | Route by `sessionKey`; replace optimistic same-device user messages; merge streaming assistant updates by `id`. |
| `ack` | accepted client message `id` | Clear pending resend timer and keep waiting for echoed canonical message. |
| `typing` | assistant-only in current product behavior | Drive transient UI only; do not persist or count as unread. |
| `stream_snapshot` | full ordered stream metadata snapshot and per-stream provisioning surface | Treat as the authoritative stream inventory on auth/reconciliation. |
| `stream_created` / `stream_updated` / `stream_deleted` | stream metadata mutation events | Update ordered stream metadata without renumbering surviving streams. |
| `session_info` | provisioning/session-info updates | Update known/provisioned sessions without treating it as message content. |
| `error` | provider error code | Map to UI and recovery policy without inventing silent fallbacks. |
| `user_info` | currently consumed by iOS | Keep a typed placeholder in the web protocol layer even if no v1 UI uses it yet. |
| `event` | currently includes at least `activity` in iOS service | Treat as a typed extension event. Do not hard-wire it into unrelated modules. |

Contract notes:

- `stream_snapshot` should arrive before replayed messages on auth. That is the intended server contract even though one older guide is loose about the ordering.
- Replay deduplication is by server event ID, not client message ID.
- The browser client should record fixtures for every inbound event above before implementation starts. The appendix does not replace fixture capture.

#### Upload and download HTTP surfaces

Current contract to implement:

| Surface | Contract |
| --- | --- |
| `POST /upload` | Authenticated file upload for non-inline attachments. Returns asset metadata including `assetId`. |
| `GET /download/:assetId` | Authenticated asset fetch. |
| Inline message attachments | Small inline images only, bounded by the documented decoded-byte and total-payload limits. |
| Non-inline attachments | Sent as asset references, not raw file bytes in the chat WebSocket payload. |

Rules:

- Preflight size locally using the documented inline and payload ceilings before attempting send.
- Treat upload auth failures the same way as socket auth failures: clear invalid auth state if the provider indicates token failure.
- Do not depend on older `/www/media/...` URL attachment docs unless the provider contract is explicitly reverted to that shape.

#### Terminal WebSocket: `/ws/terminal`

Current behavioral contract inferred from docs and iOS:

| Area | Contract |
| --- | --- |
| Transport | Separate socket from chat transport |
| Auth | Same auth context as chat, different handshake/event shape |
| Identification | Attachment MIME `application/vnd.clawline.terminal-session+json` determines terminal rendering |
| Resize | Client must send PTY size derived from rendered terminal bounds |
| Lifecycle | Terminal bubble create/bind and teardown follow normal view reuse; no preserved offscreen terminal runtime |
| Responsibility boundary | Provider owns SSH/tmux integration; browser never opens SSH directly |

Implementation note:

- Keep the terminal protocol layer separate from the main chat transport machine even if both eventually share low-level reconnect helpers.

### UX and State Transition Specs

#### Pairing and auth bootstrap

1. If no valid auth material exists, show pairing UI.
2. Submit `pair_request`.
3. On `pair_result.success`, persist auth material, close pairing flow, and begin authenticated bootstrap.
4. If approval is pending, remain in approval-waiting UI and keep the retry/polling behavior defined by the product docs.
5. On authenticated bootstrap, send `auth` with the locally tracked per-stream cursor map and the minimum provider-compatible singular cursor fallback when required by older provider behavior.
6. On `auth_result.success`, seed admin capability, replay metadata, and initial stream inventory state.
7. Do not render the chat shell as fully interactive until both auth success and initial stream provisioning state are available.

Done-state rule:

- A user can pair, authenticate, refresh the page, and land back in an authenticated shell without losing the account identity unless the server explicitly invalidates auth.

#### Send, echo, and retry flow

1. User sends from a provisioned active stream while transport is connected.
2. Client appends optimistic user bubble keyed by `c_*`.
3. Client persists pending-ack journal before network send.
4. On `ack`, client clears resend timer but keeps waiting for canonical echoed user message.
5. On echoed same-device user `message`, client replaces the optimistic item with canonical `s_*` item.
6. Assistant streaming updates mutate one canonical assistant message in place until final.
7. If reconnect completes and the user echo has no final assistant response and no active stream in flight, surface retry.
8. Retry appends a new user bubble at the tail with a new `c_*` ID.

Done-state rule:

- At no point should one user action produce duplicate canonical user messages or duplicated assistant transcripts after reconnect.

#### Reconnect and recovery flow

1. Transport interruption moves the transport machine into recovery.
2. Recovery backoff becomes the sole reconnect driver unless the user explicitly requests retry.
3. Manual retry while recovering cancels the timer and reconnects immediately with reset delay.
4. Successful auth resumes from the local per-stream cursor map. If the provider still only honors a singular cursor on auth, send that minimum compatible fallback too, but do not drop the full local per-stream resume model.
5. Replay applies before the app is marked live.
6. Cache hydrate may fill missing local gaps before replay completes, but it may not overwrite replayed/live data.
7. Once replay settles, any stale recovery work from older attempts is ignored by epoch/token validation.

Done-state rule:

- A disconnect/reconnect cycle must not blank unrelated streams, duplicate messages, or regress cursors for inactive streams.

#### Stream switching flow

1. UI selection changes immediately on user intent.
2. Expensive engine activation is scheduled separately behind epoch validation.
3. Pager-swipe path waits for settle plus debounce before engine activation; programmatic path uses the same commit seam without debounce.
4. If the target stream disappears before commit, drop activation and reconcile UI selection to a valid stream.
5. For unvisited large streams, loading affordance remains visible until activation/materialization completes.
6. Read/unread clearing happens on the product-defined selection path, not from ad hoc scroll events.

Done-state rule:

- Rapid stream flipping leaves only the final selected stream active for expensive work, with no stale activation side effects in previously viewed streams.

#### Scroll, unread, and restore flow

1. Initial hydrate or replay paints the list without generating unread.
2. If the user is at bottom and a new message arrives in the active stream, auto-scroll remains eligible.
3. If the user is interacting away from bottom, auto-scroll is deferred until interaction ends.
4. The scroll-to-bottom affordance, restore fallback, and auto-scroll eligibility all read the same bottom-threshold calculation.
5. `firstUnreadMessageId` remains stable until unread clears.
6. Crossing the first unread marker at the defined viewport threshold flashes and clears unread.

Done-state rule:

- Reloading, switching streams, or replaying history must not cause unread oscillation or jumpy bottom-affordance behavior.

### Per-Phase Acceptance Criteria Refinements

These checklists refine the high-level migration phases above. Each phase still ends with a runnable browser app.

#### Phase 1: Runnable pairing and text chat

Manual acceptance:

- A first-time user can pair from the browser and reach a usable chat shell.
- A returning user refreshes and re-enters authenticated chat without re-pairing when auth remains valid.
- The user can send text into the active provisioned stream and see optimistic, acked, and canonical echoed states.
- Incoming assistant replies stream in place instead of appending duplicate partial bubbles.
- Connection state is visible through the composer/send affordance using only connected/reconnecting/disconnected semantics.
- Settings open as an in-chat overlay, not a full-route context break.

Automated acceptance:

- Fixture tests cover `pair_request`, `pair_result`, `auth`, `auth_result`, `message`, and `ack`.
- End-to-end test covers pair -> auth -> send -> echoed user message -> assistant reply.
- State-machine test proves duplicate reconnect intents are ignored while already connecting/live.
- Runtime test proves two browser tabs can authenticate independently without either tab suppressing or corrupting the other's local transport state.

Phase done when:

- Someone unfamiliar with the code can open the app in a browser, pair, exchange text messages, reload, and repeat the flow without manual state repair.

### Phase 1 Build Sheet

This is the literal kickoff sheet for the first implementation engineer. It assumes the Phase 1 goal remains: runnable browser pairing plus text chat with real transport, real provisioning, and real optimistic/ack/canonical message behavior.

Entry conditions:

- Deployment topology is chosen: direct browser-to-provider or gateway/BFF.
- Browser auth storage strategy is chosen: secure cookie, browser-held token, or gateway session.
- Browser-trusted TLS path is defined for the chosen topology.
- Protocol fixtures for `pair_request`, `pair_result`, `auth`, `auth_result`, `message`, `ack`, `stream_snapshot`, and `session_info` have been captured.

Recommended file/module kickoff set:

| Area | Files / modules to create | Why this must exist in Phase 1 |
| --- | --- | --- |
| App bootstrap | `src/app/bootstrap.tsx`, `src/app/routes.tsx`, `src/app/AppProviders.tsx` | One entrypoint is needed to wire routing, runtime providers, and test harnesses consistently. |
| Protocol layer | `src/protocol/chat-wire.ts`, `src/protocol/stream-api.ts` | The typed Phase 1 protocol must be centralized before UI work starts so event parsing does not leak into feature components. |
| Transport owner | `src/runtime/transport/transportMachine.ts`, `src/runtime/transport/wsClient.ts` | Phase 1 already depends on real connection ownership, reconnect semantics, and per-tab transport discipline. |
| Chat domain owner | `src/runtime/chat/chatDomainStore.ts`, `src/runtime/chat/applyServerEvent.ts`, `src/runtime/chat/pendingSendJournal.ts` | Stream inventory, provisioning state, messages, cursors, unread state, and optimistic reconciliation need one write seam from the start. |
| Persistence boundary | `src/runtime/persistence/indexedDbChatPersistence.ts`, `src/runtime/persistence/preferences.ts` | Even Phase 1 needs durable auth bootstrap and the beginning of transcript/pending-send persistence. |
| Pairing/auth feature | `src/features/auth/PairingScreen.tsx`, `src/features/auth/AwaitingApprovalScreen.tsx`, `src/features/auth/usePairingActions.ts` | Pairing is a real product flow, not a debug screen. |
| Chat shell feature | `src/features/chat/ChatRoute.tsx`, `src/features/chat/ChatShell.tsx`, `src/features/chat/StreamRail.tsx`, `src/features/chat/MessageList.tsx`, `src/features/chat/Composer.tsx` | This is the first runnable slice the user actually uses. |
| Settings overlay | `src/features/settings/SettingsDrawer.tsx` | Phase 1 must prove the web app keeps users anchored in chat while exposing settings. |
| Test fixtures | `src/test/fixtures/protocol/*.json`, `src/test/fixtures/transcripts/*.ts` | The protocol and transcript rules must be codified before richer rendering lands. |
| End-to-end coverage | `playwright/tests/phase1-pairing-and-chat.spec.ts` | Phase 1 is not ready without a browser-level proof of pair/auth/chat/reload. |

Runtime owners that must exist before UI polish:

| Owner | Must own | Must not own |
| --- | --- | --- |
| `transportMachine` | socket lifecycle, auth bootstrap, reconnect phase, and server event ingress for one tab | transcript mutation, unread state, selected stream UI |
| `chatDomainStore` | ordered streams, provisioned session keys, provisioning state, messages by `sessionKey`, pending sends, replay cursors, unread/read markers, optimistic echo replacement | socket lifecycle ownership, provider identity, route authority |
| `settingsStore` | local appearance/debug preferences only | connection readiness, send gating, transcript truth |

Routes and screens required in Phase 1:

| Route / surface | Requirement |
| --- | --- |
| `/` | Bootstrap route that resolves to pairing or chat based on auth/runtime state |
| `/pair` | Pairing entry with claimed-name input and error/pending handling |
| `/chat/:sessionKey?` or equivalent URL-carried selected-session state | Main chat route; selected session must be URL-addressable |
| Settings overlay on the chat route | Drawer/modal, not a dedicated route |
| Awaiting approval surface | Required if `pair_pending` or `device_not_approved` occurs |

Tests required before Phase 1 is ready for Flynn verification:

- Serialization tests for every Phase 1 event: `pair_request`, `pair_result`, `auth`, `auth_result`, `message`, `ack`, `stream_snapshot`, `session_info`, `error`.
- Transport-machine tests for: duplicate reconnect intent suppression, auth success transition, auth failure transition, and manual retry out of recovery.
- Independent-tab transport tests proving two browser tabs can connect and recover independently without shared in-memory coordination.
- Chat-domain-store tests for: optimistic send -> ack -> echoed user replacement, streaming assistant update in place, stream/provisioning snapshot application, and hydrate/replay producing no unread.
- Route/runtime tests proving selected session comes from URL state and that settings open as overlay, not navigation.
- Playwright test covering: pair -> auth -> select session -> send -> receive -> reload -> transcript still usable.

Stub versus omit guidance:

| Category | Stub in Phase 1 | Omit entirely from Phase 1 |
| --- | --- | --- |
| Message rendering | Plain text bubble rendering only; attachments may render as unsupported placeholders if they arrive unexpectedly | Markdown, code blocks, tables, link cards, image gallery, file previews |
| Typing/activity | Parse the events and allow a minimal text-only typing affordance if stream-scoped data exists | Fancy animation or richer activity surfaces |
| Settings | Only ship settings needed for appearance and connection diagnostics under the chosen topology | Native-only trust toggles and any iOS platform settings |
| Streams | Real stream selection from provisioned inventory; no fake local streams | Create/rename/delete/adopt/untrack flows |
| Rich surfaces | None | Terminal, interactive HTML, embedded previews |
| Uploads | None | Upload pipeline, paste/drop/file-input |

Phase 1 engineer checklist:

- Create the protocol types before writing transport logic.
- Create the transport machine before writing the chat shell.
- Create the chat-domain-store write seam before handling inbound `message` and `ack`.
- Wire selected session to URL state before building the stream rail.
- Land Phase 1 tests before adding any Phase 2 persistence or broader multi-tab UX polish.

#### Phase 2: Session fidelity and durable reload

Manual acceptance:

- Refreshing or transient network loss restores the chat shell and recovers the same visible transcript set.
- Inactive streams preserve message history and cursors across reload.
- Non-active assistant replies mark streams unread; visiting the stream clears unread at tail.
- No unread is generated by hydrate, replay, or backfill.

Automated acceptance:

- Projection tests cover unread mutation call sites and read-cursor-to-tail behavior.
- Replay tests prove all per-stream cursors resume, not only the currently visible stream.

Phase done when:

- Reload and reconnect preserve transcript continuity across more than one stream with no duplicate sends or stale empty streams.

#### Phase 3: Rich rendering and common attachments

Manual acceptance:

- Markdown preserves strict source order for mixed prose/code/table content.
- `==highlight==` styling renders in both compact and expanded message surfaces.
- Inline images, uploaded assets, and file chips render correctly and download through the authenticated path.
- Composer supports paste/drop/file-input flows for the supported attachment types.

Automated acceptance:

- Static render fixtures cover mixed markdown ordering, highlight syntax, inline images, uploaded assets, and streaming message updates.
- Upload integration tests cover oversize rejection, auth failure handling, and successful asset reference send.
- Screenshot or visual regression coverage exists for the main bubble variants.

Phase done when:

- Rich-text and common attachment transcripts can be rendered from static fixtures with no server, and real uploaded assets round-trip against the provider contract.

#### Phase 4: Stream management and chat-surface maturity

Manual acceptance:

- Users can create, rename, delete, adopt, and untrack streams using the current stream API contract.
- Rapid stream switching does not jank the UI or apply stale data to the wrong stream.
- Scroll restoration, unread anchors, and bottom affordance remain coherent in long transcripts.
- Keyboard and screen-reader flows remain intact after virtualization and stream-management UI are added.

Automated acceptance:

- Stream CRUD tests verify ordering stability and no client-side renumbering after deletes.
- Engine/UI stream split tests verify delayed activation is cancelled by newer selection epochs.
- End-to-end tests cover unread clearing on selection, long-list restore, and scroll-to-bottom affordance behavior.

Phase done when:

- The browser app can replace the core multi-stream experience of the current iOS app for text, rendering, and stream organization flows.

#### Phase 5: Advanced rich surfaces

Manual acceptance:

- Terminal attachments render only when the terminal MIME type is present and connect through the terminal-specific runtime.
- Terminal resize affects remote wrapping correctly.
- Interactive HTML content renders inside a sandboxed surface, locks its height after initial measurement, and never escapes its bridge contract.
- Crashed rich surfaces degrade to stable error states instead of taking down the chat shell.

Automated acceptance:

- Security tests verify interactive HTML sandbox flags, blocked network access, message-bridge allowlist, and one-time `_resize` handling.
- Terminal tests verify separate transport ownership and disconnect behavior independent from the main chat socket.
- Regression tests prove rich-surface failures do not mutate chat-runtime state ownership.

Phase done when:

- Advanced surfaces operate as isolated runtimes inside the chat product without weakening chat transport, transcript correctness, or browser trust boundaries.

### Rendering and Edge-Case Fixtures

These fixtures should exist as static JSON or TS objects plus screenshot fixtures where rendering matters.

| Fixture | Input shape | Expected behavior |
| --- | --- | --- |
| Mixed markdown order | Paragraph -> code block -> paragraph -> table | Render in source order in both bubble and expanded surfaces. |
| Highlight syntax | Markdown containing `==important==` | Preserve highlight styling instead of dropping or escaping it. |
| Streaming assistant update | Three `message` events with same assistant `id`, first two `streaming:true`, final `streaming:false` | One bubble updates in place and ends non-streaming. |
| Same-device optimistic echo replacement | Local `c_*` optimistic send followed by `ack` and echoed user `s_*` with matching `deviceId` | Optimistic bubble is replaced, not duplicated. |
| Retry-after-failure | Failed user bubble retried after missing final assistant output | New user bubble appears at tail with new `c_*`; failed bubble remains historical until product chooses otherwise. |
| Non-active stream unread | Assistant message delivered to non-active stream | Stream gains unread marker; selecting stream clears unread at tail. |
| Hydrate/replay no-unread | Cached transcript + replayed messages on load | No unread badge appears solely because of restore. |
| First unread stability | Multiple incoming assistant messages after unread begins | `firstUnreadMessageId` stays anchored to the first unseen message until clear. |
| Interactive HTML size lock | HTML payload with post-load animation growth | Bubble height locks after initial measure; content scrolls internally. |
| Interactive HTML `_resize` | Two `_resize` bridge requests | First may be honored; second is ignored. |
| Terminal MIME detection | Document attachment with `application/vnd.clawline.terminal-session+json` | Render terminal surface instead of generic file chip. |

### Security Rules for Rich Surfaces and Uploads/Previews

#### Interactive HTML

- Treat interactive HTML as a separate untrusted runtime even if the content author is a trusted agent in product terms.
- Use a sandboxed iframe/runtime with no ambient app credentials, no shared browsing context, and a narrow explicit bridge.
- Mirror the native isolation intent: no shared preview runtime, no casual consolidation with link-preview infrastructure.
- Enforce the 256KB content cap client-side even if the provider already enforces it.
- Size once, lock height, allow at most one explicit `_resize` escape hatch.
- Callback delivery is best-effort and unordered under rate limits; product logic must not assume exactly-once or ordered callbacks.

#### Terminal surfaces

- Terminal runtime is separate from chat runtime.
- Terminal auth may share the user session but not the chat socket or chat state machine.
- The browser must never open SSH directly; remote shell trust and host access remain provider responsibilities.
- Terminal clipboard, focus, and resize behavior must stay inside the terminal module boundary and not mutate unrelated chat state.

#### Uploads, downloads, and previews

- Inline attachments are image-only and must obey the documented decoded-byte and payload caps.
- Uploaded assets must go through authenticated provider surfaces, not ad hoc unsigned URLs, unless the contract is explicitly changed.
- Download URLs should be treated as authenticated resources; previews must not leak bearer credentials into arbitrary third-party origins.
- Link preview fetching remains an open topology decision. If preview fetch happens server-side, the browser renders sanitized metadata only. If preview fetch happens client-side, preview rendering must not become a covert credential bridge.
- Any preview or embed rule not grounded in the current docs remains unresolved and must be documented as such before implementation.

### Unresolved Decisions Table

These remain intentionally unresolved where the docs and iOS behavior do not settle them. An implementation engineer should not silently decide them in code.

| Decision | Options | Impact | Blocks / affects |
| --- | --- | --- | --- |
| Browser deployment topology | direct browser-to-provider; same-origin gateway/BFF; another mediated proxy | Determines auth shape, TLS requirements, CORS, deployment, and whether the browser may talk to the provider WebSocket directly | Blocks Phase 1 |
| Browser auth storage model | httpOnly cookie/session; browser-held token; gateway-issued opaque session | Changes `auth` bootstrap, logout semantics, XSS/CSRF surface, reload behavior, and upload/download auth plumbing | Blocks Phase 1 |
| TLS / trust model for browser users | CA-trusted end-to-end; trusted gateway fronting self-signed provider; internal-only environment | Determines whether the browser app is viable outside controlled environments | Blocks external Phase 1 rollout |
| Admin approval UX scope for web v1 | include pending approvals in v1; non-admin-only Phase 1 with admin approval deferred | Affects whether `pair_approval_request` / `pair_decision` need browser UI in the first release | Affects Phase 1 scope |
| Preview-fetch topology | server-side preview service; client-side metadata fetch; no link previews in v1 | Changes security model, credential exposure, CSP, and rendering pipeline shape | Affects Phase 3 |
| Offline support target | durable reload only; cached read-only transcripts; fuller offline browsing | Changes persistence semantics, cache eviction, and scope of browser storage | Affects Phase 2 and Phase 6 |
| Mobile-web replacement target | desktop-first web; responsive mobile web replacing iPad usage; desktop-only v1 | Changes route/layout priorities, input bar behavior, and browser QA matrix | Affects Phase 4 and release criteria |
| Terminal bubble launch scope | launch-critical; post-launch phase; omit from web | Determines whether terminal protocol/runtime is a v1 requirement or a gated later phase | Affects Phase 5 and launch scope |
| Interactive HTML launch scope | launch-critical; post-launch phase; omit from web | Determines whether sandbox bridge/runtime must ship before launch | Affects Phase 5 and launch scope |
| Salience/highlight parity | full `==highlight==` parity in v1; plain markdown first; omit salience entirely | Changes Phase 3 renderer fidelity and whether highlight tokens must be product-visible at launch | Affects Phase 3 |

### Engineering Conventions Grounded in Current System

These are not stylistic preferences. They are direct translations of invariants already established in the docs and iOS implementation.

| Convention | Implementer rule | Grounding |
| --- | --- | --- |
| Single transport writer | Only the transport state machine writes connection phase. Other code emits intents/events only. | `connection-lifecycle.md` |
| Single transcript writer | Only one conversation projection seam mutates messages, cursors, unread markers, and pending send reconciliation. | `connection-lifecycle.md`, `message-stream-seam.md`, unread docs |
| Gap-fill persistence | Hydrate from persisted state only to fill missing local gaps. Never overwrite or reorder live data. | connection lifecycle and message-stream seam docs |
| Yield-boundary guards | After any async/yield boundary, capture and revalidate the relevant `sessionKey` and generation/epoch before applying per-stream side effects. | per-stream transition and encapsulation docs |
| Shared bottom-threshold calculation | Compute one bottom-threshold decision and use it for auto-scroll, restore fallback, and scroll-to-bottom visibility. | scroll invariants docs |
| URL-selected session is authoritative | URL state owns selected session. If expensive activation work ever needs deferral, treat it as an internal optimization only after profiling proves the need; do not introduce a second user-visible selection owner. | stream-switch coordinator doc, selected-session ownership seam |
| Render-plan reuse | Parse markdown once per message and reuse the plan across compact and expanded surfaces. | unified-markdown doc |
| Rich-surface isolation | Interactive HTML and terminal runtimes do not share incidental transport, process, or preview infrastructure. | interactive HTML and terminal docs |
| Main chat transport visibility is not lifecycle | React mount/unmount or tab visibility changes must not by themselves own main chat socket teardown semantics. Rich surfaces may define narrower lifecycle rules inside their own modules. | chat VM lifecycle ownership doc |
| Staged first-open materialization | Only large unvisited streams should use staged materialization, and only on first activation. | staged-stream-materialization doc |
