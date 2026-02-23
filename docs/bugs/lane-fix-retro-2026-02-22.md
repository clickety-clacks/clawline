# Retro: Lane Fix → Revert → Current State
*2026-02-22*

---

## What we were solving

Clawline parallel streams were serializing — sending a message on stream A would block stream B from getting a response until A finished.

Root cause: `runEmbeddedPiAgent` wraps all agent work as `enqueueSession(() => enqueueGlobal(...))`. With `params.lane` undefined, `resolveGlobalLane(undefined)` returns `CommandLane.Main`, so every stream's agent work queues into the same global lane and runs serially.

---

## What T101 fixed

Commit `a31a63e2c8` — moved `dispatchReplyFromConfig` outside `runPerUserTask` in `server.ts`. This removed serialization at the **per-user queue** level. Streams no longer blocked each other at the server dispatch layer.

---

## What the lane fix added

Commit `c28f81f2e3` — changed `src/agents/pi-embedded-runner/run.ts`:

```diff
- const globalLane = resolveGlobalLane(params.lane);
+ const globalLane = resolveGlobalLane(params.lane ?? sessionLane);
```

Intent: when no explicit lane is provided, fall back to the per-session lane instead of `CommandLane.Main`, so each stream runs in its own isolated global lane rather than all sharing one.

---

## Why it was reverted

Commit `0d959a2da2` reverted it with note "revert lane fallback deadlock."

The deadlock is real: `enqueueSession` holds the session lane lock, then calls `enqueueGlobal` with `globalLane = sessionLane`. But `enqueueGlobal` tries to enqueue into the same lane that's already held — deadlock. The fix was architecturally unsound because `sessionLane` and `globalLane` must always be distinct lanes.

---

## Current state

- `run.ts` is back to bare `resolveGlobalLane(params.lane)`.
- `params.lane` is `undefined` for all Clawline stream calls.
- `resolveGlobalLane(undefined)` returns `CommandLane.Main`.
- All Clawline streams still share `CommandLane.Main` for global lane serialization.
- T101's per-user queue fix is still in place.

---

## Open question

Does T101 alone make streams feel parallel in practice? The serialization moved from per-user queue to global lane. If T101 removed the bottleneck users actually felt, the remaining `CommandLane.Main` serialization may not matter. If streams still feel serialized, the global lane is the remaining bottleneck.

---

## What a correct fix looks like

Use a **separate per-stream lane** that is distinct from `sessionLane`. The nested enqueue structure (`enqueueSession(() => enqueueGlobal(...))`) requires two distinct lanes — using the same lane for both causes deadlock.

A safe approach: derive a stream-specific global lane from the session key, but using a **different key prefix** than the session lane so they never collide. Example:

```ts
const streamGlobalLane = resolveGlobalLane(
  params.lane ?? deriveStreamLane(params.sessionKey)
);
```

Where `deriveStreamLane` returns a lane ID keyed on the stream session key but with a distinct namespace from `resolveSessionLane`.

---

## Also fixed in 0d959a2da2

The same commit fixed an unrelated bug: T101 renamed `normalizedMainKey` → `_normalizedMainKey` in two places in `server.ts` but missed a third usage inside `resolveAlertSessionKey`. This caused alert routing to misbehave for Clawline stream session keys. That fix is correct and should stay.
