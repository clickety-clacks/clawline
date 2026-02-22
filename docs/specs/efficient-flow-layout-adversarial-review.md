# Adversarial Review: `efficient-flow-layout.md`

## Verdict
Not implementation-ready. The spec has multiple blocking inaccuracies about current architecture and at least one core algorithmic assumption that is false in the target code.

## Blocking Findings

1. **Core model is wrong: layout is not a 1D fixed-width vertical list.**
- Spec claims: "Chat bubble layout is effectively a one-dimensional vertical list" and "Width is fixed" (`efficient-flow-layout.md:17-23`).
- Code reality:
  - `MessageFlowLayout.prepare()` packs items in flow rows with wrapping (`MessageFlowCollectionView.swift:2696-2708`), not a strict single-column stack.
  - Width is message-dependent (`maxItemWidth`, `mediumMaxWidth`) and can vary across items (`MessageFlowCollectionView.swift:1340-1368`, `MessageFlowCollectionView.swift:2028-2076`).
- Why this blocks implementation:
  - Proposed "remeasure one + y-shift all below" (`efficient-flow-layout.md:150-158`) is invalid for multi-item rows.
  - If an item's height changes and it is not row-max height, downstream `delta` may be zero; if width changes, row breaks/reflow can change both x and y for many items.

2. **Spec overstates "full remeasurement" and misdiagnoses where O(n) cost comes from.**
- Spec says single height changes trigger O(n) remeasurement across all items (`efficient-flow-layout.md:11-14`).
- Code reality:
  - `prepare()` does iterate all items and request `sizeForItemAt` (`MessageFlowCollectionView.swift:2691-2694`).
  - But remeasurement is heavily cached:
    - V1 path returns `sizeCache[id]` early (`MessageFlowCollectionView.swift:1547-1550`).
    - V2 path returns `bubbleSizingV2MeasurementCache` early via key lookup (`MessageFlowCollectionView.swift:1784-1792`).
- Risk:
  - Optimization may be aimed at eliminating remeasurement that is often already avoided, while still leaving full attribute rebuild and per-item delegate dispatch cost unaddressed.
  - Acceptance criterion #1 ("does not call `sizeForItemAt` for any other item", `efficient-flow-layout.md:236-237`) is stricter than current architecture and requires a deeper redesign than spec acknowledges.

3. **Trigger inventory is incomplete and inaccurate.**
- Spec says six recalculation triggers (`efficient-flow-layout.md:83-98`).
- Missing real triggers in current code:
  - Appearance change (`isDark`) clears caches + forces reconfigure (`MessageFlowCollectionView.swift:546-551`).
  - Session change (`previousSessionKey != sessionKey`) is part of full-layout decision (`MessageFlowCollectionView.swift:565-568`).
  - Bounds changes also come through layout invalidation path (`shouldInvalidateLayout(forBoundsChange:)`, `MessageFlowCollectionView.swift:2739-2745`) in addition to controller path.
- Consequence:
  - Proposed invalidation classes and sequencing are based on an incomplete trigger map, violating separation-of-concerns-first (architecture principle #3).

4. **Section contradiction on recalculation timing.**
- Section 2.2 states capped bubbles should only recalc when visible **and scrolling has stopped** (`efficient-flow-layout.md:38-43`).
- Section 6.2 prescribes immediate targeted update on top inset change (`efficient-flow-layout.md:188-190`) with no rest-state requirement.
- This is internally inconsistent and leaves implementation behavior undefined for top-inset changes during scroll/animation.

5. **Mutation seam scope is incomplete; proposed verification is insufficient.**
- Spec frames six cache families as the state surface (`efficient-flow-layout.md:249-284`) and validates with a grep pattern list (`efficient-flow-layout.md:242-243`).
- But size/layout state mutation also flows through:
  - `dirtySizeIds` + `scheduleLayoutInvalidation` mutation path (`MessageFlowCollectionView.swift:2247-2250`, `MessageFlowCollectionView.swift:2621-2636`).
  - Layout-owned caches/state (`cachedAttributes`, `cachedContentSize`, `needsRebuild`, signature) (`MessageFlowCollectionView.swift:2647-2650`, `MessageFlowCollectionView.swift:2678-2713`, `MessageFlowCollectionView.swift:2729-2736`).
- Consequence:
  - "All bubble cache mutations go through seam" is not actually guaranteed by the proposed checklist.

## Important Risks

1. **Step sequencing does not match data-model realities (index vs ID).**
- Proposed invalidation API is index-based (`itemHeightChange(index: Int, delta: ...)`, `efficient-flow-layout.md:129-134`), while controller mutation and diffable operations are message-ID based (`scheduleReconfigure(for:)`, snapshot operations; `MessageFlowCollectionView.swift:2541-2552`, `MessageFlowCollectionView.swift:598-644`).
- Insertions/deletions/typing-indicator injection can shift indices between plan creation and layout application (`MessageFlowCollectionView.swift:603-615`).
- Spec does not define an index-stability contract.

2. **"Measure-once permanent" assumption is too strong for current system.**
- Spec claims most bubbles are permanent after first measurement (`efficient-flow-layout.md:25-35`).
- Current V2 cache keys include environment + metrics fingerprint (`BubbleSizingV2.swift:63-69`, `BubbleSizingV2.swift:221-234`) and layout fingerprint inputs (`MessageFlowCollectionView.swift:1809-1823`), so trait/inset/metrics shifts can invalidate cached measurements even without message-content changes.
- Also message fingerprints include streaming/attachments (`MessageFlowCollectionView.swift:2235-2243`), so many messages are not stable during generation.

3. **Bottom-inset strategy conflicts with current user-protection behavior.**
- Spec says "No immediate layout recalculation" on bottom inset (`efficient-flow-layout.md:181-186`).
- Current V2 path intentionally batches/debounces and gates flush near bottom + scroll rest to avoid reflow while user reads (`MessageFlowCollectionView.swift:2368-2448`).
- Spec does not reconcile whether off-bottom users should ever receive deferred correction, and when stale geometry is acceptable if they never return near bottom.

4. **Anchor-preservation reuse is underspecified for non-local reflow.**
- Spec says no anchor changes needed (`efficient-flow-layout.md:172-177`).
- Current anchor picks first fully visible cell only (`MessageFlowCollectionView.swift:2490-2504`); if none qualifies, compensation is skipped.
- For broader reflow scenarios (row rewrap / multiple changed indices), this may not preserve visual stability.

## Missing Edge Cases

1. **Multi-item row interactions**
- Height delta behavior when changed cell is not tallest in row.
- Height delta behavior when changed cell becomes tallest and row-height increases.

2. **Width-change induced reflow**
- Any width delta (not just height) can alter wrap points and invalidate simple tail-shift assumptions.

3. **Typing indicator as extra item**
- Dynamic insertion/removal of `TypingIndicatorCell.itemId` changes item order/count (`MessageFlowCollectionView.swift:603-615`) and can invalidate index-based delta plans.

4. **Trait/appearance changes beyond compactness**
- `preferredContentSizeCategory` contributes to metrics fingerprint (`BubbleSizingV2.swift:233`), but spec only calls out compactness/rotation as "full rebuild" triggers.

5. **Concurrent batch updates + pending remeasure queue**
- `bubbleSizingV2PendingRemeasureIds` flushes asynchronously (`MessageFlowCollectionView.swift:2452-2468`); spec does not define conflict resolution with simultaneous diffable snapshot mutations.

## Architecture-Principles Compliance Gaps

1. **Separation of concerns (#3) not satisfied yet**
- Spec's architecture description is incomplete (missing triggers/state paths), so ownership boundaries are not fully mapped before prescribing optimization.

2. **State mutation seam discipline (#6) only partially addressed**
- Proposed seam omits active mutation surfaces (`dirtySizeIds`, layout internal cache state), so the "single mutation point" claim is not currently enforceable.

3. **Right-weight architecture (#2) is at risk**
- Introducing index-based invalidation classes plus optional cumulative-offset layer (`efficient-flow-layout.md:127-168`) before resolving row/wrap correctness risks adding complexity on a faulty base model.

## Questions That Must Be Resolved Before Implementation

1. Is the target layout model truly single-column? If not, how does incremental update handle row wrapping and width-driven reflow correctly?
2. Is the actual performance bottleneck remeasurement, attribute rebuild, snapshot reconfigure, or a combination? Where is the measured breakdown?
3. What is the canonical invalidation identity: message ID or index? How is stability guaranteed across diffable updates?
4. Should seam consolidation include `dirtySizeIds` and layout-owned state, or is this explicitly out of scope?
5. What are exact rules for deferred remeasure when user is not near bottom for extended periods?
