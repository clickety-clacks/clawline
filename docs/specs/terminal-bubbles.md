# Embedded Terminal Bubbles (GitHub #46)

## Goal
Embed interactive terminal sessions directly inside chat message bubbles. When CLU needs to show live logs/debugging output, it should send a *terminal session bubble* instead of streaming plain text. The user can scroll, select/copy, and interact (keyboard input) within the bubble.

This spec targets Clawline’s existing message/bubble pipeline and adapts the proven Floatty approach (SwiftTerm + PTY streaming + tmux attach patterns).

## Non-Goals (v1)
- No multi-pane tmux UI (pane list, split management) in-chat.
- No “attach to arbitrary existing user tmux pane on arbitrary host via SSH from the iOS client”.
- No guaranteed pixel-perfect replay of historical terminal state prior to opening the bubble.
- No group chat terminal sharing (pair programming) in v1. This needs its own security model.

## Terms
- **Provider**: The Clawline backend the client already connects to over WebSocket (`/ws`) with a token.
- **Client**: iOS app (and later Android) rendering chat bubbles.
- **Terminal Session**: A server-side resource that proxies a PTY to the client over WebSocket.
- **tmux session/pane**: The backing terminal state.
  - v1 supports two deployment shapes:
    - **Local tmux**: provider host can create/manage tmux sessions locally.
    - **Remote tmux**: provider SSHes to a dedicated terminal host (e.g. provider runs on TARS, tmux lives on eezo).

## Architecture (Client)

### Where It Fits
Clawline currently renders a `Message` by building a `MessagePresentation` (parts like `.text`, `.code`, `.image`, `.file`) and then laying those parts out in `MessageBubbleUIKitView`.

Add a new renderable part:
- `MessagePart.terminalSession(TerminalSessionDescriptor)` (new case)

Flow:
1. Provider sends a normal `"type": "message"` payload.
2. The payload includes a “terminal session attachment” (see **Wire Protocol**).
3. The client parses the attachment into a `TerminalSessionDescriptor`.
4. `MessagePresentationBuilder` produces a `.terminalSession(...)` part (in addition to or instead of textual content).
5. `MessageBubbleUIKitView` creates a `TerminalBubbleView` and adds it to `dynamicContentStack`.

Client parsing rule (important for backwards compatibility):
- Terminal sessions are encoded as `AttachmentType.document` with `mimeType: application/vnd.clawline.terminal-session+json`.
- The client MUST intercept this mimeType during presentation building and render it as a terminal session part (not as a generic file attachment preview).
  - Old clients will still render it as a generic document attachment; this is acceptable fallback behavior.

### New UI Component: `TerminalBubbleView`
UIKit view embedded inside the message bubble area. Responsibilities:
- Own and layout a SwiftTerm `TerminalView` (the terminal emulator).
- Manage connection state (connecting, live, disconnected, exited).
- Expose controls (expand, reconnect when dead).
- Forward terminal input bytes to the provider session WebSocket.
- Apply size changes (cols/rows) back to the provider.

### New Service: `TerminalSessionService`
Separate from chat websocket (`ProviderChatService`). Responsibilities:
- Establish a terminal session websocket to the provider.
- Multiplex control frames (JSON) and data frames (binary).
- Provide an `AsyncStream`/callback for:
  - Raw output bytes (to feed SwiftTerm)
  - State events (ready/exit/error)
- Manage reconnection/backoff.

Rationale: terminal traffic is high-volume, binary, and has different lifecycle than chat messages.

Implementation note: Clawline's current `WebSocketClient` abstraction is text-only; terminal sessions require either (a) a new binary-capable socket abstraction or (b) a terminal-specific implementation that uses `URLSessionWebSocketTask` directly and handles both `.string` and `.data` messages.

Recommended interface (client):
```swift
protocol TerminalWebSocketClient: AnyObject {
    var incomingMessages: AsyncStream<URLSessionWebSocketTask.Message> { get }
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func close(code: URLSessionWebSocketTask.CloseCode?)
}
```

## SwiftTerm Integration (What To Steal From Floatty)

Floatty has an existing, working SwiftTerm integration with the right abstractions for:
- Feeding output bytes into the terminal emulator.
- Capturing user input bytes (including paste).
- Resizing PTY based on terminal view size changes.

Reuse/adapt these concepts from `~/src/Floatty/Floatty/SwiftTermView.swift` (repo-local path: `Floatty/SwiftTermView.swift`):
- **Terminal feeding**: `terminalView.feed(byteArray:)` via a small `TerminalViewModel`-like wrapper.
- **TerminalViewDelegate plumbing**:
  - `send(source:data:)` to capture user input.
  - `sizeChanged(source:newCols:newRows:)` to trigger remote resize.
- **Input sanitization**: `TerminalInputSanitizer` to filter problematic control bytes during bracketed paste (prevents tmux/session flow-control issues).

Implementation detail for Clawline:
- Clawline chat bubbles are UIKit-heavy (`MessageBubbleUIKitView`). Prefer directly embedding `SwiftTerm.TerminalView` (a `UIView`) inside `TerminalBubbleView`, rather than introducing SwiftUI wrappers inside cells.

## Wire Protocol

### Wire Protocol Changes Required (Both Sides)
- Client: extend the chat `auth` payload to include `clientFeatures` so the provider can gate terminal attachments to compatible clients.
- Provider: parse and honor `clientFeatures`, and only emit terminal session attachments when `terminal_bubbles_v1` is present.
- Provider: implement a separate terminal data-plane endpoint (suggested `/ws/terminal`) that supports binary WebSocket frames.

### Capability Negotiation
We must not break older clients. Today, unknown attachment types can cause decode failures if we add new enum cases naively.

Rollout approach:
1. **Client advertises support** in chat auth:
   - Extend chat auth payload (client → provider) with an optional `clientFeatures` array.
2. **Provider only sends terminal session attachments** if it saw `terminal_bubbles_v1` in `clientFeatures`.

Client → provider chat auth (existing fields preserved):
```json
{
  "type": "auth",
  "protocolVersion": 1,
  "token": "...",
  "deviceId": "...",
  "lastMessageId": "s_123",
  "clientFeatures": ["terminal_bubbles_v1"]
}
```

Provider → client auth_result (existing `features` preserved; provider may also echo support):
```json
{
  "type": "auth_result",
  "success": true,
  "features": ["session_info", "terminal_bubbles_v1"]
}
```

### Encoding Terminal Sessions Inside Messages (Backwards-Compatible)
Use an `attachments[]` entry with `type: "document"` and a special `mimeType`. This avoids introducing a new `AttachmentType` value before clients are tolerant to unknown enums.

Server message payload excerpt:
```json
{
  "type": "message",
  "id": "s_456",
  "role": "assistant",
  "content": "",
  "timestamp": 1700000000000,
  "streaming": false,
  "sessionKey": "agent:main:clawline:mike:main",
  "attachments": [
    {
      "id": "term_8e1d",
      "type": "document",
      "mimeType": "application/vnd.clawline.terminal-session+json",
      "data": "BASE64_ENCODED_JSON_BYTES"
    }
  ]
}
```

Attachment `data` (decoded bytes) is UTF-8 JSON for `TerminalSessionDescriptor`:
```json
{
  "version": 1,
  "terminalSessionId": "ts_8e1d",
  "title": "gateway logs",
  "provider": {
    "baseUrl": "https://provider.example.com",
    "wsPath": "/ws/terminal"
  },
  "capabilities": {
    "interactive": true,
    "supportsBinaryFrames": true,
    "supportsResize": true,
    "supportsDetach": true
  },
  "auth": {
    "mode": "chat_token",
    "terminalAccessToken": null
  },
  "expiresAtMs": 1700003600000
}
```

Notes:
- `provider.baseUrl` should usually match the paired provider base URL already stored on device; it’s included for clarity/debuggability. The client should treat the paired base URL as authoritative unless explicitly overridden by a future policy.
- `expiresAtMs` is not used in v1. Terminal sessions do not expire automatically (see Lifecycle).

Auth note:
- v1 MAY reuse the existing chat token (`auth.mode: chat_token`).
- Recommended hardening: include a short-lived, session-scoped `terminalAccessToken` in `auth` (minted by the provider at creation time) to reduce replay/overbreadth. If used, the client prefers it over the chat token.

### Terminal Session WebSocket (Data Plane)
Separate endpoint from chat (`/ws`). Suggested:
- `wss://<provider-host>/ws/terminal`

Handshake (text frames, JSON):
Client → provider:
```json
{
  "type": "terminal_auth",
  "protocolVersion": 1,
  "authMode": "terminal_access_token",
  "authToken": "...",
  "deviceId": "...",
  "terminalSessionId": "ts_8e1d",
  "backfillLines": 2000,
  "cols": 100,
  "rows": 28
}
```

Auth precedence:
- If `TerminalSessionDescriptor.auth.terminalAccessToken` is non-null, the client sends `authMode: terminal_access_token` and uses that token as `authToken`.
- Otherwise the client sends `authMode: chat_token` and uses the existing provider chat token as `authToken`.

Provider → client:
```json
{
  "type": "terminal_ready",
  "terminalSessionId": "ts_8e1d",
  "cols": 100,
  "rows": 28,
  "readOnly": false,
  "maxBackfillLines": 5000,
  "backfillLinesActual": 2000
}
```

Backfill framing (required for consistent UX):
- Provider sends `terminal_ready` first.
- Provider then sends 0..N binary output frames that include backfill content.
- Provider then sends:
```json
{ "type": "terminal_backfill_complete", "backfillLinesActual": 2000 }
```
- After `terminal_backfill_complete`, all subsequent binary output frames are live.

Resize (text frame):
```json
{ "type": "terminal_resize", "cols": 100, "rows": 28 }
```

Detach (text frame; idempotent):
```json
{ "type": "terminal_detach" }
```

Close (text frame; kills server-side backing session and prevents reconnect):
```json
{ "type": "terminal_close" }
```

Close acknowledgement (text frame):
```json
{ "type": "terminal_closed" }
```

Exit (text frame):
```json
{ "type": "terminal_exit", "code": 0, "reason": "command_finished" }
```

Error (text frame):
```json
{ "type": "terminal_error", "code": "not_found", "message": "Session not found" }
```

Data frames:
- Provider → client: **binary frames** containing raw PTY output bytes. Client feeds bytes into SwiftTerm.
- Client → provider: **binary frames** containing raw user input bytes from SwiftTerm (after sanitization).

If binary frames are unavailable in some client environments, fall back to a text-frame encoding:
```json
{ "type": "terminal_output_b64", "data": "..." }
{ "type": "terminal_input_b64",  "data": "..." }
```
This fallback is supported only as a compatibility mode; v1 should prefer binary.

### Keepalive / Stale Connection Detection (Required)
- Client SHOULD send WebSocket-level ping frames periodically (e.g., every 15s) while attached; if 3 consecutive pings fail or no pong is received within 45s, the client marks the session disconnected and shows `Reconnect`.
- Provider SHOULD enforce an idle timeout (e.g., 60-120s without any data/ping) and close the WS so the client can reconnect cleanly.

### Flow Control / Backpressure (Required)
Terminal output can be unbounded. v1 MUST define a cap and behavior.

Provider rules (v1):
- Maintain a bounded output ring buffer per `terminalSessionId` (e.g., 4-16 MB or N lines).
- If the client cannot keep up, drop oldest output first.
- When drops occur, send:
```json
{ "type": "terminal_overflow", "droppedBytes": 123456 }
```

Client rules (v1):
- If `terminal_overflow` is received, show a non-intrusive “output truncated” indicator in the bubble header.
- If app is backgrounded or bubble is offscreen, the client SHOULD disconnect the terminal WS to avoid buffering; reconnect is user-driven via `Reconnect`.

Backfill semantics (v1):
- `backfillLines` is a client hint; provider MAY cap it to `maxBackfillLines` and reports the applied value in `terminal_ready.backfillLinesActual` and in `terminal_backfill_complete`.

### Error Codes (v1)
Provider MUST use stable error codes so clients can render actionable UI.

- `not_found`: session does not exist or expired.
- `unauthorized`: token invalid or user not allowed for this `terminalSessionId`.
- `already_attached`: another client is currently attached (if provider enforces single-attach).
- `rate_limited`: input/output throttled; client should back off and retry later.
- `resource_exhausted`: provider refused creation/attach due to limits.
- `internal`: unexpected server error.

## tmux Connectivity (Provider)

### Personal-Stream Policy (Provider) (Product Decision)
Terminal bubbles are allowed for any *personal Clawline stream* session keys of the form:
- `agent:main:clawline:{userId}:main`
- `agent:main:clawline:{userId}:s_*` (user-created personal streams)

Provider MUST refuse to emit terminal session attachments for:
- `agent:main:main` (global admin channel)
- any non-personal / group session key patterns

Enforcement rule (provider):
- Gate on personal-stream session key pattern before creating the tmux session and before emitting the message attachment.
- `...:main` has no elevated rendering privilege over `...:s_*`; both must decode/render identically on clients.

### Provider Responsibilities
The provider owns:
- Creating tmux sessions/panes for terminal bubbles (locally or on a remote terminal host via SSH).
- Attaching a PTY to tmux on behalf of the client.
- Proxying PTY output to the terminal session WebSocket.
- Applying client input and resize to the PTY.
- Cleanup/expiry.

The client does **not** SSH and does **not** speak to tmux directly.

### Remote Terminal Host (SSH)

In split deployments (provider host != terminal host), the provider connects to a configurable remote terminal host over SSH and runs all tmux operations there:
- `list-panes`, `capture-pane`, `resize-pane`, `kill-session`
- `attach-session` (PTY bridging via `ssh -tt ... tmux attach-session`)

Config (provider):
- `terminal.tmux.mode`: `"local"` (default) or `"ssh"`
- `terminal.tmux.ssh.target`: ssh target, e.g. `"mike@eezo.tail4105e8.ts.net"`
- Optional: `terminal.tmux.ssh.identityFile`, `port`, `knownHostsFile`, `strictHostKeyChecking`, `extraArgs`

Security notes:
- Use a dedicated SSH key with minimum privileges on the terminal host.
- Prefer non-interactive SSH options (`BatchMode=yes`) so the provider never blocks on prompts.

### Backing Model
Each `terminalSessionId` maps to:
- A tmux session name (e.g., `clawline_ts_8e1d`)
- Optionally, a specific pane target inside that session (v1 can treat the whole session as the unit)
- An optional command that was launched (for logs/debug)
- Ownership/authorization:
  - Chat `sessionKey` that received the message (Clawline invariant: session keys are routing identifiers)
  - User identity (from provider auth token)
- Timestamps: created/lastAttached/lastActivity/expiresAt

### Creating a Terminal Session
Two common creation modes:
1. **Run a command** (logs / debugging):
   - `tmux new-session -d -s clawline_ts_8e1d "bash -lc '<command>'"`
2. **Interactive shell** (ad-hoc debugging):
   - `tmux new-session -d -s clawline_ts_8e1d`

Provider then sends a chat message containing the terminal session attachment, referencing `terminalSessionId`.

### Attaching for Streaming
When a client connects to `/ws/terminal` for a given session:
1. Provider optionally backfills scrollback using `tmux capture-pane`:
   - Prefer `tmux capture-pane -e -p -S -<lines> -t clawline_ts_8e1d`
   - Send captured bytes before live attach so SwiftTerm has context.
2. Provider starts a PTY process:
   - `tmux attach -t clawline_ts_8e1d`
3. Provider bridges PTY <-> WebSocket:
   - PTY stdout/stderr → WS binary output frames
   - WS binary input frames → PTY stdin
4. Resize:
   - Apply `SIGWINCH`/pty resize to the PTY when client reports `cols/rows`.
5. Detach:
   - On WS disconnect, provider closes PTY; tmux session stays alive until it is explicitly killed or it exits.

Notes:
- If multiple clients attach concurrently, provider should decide:
  - v1 simplest: single active attachment per `terminalSessionId` (second attach fails with `already_attached`), or last-writer-wins (disconnect prior).
  - Document and enforce server-side.

## Lifecycle

### Creation
- Triggered by CLU (agent) deciding to present terminal output interactively.
- Provider allocates `terminalSessionId`, provisions tmux, stores mapping, then emits a normal chat message with the attachment.

### Attach / Detach
- Bubble auto-connects immediately when it appears in chat. No tap-to-connect in v1.
- On detach (view offscreen / memory management / app backgrounding), the provider stops proxying but does not necessarily kill tmux.
  - Rule: WebSocket disconnect implies **detach**, not close.
  - Only explicit user action invokes `terminal_close`.

### Reconnect
- The same message attachment is sufficient to reconnect while session is alive.
- When the session exits or is killed, the bubble shows the session name/description and a `Reconnect` button.
- Reconnect should succeed if the backing tmux session is still alive; otherwise show error gracefully.

### Cleanup
Provider cleanup rules:
- No automatic TTL in v1.
- When the backing command exits, the provider SHOULD surface `terminal_exit` and MAY kill the tmux session (depending on whether tmux was created just to run the command).
- On explicit user “Close” action:
  - Provider kills backing tmux session immediately and marks session as closed; subsequent attach attempts should return `terminal_error` with code `not_found` (or `session_closed` if we add that code later).

Client cleanup rules:
- Client SHOULD tear down terminal WebSockets for bubbles that are far offscreen and have not been accessed recently.
  - Only visible/recent terminal bubbles stay live.
  - Reconnect is cheap because tmux scrollback is restored via backfill.
- Persist only the descriptor already in the message; do not persist additional secrets.

## UI / UX (Chat Bubble)

### In-Bubble Layout
Terminal renders without standard message bubble chrome:
- No sender header, no rounded bubble background, no “card” padding.
- Use the same sizing behavior as HTML link previews:
  - Wide layout (full container width).
  - Height capped (large viewport) with internal scrolling handled by the terminal view.
- Controls:
  - When live: show a minimal title/status strip and an `Expand` affordance.
  - When dead: show the session name/description plus a `Reconnect` button.

### Scrollback Behavior
- SwiftTerm provides local scrollback once connected.
- If provider supports backfill (`tmux capture-pane -e`), prepopulate scrollback on connect.
- When the user scrolls up, auto-scroll to bottom should pause until the user returns to bottom (“scroll lock”).

### Interaction With Chat Scrolling
- Scrolling inside the terminal is captured by the terminal (same pattern as HTML previews capturing web scroll).

### Keyboard Focus (Interactive Sessions)
- Tapping inside the terminal viewport focuses the terminal and brings up the software keyboard (unless policy disables it).
- While terminal is focused, the chat input bar MUST NOT intercept Enter/Return for “send message”.
- Provide an explicit “Done” affordance to return focus to the chat composer.

### Accessibility
- Header and controls are standard accessible elements.
- Terminal content: expose as a single accessibility element with hint “Terminal output; double tap to focus; swipe to scroll”.

## Security & Privacy
- The terminal session is authorized by the same provider auth token used for chat, plus server-side checks that:
  - The authenticated user is allowed to access the chat `sessionKey` associated with the terminal session.
- Do not embed hostnames, SSH credentials, or tmux server paths in client-visible descriptors beyond what is necessary.
- Rate limit input and enforce output caps to mitigate abuse.
- Provider should redact/disable terminal sessions for untrusted users or non-admin streams if needed (policy gate).

## Resource Limits (Provider)
To prevent terminal bubbles from becoming an easy resource exhaustion vector, provider MUST enforce limits (numbers TBD):
- Max active terminal sessions per user.
- Max active terminal sessions per chat `sessionKey`.
- Max total PTY processes across the provider.
- Max output buffered per session (see flow control).

## Session Updates (Chat Plane)
To keep bubble state accurate even when the terminal is detached, the provider SHOULD send a chat-plane update when the terminal session exits.

Suggested payload over the existing chat websocket:
```json
{
  "type": "event",
  "event": "terminal_session_update",
  "payload": {
    "terminalSessionId": "ts_8e1d",
    "state": "exited",
    "exitCode": 0
  }
}
```

Client behavior:
- When receiving `terminal_session_update`, update the corresponding terminal bubble header status (e.g., `EXIT 0`) without requiring a reconnect.

## Single-Attach Policy (Provider) (v1 Decision)
v1 behavior: **last-writer-wins**.
- If a second client attaches to the same `terminalSessionId`, the provider terminates the older WS attachment (detach) and allows the new one.
- Provider MAY send a final control frame to the old client before closing:
```json
{ "type": "terminal_error", "code": "replaced", "message": "Attached from another device." }
```
If this is implemented, add `replaced` to the error code list.

## Compatibility & Rollout Plan
1. Ship client support for parsing the special terminal-session document attachment (no new `AttachmentType` values yet).
2. Ship provider-side feature negotiation:
   - Only send terminal session attachments when client advertises `terminal_bubbles_v1`.
3. Later hardening:
   - Make attachment decoding tolerant of unknown `AttachmentType` values.
   - Introduce a first-class `AttachmentType.terminalSession` once safe.

Fallback behavior:
- If the client cannot parse the descriptor, it renders as a normal file attachment (document) and the message still displays.
- If terminal WS connect fails, show error state with `Reconnect` and optionally allow “View as text” (provider could also provide a static log snippet in `content`).

## Open Questions
Resolved by Flynn decisions:
- Personal-stream scope for Clawline streams: `agent:main:clawline:{userId}:main` and `agent:main:clawline:{userId}:s_*`; `...:main` has no elevated rendering privilege.
- Auto-connect immediately on render.
- No bubble chrome; sizing and scroll capture match HTML link previews.
- Expand opens a larger pane via a NEW connection (tmux backfill restores scrollback).
- No TTL/expiry in v1.
- Dead-session UX shows name + Reconnect.
- Client tears down offscreen sessions aggressively; reconnect is cheap.
