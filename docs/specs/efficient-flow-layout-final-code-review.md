# T085 Final Adversarial Code Review (Steps 1-4)

Scope reviewed:
- Commits `3c887bf2b..46fa718a0` (`git diff f2ede077a..HEAD`)
- Spec: `/Users/mike/shared-workspace/clawline/specs/efficient-flow-layout.md`
- Architecture principles: `~/.codex/skills/architecture-principles/SKILL.md`

## Blocking Findings

1. **Y-shift path is functionally incorrect: `rowDelta` is computed as zero in the normal case, so downstream rows are not shifted.**
- Code path: `applyMeasuredSize` -> `executeInvalidationPlan(.remeasureAndShift)` -> `flowLayout.invalidateLayout(mode: .itemHeightChange)` -> `MessageFlowLayout.prepare()` -> `applyItemHeightChange(index:delta:)`.
- In `applyItemHeightChange`, the changed cell frame is mutated first, then both `oldRowHeight` and `newRowHeight` are derived from the already-mutated row snapshot:
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2941`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2945`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2946`
- Result: for a row where the changed item determines row height, `oldRowHeight == newRowHeight`, `rowDelta == 0`, and items below are not moved.
- Spec impact: violates Section 5.3 and Step 4 requirement to "add delta to y-position of all items below"; risks overlaps/gaps (AC#3).

2. **Bottom inset policy still violates the spec’s deferred/zero-invalidation requirement.**
- Spec Section 6.1 requires no immediate layout recalc/invalidation on bottom inset change.
- Current code still immediately processes affected IDs and schedules full rebuild invalidation per ID:
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:620`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:642`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:644`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:320`
- Spec impact: AC#2 fails in current implementation.

3. **Scroll-anchor preservation is not applied for the new `.remeasureAndShift` path.**
- Spec Step 4 says preserve scroll anchor using existing compensation mechanism.
- Existing anchor capture/compensation is used only in BubbleSizingV2 remeasure flush path (`captureBubbleSizingV2ViewportAnchor` + `scheduleBubbleSizingV2ViewportAnchorCompensation`) around invalidation/reconfigure, not in `.remeasureAndShift` execution.
  - Anchor functions: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2517`, `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2545`
  - `.remeasureAndShift` execution: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:310`
- Spec impact: AC#4 is not demonstrated and is at risk for non-V2 height changes.

## Major Findings

4. **Step 3 "callers do not decide invalidation policy" is only partially achieved.**
- Centralization exists (`invalidateFor`, `executeInvalidationPlan`), but callers still choose behavior by constructing plan payloads directly (`.remeasureAndShift`) and by manually mixing policy actions (`scheduleReconfigure`, V2 cache invalidation) outside `invalidateFor`.
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2741`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:642`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:798`
- This is not a single policy decision point in the strict sense requested by Step 3.

5. **Spec edge case 7.1 (multiple simultaneous height changes in one pass) is not implemented.**
- `.remeasureAndShift` executor explicitly requires exactly one change; otherwise it falls back to full invalidation path.
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:311`
- If batch height changes occur together, the single-pass accumulated-delta behavior from Section 7.1 is absent.

## Moderate Findings

6. **AC#7 literal grep criterion is not satisfied as written.**
- Required command returns hits outside seam methods (declarations and reads at top of file), e.g. lines 98-101.
- Command run:
  - `grep -nE 'sizeCache\[|sizeCache\.remove|lastMeasuredSizes\[|lastMeasuredSizes\.remove|bubbleSizingV2MeasurementCache|bubbleSizingV2KeysByMessageId|bubbleSizingV2LinkPreviewHeightCache|bubbleSizingV2LinkPreviewStateVersion' ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- Practical seam integrity appears enforced by the added test (`MessageFlowCacheSeamIntegrityTests`), but AC#7 text says grep should return only seam-method hits.

## Step-by-Step Compliance Check

### Step 1 (Section 9.1)
- **Spec compliance:** Partial pass.
  - Required seam methods exist with expected signatures: `readSizeState`, `writeMeasuredSize`, `recordAsyncPreview`, `invalidateFor`.
  - Comment invariant exists: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:230`.
  - Cache writes are largely routed through seam helper methods.
- **Architecture:** Mostly pass on principle #6 (mutation seam), with improved pattern propagation.
- **Risk:** AC#7 literal grep mismatch remains.

### Step 2 (Section 9.3 step 2)
- **Spec compliance:** Pass.
  - Seam integrity test added: `ios/Clawline/ClawlineTests/MessageFlowCacheSeamIntegrityTests.swift`.
- **Architecture:** Pass (boundary invariant test supports seam discipline).
- **Risk:** Test depends on seam block textual boundaries (`MARK` + `viewDidLayoutSubviews` sentinel), which is brittle to unrelated refactors.

### Step 3 (Section 9.3 step 3)
- **Spec compliance:** Partial pass.
  - `InvalidationReason` and `InvalidationPlan` enums added with requested cases.
  - `invalidateFor(reason)` returns plan.
  - But callers still contain policy choices not fully centralized (see Major Finding #4).
- **Architecture:** Partial pass on principle #6 (improved but not strict single-policy seam).

### Step 4 (Section 9.3 step 4 / Section 5.3)
- **Spec compliance:** Fail (blocking).
  - Added invalidation mode and incremental path, but row-shift math bug prevents correct downstream movement (Blocking #1).
  - Bottom-inset invalidation behavior remains contrary to Section 6.1 (Blocking #2).
  - Anchor preservation not clearly applied to `.remeasureAndShift` path (Blocking #3).
- **Architecture:** Added optimization path, but correctness regression outweighs performance gain.

## Acceptance Criteria Check (Section 8)

- **AC#7 (seam integrity grep):** **Fail (literal criterion).**
  - Grep returns non-seam hits (declarations/reads outside seam block).
- **AC#7 (practical mutation seam):** **Pass** via `MessageFlowCacheSeamIntegrityTests` (mutation-only patterns scoped to seam block).
- **Simulator-testable unit checks run:**
  - `ClawlineTests/MessageFlowCacheSeamIntegrityTests` passed.
  - `ClawlineTests/BubbleScrollTests` passed.
  - `ClawlineTests/ScrollToBottomUnreadTests` passed.
- **Full `ClawlineTests`:** **Fail (pre-existing/unrelated in this diff)**
  - `ChatViewModelTests` -> "Outbound sends respect active session selection" (`ChatViewModelTests.swift:696`).

## Architecture-Principles Compliance Summary

- **#1 Pattern propagation:** Improved; seam pattern is now visible and test-backed.
- **#6 State mutation seam discipline:** Improved but incomplete at invalidation-policy level.
- **#7 No embellishment:** No major unspecced subsystem added; changes are mostly in-spec. Main issue is not embellishment but correctness/policy mismatches against explicit spec sections.

## Bottom Line

This range is **not implementation-ready** due to blocking correctness/policy issues in Step 4 and unresolved AC mismatch in Section 8 (#7 literal grep and #2 bottom-inset invalidation behavior).
