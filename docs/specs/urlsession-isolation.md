Date: 2026-03-06
Owner: Clawline iOS client
Status: Ready for implementation handoff

# URLSession Isolation

## Goal

Restore strict transport isolation in the Clawline iOS app while keeping one shared provider TLS trust policy.

The bug this spec addresses:
- Commit `8628e70b9` fixed large-image TLS failures by injecting the WebSocket connector's `URLSession` into `UploadService`.
- That fix coupled HTTP upload/download traffic to the WebSocket transport session.
- Result: one `URLSession` and one delegate boundary now serve multiple transport roles, so HTTP activity can interfere with the WebSocket lifecycle.

This spec separates provider-facing transports so each owns its own `URLSession`, while all of them evaluate the same TLS trust policy.

## Non-Goals

- No TLS policy redesign. `ProviderTLSSettingsStore` remains the source of truth for trust settings.
- No protocol changes for `/ws`, `/upload`, or `/download/{assetId}`.
- No changes to unrelated networking such as external link previews or arbitrary web content fetches.
- No change to authentication, message replay, or attachment payload rules.
- No attempt to retroactively change trust on an already-established TLS connection mid-flight; policy changes apply by rotating sessions and reconnecting/retrying through normal transport lifecycles.

## Baseline

Current relevant state in `ios/Clawline/Clawline`:
- `URLSessionWebSocketConnector` owns a TLS-aware `URLSession` for the provider chat WebSocket.
- `UploadService` performs both `POST /upload` and `GET /download/{assetId}`.
- Commit `8628e70b9` exposed `connector.tlsAwareURLSession` and injected that same session into `UploadService`.
- `ProviderTLSSettingsStore.policy` is already read through a closure at TLS challenge time.

This shape is wrong even if the current delegate only handles TLS challenges: transport ownership is now shared, future delegate behavior cannot stay transport-local, and session lifecycle for WebSocket and HTTP is no longer independent.

## Provider Transport Inventory

This spec covers the provider-facing transports in the main app graph:
1. Chat WebSocket transport: `URLSessionWebSocketConnector`
2. HTTP upload transport: `UploadService`
3. Provider asset download transport: the code path responsible for `GET /download/{assetId}`

External fetchers such as link preview metadata/image loading are out of scope because they do not use the provider TLS policy.

## Non-Negotiable Safety Invariants

### 1. TLS Policy SSOT

- `ProviderTLSSettingsStore` is the only source of truth for provider trust policy.
- All provider-facing sessions covered by this spec must evaluate the same effective `ProviderTLSPolicy`.
- No transport may hardcode or cache a divergent trust decision outside the shared policy path.
- No transport owner may persist a `ProviderTLSPolicy` snapshot and reuse it across multiple handshakes; trust policy must be resolved from the shared source at TLS challenge time.

### 2. Session Instance Isolation

- Each transport owner must own its own `URLSession` instance.
- No provider `URLSession` instance may be shared between WebSocket, upload, and asset-download transports.
- `URLSession.shared` must not be used for provider upload/download work.
- A transport owner may replace its own session over time, but another owner must never borrow that session.
- A transport owner may have at most one current session for new work. Older sessions may remain alive only to drain already-started HTTP tasks after rotation and must not be reused for later work.
- Upload and asset-download must be treated as separate transport roles for session ownership even if one type temporarily implements both code paths.

### 3. Delegate Isolation

- Each transport owner must use a delegate object that belongs only to that owner's session.
- The chat WebSocket session must have a WebSocket-owned delegate boundary.
- Upload and asset-download sessions must use TLS-only delegate handling; they must not share a delegate instance with the WebSocket transport.
- No delegate object may observe callbacks for more than one transport owner.

### 4. Current-Session SSOT

- Each transport owner must be the single authoritative holder of its current session reference and current session generation.
- No second component may independently decide whether that owner's current session is fresh or stale.
- Starting new transport work must go through the owner's freshness check; no call site may retain and reuse a session reference out-of-band.

### 5. Lifecycle Isolation

- Session creation, invalidation, and teardown are the responsibility of the owning transport only.
- Rotating or invalidating the upload session must not directly cancel, reconfigure, or otherwise perturb the WebSocket session.
- Rotating or invalidating the asset-download session must not directly affect the upload or WebSocket sessions.
- The app composition root may share a factory dependency, but not a session instance.

### 6. Runtime TLS Policy Propagation

- When provider TLS policy changes at runtime, all covered transport owners must stop using stale sessions.
- New transport work started after the policy change must run on a session created from the new policy generation.
- Because existing TLS handshakes cannot be mutated in place:
  - active WebSocket connections must reconnect through the normal connection lifecycle so the next handshake uses the new policy
  - in-flight HTTP upload/download tasks may finish or fail under the old connection, but any subsequent task must use a rotated session

## Required End State

The following outcomes are mandatory regardless of how much structure is introduced:

1. WebSocket, upload, and asset-download each use separate provider `URLSession` instances.
2. All three transport roles evaluate the same current `ProviderTLSPolicy`.
3. No raw provider `URLSession` instance is shared across service boundaries.
4. TLS policy changes mark existing sessions stale and prevent new work from starting on them.
5. The active or connecting provider WebSocket reconnects promptly on a fresh session after a real TLS policy change.

## Recommended Structure

The spec intentionally separates required safety behavior from optional refactoring weight.

Recommended, but not mandatory if the safety invariants are still met:
- introducing a dedicated `AssetDownloadService` and `AssetDownloading` protocol
- removing `download(assetId:)` from `UploadServicing`
- making upload and asset-download ownership separate top-level types instead of separate internal session owners inside one type

An implementation may keep upload and asset-download code in one service temporarily only if it still enforces the non-negotiable invariants above:
- one session for WebSocket
- one distinct session for upload
- one distinct session for asset download
- one separately-tracked current-session reference and generation for upload and for asset download
- one freshness/rotation path per session role
- no caller-visible raw session sharing

## Target End State

### 1. Shared TLS Session Factory

Introduce a shared provider TLS session factory. This is a shared factory object, not a shared `URLSession`.

Required responsibilities:
- Read provider TLS policy from one shared source (`ProviderTLSSettingsStore`, directly or via injected provider closure).
- Build fresh `URLSessionConfiguration` values with common provider defaults.
- Create a fresh `URLSession` per caller.
- Attach the correct delegate boundary for the requested transport role.
- Surface TLS policy change events or generation changes so transport owners know when to rotate their sessions.
- Be the sole source of policy generation values used for session freshness checks.

Required non-responsibilities:
- The factory must not cache and hand out a singleton `URLSession`.
- The factory must not own WebSocket connection state, upload state, or download state.
- The factory must not become a shared transport manager.
- The factory must not become a second mutable source of truth for TLS policy; any generation it exposes must be derived from `ProviderTLSSettingsStore`.

### 2. WebSocket Session Ownership

`URLSessionWebSocketConnector` must own its own session created by the shared TLS session factory.

Requirements:
- Remove the API that exposes the connector's session for reuse by other services.
- The connector's session is used only to create and manage provider chat WebSocket tasks.
- The connector retains sole ownership of its delegate and session lifecycle.
- The connector must check session freshness before each new connect attempt and recreate its session if its stored generation is stale.
- On TLS policy change while the provider chat socket is active or connecting, the connector must rotate its session and force the provider connection to reconnect through the existing connection lifecycle without waiting for some unrelated future trigger.

### 3. Upload Session Ownership

`UploadService` must own its own session created by the shared TLS session factory.

Requirements:
- `UploadService` must use a session dedicated to `POST /upload`.
- That session must use TLS-only delegate handling.
- `UploadService` constructor dependency must be the shared TLS session factory, not a raw `URLSession`.
- `UploadService` must check session freshness immediately before each upload starts and recreate its session if its stored generation is stale.
- On TLS policy change, `UploadService` must invalidate its stale session and lazily recreate or eagerly replace it before the next upload starts.

### 4. Asset Download Session Ownership

Provider asset download must use its own session created by the shared TLS session factory.

Requirements:
- The asset-download code path must use a dedicated session and TLS-only delegate handling.
- The component that owns asset download must depend on the shared TLS session factory, not a raw `URLSession`.
- The asset-download owner must check session freshness immediately before each fetch starts and recreate its session if its stored generation is stale.
- On TLS policy change, the asset-download owner must invalidate its stale session and recreate it before the next asset fetch.

Recommended structural tightening:
- Extract `GET /download/{assetId}` into a dedicated `AssetDownloadService`.
- Introduce an `AssetDownloading` protocol so asset-fetch call sites do not couple to upload behavior.

## Factory Contract

The implementation may use dedicated `makeWebSocketSession` / `makeUploadSession` / `makeDownloadSession` helpers or a single role-based API, but the following contract is mandatory:

1. Every factory call returns a fresh `URLSession`.
2. Every produced session applies the same current `ProviderTLSPolicy`.
3. Every produced session is tagged, directly or indirectly, with the factory's current policy generation at creation time.
4. WebSocket sessions and HTTP sessions do not share delegate instances.
5. Per-transport timeouts/configuration remain transport-specific:
   - WebSocket keeps the existing connect/resource timeout behavior.
   - Upload and download may use their own HTTP-appropriate timeouts.
6. The factory exposes a stable way for owners to detect TLS policy changes.
7. The factory API must not allow callers to ask for "the shared provider session" or any other session reuse primitive.

One acceptable shape is:
- a policy provider closure used by challenge delegates for per-handshake evaluation
- plus a policy-generation or notification signal used by transport owners to rotate stale sessions

Both parts are required. Per-challenge policy lookup alone is not sufficient, because keep-alive/reused connections may otherwise continue using a pre-change TLS session indefinitely.

## Runtime TLS Policy Change Contract

Changing either of these settings counts as a TLS policy change:
- `trustSelfSignedCertificates`
- `pinnedLeafCertificateSHA256`

The change test is based on the effective normalized policy, not raw input strings. Writing the same effective policy twice must not force unnecessary rotation; changing to a different effective policy must always rotate.

Required behavior:
1. `ProviderTLSSettingsStore` must emit a policy-change signal whenever the effective policy changes.
2. The shared TLS session factory must make that signal available to transport owners, directly or indirectly.
3. Each transport owner must treat that signal as invalidating its current session generation immediately, even if it defers actual session recreation until the next task or connect attempt.
4. After invalidation, no new work may start on the stale session.
5. After invalidation:
   - WebSocket transport reconnects using a newly-created session.
   - Upload transport must not start another upload on the stale session.
   - Asset-download transport must not start another fetch on the stale session.
6. Old HTTP sessions may remain alive only to drain in-flight requests. Once those requests finish or fail, the stale session must be invalidated and released.

Clarifications:
- No transport is required to mutate an already-established TLS connection in place.
- No transport is required to transparently retry failed in-flight work unless existing behavior already does so.
- The invariant is forward-looking: once policy changes, all subsequent handshakes and new tasks use fresh sessions built from the new policy.

## Composition Root Changes

In `ClawlineApp` and `Clawline_SpatialApp`:
- Create one shared TLS session factory dependency.
- Inject that factory into the WebSocket connector.
- Inject that factory into `UploadService`.
- Inject that factory into the asset-download owner.
- Do not pass raw `URLSession` instances across service boundaries.

Recommended:
- Update the chat/image asset-fetch dependency graph so provider asset reads flow through `AssetDownloading`, not `UploadServicing`.

## Required API/Ownership Changes

1. Remove connector session sharing
- Delete the public/internal escape hatch that exposes the connector's `URLSession` for reuse.

2. Preserve download-session isolation
- `GET /download/{assetId}` must not run on the upload session or the WebSocket session.
- The asset-download code path must have distinct session ownership from upload and WebSocket, even if one type temporarily contains multiple owners.
- If one concrete type temporarily owns both upload and asset download, it must keep separate stored session references, separate stored generations, and separate freshness checks for those two roles.

3. Preserve TLS behavior parity
- Existing self-signed trust and pinned-leaf behavior must remain identical across all three transport owners.

4. Invalidate sessions on owner teardown
- Each owner must invalidate its own session when the owner is torn down or replaced.

5. Remove raw-session injection from transport APIs
- Transport owners in scope must depend on the shared TLS session factory rather than accepting caller-owned provider `URLSession` instances.

## Optional Structural Follow-Ups

These are explicitly deferrable if the required safety invariants are already satisfied:

1. Introduce `AssetDownloadService`
- Good when the current type graph makes session ownership ambiguous or too easy to regress.

2. Introduce `AssetDownloading`
- Good when chat/image asset fetch call sites should stop depending on upload-oriented APIs.

3. Remove `download(assetId:)` from `UploadServicing`
- Good when the protocol shape currently obscures the fact that upload and download use different sessions.

## Acceptance Checks

1. The app graph contains three distinct provider-facing `URLSession` instances for chat WebSocket, upload, and asset download.
2. No code path injects the WebSocket connector's session into `UploadService` or the asset-download owner.
3. WebSocket, upload, and asset-download transports all evaluate the same current `ProviderTLSPolicy`.
4. A TLS policy change causes all three transport owners to mark their current sessions stale immediately.
5. After a TLS policy change, new uploads, new asset downloads, and the reconnected WebSocket all use sessions created after the change.
6. Upload or asset-download activity no longer shares delegate/session state with the chat WebSocket transport.
7. No public or injected API in scope accepts a caller-owned provider `URLSession` as the way to satisfy these transports.
8. Automated coverage proves all of the following:
   - the factory returns distinct sessions for the three transport roles
   - a no-op write of the same effective TLS policy does not rotate sessions
   - a real TLS policy change prevents new work from using a stale upload or asset-download session
   - a real TLS policy change forces an active or connecting provider chat WebSocket to reconnect on a fresh session

Optional structural checks if that path is chosen:
- `UploadServicing` no longer exposes `download(assetId:)`
- provider asset reads flow through `AssetDownloading`

## Implementation Handoff

- Keep the scope to provider chat WebSocket, provider upload, and provider asset download.
- Do not fold unrelated networking clients into this change.
- Prefer the lightest structure that still makes the safety invariants obvious and hard to violate.
- If implementation cannot make runtime TLS policy changes observable without broadening `ProviderTLSSettingsStore`, update this spec first rather than silently weakening the invariant.
