# Surf Ace Wire Protocol (WebSocket)

Status: Design draft
Last updated: 2026-03-02
Supersedes: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md` (2026-02-26 REST/callback/watch design)
Depends on: `/Users/mike/shared-workspace/clawline/specs/clawline-invariants.md`

## 1. Flynn-Directed Protocol Change

This spec replaces the prior architecture (REST push + callback URL + watch mode) with a single persistent WebSocket connection per surface.

Required decisions implemented in this spec:
1. Provider initiates the connection (provider is WS client).
2. Surface runs a lightweight WS server (HTTP only for upgrade/minimal health).
3. One active provider connection per surface, with automatic reconnect.
4. All operations run over that socket: pair handshake, content push, clear, events, snapshots.
5. No callback URL.
6. No explicit watch mode. Event streaming is always on while connected.

## 2. Scope and Non-Goals

### 2.1 In Scope
1. Discovery metadata needed to open the WS connection.
2. WS handshake, pairing, session ownership, reconnect.
3. Wire message contracts for content operations, snapshot operations, and user interaction events.
4. JSON Schema definitions for all message types.

### 2.2 Non-Goals
1. UI design details for surface rendering.
2. CLU prompt orchestration details.
3. Multi-surface layout protocol (still one content item per surface at a time).
4. Cloud relay transport.

## 2a. Concepts

Before the protocol details, these terms are used consistently throughout this spec:

**Surface** — a physical screen running the Surf Ace app (iOS, Electron). It is the WS server. It displays content and captures user interaction.

**Provider** — the Clawline server-side component that manages connections to surfaces. It is the WS client and reconnect owner. It maintains local state for each surface.

**Content** — the single item currently displayed on a surface. Content has a type (`html`, `image`, `pdf`, `terminal`, `markdown`, `video`, `canvas`) and a stable identity (`contentId`). A surface displays at most one piece of content at a time. CLU pushes content to a surface and can clear it. Content is distinct from annotations. `video` and `canvas` are defined in the protocol for forward compatibility; full implementation is deferred to v2.

**Annotations** — drawing strokes the user has made on top of the current content using the stylus or finger. Annotations are layered over content and persist until the provider explicitly removes them. Annotations are not content and are not cleared when content changes unless the spec says so.

**Event** — a user interaction reported by the surface to the provider over the WS socket (drawing flush, tap, selection, page turn, scroll, snapshot hint). Events are buffered locally by the provider.

**Local buffer** — the provider's in-memory store of events and annotation state for each surface. CLU reads from this buffer only; it never triggers live network calls to a surface for reads.

**Connection job** — the provider's per-surface background process that maintains the WS connection, runs the pair handshake, handles reconnect, and syncs local state. Fully opaque to CLU.

## 3. Transport and Discovery

### 3.1 Discovery

Surfaces continue advertising `_surf-ace._tcp` over Bonjour/mDNS.

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
| `pk` | hex8 | `a1b2c3d4` | Surface public key fingerprint prefix |
| `ws` | path | `/ws` | WS upgrade path |
| `tls` | `0|1` | `0` | Reserved for future WSS profile; ignored by v1 |

Connection URL derivation:
1. Resolve host/port from SRV/A/AAAA.
2. Use path from TXT `ws` (default `/ws` if missing).
3. v1 scheme is always `ws` (WSS is out of scope in v1).

### 3.2 Surface HTTP Server

Surface HTTP server is minimal:
1. Required: WS upgrade endpoint (`GET /ws` or advertised path).
2. Optional: `GET /health` -> `200 OK` for diagnostics.
3. No REST data endpoints (`/pair`, `/frame`, `/watch`, `/snapshot`) in this protocol.

## 4. Connection and Session Lifecycle

### 4.1 Roles
1. Provider is WS client and reconnect owner.
2. Surface is WS server and session authority.

### 4.2 Single-Connection Rule
1. Exactly one paired provider connection is active per surface.
2. If another provider tries to pair while occupied, surface rejects pairing with `busy`.
3. Surface advertises `busy=1` while paired or in reconnect grace.
4. Same-provider takeover is explicit: if a new `pair.request` has the same `providerId` and `takeover=true`, surface accepts the new socket and closes the old one as `1000` reason `superseded`.

### 4.3 Pair-First Rule

All operations other than `pair.request` are invalid until pairing succeeds.

### 4.4 Reconnect Behavior

Provider reconnect policy:
1. Exponential backoff with jitter: 0.5s, 1s, 2s, 4s, 8s, 16s, max 30s.
2. Reconnect uses the same discovered surface address.
3. Provider sends `pair.request` again after each reconnect.
4. Provider sets `takeover=true` on reconnect attempts after any missed heartbeat window to evict stale half-open sockets owned by itself.
5. If provider receives `busy` but has a prior session for the same surface, provider SHOULD retry once with `takeover=true` before continuing backoff.

Surface reconnect grace:
1. On abnormal close, surface keeps session state for `resumeGraceMs` (default 20000).
2. During grace, only the same `providerId` may resume.
3. If grace expires without resume, surface clears displayed content, invalidates session, sets `busy=0`.
4. On normal close (`1000` reason `provider_shutdown`), surface clears immediately and sets `busy=0`.

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

### 6.1 Pair Handshake

Flow:
1. Provider opens WS.
2. Provider sends `pair.request`.
3. Surface replies `pair.response` (success or error).
4. If success, connection enters active mode and event streaming starts immediately.

`pair.request` fields include:
1. `providerId` (stable identity for resume).
2. `connectionId` (unique per socket attempt).
3. `resume` (optional prior `sessionId`).
4. `takeover` (optional bool, same-provider stale-connection eviction).
5. `eventProfile` (optional, default `minimum_deep`).
6. `drawingFlushConfig` (optional, provider-preferred idle/max interval values).
7. `protocolVersion` (`1` for this spec).

`pair.response` success includes:
1. `sessionId`.
2. `resumed` boolean.
3. Surface metadata (id/name/viewport/capabilities).
4. `eventConfig` (active event profile, active event list, and effective drawing flush config).
5. Limits.
6. Current content summary (`currentContentId`, `currentRevision`, `contentType` or `null`).

### 6.2 Content Set

`content.set` replaces active content payload.

Rules:
1. `contentId` generated by provider (`ct_<8hex>`).
2. `revision` must be next revision.
3. Content must be self-contained.
4. `content.set` MUST clear all drawing overlay strokes before rendering the new content.
5. Successful set returns rendered content summary.

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
3. Invalid selector/action returns `render_failed`.

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

#### `canvas` (v1 reserved, v2 required)
- `content.set` payload is optional: a background specification (`{ color, grid }`) or empty.
- There is no underlying document — annotations are the primary artifact, not an overlay.
- `visibleText` in snapshot is always empty.
- Navigation events do not fire (no URLs, no links).
- `content.clear` clears the background spec and ALL annotations (canvas is the only type where `content.clear` removes annotations; for all other types, annotations survive content changes unless explicitly removed).
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
2. `event.tap` - resolved tap/long-press interaction with nearest semantic content.
3. `event.selection` - semantically complete text/point/region selection.
4. `event.page` - full PDF page transition state.
5. `event.snapshot_hint` - control-plane event telling provider to fetch authoritative snapshot.

Drawing semantics in default mode:
1. Surface does no stroke classification, shape recognition, or gesture interpretation.
2. Surface accumulates raw strokes locally.
3. Surface emits `event.drawing_flush` only when the flush gate fires.
4. Each stroke has a stable unique `strokeId` (`stroke_<hex>`) assigned at capture time.
5. Flush payload is an ordered array of strokes; each stroke remains independently addressable by `strokeId`.
6. Surface keeps strokes rendered until explicitly removed by provider via `annotations.remove`.

Flush gate (single time-based model):
1. Let `dirty=true` when new strokes were added since last successful send.
2. Idle gate condition: user idle for `idleWindowMs` (no new strokes) and at least `idleWindowMs` elapsed since last successful send.
3. Max interval condition: `maxIntervalMs` elapsed since last successful send and `dirty=true`.
4. Send occurs when `dirty=true` and either idle gate or max interval condition is true.
5. Do not send when `dirty=false` (no changes since last send).
6. `lastSuccessfulSendAt` initializes to pair-success time for each connection.

Default flush timings:
1. `idleWindowMs` default 8000 (configurable, valid range 5000-10000).
2. `maxIntervalMs` default 30000.

Behavioral result:
1. Short natural pauses do not send.
2. Genuine stops send after idle settles.
3. Continuous drawing is force-flushed at most every 30s.

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
| `event.tap` | Deep semantic | Yes | Contains resolved interaction target context. |
| `event.selection` | Deep semantic | Yes | Represents explicit user focus with interpretable payload. |
| `event.page` | Deep semantic | Yes | Complete navigation state transition for paged content. |
| `event.snapshot_hint` | Control plane | Yes | Not semantic intent, but required to maintain authoritative state sync. |
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
9. Provider deduplicates events by `eventId` (retain last 1024 IDs per surface session).
10. If a flush send fails or disconnects mid-send, surface keeps unsent dirty strokes and retries on reconnect under normal flush-gate rules.

### 7.4 Flush Send Indicator (UI Requirement)

Surface must show a subtle visual send indicator while a drawing flush is in-flight to provider.

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
| `1000` | Normal close (`provider_shutdown`) |
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

### 9.4 WSS/TLS Scope
1. WSS/TLS certificate format and pinning profile is deferred to v2.
2. `tls` discovery TXT field is reserved and non-normative in v1.
3. Implementations MAY experiment with WSS privately, but v1 interoperability requirements are defined only for `ws`.

### 9.3 Session and Ownership
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
    { "$ref": "#/$defs/PairRequest" },
    { "$ref": "#/$defs/ContentSetRequest" },
    { "$ref": "#/$defs/ContentAppendRequest" },
    { "$ref": "#/$defs/ContentPatchRequest" },
    { "$ref": "#/$defs/ContentClearRequest" },
    { "$ref": "#/$defs/AnnotationsRemoveRequest" },
    { "$ref": "#/$defs/SnapshotGetRequest" },
    { "$ref": "#/$defs/HeartbeatPingRequest" },

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
    { "$ref": "#/$defs/SnapshotHintEvent" }
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
          "required": ["kind", "position"],
          "properties": {
            "kind": { "const": "point" },
            "position": { "$ref": "#/$defs/Position" }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
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
          "required": ["providerId", "connectionId", "protocolVersion"],
          "properties": {
            "providerId": { "$ref": "#/$defs/ProviderId" },
            "connectionId": { "$ref": "#/$defs/ConnectionId" },
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
                "content": { "type": "object" },
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
            "surfaceId": { "type": "string" },
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
                  "items": { "$ref": "#/$defs/EventType" },
                  "uniqueItems": true
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
                "maxDrawingFlushBytes"
              ],
              "properties": {
                "maxMessageBytes": { "type": "integer", "minimum": 1024 },
                "maxFrameBytes": { "type": "integer", "minimum": 1024 },
                "maxVisibleTextBytes": { "type": "integer", "minimum": 256 },
                "maxStrokePointsPerFlush": { "type": "integer", "minimum": 1 },
                "maxDrawingFlushBytes": { "type": "integer", "minimum": 1024 }
              }
            },
            "state": {
              "type": "object",
              "additionalProperties": false,
              "required": ["currentRevision"],
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
          "required": ["currentContentId", "currentRevision"],
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
            "pair.request",
            "content.set",
            "content.append",
            "content.patch",
            "content.clear",
            "annotations.remove",
            "snapshot.get",
            "heartbeat.ping"
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
    }
  }
}
```

## 11. Adversarial Hardening Results

This section records the adversarial review pass and the fixes locked into the protocol.

1. Race: duplicate sockets from reconnect overlap.
Resolution: pair handshake includes `providerId` + per-attempt `connectionId`; one paired session only; busy rejection for non-owner providers; explicit same-provider `takeover=true` closes stale socket and hands ownership to the new socket.

2. Out-of-order or retried content mutations.
Resolution: mandatory monotonic `revision`; strict `expectedRevision` gate; request-ID idempotency cache.

3. Event loss or event flood.
Resolution: event stream is best-effort across reconnect by design; provider must issue `snapshot.get` after reconnect; backpressure coalesces high-rate events and emits `event.snapshot_hint`; drawing flushes are dual-gated (idle + max interval) to bound send frequency.

4. Ghost occupancy after crash.
Resolution: abnormal close enters bounded resume grace only; if not resumed in 20s, surface clears and releases `busy`.

5. Payload abuse and parser risk.
Resolution: explicit max-byte limits in pair response; typed schemas; `content_too_large` and WS close `4413`; malformed envelope closes `4410`.

6. Stale content targeting (append/patch after replace).
Resolution: mutation ops require both current `contentId` and next `revision`; stale content returns `stale_content`.

7. Ambiguous state after reconnect.
Resolution: pair response always returns authoritative current state (`currentContentId`, `currentRevision`, `contentType`), and provider performs immediate `snapshot.get` before normal operation.

8. Short drawing pauses triggering noisy sends.
Resolution: send requires both idle-window silence and a minimum interval since the prior send; small pauses do not flush.

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
2. Default `minimum_deep` profile emits `event.drawing_flush`, `event.tap`, `event.selection`, `event.page`, and `event.snapshot_hint` without any watch subscription call.
3. Surface flushes drawings only under dual-gate timing (`idleWindowMs` + `maxIntervalMs`) and never flushes unchanged data.
4. Every stroke in `event.drawing_flush` and `snapshot.get` has stable `strokeId` and retains ID stability until explicitly removed.
5. `annotations.remove` removes only requested stroke IDs, reports `removedStrokeIds`/`notFoundStrokeIds`, and preserves all unspecified strokes.
6. Reconnect path resumes within grace for same provider and hard-resets after grace expiry.
7. Revision errors and idempotency replay behave exactly as specified.
8. Visual send indicator is visible while each drawing flush transmission is in-flight.
9. `content.set` and `content.clear` both clear drawing overlay state.
10. Heartbeat pong is emitted within SLA even while render queue is busy.
11. Pair request times out at 10s when `pair.response` is missing.
12. Reconnect path buffers events until snapshot succeeds, then replays in order; on snapshot failure provider reconnects.
13. `snapshot.get` returns base64 PNG for `image` and conditionally includes `visibleText`/`drawings` per request flags.
14. All messages validate against the schema in Section 10.

Implementation status: ready for Flynn verification.

## 13. Provider → CLU Event Routing

This section specifies how surface events reach CLU. It is intentionally separate from the WS protocol (Sections 3–10), which covers only the provider↔surface channel. The provider↔CLU channel is a different seam with different requirements.

### 13.1 Design Principles

1. **Augmentative, not invasive.** Normal Clawline message dispatch must have zero knowledge of Surf Ace. No Surf Ace logic runs in the inbound message critical path.
2. **Tool-driven.** CLU interacts with surfaces exclusively via explicit tool calls. The provider never injects context into a CLU turn automatically.
3. **Alerts are expensive.** Each alert fires a CLU agent turn. The provider MUST minimize alerts while still ensuring CLU can observe surface activity in a timely way.
4. **No live network I/O in dispatch path.** The provider MUST NOT issue live `snapshot.get` calls (or any network calls to surfaces) as part of processing an inbound CLU message.

### 13.2 Per-Screen Local Buffer (Register Model)

The provider maintains a structured local buffer for each surface. The buffer is not a flat event log — it is a set of typed **registers**, each with a defined accumulation rule. This ensures CLU always receives meaningful, non-redundant state when it reads.

#### Register Accumulation Rules

**Latest-wins** — Only the most recent value is stored. Each new incoming event of this type overwrites the previous value. CLU always sees current state, never intermediate history.

**Append** — Values accumulate in arrival order. All entries since the last CLU read are preserved. Cleared on read.

**Persistent** — Never cleared by a CLU read. Modified only by explicit CLU action (e.g. `surf_ace_annotations_remove`). Always reflects authoritative current state.

#### Registers

| Register | Rule | Type | Description |
|---|---|---|---|
| `scrollPosition` | Latest-wins | object | Latest settled scroll offset and visible rect `{ x, y, visibleRect }` |
| `selection` | Latest-wins | object? | Current text or region selection; `null` if none |
| `page` | Latest-wins | object? | Current page state `{ pageNumber, pageCount, pageLabel }`; `null` if not a paged content type |
| `snapshotHint` | Latest-wins | bool | `true` if a `snapshot_hint` event arrived since last read; `false` otherwise |
| `taps` | Append | array | Ordered list of discrete tap events since last read |
| `drawingActivity` | Append | array | Ordered list of drawing flush records since last read. Each record: `{ flushId, timestamp, strokeIdsAdded[] }`. Stroke geometry is in `annotations`. |
| `annotations` | Persistent | array | Full set of annotation strokes currently on the surface. Each stroke: `{ strokeId, points: [{x, y, pressure}], startedAt, endedAt, videoTimestamp? }`. Updated by incoming `drawing_flush` events (adds) and `surf_ace_annotations_remove` calls (removes). `videoTimestamp` is populated only for `video` content type. |
| `playbackPosition` | Latest-wins | number? | **Video only.** Current playback position in seconds. `null` for all other content types. |
| `playbackState` | Latest-wins | string? | **Video only.** One of `"playing"`, `"paused"`, `"ended"`. `null` for all other content types. |

#### Buffer State Fields

- `dirty` — boolean; `false` on init and after each CLU read of the consumed registers; `true` when any latest-wins or append register receives new data
- `alertFired` — boolean; tracks whether an alert has been sent for the current dirty cycle

#### Overflow

The append registers (`taps`, `drawingActivity`) are capped at 512 entries combined. On overflow, oldest entries are dropped and `overflowed = true` is set on the next `surf_ace_read` response. The `annotations` persistent register is not subject to this cap — it reflects current surface state and grows/shrinks with strokes added and removed.

### 13.3 Dirty Flag and Alert Gate

When a WS event arrives from a surface:

1. Update the appropriate register(s) per the accumulation rules above.
2. If `dirty` was `false`: set `dirty = true`, set `alertFired = false`.
3. If `alertFired` is `false`: fire exactly one Clawline alert to `agent:main:main`. Set `alertFired = true`.
4. If `dirty` was already `true`: update registers silently. Do NOT fire another alert.

This guarantees: one alert per dirty cycle, regardless of how many events arrive before CLU reads.

### 13.4 CLU Reads the Buffer

CLU calls `surf_ace_read` to read the local buffer for a screen. On that call:

1. Provider returns all register values.
2. Provider clears the consumed registers: `taps[]` → `[]`, `drawingActivity[]` → `[]`, latest-wins registers → reset to `null`/`false`, `dirty` → `false`, `alertFired` → `false`.
3. The `annotations` persistent register is NOT cleared — it is returned as-is and remains current.
4. The buffer is now armed: the next surface event triggers the alert cycle again.

The tool call is the acknowledgment. CLU controls the read cadence. If CLU is busy, registers update silently — no additional alerts fire.

### 13.5 Alert Content

The alert sent to the watcher session MUST be lightweight:
- It names the screen and indicates activity type (e.g. "drawing activity on Emanator").
- It does NOT include event payloads in the alert body.
- CLU retrieves payloads via the `surf_ace_read` tool call.

### 13.6 What the Provider MUST NOT Do

- **No live snapshot calls during inbound message handling.** Context injection that requires network round-trips to surfaces is forbidden in the Clawline admission/dispatch path.
- **No automatic context enrichment.** Provider must not attempt to append surface state to CLU messages pre-run. If CLU wants current state, it calls `surf_ace_read`, which reads from local cache only.
- **No multiple alerts per dirty cycle.** Once `alertFired = true`, the provider suppresses further alerts until CLU reads the buffer.

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

CLU interacts with surfaces through exactly five tools. All tools accept `fingerprint` (the screen's stable identity, e.g. `1d6ffead`) as the primary screen selector.

---

#### `surf_ace_list`

Returns all known screens and their locally cached state. Read-only, local.

**Params:** none

**Returns:** array of screen records:
```
fingerprint       string    Stable screen identity (pk fingerprint prefix)
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

Read the local buffer for a screen. Returns all register values, then clears the consumed registers and resets the dirty flag. Read-only, local — no network call to the surface.

**Params:**
```
fingerprint    string   Target screen
```

**Returns:**
```
fingerprint       string

// Consumed registers (cleared after this read)
taps              array    Ordered tap events since last read.
                           Each: { eventId, timestamp, x, y, nearestText?, elementRole? }
drawingActivity   array    Ordered drawing flush records since last read.
                           Each: { flushId, timestamp, strokeIdsAdded[] }
scrollPosition    object?  Latest settled scroll state: { x, y, visibleRect }. null if no scroll event since last read.
selection         object?  Latest selection: { selectedText, bounds, anchorStart?, anchorEnd? }. null if none.
page              object?  Latest page state: { pageNumber, pageCount, pageLabel? }. null if not applicable.
snapshotHint      bool     Whether a snapshot_hint arrived since last read.
playbackPosition  number?  Video only: latest playback position in seconds. null for all other content types.
playbackState     string?  Video only: "playing" | "paused" | "ended". null for all other content types.

// Persistent register (not cleared, always current)
annotations       array    All strokes currently on surface: [{ strokeId, points:[{x,y,pressure}], startedAt, endedAt }]

// Buffer health
overflowed        bool     True if append registers dropped entries due to 512-entry cap.
                           When true, rely on annotations (always current) for drawing state;
                           taps/drawingActivity may be incomplete.
readAt            epochMs
```

**Errors:** `screen_not_found`

`surf_ace_read` may be called regardless of connection state.

---

#### `surf_ace_annotations_remove`

Remove specific annotation strokes from a screen's drawing overlay by stroke ID. Write.

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

When a screen's event buffer transitions from clean to dirty, the provider fires one Clawline alert. Alerts route to `agent:main:main` by default. This is opaque to CLU — there is no tool to configure routing.

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

## Appendix A. Open Questions (Unresolved)

These questions surfaced during design review on 2026-03-02 and are deferred pending further thought. They affect the image capture model, annotation semantics, and on-device intelligence layer. Do not implement against these areas until they are resolved.

---

### A.1 Annotation Coordinate Space

**Question:** Do annotation strokes live in screen coordinates (where the pencil touched the glass) or content coordinates (position within the scrollable document)?

**Why it matters:** If screen coordinates, strokes made before and after scrolling are spatially disconnected and cannot be composed into a meaningful region. If content coordinates, strokes retain their document position across scroll and can be correctly bounded.

**Constraint:** This is a hard implementation decision on iOS — it determines how the PencilKit overlay is positioned relative to the scroll view.

**Status:** Unresolved. Must be decided before speccing multi-scroll annotation behavior.

---

### A.2 Multi-Scroll Annotation Image Capture

**Question:** If a user annotates the top of a long webpage, scrolls down, and annotates the bottom — how does the provider produce a meaningful image for CLU?

**Options considered:**
- Bounding box of all strokes in content coordinates (may miss content between annotated regions)
- Programmatic scroll-and-stitch: surface scrolls to each annotated region, captures, stitches composite (expensive, complex)
- Thumbnail of full page at reduced scale with all strokes overlaid (low fidelity for long pages)
- Defer to CLU: provide stroke positions and let CLU decide what to request

**Status:** Unresolved. Depends on resolution of A.1.

---

### A.3 Semantic Gesture Interpretation (Brackets Problem)

**Question:** When a user draws `[` at one position and `]` far below it, their intent is "everything between these brackets." Raw stroke geometry alone cannot convey this — the provider would only see two curved strokes with a large gap. How does the system convey the user's region intent to CLU?

**Related:** Same problem applies to any multi-stroke semantic gesture where the intent spans content between the strokes rather than the strokes themselves.

**Options considered:**
- Leave interpretation entirely to CLU (CLU infers from geometry — likely insufficient)
- On-device model classifies gesture intent before reporting to provider (see A.4)
- Surface reports stroke geometry plus a "semantic region hint" when confident (requires surface intelligence)

**Status:** Unresolved. Likely requires on-device model (A.4).

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

**Status:** Unresolved. Promising direction. Needs design session.

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

**Status:** Partially resolved. Blocked on A.1.

---

### A.7 Surface Interaction Model: Modes vs. No Modes

**Question:** Does the surface have explicit interaction modes (e.g. "navigation mode" vs. "markup mode"), or is it always one unified thing?

**Current lean (Flynn, 2026-03-02):** No explicit modes. The surface always behaves like a real browser. Full link following is supported — if CLU pushes a website, the user should be able to use it as a website including hyperlinks. Pencil always draws annotations. Finger always does finger things: scroll, select text, tap elements, follow links. Point-out is not a mode — it is the natural byproduct of ordinary finger interactions (text selection, element tap) that happen to produce structured register entries.

**Implications:**
- Link navigation must be detected and reported as a content state change (URL change → navigation event → snapshot_hint)
- Annotations should be buffered per URL (or per content hash for non-URL content) so that navigating away and back restores annotations to their previous state
- The provider tracks which annotations belong to which URL; when the user returns to a URL, the annotation register is restored from that buffer
- The model observes URL changes via the content state register and can react or ignore

**Open sub-questions:**
- Should the surface suppress link navigation when CLU-pushed content is active, with an opt-in flag to allow it? Or always allow it?
- How should annotation buffering handle URL fragments (#section) vs. full URL changes?
- What happens to annotations when CLU calls `surf_ace_push` with new content — are they cleared or preserved?

**Status:** Lean established. Sub-questions unresolved.

---

### A.8 Content Types — Coverage and Gaps

**Covered content types** and their fundamental character:
- `html` — scrollable, navigable, links, dynamic. The full browsing case. All open questions in A.1–A.7 center on this type.
- `pdf` — paginated, not URL-navigable. Annotations per page. Simpler than HTML.
- `image` — static. No scroll. Annotations stay put. Easiest case.
- `markdown` — rendered HTML, typically no links or interactivity. Simplified HTML.
- `terminal` — live text stream, content changes continuously. Annotations on moving targets are conceptually difficult. Lower priority.

**Added to spec (v1 reserved, v2 required):**

**Video** (`video`) — fundamentally temporal rather than spatial. Annotations carry an optional `videoTimestamp` field anchoring strokes to playback position. Two additional registers: `playbackPosition` and `playbackState`. The multi-scroll / bounding-box problems from A.2/A.3 have a temporal analog here — strokes made at different playback times may span content that is no longer visible. Full semantics deferred to v2. See Section 6.9.

**Blank canvas** (`canvas`) — annotations are the primary artifact; there is no underlying document. The surface renders a blank or gridded background. `content.clear` removes all annotations (unlike all other content types). CLU observes user strokes or pushes its own via future annotation-write operations. Useful for whiteboard-style collaboration. See Section 6.9.

**Everything else** (slides, word documents, maps) is a variant of HTML or PDF with cosmetic differences. No new model required.

**Status:** Both types added to the protocol (schema enum, content type characteristics in 6.9, video registers in 13.2). Implementations may return `unsupported_content_type` for these in v1. Full behavioral spec deferred to v2.
