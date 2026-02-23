# Retro: Alert Routing Breakage + Fix (commit 0d959a2da2)
*2026-02-22*

---

## What broke

`POST /alert` with a Clawline stream session key (`agent:main:clawline:flynn:s_*`) returned `{"ok":true}` but messages never appeared. The announce queue drained in a retry storm until the gateway was restarted.

---

## Root cause

T101 (commit `a31a63e2c8`) renamed `normalizedMainKey` → `_normalizedMainKey` in two places in `server.ts`, but missed a third usage inside `resolveAlertSessionKey`:

```ts
// Before fix — still referenced the old name (undefined in this scope):
if (normalized === normalizedMainKey) {
```

This caused `resolvedSessionKey` to be handled incorrectly, breaking alert delivery for Clawline stream sessions. The error propagated as `Error: Invalid clawline session key` in the gateway logs.

**Note:** Pre-rebase log entries showing the same error string (`2026-02-17`, `2026-02-22 15:53`) are red herrings — those are Discord channel sessions (`agent:main:discord:channel:...`) being misrouted through the Clawline announce queue. Unrelated to this bug.

---

## What 0d959a2da2 fixed

```diff
- if (normalized === normalizedMainKey) {
+ if (normalized === _normalizedMainKey) {
```

Corrected the variable reference. Alert routing for Clawline stream session keys should now work.

---

## Side effect in the same commit

The same commit also reverted the lane fix from `c28f81f2e3`:

```diff
- const globalLane = resolveGlobalLane(params.lane ?? sessionLane);
+ const globalLane = resolveGlobalLane(params.lane);
```

The revert message says "lane fallback deadlock." The deadlock is real: `enqueueSession` holds the session lane lock, then `enqueueGlobal` with `globalLane = sessionLane` tries to enqueue into the same held lane — deadlock. The revert is correct.

However: this means all Clawline streams are back to sharing `CommandLane.Main` as their global lane. T101's per-user queue fix is still in place. Whether `CommandLane.Main` is still a visible serialization bottleneck is an open question.

---

## Current state on TARS

- Commit `0d959a2da2` is at HEAD, gateway restarted at 6:02 PM PST (after commit landed at 5:32 PM PST)
- `_normalizedMainKey` fix is live
- Lane fix is reverted
- No new drain failures in logs since the gateway restart

---

## Open question

The Discord channel sessions (`agent:main:discord:channel:...`) keep showing up in the Clawline announce queue with `Invalid clawline session key`. That's a separate pre-existing routing issue — Discord sessions shouldn't be hitting the Clawline drain at all. Worth a separate look.
