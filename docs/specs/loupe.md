# Surf Ace

Status: Design draft
Last updated: 2026-02-25
Depends on: `specs/clawline-invariants.md`, `specs/generative-ui-guidance.md`

## 2. What Is a Surf Ace

A surf ace is a screen that CLU can draw on. Any screen — phone, tablet, monitor, Vision Pro window, LED ticker. CLU pushes content to it, the user looks at it, and CLU knows what they're looking at.

Surf Aces are not apps. They don't have opinions about what to show. They render what CLU tells them to render and report back what the user is doing — scrolling, selecting, drawing. CLU decides everything else.

## 1. Concept

A jeweler's surf-ace is pressed against something to look closely. Surf Ace is the same idea applied to screens: CLU presses content against a display so you can examine it together.

Surf Ace is a standalone app — separate from Clawline, own codebase, own binary. It turns any device into a dumb screen that CLU can push content to. A Mac, an iPad, a Raspberry Pi with a monitor, a Vision Pro window. The screen broadcasts itself on the local network. CLU's provider on TARS discovers it, connects, and starts pushing content. The screen renders what it's told and reports what the user is looking at.

Screens are ownerless. Like a projector in a conference room — it doesn't belong to anyone. You walk up, pair with it, use it, leave. The screen forgets you.

Phone-specific contextual interactions are just surf ace behavior on one surf ace.

## 2. Goal

1. **Standalone app.** Surf Ace is its own app for iOS, iPadOS, macOS, visionOS (one SwiftUI codebase) and Linux (Electron). Not embedded in Clawline.
2. **Zero-config discovery.** Screens broadcast `_surf-ace._tcp` on Bonjour. CLU's provider discovers them automatically. No registry, no manual setup.
3. **Direct connection.** The provider on TARS is on the LAN. It connects to screens via HTTP directly. No relay, no phone middleman.
4. **Ownerless screens.** No user accounts, no persistent ownership. Session-scoped.
5. **Shared screens.** Visit a friend's house, their screens show up. AirPlay-style PIN pairing for untrusted screens. Trusted screens auto-connect.
6. **CLU decides.** CLU decides what goes on which screen. Screens don't decide anything.

## 3. Non-Goals

1. Embedding Surf Ace inside Clawline. They are separate apps.
2. Cloud-hosted screen connections. Screens are local network only.
3. Multi-user on one screen simultaneously. One session per screen.
4. Screen-to-screen communication. All coordination goes through CLU.
5. Video or audio streaming. Content is document-like.
6. Persistent screen state. Screens are stateless across sessions.


## 5. Architecture

```
┌───────────┐  ┌───────────┐  ┌───────────┐
│  Surf Ace    │  │  Surf Ace    │  │  Surf Ace    │
│  macOS    │  │  iPad     │  │  Raspi    │
│  Monitor  │  │  Kitchen  │  │  Office   │
└─────┬─────┘  └─────┬─────┘  └─────┬─────┘
      │               │               │
      │  _surf-ace._tcp  │  _surf-ace._tcp  │  _surf-ace._tcp
      │               │               │
      └───────────────┼───────────────┘
                      │  LAN (HTTP)
               ┌──────┴──────┐
               │    TARS     │
               │  Provider   │     ← mDNS browser discovers screens
               │  CLU        │     ← HTTP to each paired screen
               └──────┬──────┘
                      │  (existing Clawline WS, may traverse Tailscale)
               ┌──────┴──────┐
               │  Clawline   │
               │  (phone)    │     ← chat with CLU
               └─────────────┘
```

**TARS connects directly.** The provider runs an mDNS browser, discovers screens on the LAN, and talks to them over HTTP. No intermediary. No persistent socket needed for basic operation.

**Protocol is HTTP, both directions.** Each screen runs a tiny HTTP server. The provider POSTs frames to it and GETs snapshots from it. The provider also runs an HTTP server (port 18800, already exists). When the screen has events to report (watch mode, pencil strokes), it POSTs to the provider's callback URL. Every request is stateless and self-contained. No persistent socket, no connection state, no reconnect logic. If a socket is ever needed later for high-frequency events, same payloads, trivial upgrade.

**Two surf ace intake paths.** Standalone screens are discovered via Bonjour — the provider reaches out. Spawned surf aces (e.g., Apple Pencil annotation on a chat bubble) phone home over Clawline's existing WebSocket. Both paths end the same way: the provider has an address and can push frames or request snapshots.

**Clawline and Surf Ace are separate apps.** On iPhone, the user runs one at a time — foreground determines which. On iPad, they run side-by-side in split view. On Vision Pro, they're separate windows. On macOS, they're separate apps.

**Surf Ace on a phone IS a screen.** When the Surf Ace app is in the foreground on an iPhone that's on the same LAN as TARS, it broadcasts `_surf-ace._tcp` and TARS connects to it like any other screen. The phone is just another dumb display.

## 6. Screen Protocol

### 6.1 Bonjour Advertisement

Every Surf Ace instance broadcasts:

Service type: `_surf-ace._tcp`

TXT records:

| Key | Value | Example |
|---|---|---|
| `name` | Human-readable screen name | `Kitchen Display` |
| `v` | Protocol version | `1` |
| `w` | Viewport width (points) | `1920` |
| `h` | Viewport height (points) | `1080` |
| `s` | Display scale factor | `2` |
| `cap` | Content type bitmask | `31` |
| `busy` | Active session exists | `0` or `1` |
| `pk` | Public key fingerprint (first 8 hex of SHA-256) | `a1b2c3d4` |

Content type bitmask:

| Bit | Type |
|---|---|
| 1 | `html` |
| 2 | `image` |
| 4 | `pdf` |
| 8 | `terminal` |
| 16 | `markdown` |

`busy` is updated in real-time as sessions start and end. The provider uses this to avoid connecting to occupied screens.

### 6.2 Screen Identity

On first launch, the Surf Ace app generates an Ed25519 keypair. The public key is the screen's identity — stable across reboots. The fingerprint (first 8 hex of SHA-256 of the public key) is advertised in the `pk` TXT record.

The private key proves identity during the TLS handshake (self-signed cert derived from the keypair). The keypair is the only persistent state on the screen.

### 6.3 Surf Ace API

Each screen runs a tiny HTTPS server. The provider POSTs to the screen to push content and GETs to read state. The screen POSTs outbound to the provider for events (watch mode, pencil strokes).

**Screen HTTP server (provider → screen):**

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/pair` | Create session (PIN exchange or auto-connect) |
| `POST` | `/frame` | Push a content frame |
| `POST` | `/frame/append` | Append to terminal frame |
| `POST` | `/frame/patch` | Patch HTML frame |
| `DELETE` | `/frame` | Clear screen content |
| `GET` | `/snapshot` | Get current screen state |
| `POST` | `/watch` | Subscribe to real-time events |
| `POST` | `/unwatch` | Unsubscribe from events |

**Provider HTTP server (screen → provider):**

The provider's existing HTTP server on port 18800 receives events from screens at a new path:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/surf-ace/events/<screenId>` | Watch mode events, pencil strokes, debounced snapshots |

The screen learns the callback URL from `POST /watch`. All outbound POSTs from the screen go to this URL. Each POST is self-contained — no session state on the wire.

TLS uses the screen's self-signed certificate (derived from its Ed25519 keypair) for the screen's server. The provider pins the public key after first pairing. The provider's server uses its own certificate (already configured).

All screen-side endpoints except `POST /pair` require `Authorization: Bearer <sessionToken>`. The session token is returned by a successful `POST /pair`.

### 6.4 Session Lifetime

Sessions have **no TTL**. Content stays on screen indefinitely until the provider explicitly clears it, pushes a new frame, or the network connection is lost. If you're sitting there reading, nothing disappears.

When the session ends:
- Screen clears all content.
- Screen goes idle, sets `busy=0` in Bonjour TXT.
- Session token is invalidated.

The provider can also end a session explicitly by sending `DELETE /frame` followed by not renewing. There is no explicit disconnect endpoint — TTL expiry handles cleanup.

### 6.5 Occupancy

One active session per screen. If a second client sends `POST /pair` while the screen is busy:

```
409 Conflict
{ "error": "busy" }
```

The provider sees `busy=1` in Bonjour TXT and skips connection attempts.

### 6.6 Grace Period

When the provider stops sending requests (crash, network blip, iPhone app backgrounded), the screen doesn't immediately go idle. The screen holds the last displayed frame until the provider reconnects or a network timeout is detected.

For iPhone backgrounding specifically: user switches away from Surf Ace, Surf Ace's HTTP server may become unreachable (iOS suspends it). The provider can't reach the screen. When the user switches back, Surf Ace wakes up, the server comes back online. The provider's next request (frame push or snapshot) resets the TTL and the session continues. If the provider becomes permanently unreachable (e.g., TARS goes offline), the screen holds the last frame indefinitely. It only goes idle on explicit clear or app quit.

The provider holds its own session state (current frame, source refs) so it can re-push the current frame on reconnect without asking CLU.

### 6.7 Error Reporting

Errors are reported via HTTP response codes on frame push requests:

```
POST /frame → 200 OK (rendered successfully)
POST /frame → 422 Unprocessable Entity
{
  "error": {
    "code": "render_failed",
    "message": "HTML exceeded maximum DOM node count"
  }
}
```

Error codes:
- `render_failed` — content couldn't be rendered.
- `content_too_large` — frame payload exceeds screen's memory budget.
- `unsupported_type` — content type not in screen's capability set.
- `decode_failed` — base64 or payload couldn't be decoded.

In watch mode, errors during live updates (append/patch) are reported as error events on the callback URL.

The provider surf aces errors to CLU so it can retry with different content or choose a different screen.

## 7. Discovery and Pairing

### 7.1 Provider-Side Discovery

The provider on TARS runs an mDNS browser for `_surf-ace._tcp`. Discovered screens are parsed from TXT records into an in-memory screen table:

```typescript
interface DiscoveredScreen {
  instanceName: string       // Bonjour instance name
  host: string               // resolved IP/hostname
  port: number               // resolved port
  name: string               // from TXT "name"
  protocolVersion: number    // from TXT "v"
  width: number              // from TXT "w"
  height: number             // from TXT "h"
  scale: number              // from TXT "s"
  contentTypes: number       // from TXT "cap" bitmask
  busy: boolean              // from TXT "busy"
  fingerprint: string        // from TXT "pk"
  status: 'discovered' | 'pairing' | 'paired' | 'busy'
}
```

The screen table is ephemeral — rebuilt from live mDNS on provider restart. No database persistence.

### 7.2 Trust Store

The provider maintains a trust store (persisted to disk as JSON) mapping screen fingerprints to trusted status:

```typescript
interface TrustedScreen {
  fingerprint: string        // 8 hex chars from pk TXT
  publicKey: string          // full Ed25519 public key, hex
  displayName: string        // name at time of trust
  trustedAt: number          // epoch ms
}
```

When a discovered screen's `pk` matches a trusted entry, the provider auto-connects without PIN. Otherwise, PIN pairing is required.

### 7.3 Auto-Connect (v1 Home Networks)

For v1, auto-connect without auth is fine on home networks. When the provider discovers a screen:

1. If `busy=1`, skip.
2. If the screen's fingerprint is in the trust store, connect via `POST /pair` with auto mode.
3. If the screen is unknown, leave it in `discovered` state until CLU or the user initiates pairing.

**Auto-connect flow:**

```
Provider                                Screen
   │                                       │
   ├── POST /pair                          │
   │   { "mode": "auto" }  ─────────────► │
   │                                       │  (screen checks: not busy)
   │  ◄── 200 OK                           │
   │   { "sessionToken": "<token>" }  ──── │
   │                                       │
   │  [provider verifies TLS cert pk       │
   │   matches trusted fingerprint]        │
   │                                       │
   │  [session active, provider can        │
   │   now POST /frame, GET /snapshot]     │
```

The provider verifies the screen's TLS certificate public key matches the trusted fingerprint. If it doesn't match (screen was reset, or MITM), the provider refuses and marks the screen as untrusted.

### 7.4 PIN Pairing (Untrusted Screen)

When CLU wants to use an untrusted screen, or the user asks to pair one:

```
Provider                                Screen
   │                                       │
   ├── POST /pair                          │
   │   { "mode": "pin" }  ──────────────► │
   │                                       │  ← screen shows "1847"
   │  ◄── 200 OK                           │
   │   { "status": "pin_required",         │
   │     "pin_hash": "<sha256>",           │
   │     "nonce": "<32 hex bytes>" }  ──── │
   │                                       │
   │  [CLU asks user for PIN via           │
   │   Clawline chat: "Kitchen Display     │
   │   is showing a PIN. What is it?"]     │
   │                                       │
   ├── POST /pair                          │
   │   { "mode": "pin",                   │
   │     "pin": "1847",                    │
   │     "nonce": "<32 hex bytes>" } ────► │
   │                                       │
   │  ◄── 200 OK                           │
   │   { "status": "ok",                   │
   │     "sessionToken": "<token>" }  ──── │
   │                                       │
   │  [provider stores screen pubkey       │
   │   in trust store]                     │
```

PIN details:
- 4-digit numeric (0000–9999). Displayed large and centered on the screen.
- Valid for 60 seconds, then auto-rotates.
- `pin_hash` = SHA-256(pin + nonce). The provider can't learn the PIN from the challenge.
- 3 failed attempts = 30-second lockout.
- CLU asks the user for the PIN via Clawline chat. The user reads the number off the physical screen and types it into chat. CLU relays it to the provider.

### 7.5 Session Lifecycle

A session starts at `POST /pair` success and ends when:
1. The provider explicitly clears the frame or becomes permanently unreachable.
2. The screen is shut down.
3. The screen is power-cycled or factory-reset.

On session end, the screen clears all content, goes idle, and sets `busy=0`.

There is no explicit disconnect endpoint. The provider simply stops sending requests. The provider explicitly clears frames when done. No silent timeouts.

## 8. Content Frames

### 8.1 Pushing a Frame

```
POST /frame
Authorization: Bearer <sessionToken>
Content-Type: application/json

{
  "frameId": "fr_<8hex>",
  "contentType": "html",
  "content": {
    "html": "<html>...</html>"
  },
  "display": {
    "title": "Build Output",
    "scrollable": true,
    "interactive": false
  }
}
```

Response: `200 OK` on success, `422` with error body on failure.

One screen, one frame. Pushing a new frame replaces the old one. `frameId` is generated by the provider (8 lowercase hex chars, prefixed `fr_`).

### 8.2 Content Types

| Type | `content` shape | Limits |
|---|---|---|
| `html` | `{ html: string, baseUrl?: string }` | 256KB |
| `image` | `{ data: string, mediaType: string, alt?: string }` | 10MB (base64) |
| `pdf` | `{ data: string }` | 10MB (base64) |
| `terminal` | `{ lines: string[], scrollback: number }` | 10,000 lines |
| `markdown` | `{ markdown: string }` | 64KB |

Images and PDFs are base64-encoded inline. Screens are local devices with no guaranteed internet access. All content must be self-contained.

### 8.3 Source References

Source references link frame content back to a Clawline stream message. They are provider-side metadata — never sent to the screen. The screen has no concept of session keys or streams.

The provider maintains a mapping: `(screenFingerprint, frameId) → sourceRef`. When the screen reports viewport or selection, the provider attaches the source ref before including it in CLU's context.

```typescript
interface SourceRef {
  sessionKey: string
  messageId: string
}
```

### 8.4 Live Updates

**Append (terminal):**

```
POST /frame/append
Authorization: Bearer <sessionToken>
Content-Type: application/json

{
  "frameId": "fr_8e9f0a1b",
  "append": {
    "lines": ["[14:32:01] Build succeeded", "[14:32:01] Running tests..."]
  }
}
```

**Patch (HTML):**

```
POST /frame/patch
Authorization: Bearer <sessionToken>
Content-Type: application/json

{
  "frameId": "fr_8e9f0a1b",
  "patch": {
    "selector": "#build-status",
    "action": "replace_inner",
    "html": "<span class='success'>Passed</span>"
  }
}
```

Patch actions: `replace_inner`, `replace_outer`, `insert_before`, `insert_after`, `remove`.

Rules:
1. Append: only for `terminal`. Patch: only for `html`.
2. Stale `frameId` → `409 Conflict` with `{ "error": "stale_frame" }`.
3. Response: `200 OK` on success, `422` on render error.

### 8.5 Clear

```
DELETE /frame
Authorization: Bearer <sessionToken>
```

Response: `204 No Content`.

Screen clears content. Shows connected-idle state (screen name, subtle "connected" indicator).

### 8.6 Frame Lifecycle

```
POST /frame (new)         → [active, rendering]
POST /frame/append        → [active, updating]
POST /frame/patch         → [active, updating]
POST /frame (replace)     → old frame discarded, new frame active
DELETE /frame             → [connected, idle]
provider clears frame     → [idle, standby]
```

## 9. Snapshot and Watch Mode

Two ways to know what's on a screen: ask (snapshot) or subscribe (watch). Snapshot is the default. Watch is opt-in for real-time awareness.

### 9.1 Query-Time Snapshot (Default)

When the user sends a message, the provider queries each active surf ace for its current state. One GET per surf ace, attached to the user's message as context. Zero idle token cost — only queries when the user asks something.

```
GET /snapshot
Authorization: Bearer <sessionToken>
```

Response:

```json
{
  "frameId": "fr_8e9f0a1b",
  "contentType": "html",
  "title": "Build Output",
  "viewport": {
    "scrollOffset": { "x": 0, "y": 1240 },
    "visibleRect": { "x": 0, "y": 1240, "width": 1920, "height": 1080 },
    "contentSize": { "width": 1920, "height": 4800 },
    "zoomLevel": 1.0
  },
  "visibleText": "[text content currently visible on screen]",
  "selection": null,
  "annotations": []
}
```

`visibleText` is the screen's extraction of what's currently visible in the viewport:
- **HTML:** DOM `textContent` of elements intersecting the visible rect.
- **Terminal:** The visible lines.
- **Markdown:** Rendered text in the visible region.
- **PDF:** Text on the visible page(s).
- **Image:** The `alt` text.

Truncated to 4KB. This keeps CLU's context window manageable.

`selection` is the current user selection, if any:

```json
{
  "kind": "text",
  "text": "Error: connection refused on port 8080",
  "boundingRect": { "x": 12, "y": 1340, "width": 360, "height": 20 }
}
```

Selection kinds: `text` (highlighted range), `point` (tap/long-press), `region` (drawn rectangle).

`annotations` is reserved for future use (pencil strokes, circles, arrows). Empty array in v1.

This is the core of contextual awareness. User says "what's this error?" → provider GETs snapshot from each screen → one screen has a text selection of "Error: connection refused" → CLU answers contextually.

### 9.2 Watch Mode (Opt-In Streaming)

For real-time awareness, the provider subscribes to events from a screen.

**Subscribe:**

```
POST /watch
Authorization: Bearer <sessionToken>
Content-Type: application/json

{
  "callbackUrl": "https://tars.local:18789/surf-ace/events/sf_a1b2c3d4",
  "events": ["text_selected", "point", "region", "scroll_settle", "zoom_settle", "page_change"],
  "debounce": {
    "scroll_settle": 500,
    "zoom_settle": 500,
    "text_selected": 0,
    "point": 0,
    "region": 0,
    "page_change": 0
  }
}
```

Response: `200 OK`.

The screen POSTs discrete events to the callback URL as they happen. All events fire on settled state, not continuously — the screen debounces internally per the provided config.

**Unsubscribe:**

```
POST /unwatch
Authorization: Bearer <sessionToken>
```

Response: `200 OK`. Screen stops sending events.

### 9.3 Watch Mode Events (v1)

All events POSTed to the callback URL as JSON. Selection and navigation events only in v1.

**`text_selected`** — user highlighted text:

```json
{
  "event": "text_selected",
  "frameId": "fr_8e9f0a1b",
  "text": "Error: connection refused on port 8080",
  "boundingRect": { "x": 12, "y": 1340, "width": 360, "height": 20 },
  "timestamp": 1771905600000
}
```

**`point`** — user tapped or long-pressed:

```json
{
  "event": "point",
  "frameId": "fr_8e9f0a1b",
  "position": { "x": 450, "y": 1340 },
  "nearestContent": "connection refused on port 8080",
  "timestamp": 1771905600000
}
```

**`region`** — user drew a selection rectangle:

```json
{
  "event": "region",
  "frameId": "fr_8e9f0a1b",
  "rect": { "x": 10, "y": 1300, "width": 400, "height": 100 },
  "containedText": "Error: connection refused on port 8080\nRetrying in 5s...",
  "timestamp": 1771905600000
}
```

**`scroll_settle`** — user stopped scrolling:

```json
{
  "event": "scroll_settle",
  "frameId": "fr_8e9f0a1b",
  "viewport": {
    "scrollOffset": { "x": 0, "y": 1240 },
    "visibleRect": { "x": 0, "y": 1240, "width": 1920, "height": 1080 },
    "contentSize": { "width": 1920, "height": 4800 },
    "zoomLevel": 1.0
  },
  "visibleText": "[visible text at settled position]",
  "timestamp": 1771905600000
}
```

**`zoom_settle`** — user finished pinch-zoom:

```json
{
  "event": "zoom_settle",
  "frameId": "fr_8e9f0a1b",
  "viewport": {
    "scrollOffset": { "x": 0, "y": 600 },
    "visibleRect": { "x": 0, "y": 600, "width": 960, "height": 540 },
    "contentSize": { "width": 1920, "height": 4800 },
    "zoomLevel": 2.0
  },
  "visibleText": "[visible text at settled zoom]",
  "timestamp": 1771905600000
}
```

**`page_change`** — PDF page navigation:

```json
{
  "event": "page_change",
  "frameId": "fr_8e9f0a1b",
  "page": 3,
  "totalPages": 12,
  "pageText": "[text on the new page]",
  "timestamp": 1771905600000
}
```

### 9.4 Future Watch Events (Not v1)

| Event | Trigger | Payload |
|---|---|---|
| `gaze_dwell` | Vision Pro gaze settled on area | Gaze point, dwell duration, content |

Pencil/stylus input is handled by the Pencil Markup System (§13), not watch mode. The surf ace sends raw strokes and screenshots — CLU interprets everything. No gesture recognition on the surf ace side.

### 9.5 Two-Tier Watch Processing

Raw watch events are noisy. Scroll events, zoom events — most of them don't need CLU's attention. Running every event through the main agent wastes tokens.

**Architecture:**

```
Screen events  →  Cheap/fast model (Haiku-level)  →  Main agent (only when actionable)
```

The provider routes real-time watch events to a cheap, fast model for pattern recognition. The cheap model filters noise and only escalates to the main CLU agent when something actionable happens.

**Examples of escalation:**
- `scroll_settle` alone → no escalation (user is just browsing).
- `text_selected` with error-like content → escalate ("user highlighted an error, they may ask about it soon").
- `scroll_settle` + `text_selected` + user sends a message within 5 seconds → escalate with full context.
- `point` on a specific UI element → escalate if the element is actionable.

**Examples of suppression:**
- Rapid scroll_settle events (user scanning through a document) → suppress all, cache latest position.
- zoom_settle without selection → suppress (user is just adjusting view).

**Cost model:** The cheap model processes watch events at ~0.1% the token cost of the main agent. A screen producing 100 events/minute costs negligible tokens. Only escalated events (maybe 2-3/minute) hit the main agent.

The two-tier model is a provider-side concern. The screen knows nothing about it. The screen just POSTs events to the callback URL.

## 10. CLU Integration

### 10.1 Provider Screen Management

The provider maintains the screen table in memory. It exposes screen state to CLU through:

1. **System prompt injection.** On every user message, the provider queries snapshots and includes current screen context.
2. **`surf-ace_push` action.** CLU invokes this to push content to a screen.
3. **`surf-ace_pair` action.** CLU invokes this to initiate PIN pairing with an untrusted screen.
4. **`surf-ace_clear` action.** CLU invokes this to clear a screen.
5. **`surf-ace_watch` action.** CLU invokes this to start/stop watch mode on a screen.

### 10.2 Query-Time Context Injection

When processing a user message, the provider:

1. Identifies all paired screens (Bonjour-discovered and spawned).
2. Sends `GET /snapshot` to each one.
3. Attaches source refs from the provider's mapping.
4. Injects the combined context into CLU's system prompt.

```
## Surf Ace Screens
- "Kitchen Display" (1920x1080, paired): showing terminal "Build Output"
  visible: [last 30 lines of build output...]
  selection: none
- "Office Monitor" (2560x1440, paired): showing HTML "Diff View"
  visible: [visible portion of diff...]
  selection: "Error: connection refused on port 8080"
- "Living Room TV" (3840x2160, available — not paired)
```

**Zero idle cost.** When the user isn't sending messages, no snapshots are requested, no tokens are spent. Context is assembled on-demand at message time.

### 10.3 CLU Actions

**`surf-ace_push`** — push a frame to a paired screen:

```json
{
  "action": "surf-ace_push",
  "screen": "Kitchen Display",
  "contentType": "html",
  "content": { "html": "<html>...</html>" },
  "title": "Build Output",
  "sourceRef": {
    "sessionKey": "agent:main:clawline:flynn:main",
    "messageId": "s_123"
  }
}
```

`screen` is the human-readable name. The provider resolves it to a fingerprint and address. If ambiguous (two screens with the same name), the provider asks CLU to disambiguate.

**`surf-ace_pair`** — initiate PIN pairing:

```json
{
  "action": "surf-ace_pair",
  "screen": "Living Room TV"
}
```

The provider sends `POST /pair` to the screen, receives the PIN challenge, and CLU asks the user via Clawline chat: "The Living Room TV is showing a 4-digit code. What is it?" User responds, CLU relays, pairing completes.

**`surf-ace_clear`** — clear a screen:

```json
{
  "action": "surf-ace_clear",
  "screen": "Kitchen Display"
}
```

**`surf-ace_watch`** — start or stop watch mode:

```json
{
  "action": "surf-ace_watch",
  "screen": "Office Monitor",
  "enabled": true,
  "events": ["text_selected", "point", "scroll_settle"]
}
```

### 10.4 Contextual Awareness Flow

User says "what's this error?" in Clawline:

1. Provider receives message, sends `GET /snapshot` to each paired screen.
2. "Office Monitor" snapshot returns: selection "Error: connection refused on port 8080".
3. Provider attaches the source ref (frame came from message s_123 in main stream).
4. Provider injects screen context into CLU's system prompt.
5. CLU sees the selection, the frame title ("Build Output"), and the source ref.
6. CLU answers contextually, referencing both the screen content and the conversation history.

### 10.5 Screen Addressing

Users reference screens by name in Clawline chat:

> "Show this on the kitchen display"
> "Pull up the diff on the big monitor"
> "Clear the office screen"

CLU resolves names using the screen table. Ambiguity resolved by asking.

## 11. Spawned Surf Aces

### 11.1 Concept

Not all surf aces are standalone screens discovered on the network. Some surf aces are born inside Clawline — temporary, purpose-built, and pre-wired to a conversation.

The canonical example: user picks up Apple Pencil and starts drawing on a chat bubble in Clawline. Clawline captures a screenshot of that bubble, creates a temporary Surf Ace surf ace, and tells the provider about it immediately. The user draws annotations (circles, arrows, highlights), then lifts the pencil or hits send. The annotated screenshot goes to CLU as context with the message. The temporary surf ace disappears.

This also works in the Surf Ace app itself — pencil on pushed content creates an annotation layer.

### 11.2 Spawn Flow

```
Clawline App                                    Provider
     │                                              │
     │  [user picks up Apple Pencil,                │
     │   starts drawing on a chat bubble]           │
     │                                              │
     │  [Clawline captures screenshot,              │
     │   spins up a temporary HTTP server]          │
     │                                              │
     ├── (existing Clawline WebSocket) ───────────► │
     │   { "type": "surf ace_spawned",               │
     │     "surf aceId": "sp_<8hex>",                │
     │     "streamKey": "agent:main:clawline:...",  │
     │     "callbackUrl": "https://phone:port/..." }│
     │                                              │
     │  [provider now knows about the surf ace,      │
     │   which stream it belongs to, and            │
     │   where to reach it]                         │
     │                                              │
     │  [user draws annotations...]                 │
     │                                              │
     │  [user lifts pencil or taps send]            │
     │                                              │
     ├── (existing Clawline WebSocket) ───────────► │
     │   { "type": "surf ace_submitted",             │
     │     "surf aceId": "sp_<8hex>" }               │
     │                                              │
     │  [provider GETs /snapshot from               │
     │   the spawned surf ace to capture             │
     │   annotations, then attaches to              │
     │   the user's message context]                │
     │                                              │
     │  [surf ace disappears]                        │
```

### 11.3 Key Properties

- **Zero discovery latency.** The surf ace is pre-wired at birth — the `surf ace_spawned` message over the existing Clawline WebSocket tells the provider everything it needs (address, stream context).
- **No new API endpoint.** Uses the existing Clawline WebSocket. `surf ace_spawned` and `surf ace_submitted` are new message types on an existing connection.
- **Same API on the surf ace.** The spawned surf ace runs the same HTTP server as a standalone Surf Ace screen (GET /snapshot works). The provider doesn't need to know if it's talking to a standalone screen or a spawned surf ace.
- **Stream-bound.** The `streamKey` in the spawn message tells the provider which conversation this annotation belongs to. Source ref is automatic.
- **Ephemeral.** The surf ace exists only for the duration of the annotation. After submission, it's gone. No cleanup needed — the HTTP server shuts down with the annotation session.

### 11.4 Annotation as Context

When the user submits the annotation, the provider `GET /snapshot`s the spawned surf ace. The snapshot includes:
- The original screenshot.
- Any drawn annotations (strokes, circles, arrows, text notes) as an overlay.
- Any text selections within the screenshot.

This snapshot is attached to the user's message as visual context. CLU sees the annotated screenshot and can reason about what the user circled, pointed at, or highlighted.

## 12. Two Surf Ace Intake Paths

The provider has two ways to learn about surf aces:

### 12.1 Path 1: Bonjour Discovery (Standalone Screens)

- Screen broadcasts `_surf-ace._tcp` on the LAN.
- Provider's mDNS browser discovers it.
- Provider initiates pairing via `POST /pair`.
- Provider manages the session.

**Provider reaches out to the surf ace.**

### 12.2 Path 2: `surf ace_spawned` Message (Spawned Surf Aces)

- User triggers an annotation in Clawline or Surf Ace.
- App sends `surf ace_spawned` over its existing WebSocket to the provider.
- Provider receives the callback URL and connects immediately.

**Surf Ace phones home to the provider.**

### 12.3 Convergence

Both paths end the same way: the provider has a surf ace address (host + port) and a session (token for standalone, inherent for spawned). It can `POST /frame`, `GET /snapshot`, `POST /watch` — the same Surf Ace API regardless of how the surf ace was discovered.

The provider's screen table holds both types:

```typescript
interface ActiveSurf Ace {
  id: string                   // fingerprint for standalone, sp_<hex> for spawned
  name: string
  address: string              // host:port
  sessionToken: string | null  // null for spawned (no pairing needed)
  intake: 'bonjour' | 'spawned'
  streamKey: string | null     // set for spawned, null for standalone
  sourceRef: SourceRef | null
  // ... capabilities, viewport, etc.
}
```

CLU doesn't need to know which intake path was used. It just sees "Kitchen Display" and "annotation on message s_123" as available surf aces.

## 13. Pencil Markup System

The user can draw on any Surf Ace surf ace with Apple Pencil (or mouse, or finger). CLU interprets the strokes in context and responds by modifying the surf ace content in real-time.

This is not an annotation overlay. It's a conversation with CLU through ink.

### 13.1 No Prescribed Gesture Vocabulary

The surf ace does NOT interpret strokes. No gesture recognition on the surf ace side. No circle detector, no arrow detector, no handwriting recognizer. The surf ace captures raw stroke paths and screenshots, sends them to the provider, and CLU does all interpretation using vision models.

The model is smart enough to figure out intent from raw strokes + visual context + change history. Examples of things that just work without explicit gesture code:

- Scribble out text → CLU deletes it.
- Write a word between other words → CLU inserts it.
- Draw a rough circle around something → CLU cleans it to a perfect circle, or interprets it as "look at this."
- Underline something → CLU emphasizes it.
- Write a correction over a word → CLU replaces the word.
- Draw a rough table or flowchart → CLU snaps it to a clean version.
- Write `?` next to something → CLU explains it.
- Write a name → CLU pops up contextual info about that person/thing.
- Write `oops` next to a deletion → CLU undoes the change.
- Draw an arrow from A to B → CLU moves A to B, or connects them, depending on context.
- Cross out an entire paragraph → CLU removes it.
- Draw a bracket spanning multiple items → CLU groups them.

None of these are coded as gestures. The model infers intent from strokes + visual context + what CLU has already placed on the surf ace + the conversation history.

### 13.2 Two Debounce Tiers

The surf ace runs two debounce timers for stroke input:

**Short debounce (~500ms after pencil lifts):** Sends the raw strokes plus a local crop screenshot of the area around the strokes. Covers instant-feedback interactions — corrections, insertions, quick annotations. CLU responds fast with local context.

**Long debounce (~3–5s of no new strokes):** Sends a full surf ace screenshot plus all strokes since the last full snapshot. CLU does a holistic pass — catches cross-surf ace connections, cleans up stale artifacts, fixes anything the short pass missed, resolves ambiguities.

Short gives speed. Long gives completeness. Both are single-pass, no correction loops.

The user experiences it as: *magic happened immediately, then a moment later it got even smarter.*

### 13.3 What the Surf Ace Sends

Both payloads are POSTed to the provider's callback URL (same as watch mode events, at `/surf-ace/events/<screenId>`).

**Short debounce payload:**

```json
{
  "event": "strokes",
  "frameId": "fr_8e9f0a1b",
  "strokes": [
    {
      "points": [
        { "x": 120, "y": 340, "pressure": 0.8, "timestamp": 1771905600000 },
        { "x": 125, "y": 342, "pressure": 0.7, "timestamp": 1771905600016 }
      ],
      "tool": "pencil"
    }
  ],
  "crop": "<base64 image of local area around strokes>",
  "cropRect": { "x": 80, "y": 300, "w": 200, "h": 120 },
  "timestamp": 1771905600500
}
```

**Long debounce payload:**

```json
{
  "event": "surf ace_snapshot",
  "frameId": "fr_8e9f0a1b",
  "image": "<base64 full surf ace screenshot>",
  "strokesSinceLastSnapshot": [
    {
      "points": [ ... ],
      "tool": "pencil"
    }
  ],
  "timestamp": 1771905604000
}
```

The crop screenshot shows the strokes rendered on top of the underlying content — exactly what the user sees. The full screenshot shows everything: CLU's pushed content, any previous CLU modifications, and all new strokes. This is the primary input for vision model interpretation.

`tool` is one of: `pencil` (Apple Pencil), `finger`, `mouse`. Pressure data is available for Pencil, absent for finger/mouse.

### 13.4 CLU Responds with Frame Updates

CLU interprets the strokes and responds by pushing updated content to the surf ace. Same `POST /frame` as regular content push. No special markup protocol.

CLU can:
- **Push a new frame** that incorporates the changes (deleted text removed, inserted text added, cleaned-up shapes replacing rough ones).
- **Patch the existing frame** via `POST /frame/patch` for small changes (replace a word, add emphasis).
- **Push artifacts** — info cards, expanded explanations, cleaned-up diagrams — as new frame content overlaid on or replacing the original.

The surf ace maintains a **change stack** — an ordered list of frames CLU has pushed during this session. This enables:
- CLU referencing previous changes ("undo the last thing I did").
- The user writing "oops" or scribbling to trigger undo — CLU pops the change stack and re-pushes the previous frame.
- CLU seeing its own modification history when interpreting new strokes in the long-debounce full screenshot.

### 13.5 Context Payload

What CLU receives to make interpretation decisions:

1. **Raw stroke paths** — what the user drew. Points, pressure, timestamps. No pre-interpretation.
2. **Screenshot** — local crop (short debounce) or full surf ace (long debounce). Shows strokes rendered on top of the underlying content. This is what the vision model sees.
3. **Underlying semantic content** — the actual text, HTML, or data beneath the strokes. Not just pixels. The provider knows what it pushed to the surf ace and attaches it.
4. **Change history** — what CLU has modified this session. Enables undo and prevents CLU from re-interpreting its own previous modifications as new user input.
5. **CLU's previously placed artifacts** — visible in the full screenshot. CLU can see what it already put on the surf ace and revise.
6. **Source ref** — which stream message this content came from, if any. Links the markup back to conversation context.

### 13.6 Speculative Interpretation with Revision

CLU's interpretation on the short debounce is provisional. The user may still be drawing.

Example: user writes "George Washington." Short debounce fires. CLU pops up an info card about George Washington. User continues writing "Carver." Long debounce fires with full screenshot. CLU sees "George Washington Carver" alongside its own previously placed George Washington card. CLU realizes the mistake, pushes an updated card for George Washington Carver.

No special revision protocol needed. CLU just pushes updated frames that replace previous content. The full screenshot on the long debounce shows CLU its own previous output alongside new strokes, giving it everything it needs to self-correct.

The change stack makes this clean: CLU pushes a speculative frame on short debounce, then pushes a corrected frame on long debounce. Both are recorded. If the user writes "no, the first one was right," CLU can reference the stack.

### 13.7 Two-Tier Processing

Same architecture as watch mode two-tier processing (§9.5):

```
Short debounce events  →  Cheap/fast model (Haiku-level)  →  Immediate surf ace updates
Long debounce events   →  Main agent                      →  Holistic pass, revisions
```

The cheap model handles short-debounce strokes: simple transforms, text insertion, deletion, emphasis. Fast feedback, low token cost. It has access to the crop screenshot and local context — enough for most instant interactions.

The main agent handles long-debounce snapshots: full-surf ace reasoning, cross-reference with conversation history, complex diagram cleanup, speculative revision. Higher cost, but fires much less frequently (every 3–5 seconds of idle, not every 500ms).

**Cost model:** Short debounce events average ~200 tokens each at Haiku pricing. A heavy markup session (user drawing constantly for 5 minutes) produces maybe 100 short events and 20 long events. Total cost is dominated by the 20 main-agent calls, which is comparable to 20 chat messages.

### 13.8 What the Surf Ace Does NOT Do

The surf ace has no intelligence about markup. Specifically:

- No gesture recognition (circle, arrow, underline, etc.).
- No handwriting recognition.
- No shape snapping or cleanup.
- No stroke classification.
- No intent inference.

The surf ace captures raw input, renders strokes as-is on a transparent overlay above the content, takes screenshots, and sends them to the provider. All interpretation is CLU's job. This keeps the surf ace dumb and ensures behavior improves as models improve, not as surf ace code is updated.

The surf ace does handle:
- PencilKit (Apple) or equivalent for smooth stroke capture and rendering.
- Pressure sensitivity for Apple Pencil.
- Palm rejection.
- Screenshot capture of the current rendered state with strokes overlaid.
- Debounce timers (500ms short, 3–5s long).
- Change stack (ordered list of frames received from the provider).

## 14. Surf Ace App

### 13.1 Platforms

| Platform | Framework | Notes |
|---|---|---|
| iOS | SwiftUI | Phone is a screen. Foreground = broadcasting. Background = HTTP server suspended, 5min TTL grace. |
| iPadOS | SwiftUI | Split view with Clawline. Or full-screen Surf Ace. |
| macOS | SwiftUI | Chromeless window option. Menu bar icon. |
| visionOS | SwiftUI | Separate window from Clawline. |
| Linux | Electron | Raspberry Pi, standalone monitors. Kiosk mode. |

One SwiftUI codebase for all Apple platforms. Electron for Linux.

### 13.2 What the App Does

1. **Generates identity** on first launch (Ed25519 keypair, stored in Keychain / filesystem).
2. **Broadcasts** `_surf-ace._tcp` with screen metadata in TXT records.
3. **Runs HTTP server** on the advertised port (Surf Ace API: /pair, /frame, /snapshot, /watch, /unwatch).
4. **Handles pairing** — PIN display or auto-connect acceptance.
5. **Renders content** — HTML (WKWebView / Electron webview), PDF (native viewer), images, terminal (monospace view), markdown (rendered view).
6. **Responds to snapshots** — extracts visible text, selection, viewport position on GET /snapshot.
7. **Reports events** — POSTs watch mode events and pencil stroke data to the provider's callback URL.
8. **Captures pencil input** — PencilKit (Apple) or equivalent for raw stroke capture, debounced at two tiers, with crop and full screenshots.
9. **Maintains change stack** — ordered history of frames received from the provider, enabling CLU-driven undo.
10. **Manages session** — one active session, 5-minute TTL, idle on expiry.

That's all. No CLU knowledge. No Clawline knowledge. No user accounts. No cloud connections. No gesture recognition. No handwriting recognition. No stroke interpretation. The surf ace is dumb. CLU is smart.

### 13.3 Screen States

```
┌──────────┐    pair     ┌──────────┐   frame   ┌──────────┐
│  Standby │───────────►│Connected │─────────►│Displaying│
│          │◄───────────│  (idle)  │◄─────────│          │
└──────────┘  TTL        └──────────┘   clear   └──────────┘
              expiry           ▲                      │
                               │    DELETE /frame     │
                               └──────────────────────┘
```

**Standby:** No active session. Screen shows its name and a subtle network indicator. Broadcasting `_surf-ace._tcp` with `busy=0`.

**Pairing:** PIN displayed large and centered. Waiting for response.

**Connected (idle):** Session active, no content pushed yet. Shows screen name and "Connected" indicator.

**Displaying:** Rendering a frame. Responding to GET /snapshot and watch mode events.

**TTL expiry:** Session timed out (5 minutes without any request). Screen clears content, transitions to Standby.

### 13.4 Standby Display

When idle, the screen shows:
- Screen name (large, centered).
- Network status icon.
- Public key fingerprint (small, bottom corner) for manual identification if needed.

No clock, no weather, no ambient content. Surf Ace is a tool, not a dashboard.

### 13.5 Content Rendering

| Content Type | Apple Platforms | Electron |
|---|---|---|
| `html` | `WKWebView` | Chromium webview |
| `image` | Native image view | `<img>` |
| `pdf` | `PDFKit` / `PDFView` | `pdf.js` |
| `terminal` | Custom monospace `NSAttributedString` view with ANSI color | `xterm.js` |
| `markdown` | Native markdown rendering | `marked` + custom CSS |

HTML frames use CSS variables for theming: `--surf-ace-bg`, `--surf-ace-fg`, `--surf-ace-accent`, `--surf-ace-font-size`, `--surf-ace-width`, `--surf-ace-height`. The Surf Ace app injects these based on screen characteristics.

### 13.6 iPhone Behavior

When the Surf Ace app is in the foreground:
- Broadcasting `_surf-ace._tcp`.
- HTTP server running, accepting requests, rendering content.
- User sees CLU's pushed content full-screen.

When the user switches to Clawline (or any other app):
- Surf Ace moves to background. iOS suspends the HTTP server.
- Provider can't reach the screen.
- Session TTL (5 minutes) acts as grace period.
- User switches back to Surf Ace within 5 minutes: HTTP server wakes up. Provider's next request resets TTL. Session continues. Provider re-pushes current frame if needed.
- User doesn't switch back within 5 minutes: session expires, screen goes idle.

This is fine. Background death on iPhone is expected and handled by the TTL.

### 13.7 iPad Behavior

iPad supports Split View and Slide Over. User can run Clawline on one side and Surf Ace on the other — chat with CLU while seeing CLU's pushed content. Both apps maintain their own connections: Clawline to the gateway (potentially over Tailscale), Surf Ace's HTTP server serving the provider on the LAN.

### 13.8 Vision Pro Behavior

Surf Ace runs as a separate window from Clawline. Multiple Surf Ace windows can exist, each a separate surf ace with its own Bonjour advertisement and session. CLU sees each window as a distinct screen.

### 13.9 macOS Behavior

Surf Ace runs as a regular macOS app. Options:
- Windowed mode: resizable window.
- Chromeless mode: borderless window for dedicated displays.
- Menu bar mode: Surf Ace runs in the background, activates a window when content is pushed.

### 13.10 Linux / Electron Behavior

Electron app with kiosk mode for dedicated displays (Raspberry Pi). Uses system-level mDNS (Avahi on Linux) for Bonjour advertisement. HTTP server via Node.js. Renders HTML via Chromium, other types via JS libraries.

## 15. Security

### 15.1 Pairing as Authentication

PIN pairing proves physical proximity — the user can see the screen's display. After first pairing, the provider trusts the screen's public key. Future connections verify identity via TLS certificate pinning.

Auto-connect without PIN is fine for v1 on home networks. The provider auto-connects to trusted screens. For untrusted screens, CLU asks the user for the PIN via Clawline chat.

### 15.2 Transport

All Surf Ace API requests use HTTPS with the screen's self-signed certificate (derived from its Ed25519 keypair). The provider pins the public key after first pairing. No CA chain needed.

Prevents passive eavesdropping on the LAN. Active MITM is prevented by public key pinning.

### 15.3 Session Tokens

Session tokens are opaque random strings (32 bytes, hex-encoded) generated by the screen on successful pairing. Tokens are short-lived (5-minute TTL, refreshed on use). A stolen token expires quickly. Tokens are transmitted only over TLS.

### 15.4 Screen Impersonation

A malicious device broadcasting `_surf-ace._tcp` with a spoofed name. Mitigated by:
1. PIN pairing requires visual verification of the physical screen.
2. After trust, public key pinning catches identity changes.
3. If a trusted screen's key changes (factory reset or impersonation), the provider flags it and requires re-pairing.

### 15.5 Content on Shared Screens

Content pushed to screens is visible to anyone in the room. This is inherent to physical displays. CLU should be aware that Surf Ace screens are physically public and avoid pushing sensitive content unless explicitly asked.

### 15.6 Watch Mode Callback Security

The callback URL for watch mode points to the provider (TARS). Events from the screen are POSTed to this URL over HTTPS. The provider validates that incoming events match an active watch subscription (by source IP and session). Spoofed events from other devices are rejected.

## 16. Edge Cases

### 16.1 Screen Unreachable

Provider sends POST /frame but the screen is unreachable (powered off, network gone). HTTP request times out. Provider marks the screen as unreachable, retries with exponential backoff. After 3 failures, marks screen as disconnected. If the screen reappears on mDNS later, provider re-pairs.

### 16.2 Provider Restart

TARS restarts. Provider rebuilds screen table from mDNS. Sessions on screens haven't expired yet (5-minute TTL). Provider re-pairs with trusted screens and can resume pushing content. Screens that have expired their TTL during the restart window will need fresh pairing.

### 16.3 Screen Name Collision

Two screens named "Monitor" on the same network. Provider disambiguates by fingerprint. CLU reports to user: "There are two screens named 'Monitor'. Which one? Monitor (a1b2) or Monitor (c3d4)?"

### 16.4 Content Too Large

Provider sends a 256KB HTML frame to a screen with limited memory. Screen responds `422` with `content_too_large`. Provider surf aces to CLU. CLU retries with simpler content or chooses a different screen.

### 16.5 No Screens on Network

No Surf Ace screens discovered. CLU falls back to inline display — generative UI bubbles in Clawline chat. Surf Ace enhances the experience when screens are available but never requires them.

### 16.6 Screen Factory Reset

Screen regenerates keypair. Provider's trusted entry no longer matches the fingerprint in Bonjour TXT. Provider treats it as a new untrusted screen. PIN pairing required to re-establish trust.

### 16.7 Multiple Providers on Same Network

Two TARS instances (or dev + prod) discover the same screens. First to `POST /pair` occupies the screen (`busy=1`). Second sees it as busy. No conflict — occupancy is first-come-first-served.

### 16.8 Snapshot During Render

Provider sends `GET /snapshot` while the screen is still rendering a just-pushed frame. Screen returns the snapshot of whatever is currently visible (may be partial render). The `frameId` in the snapshot tells the provider which frame the snapshot corresponds to. Provider can re-request after a delay if it needs the settled state.

### 16.9 Watch Mode Callback Unreachable

Screen is in watch mode, POSTing events to the provider's callback URL. Provider becomes temporarily unreachable. Screen's event POST fails. Screen retries once after 1 second, then drops the event. Events are best-effort, not guaranteed delivery. The provider can always `GET /snapshot` for authoritative state.

### 16.10 Pencil Strokes During Frame Push

User is drawing while CLU pushes a new frame in response to earlier strokes. The surf ace must not lose in-flight strokes. The surf ace buffers strokes during frame render. After the new frame is applied, buffered strokes are rendered on the overlay and included in the next debounce event. The change stack records the new frame so CLU knows its update was applied.

### 16.11 Rapid Pencil Input

User draws continuously for 30 seconds without lifting the pencil. Short debounce never fires (pencil never lifts). Long debounce fires once at the 3–5s mark, then again at the next idle gap. The surf ace accumulates strokes and sends them all in the long-debounce payload. CLU may receive a large stroke set. This is fine — the vision model sees the full screenshot and doesn't need to process strokes sequentially.

## 17. Surf Ace API Reference

### 17.1 POST /pair

Create a session with the screen.

**Request (auto mode):**
```json
{ "mode": "auto" }
```

**Response (success):**
```json
{ "status": "ok", "sessionToken": "<token>" }
```

**Request (PIN mode, step 1):**
```json
{ "mode": "pin" }
```

**Response (challenge):**
```json
{
  "status": "pin_required",
  "pin_hash": "<sha256(pin + nonce)>",
  "nonce": "<32 hex bytes>"
}
```

**Request (PIN mode, step 2):**
```json
{ "mode": "pin", "pin": "1847", "nonce": "<32 hex bytes>" }
```

**Response (success):**
```json
{ "status": "ok", "sessionToken": "<token>" }
```

**Error responses:**
- `409 Conflict` — screen is busy.
- `403 Forbidden` — PIN incorrect or lockout active.
- `429 Too Many Requests` — lockout (3 failed attempts).

### 17.2 POST /frame

Push a content frame. Replaces any existing frame.

**Request:** Frame JSON (see §8.1).
**Response:** `200 OK` or `422` with error body (see §6.7).

### 17.3 POST /frame/append

Append to a terminal frame.

**Request:** Append JSON (see §8.4).
**Response:** `200 OK` or `409 Conflict` (stale frameId) or `422` (error).

### 17.4 POST /frame/patch

Patch an HTML frame.

**Request:** Patch JSON (see §8.4).
**Response:** `200 OK` or `409 Conflict` (stale frameId) or `422` (error).

### 17.5 DELETE /frame

Clear screen content.

**Response:** `204 No Content`.

### 17.6 GET /snapshot

Get current screen state.

**Response:** Snapshot JSON (see §9.1).

Returns `204 No Content` if no frame is displayed (connected-idle state).

### 17.7 POST /watch

Subscribe to real-time events.

**Request:** Watch config JSON (see §9.2).
**Response:** `200 OK`.

### 17.8 POST /unwatch

Unsubscribe from events.

**Response:** `200 OK`.

## 18. Open Questions

1. **mDNS across subnets.** Bonjour works within a broadcast domain. If TARS is on a different subnet from the screens (common in larger networks), mDNS won't work without an mDNS reflector or Tailscale's MagicDNS. Should the provider support manual screen addresses as a fallback?

2. **Screen input.** Should screens support keyboard input for terminal frames? This would make Surf Ace a lightweight remote terminal. Significant scope increase — deferred for now, but the Surf Ace API could add a `POST /input` endpoint later.

3. **Multi-frame screens.** V1 is one frame per screen. Should v2 support split-screen (multiple frames on one display)? This requires a layout protocol. The frame model is designed so this could be additive.

4. **Discovery beyond LAN.** Should Tailscale MagicDNS be supported for discovering screens on the Tailscale network but not the local LAN? This would let TARS reach screens at a remote location.

5. **Watch mode cost ceiling.** Should the provider enforce a max events/minute rate per screen to prevent runaway token costs from the two-tier processing model?

6. **Pencil markup latency budget.** What's the acceptable latency from pencil-lift to CLU's response appearing on screen? 500ms debounce + network + model inference + frame push. If total exceeds ~1.5s, the "magic" feeling breaks. Is Haiku fast enough for the short-debounce path?

7. **Change stack depth.** How deep should the change stack be? Unlimited risks memory bloat on long sessions. But limiting it means CLU can't undo far back. 50 frames?

## 19. Implementation Phases

### Phase 1: Core
- Surf Ace macOS app (SwiftUI): Bonjour broadcast, HTTP server, HTML frame rendering, GET /snapshot.
- Surf Ace Electron app (Linux): same capabilities.
- Provider mDNS browser and screen table.
- Provider HTTP client to screens.
- Auto-connect (trusted screens, no PIN).
- `POST /frame` (HTML only).
- `GET /snapshot` with `visibleText` extraction.
- Query-time context injection into CLU system prompt.
- `surf-ace_push` provider action.
- Session TTL (5 minutes).
- Error reporting via HTTP responses.

### Phase 2: Full Content + Pairing
- All content types: image, PDF, terminal, markdown.
- `POST /frame/append` for terminal.
- `POST /frame/patch` for HTML.
- PIN pairing protocol (`POST /pair`).
- Trust store persistence.
- Selection in snapshots.
- `surf-ace_pair` and `surf-ace_clear` CLU actions.

### Phase 3: Watch Mode
- `POST /watch` and `POST /unwatch`.
- Provider callback endpoint at `/surf-ace/events/<screenId>`.
- v1 event types: text_selected, point, region, scroll_settle, zoom_settle, page_change.
- Two-tier watch processing (Haiku-level filter + main agent escalation).
- `surf-ace_watch` CLU action.
- Watch mode callback security.

### Phase 4: Pencil Markup
- PencilKit / equivalent stroke capture on Surf Ace surf aces.
- Two debounce tiers (500ms short, 3–5s long).
- Stroke + crop screenshot POST to provider callback.
- Full surf ace screenshot POST on long debounce.
- Haiku-level fast model for short-debounce interpretation.
- Main agent for long-debounce holistic pass.
- Change stack on surf ace (frame history for undo).
- CLU responds via `POST /frame` with interpreted content.

### Phase 5: Spawned Surf Aces
- `surf ace_spawned` and `surf ace_submitted` messages on Clawline WebSocket.
- Temporary HTTP server in Clawline for annotation surf aces.
- Apple Pencil annotation capture and snapshot.
- Annotation-as-context in CLU messages.

### Phase 6: Mobile + Spatial
- Surf Ace iOS app.
- Surf Ace iPadOS app (split view with Clawline).
- Surf Ace visionOS app (spatial windows).
- iPhone background/foreground lifecycle handling.

### Phase 7: Polish
- macOS chromeless/menu-bar mode.
- Electron kiosk mode.
- Screen name collision handling.
- Provider screen disambiguation in CLU prompts.

---

## Appendix: Preserved Notes

### From: specs/loupe-canvas-foundation-analysis.md

**Decision: Do NOT use OpenClaw Canvas as kernel for Loupe.**

Canvas is command-oriented (`present/hide/navigate/eval/snapshot`), foreground-gated on mobile nodes, and optimized for single-node visual control — not multi-surface state orchestration.

For any Loupe multi-surface state needs, Canvas can serve as a rendering adapter/prototyping surface, but a dedicated surface control plane is required for production use.
