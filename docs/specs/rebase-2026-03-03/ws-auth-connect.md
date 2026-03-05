# WS Auth/Connect Migration Spec (Rebase to v2026.3.2)

## Scope

Collision zone:
- `src/gateway/server/ws-connection/*`
- `src/gateway/server/ws-connection.ts`
- `src/gateway/client.ts`
- Clawline touchpoints: `src/clawline/server.ts` (B5 terminal WS server, B7 provider->gateway usage)

Compared upstream changes from `aba15763b` to `upstream/v2026.3.2` (`85377a281756`), then mapped to current fork state.

## What Changed Upstream

### 1) `ws-connection/*` was split into dedicated auth/policy/flood modules

New modules in upstream `src/gateway/server/ws-connection/`:
- `auth-context.ts`
  - Resolves shared auth vs device-token candidate auth for connect handshake.
  - Splits shared auth (`token`/`password`) from device-token path.
  - Adds device-token source tracking (`explicit-device-token` vs `shared-token-fallback`).
  - Centralizes rate-limit handling for shared-secret and device-token scopes.
- `connect-policy.ts`
  - Encapsulates control-ui auth policy and missing-device decisions.
  - Encapsulates trusted-proxy/operator bypass and control-ui pairing bypass rules.
- `unauthorized-flood-guard.ts`
  - Tracks repeated post-connect unauthorized role request errors.
  - Suppresses noisy logs and closes connection after threshold.
- `auth-messages.ts`
  - `AuthProvidedKind` now includes `"device-token"`.
  - Adds explicit message for rejected device-token auth.
- Tests added for all three new modules.

Current fork state in this zone:
- Missing upstream files: `auth-context.ts`, `connect-policy.ts`, `unauthorized-flood-guard.ts` (and their tests).
- Logic remains in monolithic `message-handler.ts`.

### 2) Handshake/auth behavior changed materially

Server-side handshake/auth changes in upstream `message-handler.ts`:
- Device nonce is now required whenever device identity is present (no local-client nonce exemption).
- Legacy v1 device signature fallback removed; accepted signatures are v2/v3 path.
- Device signature skew tightened (`10m` -> `2m`).
- Auth resolution now runs through `resolveConnectAuthState` and `resolveConnectAuthDecision`.
- Origin/security handling expanded via browser security context and optional `browserRateLimiter`.
- Unauthorized role flood guard applied to request-response logging/connection close behavior.

Client-side handshake/auth changes in upstream `gateway/client.ts`:
- `connect.challenge` nonce is now mandatory.
  - If challenge missing nonce: client closes with connect error.
  - Client waits for challenge; timeout closes connection.
- Added explicit `deviceToken` support in `auth`.
- Device auth payload upgraded to `buildDeviceAuthPayloadV3` (adds `platform` and `deviceFamily` into signed payload).
- Insecure remote `ws://` handling hardened (with explicit break-glass private-network env path).

### 3) `ws-connection.ts` orchestration changed

- Exposes shared handler parameter types.
- Adds optional `browserRateLimiter` plumbed into `message-handler`.
- Adds origin check metrics object passed to handler.

## What Clawline Depends On

### Clawline provider -> gateway path (B7)

`src/clawline/server.ts` does not instantiate `GatewayClient` directly. It calls `callGateway(...)` in `wakeGatewayForAlert`, and `callGateway` constructs `GatewayClient`.

Implication:
- Clawline is **indirectly** coupled to `src/gateway/client.ts` handshake behavior.
- Rebase must preserve this path so alert wake still connects/authenticates.

### Clawline own WS servers (B5 + app WS)

`src/clawline/server.ts` has independent WS servers:
- `/ws` with custom message types (`pair_request`, `auth`, `message`, `interactive-callback`).
- `/ws/terminal` with `terminal_auth` and SQLite-backed session hydration.

These do not consume `src/gateway/server/ws-connection/*`.

Implication:
- Upstream gateway module split does not require structural changes in Clawline’s own WS server for this rebase.

## Conflict Points

1. Upstream extracted auth/policy/flood logic into new files; fork keeps equivalent logic inline in `message-handler.ts`.
2. Upstream connect flow is stricter (nonce required, challenge-required sequencing, v3 payload path); fork client/server paths are older.
3. Upstream added `browserRateLimiter` plumbing in `ws-connection.ts`; fork signature is older.
4. Upstream auth messaging now distinguishes `"device-token"` auth input; fork message type set is older.

## Migration Path

1. Adopt upstream module layout exactly for `src/gateway/server/ws-connection/*`.
   - Restore upstream files: `auth-context.ts`, `connect-policy.ts`, `unauthorized-flood-guard.ts` and tests.
   - Keep `message-handler.ts` aligned to upstream imports and composition points.

2. Rebase `src/gateway/server/ws-connection.ts` to upstream handler signature.
   - Include `browserRateLimiter` and origin-check metric plumbing.

3. Rebase `src/gateway/client.ts` to upstream handshake semantics.
   - Enforce challenge nonce flow (no connect-before-challenge fallback).
   - Keep upstream `deviceToken` + payload v3 behavior.

4. Clawline-specific handling:
   - Do not refactor `src/clawline/server.ts` WS server architecture as part of this zone.
   - Keep existing B5 terminal auth/session hydration flow unchanged.
   - Keep B7 behavior: `wakeGatewayForAlert` continues to use `callGateway` with gateway token path.

5. TLS/B7 requirement check:
   - No Clawline-specific protocol change required if deployment already uses TLS (`wss://`) for non-loopback provider->gateway.
   - Any remote plaintext `ws://` provider->gateway path must be treated as migration-incompatible and moved to `wss://`/tunnel per upstream client enforcement.

## Verification

Code-shape/grep checks:
- `ls src/gateway/server/ws-connection/` includes:
  - `auth-context.ts`
  - `connect-policy.ts`
  - `unauthorized-flood-guard.ts`
  - `auth-messages.ts`
  - `message-handler.ts`
- `rg "resolveConnectAuthState|resolveConnectAuthDecision" src/gateway/server/ws-connection/message-handler.ts`
- `rg "UnauthorizedFloodGuard|isUnauthorizedRoleError" src/gateway/server/ws-connection/message-handler.ts`
- `rg "buildDeviceAuthPayloadV3|deviceToken|connect challenge timeout|connect challenge missing nonce" src/gateway/client.ts`

Behavioral checks:
- Gateway WS handshake succeeds for Clawline alert wake path (`wakeGatewayForAlert` -> `callGateway` -> `GatewayClient`).
- Confirm no regressions in terminal WS flow:
  - `/ws/terminal` `terminal_auth` still authenticates and reconnect hydration from SQLite still works (B5).
- Confirm provider/gateway TLS behavior (B7):
  - Non-loopback connections use `wss://`.
  - No silent fallback to insecure remote `ws://`.

Targeted tests:
- Run gateway WS connection tests including new module tests.
- Run gateway client tests covering connect challenge and device token behavior.
- Run Clawline server tests that cover `/ws` and `/ws/terminal` authentication flows.

## Blockers / Risks

No hard blocker identified for this collision zone.

Risk to watch:
- Any out-of-tree WS clients that still send connect without waiting for `connect.challenge` nonce (or rely on legacy v1/no-nonce signatures) may fail after rebase. Clawline path via `callGateway` should be safe once `gateway/client.ts` is rebased to upstream behavior.
