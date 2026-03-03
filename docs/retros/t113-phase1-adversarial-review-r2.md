# T113 Phase 1 Adversarial Review — Rerun R2

**Date:** 2026-02-24
**Reviewer:** Opus (architecture agent, per-stream-state branch)
**Commits reviewed:** `e4306bf5c` (scroll debounce timer fix), `77b38fcc8` (callback registration fix)
**Baseline:** R1 review at commit `c110f5618` — 1 blocking (Gate 4), 4 minor findings
**Spec:** `/Users/mike/shared-workspace/clawline/specs/per-stream-state-encapsulation.md`
**Architecture plan:** `/Users/mike/shared-workspace/clawline/specs/t113-architecture-plan.md`
**Branch:** `per-stream-state` @ `77b38fcc8`

---

## Delta From R1

Two commits since R1 baseline:

### Commit `e4306bf5c` — Fix scroll debounce timer switch cancellation and generation guard

Addresses the R1 Gate 4 blocker. Two changes:

1. `cancelDeferredWork(for:cancelAll:)` now invalidates `scrollStateWriteDebounceTimer` (line 1311):
   ```swift
   state.scrollStateWriteDebounceTimer?.invalidate()
   state.scrollStateWriteDebounceTimer = nil
   ```
   This prevents the outgoing session's debounce timer from firing after a stream switch, which was the data corruption path identified in R1.

2. `schedulePersistScrollState` now captures `restoreGeneration` and validates it in the timer callback (lines 2264, 2267):
   ```swift
   let expectedGeneration = state.restoreGeneration
   // ... timer callback:
   guard self.readState(for: sessionKey).restoreGeneration == expectedGeneration else { return }
   ```
   This is defense-in-depth: even if cancellation fails, a generation mismatch (from switch or re-read) prevents the stale write.

### Commit `77b38fcc8` — Fix on-message-load registration drop during stream transitions

Addresses a latent issue in the callback registry (Gate 2). The R1 review passed this gate because it verified the 5 behavioral requirements, but did not catch a timing edge case: during `runStreamContextSwitchSeam`, `callbackSessionKey()` still returns the outgoing key. Calls to `registerOnMessageLoad` for the incoming session's key would fail the `callbackSessionKey() == sessionKey` guard and silently drop the registration.

Fix: removed the `callbackSessionKey() == sessionKey` guard from `registerOnMessageLoad`. The function now only guards on non-empty key/id (line 2358) and stores directly into the target session's per-stream state (line 2366). The immediate-fire path (`isMessageMaterialized`) still correctly guards on `callbackSessionKey()` (line 2372) — you can only check materialization for the currently active session. The fire path (`fireRegisteredMessageLoadCallbacksIfMaterialized`) also still guards correctly.

---

## Phase 1 Completion Gate Re-evaluation

### Gate 1: forceReRead flows from ChatViewModel → ChatView → controller

**PASS** — No change from R1. No regression.

### Gate 2: One-shot callback registry implemented and used for restore

**PASS** — Previously PASS in R1 on behavioral requirements, but had latent registration-drop bug during transitions. Now fixed:
- Registration stores by target sessionKey without active-key guard (line 2366).
- Fire path remains key-scoped and materialization-gated (line 2372).
- Expiry on switch-away (`clearRegisteredMessageLoadCallbacks`) unchanged.
- Expiry on message deletion (`expireRegisteredMessageLoadCallbacks`) unchanged.
- One-shot semantics (remove before fire) unchanged.

### Gate 3: Canonical auth cursor — nil when incomplete, max when complete, no bias

**PASS** — No change from R1. No regression.

### Gate 4: Timer callbacks validate (sessionKey, generation) not just key

**PASS** — Previously FAIL. Now all 5 timer types are correctly handled:

| Timer | Token/gen capture | Generation check | Cancel in `cancelDeferredWork` |
|---|---|---|---|
| `scheduleBottomInsetHeightCapInvalidation` | ✓ | ✓ | ✓ |
| `scheduleDeferredBottomInsetRemeasure` | ✓ | ✓ | ✓ |
| `scheduleBubbleSizingV2Remeasure` | ✓ | ✓ | ✓ |
| `scheduleBubbleSizingV2DeferredFlushAfterRest` | ✓ | ✓ | ✓ |
| `schedulePersistScrollState` | ✓ (line 2264) | ✓ (line 2267) | ✓ (line 1311) |

Additionally, `prepareSameKeyReread` also invalidates the timer (line 1359) — correct for the re-read path.

### Gate 5: Spec text updated with adversarial review resolutions

**PASS** — No change from R1. Spec has `forceReReadGeneration` wording at lines 207, 278, 387, 426. Adversarial review resolution notes at lines 73-79.

### Gate 6: Per-stream-state spec acceptance checks 1-25

**25/25 PASS** — Previously 24/25 (check 3 partial fail due to Gate 4 root cause). Now:

| # | Description | Verdict | Delta from R1 |
|---|---|---|---|
| 1 | Stream A scrolled-up → switch B → switch back A: restores | **PASS** | No change |
| 2 | First activation tail→full restore resolves correctly | **PASS** | No change |
| 3 | Pending debounce/timers from A do not mutate B after switch | **PASS** | Was PARTIAL FAIL. Now all 5 timers cancelled + generation-guarded |
| 4 | Drag/morph deferral from A does not auto-scroll B | **PASS** | No change |
| 5 | SBB correct immediately after switch when not at bottom | **PASS** | No change |
| 6 | Same-key re-read re-arms restore at persisted position | **PASS** | No change |
| 7 | No persisted state → deterministic bottom fallback | **PASS** | No change |
| 8 | Frozen→unfrozen does not expose stale SBB/scroll | **PASS** | No change |
| 9 | Prewarm/offscreen pages do not mutate active runtime | **PASS** | No change |
| 10 | Message-ID collisions across streams: no cross-contamination | **PASS** | No change |
| 11 | Switch during `pendingFullConfirmation`: stale retry no-ops | **PASS** | No change |
| 12 | Async size changes: bounded confirmation retries converge | **PASS** | No change |
| 13 | Deleted stream keys pruned: no stale timer/callback mutation | **PASS** | No change |
| 14 | Mutation callback without resolved key no-ops | **PASS** | No change |
| 15 | Same-key re-read: no persist overwrite before restore confirmation | **PASS** | No change |
| 16 | Switch A→B: B classification uses B's per-stream lastMessageId | **PASS** | No change |
| 17 | Frozen→unfrozen triggers follow-up update and pending restore | **PASS** | No change |
| 18 | Scroll delegates during seam mutate outgoing, never incoming early | **PASS** | No change |
| 19 | Replay cursor isolated per stream on initial login | **PASS** | No change |
| 20 | Concurrent replay cannot advance sibling stream cursor | **PASS** | No change |
| 21 | Replay callbacks with stale (key, gen) no-op | **PASS** | No change |
| 22 | No direct message-store writes introduced (T105 scope) | **PASS** | No change |
| 23 | Callback registry: fires once, fires if materialized, expires on switch/deletion | **PASS** | Registration-drop edge case now fixed |
| 24 | Reload trigger normalization: cache, reconnect, cursor clear, Siri | **PASS** | No change |
| 25 | Transport replay cursor storage owned by transport layer | **PASS** | No change |

---

## Blocking Findings

None.

---

## Non-Blocking Findings (carried from R1)

Findings A–D from R1 remain. None were addressed by the two fix commits (they were classified as non-blocking):

- **A (MINOR):** `prepareIncomingStateOnSwitch` uses unconditional `allowTailStage: true` with downstream correction instead of checking materialization state.
- **B (COSMETIC):** Inconsistent `+= 1` vs `&+= 1` for generation increment.
- **C (MINOR):** Missing `// MIGRATION SHIM` markers on transitional computed properties.
- **D (MINOR):** `messagesById` not classified in spec as controller-scope.

---

## Summary

| Gate | R1 Verdict | R2 Verdict |
|---|---|---|
| 1. forceReRead end-to-end | PASS | **PASS** |
| 2. One-shot callback registry | PASS | **PASS** (registration-drop fixed) |
| 3. Canonical auth cursor | PASS | **PASS** |
| 4. Timer generation validation | FAIL | **PASS** |
| 5. Spec text updated | PASS | **PASS** |
| 6. Acceptance checks 1-25 | 24/25 | **25/25** |

**Overall: PASS.** All Phase 1 completion gates satisfied. No blocking findings.
