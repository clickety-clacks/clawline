# Migration Spec: `resolve-route.ts` Session Routing Canonicalization (v2026.3.2)

## Scope
Collision zone:
- `src/routing/resolve-route.ts`
- Related upstream behavior: `src/channels/session.ts`
- Clawline routing touchpoints reviewed: `src/clawline/server.ts`, `src/clawline/routing.ts`, `extensions/clawline/src/channel.ts`

Target upstream commit/tag:
- `v2026.3.2` (`85377a28175695c224f6589eb5c1460841ecd65c`)

Note:
- Local ref `upstream/v2026.3.2` is not present in this checkout; analysis used `v2026.3.2` tag at the same commit.

## Upstream Changes

### 1) `src/routing/resolve-route.ts` structural rewrite (+major indexing/caching)
Upstream rewrites route resolution around normalized/indexed candidate sets and caching:
- Account normalization now uses shared `normalizeAccountId` from `session-key` (`resolve-route.ts` line 13, line 75-84).
- Agent lookup now uses cached normalized-id map (`line 114-161`).
- Binding evaluation now builds and caches indexes by peer/guild/team/account/channel (`line 199-387`).
- Peer matching treats `group` and `channel` as equivalent in scope matching (`line 492-498`).
- New per-config resolved route cache keyed by normalized routing inputs (`line 424-478`, `line 553-571`, `line 599-604`).
- Resolved `sessionKey` and `mainSessionKey` are explicitly lowercased (`line 577-590`).

Behaviorally, upstream route resolution is still deterministic, but much more cache/index driven.

### 2) `src/channels/session.ts` canonicalization + pinned-main-DM skip
Upstream adds:
- `normalizeSessionStoreKey(sessionKey) => trim().toLowerCase()` (`session.ts` line 9-11).
- Canonicalization of both recorded inbound session key and update target key (`line 51-55`, `line 67-71`).
- Optional `mainDmOwnerPin` on `updateLastRoute` payload (`line 19-24`).
- Skip logic: if pinned owner recipient != sender recipient, skip updating main DM last-route (`line 26-39`, `line 64-66`).
- Guard against metadata bleed: only pass `ctx` when target session equals source session (`line 77-79`).

## Current Fork Behavior in This Zone

### `resolve-route.ts` in fork (HEAD)
Fork currently has only a small change vs merge-base (`aba15763b`) in this file:
- `normalizeId` accepts `number|bigint` in addition to strings.
- No upstream caching/indexing/session-normalization rewrite has landed yet.

### Clawline stream routing path (critical)
Clawline stream delivery is session-key first and does not call `resolveAgentRoute` in its own server path:
- `grep -R -n "from.*routing\|resolve-route\|resolveRoute" src/clawline/ extensions/clawline/` only shows:
  - `src/clawline/server.ts:68` (`DEFAULT_ACCOUNT_ID` import)
  - `src/clawline/server.ts:75` (`ClawlineDeliveryTarget` import)
- Inbound Clawline message flow sets `route.sessionKey = resolvedSessionKey` directly and then calls `recordInboundSession` with that explicit key:
  - `src/clawline/server.ts` line `5040-5094`
  - `src/clawline/server.ts` line `5441-5494`
- Outbound Clawline send resolves/validates explicit session keys through Clawline-specific helpers (`resolveSessionTargetFromSessionKey`, `normalizeStreamMutationSessionKeyForUser`) rather than `resolveAgentRoute`:
  - `src/clawline/server.ts` line `4730-4766`

This preserves invariant B2 (session key is routing primitive for Clawline streams).

## Key Questions Answered

### What is pinned-main-DM route-skip behavior?
`recordInboundSession` now accepts optional `mainDmOwnerPin` and skips the `updateLastRoute` write when pinned owner != sender. This is designed to prevent non-owner DM messages from repointing `agent:main:main` last-route.

For Clawline specifically:
- Current Clawline calls to `recordInboundSession` do not set `mainDmOwnerPin`.
- Therefore this skip logic does not intercept Clawline stream writes under current code.

### Could new caching/indexing stale-hit Clawline stream routing?
For Clawline stream delivery, no, because Clawline does not route via `resolveAgentRoute` for stream selection.

If Clawline were forced through `resolveAgentRoute`, it would not produce `agent:main:clawline:<user>:s_xxxx` stream keys; it derives keys from channel/account/peer semantics, not Clawline stream suffix semantics. That would risk stream collapse. Therefore Clawline must continue bypassing `resolveAgentRoute` for stream-key targeting.

### Does session key canonicalization normalize away `agent:main:clawline:flynn:s_XXXX`?
In upstream `channels/session.ts`, canonicalization is only `trim().toLowerCase()`. It does not rewrite segments or collapse stream suffix structure.

For Clawline keys:
- Stream suffix format is already lowercase (`s_[0-9a-f]{8}` policy).
- Clawline key builders normalize case.
- Result: canonicalization should not merge distinct valid stream keys.

### Does Clawline bypass `resolve-route` entirely for its own routing?
Yes for stream routing behavior:
- Clawline server sets and validates session keys in Clawline-owned logic.
- `resolveAgentRoute` is not used in Clawline inbound/outbound stream routing path.

### Are there new upstream routing hooks Clawline should register?
No new hook registration points were added in `resolve-route.ts` or `channels/session.ts`. Upstream changes are internal algorithm/cache/canonicalization changes.

## Conflict

Conflict is behavioral, not compile-level:
- Upstream canonicalizes and skips certain main-DM route updates.
- Clawline requires strict per-stream session key isolation (`agent:main:clawline:<user>:<stream>`).
- Any migration that routes Clawline through upstream generic `resolveAgentRoute` risks losing stream-specific routing.

## Migration Path

1. Adopt upstream `src/routing/resolve-route.ts` as-is (prefer upstream pattern, minimize divergence).
2. Adopt upstream `src/channels/session.ts` as-is, including canonicalization and pinned-main-DM skip behavior.
3. Preserve Clawline stream-key routing seam:
   - Keep Clawline-owned explicit session-key path in `src/clawline/server.ts` (do not switch Clawline inbound/outbound stream selection to `resolveAgentRoute`).
   - Keep `recordInboundSession` calls with Clawline `sessionKey` values derived from Clawline helpers.
4. Do not add core hooks in routing for Clawline. This zone needs no new upstream-core extension point.
5. `src/clawline/routing.ts` status for this collision:
   - No required update for compatibility with upstream `resolve-route` rewrite.
   - It remains fork-specific/session-target formatting logic and should stay independent of upstream routing internals.

## Verification Plan (Post-merge)

### Static checks
1. Confirm upstream files landed:
   - `src/routing/resolve-route.ts` contains route cache/index code (`resolveRouteCacheForConfig`, `buildResolvedRouteCacheKey`, indexed tier candidates).
   - `src/channels/session.ts` contains `normalizeSessionStoreKey`, `mainDmOwnerPin`, and `ctx` cross-session guard.
2. Confirm Clawline still bypasses generic route resolver for stream routing:
   - `grep -R -n "resolveAgentRoute" src/clawline/ extensions/clawline/` should not show stream-path usage.
   - `src/clawline/server.ts` still sets `route.sessionKey` from `resolvedSessionKey` and calls `recordInboundSession` with that key.

### Behavior tests
1. Existing stream targeting coverage in `src/clawline/server.test.ts` should pass, especially:
   - alert routing to dynamic stream session keys (existing dynamic stream test)
   - unknown stream key returns `stream_not_found`
2. Add/port focused test coverage for `channels/session.ts` canonicalization interactions with Clawline-shaped keys:
   - mixed-case `agent:main:clawline:Flynn:s_deadbeef` is stored/updated as lowercase key
   - cross-session `updateLastRoute` does not copy `ctx`
3. Add stream-isolation regression check:
   - two concurrent streams for one user (`...:main` and `...:s_xxxx`) receive only their own traffic; no cross-stream delivery.

## Blockers / Open Questions

No hard blocker identified for this collision zone.

Open watch item during merge verification:
- Upstream `channels/session.ts` drops `ctx` when writing `updateLastRoute` to a different session key. Confirm Clawline does not depend on cross-session metadata side effects from DM follow-me writes (only delivery-context update should be required).

## Decision

Ready for merge-agent implementation: adopt upstream routing/session canonicalization internals, while explicitly preserving Clawline-owned session-key routing seam and stream isolation behavior.
