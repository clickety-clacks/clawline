# Surf Ace Wire Protocol (WebSocket)

Status: Design draft
Depends on: `/Users/mike/shared-workspace/clawline/specs/clawline-invariants.md`

## 1. Purpose and Goals

Surf Ace is a standalone display and annotation system that turns any screen running the Surf Ace app into a CLU-managed surface. It is a purpose-built binary application — not embedded in another app — available on iOS/iPadOS and as an Electron app on macOS, Windows, and Linux.

### Actors

- **CLU** — the AI orchestrator. CLU discovers surfaces, pushes content to them, reads user annotations and events, and interprets surface activity.
- **Surfaces** — screens running the Surf Ace app. A surface is a render target that CLU can address by stable identity. Multiple surfaces can be active simultaneously; CLU manages them independently.
- **Users** — annotators and viewers. On iPad, users draw on content with a stylus (Apple Pencil) or finger. On Electron, users annotate with mouse or trackpad. User interactions are captured and reported to CLU for interpretation.

### Core Goals

1. **CLU-managed surface.** Any screen running the Surf Ace app becomes a surface CLU can push content to and read events from.
2. **Content display.** CLU pushes content to surfaces in the following types: `html`, `image`, `pdf`, `terminal`, `markdown`. `video` and `canvas` are defined in the wire protocol for forward compatibility but full surface-side implementation is deferred to v2. The surface renders content and keeps it displayed until CLU explicitly changes it.
3. **User annotation.** Users draw and annotate on displayed content using a stylus (iPad) or input device (Electron). Annotation strokes are captured and reported to CLU.
4. **CLU interpretation.** CLU reads user annotations and interprets them — identifying point-outs, markup gestures, written content, and spatial relationships to the displayed material.
5. **Zero-config discovery.** Surfaces advertise themselves via Bonjour/mDNS (`_surf-ace._tcp`). No manual setup, pairing codes, or configuration is required.
6. **Multi-surface and multi-pane.** CLU can manage multiple surfaces simultaneously. Each surface has a stable identity and independent state. Within a surface, windows can be split into multiple panes, each with independent content and annotation context. CLU can target content and read annotations at the pane level.
7. **Standalone app.** Surf Ace is its own binary on each platform. It is not a plugin, extension, or embedded view inside another application.

### Architecture Overview

All provider↔surface communication runs over a persistent WebSocket connection per surface. The provider (CLU's runtime component managing surface connections) is the WS client; the surface app runs the WS server. There is no REST API. The provider maintains the connection, handles reconnect, and buffers surface state for CLU tool reads.

Key design decisions:
1. Provider initiates the connection (provider is WS client).
2. Surface runs a lightweight WS server (HTTP only for the mandatory upgrade handshake required by RFC 6455).
3. One active provider connection per surface at a time, with automatic reconnect.
4. All operations run over that socket: pair handshake, content push, clear, events, snapshots.
5. No callback URL; no explicit watch mode — event streaming is always on while connected.

## 2. Scope and Non-Goals

### 2.1 In Scope
1. Discovery metadata needed to open the WS connection.
2. WS handshake, pairing, session ownership, reconnect.
3. Wire message contracts for content operations, snapshot operations, and user interaction events.
4. JSON Schema definitions for all message types.

### 2.2 Non-Goals
1. UI design details for surface rendering.
2. CLU prompt orchestration details.
3. Cloud relay transport.

### 2.3 Delivery Phasing

Implementation order is explicitly phased:

**Phase 1 — Surface topology first (before annotations):**
1. Multi-window support (already in protocol).
2. Multi-pane support inside a window (`paneId`, pane split/resize/focus lifecycle).
3. Stable read/write targeting by `{surfaceId, paneId}` with v1-compatible default `paneId="root"`.
4. **Multi-session pane contention policy** — handling when multiple CLU sessions target the same pane is an explicit open topic (see **`## Open Topics → OT-1`**). Candidate models currently under discussion include tab isolation and single-visible-owner with history.

**Phase 2 — Annotation semantics:**
1. Annotation mode UX lock.
2. Live dirty + closed-frame delivery model.
3. Annotation interpretation workflows.

Constraint: annotation semantics in §§13–14 are normative architecture and may be implemented in parallel, but release/priority gating is: Phase 1 topology work (multi-window + multi-pane targeting) must ship before annotation-priority milestones are considered complete.

**Phase 1 done checklist (must all be true):**
1. A single window can be split into multiple panes, each with stable `paneId`.
2. Pane lifecycle exists: create/split, resize, focus/select, close.
3. All screen-scoped tool operations can target `{surfaceId, paneId}`.
4. Backward compatibility: callers omitting `paneId` continue to target `paneId="root"`.
5. `surfaces.list` (or equivalent pane-aware listing) can enumerate panes and active content per pane.
6. Content operations are isolated per pane (push/clear in pane A does not mutate pane B).
7. Connection/session ownership semantics remain unchanged at window level (`surfaceId`), with pane routing handled inside that session.
8. At least one iOS and one Electron implementation pass topology tests for pane isolation and routing.
9. Tab model is active: `content.set` auto-creates a tab per session per pane; surface routes by `sessionId`; `surf_ace_push` returns `tabId`; `tab.list` and `tab.close` are operable; tab lifecycle events fire.
10. Annotation buffer is keyed by `(surfaceId, paneId, tabId)`; `surf_ace_read` is session-keyed and reads the calling session's tab automatically.

Only after these are true do annotation-priority implementation tasks move to Phase 2.

### 2.4 Extension Architecture

Surf Ace is implemented as its own extension (`extensions/surf-ace/`) within the same monorepo as Clawline. The two extensions are peers — neither imports from the other.

Rules:
1. `extensions/surf-ace/` has no imports from `extensions/clawline/` and vice versa.
2. Any functionality needed by both goes through core internals (`src/`) or a shared utility module, not through cross-extension imports.
3. Surf Ace has its own `openclaw.plugin.json` manifest and registers its own tools and services independently.
4. This boundary is enforced to prevent cross-project leakage and to keep extraction to a true standalone plugin clean if that becomes necessary.
5. Both extensions benefit from monorepo-level access to core internals (`src/`) while this boundary is maintained.

Ownership: `extensions/surf-ace/` owns the Surf Ace provider runtime — mDNS discovery, WS connection management, local state buffers, and all `surf_ace_*` CLU tools. The corresponding surface-side core module (if needed) lives in `src/surf-ace/`. Neither Clawline nor any other extension imports from these paths.

## 2a. Concepts

Before the protocol details, these terms are used consistently throughout this spec:

**Surface** — a render-target context addressable by stable identity. In v1 multi-window topology, each window is a distinct surface (`surfaceId`) even when hosted by one app instance/device endpoint. Within each window, pane routing is nested under the surface via `paneId` (default `root`, split into additional panes as needed).

**Endpoint** — the app/device WS host:port advertised via mDNS. One endpoint may host multiple surfaces (windows).

**Provider** — the Clawline server-side component that manages connections to surfaces. It is the WS client and reconnect owner. It maintains local state for each surface.

**Content** — the item currently displayed in a rendering scope. Content has a type (`html`, `image`, `pdf`, `terminal`, `markdown`, `video`, `canvas`) and a stable identity (`contentId`). A window always has panes; when unsplit it has one pane (`root`), and when split it has multiple panes. Each pane displays one content item independently (scoped by `paneId`). CLU pushes content to a target scope and can clear it. Content is distinct from annotations. `video` and `canvas` are defined in the protocol for forward compatibility; full implementation is deferred to v2.

**Annotations** — drawing strokes the user has made on top of the current content using the stylus or finger. Annotations are layered over content and persist until the provider explicitly removes them. Annotations are not content and are not cleared when content changes unless the spec says so.

**Event** — a user interaction reported by the surface to the provider over the WS socket (drawing flush, tap, selection, page turn, navigation, scroll, snapshot hint). Events are buffered locally by the provider.

**Local buffer** — the provider's in-memory store of events and annotation state for each surface. CLU reads from this buffer only; it never triggers live network calls to a surface for reads.

**Connection job** — the provider's per-surface background process that maintains the WS connection, runs the pair handshake, handles reconnect, and syncs local state. Fully opaque to CLU.

**Tab** — a rendering slot within a pane, owned by a single CLU session. Tabs are auto-created on the session's first push to a pane and persist until the tab is cleared or closed. Each pane holds at most one tab per CLU session (one-per-session-per-pane rule). The surface routes pushes to the correct tab by session ID; CLU does not reference tabs explicitly — routing is implicit. The annotation layer belongs to the active tab. Tabs are a Phase 1 concept (see §2.3). `tabId` is assigned by the surface on tab creation as a stable opaque string. The surface MAY derive it from `sessionId` (e.g. a truncated hash) but is not required to. `tabId` is authoritative as returned by the surface in push responses and `event.tab_created`. CLU MUST use the echoed `tabId` as the canonical identifier — not attempt to predict or derive it.

## Core Invariants

These are normative, settled statements about Surf Ace behavior. Implementations MUST conform to every invariant listed here. These statements are not subject to the open topics in `## Open Topics`.

1. **WebSocket-only transport.** All provider↔surface communication runs over a persistent WebSocket connection. The provider is the WS client; the surface app runs the WS server. There is no REST API.
2. **One connection per surface.** Exactly one paired provider connection is active per surface at a time. Additional providers are rejected with `busy` until the current session expires or is explicitly taken over by the same provider.
3. **Content persistence through reconnect.** Connection state MUST NOT affect displayed content. Content is never cleared by a disconnect, grace expiry, restart, or takeover. Content changes only when CLU explicitly calls `content.set` or `content.clear`.
4. **Reads are local-only.** CLU reads exclusively from the provider's local buffer. No `surf_ace_*` read operation triggers a live network call to a surface.
5. **Panes are always present.** Every surface window has one or more panes at all times. The default layout uses `paneId="root"`. There are no separate "single-pane mode" and "multi-pane mode" — pane routing is always active. When unsplit, a window has one pane (`root`).
6. **Tab-per-session isolation.** Each pane may contain one or more tabs. Each tab is owned by exactly one CLU session. One tab per session per pane. Subsequent pushes from the same session update that session's existing tab in-place. Tab routing is by `sessionId`; CLU does not address tabs explicitly for normal pushes.
7. **Provider-injected session identity.** `sessionId` is injected by the provider from the authenticated WS session context. CLU MUST NOT pass `sessionId` as a wire field on any operation. Surface implementations MUST NOT accept `sessionId` from the wire payload.
8. **Always-on event streaming.** Once paired, the surface emits events continuously. There is no subscribe/unsubscribe API — event streaming is always on while connected.
9. **Annotation mode locks the viewport.** When annotation mode is active, scroll is disabled and link following is disabled. The drawing layer captures all touch and stylus input until annotation mode exits.
10. **Monotonic revision gate.** Content mutations (`content.set`, `content.clear`, `content.append`, `content.patch`) carry a monotonic `revision`. The surface applies mutations only when `revision == currentRevision + 1`. Out-of-order mutations are rejected with `stale_revision`.
11. **Annotation buffer is tab-scoped.** The annotation buffer (live dirty channel, closed frame queue, and all non-annotation registers) is keyed per tab: `(surfaceId, paneId, tabId)`. Tabs in the same pane do not share annotation state.
12. **Lifecycle events are always-on.** Surface lifecycle events (`event.surface_appeared`, `event.surface_removed`), pane lifecycle events (`event.pane_created`, `event.pane_removed`, `event.pane_focused`, `event.pane_renamed`), and tab lifecycle events (`event.tab_created`, `event.tab_removed`, `event.tab_focused`) are never profile-gated. They fire regardless of `eventProfile` setting and do not appear in `pair.response.eventConfig.activeEvents`.
13. **Platform target floor policy.** Surf Ace targets the newest released OS major version as the minimum deployment target (current decision: iOS/iPadOS 26 and macOS 26 for native surface builds).
14. **Portable extension packaging.** Surf Ace MUST remain installable as a standalone OpenClaw extension bundle that can be dropped into any compatible OpenClaw installation (without requiring Clawline as a dependency and without requiring core patches). Any needed wake/routing behavior must be implemented through extension-local code and published SDK surfaces.

## 3. Transport and Discovery

### 3.1 Discovery

Surfaces continue advertising `_surf-ace._tcp` over Bonjour/mDNS.

#### 3.1.1 Multi-Window, Multi-Pane, and Multi-Tab Topology (iPad + Electron)

A single app instance may host multiple surface windows simultaneously. Each window is an independent Surf Ace surface. Within each window, one or more panes provide independent content and annotation contexts. Within each pane, one or more tabs allow multiple CLU sessions to coexist without overwriting each other.

**Topology hierarchy:** Surface → Window (letter-labeled A/B/AA…) → Pane (number-labeled pane_0/pane_1…/root) → Tab (session-keyed)

> **Phasing note:** Tab support is Phase 1 scope — it ships alongside multi-pane topology, before any annotation-semantics work (Phase 2). See §2.3 for the full phasing plan.

Window rules:
1. Each window has its own stable `surfaceId` and independent local state (capture frame queue, taps, selection, scroll, etc.).
2. The app advertises one device endpoint over mDNS (one host/port), not one mDNS record per window.
3. Windows are enumerated in-band over WS (`surfaces.list`) and can appear/disappear at runtime (`event.surface_appeared`, `event.surface_removed`).
4. Provider maintains one paired WS session per active window/surface, even when multiple windows share the same device endpoint.
5. Creating/removing a window does not require mDNS rebroadcast; only app endpoint lifecycle affects mDNS advertisement/goodbye.

Pane rules (Phase 1 committed work, see §2.3):
1. Each window may contain one or more panes, each identified by a stable `paneId`. `paneId` format: `pane_<decimal>` for auto-assigned (e.g. `pane_0`, `pane_1`); user-assigned names are arbitrary non-empty strings that do not start with `pane_`. The default single-pane ID is the literal string `root`.
2. Default single-pane layout uses `paneId="root"`.
3. Each pane has independent content, capture frame queue, taps, selection, scroll, and annotation state.
4. All screen-scoped operations target `{ surfaceId, paneId }`; callers omitting `paneId` default to `"root"`.
5. Pane lifecycle (create/split/resize/focus/close) is managed in-band; pane changes do not affect window-level session or mDNS state.

Naming system:
1. Windows are auto-assigned short letter labels: A, B, C … Z, AA, AB … (displayed prominently on surface).
2. Panes within a window are auto-assigned numbers starting at 0 (0, 1, 2 …); numbers reset per window.
3. Users and the model may assign human-readable names to panes (e.g. "fred", "reference"). Named panes remain addressable by their human name or their number.
4. The model may create, split, rename, and close panes in conversation with the user; this is not considered intrusive.
5. When a window is split into N panes, new panes are auto-numbered sequentially from the highest existing pane number + 1.
6. Labels and names are displayed prominently on the surface — exact placement and visual style TBD in the separate UI spec (see tracking/surf-ace-ui-open-topics.md).

Tab rules (Phase 1 committed work, see §2.3):
1. Each pane may contain one or more tabs. Each tab is owned by exactly one CLU session (identified by `sessionId`). One tab per session per pane — tabs do not proliferate beyond the number of distinct sessions that have pushed to that pane.
2. A tab is auto-created on the first `content.set` push from a given session to a pane. Subsequent pushes from the same session update that session's existing tab in-place — no new tab is created.
3. A push from a different session creates that session's own tab in the pane (up to the practical max of 2–3 tabs per pane in normal use).
4. The surface routes `content.set` pushes to the correct tab by `sessionId`. CLU does not address tabs explicitly — routing is invisible to CLU by default.
5. `content.set` response (and `surf_ace_push` at the CLU tool layer) echoes `tabId` so CLU knows which tab it owns. CLU does not need to reference `tabId` for subsequent pushes to the same pane.
6. Tab addressing: CLU targets a pane by `paneId` only; the surface resolves the correct tab using `sessionId` on the connection. CLU tools pass `paneId`; tab routing is implicit.
7. User tab switching: the user can switch between tabs within a pane (browser-style UI on the surface). `event.tab_focused` fires when the user switches to a different tab. Tab switching is a surface-side UI feature; CLU is notified but does not drive it.
8. The user can close a tab manually from the surface UI; CLU can call `tab.close` explicitly. Surface emits `event.tab_removed` in both cases.
9. Max tabs per pane equals the number of distinct CLU sessions that have pushed to that pane and not cleared (typically 2–3 in practice).
10. `tabId` format: derived from `sessionId` (e.g., a stable short hash or the full `sessionId` string). Surface assigns `tabId` on tab creation and echoes it in the `content.set` response. Required properties: (1) stable for the tab's lifetime, (2) unique within its containing pane (enforces one-tab-per-session-per-pane), (3) treated as opaque by providers — surface is free to use any derivation scheme. `tabId` is authoritative as returned by the surface in push responses and `event.tab_created`. CLU MUST use the echoed `tabId` as the canonical identifier — not attempt to predict or derive it.
11. Annotations are tab-scoped. The annotation layer (drawing overlay, capture frames) belongs to the active tab. See §13.2 for buffer scoping.
12. **`sessionId` injection:** The provider injects `sessionId` from the authenticated WS session context. CLU does not pass `sessionId` explicitly — it is derived server-side from the connection that delivered the push request. Surface implementations MUST NOT accept `sessionId` from the wire payload; the provider stamps it before forwarding the request to the surface.
13. **Tab switch during active annotation:** If the user switches tabs while annotation mode is active (an open live frame exists), annotation mode exits immediately (equivalent to tapping Done). Any in-flight strokes are finalized and assigned to the tab that was active when the strokes began. The newly focused tab is displayed in view-only mode until annotation mode is re-entered. `event.tab_focused` fires after the tab switch completes; annotation mode on the new tab is inactive until the user re-engages.

TXT keys used by WS protocol:

| Key | Type | Example | Notes |
|---|---|---|---|
| `name` | string | `Kitchen Display` | Human-readable label |
| `v` | int | `1` | Protocol major version |
| `w` | int | `1920` | Viewport width (points) |
| `h` | int | `1080` | Viewport height (points) |
| `s` | int | `2` | Scale factor |
| `cap` | int | `31` | Content type bitmask |
| `busy` | `0|1` | `0` | Paired/occupied or in resume grace |
| `pk` | hex8 | `a1b2c3d4` | Device public key fingerprint prefix (endpoint identity only; not used as screen selector in CLU tools) |
| `ws` | path | `/ws` | WS upgrade path |
| `tls` | `0|1` | `0` | Reserved for future WSS profile; ignored by v1 |

Connection URL derivation:
1. Resolve host/port from SRV/A/AAAA.
2. Use path from TXT `ws` (default `/ws` if missing).
3. v1 scheme is always `ws` (WSS is out of scope in v1).

### 3.2 Surface WS Endpoint

The surface runs a WebSocket server. There is no REST HTTP API — the only HTTP traffic is the mandatory WS upgrade handshake required by RFC 6455 before the socket is established.

1. Required: WS upgrade path (`/ws` by default, or the path advertised in TXT `ws` key).
2. Optional: `GET /health` → `200 OK` for diagnostics only.
3. No REST data endpoints exist (`/pair`, `/frame`, `/watch`, `/snapshot` are not part of this protocol).

## 4. Connection and Session Lifecycle

### 4.1 Roles
1. Provider is WS client and reconnect owner.
2. Surface is WS server and session authority.

### 4.2 Single-Connection Rule
1. Exactly one paired provider connection is active per surface.
2. If another provider tries to pair while occupied, surface rejects pairing with `busy`.
3. Surface advertises `busy=1` while paired or in reconnect grace.
4. Same-provider takeover is explicit: if a new `pair.request` has the same `providerId` and `takeover=true`, surface accepts the new socket and closes the old one as `1000` reason `superseded`.

**Multi-session CLU contention** policy is currently open. The protocol must support whichever policy is selected (e.g., tab isolation or single-visible-owner with history) without requiring user permission prompts. See **`## Open Topics → OT-1`** for the authoritative open topic.

### 4.3 Pair-First Rule

All operations other than `surfaces.list` and `pair.request` are invalid until pairing succeeds.

`surfaces.list` is a pre-pair discovery operation used only on multi-window endpoints to enumerate active window surfaces and their stable IDs.

### 4.4 Reconnect Behavior

Provider reconnect policy:
1. Exponential backoff with jitter: 0.5s, 1s, 2s, 4s, 8s, 16s, max 30s.
2. Reconnect uses the same discovered surface address.
3. Provider sends `pair.request` again after each reconnect.
4. Provider sets `takeover=true` on reconnect attempts after any missed heartbeat window to evict stale half-open sockets owned by itself.
5. If provider receives `busy` but has a prior session for the same surface, provider SHOULD retry once with `takeover=true` before continuing backoff.

Surface reconnect grace:
1. On any disconnect (abnormal OR normal close), surface keeps displayed content and all registers intact — indefinitely.
2. During the grace window (`resumeGraceMs`, default 20000), only the same `providerId` may resume with session continuity.
3. If grace expires without resume, surface invalidates session and sets `busy=0` so new providers can connect — but displayed content is NOT cleared.
4. On normal close with reason `superseded`, surface accepts the takeover — but displayed content is NOT cleared. The new provider decides what to show.

**Invariant: connection state MUST NOT affect displayed content.** Content is never cleared by a disconnect, grace expiry, restart, or takeover. Content changes only when CLU explicitly calls `content.set` or `content.clear`. A surface showing content will continue showing that content indefinitely until told otherwise.

### 4.5 Keepalive

Application-level keepalive is required:
1. Provider starts heartbeat only after successful `pair.response`.
2. Provider sends `heartbeat.ping` every 10s.
3. Surface replies with `heartbeat.pong` within 3s.
4. Surface MUST prioritize heartbeat handling above queued frame/render work and MUST NOT queue `heartbeat.pong` behind render/mutation tasks.
5. Missing 2 consecutive pong responses causes provider to close socket and reconnect.

Pair timeout:
1. Provider MUST apply a 10s pairing timeout from WS connection establishment.
2. If no `pair.response` arrives in 10s, provider closes socket and enters reconnect backoff.

**Surface UI connectivity indicator (required):**
The surface MUST display a persistent visual indicator of connection state. Visual design TBD in separate UI spec (see tracking/surf-ace-ui-open-topics.md); required behavior:
- Healthy: ping received within expected window — no indicator or neutral.
- Stale — yellow: no ping received within `heartbeatIntervalMs + heartbeatGraceMs` (default 13s = 10s interval + 3s grace). Surface transitions to yellow at this threshold.
- Disconnected — red: WS socket is not connected.
Returns to healthy immediately when a ping is received on a live connection. Content is never cleared by any of these states (see §4.4 invariant).

### 4.6 Runtime Window Lifecycle (Multi-Window Endpoints)

When a user opens or closes windows on iPad/Electron, surface availability changes without endpoint change.

Rules:
1. On window create, surface emits `event.surface_appeared` with `{ surfaceId, name, viewport }` on any active provider socket for that endpoint.
2. On window close, surface emits `event.surface_removed` with `{ surfaceId }` and closes any paired socket for that surface.
3. Provider may call `surfaces.list` at any time to reconcile active windows.
4. Window lifecycle changes are in-band WS signals; they do not require mDNS rebroadcast.
5. Surface identity is window-scoped and stable across app restarts when restoration metadata exists; otherwise new windows receive new `surfaceId`s.
6. `event.surface_appeared` and `event.surface_removed` are **not profile-gated** — they are always emitted regardless of `eventProfile` setting. Providers MUST handle these events on any active socket.

## 5. Message Model

### 5.1 Encoding
1. UTF-8 JSON text messages only.
2. Binary WS frames are not used by v1.

### 5.2 Envelope Types
1. `request`: provider -> surface command with correlation `id`.
2. `response`: surface -> provider reply matching request `id`.
3. `event`: surface -> provider async user interaction stream.

### 5.3 Correlation and Idempotency
1. Every request has unique `id` per connection.
2. Surface caches last 1024 request IDs for idempotent replay.
3. Duplicate request ID with identical payload must return the original response.
4. Duplicate request ID with different payload returns `invalid_request_id_reuse`.

### 5.4 Ordering and Mutation Seam
1. Provider is the only writer of content state.
2. Mutating content operations (`content.set`, `content.append`, `content.patch`, `content.clear`) carry monotonic `revision`.
3. Surface applies mutation only when `revision == currentRevision + 1`.
4. Revision mismatch returns `stale_revision` with `expectedRevision`.
5. This revision gate is the single mutation seam for content state.
6. Drawing overlay mutations are provider-controlled through `annotations.remove`; surface never autonomously deletes strokes.

### 5.5 Size Limits

Surface advertises limits in `pair.response`:
1. `maxMessageBytes` (default 12 MiB).
2. `maxFrameBytes` (default 10 MiB for `content.set` content payload).
3. `maxVisibleTextBytes` (default 4096).
4. `maxStrokePointsPerFlush` (default 8192 for `event.drawing_flush`).
5. `maxDrawingFlushBytes` (default 2 MiB).

Requests above limit return `content_too_large`; severe violations may close socket with code `4413`.
Severe violation threshold:
1. Message size > 2x `maxMessageBytes`, or
2. 3+ `content_too_large` responses on one connection within 60s.

## 6. Operations

### 6.0 Surfaces List (Multi-Window Discovery)

`surfaces.list` is an endpoint-scoped request that may be called before pairing. It returns currently active window surfaces on the endpoint.

Rules:
1. Provider MAY call `surfaces.list` immediately after WS connect.
2. Response contains `{ surfaceId, name, autoLabel, viewport, paired }[]`. `autoLabel` is the auto-assigned window letter (e.g. `"A"`, `"B"`, `"AA"`) used to address the window by letter in CLU and displayed on the surface UI. `paired: true` when the surface is either actively connected to a provider OR is in resume grace for a prior session — mirroring `busy=1` mDNS semantics. When `paired: true`, `pair.request` requires `takeover=true`, but note: only the **same** `providerId` that owns the current session can successfully take over during the grace window (§4.2). A different provider sending `takeover=true` will still receive a `busy` error. `paired: false` means the surface is fully available and any provider may connect.
3. Provider selects a `surfaceId` and sends `pair.request` for that surface.
4. Phase 1 pane profile: once pane support is enabled, `surfaces.list` MUST optionally expose pane summaries per surface (at minimum `paneId` and `activeContent`) for topology-aware targeting.

### 6.1 Pair Handshake

Flow:
1. Provider opens WS.
2. Provider sends `pair.request`.
3. Surface replies `pair.response` (success or error).
4. If success, connection enters active mode and event streaming starts immediately.

`pair.request` fields include:
1. `providerId` (stable identity for resume).
2. `connectionId` (unique per socket attempt).
3. `surfaceId` (target window surface on multi-window endpoints).
4. `resume` (optional prior `sessionId`).
5. `takeover` (optional bool, same-provider stale-connection eviction).
6. `providerName` (optional human-readable session/chat label for UI indicators such as tab labels).
7. `eventProfile` (optional, default `minimum_deep`).
8. `drawingFlushConfig` (optional, provider-preferred idle/max interval values).
9. `protocolVersion` (`1` for this spec).

`pair.response` success includes:
1. `sessionId`.
2. `resumed` boolean.
3. Surface metadata (id/name/viewport/capabilities).
4. `eventConfig` (active event profile, active event list, and effective drawing flush config).
5. Limits.
6. Current content summary (`currentContentId`, `currentRevision`, `contentType` or `null`).

### 6.1.1 Pane and Tab Lifecycle Operations (Phase 1)

These operations are post-pair and scoped to a paired `surfaceId`. They implement the pane topology committed in §2.3 Phase 1 and §3.1.1.

#### `panes.list`
Returns current pane layout for the paired surface.

**Response fields per pane:** `paneId`, `name` (user-assigned or null), `autoLabel` (auto-assigned number, e.g. `0`), `activeContentId` (or null), `contentType` (or null), `viewport`, `focused` (bool).

#### `pane.split`
Splits an existing pane into N panes.

**Request fields:** `paneId` (pane to split, default `root`), `count` (total pane count after split, including the source pane; min 2), `direction` (`horizontal` | `vertical`).

**Behavior:** The source pane retains its `paneId` and content and becomes the first pane. `count - 1` new empty panes are created with sequentially auto-assigned `paneId`s (`pane_N`). Surface emits `event.pane_created` for each new pane.

**Response fields:** `panes` — array of `{ paneId, autoLabel }` for all panes in the window after the split (including existing panes).

#### `pane.focus`
Brings a pane into foreground / active focus.

**Request fields:** `paneId`.

**Response fields:** `paneId` (ack echo), `focused: true`.

#### `pane.rename`
Assigns or clears a human-readable name for a pane.

**Request fields:** `paneId`, `name` (string or null to clear).

**Response fields:** `paneId`, `name` (new name or null).

**Behavior:** Named panes remain addressable by both their auto-number and their name. CLU tools accept either form in the `paneId` selector field.

#### `pane.close`
Closes a pane and removes it from the layout.

**Request fields:** `paneId`. Cannot close the last remaining pane in a window (returns `invalid_operation`).

**Response fields:** `paneId` (ack echo), `closedFramesDiscarded` (count of unread closed frames dropped from provider buffer for this pane).

**Behavior:** Before the pane is removed, the surface closes all tabs within the pane. `event.tab_removed` is emitted for each tab. Tab annotation state (including any open live frame and queued closed frames) is discarded. `closedFramesDiscarded` in the `pane.close` response counts frames across all tabs in the pane — it is the sum of discarded closed frames across all tabs, not just the focused tab. All `event.tab_removed` events are emitted before `event.pane_removed`. Content and annotation state for the closed pane are discarded. Any unread closed frames in the provider buffer for this pane are also discarded; `closedFramesDiscarded` reports the total count so CLU knows what was lost. `event.pane_removed` is emitted last.

---

**Pane lifecycle events (surface → provider):**
- `event.pane_created` — `{ surfaceId, paneId, autoLabel, parentPaneId (pane that was split, or null if created standalone), fromSplit: bool }`
- `event.pane_removed` — `{ surfaceId, paneId }`
- `event.pane_focused` — `{ surfaceId, paneId }`
- `event.pane_renamed` — `{ surfaceId, paneId, name }`

These events are always-on (not profile-gated), analogous to `event.surface_appeared`/`event.surface_removed`.

---

#### `tab.list`
Lists all tabs currently open in a pane.

**Request fields:** `paneId`.

**Response fields:** `tabs` — array of `{ tabId, sessionId, label (e.g. "Chat A"), activeContentId, contentType, focused: bool }`.

- `label` is a surface-assigned human-readable label derived from `sessionId` (e.g. "Chat A", "Chat B").
- `activeContentId` and `contentType` reflect the content currently displayed in that tab (`null` if the tab has been cleared).
- `focused: true` for the tab currently visible to the user.

#### `tab.close`
Closes a tab and discards its content and annotation state.

**Request fields:** `paneId`, `tabId`.

**Response fields:** `tabId` (ack), `closedFramesDiscarded` (count of unread closed annotation frames dropped from provider buffer for this tab).

**Behavior:** Tab content and annotation state (including any open live frame and queued closed frames) are discarded. Surface emits `event.tab_removed`. If the closed tab was the focused tab, the surface focuses another tab in the pane (surface-defined behavior).

---

**Tab lifecycle events (surface → provider, always-on, not profile-gated):**
- `event.tab_created` — `{ surfaceId, paneId, tabId, sessionId, label }` — fired when a new tab is auto-created on first push from a session.
- `event.tab_removed` — `{ surfaceId, paneId, tabId }` — fired when a tab is closed (user-initiated or via `tab.close`).
- `event.tab_focused` — `{ surfaceId, paneId, tabId }` — fired when the user switches to a different tab within a pane.

These events are always-on and do not appear in `pair.response.eventConfig.activeEvents` (which lists only profile-controlled events).

### 6.2 Content Set

`content.set` replaces active content payload in the calling session's tab within the target pane.

Rules:
1. `contentId` generated by provider (`ct_<8hex>`).
2. `revision` must be next revision.
3. Content must be self-contained.
4. `content.set` MUST clear all drawing overlay strokes before rendering the new content.
5. The surface uses `sessionId` to route the push to the correct tab — creating a new tab if no tab yet exists for this session in this pane, or updating the existing tab in-place if one does. **The provider injects `sessionId` from the authenticated WS session context. CLU does not pass `sessionId` explicitly — it is derived server-side from the connection that delivered the push request. Surface implementations MUST NOT accept `sessionId` from the wire payload; the provider stamps it. `sessionId` is NOT a wire field on `content.set` requests.**
6. Successful set returns rendered content summary including `tabId` (the tab that was created or updated).
7. `tabId` in the response allows CLU to know which tab it owns, but CLU does not need to reference `tabId` for subsequent pushes — the surface continues to route by `sessionId` automatically.

### 6.3 Content Append

`content.append` is terminal-only incremental append.

Rules:
1. Requires active content with `contentType=terminal` and matching `contentId`.
2. `revision` must be next revision.
3. On mismatch return `stale_content` or `unsupported_operation_for_content_type`.

### 6.4 Content Patch

`content.patch` is html-only patch operation.

Patch actions: `replace_inner`, `replace_outer`, `insert_before`, `insert_after`, `remove`.

Rules:
1. Requires active `html` frame and matching `contentId`.
2. `revision` must be next revision.
3. Invalid `selector` returns `render_failed`; invalid `action` value returns `invalid_payload`.

### 6.5 Content Clear

`content.clear` removes current content and moves to connected-idle.

Rules:
1. `revision` must be next revision.
2. `content.clear` MUST clear all drawing overlay strokes.
3. Success returns `currentContentId=null` and updated revision.

### 6.6 Snapshot Get

`snapshot.get` returns authoritative current surface state over the same WS connection.

Snapshot contains:
1. Content identity (`contentId`, `revision`, `contentType`).
2. Viewport (`scrollOffset`, `visibleRect`, `contentSize`, `zoomLevel`).
3. Optional `visibleText` (truncated to `maxVisibleTextBytes`).
4. Current `selection` (or `null`).
5. Optional current `drawings` (raw strokes currently retained on surface).
6. Optional base64 PNG `image` when requested.

Request flag behavior:
1. `includeVisibleText`: default `true` when unspecified.
2. `includeDrawings`: default `false` when unspecified.
3. `includeImage`: default `false` when unspecified.
4. If `includeVisibleText=false`, surface omits `visibleText`.
5. If `includeDrawings=false`, surface omits `drawings`.
6. If `includeImage=true`, `image` MUST be RFC4648 base64 PNG bytes (no line breaks).

No separate snapshot HTTP endpoint exists in this protocol.

### 6.7 Annotations Remove

`annotations.remove` removes a subset of rendered drawing strokes by stable stroke ID.

Request fields:
1. `contentId` (must match current content).
2. `strokeIds` (ordered array of stable stroke IDs to remove).

Rules:
1. Surface removes exactly matching stroke IDs from current drawing overlay.
2. Strokes not listed in `strokeIds` are unaffected.
3. If `contentId` is not current, return `stale_content`.
4. Response returns `removedStrokeIds`, `notFoundStrokeIds`, and `remainingStrokeCount`.
5. Operation is idempotent: repeating remove on already-removed IDs is allowed and returns them in `notFoundStrokeIds`.

### 6.8 Heartbeat

`heartbeat.ping` / `heartbeat.pong` are request/response messages, not event stream entries.

### 6.9 Content Type Characteristics

Each content type has distinct protocol behavior. The following are the notable differences from the baseline `html` type.

### 6.10 Annotation Mode

**Annotation mode** is a surface-level UX lock that activates when the user begins drawing. It is not a wire protocol concept — no messages are exchanged when annotation mode enters or exits. It exists solely to define surface interaction constraints during drawing. For required visual treatment (buttons, overlay state, platform-specific UI), see §15.4.

**When annotation mode is active:**
- Scroll is disabled (the viewport is locked in place)
- Link following is disabled (taps do not navigate)
- Drawing is enabled (stylus or finger strokes accumulate into the open capture frame)

**Platform implementations:**

*iPad (pencil-supported):* Pencil contact automatically enters annotation mode (pencil-only by default). A "finger sketching" button is always visible on screen; tapping it adds finger drawing capability alongside the pencil. The button can also be tapped before any pencil contact, which enters annotation mode with finger drawing already enabled. Annotation mode is exited when the user taps the "Done" button. Exiting annotation mode ends active live writes but does not by itself require frame finalization; frame finalization follows the dual-channel/context rules in §13.2.

*Non-pencil platforms (Electron, non-pencil touch):* An "Annotate" button must be tapped to enter annotation mode; finger then draws strokes. Tapping the button again exits annotation mode. This is vim-style (press once to enter, press again to exit) and is not a persistent setting.

**Tab switch during annotation mode:** If the user switches tabs while annotation mode is active, annotation mode exits immediately (equivalent to tapping Done). Any in-flight strokes are finalized and assigned to the tab that was active when the strokes began. The newly focused tab is displayed in view-only mode until annotation mode is re-entered. `event.tab_focused` fires after the tab switch completes; annotation mode on the new tab is inactive until the user re-engages.

**Why this is UX-only:** The wire protocol does not distinguish annotation-mode events from normal drawing events. Drawing flushes are emitted from both annotation mode strokes and (on surfaces that permit it) free-form drawing. The annotation mode construct exists at the surface UX layer to ensure a clean, scroll-locked capture frame — it does not produce a distinct wire event type.

---

#### `canvas` (v1 reserved, v2 required)
- `content.set` payload is optional: a background specification (`{ color, grid }`) or empty.
- There is no underlying document — annotations are the primary artifact, not an overlay.
- `visibleText` in snapshot is always empty.
- Navigation events do not fire (no URLs, no links).
- `content.clear` clears the background spec and ALL annotations (same global rule as all content types).
- Scroll and page registers do not apply.
- The surface renders a blank (or gridded) background. CLU populates the surface entirely through CLU-initiated annotation operations, or by observing user strokes and responding.

#### `video` (v1 reserved, v2 required)
- `content.set` payload is a URL string pointing to the video source.
- Scroll and page registers do not apply.
- Two additional registers are active for `video` content (see Section 13.2): `playbackPosition` and `playbackState`.
- Strokes carry an optional `videoTimestamp` field (seconds from video start) indicating the playback position when the stroke was made. This allows annotations to be temporally anchored.
- `visibleText` reflects any closed captions or subtitles visible at the current playback position, if available.
- Navigation events do not fire.
- `content.clear` clears the video and all annotations.

#### Protocol forward compatibility
The `video` and `canvas` content types are included in the `ContentType` schema enum in v1 so that implementations can reject them with `unsupported_content_type` rather than `invalid_payload`. This preserves forward compatibility: a v1 surface that does not implement these types still handles the message gracefully. A surface advertises supported content types via `cap` bitmask in mDNS TXT and in the `pair.response` capabilities field.

## 7. Always-On Event Delivery

Once paired, surface emits events without any subscribe/unsubscribe API.

### 7.1 Minimum Deep Event Set (Default)

Default event profile is `minimum_deep`.
`minimum_deep` is the smallest set that keeps CLU useful with low noise.

Active events in `minimum_deep`:
1. `event.drawing_flush` - raw strokes accumulated locally and flushed as one batch by flush gate timing.
2. `event.tap` - resolved point-out tap/long-press. UI-navigation taps (link follows, button activations) are excluded from this event; they produce `event.navigation` instead.
3. `event.selection` - semantically complete selection event. In v1 interoperability profile, only `kind:"text"` is guaranteed; `point`/`region` are reserved for v2 unless explicitly negotiated.
4. `event.page` - full PDF page transition state.
5. `event.navigation` - surface navigated away from pushed content (user followed a link or triggered in-page navigation). Carries the new URL and signals that any open capture frame or buffered annotation state should be considered stale relative to the original content. **Applies to `html` content type only.** Surfaces MUST NOT emit `event.navigation` for any other content type (`pdf`, `image`, `markdown`, `terminal`, `canvas`, `video`). If the provider receives a `NavigationEvent` while a non-HTML content type is active, it MUST discard it silently.
6. `event.snapshot_hint` - provider-internal control-plane event (reconnect/backpressure sync). NOT exposed in the CLU register model.

Drawing semantics in default mode:
1. Surface does no stroke classification, shape recognition, or gesture interpretation.
2. Surface accumulates raw strokes locally.
3. Surface emits `event.drawing_flush` only when the flush gate fires.
4. Each stroke has a stable unique `strokeId` (`stroke_<hex>`) assigned at capture time.
5. Flush payload is an ordered array of strokes; each stroke remains independently addressable by `strokeId`.
6. Surface keeps strokes rendered until explicitly removed by provider via `annotations.remove`.

Flush gate (trailing debounce model):
1. Let `dirty=true` when new strokes were added since last successful send.
2. Each new stroke resets a trailing debounce timer of `idleWindowMs`.
3. Idle gate condition: `idleWindowMs` has elapsed since the **last stroke ended** (not since pencil lift — the timer resets on every new stroke, so slow drawers with long gaps between strokes do not trigger spurious flushes mid-session).
4. Max interval condition: `maxIntervalMs` elapsed since last successful send and `dirty=true` (anti-spam backstop for continuous drawing without pause).
5. Send occurs when `dirty=true` and either idle gate or max interval condition is true.
6. Do not send when `dirty=false` (no changes since last send).
7. `lastSuccessfulSendAt` initializes to pair-success time for each connection.

Default flush timings:
1. `idleWindowMs` default 8000 (8 seconds of no new stroke activity).
2. `maxIntervalMs` default 30000.

Behavioral result:
1. A user who pauses naturally between strokes does not trigger a flush until they have been fully idle for 8s.
2. A slow drawer (long gaps between strokes) does not spam flushes — the timer resets on each new stroke.
3. Continuous drawing without pause is force-flushed at most every 30s.
4. There is intentionally no short/fast tier. Sending partial annotation batches mid-session would inundate CLU and produce redundant passes. One flush per drawing session is the goal.

Provider interpretation model:
1. CLU decides at interpretation time whether strokes are persistent (leave rendered) or consumed (call `annotations.remove`).
2. No user mode switch is required.
3. Surface is passive: it renders and flushes strokes, and removes only the explicit IDs requested by provider.
4. Canonical consumed example: scratch-out gesture is interpreted by CLU, then CLU calls `annotations.remove` for scratch stroke IDs and separately edits/deletes the scratched content.
5. Stroke visual attributes (color/width/opacity) are intentionally omitted from v1 wire schema; v1 interpretation uses stroke geometry and timing.

### 7.2 Optional Event Expansions (Still No Watch Mode)

The stream is still always-on; expansions are negotiated at pair time, not through runtime watch subscriptions.

1. `eventProfile=deep_plus_scroll`: adds `event.scroll` (settled viewport + visible text) to `minimum_deep`.

### 7.3 Event Audit: Deep vs Shallow

| Event | Classification | Default | Rationale |
|---|---|---|---|
| `event.drawing_flush` | Batched raw intent artifact | Yes | Carries all changed drawing input since last send at meaningful time boundaries. |
| `event.tap` | Deep semantic | Yes | Point-out taps only; UI-navigation taps excluded (see `event.navigation`). |
| `event.selection` | Deep semantic | Yes | Represents explicit user focus with interpretable payload. |
| `event.page` | Deep semantic | Yes | Complete navigation state transition for paged content. |
| `event.navigation` | Deep semantic | Yes | Surface navigated away from pushed content. Carries new URL; signals any open capture frame or buffered annotation state is stale. |
| `event.snapshot_hint` | Provider-internal control plane | Yes (internal only) | Used for reconnect/backpressure state sync. Not exposed in CLU register model. Appears in `pair.response.eventConfig.activeEvents` (it is profile-controlled, part of `minimum_deep`), but the provider does not surface it to CLU tooling. |
| `event.surface_appeared` | Lifecycle — **not profile-gated** | Always | Emitted on any active socket when a new window appears. Always active regardless of `eventProfile`. Does NOT appear in `pair.response.eventConfig.activeEvents` (which lists only profile-controlled events). |
| `event.surface_removed` | Lifecycle — **not profile-gated** | Always | Emitted when a window closes. Always active regardless of `eventProfile`. Does NOT appear in `pair.response.eventConfig.activeEvents`. |
| `event.pane_created` | Lifecycle — **not profile-gated** | Always | Emitted when a new pane is created (split or standalone). Always active regardless of `eventProfile`. Does NOT appear in `pair.response.eventConfig.activeEvents`. |
| `event.pane_removed` | Lifecycle — **not profile-gated** | Always | Emitted when a pane is closed. Always active regardless of `eventProfile`. Does NOT appear in `activeEvents`. |
| `event.pane_focused` | Lifecycle — **not profile-gated** | Always | Emitted when a pane is brought to focus. Always active regardless of `eventProfile`. Does NOT appear in `activeEvents`. |
| `event.pane_renamed` | Lifecycle — **not profile-gated** | Always | Emitted when a pane name changes. Always active regardless of `eventProfile`. Does NOT appear in `activeEvents`. |
| `event.tab_created` | Lifecycle — **not profile-gated** | Always | Emitted when a new tab is auto-created on first push from a session. Always active. Does NOT appear in `activeEvents`. |
| `event.tab_removed` | Lifecycle — **not profile-gated** | Always | Emitted when a tab is closed (user or `tab.close`). Always active. Does NOT appear in `activeEvents`. |
| `event.tab_focused` | Lifecycle — **not profile-gated** | Always | Emitted when the user switches to a different tab within a pane. Always active. Does NOT appear in `activeEvents`. |
| `event.scroll` | Context-rich but high-volume | No (`deep_plus_scroll` only) | Useful but not strictly required for minimum usefulness. |

Event behavior rules:
1. Events are in-order and reliable while socket is healthy.
2. Events are not replayed across reconnect.
3. After reconnect, provider must request `snapshot.get` before acting on new events.
4. Provider MUST buffer events that arrive while this mandatory `snapshot.get` is in-flight.
5. Provider event buffer during snapshot is bounded to 128 events. On overflow, oldest events are dropped and provider emits a local warning.
6. On snapshot success, provider applies snapshot state first, then processes buffered events in receive order.
7. On snapshot failure (`internal_error` or `content_too_large`), provider MUST close socket and re-enter reconnect backoff.
8. On backpressure, surface may coalesce/delay high-rate events (`event.scroll`) and delay `event.drawing_flush` emission until sendable; if any events were dropped/coalesced, emit `event.snapshot_hint` with reason `backpressure_drop`.
9. After completing a complex render (e.g. `content.set` with large HTML), surface emits `event.snapshot_hint` with reason `after_render` to signal provider that a fresh `snapshot.get` would yield meaningful content. This is advisory; provider may ignore it.
10. After a successful reconnect and re-pair, surface emits `event.snapshot_hint` with reason `after_reconnect` immediately after sending `pair.response` and before any other post-reconnect events. This hint will be buffered by the provider per rule 4 while `snapshot.get` is in-flight, and processed in order per rule 6 after snapshot completes. It is a trailing confirmation that post-snapshot state is authoritative — not a trigger. Provider SHOULD log receipt for diagnostics but no additional action is required beyond the rules 3–6 sync model.
11. Provider deduplicates events by `eventId` (retain last 1024 IDs per surface session).
12. If a flush send fails or disconnects mid-send, surface keeps unsent dirty strokes and retries on reconnect under normal flush-gate rules.

### 7.4 Flush Send Indicator (UI Requirement)

Surface must show a subtle visual send indicator while a drawing flush is in-flight to provider. See §15.5 for the required UI treatment of this indicator.

Required behavior:
1. Indicator becomes visible when `event.drawing_flush` transmission starts.
2. Indicator remains visible while transmission is in-flight.
3. Indicator hides immediately when transmission finishes (success or terminal failure).
4. Indicator must be subtle but noticeable (for example corner badge, pulsing icon, or brief overlay).
5. Indicator is only shown for drawing flush sends; no indicator when nothing changed.

## 8. Errors and Close Codes

### 8.1 Error Codes (response-level)

| Code | Meaning |
|---|---|
| `busy` | Surface already paired with another provider |
| `not_paired` | Operation attempted before successful pair |
| `invalid_payload` | JSON shape/type invalid |
| `invalid_request_id_reuse` | Duplicate request ID with different payload |
| `invalid_operation` | Operation not permitted in current state (e.g. closing the last pane) |
| `unsupported_protocol_version` | Provider protocol version mismatch |
| `unsupported_content_type` | Content type unsupported by surface |
| `unsupported_operation_for_content_type` | Append/patch not valid for current type |
| `stale_revision` | Revision gap or duplicate revision |
| `stale_content` | Frame-targeted mutation references non-current content |
| `content_too_large` | Message or content exceeds limits |
| `render_failed` | Rendering/patch failed |
| `rate_limited` | Temporary event/operation throttle |
| `internal_error` | Unhandled surface error |

### 8.2 WebSocket Close Codes

| Code | Reason |
|---|---|
| `1000` + `provider_shutdown` | Provider-initiated graceful shutdown. Content is preserved indefinitely (per §4.4 invariant). Session continuity available to same provider during grace window (`resumeGraceMs`). |
| `1000` + `superseded` | Same-provider takeover accepted. Old socket closed; displayed content preserved. New provider decides what to show next. |
| `4401` | Pair/auth failure |
| `4409` | Busy/occupied |
| `4410` | Protocol violation (malformed envelope/op mismatch) |
| `4413` | Payload too large |
| `4500` | Internal surface failure |

## 9. Security and Trust

### 9.1 Surface Identity
1. Surface holds persistent Ed25519 keypair.
2. `pk` TXT advertises fingerprint prefix.
3. v1 transport profile is `ws` on trusted LAN; WSS key/certificate profile is explicitly out of scope for v1.

### 9.2 Pairing Trust Model (v1)
1. Home-network default: auto-trust unknown surface on first successful pair.
2. Trusted surfaces auto-reconnect.
3. If pinned key changes, provider marks surface untrusted and requires re-pair approval.

### 9.3 WSS/TLS Scope
1. WSS/TLS certificate format and pinning profile is deferred to v2.
2. `tls` discovery TXT field is reserved and non-normative in v1.
3. Implementations MAY experiment with WSS privately, but v1 interoperability requirements are defined only for `ws`.

### 9.4 Session and Ownership
1. Session is bound to paired socket and `providerId`.
2. No callback token model exists.
3. No watch subscription tokens exist.

## 10. JSON Schemas (All Message Types)

The schema below defines every v1 application message type over WS.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://clawline.local/specs/surf-ace-ws-v1.schema.json",
  "title": "Surf Ace WS v1 Message",
  "type": "object",
  "oneOf": [
    { "$ref": "#/$defs/SurfacesListRequest" },
    { "$ref": "#/$defs/PairRequest" },
    { "$ref": "#/$defs/ContentSetRequest" },
    { "$ref": "#/$defs/ContentAppendRequest" },
    { "$ref": "#/$defs/ContentPatchRequest" },
    { "$ref": "#/$defs/ContentClearRequest" },
    { "$ref": "#/$defs/AnnotationsRemoveRequest" },
    { "$ref": "#/$defs/SnapshotGetRequest" },
    { "$ref": "#/$defs/HeartbeatPingRequest" },

    { "$ref": "#/$defs/SurfacesListResponse" },
    { "$ref": "#/$defs/PairResponse" },
    { "$ref": "#/$defs/MutationAckResponse" },
    { "$ref": "#/$defs/AnnotationsRemoveResponse" },
    { "$ref": "#/$defs/SnapshotResponse" },
    { "$ref": "#/$defs/HeartbeatPongResponse" },
    { "$ref": "#/$defs/ErrorResponse" },

    { "$ref": "#/$defs/DrawingFlushEvent" },
    { "$ref": "#/$defs/TapEvent" },
    { "$ref": "#/$defs/ScrollEvent" },
    { "$ref": "#/$defs/SelectionEvent" },
    { "$ref": "#/$defs/PageEvent" },
    { "$ref": "#/$defs/NavigationEvent" },
    { "$ref": "#/$defs/SurfaceAppearedEvent" },
    { "$ref": "#/$defs/SurfaceRemovedEvent" },
    { "$ref": "#/$defs/SnapshotHintEvent" },

    { "$ref": "#/$defs/PanesListRequest" },
    { "$ref": "#/$defs/PaneSplitRequest" },
    { "$ref": "#/$defs/PaneFocusRequest" },
    { "$ref": "#/$defs/PaneRenameRequest" },
    { "$ref": "#/$defs/PaneCloseRequest" },

    { "$ref": "#/$defs/PanesListResponse" },
    { "$ref": "#/$defs/PaneSplitResponse" },
    { "$ref": "#/$defs/PaneFocusResponse" },
    { "$ref": "#/$defs/PaneRenameResponse" },
    { "$ref": "#/$defs/PaneCloseResponse" },

    { "$ref": "#/$defs/PaneCreatedEvent" },
    { "$ref": "#/$defs/PaneRemovedEvent" },
    { "$ref": "#/$defs/PaneFocusedEvent" },
    { "$ref": "#/$defs/PaneRenamedEvent" },

    { "$ref": "#/$defs/TabListRequest" },
    { "$ref": "#/$defs/TabCloseRequest" },

    { "$ref": "#/$defs/TabListResponse" },
    { "$ref": "#/$defs/TabCloseResponse" },

    { "$ref": "#/$defs/TabCreatedEvent" },
    { "$ref": "#/$defs/TabRemovedEvent" },
    { "$ref": "#/$defs/TabFocusedEvent" }
  ],
  "$defs": {
    "RequestId": {
      "type": "string",
      "pattern": "^[A-Za-z0-9._:-]{1,64}$"
    },
    "ProviderId": {
      "type": "string",
      "pattern": "^pv_[A-Za-z0-9._:-]{3,64}$"
    },
    "ConnectionId": {
      "type": "string",
      "pattern": "^cn_[A-Za-z0-9._:-]{3,64}$"
    },
    "SessionId": {
      "type": "string",
      "pattern": "^sa_[A-Za-z0-9._:-]{8,128}$"
    },
    "SurfaceId": {
      "type": "string",
      "pattern": "^sf_[A-Za-z0-9._:-]{3,64}$"
    },
    "ContentId": {
      "type": "string",
      "pattern": "^ct_[0-9a-f]{8}$"
    },
    "StrokeId": {
      "type": "string",
      "pattern": "^stroke_[0-9a-f]{6,64}$"
    },
    "EventId": {
      "type": "string",
      "pattern": "^ev_[A-Za-z0-9._:-]{3,96}$"
    },
    "FlushId": {
      "type": "string",
      "pattern": "^fl_[A-Za-z0-9._:-]{3,96}$"
    },
    "PaneId": {
      "type": "string",
      "minLength": 1,
      "maxLength": 64,
      "description": "Pane identity within a surface. 'root' for the default single-pane layout. 'pane_N' (N a non-negative decimal integer) for auto-assigned panes (e.g. 'pane_0', 'pane_1'). Any non-empty string not starting with 'pane_' for user-assigned names. Name resolution (human-friendly aliases) is handled at the CLU layer; the wire layer accepts any non-empty string."
    },
    "TabId": {
      "type": "string",
      "minLength": 1,
      "maxLength": 128,
      "description": "Tab identity within a pane. Assigned by the surface on first push from a session. Derived from sessionId (e.g., a stable short hash or the full sessionId string). Format is surface-defined; providers treat it as an opaque string. CLU does not need to reference tabId for routing — surface routes by sessionId automatically. TabId is echoed in push responses so CLU can identify which tab it owns."
    },
    "Revision": {
      "type": "integer",
      "minimum": 0
    },
    "EpochMs": {
      "type": "integer",
      "minimum": 0
    },
    "ContentType": {
      "type": "string",
      "enum": ["html", "image", "pdf", "terminal", "markdown", "video", "canvas"]
    },
    "EventType": {
      "type": "string",
      "enum": [
        "event.drawing_flush",
        "event.tap",
        "event.scroll",
        "event.selection",
        "event.page",
        "event.navigation",
        "event.surface_appeared",
        "event.surface_removed",
        "event.snapshot_hint",
        "event.pane_created",
        "event.pane_removed",
        "event.pane_focused",
        "event.pane_renamed",
        "event.tab_created",
        "event.tab_removed",
        "event.tab_focused"
      ]
    },
    "ProfileControlledEventType": {
      "type": "string",
      "description": "Event types that are governed by eventProfile. Excludes lifecycle events (event.surface_appeared, event.surface_removed) which are always active and never appear in activeEvents.",
      "enum": [
        "event.drawing_flush",
        "event.tap",
        "event.scroll",
        "event.selection",
        "event.page",
        "event.navigation",
        "event.snapshot_hint"
      ]
    },
    "EventProfile": {
      "type": "string",
      "enum": ["minimum_deep", "deep_plus_scroll"]
    },
    "DrawingFlushConfig": {
      "type": "object",
      "additionalProperties": false,
      "required": ["idleWindowMs", "maxIntervalMs"],
      "properties": {
        "idleWindowMs": {
          "type": "integer",
          "minimum": 5000,
          "maximum": 10000,
          "default": 8000
        },
        "maxIntervalMs": {
          "type": "integer",
          "minimum": 10000,
          "default": 30000
        }
      }
    },
    "Position": {
      "type": "object",
      "additionalProperties": false,
      "required": ["x", "y"],
      "properties": {
        "x": { "type": "number" },
        "y": { "type": "number" }
      }
    },
    "Rect": {
      "type": "object",
      "additionalProperties": false,
      "required": ["x", "y", "width", "height"],
      "properties": {
        "x": { "type": "number" },
        "y": { "type": "number" },
        "width": { "type": "number", "minimum": 0 },
        "height": { "type": "number", "minimum": 0 }
      }
    },
    "Viewport": {
      "type": "object",
      "additionalProperties": false,
      "required": ["scrollOffset", "visibleRect", "contentSize", "zoomLevel"],
      "properties": {
        "scrollOffset": {
          "type": "object",
          "additionalProperties": false,
          "required": ["x", "y"],
          "properties": {
            "x": { "type": "number" },
            "y": { "type": "number" }
          }
        },
        "visibleRect": { "$ref": "#/$defs/Rect" },
        "contentSize": {
          "type": "object",
          "additionalProperties": false,
          "required": ["width", "height"],
          "properties": {
            "width": { "type": "number", "minimum": 0 },
            "height": { "type": "number", "minimum": 0 }
          }
        },
        "zoomLevel": { "type": "number", "exclusiveMinimum": 0 }
      }
    },
    "SurfaceViewport": {
      "type": "object",
      "additionalProperties": false,
      "required": ["width", "height", "scale"],
      "properties": {
        "width": { "type": "integer", "minimum": 1 },
        "height": { "type": "integer", "minimum": 1 },
        "scale": { "type": "number", "exclusiveMinimum": 0 }
      }
    },
    "Selection": {
      "oneOf": [
        { "type": "null" },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["kind", "text"],
          "properties": {
            "kind": { "const": "text" },
            "text": { "type": "string" },
            "boundingRect": { "$ref": "#/$defs/Rect" }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "description": "Selection point variant (reserved for v2 unless explicitly negotiated). v1 providers MAY receive this but MUST ignore when no v2 selection negotiation is active.",
          "required": ["kind", "position"],
          "properties": {
            "kind": { "const": "point" },
            "position": { "$ref": "#/$defs/Position" }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "description": "Selection region variant (reserved for v2 unless explicitly negotiated). v1 providers MAY receive this but MUST ignore when no v2 selection negotiation is active.",
          "required": ["kind", "rect"],
          "properties": {
            "kind": { "const": "region" },
            "rect": { "$ref": "#/$defs/Rect" },
            "text": { "type": "string" }
          }
        }
      ]
    },
    "ErrorBody": {
      "type": "object",
      "additionalProperties": false,
      "required": ["code", "message"],
      "properties": {
        "code": {
          "type": "string",
          "enum": [
            "busy",
            "not_paired",
            "invalid_payload",
            "invalid_request_id_reuse",
            "invalid_operation",
            "unsupported_protocol_version",
            "unsupported_content_type",
            "unsupported_operation_for_content_type",
            "stale_revision",
            "stale_content",
            "content_too_large",
            "render_failed",
            "rate_limited",
            "internal_error"
          ]
        },
        "message": { "type": "string", "minLength": 1 },
        "details": { "type": "object" }
      }
    },
    "HtmlContent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["html"],
      "properties": {
        "html": { "type": "string" },
        "baseUrl": { "type": "string" }
      }
    },
    "ImageContent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["data", "mediaType"],
      "properties": {
        "data": { "type": "string" },
        "mediaType": { "type": "string" },
        "alt": { "type": "string" }
      }
    },
    "PdfContent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["data"],
      "properties": {
        "data": { "type": "string" }
      }
    },
    "TerminalContent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["lines", "scrollback"],
      "properties": {
        "lines": {
          "type": "array",
          "items": { "type": "string" }
        },
        "scrollback": { "type": "integer", "minimum": 0 }
      }
    },
    "MarkdownContent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["markdown"],
      "properties": {
        "markdown": { "type": "string" }
      }
    },
    "VideoContent": {
      "type": "string"
    },
    "CanvasContent": {
      "oneOf": [
        { "type": "string", "maxLength": 0 },
        {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "color": { "type": "string" },
            "grid": { "type": "boolean" }
          }
        }
      ]
    },

    "SurfacesListRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "surfaces.list" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" }
      }
    },
    "SurfacesListResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "surfaces.list" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaces"],
          "properties": {
            "surfaces": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["surfaceId", "name", "autoLabel", "viewport", "paired"],
                "properties": {
                  "surfaceId": { "$ref": "#/$defs/SurfaceId" },
                  "name": { "type": "string" },
                  "autoLabel": { "type": "string", "description": "Auto-assigned window letter label (e.g. 'A', 'B', 'AA'). Displayed prominently on surface UI and usable as a short address in CLU tools." },
                  "viewport": { "$ref": "#/$defs/SurfaceViewport" },
                  "paired": { "type": "boolean", "description": "true if actively paired or in resume grace (mirrors mDNS busy=1). pair.request requires takeover=true, but only same-provider takeover succeeds during grace. A different provider will receive busy." }
                }
              }
            }
          }
        }
      }
    },

    "PairRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "pair.request" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["providerId", "connectionId", "protocolVersion", "surfaceId"],
          "properties": {
            "providerId": { "$ref": "#/$defs/ProviderId" },
            "connectionId": { "$ref": "#/$defs/ConnectionId" },
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "providerName": { "type": "string" },
            "protocolVersion": { "const": 1 },
            "takeover": { "type": "boolean" },
            "eventProfile": { "$ref": "#/$defs/EventProfile" },
            "drawingFlushConfig": { "$ref": "#/$defs/DrawingFlushConfig" },
            "resume": {
              "type": "object",
              "additionalProperties": false,
              "required": ["sessionId"],
              "properties": {
                "sessionId": { "$ref": "#/$defs/SessionId" }
              }
            }
          }
        }
      }
    },
    "ContentSetRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "content.set" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "allOf": [
            {
              "type": "object",
              "additionalProperties": false,
              "required": ["contentId", "revision", "contentType", "content"],
              "properties": {
                "contentId": { "$ref": "#/$defs/ContentId" },
                "revision": { "$ref": "#/$defs/Revision" },
                "contentType": { "$ref": "#/$defs/ContentType" },
                "content": {},
                "tabId": {
                  "$ref": "#/$defs/TabId",
                  "description": "Optional. If provided, explicitly targets an existing tab within the pane. If omitted, the surface routes by sessionId to the session's existing tab or creates a new one. CLU does not need to pass tabId for normal pushes — session-based routing handles this automatically."
                },
                "display": {
                  "type": "object",
                  "additionalProperties": false,
                  "properties": {
                    "title": { "type": "string" },
                    "scrollable": { "type": "boolean" },
                    "interactive": { "type": "boolean" }
                  }
                }
              }
            },
            {
              "oneOf": [
                {
                  "properties": {
                    "contentType": { "const": "html" },
                    "content": { "$ref": "#/$defs/HtmlContent" }
                  }
                },
                {
                  "properties": {
                    "contentType": { "const": "image" },
                    "content": { "$ref": "#/$defs/ImageContent" }
                  }
                },
                {
                  "properties": {
                    "contentType": { "const": "pdf" },
                    "content": { "$ref": "#/$defs/PdfContent" }
                  }
                },
                {
                  "properties": {
                    "contentType": { "const": "terminal" },
                    "content": { "$ref": "#/$defs/TerminalContent" }
                  }
                },
                {
                  "properties": {
                    "contentType": { "const": "markdown" },
                    "content": { "$ref": "#/$defs/MarkdownContent" }
                  }
                },
                {
                  "properties": {
                    "contentType": { "const": "video" },
                    "content": { "$ref": "#/$defs/VideoContent" }
                  }
                },
                {
                  "properties": {
                    "contentType": { "const": "canvas" },
                    "content": { "$ref": "#/$defs/CanvasContent" }
                  }
                }
              ]
            }
          ]
        }
      }
    },
    "ContentAppendRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "content.append" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "revision", "lines"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "lines": {
              "type": "array",
              "items": { "type": "string" }
            }
          }
        }
      }
    },
    "ContentPatchRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "content.patch" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "revision", "patch"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "patch": {
              "type": "object",
              "additionalProperties": false,
              "required": ["selector", "action"],
              "properties": {
                "selector": { "type": "string" },
                "action": {
                  "type": "string",
                  "enum": [
                    "replace_inner",
                    "replace_outer",
                    "insert_before",
                    "insert_after",
                    "remove"
                  ]
                },
                "html": { "type": "string" }
              }
            }
          }
        }
      }
    },
    "ContentClearRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "content.clear" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["revision"],
          "properties": {
            "revision": { "$ref": "#/$defs/Revision" }
          }
        }
      }
    },
    "AnnotationsRemoveRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "annotations.remove" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "strokeIds"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "strokeIds": {
              "type": "array",
              "items": { "$ref": "#/$defs/StrokeId" },
              "minItems": 1,
              "uniqueItems": true
            }
          }
        }
      }
    },
    "SnapshotGetRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "snapshot.get" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "includeImage": { "type": "boolean", "default": false },
            "includeVisibleText": { "type": "boolean", "default": true },
            "includeDrawings": { "type": "boolean", "default": false }
          }
        }
      }
    },
    "HeartbeatPingRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "heartbeat.ping" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["nonce"],
          "properties": {
            "nonce": { "type": "string", "minLength": 1, "maxLength": 128 }
          }
        }
      }
    },

    "PairResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "pair.request" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "sessionId",
            "resumed",
            "surfaceId",
            "surfaceName",
            "viewport",
            "capabilities",
            "eventConfig",
            "limits",
            "state"
          ],
          "properties": {
            "sessionId": { "$ref": "#/$defs/SessionId" },
            "resumed": { "type": "boolean" },
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "surfaceName": { "type": "string" },
            "viewport": {
              "type": "object",
              "additionalProperties": false,
              "required": ["width", "height", "scale"],
              "properties": {
                "width": { "type": "integer", "minimum": 1 },
                "height": { "type": "integer", "minimum": 1 },
                "scale": { "type": "number", "exclusiveMinimum": 0 }
              }
            },
            "capabilities": {
              "type": "object",
              "additionalProperties": false,
              "required": ["contentTypes", "eventTypes"],
              "properties": {
                "contentTypes": {
                  "type": "array",
                  "items": { "$ref": "#/$defs/ContentType" },
                  "uniqueItems": true
                },
                "eventTypes": {
                  "type": "array",
                  "items": { "$ref": "#/$defs/EventType" },
                  "uniqueItems": true
                }
              }
            },
            "eventConfig": {
              "type": "object",
              "additionalProperties": false,
              "required": ["profile", "activeEvents", "drawingFlushConfig"],
              "properties": {
                "profile": { "$ref": "#/$defs/EventProfile" },
                "activeEvents": {
                  "type": "array",
                  "items": { "$ref": "#/$defs/ProfileControlledEventType" },
                  "uniqueItems": true,
                  "description": "Profile-controlled events active for this session. Lifecycle events (surface_appeared/removed) are excluded — they are always active regardless of profile."
                },
                "drawingFlushConfig": { "$ref": "#/$defs/DrawingFlushConfig" }
              }
            },
            "limits": {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "maxMessageBytes",
                "maxFrameBytes",
                "maxVisibleTextBytes",
                "maxStrokePointsPerFlush",
                "maxDrawingFlushBytes",
                "resumeGraceMs"
              ],
              "properties": {
                "maxMessageBytes": { "type": "integer", "minimum": 1024 },
                "maxFrameBytes": { "type": "integer", "minimum": 1024 },
                "maxVisibleTextBytes": { "type": "integer", "minimum": 256 },
                "maxStrokePointsPerFlush": { "type": "integer", "minimum": 1 },
                "maxDrawingFlushBytes": { "type": "integer", "minimum": 1024 },
                "resumeGraceMs": { "type": "integer", "minimum": 5000, "default": 20000, "description": "Session continuity grace window in ms. The same provider must reconnect within this window to resume the session with the same providerId. New providers may connect after grace expiry." }
              }
            },
            "state": {
              "type": "object",
              "additionalProperties": false,
              "required": ["currentContentId", "currentRevision", "contentType"],
              "properties": {
                "currentContentId": {
                  "oneOf": [{ "$ref": "#/$defs/ContentId" }, { "type": "null" }]
                },
                "currentRevision": { "$ref": "#/$defs/Revision" },
                "contentType": {
                  "oneOf": [{ "$ref": "#/$defs/ContentType" }, { "type": "null" }]
                }
              }
            }
          }
        }
      }
    },
    "MutationAckResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": {
          "type": "string",
          "enum": ["content.set", "content.append", "content.patch", "content.clear"]
        },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["currentContentId", "currentRevision", "tabId"],
          "properties": {
            "currentContentId": {
              "oneOf": [{ "$ref": "#/$defs/ContentId" }, { "type": "null" }]
            },
            "currentRevision": { "$ref": "#/$defs/Revision" },
            "contentType": {
              "oneOf": [{ "$ref": "#/$defs/ContentType" }, { "type": "null" }]
            },
            "tabId": {
              "oneOf": [{ "$ref": "#/$defs/TabId" }, { "type": "null" }],
              "description": "The tab that was created or updated for this session in the target pane. Required. Present (non-null) on content.set responses. Null on content.append, content.patch, and content.clear. CLU does not need to pass tabId on subsequent pushes — surface continues routing by sessionId automatically."
            }
          }
        }
      }
    },
    "AnnotationsRemoveResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "annotations.remove" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "removedStrokeIds", "notFoundStrokeIds", "remainingStrokeCount"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "removedStrokeIds": {
              "type": "array",
              "items": { "$ref": "#/$defs/StrokeId" },
              "uniqueItems": true
            },
            "notFoundStrokeIds": {
              "type": "array",
              "items": { "$ref": "#/$defs/StrokeId" },
              "uniqueItems": true
            },
            "remainingStrokeCount": { "type": "integer", "minimum": 0 }
          }
        }
      }
    },
    "SnapshotResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "snapshot.get" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "contentId",
            "revision",
            "contentType",
            "viewport",
            "selection"
          ],
          "properties": {
            "contentId": {
              "oneOf": [{ "$ref": "#/$defs/ContentId" }, { "type": "null" }]
            },
            "revision": { "$ref": "#/$defs/Revision" },
            "contentType": {
              "oneOf": [{ "$ref": "#/$defs/ContentType" }, { "type": "null" }]
            },
            "viewport": { "$ref": "#/$defs/Viewport" },
            "visibleText": { "type": "string" },
            "selection": { "$ref": "#/$defs/Selection" },
            "drawings": {
              "type": "array",
              "items": { "$ref": "#/$defs/Stroke" }
            },
            "image": {
              "type": "string",
              "contentEncoding": "base64",
              "contentMediaType": "image/png"
            }
          }
        }
      }
    },
    "HeartbeatPongResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "heartbeat.ping" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["nonce"],
          "properties": {
            "nonce": { "type": "string", "minLength": 1, "maxLength": 128 }
          }
        }
      }
    },
    "ErrorResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "error"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": {
          "type": "string",
          "enum": [
            "surfaces.list",
            "pair.request",
            "content.set",
            "content.append",
            "content.patch",
            "content.clear",
            "annotations.remove",
            "snapshot.get",
            "heartbeat.ping",
            "panes.list",
            "pane.split",
            "pane.focus",
            "pane.rename",
            "pane.close",
            "tab.list",
            "tab.close"
          ]
        },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": false },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "error": { "$ref": "#/$defs/ErrorBody" }
      }
    },

    "StrokePoint": {
      "type": "object",
      "additionalProperties": false,
      "required": ["x", "y", "timestamp"],
      "properties": {
        "x": { "type": "number" },
        "y": { "type": "number" },
        "pressure": { "type": "number", "minimum": 0, "maximum": 1 },
        "timestamp": { "$ref": "#/$defs/EpochMs" }
      }
    },
    "Stroke": {
      "type": "object",
      "additionalProperties": false,
      "required": ["strokeId", "tool", "points"],
      "properties": {
        "strokeId": { "$ref": "#/$defs/StrokeId" },
        "tool": { "type": "string", "enum": ["pencil", "finger", "mouse"] },
        "videoTimestamp": { "type": "number", "minimum": 0 },
        "points": {
          "type": "array",
          "items": { "$ref": "#/$defs/StrokePoint" },
          "minItems": 1
        }
      }
    },

    "DrawingFlushEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.drawing_flush" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "contentId",
            "revision",
            "flushId",
            "flushReason",
            "idleWindowMs",
            "maxIntervalMs",
            "strokes",
            "strokeCount",
            "pointsCount",
            "firstStrokeAt",
            "lastStrokeAt"
          ],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "flushId": { "$ref": "#/$defs/FlushId" },
            "flushReason": {
              "type": "string",
              "enum": ["idle_window", "max_interval"]
            },
            "idleWindowMs": { "type": "integer", "minimum": 5000, "maximum": 10000 },
            "maxIntervalMs": { "type": "integer", "minimum": 10000 },
            "strokes": {
              "type": "array",
              "items": { "$ref": "#/$defs/Stroke" },
              "minItems": 1
            },
            "strokeCount": { "type": "integer", "minimum": 1 },
            "pointsCount": { "type": "integer", "minimum": 1 },
            "firstStrokeAt": { "$ref": "#/$defs/EpochMs" },
            "lastStrokeAt": { "$ref": "#/$defs/EpochMs" }
          }
        }
      }
    },
    "TapEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.tap" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "revision", "kind", "position"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "kind": { "type": "string", "enum": ["tap", "long_press"] },
            "position": { "$ref": "#/$defs/Position" },
            "nearestContent": { "type": "string" }
          }
        }
      }
    },
    "ScrollEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.scroll" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "revision", "phase", "viewport", "visibleText"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "phase": { "const": "settled" },
            "viewport": { "$ref": "#/$defs/Viewport" },
            "visibleText": { "type": "string" }
          }
        }
      }
    },
    "SelectionEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.selection" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "revision", "selection"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "selection": { "$ref": "#/$defs/Selection" }
          }
        }
      }
    },
    "PageEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.page" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "revision", "page", "totalPages"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "page": { "type": "integer", "minimum": 1 },
            "totalPages": { "type": "integer", "minimum": 1 },
            "pageText": { "type": "string" }
          }
        }
      }
    },
    "NavigationEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.navigation" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["contentId", "revision", "url"],
          "properties": {
            "contentId": { "$ref": "#/$defs/ContentId" },
            "revision": { "$ref": "#/$defs/Revision" },
            "url": { "type": "string" }
          }
        }
      }
    },
    "SurfaceAppearedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.surface_appeared" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "name", "viewport"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "name": { "type": "string" },
            "viewport": { "$ref": "#/$defs/SurfaceViewport" }
          }
        }
      }
    },
    "SurfaceRemovedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.surface_removed" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" }
          }
        }
      }
    },
    "SnapshotHintEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.snapshot_hint" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["reason"],
          "properties": {
            "reason": {
              "type": "string",
              "enum": ["after_render", "after_reconnect", "backpressure_drop"]
            }
          }
        }
      }
    },

    "PanesListRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "panes.list" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" }
      }
    },
    "PanesListResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "panes.list" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["panes"],
          "properties": {
            "panes": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["paneId", "name", "autoLabel", "activeContentId", "contentType", "viewport", "focused"],
                "properties": {
                  "paneId": { "$ref": "#/$defs/PaneId" },
                  "name": {
                    "oneOf": [
                      { "type": "string", "minLength": 1 },
                      { "type": "null" }
                    ],
                    "description": "User-assigned human-readable name for this pane, or null if none."
                  },
                  "autoLabel": {
                    "type": "integer",
                    "minimum": 0,
                    "description": "Auto-assigned pane number within the window (0, 1, 2, …). Displayed on surface UI."
                  },
                  "activeContentId": {
                    "oneOf": [{ "$ref": "#/$defs/ContentId" }, { "type": "null" }]
                  },
                  "contentType": {
                    "oneOf": [{ "$ref": "#/$defs/ContentType" }, { "type": "null" }]
                  },
                  "viewport": { "$ref": "#/$defs/SurfaceViewport" },
                  "focused": { "type": "boolean" }
                }
              }
            }
          }
        }
      }
    },

    "PaneSplitRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "pane.split" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["count", "direction"],
          "properties": {
            "paneId": {
              "$ref": "#/$defs/PaneId",
              "default": "root",
              "description": "Pane to split. Defaults to 'root' when omitted."
            },
            "count": {
              "type": "integer",
              "minimum": 2,
              "description": "Total pane count after split, including the source pane."
            },
            "direction": {
              "type": "string",
              "enum": ["horizontal", "vertical"]
            }
          }
        }
      }
    },
    "PaneSplitResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "pane.split" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["panes"],
          "properties": {
            "panes": {
              "type": "array",
              "minItems": 1,
              "description": "All panes in the window after the split, including pre-existing panes. The source pane retains its original paneId and appears first.",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["paneId", "autoLabel"],
                "properties": {
                  "paneId": { "$ref": "#/$defs/PaneId" },
                  "autoLabel": { "type": "integer", "minimum": 0 }
                }
              }
            }
          }
        }
      }
    },

    "PaneFocusRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "pane.focus" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" }
          }
        }
      }
    },
    "PaneFocusResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "pane.focus" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId", "focused"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" },
            "focused": { "const": true }
          }
        }
      }
    },

    "PaneRenameRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "pane.rename" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId", "name"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" },
            "name": {
              "oneOf": [
                { "type": "string", "minLength": 1 },
                { "type": "null" }
              ],
              "description": "New human-readable name for the pane, or null to clear an existing name."
            }
          }
        }
      }
    },
    "PaneRenameResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "pane.rename" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId", "name"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" },
            "name": {
              "oneOf": [
                { "type": "string", "minLength": 1 },
                { "type": "null" }
              ]
            }
          }
        }
      }
    },

    "PaneCloseRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "pane.close" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" }
          }
        }
      }
    },
    "PaneCloseResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "pane.close" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId", "closedFramesDiscarded"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" },
            "closedFramesDiscarded": {
              "type": "integer",
              "minimum": 0,
              "description": "Count of unread closed annotation frames dropped from the provider buffer for this pane. CLU can use this to know what was lost."
            }
          }
        }
      }
    },

    "PaneCreatedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.pane_created" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "paneId", "autoLabel", "fromSplit"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "paneId": { "$ref": "#/$defs/PaneId" },
            "autoLabel": { "type": "integer", "minimum": 0 },
            "parentPaneId": {
              "oneOf": [{ "$ref": "#/$defs/PaneId" }, { "type": "null" }],
              "description": "The pane that was split to produce this new pane, or null if created standalone."
            },
            "fromSplit": {
              "type": "boolean",
              "description": "true when this pane was created as part of a pane.split operation."
            }
          }
        }
      }
    },
    "PaneRemovedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.pane_removed" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "paneId"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "paneId": { "$ref": "#/$defs/PaneId" }
          }
        }
      }
    },
    "PaneFocusedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.pane_focused" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "paneId"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "paneId": { "$ref": "#/$defs/PaneId" }
          }
        }
      }
    },
    "PaneRenamedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.pane_renamed" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "paneId", "name"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "paneId": { "$ref": "#/$defs/PaneId" },
            "name": {
              "oneOf": [
                { "type": "string", "minLength": 1 },
                { "type": "null" }
              ]
            }
          }
        }
      }
    },

    "TabListRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "tab.list" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" }
          }
        }
      }
    },
    "TabListResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "tab.list" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["tabs"],
          "properties": {
            "tabs": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["tabId", "sessionId", "label", "activeContentId", "contentType", "focused"],
                "properties": {
                  "tabId": { "$ref": "#/$defs/TabId" },
                  "sessionId": { "$ref": "#/$defs/SessionId" },
                  "label": {
                    "type": "string",
                    "description": "Surface-assigned human-readable label for this tab (e.g. 'Chat A', 'Chat B'). Derived from sessionId."
                  },
                  "activeContentId": {
                    "oneOf": [{ "$ref": "#/$defs/ContentId" }, { "type": "null" }],
                    "description": "The content currently displayed in this tab, or null if the tab has been cleared."
                  },
                  "contentType": {
                    "oneOf": [{ "$ref": "#/$defs/ContentType" }, { "type": "null" }]
                  },
                  "focused": {
                    "type": "boolean",
                    "description": "true if this is the tab currently visible to the user in this pane."
                  }
                }
              }
            }
          }
        }
      }
    },

    "TabCloseRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "request" },
        "op": { "const": "tab.close" },
        "id": { "$ref": "#/$defs/RequestId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["paneId", "tabId"],
          "properties": {
            "paneId": { "$ref": "#/$defs/PaneId" },
            "tabId": { "$ref": "#/$defs/TabId" }
          }
        }
      }
    },
    "TabCloseResponse": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "id", "ok", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "response" },
        "op": { "const": "tab.close" },
        "id": { "$ref": "#/$defs/RequestId" },
        "ok": { "const": true },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["tabId", "closedFramesDiscarded"],
          "properties": {
            "tabId": { "$ref": "#/$defs/TabId" },
            "closedFramesDiscarded": {
              "type": "integer",
              "minimum": 0,
              "description": "Count of unread closed annotation frames dropped from provider buffer for this tab. CLU can use this to know what was lost."
            }
          }
        }
      }
    },

    "TabCreatedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.tab_created" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "paneId", "tabId", "sessionId", "label"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "paneId": { "$ref": "#/$defs/PaneId" },
            "tabId": { "$ref": "#/$defs/TabId" },
            "sessionId": { "$ref": "#/$defs/SessionId" },
            "label": {
              "type": "string",
              "description": "Surface-assigned human-readable label for the new tab (e.g. 'Chat A')."
            }
          }
        }
      }
    },
    "TabRemovedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.tab_removed" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "paneId", "tabId"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "paneId": { "$ref": "#/$defs/PaneId" },
            "tabId": { "$ref": "#/$defs/TabId" }
          }
        }
      }
    },
    "TabFocusedEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": ["v", "type", "op", "eventId", "sentAt", "payload"],
      "properties": {
        "v": { "const": 1 },
        "type": { "const": "event" },
        "op": { "const": "event.tab_focused" },
        "eventId": { "$ref": "#/$defs/EventId" },
        "sentAt": { "$ref": "#/$defs/EpochMs" },
        "payload": {
          "type": "object",
          "additionalProperties": false,
          "required": ["surfaceId", "paneId", "tabId"],
          "properties": {
            "surfaceId": { "$ref": "#/$defs/SurfaceId" },
            "paneId": { "$ref": "#/$defs/PaneId" },
            "tabId": {
              "$ref": "#/$defs/TabId",
              "description": "The tab the user has switched to."
            }
          }
        }
      }
    }

  }
}
```

## 11. Adversarial Hardening Results

This section documents the hardening decisions locked into the protocol.

1. Race: duplicate sockets from reconnect overlap.
Resolution: pair handshake includes `providerId` + per-attempt `connectionId`; one paired session only; busy rejection for non-owner providers; explicit same-provider `takeover=true` closes stale socket and hands ownership to the new socket.

2. Out-of-order or retried content mutations.
Resolution: mandatory monotonic `revision`; strict `expectedRevision` gate; request-ID idempotency cache.

3. Event loss or event flood.
Resolution: event stream is best-effort across reconnect by design; provider must issue `snapshot.get` after reconnect; backpressure coalesces high-rate events and emits `event.snapshot_hint`; drawing flushes are dual-gated (idle + max interval) to bound send frequency.

4. Ghost occupancy after crash.
Resolution: any disconnect enters bounded resume grace; if not resumed in `resumeGraceMs` (default 20s), surface releases `busy` so new providers can connect. Displayed content is NEVER cleared by grace expiry — content persists until CLU explicitly changes it.

5. Payload abuse and parser risk.
Resolution: explicit max-byte limits in pair response; typed schemas; `content_too_large` and WS close `4413`; malformed envelope closes `4410`.

6. Stale content targeting (append/patch after replace).
Resolution: mutation ops require both current `contentId` and next `revision`; stale content returns `stale_content`.

7. Ambiguous state after reconnect.
Resolution: pair response always returns authoritative current state (`currentContentId`, `currentRevision`, `contentType`), and provider performs immediate `snapshot.get` before normal operation.

8. Short drawing pauses triggering noisy sends.
Resolution: send requires unsent changes (`dirty=true`) plus either idle-window silence or max-interval expiry; small pauses do not flush.

9. Continuous drawing never flushing.
Resolution: max interval timer forces `event.drawing_flush` at 30s (default) whenever unsent strokes exist.

10. Redundant resend with no changes.
Resolution: `dirty` gating forbids sends unless new strokes arrived since last successful send.

11. Flush transmission visibility ambiguity.
Resolution: surface shows a visible in-flight send indicator for every drawing flush attempt.

12. Surgical deletion drift (wrong strokes removed).
Resolution: every stroke carries stable `strokeId`; `annotations.remove` accepts explicit `strokeIds` and returns `removedStrokeIds` + `notFoundStrokeIds`, leaving unspecified strokes untouched.

13. Surface overreach on drawing semantics.
Resolution: surface remains passive and non-interpreting; only CLU decides persistent vs consumed drawings and invokes `annotations.remove` when needed.

14. Orphaned strokes across content transitions.
Resolution: `content.set` and `content.clear` both hard-clear the drawing overlay; no cross-content carryover is allowed.

15. Snapshot bloat and recovery failure.
Resolution: `visibleText` and `drawings` are conditional fields governed by request flags (`includeVisibleText` default true, `includeDrawings` default false).

16. Heartbeat false timeouts during heavy rendering.
Resolution: surface must prioritize pong generation over render/mutation queue work.

17. Pair handshake hang.
Resolution: provider enforces 10s `pair.request` timeout from socket establishment, then closes and reconnects.

18. Reconnect race between fresh events and state resync.
Resolution: provider buffers post-reconnect events during mandatory snapshot, applies snapshot first, then drains buffered events in order.

19. Snapshot image interoperability mismatch.
Resolution: `snapshot.get` image payload is explicitly base64-encoded PNG.

20. TLS profile ambiguity for v1.
Resolution: v1 interop scope is `ws` only; WSS/TLS profile is deferred to v2 and marked out of scope.

## 12. Implementation Readiness Checks

Protocol is ready for implementation when these checks pass in integration tests:
1. Provider can discover, connect, pair, push content, clear content, and get snapshot over WS only.
2. Default `minimum_deep` profile emits `event.drawing_flush`, `event.tap`, `event.selection`, `event.page`, `event.navigation`, and provider-internal `event.snapshot_hint` without any watch subscription call.
3. Surface flushes drawings only under dual-gate timing (`idleWindowMs` + `maxIntervalMs`) and never flushes unchanged data.
4. Every stroke in `event.drawing_flush` and `snapshot.get` has stable `strokeId` and retains ID stability until explicitly removed.
5. `annotations.remove` removes only requested stroke IDs, reports `removedStrokeIds`/`notFoundStrokeIds`, and preserves all unspecified strokes.
6. Reconnect path resumes within grace for same provider; after grace expiry the session is invalidated and `busy=0` (new providers may connect), but displayed content is unchanged.
7. Revision errors and idempotency replay behave exactly as specified.
8. Visual send indicator is visible while each drawing flush transmission is in-flight.
9. `content.set` and `content.clear` both clear drawing overlay state.
10. Heartbeat pong is emitted within SLA even while render queue is busy.
11. Pair request times out at 10s when `pair.response` is missing.
12. Reconnect path buffers events until snapshot succeeds, then replays in order; on snapshot failure provider reconnects.
13. `snapshot.get` returns base64 PNG for `image` and conditionally includes `visibleText`/`drawings` per request flags.
14. All messages validate against the schema in Section 10.
15. Surf Ace extension skills are present at these provider paths and load successfully:
   - `extensions/surf-ace/skills/surf-ace-ops/SKILL.md` (tool usage for list/push/read/clear/pane/tab ops)
   - `extensions/surf-ace/skills/surf-ace-markup/SKILL.md` (annotation interpretation + markup workflow)
16. Surf Ace agent-instruction injection is present and wired from these provider paths:
   - `extensions/surf-ace/src/agent-instructions.ts` (builds Surf Ace instruction snippet)
   - `extensions/surf-ace/index.ts` (registers/injects Surf Ace instruction snippet into agent runtime prompt)
   The injected instructions MUST cover event semantics (`event.drawing_flush`, pane/tab lifecycle events, navigation/page/selection handling) so agents can correctly interpret Surf Ace alerts.

Implementation status: ready for implementation.

## 13. Provider → CLU Event Routing

This section specifies how surface events reach CLU. It is intentionally separate from the WS protocol (Sections 3–10), which covers only the provider↔surface channel. The provider↔CLU channel is a different seam with different requirements.

### 13.1 Design Principles

1. **Augmentative, not invasive.** Normal Clawline message dispatch must have zero knowledge of Surf Ace. No Surf Ace logic runs in the inbound message critical path.
2. **Tool-driven.** CLU interacts with surfaces exclusively via explicit tool calls. The provider never injects context into a CLU turn automatically.
3. **Alerts are expensive.** Each alert fires a CLU agent turn. The provider MUST minimize alerts while still ensuring CLU can observe surface activity in a timely way.
4. **No live network I/O in dispatch path.** The provider MUST NOT issue live `snapshot.get` calls (or any network calls to surfaces) as part of processing an inbound CLU message.

### 13.2 Per-Screen Local Buffer (Dual Channel: Live Dirty + Closed Frames + Registers)

The provider maintains a structured local buffer for each surface. The buffer has **two annotation channels** plus typed **non-annotation registers**.

- **Channel A — Live dirty channel (mutable):** near-real-time stroke deltas for the currently active context frame while the user is annotating.
- **Channel B — Closed frame queue (immutable):** finalized context frames that must remain deliverable until CLU consumes them.

CLU reads from this local buffer only; no `surf_ace_read` call triggers a live network call to a surface.

**Buffer scoping (tab model):** The annotation buffer — both channels A and B, plus all non-annotation registers — is scoped per tab. The buffer key is `(surfaceId, paneId, tabId)`. Each tab maintains its own independent live dirty channel, closed frame queue, and registers. Tabs in the same pane do not share annotation state.

`surf_ace_read` at the CLU tool layer is already session-keyed: the calling session's `sessionId` is used to derive `tabId`, so the read automatically targets that session's tab without requiring any `tabId` parameter. No API change is needed at the CLU tool layer — session-keyed routing is implicit and transparent to callers. This means existing `surf_ace_read` callers continue to work unchanged and automatically read their own tab's buffer.

---

#### Annotation Context Frame Model (Context-Keyed, Not Session-Keyed)

Annotation data is keyed by **context**, not by annotation session.

A context key is:
- CLU-pushed content: active `contentId`
- HTML user navigation context: normalized URL (fragment stripped, query preserved)
- Non-URL types: `contentId` (or equivalent stable content identity)

**Important invariants:**
1. Scroll alone does **not** create a new context frame.
2. Navigation/content change alone does **not** create a frame.
3. A new frame is created only when annotation actually occurs in that context.
4. Re-entering annotation mode in the same context appends to the same mutable context frame.

**Lifecycle (dual-channel semantics):**
1. On first stroke in a context with no open frame, provider creates/open a mutable context frame.
2. While annotating in that context, incoming `event.drawing_flush` strokes are appended to that open frame and exposed through the live dirty channel.
3. Exiting annotation mode (`Done` / toggle off) does **not** force frame finalization; it only pauses live writes. Re-entry in the same context resumes appending to the same frame.
4. When annotation begins in a different context, provider finalizes the previous context frame and enqueues it to Channel B (closed queue), then opens/resumes the new context's frame.
5. Provider also finalizes the current open frame on explicit content replacement/clear (`content.set` / `content.clear`) before applying the content mutation.

Note: This section governs **frame finalization** only. Transport flush/send cadence for `event.drawing_flush` remains governed by Section 7.1 flush-gate timing (`idleWindowMs` / `maxIntervalMs`).

This preserves context-coherent payloads while still allowing CLU to react during active annotation.

**Frame structure (shared by live and closed channels):**

```
{
  frameId:       string      Stable frame identity (fr_<hex>)
  contextKey:    string      Stable context identity for this frame
  contentId:     string      contentId active when frame was first opened
  url?:          string      URL for HTML contexts
  scrollOffset:  { x, y }    Viewport scroll offset at frame open
  viewport:      { width, height, scale }
  openedAt:      EpochMs     First annotation timestamp for this context frame
  updatedAt:     EpochMs     Last stroke appended timestamp
  image:         string      Base64 PNG of viewport captured at frame open
  strokes: [
    {
      strokeId:   string      Stable stroke identity (stroke_<hex>)
      points:     [{ x, y, pressure? }]
      bbox:       { x, y, width, height }
      startedAt:  EpochMs
      endedAt:    EpochMs
    }
  ]
}
```

**Coordinate space:** image and strokes are both viewport-at-open coordinates. No translation is required for in-frame geometry alignment. `scrollOffset` remains available for content-space mapping.

---

#### Channel A: Live Dirty Channel (Mutable)

The live channel exposes the currently open context frame with incremental dirty state:

- `liveFrame` — current mutable frame (or `null` if none)
- `liveDirtyStrokeIds[]` — stroke IDs appended since last `surf_ace_read`
- `liveSeq` — monotonically increasing sequence for live updates on that frame

**Live read semantics:** CLU can repeatedly call `surf_ace_read` during annotation and receive the newest deltas for near-real-time reaction.

---

#### Channel B: Closed Frame Queue (Immutable)

Closed frames are appended to FIFO `frames[]` and remain deliverable until consumed by `surf_ace_read`.

**Batch limits per read:**
1. Max **5** closed frames per read.
2. Pixel budget cap: approximately **4 MB** total encoded image payload across returned closed frames.
3. If next frame would exceed cap, leave it queued and return `pendingFrames`.

Closed frames are consumed-on-read (dequeued immediately after inclusion in response).

---

#### Anti-Dup Semantics Across Channels

The same stroke may appear in both channels:
- first via live dirty updates (Channel A)
- later inside its finalized closed frame (Channel B)

This is intentional. Closed frames are guaranteed context-preserved records and MUST remain deliverable even if CLU already saw live deltas.

**Dedup guidance:** CLU should dedupe by `strokeId` per `frameId` (or per `contextKey` where appropriate). Provider MUST keep stable `strokeId` across live and closed representations.

---

#### Non-Annotation Registers

The following registers handle non-annotation surface events.

**Latest-wins** — Only the most recent value is stored. Overwrites previous on each new event. Cleared on `surf_ace_read`.

**Append** — Values accumulate in arrival order since last read. Cleared on `surf_ace_read`.

| Register | Rule | Type | Description |
|---|---|---|---|
| `scrollPosition` | Latest-wins | object | Latest settled scroll offset and visible rect `{ x, y, visibleRect }`. Cleared on `surf_ace_read`. |
| `selection` | Latest-wins | object? | Current text selection; `null` if none. In v1, surfaces only emit `kind: "text"` selection events. If the provider receives a `kind: "point"` or `kind: "region"` selection from the wire, it MUST discard it and leave this register unchanged. Cleared on `surf_ace_read`. |
| `page` | Latest-wins | object? | Current page state `{ pageNumber, pageCount, pageLabel }`; `null` if not a paged content type. Cleared on `surf_ace_read`. |
| `taps` | Append | array | Ordered list of point-out tap events since last read. UI-navigation taps (link follows, button activations) are NOT included here — they produce `event.navigation` instead. |
| `playbackPosition` | Latest-wins | number? | **Video only.** Current playback position in seconds. `null` for all other content types. Populated by a v2 wire event. In v1, always `null`. |
| `playbackState` | Latest-wins | string? | **Video only.** One of `"playing"`, `"paused"`, `"ended"`. `null` for all other content types. In v1, always `null`. |
| `lastNavigation` | Latest-wins | object? | **HTML only.** Most recent navigation away from CLU-pushed content. `{ url: string, navigatedAt: EpochMs }` or `null`. Populated by `event.navigation`. `navigatedAt` maps from wire `NavigationEvent.sentAt`. Cleared on `surf_ace_read`. |

#### Overflow

The `taps` append register is capped at 512 entries. On overflow, oldest entries are dropped and `overflowed = true` is set on the next `surf_ace_read` response.

### 13.3 Alert Gate (Dual-Channel Activity Gate)

**Alert trigger:** fire an alert when unread annotation activity first appears, from either channel:
- first live-dirty update since last read, or
- first newly queued closed frame since last read.

**Alert text:** `"Surf Ace updates pending on [screen name]"` (optionally include counts: live dirty present + queue depth).

**Alert gate rules:**
1. If `alertFired=false` and new unread annotation activity appears, fire one alert and set `alertFired=true`.
2. While `alertFired=true`, suppress additional alerts for subsequent dirty deltas/frame closures.
3. On `surf_ace_read`, reset `alertFired=false`.

This gives one alert per unread activity burst while still allowing live reads during annotation.

**Alert timeout:** If `alertFired=true` and no `surf_ace_read` arrives within 10 minutes, reset `alertFired=false` so future activity can re-trigger.

**Non-annotation events:** register-only updates do not independently trigger alerts in v1.

### 13.4 CLU Reads the Buffer

CLU uses one read tool:

**`surf_ace_read(fingerprint)`** — reads live annotation state first, then closed frames (bounded), plus registers.

Read order and behavior:
1. Return **live channel first** (`liveFrame` + `liveDirtyStrokeIds` + `liveSeq`) if present.
2. Return closed frames from FIFO queue (up to 5 and within ~4 MB image budget).
3. Include `pendingFrames` when queue remains.
4. Clear consumed register values (`taps[]` to `[]`; latest-wins to `null`).
5. Mark current live dirty set as read (`liveDirtyStrokeIds` reset).
6. Dequeue returned closed frames.
7. Reset `alertFired=false`.

CLU should prioritize interpreting `liveFrame` first when present, then process closed frames for guaranteed context-preserved completion.

**Model processing order policy (dirty vs backlog):**
1. **Live preempts backlog.** If `liveFrame` + `liveDirtyStrokeIds` is present, model should process that first for real-time responsiveness.
2. **Backlog drains when live is quiescent.** Process `frames[]` oldest-first only when no `liveSeq` increment has occurred for at least 1000 ms (recommended default).
3. **If new live arrives while draining backlog, pause backlog and return to live processing.**
4. **Closed frames are still processed even if some strokes were seen live.** Their image/context payload is authoritative for completion and auditability.
5. **Dedup by stroke identity.** A stroke may appear in both channels; dedupe by `strokeId` scoped to `frameId`/`contextKey`.

This preserves both goals: real-time reaction during active annotation and guaranteed catch-up for older context.

**Tool surface continuity:** `surf_ace_read_buffer` remains deprecated/removed. No new mandatory read tool is introduced for v1 dual-channel; the existing `surf_ace_read` response shape is extended.

### 13.5 Alert Content

The alert sent to the watcher session MUST be lightweight:
- It names the screen and indicates pending update state (live dirty and/or closed frame queue depth).
- It does NOT include frame payloads or stroke data in the alert body.
- CLU retrieves payloads via the `surf_ace_read` tool call.

### 13.6 What the Provider MUST NOT Do

- **No live snapshot calls during inbound message handling.** Context injection that requires network round-trips to surfaces is forbidden in the Clawline admission/dispatch path.
- **No automatic context enrichment.** Provider must not attempt to append surface state to CLU messages pre-run. If CLU wants current state, it calls `surf_ace_read`, which reads from local cache only.
- **No multiple alerts per unread activity burst.** Once `alertFired = true`, the provider suppresses further alerts until CLU reads (which re-arms the gate) OR the 10-minute alert timeout expires.

### 13.7 Relationship to Inbound Context Enrichment

If surface context (e.g. cached screen description) is ever added to CLU's context, it must use a fail-open enricher interface:
- Reads from a local cache only — never issues live network calls.
- Has a bounded synchronous timeout (< 5ms cache read).
- Returns empty/stale context on any failure — never blocks or throws.
- Cache is populated by background refresh triggered by WS events (pair, content.set, snapshot_hint), not by inbound message handling.

This enricher, if implemented, must be incapable of affecting message delivery correctness.

## 14. Provider Connection Daemon and CLU Tool Surface

### 14.1 Connection Daemon Model

The provider maintains persistent WS connections to all discovered screens automatically. CLU never initiates, manages, or tears down connections.

Rules:
1. When a screen is discovered via mDNS, the provider immediately begins connecting and runs the WS pair handshake.
2. The provider owns an ongoing connection job for each discovered screen. The job runs continuously: if the socket drops, the provider reconnects per the backoff policy in Section 4.4.
3. If a screen disappears from mDNS, the provider stops the connection job for it.
4. If a screen reappears, the provider resumes immediately.
5. The WS pair handshake (Section 6.1) is an internal protocol detail executed by the connection job. It is not exposed as a CLU action.
6. CLU never calls a "connect" or "pair" tool. By the time CLU acts on a screen, the provider is already connected — or actively attempting to be.

Connection states visible to CLU (via `surf_ace_list`):
- `connected` — WS socket established and pair handshake complete; ready for operations.
- `connecting` — provider is actively attempting to connect or reconnect.
- `unreachable` — screen was discovered but repeated connection attempts have failed (backoff limit reached or mDNS record stale).

### 14.2 Read/Write Model

CLU's tool surface has a strict read/write split:

**Writes** go to the surface over the WS connection: pushing content, clearing content, removing annotations. These are explicit CLU intent.

**Reads** are always local. CLU reads from the provider's local buffers only. CLU never triggers a live network call to a surface for any read operation. The provider is responsible for keeping local state current — via snapshot fetches on reconnect, snapshot_hint handling, annotation sync — all opaque to CLU.

### 14.3 CLU Tool Surface

CLU interacts with surfaces through the tools defined in this section. All screen-scoped tools accept `fingerprint` (the window-surface stable identity, mapped from `surfaceId`) as the primary screen selector.

Pane note: pane selector is currently omitted from v1 tool signatures in this document; Phase 1 completion requires adding optional `paneId` (default `root`) to all screen-scoped tools.

---

#### `surf_ace_list`

Returns all known screens and their locally cached state. Read-only, local.

**Params:** none

**Returns:** array of screen records:
```
fingerprint       string    Stable screen identity (window-scoped; mapped from `surfaceId`)
name              string    Human-readable screen name
connectionState   enum      "connected" | "connecting" | "unreachable"
lastSeenAt        epochMs   When screen was last seen in mDNS or active
viewport          object    { width, height, scale }
activeContent     object?   { contentId, contentType, revision } or null if idle
pendingEvents     int       Count of buffered events not yet read by CLU
```

**Errors:** none (always returns current known local state, possibly empty array)

---

#### `surf_ace_push`

Push content to a screen, replacing whatever is currently displayed. Write.

**Params:**
```
fingerprint    string   Target screen
contentType    enum     "html" | "image" | "pdf" | "terminal" | "markdown" | "video" | "canvas"
content        string   Content payload. Encoding by type:
                          html/terminal/markdown: UTF-8 text
                          image/pdf: base64
                          video: URL string pointing to video source
                          canvas: optional JSON background spec { color?, grid? }, or empty string for plain white
```

**Returns:**
```
fingerprint    string
contentId      string   Stable content ID assigned by provider (ct_<8hex>)
revision       int      Revision after push
tabId          string   The tab that was created or updated for this session in the target pane.
                        Derived from sessionId. CLU does not need to pass tabId on subsequent pushes
                        — surface continues routing by sessionId automatically.
```

**Errors:** `not_connected`, `screen_not_found`, `content_too_large`, `unsupported_content_type`, `render_failed`

---

#### `surf_ace_clear`

Clear the current content and return the screen to connected-idle. Write.

**Params:**
```
fingerprint    string   Target screen
```

**Returns:**
```
fingerprint    string
revision       int      Revision after clear
```

**Errors:** `not_connected`, `screen_not_found`

---

#### `surf_ace_read`

Read dual-channel annotation state plus register values from the local buffer for a screen. Read-only, local — no network call to the surface. **Tab-scoped:** `surf_ace_read` reads the calling session's tab. The provider derives `tabId` from the calling CLU session's identity — CLU does not pass `tabId` in the tool call. No `tabId` parameter is needed or accepted. This ensures each CLU session reads only its own annotation state, with no cross-session bleed. If the session has no tab in the specified pane (it has never pushed to that pane), `surf_ace_read` returns empty channels for that pane.

Response includes:
1. **Live dirty channel first** (if a frame is currently open/active),
2. **Closed frame queue batch** (up to 5 and within ~4 MB image budget),
3. **Structured non-annotation registers** (consumed on read).

Closed frames are dequeued on read. Register values are cleared. Live dirty markers are advanced. Alert gate is reset.

**Params:**
```
fingerprint    string   Target screen
```

**Returns:**
```
fingerprint       string

// Channel A: live dirty (newest / active context)
liveFrame         object?  Current mutable context frame, or null if no active frame.
                           {
                             frameId        string
                             contextKey     string
                             contentId      string
                             url?           string
                             scrollOffset   { x, y }
                             viewport       { width, height, scale }
                             openedAt       epochMs
                             updatedAt      epochMs
                             image          string      Base64 PNG captured at frame open
                             strokes: [{
                               strokeId     string
                               points       [{ x, y, pressure? }]
                               bbox         { x, y, width, height }
                               startedAt    epochMs
                               endedAt      epochMs
                             }]
                           }
liveDirtyStrokeIds array?  Stroke IDs appended since previous surf_ace_read (for incremental reaction).
liveSeq           int?     Monotonic live update sequence for this frame.

// Channel B: closed frame queue (FIFO; oldest-first)
frames            array    Finalized closed frames, up to 5 and within ~4 MB combined image budget.
                           Each frame has the same shape as liveFrame.
pendingFrames     int?     Remaining closed frames still queued beyond this batch.

// Consumed registers (cleared after this read)
taps              array    Ordered point-out tap events since last read.
                           Each: { eventId, timestamp, x, y, kind, nearestText?, elementRole? }
                           kind: "tap" | "long_press" (from wire TapEvent.kind).
                           CLU-layer mapping: wire `nearestContent` → `nearestText`; `elementRole` =
                           provider-computed ARIA role of tapped element; `timestamp` from wire sentAt.
scrollPosition    object?  Latest settled scroll state: { x, y, visibleRect }. null if no scroll event since last read.
selection         object?  Latest selection: { selectedText, bounds, anchorStart?, anchorEnd? }. null if none.
                           CLU-layer mapping: wire `text` → `selectedText`; wire `boundingRect` → `bounds`;
                           `kind` is implicit as text in this CLU-layer shape. v1 providers preserve wire
                           `kind:"text"` selections and discard `kind:"point"`/`kind:"region"` unless explicitly
                           feature-negotiated (see §7.1 and §13.2). `anchorStart`/`anchorEnd` are provider-computed
                           DOM offsets when available (commonly HTML); otherwise null.
page              object?  Latest page state: { pageNumber, pageCount, pageLabel? }. null if not applicable.
playbackPosition  number?  Video only. null for all other content types.
playbackState     string?  Video only: "playing" | "paused" | "ended". null for all other content types.
lastNavigation    object?  HTML only: { url, navigatedAt } of most recent navigation, or null. Consumed on read.

// Buffer health
overflowed        bool     True if taps register dropped entries due to 512-entry cap.
readAt            epochMs
```

**Read priority + dedupe contract:**
- CLU should interpret `liveFrame` first when present (newest/live).
- CLU should process `frames[]` oldest-first for guaranteed context-preserved delivery.
- If new live dirty data appears while processing backlog, CLU should pause backlog and return to live.
- Closed frames should still be processed even when some strokes were already seen live (frame image/context is authoritative).
- A stroke may appear in both channels; dedupe by `strokeId` per `frameId`/`contextKey`.

**Errors:** `screen_not_found`

`surf_ace_read` may be called regardless of connection state.

**Migration notes (frame-queue-only → dual-channel):**
- Existing callers that only read `frames[]` continue to work unchanged.
- New callers should also inspect `liveFrame`/`liveDirtyStrokeIds` for near-real-time response while annotation is active.
- Dedup is required when consuming both channels: use `strokeId`.
- No new mandatory tool was introduced; `surf_ace_read_buffer` remains deprecated.

---

#### `surf_ace_read_buffer` (Deprecated)

This tool is deprecated and removed in the capture frame model. Frame images are now included directly in each capture frame returned by `surf_ace_read`. Do not use this tool in new code. It is documented here only for historical reference.

---

#### `surf_ace_annotations_remove`

Remove specific annotation strokes from a screen's drawing overlay by stroke ID. Write.

**Note (dual-channel frame model):** In the dual-channel model, strokes disappear from the surface display when annotation mode exits, but the underlying context frame may remain open and continue on later same-context re-entry (§13.2). Closed frames in the queue are immutable records and cannot be modified via this tool. `surf_ace_annotations_remove` only affects strokes currently rendered in the live annotation overlay (active session UI). For most CLU workflows, this tool is used to remove strokes from in-progress interaction (e.g., erasing a scratch-out gesture mid-session). Post-finalization frame handling is done at CLU interpretation time (dedupe/ignore/act), not by mutating closed frames.

**Params:**
```
fingerprint    string     Target screen
contentId      string     Must match the currently active content
strokeIds      string[]   Stroke IDs to remove
```

**Returns:**
```
fingerprint            string
removedStrokeIds       string[]
notFoundStrokeIds      string[]
remainingStrokeCount   int
```

**Errors:** `not_connected`, `screen_not_found`, `stale_content`

---

### 14.4 Alert Routing

When unread annotation activity first appears (live dirty update and/or closed frame queue growth), the provider fires one Clawline alert if none has fired for the current unread burst. Alerts route to `agent:main:main` by default. This is opaque to CLU — there is no tool to configure routing.

### 14.5 Tool Error Codes

| Code | Meaning |
|---|---|
| `screen_not_found` | Fingerprint is unknown to provider |
| `not_connected` | Screen is known but not currently connected (`connecting` or `unreachable`) |
| `content_too_large` | Content payload exceeds screen's size limit |
| `unsupported_content_type` | Screen does not support the requested content type |
| `render_failed` | Screen accepted the content but could not render it |
| `stale_content` | `contentId` param does not match currently active content |
| `internal_error` | Unhandled provider or surface error |

### 14.6 Extension Skills and Agent Instruction Injection (Required Paths)

Surf Ace implementation is not complete unless both extension skills and agent instruction injection are present at these provider paths.

**Required skill files:**
- `extensions/surf-ace/skills/surf-ace-ops/SKILL.md`
- `extensions/surf-ace/skills/surf-ace-markup/SKILL.md`

**Required instruction-injection files:**
- `extensions/surf-ace/src/agent-instructions.ts`
- `extensions/surf-ace/index.ts` (wires instruction injection into extension registration)

The injected Surf Ace instruction text MUST teach agents how to interpret surface-originated events, including at minimum:
- `event.drawing_flush`
- `event.navigation`
- `event.page`
- `event.selection` (v1 text-only handling)
- `event.pane_created` / `event.pane_removed` / `event.pane_focused` / `event.pane_renamed`
- `event.tab_created` / `event.tab_removed` / `event.tab_focused`

Standalone-provider note: Surf Ace MAY run as a standalone extension without Clawline coupling, provided it implements gateway wake/routing plumbing comparable to existing channel extensions (for example, Discord-style wake + route behavior) rather than relying on Clawline-specific internal helpers.

## 15. Surface UI Design

This section is **normative**. Surface implementations MUST conform to the requirements described here. This section does not specify pixel sizes, exact colors, fonts, or precise layout coordinates — those are implementation details left to each platform. It specifies what must be shown and the behavioral rules governing each UI element.

---

### 15.1 Persistent Indicators

Surface implementations MUST display the following identifiers at all times, regardless of content type, connection state, or annotation mode.

#### Window label

Each window is assigned a short alphabetic identifier using an auto-incrementing sequence: `A`, `B`, `C` … `Z`, `AA`, `AB`, … This label MUST be:
- Displayed prominently in a fixed corner of the window.
- Persistent — never hidden, obscured, or removed based on content or connection state.
- Rendered so it does not scroll with content (always in the chrome layer, not the content layer).

The window label is the primary addressing handle. It MUST be visible at all times so that a user can tell CLU "move content to window B" without ambiguity.

#### Pane label

Each pane within a window is assigned a numeric identifier starting at `0` (`0`, `1`, `2`, …). A user may assign a custom name to a pane (e.g., `fred`, `Janice`); when a custom name exists it MUST be displayed instead of the number. The pane label MUST be:
- Displayed within the pane boundary, in a position that does not overlap with active content.
- Always visible regardless of what content is rendered in the pane.

#### Tab indicator

When a pane contains multiple tabs, a tab bar MUST be shown at the top of the pane. Requirements:
- The currently active tab MUST be visually distinguished from inactive tabs.
- Each tab MUST display a short label. The label is derived from the `sessionId` of the owning CLU session. Surfaces MAY display a truncated or formatted version of the sessionId. If the provider includes a `providerName` field in `pair.request` (§6.1), the surface SHOULD prefer that as the human-readable label. If no `providerName` is available and the `sessionId` is long or opaque, a sequential tab number (1, 2, 3…) is also acceptable as a fallback label.
- The tab bar is only shown when two or more tabs are present in a pane. A single-tab pane does not show a tab bar.

---

### 15.2 Connectivity Indicator

See also §4.5, which defines the keepalive timing parameters. This section defines the required UI behavior.

The surface MUST maintain a persistent visual indicator that reflects the WebSocket connection state. Three states are defined:

| State | Trigger | Required visual |
|---|---|---|
| **Healthy** | A ping was received within the expected window (≤13s since last ping) | No indicator, or a neutral/absent state |
| **Stale** | No ping received within `heartbeatIntervalMs + heartbeatGraceMs` (default: 13s) | Visible non-error indicator (yellow or equivalent) in a non-obtrusive corner position |
| **Disconnected** | WS socket is not connected | Visible error indicator (red or equivalent) in the same corner position |

**Content persistence rule:** Content MUST NEVER be cleared, removed, dimmed, or otherwise altered based on connection state. The connectivity indicator changes; the content does not. This invariant holds across all three states.

**Placement:** The indicator MUST be placed in a corner of the surface where it does not overlap the content area. It must be present without requiring user interaction to reveal, but it must not dominate the display.

The surface transitions back to **healthy** immediately upon receiving a ping on a live connection.

---

### 15.3 Active Session Indicator

The surface MUST display the name of the CLU session (chat) that owns the currently active tab. The session name is the `providerName` field supplied in the `pair.request` message (§6.1). If no `providerName` was provided, the surface MAY display the `providerId` or a generic label.

Requirements:
- The label MUST be displayed as a small, unobtrusive element near the tab bar or connectivity indicator.
- When the active pane has no tabs (i.e., no session owns it), the label is absent or shows a neutral/empty state.
- When the active tab changes (including tab switch events per §6.1.1), the label MUST update immediately to reflect the owning session of the newly focused tab.
- The indicator is informational only; it is never interactive.

---

### 15.4 Annotation Mode UI

See also §6.10, which defines the behavioral constraints (scroll lock, link-follow disable, stroke capture) that annotation mode enforces. This section defines the required visual treatment for entering and exiting annotation mode.

#### iPad (pencil platforms)

- **Automatic entry:** Pencil contact with the screen MUST automatically enter annotation mode. No button tap is required to initiate pencil drawing.
- **Finger sketching button:** A "finger sketching" button MUST be persistently visible at all times — including when annotation mode is inactive. Tapping it enables finger input as a drawing tool, either alongside an active pencil or as the sole drawing instrument (entering annotation mode if not already active).
- **Done button:** While annotation mode is active, a "Done" button MUST be visible. Tapping it exits annotation mode. No other gesture is required to exit.

#### Electron (non-pencil platforms)

- **Annotate button:** An "Annotate" button MUST be persistently visible at all times. Tapping it toggles annotation mode on and off. There is no separate Done button on Electron — the Annotate button itself is the toggle.
- There is no automatic entry trigger on non-pencil platforms — the button is the only entry path.

#### Annotation mode visual state (all platforms)

When annotation mode is active, the surface MUST display a clear visual indication that distinguishes the annotating state from normal viewing. This MAY be a subtle overlay, a border change, or a persistent mode badge. The visual treatment must be sufficient for the user to immediately know they are in annotation mode without consulting any other indicator.

#### Behavioral constraints while in annotation mode (all platforms)

These constraints are normative (duplicated here from §6.10 for completeness):
- Scroll is disabled. The viewport is locked.
- Link following is disabled. Taps do not navigate.
- The drawing layer captures all touch and stylus input.

---

### 15.5 Drawing Flush In-Flight Indicator

See also §7.4, which defines the flush send timing requirements. This section cross-references that requirement for UI completeness.

A subtle visual indicator MUST be displayed while a `drawing_flush` event is being transmitted to the provider. Examples of acceptable treatments: a small pulsing dot, a corner status chip, or a brief overlay.

Required behavior (normative, cross-referenced from §7.4):
1. Indicator becomes visible when `event.drawing_flush` transmission starts.
2. Indicator remains visible while the transmission is in-flight.
3. Indicator hides immediately when transmission completes (success or terminal failure).
4. The indicator is shown only during active flush transmissions — not during idle or non-drawing states.

---

### 15.6 Content Area Behavior

#### General

Content MUST fill the pane. The surface renders content at native resolution. The content area is the full pane minus any chrome elements (pane label, tab bar).

#### While NOT in annotation mode

All of the following MUST be enabled, subject to what each content type supports:
- **Scroll**: user can scroll through content that extends beyond the viewport.
- **Link following**: taps on links navigate to the linked resource.
- **Text selection**: user can select and copy text where the content type supports it.

#### While IN annotation mode

All of the following MUST be enforced:
- **Scroll disabled**: the viewport is locked in place.
- **Link following disabled**: taps do not navigate.
- **Drawing layer active**: the drawing layer captures all touch and stylus input. Normal content interaction is suspended.

These constraints are synchronized with annotation mode state and are lifted immediately upon exiting annotation mode (iPad: Done button; Electron: Annotate toggle; all platforms: automatic exit on tab switch).

---

## Open Topics

This section is the authoritative list of unresolved design decisions. Items here MUST NOT be implemented against until explicitly resolved and removed from this list. When a topic is resolved, the decision moves into normative sections of the spec; it is not retained here.

### OT-1: Multi-Session Pane Contention Policy

**Problem:** When multiple CLU sessions (chats) push content to the same pane, the protocol needs a deterministic visibility policy. The current tab model ensures sessions do not overwrite each other's content, but does not specify which tab is initially visible or how supersede events work.

**Candidate policies:**
1. **Tab isolation** — each session has its own tab; the user controls which tab is visible; no session automatically becomes the foreground tab on push.
2. **Single-visible-owner + supersede** — newest write becomes visible immediately; the prior session receives a superseded signal so it can retarget or notify the user.
3. **Single-visible-owner + history** — no tabs; pane has Back/Forward navigation history so the user can restore prior visible states quickly.

**Requirements any policy must meet:**
- No permission prompts for normal session pushes.
- Superseded sessions must be explicitly notifiable when their content is no longer visible.
- The model must be able to make intelligent fallback decisions (retarget another pane/surface, notify user, or wait).

**Edge-case open questions (history policy candidate):**
1. **Push arrives during annotation mode:** defer until annotation exits (current preferred direction) vs immediate swap. If deferred, define max defer TTL and visible "pending update" indicator semantics.
2. **History stack limits:** max entries per pane, eviction policy, and whether entries store full rendered states vs references.
3. **Back then new push behavior:** whether Forward branch is truncated browser-style when new content is written after a Back navigation.
4. **Per-pane timeline scope:** history is per-pane; define UI expectations when different panes are at different timeline positions.
5. **Superseded-session behavior:** whether superseded sessions receive explicit machine events by default or infer supersession from visibility/occupancy state.

**Status:** Open. Requires explicit policy decision before implementation. See Appendix A.13 for additional rationale context.

### OT-2: Model-Side Markup (Provider-Originated Strokes)

**Problem:** CLU has no mechanism to draw on surfaces in v1. The model can only push content and read user strokes. There is no wire op for model-originated strokes, no capture exclusion mechanism to prevent them from entering annotation buffers, and no visual distinction protocol.

**Status:** Open. Not Phase 1 or Phase 2 scope. See Appendix A.12 for background.

### OT-3: Semantic Gesture Classification (On-Device)

**Problem:** Multi-stroke semantic gestures (brackets, lasso, circle-for-emphasis) cannot be reliably interpreted from raw geometry alone. On-device model integration (per finalized frame) is the most promising path but the wire contract (`semanticHints` field, confidence thresholds, fallback behavior) is not designed.

**Status:** Open. Design deferred to v2. See Appendix A.3, A.4 for background.

### OT-4: iOS Deployment Target Floor

**Decision:** Surf Ace targets the newest released OS major version as the minimum deployment target. Current floor: iOS/iPadOS 26 and macOS 26 for native surface builds.

**Status:** Resolved. Moved into Core Invariants (#13).

### OT-5: Distribution Method for Portable Surf Ace Extension

**Decision:**
- **Development:** `openclaw plugins install -l ~/src/surf-ace` (official link mode; `git pull` = immediately live after gateway restart)
- **Distribution:** `openclaw plugins install ./surf-ace.zip` (official OpenClaw zip install path; no custom packaging scripts required)
- **Separate repo:** Surf Ace lives in its own standalone repo (not bundled with Clawline). Fresh implementation — no porting from the clawline-rebase branch.

Both dev and distribution use the standard `openclaw plugins install` CLI. This satisfies all selection criteria: no Clawline dependency, no core patching, repeatable upgrades/rollback via zip replacement, skills and instruction injection verified at install time.

**Status:** Resolved. Moved into Core Invariants (#14).

---

## Appendix A. Design Rationale and Decision Notes

This appendix contains rationale context, background, and historical record for design decisions. **This appendix is not normative for unresolved items.** Open topics live in `## Open Topics` (the authoritative source); entries here are rationale and reference only. Resolved entries are historical record of decisions already encoded in normative sections above.

---

### A.1 Annotation Coordinate Space

**Question:** Do annotation strokes live in screen coordinates (where the pencil touched the glass) or content coordinates (position within the scrollable document)?

**Why it matters:** If screen coordinates, strokes made before and after scrolling are spatially disconnected and cannot be composed into a meaningful region. If content coordinates, strokes retain their document position across scroll and can be correctly bounded.

**Constraint:** This is a hard implementation decision on iOS — it determines how the PencilKit overlay is positioned relative to the scroll view.

**Decision: Viewport Coordinates**

Annotation stroke points and bounding boxes are stored in **viewport coordinates** — the coordinate space of the visible surface area at the time of capture. Coordinates are NOT content coordinates (they do not account for scroll position).

**Coordinate definition:**
- Origin `(0, 0)` is the top-left corner of the visible viewport at capture time.
- X increases to the right; Y increases downward.
- Units are logical surface points, matching `SurfaceViewport.width` × `height`. The scale factor (`SurfaceViewport.scale`) is NOT applied — coordinates are in points, not physical pixels.

**Coordinate space in the capture frame model:**

In the capture frame model (see §13.2), each closed frame contains a viewport screenshot and strokes in the same viewport-at-capture-time coordinate space. Because annotation mode locks the viewport (§6.10), there is no scroll movement between screenshot and strokes — they are spatially coherent by construction. The frame-level `scrollOffset` can be used to map strokes to content-space position when needed:

```
content_x = stroke_bbox.x + frame.scrollOffset.x
content_y = stroke_bbox.y + frame.scrollOffset.y
```

Note: `surf_ace_read_buffer` (the old composite buffer read tool) is deprecated and removed. Frame images are now included directly in each capture frame returned by `surf_ace_read`.

**Wire protocol — stroke coordinate space (unchanged):**

The wire `DrawingFlushEvent` continues to carry strokes in viewport coordinates. This is unchanged from the original v1 resolution. The surface-level implementation guidance below continues to apply:

**Implementation on iOS (PencilKit):**

Position the `PKCanvasView` as a **fixed overlay** over the scroll view's visible area — not inside the scroll view. PencilKit stroke coordinates are then naturally in viewport space and do not shift when the underlying content scrolls. The canvas does not scroll with the content.

**Implementation on Electron (canvas):**

Position the annotation canvas element as a fixed overlay (`position: fixed`, or `position: absolute` within a non-scrolling container) over the content frame. Canvas `(x, y)` coordinates are directly in viewport space.

**v2 upgrade path:**

In v2, the wire `DrawingFlushEvent` payload may optionally be extended with `scrollOffsetAtFirstStroke` / `scrollOffsetAtLastStroke` for surfaces that do not implement the annotation mode lock. In the capture frame model, this is unnecessary — the frame-level `scrollOffset` is authoritative.

**Capture frame model note:** The coordinate ambiguity question is fully resolved by the frame design. Each finalized frame contains both (a) a viewport screenshot taken at frame open and (b) all strokes accumulated into that frame — both in the same viewport-at-open coordinate space. Because the surface is scroll-locked during annotation mode (§6.10), viewport motion does not occur while drawing. Image and strokes are in the same coordinate space by construction, with zero translation required. `scrollOffset` at frame open can map to content space when needed. No per-stroke `scrollOffset` capture is required — frame-level `scrollOffset` is authoritative.

---

### A.2 Multi-Scroll Annotation Image Capture

**Question:** If a user annotates the top of a long webpage, scrolls down, and annotates the bottom — how does the provider produce a meaningful image for CLU?

**Decision:** Multi-scroll behavior is handled by the dual-channel context model. Because annotation mode locks the viewport (§6.10), scrolling cannot occur while actively drawing. If a user annotates at scroll position A, exits annotation mode, scrolls, and re-enters annotation in the **same context**, strokes append to the same context frame (not a new context frame). If annotation resumes only after a true context switch (e.g., different URL/content context and annotation starts there), the previous context frame is finalized and the new context gets its own frame.

CLU may therefore receive either one evolving context frame (same context, multiple annotation sessions) or multiple finalized frames (annotation across distinct contexts). `scrollOffset` at frame open remains the reference anchor for mapping to document-space.

---

### A.3 Semantic Gesture Interpretation (Brackets Problem)

**Question:** When a user draws `[` at one position and `]` far below it, their intent is "everything between these brackets." Raw stroke geometry alone cannot convey this — the provider would only see two curved strokes with a large gap. How does the system convey the user's region intent to CLU?

**Related:** Same problem applies to any multi-stroke semantic gesture where the intent spans content between the strokes rather than the strokes themselves.

**Status:** Partially addressed by the capture frame model — full resolution requires on-device gesture classification (A.4).

**With dual-channel context frames:** Bracket strokes and other multi-stroke semantic gestures can be accumulated into one finalized context frame (even across multiple same-context annotation sessions). CLU receives the frame stroke set plus viewport screenshot, reducing partial-geometry ambiguity.

However, geometry-based inference of the "between" region still requires understanding that the strokes form brackets and that the intent is spatial span between them. This is the unresolved part. On-device classification (A.4) applied per finalized frame remains the most promising path: the surface classifies gesture intent for the frame stroke set before (or at) finalization and includes a `semanticHints` field. Design deferred to v2.

---

### A.4 On-Device Model Integration (Apple Foundation Model)

**Question:** iOS devices with Apple Intelligence have an on-device foundation model available. Should the surface use it to classify stroke gestures (lasso, bracket, circle-for-emphasis, underline, cross-out, drawn box, etc.) before reporting to the provider?

**Why it matters:**
- CLU receives classified intent rather than raw geometry — dramatically reduces ambiguity
- On-device inference is fast and private
- Resolves A.3 (bracket problem) and the point-out classification ambiguity
- Raises question of confidence threshold: what does the surface report when classification is uncertain?

**Related questions:**
- Does the surface report raw strokes + classification, or classification only?
- What is the fallback when on-device model is unavailable or below confidence threshold?
- Does classification happen per-stroke, per-flush, or after a settling window?

**With context-keyed frames:** On-device classification applies naturally **per finalized frame**. At frame finalization time (context-switch boundary, or explicit `content.set`/`content.clear` per A.8), the surface has the complete stroke set for that finalized unit. This is the ideal classification boundary: the model sees full gesture context before delivery. Classification at flush time (mid-session live deltas) would see partial stroke sets and is not recommended. A v2 `semanticHints` field in the frame structure is the right integration point.

**Status:** Unresolved. Needs design session. The dual-channel frame model provides the right unit of analysis — classify at frame finalization, not at live-delta flush time.

---

### A.5 Point-Out vs. Passive Annotation

**Question:** Is "point-out" (user explicitly directing CLU's attention) a distinct surface behavior, or is it inferred by CLU from existing event types?

**Context:** Two modes of surface use were identified:
1. *Point-out* — user highlights, boxes, or selects something, meaning "look at this specifically"
2. *Passive* — user scribbles, writes, thinks on-screen; CLU observes without explicit direction

**Open sub-questions:**
- Does the surface classify which mode is active, or does CLU infer it?
- Are point-out gestures a distinct register, or do they arrive as ordinary stroke/selection events?
- For text selections (OS-level), the selected text is cleanly available — CLU may not need an image at all. For drawn boxes or lasso regions, an image crop is needed. Should these be unified under one "attention region" concept?

**Status:** Unresolved. Depends on A.4.

---

### A.6 Image Request Scope and Cropping

**Question:** When CLU requests an image of a region, how is the region specified, and what exactly is composited?

**Partially resolved:**
- Images always include the annotation overlay rendered on top of content (never content-only or strokes-only)
- CLU specifies a region of interest rather than always requesting full-screen
- Provider crops from locally cached render + live annotation layer

**Still open:**
- Is the region in screen coordinates or content coordinates? (Depends on A.1)
- How current must the locally cached render be? If the user has scrolled since the last cache update, the crop is wrong.
- Does the provider maintain a rendered image cache proactively, or only on demand?
- For "full screen" requests, is the image the current viewport or the full scrollable content?

**Status:** Partially resolved. Coordinate space is settled (viewport coordinates per A.1). In the capture frame model, each frame includes a viewport screenshot — CLU receives the image directly in `surf_ace_read` without needing a separate buffer crop. The region-of-interest question is moot for closed frames (each frame image is already the viewport at capture time). For live/open frame inspection, `snapshot.get` with `includeImage=true` remains available over the WS protocol.

---

### A.7 Surface Interaction Model: Modes vs. No Modes

**Question:** Does the surface have explicit interaction modes (e.g. "navigation mode" vs. "markup mode"), or is it always one unified thing?

**Design direction:** No explicit modes. The surface always behaves like a real browser. Full link following is supported — if CLU pushes a website, the user should be able to use it as a website including hyperlinks. Pencil always draws annotations. Finger always does finger things: scroll, select text, tap elements, follow links. Point-out is not a mode — it is the natural byproduct of ordinary finger interactions (text selection, element tap) that happen to produce structured register entries.

**Implications:**
- Link navigation must be detected and reported as a content state change (URL change → navigation event → snapshot_hint)
- Annotations should be buffered per URL (or per content hash for non-URL content) so that navigating away and back restores annotations to their previous state
- The provider tracks which annotations belong to which URL; when the user returns to a URL, the annotation register is restored from that buffer
- The model observes URL changes via the content state register and can react or ignore

**Open sub-questions:**
- Should the surface suppress link navigation when CLU-pushed content is active, with an opt-in flag to allow it? Or always allow it?
- How should annotation buffering handle URL fragments (#section) vs. full URL changes?
- What happens to annotations when CLU calls `surf_ace_push` with new content — are they cleared or preserved?

**Decision:** On pencil-supported devices, pencil contact automatically enters annotation mode; fingers do normal operations (scroll, select, tap, follow links) by default. A "finger sketching" button is always visible and, when tapped, adds finger drawing capability to annotation mode. On non-pencil platforms (Electron), an "Annotate" button is the sole entry point for annotation mode and enables finger drawing. In both cases the button can be tapped before any drawing occurs. This is the only surface-level mode distinction and it is UI-only; the wire protocol and register model do not change based on mode.

**Data model:** The provider MUST store surface state in a context dictionary keyed by `contextKey`, where `contextKey` is:
- For CLU-pushed content: the `contentId` (e.g. `ct_a1b2c3d4`)
- For user-navigated URLs (within an HTML push): the full URL string, normalized (fragment stripped, query preserved)
- For non-URL content (images, PDFs): the content hash or `contentId`

Each context record holds: `{ contentId?, url?, liveFrame?, liveDirtyStrokeIds?, closedFrameQueue, scrollPosition, selection, page, timestamps }`, where `timestamps` is `{ createdAt: EpochMs, lastActivityAt: EpochMs }` — `createdAt` is when the context record was first established (content pushed or first navigation), `lastActivityAt` is updated on every register write. Note: the old `annotations`/`drawBuffer` fields are replaced by dual annotation channels (`liveFrame` + `closedFrameQueue`).

In v1, `content.set`, `content.clear`, and `event.navigation` still enforce hard-clear behavior at the surface rendering layer, but provider buffer retention is split:
- interactive overlay state is cleared per protocol,
- unread closed frames and live-frame bookkeeping are retained until `surf_ace_read` consumes them.

Navigation to a new URL creates a new active context candidate, but context switch for frame finalization occurs only when annotation starts in that new context. Navigation alone does not create/finalize a frame.

In v2+, restore-on-revisit will require a new wire operation (e.g. `content.restore`) or a `preserveAnnotations` flag on `content.set`. This is a **protocol change**, not a provider-side policy switch — Section 6.2 mandates that `content.set` MUST clear all drawing overlay strokes at the surface level, and the provider cannot suppress this behavior unilaterally. The context dictionary is the right data structure for v2; the wire op to activate it is a v2 design item.

**Implementation note:** Surface implementations should keep a context dictionary from day one. v1 already uses it for dual-channel buffering/finalization boundaries; v2 restore-on-revisit can layer on without storage rewrite.

**Status:** Resolved for v1. Restore policy deferred to v2 (A.7 phase). UI/UX/presentation details (button design, visual affordances, mode indicator) are a separate TODO — not specced here.

---

### A.8 Frame Lifecycle When Context Never Changes (No Forced Frame Finalization)

**Decision:** No forced frame finalization. In the dual-channel context-keyed model, an open frame may remain open indefinitely while context remains the same.

Rules:
1. Live channel remains authoritative for in-context work-in-progress (strokes + screenshot context while annotating).
2. Closed-frame queue exists to preserve older context when user moves on to a different context.
3. Same-context re-entry appends to the same open frame.
4. Frame finalization occurs only on context switch (different URL/content context with annotation starting there) or explicit content replacement/clear (`content.set`/`content.clear`).
5. No timeout-based or size-based forced finalization in v1.

Transport note: this does **not** change `event.drawing_flush` transport cadence (Section 7.1 flush gates still apply).

Rationale: Frames are preservation/backlog artifacts, not mandatory segmentation units. If CLU is already receiving live updates, forced frame finalization adds complexity without user value.

---

### A.9 Content Types — Coverage and Gaps

**Covered content types** and their fundamental character:
- `html` — scrollable, navigable, links, dynamic. The full browsing case. All open questions in A.1–A.7 center on this type.
- `pdf` — paginated, not URL-navigable. Annotations per page. Simpler than HTML.
- `image` — static. No scroll. Annotations stay put. Easiest case.
- `markdown` — rendered HTML, typically no links or interactivity. Simplified HTML.
- `terminal` — live text stream, content changes continuously. Annotations on moving targets are conceptually difficult. Lower priority.

**Added to spec (v1 reserved, v2 required):**

**Video** (`video`) — fundamentally temporal rather than spatial. Annotations carry an optional `videoTimestamp` field anchoring strokes to playback position. Two additional registers: `playbackPosition` and `playbackState`. The multi-scroll / bounding-box problems from A.2/A.3 have a temporal analog here — strokes made at different playback times may span content that is no longer visible. Full semantics deferred to v2. See Section 6.9.

**Blank canvas** (`canvas`) — annotations are the primary artifact; there is no underlying document. The surface renders a blank or gridded background. `content.clear` removes all annotations (same global rule as all content types). In v1, CLU observes user strokes via the existing register model (read-only for CLU). CLU-initiated annotation writes (e.g. CLU drawing on the canvas) are not defined in v1 — no wire op exists for this; deferred to v2. Useful for whiteboard-style collaboration. See Section 6.9.

**Everything else** (slides, word documents, maps) is a variant of HTML or PDF with cosmetic differences. No new model required.

**Status:** Both types added to the protocol (schema enum, content type characteristics in 6.9, video registers in 13.2). Implementations may return `unsupported_content_type` for these in v1. Full behavioral spec deferred to v2.

---

### A.10 Multi-Pane Surfaces (One Window, Multiple Independent Contexts)

Multi-pane support — splitting a single Surf Ace window into multiple panes, each with separate content and annotation context — is committed phase work. Implement before annotation-priority work (see §2.3 Delivery Phasing).

**Design direction:**
1. Keep multi-window model unchanged (`surfaceId` stays window identity).
2. Add pane identity inside a surface: `paneId`.
3. Scope all mutable state by `contextScope = { surfaceId, paneId }`.
4. Default single-pane v1 behavior maps to `paneId="root"`.
5. Pane-aware operations (split/resize/close/focus) are Phase 1 committed topology operations.
6. Read/write tools become pane-aware by optional selector:
   - Phase 1-compatible default: no pane specified → `root`
   - pane-aware targeting: explicit pane target for `push/read/clear/annotations_remove`.

**Why this is safe:** This adds pane orchestration without breaking current one-pane defaults. Existing clients continue to work unchanged against `root`; pane-aware clients can split into more panes without semantic breakage.

---

### A.11 Future Extension — Multi-Pane Enhancements Beyond Phase 1

**Goal (v2+ enhancements):** Extend one-window multi-pane behavior with richer pane layout orchestration and lifecycle semantics beyond the Phase 1 committed baseline.

**Compatibility principle:** Model mutable state as `contextScope = { surfaceId, paneId? }` where `paneId` defaults to `root` in v1/Phase 1. This preserves current single-pane behavior and allows advanced pane-aware ops without breaking existing semantics.

**Expected v2+ shape:**
1. Advanced pane lifecycle/layout operations (nested split templates, persistent layout presets, pane groups).
2. Full read/write scoping by `{ surfaceId, paneId }` across all tools and schema operations.
3. Independent live dirty channel + closed-frame queue + register state per pane, with optional cross-pane coordination events.
4. Ordering/dedupe contracts remain unchanged per pane.

**Status:** Base multi-pane topology is Phase 1 committed work (§2.3). This subsection covers additional v2+ enhancements beyond Phase 1.


### A.12 Model-Side Markup and Point-Outs (Open Topic)

**Problem:** The current spec defines annotations as user-generated (stylus/finger strokes). The model currently has no way to draw on the surface — it can only push content and read user strokes. But the model may need to point things out, circle items, draw attention to regions, or add its own visual commentary on displayed content.

**Proposed behavior:**
1. The model can send its own point-outs and markup strokes to a surface via a dedicated tool (e.g. `surf_ace_annotate` or extended `surf_ace_push`).
2. Model markups are tracked separately from user annotations at the provider layer.
3. Model has full CRUD over its own markups: create, read, update, delete.
4. Model markups are intended to be excluded from capture frames / screenshot buffers (they are provider-originated, not user-originated, and must not pollute the surface-observation loop). Mechanism TBD — the v1 `Stroke` schema has no `source` field; wire protocol extension required before this invariant can be enforced.
5. Model markups render visually on the surface alongside (but distinguishable from) user strokes.

**Future extension (not v1):**
Model markups may become full interactive UIs embedded in the surface — widgets, buttons, state displays — that can send user actions and state back to the model. This would make model markup a bidirectional communication channel, not just visual output.

**Open questions:**
- Wire protocol: how are model markups delivered to the surface? As a new op type (`markup.set`) or as a variant of `content.set` in an overlay pane?
- Visual distinction: how does the surface render model strokes vs user strokes? Different color, opacity, or layer?
- Scope: are model markups pane-scoped or surface-scoped?
- Capture exclusion: how does the frame capture mechanism know to exclude model-originated strokes?
- Interactive markup v2: what protocol extensions are needed for widget → model callbacks?

**Status:** Open. Needs design discussion before any implementation. Not part of Phase 1 or Phase 2 scope as currently defined.

### A.13 Multi-Session CLU Contention — Rationale Context

> **This topic is tracked in `## Open Topics → OT-1` (the authoritative source).** The candidate policies, requirements, and resolution status are documented there. This appendix entry is rationale context only.

**Background:** The WS single-connection rule governs provider-level connections. At the CLU tool layer, multiple CLU sessions route through the same provider. The tab model (§3.1.1, §6.1.1) was designed so that sessions never overwrite each other's content — but the policy governing tab visibility (which session's tab is foregrounded on push, and how superseded sessions are notified) has not been decided.

**Protocol support:** The wire protocol as specified (`tab.list`, `tab.close`, `event.tab_focused`, `content.set` routing by `sessionId`) can support any of the three candidate policies in OT-1 without wire-level changes. The policy choice is a provider-side behavior decision.

**Related sections:** §3.1.1 (topology), §6.1.1 (pane/tab lifecycle ops), §6.2 (content routing), §13.2 (annotation buffering), §14.3 (`surf_ace_list` occupancy).

---

## Appendix: Preserved Notes

### From: retros/surf-ace-a1-resolution.md

**Annotation coordinate space decision: viewport coordinates.**
Strokes are captured, stored, and composited in viewport coordinates. CLU uses the per-annotation `scrollOffset` field to reconstruct content position when needed.

Rationale:
- `drawBuffer` is a pixel image matching the viewport — viewport-space strokes composite at raw captured positions with zero transform.
- iOS: place `PKCanvasView` as fixed overlay over scroll view's visible area (not inside it) to get viewport coordinates naturally. Placing inside the scroll view for content coordinates requires unbounded canvas and coordinate remapping.
- Electron: `position: fixed` canvas over content frame gives viewport coordinates natively.

---

### From: retros/surf-ace-extension-recon.md

**Surf Ace extraction feasibility — feasible with 3 meaningful engineering tasks:**

Coupling points ranked:
- 🟢 Easy: Tool layer (`surf-ace-tools.ts`) — only imports from typebox, plugin-sdk, local runtime shim. Moves verbatim.
- 🟢 Easy: Runtime singleton shim (`surf-ace-runtime.ts`) — 35 lines. Moves verbatim.
- 🟡 Medium: `SurfAceManager` class (`src/clawline/surf-ace.ts`) — imports `runCommandWithTimeout` from core (available via `api.runtime.system.runCommandWithTimeout`). Move to extension + swap two core imports.
- 🔴 Hard: Alert routing — `postActivityAlert` POSTs to Clawline HTTP server port 18800. `wakeGatewayForAlert`/`enqueueAnnounce`/`callGateway` are NOT exposed in plugin SDK. Options: (1) inject alert callback at service start (inter-extension dep); (2) use `enqueueSystemEvent` only (degraded, no proactive wake); (3) expose `api.runtime.system.postAlert` in SDK (right long-term fix); (4) expose Clawline alert URL via config (cheapest "works today" path).

---

### From: specs/surf-ace-canvas-foundation-analysis.md / loupe-canvas-foundation-analysis.md

**Decision: Do NOT use OpenClaw Canvas as kernel for Surf Ace.**

Canvas is command-oriented (`present/hide/navigate/eval/snapshot`, A2UI v0.8), foreground-gated on mobile nodes, and optimized for single-node visual control — not multi-surface state orchestration.

Surf Ace needs first-class concepts Canvas doesn't provide:
- Surface registration/discovery model
- Frame lifecycle as domain objects
- Surface context table + contextual injection into CLU processing
- Reliable multi-surface orchestration semantics independent of node UI implementation

**Use Canvas as rendering adapter/prototyping surface only.** Build dedicated Surface Control Plane in Gateway/Provider for production Surf Ace.

---

### From: retros/surf-ace-inbound-seam-critique-2026-03-02.md

**Surf Ace inbound seam architectural constraint:**
Do NOT call `surfAceManager.buildContextInjection()` (or any live network call) inside the core Clawline inbound message handling path before `agent_run_start`. This creates:
- Live network dependency in the critical inbound path
- Messages that are persisted+acked (`ackSent=1, streaming=1`) but never advanced to completion
- Queue head poisoning: one stuck item blocks all subsequent inbound on that per-stream queue

**Required seam:** Use a formal "inbound context enricher" extension interface with:
- Bounded timeout (context enrichment must not stall dispatch indefinitely)
- Async/non-blocking execution
- Graceful degradation if enrichment fails/times out
