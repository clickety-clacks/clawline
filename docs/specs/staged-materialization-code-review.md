# Staged Stream Materialization — Adversarial Code Review

**Date:** 2026-02-18
**Reviewer:** Subagent (adversarial, cross-model)
**Spec:** `staged-stream-materialization.md`
**Diff:** Single file: `MessageFlowCollectionView.swift`

---

## Verdict: **REVISE**

Two blocking issues (one correctness risk, one spec gap) and several warnings.

---

## Spec Compliance

### ✅ Two stages only (tail N=50 → full)
`MaterializationStage` has exactly `.tail` and `.full`. `stagedMaterializationTailWindowCount = 50`. Pass.

### ✅ Single `advanceMaterialization` mutation seam
All state mutations to `materializationStateBySessionKey` go through `advanceMaterialization(sessionKey:event:)`. The queue wrapper (`enqueueMaterializationEvent` → `processMaterializationEventQueue` → `advanceMaterialization`) enforces FIFO ordering. No direct writes outside the seam.

### ⚠️ Anchor preservation — partially implemented
The diff hooks into `captureBubbleSizingV2ViewportAnchor()` and `scheduleBubbleSizingV2ViewportAnchorCompensation()` for expansion applies. This reuses existing anchor infrastructure rather than implementing the spec's explicit `(anchorMessageId, anchorFrameMinY, contentOffsetY)` tuple with `contentOffset.y += (newMinY - oldMinY)`.

**Question:** Does `captureBubbleSizingV2ViewportAnchor` implement equivalent offset compensation? The diff doesn't show that function's body. If it does explicit offset math, this is fine. If it's heuristic-based (e.g., `scrollToItem`), it violates the spec's "explicit contentOffset compensation, not heuristic scrolling" requirement.

**Action needed:** Confirm the existing anchor function does concrete offset compensation, or implement the spec's explicit mechanism.

### ✅ New messages during expansion handled through seam
Append events go through `enqueueMaterializationEvent` → same FIFO queue. When in `.tail` stage, `messagesUpdated` recalculates tail bounds. When in `.full` stage, full snapshot is used. No bypass path.

### ✅ Unread marker outside tail window
`isUnreadOutsideTailWindow` correctly checks if unread ID index falls outside tail bounds. The unread-clearing guard in the visibility checker prevents premature clearing during tail stage. Unread state is preserved.

### ✅ Small streams bypass staging
`totalCount <= stagedMaterializationTailWindowCount` → immediate `.full` stage. Correct.

### ⚠️ Comments — adequate but not ample
Comments explain WHAT but several miss WHY:
- The `expansionState` transition from `.pendingFull` → `.idle` during `messagesUpdated` has a comment ("Gate scheduling so only one tail->full promotion") but doesn't explain WHY only one is needed.
- `isFirstActivationForSession` as the `allowTailStage` gate has no comment explaining why revisits skip staging.
- The `guard var state` fallback after the `if state == nil` block is defensive but uncommented — why could state still be nil there? (It can't, but the compiler doesn't know.)

---

## Architecture Principles

| # | Principle | Verdict | Notes |
|---|-----------|---------|-------|
| 1 | Pattern propagation | ✅ Pass | Reuses existing snapshot/apply patterns, anchor infrastructure, epoch checks |
| 2 | Right-weight | ✅ Pass | Minimal new types. No unnecessary abstraction layers |
| 3 | Separation of concerns | ✅ Pass | Staged logic is self-contained in MFCVC. No ViewModel changes. No ownership shifts |
| 4 | Paired deliverables | ⚠️ Warning | No test or validation artifact paired with this. Spec mentions validation notes but no test plan in diff |
| 5 | Refactor workflow | ✅ Pass | Additive changes, no destructive refactoring |
| 6 | State mutation seam discipline | ✅ Pass | Single seam enforced. Queue serialization prevents races |
| 7 | No embellishment | ✅ Pass | Nothing beyond spec scope |

### Mutation seam enforcement
**Can anything bypass `advanceMaterialization`?** No. The only writes to `materializationStateBySessionKey` are inside `advanceMaterialization`. The queue processing is guarded by `isMaterializationQueueProcessing` reentrance flag. Clean.

One concern: `lastMaterializationPlanBySessionKey` is written outside `advanceMaterialization` (in `processMaterializationEventQueue`). This is the plan cache, not the stage state, so it's acceptable — but it means there are two dictionaries to keep in sync. Low risk.

### UICollectionView consistency risk
**🔴 BLOCKING ISSUE #1: `messagesById` populated with full messages, snapshot has tail-only IDs.**

In the `update` method:
```swift
messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
```
This populates `messagesById` with ALL messages. But the snapshot only contains tail-window IDs. If `cellForItemAt` or any cell configuration looks up a message by ID from the snapshot, that's fine — the ID exists in both. But if any code iterates `messagesById` assuming it matches the snapshot, there's a mismatch.

More critically: `reconfigureItems(changedIds)` filters to `materializedIdSet` — good. But the fingerprint dictionary update:
```swift
changedIds.forEach { id in
    if let fp = newFingerprints[id] { fingerprints[id] = fp }
}
```
Only updates fingerprints for materialized+changed items. On expansion to full, items that were never in the tail won't have fingerprint entries, so they'll all be "changed" on the first full pass. This means the full-expansion apply will reconfigure ALL items (the entire history), which is correct but means the expansion apply is as expensive as the original full apply for reconfiguration. This may partially negate the perf win if `needsFullLayout` is true during expansion.

**Severity:** Medium. Not a crash risk, but could reduce the effectiveness of the optimization during expansion. The FIRST paint is still fast (that's the goal), so this may be acceptable.

**Revised assessment:** Not blocking. The goal is fast first paint, not fast expansion. Downgrading to warning.

### 🔴 BLOCKING ISSUE: Stale `totalCount` and `fullMessageIds` in promotion closure

In `scheduleTailToFullPromotionIfNeeded`, the promotion fires on the next runloop turn. But it captures `totalCount`, `firstUnreadMessageId`, and `fullMessageIds` from the TAIL stage's `update` call:

```swift
if materializationPlan.scheduleTailToFullPromotion {
    self.scheduleTailToFullPromotionIfNeeded(
        sessionKey: effectiveSessionKey,
        totalCount: messageCount,        // ← captured at tail-stage time
        firstUnreadMessageId: firstUnreadMessageId,
        fullMessageIds: fullMessageIds    // ← captured at tail-stage time
    )
}
```

If a new message arrives between tail render and promotion dispatch, the `tailRendered` event will carry the OLD `totalCount` and `fullMessageIds`. The `advanceMaterialization` seam will compute `WindowBounds(lowerBound: 0, upperBound: oldTotalCount)`, missing the new message.

**However:** `runMaterializationRefreshPass()` calls `update()` which re-fetches `viewModel.messages` — so the snapshot will include the new message. But the `advanceMaterialization` state will have stale bounds. The snapshot will have `newCount` items but the plan says `upperBound: oldCount`.

Wait — looking more carefully: `runMaterializationRefreshPass` calls `update`, which calls `enqueueMaterializationEvent(.messagesUpdated(...))` with FRESH data. The `.tailRendered` event from the promotion fires first (it's already enqueued), then the `.messagesUpdated` from the refresh pass fires. But actually — the promotion enqueues `.tailRendered` and if it returns `isTailToFullExpansionApply`, it calls `runMaterializationRefreshPass` which triggers another `update` → another `.messagesUpdated`. So there are TWO events: the stale `.tailRendered` transitions state to `.full`, then the fresh `.messagesUpdated` updates with current data.

The `.tailRendered` with stale count transitions to `.full` with `upperBound: oldCount`. Then `runMaterializationRefreshPass` → `update` → `.messagesUpdated` with fresh count → already in `.full` stage → updates to `upperBound: newCount`. The second apply has the correct data.

**But:** The first apply (from `.tailRendered` path) doesn't directly apply a snapshot — it just returns a plan. The actual snapshot apply happens in `runMaterializationRefreshPass` → `update`, which gets fresh data. So there's no stale snapshot applied.

**Revised assessment:** Not blocking after tracing the full flow. The stale data in `.tailRendered` only affects the seam's internal state momentarily; the actual snapshot is always built from fresh `viewModel.messages`. Downgrading to **warning** — the stale event parameters are misleading but not incorrect because the refresh pass immediately follows with fresh data.

### UI/engine separation
No changes to `uiSelectedSessionKey` or `engineActiveSessionKey` ownership. Staged materialization starts only after engine activation (checked via `isActiveSession` and session key matching). Clean.

---

## Regressions

### ⚠️ `messagesById` contains unmaterialized messages during tail stage
Any code that iterates `messagesById.keys` and assumes all are in the collection view will get items that don't have index paths. This is existing behavior for empty states but worth auditing callers.

### ✅ Fingerprint/reconfigure filtering
The `materializedIdSet.contains` filter on `changedIds` prevents reconfiguring items not in the snapshot. This was a potential crash vector (reconfiguring non-existent items) and it's correctly handled.

### ✅ Epoch/session-switch safety
`scheduleTailToFullPromotionIfNeeded` checks `isActiveSession` and session key match before firing. If user switches streams during expansion, the promotion is dropped. Correct.

---

## Edge Cases

### Stream deletion during expansion
If the stream is deleted, `viewModel.messages` returns empty → `totalCount: 0` → state set to `.full` with empty bounds. Safe.

### Rapid switches during expansion
Promotion closure checks session key match. If user switched away, promotion is dropped. If user switches back, it's a new activation (`isFirstActivationForSession` will be false since state exists) → goes to `.full` directly. This means a switch-away-switch-back loses the staging optimization, which is correct (revisits should be fast anyway).

### ⚠️ State accumulation
`materializationStateBySessionKey` is never cleaned up. Over a long session visiting many streams, this dictionary grows unboundedly. Low severity (small structs) but worth a cleanup on deactivation.

---

## Embellishment Check
No embellishment found. Every addition maps to a spec requirement.

---

## Summary of Required Changes

### Must fix before approve:
1. **Confirm anchor compensation mechanism** — verify `captureBubbleSizingV2ViewportAnchor` / `scheduleBubbleSizingV2ViewportAnchorCompensation` implements concrete offset compensation per spec (not heuristic scrolling). If it does, document why it satisfies the spec requirement. If not, implement the spec's explicit `contentOffset.y += (newMinY - oldMinY)` approach.

### Should fix:
2. Add WHY comments on: `isFirstActivationForSession` gate, `pendingFull → idle` transition, the defensive `guard var state` fallback.
3. Add cleanup of `materializationStateBySessionKey` entries on stream deactivation or session removal.
4. Document (even as a code comment) that stale parameters in the `.tailRendered` event are harmless because `runMaterializationRefreshPass` immediately follows with fresh data.

---

## Verdict: **REVISE**

The mutation seam is clean, spec compliance is strong, and there are no crash-risk regressions. The single blocking question is whether the anchor compensation reuse actually implements the spec's explicit offset math. If confirmed, this moves to APPROVE with the comment improvements as nice-to-haves.
