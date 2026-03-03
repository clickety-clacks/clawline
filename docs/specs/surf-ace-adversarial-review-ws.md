# Surf Ace WS Protocol — Adversarial Review

Reviewer: Claude (adversarial pass)
Date: 2026-03-01
Spec reviewed: `surf-ace.md` (WS protocol, 2026-03-01 version)
Supporting context: `docs/architecture.md`, `docs/provider-architecture.md`, architecture-principles SKILL.md

---

## Methodology

Each critique includes: exact spec location, the specific problem, why it matters in production, and a concrete fix. Only raising issues I am confident are real bugs or implementation blockers — not preferences or style.

---

## CRITICAL Issues (will cause bugs in implementation)

---

### C1 — Drawing annotation lifecycle on frame.clear and frame.set is undefined

**Location:** §6.5 Frame Clear, §6.2 Frame Set, §7.1 Drawing Flush

**Problem:**

The spec states:
- "surface never autonomously deletes strokes"
- "Surface keeps strokes rendered until explicitly removed by provider via `annotations.remove`"
- `frame.clear` "removes current frame and moves to connected-idle" → `currentFrameId=null`
- `annotations.remove` requires: "frameId (must match current frame)"

After `frame.clear`, `currentFrameId` is `null`. Any call to `annotations.remove` with any `frameId` returns `stale_frame`. **The provider has no protocol mechanism to remove drawing strokes once the frame is cleared.** If strokes persist (as the spec's "never autonomously deletes" clause implies), they render on top of whatever comes next — including the next `frame.set` content.

The same ambiguity applies to `frame.set` with a new `frameId`. The provider cannot know whether strokes are carried over to the new frame or cleared.

This is a correctness hole, not an edge case. Drawing is a core feature. Frame transitions (clear, replace) will happen on every normal workflow. Orphaned strokes with no removal path will accumulate across sessions.

**Why it matters:**

Surface shows old strokes on new frame content. Provider has no mechanism to clean them up. Implementation agents will make inconsistent choices (some clear on transition, some don't), creating a split behavior that cannot be detected by protocol conformance tests.

**Fix:**

Add an explicit rule to §6.2 and §6.5:

> `frame.set` (with any `frameId`, including a new one) and `frame.clear` MUST clear all drawing annotations from the surface. After either operation, the drawing overlay is empty. The provider does not need to call `annotations.remove` before or after frame transitions. The `annotations.remove` operation is only meaningful while strokes have been added to the current active frame.

---

### C2 — SnapshotResponse schema contradicts optional request flags

**Location:** §6.6 Snapshot Get, §10 JSON Schemas (`SnapshotGetRequest`, `SnapshotResponse`)

**Problem:**

`SnapshotGetRequest` defines three optional booleans:
```json
"includeImage": boolean    // optional
"includeVisibleText": boolean   // optional
"includeDrawings": boolean   // optional
```

The narrative says "Current `drawings` (raw strokes currently retained on surface, if requested)."

But `SnapshotResponse` schema has BOTH `visibleText` and `drawings` in `required`:
```json
"required": ["frameId", "revision", "contentType", "viewport",
             "visibleText", "selection", "drawings"]
```

`image` is NOT in required (correctly optional). But `visibleText` and `drawings` ARE required.

This means:
1. Surface MUST always serialize all stroke data in every `snapshot.get` response, regardless of `includeDrawings`.
2. Surface MUST always extract visible text, regardless of `includeVisibleText`.
3. A surface with 5000 stroke points will serialize all of them every time — potentially approaching or exceeding `maxMessageBytes` (12 MiB default). A snapshot.get that exceeds `maxMessageBytes` returns `content_too_large`, making post-reconnect recovery impossible if drawing state is large.

The schema directly contradicts the spec narrative. The request flags are dead code as written.

**Why it matters:**

Schema-strict implementation agents (which all should be) will always return full drawings and visibleText. Post-reconnect recovery requires `snapshot.get`, but on a surface with many strokes this will fail with `content_too_large`. The recovery path is broken by design if the schema is implemented correctly.

**Fix:**

Remove `visibleText` and `drawings` from the `required` array. Add conditional behavior:

> `visibleText`: included (non-null string) when `includeVisibleText=true` or when unspecified (default true); `null` or omitted when `includeVisibleText=false`.
> `drawings`: included as array (may be empty) when `includeDrawings=true`; omitted or `null` when `includeDrawings=false`. Default when unspecified: `false` (not included) to keep snapshot payloads small.

Add `"default": false` annotation to `includeDrawings` in the request schema.

---

## MAJOR Issues (will cause implementation pain and real-world failures)

---

### M1 — Heartbeat pong priority is unspecified; will cause reconnect storms during rendering

**Location:** §4.5 Keepalive

**Problem:**

Heartbeat uses the application-level request/response mechanism. The spec gives the surface a 3-second window to reply. No priority is specified.

The surface may be processing a large `frame.set` (10 MiB PDF, complex HTML render). A naive implementation queues `heartbeat.pong` behind frame rendering. If PDF rendering takes 4 seconds, pong is delayed past 3s. Provider detects "missed pong," closes the socket, and reconnects. This triggers a reconnect during rendering, which may then also be slow, causing another missed pong. Reconnect storm.

This is not a hypothetical. Rendering latency spikes are the most common real-world cause of heartbeat timeout false positives.

**Why it matters:**

Surfaces serving large content will be continuously disconnected from providers during normal rendering. Surface appears unreliable when content is the issue.

**Fix:**

Add to §4.5:

> Surface MUST process `heartbeat.ping` with highest priority, bypassing any pending frame render or mutation queue. The 3-second pong window assumes heartbeat is handled before queued frame work. Surface implementations MUST NOT enqueue pongs behind render operations.

---

### M2 — pair.request has no timeout; provider can hang indefinitely

**Location:** §6.1 Pair Handshake, §4.5 Keepalive

**Problem:**

The provider opens the WS, sends `pair.request`, and waits for `pair.response`. No timeout is specified. The heartbeat cannot help because it cannot start until pairing succeeds (§4.3 Pair-First Rule: "All operations other than `pair.request` are invalid until pairing succeeds"). If the surface accepts the WS connection but hangs before sending `pair.response` (stuck in startup, frozen UI, internal error), the provider waits forever.

**Why it matters:**

A surface that accepts connections but doesn't complete pairing creates zombie provider threads/tasks with no recovery path. This is a real failure mode for surfaces in an error state post-boot.

**Fix:**

Add to §6.1:

> Provider MUST apply a pairing timeout of 10 seconds from the moment the WS connection is established. If no `pair.response` is received within that window, provider closes the socket and re-enters the reconnect backoff sequence.

---

### M3 — WSS/TLS: relationship between Ed25519 keypair and X.509 TLS certificates is unspecified

**Location:** §9.1 Surface Identity, §9.2 Pairing Trust Model, §3.1 Discovery (`tls=1`)

**Problem:**

§9.1 says: "Surface holds persistent Ed25519 keypair" and "with `wss`, certificate public key must match advertised identity."

TLS uses X.509 certificates, not raw Ed25519 keys. Creating a self-signed X.509 certificate with an Ed25519 key requires:
- TLS 1.3 (TLS 1.2 does not support Ed25519 signatures in certs per RFC 8422)
- Platform support for generating Ed25519 X.509 self-signed certs (not available in all iOS/macOS SecureTransport wrappers)
- Provider support for pinning against an Ed25519 key (not standard HTTPS pinning)

The spec says "provider pins full key after first trust" but doesn't say what format the pinned key is stored in or how comparison is done against the X.509 cert.

Without this specification, different implementers will:
- Use RSA TLS certs + separate Ed25519 key (breaks the identity model)
- Use ECDSA P-256 certs (different key type from Ed25519)
- Use Ed25519 TLS certs (correct but requires explicit crypto library support)

**Why it matters:**

WSS implementation will be blocked or produce incompatible implementations. This is a complete blocker for `tls=1` surfaces.

**Fix:**

Add a §9.4 TLS Certificate Format:

> Surface MUST generate a self-signed X.509 v3 certificate using its Ed25519 private key (RFC 8410, TLS 1.3 Ed25519 signature scheme). The certificate SubjectPublicKeyInfo contains the Ed25519 public key. Certificate CN or SAN SHOULD include the surface's advertised name. The certificate MAY use any valid expiry (suggest 10 years; the pinned key is the identity, not expiry).
>
> Provider validates by extracting the certificate's public key bytes and comparing to the pinned full Ed25519 public key (the `pk` TXT field is a display hint prefix only, not used for cryptographic verification).
>
> Provider stores the full base64-encoded public key bytes as the pin on first successful pair.

---

### M4 — Post-reconnect snapshot.get: event handling during in-flight snapshot is undefined

**Location:** §7.3 Event Behavior Rules (rule 3), §11 item 7

**Problem:**

The spec states: "After reconnect, provider must request `snapshot.get` before acting on new events."

What happens to events that arrive while snapshot.get is in-flight? The spec is silent. Implementation agents will differ:
- **Drop events** (simplest): provider loses events that arrived between reconnect and snapshot completion.
- **Process events immediately**: provider acts on events with stale state context.
- **Buffer events forever**: unbounded memory.
- **Buffer with timeout**: undefined timeout behavior.

Additionally: what if snapshot.get fails (internal_error, content_too_large)? Should provider retry? Close and reconnect? The spec doesn't say.

**Why it matters:**

Provider implementations will split into incompatible behavior classes. Events arriving during snapshot are drawings, taps, selections — losing them silently is a real UX failure.

**Fix:**

Add to §7.3:

> Provider MUST buffer all events received after reconnect and while a mandatory `snapshot.get` is in-flight. The buffer MUST be bounded (recommend 128 events). If the buffer overflows before snapshot completes, discard the oldest events and emit a local warning. On snapshot success, process buffered events in received order after applying snapshot state. On snapshot failure (`internal_error` or `content_too_large`), provider MUST close the connection and re-enter reconnect backoff.

---

### M5 — Snapshot image format is unspecified

**Location:** §6.6 Snapshot Get, §10 `SnapshotResponse` schema

**Problem:**

`SnapshotResponse.payload.image` is defined as `{ "type": "string" }` with no media type, format, encoding, or dimensions specification.

The narrative says "Optional base64 `image` when requested" but doesn't say base64 of what. PNG? JPEG? WebP? PDF page rasterization?

Provider receives an opaque string it cannot decode without knowing the format.

**Why it matters:**

Surfaces will emit different image formats. Providers will fail to decode. No interoperability without out-of-band agreement.

**Fix:**

Either add `imageMediaType: { "type": "string" }` to the response, or mandate a specific format:

> The `image` field, when present, MUST be standard base64-encoded PNG (RFC 4648 §4, no line breaks). The PNG MUST have dimensions equal to `viewport.width × viewport.scale` by `viewport.height × viewport.scale` (physical pixels). Surface MUST include only the visible frame content; the background SHOULD be white.

Add `imageMediaType` field if the spec wants to allow future format negotiation.

---

## MINOR Issues (worth fixing before implementation but not blocking)

---

### Mi1 — Heartbeat timer start relative to pairing not specified

**Location:** §4.5 Keepalive, §4.3 Pair-First Rule

Spec doesn't say when provider starts the 10s heartbeat timer. Implementations starting it on WS connect (before pairing) will send pings that the surface rejects with `not_paired`.

**Fix:** Add to §4.5: "Provider starts the heartbeat timer immediately after receiving a successful `pair.response`."

---

### Mi2 — Flush gate: initial "last successful send" value undefined

**Location:** §7.1 Flush Gate

The idle gate condition requires "at least `idleWindowMs` elapsed since last successful send." On surface startup or after reconnect, `lastSuccessfulSend` has no defined initial value. Implementations initializing it to "now" impose an 8s delay on the first flush. Implementations initializing it to epoch-zero allow immediate flushes as soon as the idle window fires.

**Fix:** Add to §7.1: "On startup and after reconnect, `lastSuccessfulSend` is initialized to session start time (time of successful `pair.response` send). This imposes a minimum `idleWindowMs` delay before the first drawing flush after (re)connect."

---

### Mi3 — "Severe violation" threshold for `4413` socket close is undefined

**Location:** §5.5 Size Limits

"Severe violations may close socket with code `4413`" — no threshold defined. Implementations will pick arbitrary numbers.

**Fix:** Define: "If a single message exceeds `maxMessageBytes` by more than a factor of 2 (i.e., > 2× `maxMessageBytes`), or if the same connection triggers `content_too_large` three or more times within 60 seconds, surface SHOULD close the socket with `4413`."

---

### Mi4 — Heartbeat nonce has no maximum length

**Location:** §10 Schema, `HeartbeatPingRequest` and `HeartbeatPongResponse`

`nonce` is `{ "type": "string", "minLength": 1 }` with no `maxLength`. A malicious or buggy provider could send a multi-megabyte nonce, causing the pong to approach `maxMessageBytes`.

**Fix:** Add `"maxLength": 128` to both the request and response nonce fields.

---

### Mi5 — Provider has no defined strategy for `busy` rejection when it may be its own ghost socket

**Location:** §4.2 Single-Connection Rule, §4.4 Reconnect Behavior

If TCP drops silently (NAT timeout), the surface retains a ghost socket. Provider reconnects without `takeover=true` (it didn't miss a heartbeat — it got a TCP error and reconnected immediately). Surface returns `busy`. Provider doesn't know whether the blocking session is its own ghost or a different provider.

The `busy` error body has no `details` field content specified, so provider can't distinguish.

**Fix:** Add to §4.4: "If provider receives a `busy` error response on `pair.request`, and it was previously paired to this surface (has a `sessionId` from a prior session), provider SHOULD retry with `takeover=true`. Surface only accepts `takeover=true` from the same `providerId`, so this is safe."

Optionally: add `blockedByProviderId` to the `busy` error `details` object so the provider can confirm it's its own session.

---

### Mi6 — Stroke schema is missing visual properties (color, width)

**Location:** §10 Schema, `Stroke`

`Stroke` captures `tool` (pencil/finger/mouse), `points` (x, y, pressure, timestamp), and `strokeId`. No color, line width, or opacity is captured.

For CLU to attribute semantic meaning that depends on rendering (e.g., "user circled this in red"), these are needed. For pure shape-based interpretation (scratch-out, circle), the current schema is sufficient.

This is a deliberate omission or an oversight. The spec should explicitly note the intent.

**Fix:** Either add optional fields:
```json
"color": { "type": "string", "pattern": "^#[0-9a-fA-F]{6}$" },
"widthPoints": { "type": "number", "minimum": 0 },
"opacity": { "type": "number", "minimum": 0, "maximum": 1 }
```
Or add a note to §7.1: "Stroke visual properties (color, width, opacity) are intentionally omitted in v1. CLU interprets strokes by path shape only. Surfaces with user-selectable drawing tools SHOULD transmit strokes with the same visual attributes as rendered, even if the protocol does not carry them."

---

## Summary Table

| ID | Severity | Location | Problem |
|----|----------|----------|---------|
| C1 | CRITICAL | §6.2, §6.5, §7.1 | Drawing lifecycle on frame.clear/frame.set undefined → orphaned strokes, no removal path |
| C2 | CRITICAL | §6.6, §10 schema | SnapshotResponse requires `drawings`+`visibleText` despite optional request flags → large mandatory payloads, broken recovery |
| M1 | MAJOR | §4.5 | Heartbeat pong priority unspecified → reconnect storms during rendering |
| M2 | MAJOR | §6.1 | pair.request has no timeout → provider hangs indefinitely on unresponsive surface |
| M3 | MAJOR | §9.1, §9.2 | WSS/TLS: Ed25519→X.509 cert format unspecified → will block TLS implementation |
| M4 | MAJOR | §7.3 | Post-reconnect snapshot.get: event handling during in-flight snapshot undefined |
| M5 | MAJOR | §6.6, §10 | Snapshot image format unspecified → format incompatibility |
| Mi1 | MINOR | §4.5 | Heartbeat timer start not specified relative to pairing |
| Mi2 | MINOR | §7.1 | Flush gate initial "last successful send" value undefined |
| Mi3 | MINOR | §5.5 | "Severe violation" threshold for 4413 close undefined |
| Mi4 | MINOR | §10 | Heartbeat nonce has no maxLength |
| Mi5 | MINOR | §4.2, §4.4 | No defined provider strategy for `busy` rejection when own ghost socket suspected |
| Mi6 | MINOR | §10 | Stroke missing visual properties (color, width, opacity) |

---

## Verdict

The protocol is structurally sound. The revision-gated mutation model, reconnect/grace design, and always-on event streaming are well-reasoned. Section 11's hardening list shows prior adversarial thinking.

**C1 and C2 must be resolved before implementation starts.** C1 will cause persistent state corruption (orphaned strokes). C2 will cause broken post-reconnect recovery under heavy drawing use.

M1 and M2 are critical for real-world reliability. M3 blocks WSS entirely. M4 and M5 are implementation-incompatibility risks.

The minor items can be addressed in the same revision pass as the critical/major fixes.
