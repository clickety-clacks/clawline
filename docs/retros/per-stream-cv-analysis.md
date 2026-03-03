# Per-Stream MessageFlowCollectionView Analysis

**Date:** 2026-02-25  
**Branch analyzed:** `~/src/worktrees/per-stream-state` (eezo), cross-referenced with `main`  
**Specs cross-referenced:** `per-stream-state-encapsulation.md`, `stream-switch-coordinator.md`, `per-stream-transition-surface-contract.md`

---

## Context: What the Branch Actually Is

The `per-stream-state` branch is NOT the old single-MFCV architecture. It already has **one MFCV per stream** via a paged `TabView`. The question posed in the task ("currently a single MFCV is reused") accurately describes the *behavioral problem*, not the literal structure: because `TabView` can recycle off-screen pages, each stream switch behaves like a context hand-off into a shared controller — even though each tab has its own MFCV instance. The result is a full switch-seam pipeline.

**What the branch has added** (on top of `main`) to handle this:
1. `PerStreamRuntimeState` struct (all per-stream mutable state centralized)
2. `runStreamContextSwitchSeam` (switch ownership handoff function)
3. Two-key ChatViewModel split: `uiSelectedSessionKey` vs `engineActiveSessionKey`
4. Epoch-based debounced engine activation with pager interaction/settle signals
5. `isRenderPolicyFrozen` flag to block heavy render work during pager animation
6. Two-phase scroll restore (`pendingTail → pendingFullConfirmation → confirmed`)
7. Zero-sections guard in `MessageFlowLayout.prepare()`

The **proposal** is to replace the `TabView` paged approach with show/hide of always-live views. Stream switching becomes a `view.isHidden` toggle. This eliminates the timing race that drives all of the above.

---

## Q1: How Many Lines of Switch-Seam Code Could Be Deleted?

### MFCV (`MessageFlowCollectionView.swift` — 4,534 lines in branch)

| Function / Block | Lines | Deletable with show/hide? |
|---|---|---|
| `runStreamContextSwitchSeam` (L2275–2320) | **46** | ✅ Yes — the entire function |
| `prepareIncomingStateOnSwitch` (L1345–1363) | **19** | ✅ Yes — no incoming-stream setup needed |
| `prepareSameKeyReread` (L1364–1376) | **13** | ✅ Mostly — same-key re-read still needed for reconnect, but the flush/restore part simplifies dramatically |
| `cancelDeferredWork` switch-triggered call + function (L1314–1333) | **20** | ✅ Yes as a switch concern; stays as lifecycle cleanup |
| `isRenderPolicyFrozen` guard in `update()` (L1683–1696) | **~15** | ✅ Yes — no pager animation to protect against |
| `lastAppliedEffectiveSessionKey` tracking (scattered) | **~8** | ✅ Yes — no switch seam, no outgoing-key concept |
| Zero-sections guard in `prepare()` (L4332–4341) | **10** | ✅ Yes — each view has stable data source; UIKit won't call prepare before sections exist |
| Two-phase scroll restore: `scheduleRestoreAttemptOnMessageAppearance` + `attemptRestoreScrollIfNeeded(token:)` | **~80** | ✅ Yes — this entire timing dance exists because the view must race with data source apply. With show/hide, the view is already settled. |
| `suspendScrollPersistenceUntilRestoreConfirmed` + `restorePhase` machinery | **~40** | ✅ Yes — suspension exists to prevent flushes from a live-but-rebinding view overwriting the restore anchor. Gone with show/hide. |

**MFCV subtotal: ~251 lines**

### ChatViewModel (`ChatViewModel.swift` — 2,234 lines in branch)

| Function / Block | Lines | Deletable with show/hide? |
|---|---|---|
| `requestStreamSwitch(to:source:)` | **~40** | ✅ Simplifies to: hide A, show B, call `setActiveSessionKey` |
| `streamPagerDidBeginInteraction()` | **5** | ✅ Yes — no pager |
| `streamPagerDidSettleAtRest()` | **8** | ✅ Yes — no pager |
| `scheduleDebouncedEngineActivation` | **20** | ✅ Yes — debounce exists to let pager settle; instant with show/hide |
| `commitPendingEngineActivationIfCurrent` | **20** | ✅ Yes — epoch validation for stale animations |
| `markEngineActivationRenderedIfNeeded` | **6** | ✅ Yes — spinner tracks that engine activation is in-flight during pager settle |
| `isPagerInteracting`, `uiSwitchEpoch`, `pendingEngineActivationTask/Target/Epoch`, `engineActivationInFlightSessionKey` + related state declarations | **~25** | ✅ Yes — pager-specific machinery |
| `uiSelectedSessionKey` vs `engineActiveSessionKey` split | **~30** | ⚠️ Partial — the split exists because UI intent must be immediate while engine activation is debounced. With show/hide there's no debounce gap, so both collapse back to one key. But the *read-classification discipline* was valuable work. |

**ChatViewModel subtotal: ~154 lines**

### ChatView (`ChatView.swift`)

| Code | Lines | Deletable? |
|---|---|---|
| `streamPagerDidBeginInteraction` / `streamPagerDidSettleAtRest` call sites | **~6** | ✅ |
| `isRenderPolicyFrozen` propagation into MFCV updates | **~5** | ✅ |
| `uiSelectedSessionKey` vs `engineActiveSessionKey` two-key TabView binding logic | **~25** | ✅ Collapses to simple show/hide toggle |

**ChatView subtotal: ~36 lines**

### What Would Remain (Not Deletable)

- `PerStreamRuntimeState` struct and `perStreamStateBySessionKey` dictionary: this is the **right architecture** regardless and stays. SBB, scroll-to-bottom, typing/morph state must be per-stream.
- Basic scroll persistence to UserDefaults: still needed for app relaunch and for memory-evicted streams. The `persistScrollStateNow` / `loadPersistedScrollState` functions stay, but simplified (no suspension gate, no two-phase restore, no generation tokens).
- `cancelDeferredWork` stays as lifecycle cleanup on stream deletion.
- `prunePerStreamState` stays.

### Total Deletable

| Subsystem | Lines |
|---|---|
| MFCV switch seam + restore pipeline | ~251 |
| ChatViewModel two-key + pager machinery | ~154 |
| ChatView two-key wiring | ~36 |
| **Total** | **~441 lines** |

The `per-stream-transition-surface-contract.md` (the "epoch rule" and async continuation guard) exists because deferred closures can fire after a stream switch. With show/hide and stable views, the epoch guard remains a best practice but the *enforcement complexity* drops significantly — most deferred work only needs to check "does this key match my own key" (a trivially stable property for a dedicated view).

---

## Q2: Risks and Downsides

### Memory

**This is the primary risk.** Each stream gets its own `UICollectionView`, `UICollectionViewDiffableDataSource`, `MessageFlowLayout`, and cached cell+attribute data. Current users commonly have 3–5 streams, with some power users having 10+.

Rough per-stream memory cost:
- Collection view shell: ~1–2 MB baseline
- Materialized cells for a 500-message stream: ~5–15 MB (depends on bubble complexity, cached sizes, link previews)
- Layout cache (`cachedAttributes` dictionary): ~0.5–2 MB for 500 items

**For 5 streams: ~30–85 MB additional heap beyond what `main` uses today.**  
**For 10 streams: ~60–170 MB.**

This is a meaningful pressure on devices with 3–4 GB RAM but survivable. On 2 GB devices (older iPhones) this would be dangerous. The proposed eviction path mitigates this — but see Q3 below.

### Cell Registration

In the current architecture, each MFCV tab page registers its own cell types. This is already the case in the branch (each `TabView` page creates its own MFCV). No additional work here for show/hide. ✅

### Shared ChatViewModel State

`ChatViewModel` is shared across all streams. The `var messages: [Message]` property tracks only the *active* stream's messages. With show/hide, each MFCV needs to observe changes to its *own* session's messages independently.

**This is the hardest coupling point** (see Q3). The `@Observable` change notification path for per-stream message updates needs redesign.

Additionally, `isAssistantTyping`, `typingSessionKey`, `shouldMorphTypingIndicator`, `isSending` — these are all stream-local concerns currently tracked as controller-globals on ChatViewModel. They're already causing bugs in multi-stream scenarios.

### Keyboard Handling

With multiple live scroll views, only the **visible** stream's CV should respond to keyboard frame changes. The `ChatLayoutCoordinator` currently handles this via `isActive` flags per session, and it already maintains `listViews: [String: WeakBox<MFCVC>]`. With show/hide:
- `applyLatestInset` should only animate the visible view
- `isActive` routing already exists in the coordinator

This is manageable but requires care during the show/hide lifecycle (the incoming view becomes active *before* it becomes visible, which can cause a premature inset application that jitters).

### Prewarm Loss

The current `TabView` approach "prewarms" adjacent pages by creating MFCV instances one page ahead. With show/hide, every stream is always warmed — no cold-load latency on first switch. **This is a benefit, not a risk**, except for the memory cost above.

### Diffable Data Source Ownership

Already one data source per MFCV instance. No change here. ✅

---

## Q3: What Makes This Harder Than It Sounds

### ChatViewModel Observation Pipeline

The biggest hidden complexity: **who drives `update()` on each MFCV?**

Currently, `ChatView` observes `viewModel.messages` (the active-stream copy) and calls `update()` on the active MFCV. With show/hide, all MCVCs are live simultaneously. You need *each* MFCV to trigger its own `update()` when its session's messages change.

Options:
1. **Each MFCV observes `viewModel.sessionMessages[ownSessionKey]`** — but `sessionMessages` is `private` and `@Observable` doesn't granularly observe dictionary keys (any key change redraws all observers).
2. **Expose a per-session `@Observable` message model** — requires introducing per-stream observable objects, which is a significant refactor.
3. **Broadcast notifications per session key** — works but is verbose.
4. **`ChatViewModel` posts a targeted update call** — requires a callback/delegate per MFCV registered by session key.

None of these is free. Option 4 (targeted update delegate) is the most compatible with the existing `update()` pattern but requires `ChatViewModel` to maintain a per-session MFCV callback registry.

### Two-Key Collapse and Active Session Semantics

The `uiSelectedSessionKey` / `engineActiveSessionKey` split was introduced because the pager debounce creates a gap between user intent and engine commit. With show/hide, the gap disappears (instant visibility change = instant engine activation).

But `activeSessionKey` / `engineActiveSessionKey` is still consumed by:
- Send routing (`outboundSessionKey`)
- Reconnect snapshot cursor
- Typing indicator binding
- Message failure tracking
- `lastServerMessageId` cursor

You can't just delete the key; you need to ensure all these consumers get the right value when streams switch instantaneously. The two-key discipline exposed that many of these readers were using the active key as a proxy for stream identity — work that remains valid but simplifies (all become one key again).

### `PerStreamRuntimeState` Ownership in a Non-Shared View

The `PerStreamRuntimeState` struct has `fingerprints`, `sizeCache`, `lastMeasuredSizes`, `bubbleSizingV2*` fields that are per-stream caches. With dedicated views, these can be held directly on the MFCV instance (no dictionary keying needed). This is a simplification — but it requires moving the struct from the MFCV's dictionary to being direct instance state on each MFCVC, which touches every read/write path.

The `PerStreamRuntimeState` migration work (the core of `per-stream-state-encapsulation.md`) is **still required** with either architecture. The switch-seam deletion is on top of that.

### Memory Pressure Eviction Brings Back Some Restore Complexity

The proposal says "evict under memory pressure." Eviction means tearing down the MFCV (removing from superview, deallocating). The next switch-to brings it back cold. This triggers:
- Scroll position restore (from UserDefaults) — same as today, but only on eviction
- Data source rebuild
- Layout measure pass

The restore is simpler than today's because it only happens on cold creation, not on every switch. But the two-phase restore logic (`pendingTail → pendingFullConfirmation`) may still be needed for evicted streams that rehydrate with a large message history (staged materialization is a separate concern that stays regardless).

### Input Bar / Keyboard Avoidance with Multiple Live Scroll Views

The input bar sends keyboard/inset updates to the active MFCV via `ChatLayoutCoordinator`. With all MCVCs live, inactive MCVCs must not react to keyboard frame changes. The `isActive` flag in the coordinator handles this, but there's a window during show/hide transition (between hiding A and showing B) where the inset update might hit neither, causing a visual glitch.

Precise ordering: `hide(A) → setActive(B) → setVisible(B)` must be atomic from UIKit's perspective.

### Diffable Data Source and `UICollectionView` Lifecycle During Hide

`UICollectionView` does not automatically suspend layout or diffable applies when hidden. An off-screen stream receiving new messages will still apply diffs and trigger layout. This can burn CPU in the background. You'd want to defer `update()` calls for hidden streams to avoid this — but deferral means you need a "catch-up" update when the stream becomes visible. That's a simpler version of the freeze/unfreeze pattern the current branch already has.

---

## Q4: Is This the Right Move?

**Short answer: Directionally yes, but not as a standalone refactor right now.**

### The Case For

1. **Eliminates ~441 lines of timing-sensitive code** that has been the source of T095, T103, T104, the T082 hang retro, the freeze/revert cycle, and the two-key split. These bugs have high recurrence cost.

2. **The scroll restore problem becomes trivial** for normal stream switches. Scroll position is live in the view — no write/restore needed. UserDefaults persistence is only for app relaunch and memory eviction (both rare events with simple triggers).

3. **The epoch/generation token system** (`RestoreAttemptToken`, `restoreGeneration`, `suspendScrollPersistenceUntilRestoreConfirmed`) exists entirely because of timing races with the pager animation. With show/hide, deferred-work guard rules simplify from "capture and validate a generation token" to "check if my view is still alive and my session key is unchanged."

4. **The two-key ChatViewModel split** collapses. `uiSelectedSessionKey` and `engineActiveSessionKey` diverge only because of the pager settle debounce. With show/hide, intent and engine activation are synchronous again.

5. **Future stream features are easier**: picture-in-picture, split-view, drag-to-rearrange all become possible when each stream is a self-contained view hierarchy.

### The Case Against (Right Now)

1. **The `PerStreamRuntimeState` migration isn't done.** The per-stream-state branch is implementing the correct encapsulation that's needed *regardless* of the show/hide decision. That work should ship first to establish the right ownership model.

2. **The observation pipeline redesign is non-trivial.** Each MFCV observing its own session's messages requires surfacing `sessionMessages` in a per-stream observable way. That's a `ChatViewModel` interface change that could break other things.

3. **Memory cost is real.** 3–5 streams is the common case, but the app supports unlimited streams. An eviction policy needs to be correct before this ships; evicting and restoring incorrectly will produce worse bugs than the current switch-seam code.

4. **The per-stream-state branch is mid-flight.** Switching the strategy now throws away significant work (the `runStreamContextSwitchSeam` and two-key split are the hard parts). Show/hide doesn't help unless the per-stream-state work is at least structurally complete.

### Recommended Path

1. **Finish the per-stream-state encapsulation** as currently specced. This is necessary regardless.
2. **Once `PerStreamRuntimeState` is stable**, evaluate a show/hide migration as a follow-on:
   - Replace `TabView` with explicit `ZStack` of `isHidden`-toggled views.
   - Eliminate `isRenderPolicyFrozen` and the pager interaction/settle path.
   - Collapse to single `activeSessionKey`.
   - Add lightweight update deferral for hidden views (simpler than the current freeze gate).
3. **Memory eviction policy** (LRU over N streams) must be designed before ship.

The show/hide move is architecturally correct and will pay for itself in deleted code and eliminated bugs. But the sequencing matters: per-stream-state-encapsulation first, then show/hide as the capstone simplification.

---

## Summary Table

| Seam Component | Location | Lines | With show/hide |
|---|---|---|---|
| `runStreamContextSwitchSeam` | MFCV | 46 | ✅ Delete |
| `prepareIncomingStateOnSwitch` | MFCV | 19 | ✅ Delete |
| `prepareSameKeyReread` | MFCV | 13 | ⚠️ Simplify (reconnect path stays) |
| `cancelDeferredWork` (switch path) | MFCV | ~10 | ✅ Delete switch trigger |
| `isRenderPolicyFrozen` guard + logic | MFCV | ~15 | ✅ Delete |
| `lastAppliedEffectiveSessionKey` | MFCV | ~8 | ✅ Delete |
| Zero-sections guard in `prepare()` | MessageFlowLayout | 10 | ✅ Delete |
| Two-phase scroll restore + generation tokens | MFCV | ~80 | ✅ Delete (simplify to single-phase on eviction) |
| `suspendScrollPersistenceUntilRestoreConfirmed` | MFCV | ~40 | ✅ Delete |
| `requestStreamSwitch` + debounce + epoch | ChatViewModel | ~140 | ✅ Delete / Simplify to 10 lines |
| Pager interaction/settle API | ChatViewModel | ~14 | ✅ Delete |
| `uiSelectedSessionKey/engineActiveSessionKey` split | ChatViewModel/ChatView | ~60 | ✅ Collapse to 1 key |
| **Total** | | **~455 lines** | |

**Risks to manage:** memory (eviction policy), observation pipeline redesign, keyboard inset ordering during show/hide transition.

**Sequencing:** Finish `per-stream-state-encapsulation.md` first. Show/hide is the capstone, not the foundation.
