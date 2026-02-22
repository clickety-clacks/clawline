# Adversarial Code Review: Commit `3c887bf2b` (Step 1 Cache Mutation Seam)

## Findings

1. **Spec-compliance risk: cache-family renames sidestep the explicit checklist/grep language instead of satisfying it directly.**
- The spec’s migration checklist and acceptance grep are written against `sizeCache`, `lastMeasuredSizes`, `bubbleSizingV2MeasurementCache`, `bubbleSizingV2KeysByMessageId`, `bubbleSizingV2LinkPreviewHeightCache`, `bubbleSizingV2LinkPreviewStateVersionByMessageId` (`efficient-flow-layout.md:266`, `efficient-flow-layout.md:304-311`).
- The implementation renamed all of these (`MessageFlowCollectionView.swift:95-117`), so the mandated grep now returns zero hits because names no longer exist, not because all writes were mechanically moved under the original identifiers.
- This is likely an embellishment relative to spec intent (#7 no-embellishment), because renaming was not required by Section 9.1.

2. **Contract mismatch: `writeMeasuredSize` does not implement the “nil if unchanged/within epsilon” contract.**
- Spec contract: `writeMeasuredSize(...) -> HeightDelta?` returns nil when unchanged or within epsilon threshold (`efficient-flow-layout.md:292-293`).
- Implemented method returns a delta whenever previous exists, including zero deltas (`MessageFlowCollectionView.swift:262-268`).
- Current callers often ignore the return value, so runtime behavior is likely unchanged today, but the seam contract is not implemented as specced.

## Requested Checks

1. **Every cache family in Section 9.2 routed through seam?**
- **Functionally: mostly yes.**
- `sizeCache`/`lastMeasuredSizes` equivalents (`cachedSizesById`, `measuredSizesById`) now write only through seam helpers (`readSizeState`, `writeMeasuredSize`, `clearSizeState`, `clearAllSizeState`) at `MessageFlowCollectionView.swift:253-312`.
- V2 measurement cache + key map equivalents write through seam helpers (`bubbleV2Measurement`, `recordBubbleV2Measurement`, `removeBubbleV2Measurements`, `clearAllBubbleV2State`) at `MessageFlowCollectionView.swift:332-347`, `MessageFlowCollectionView.swift:314-318`.
- Async preview cache/version writes flow through `recordAsyncPreview` / seam cleanup helpers at `MessageFlowCollectionView.swift:270-280`, `MessageFlowCollectionView.swift:320-321`.
- `dirtySizeIds` equivalent (`pendingInvalidatedSizeIds`) writes are routed via seam (`invalidateFor`, `consumePendingInvalidatedSizeIds`) at `MessageFlowCollectionView.swift:283-288`, `MessageFlowCollectionView.swift:350-353`.
- **Caveat:** renaming cache families makes this non-literal relative to Section 9.2 wording.

2. **Acceptance criterion #7 grep pass?**
- Ran exact grep from spec (`efficient-flow-layout.md:266`).
- Result: **no matches** (empty output).
- Literal criterion says “returns only hits inside seam methods”; current result is stronger syntactically but only because names were renamed.

3. **Seam method signatures consistent with Section 9.1 contracts?**
- `readSizeState(messageId, env) -> CachedMeasurement?`: **present** (`MessageFlowCollectionView.swift:253-259`), but env is currently ignored (`:255`).
- `writeMeasuredSize(messageId, measurement) -> HeightDelta?`: **present** (`MessageFlowCollectionView.swift:262-268`), but unchanged/epsilon-nil behavior is missing.
- `recordAsyncPreview(messageId, key, height) -> HeightDelta?`: **present** (`MessageFlowCollectionView.swift:270-280`) and includes epsilon gating.
- `invalidateFor(reason) -> InvalidationPlan`: **present** (`MessageFlowCollectionView.swift:283-300`) with required reason cases (`:238-244`).

4. **Zero behavior change?**
- **No obvious functional behavior regression found in diff review**, but I cannot assert strict parity due the rename-heavy refactor and contract mismatch noted above.
- Potential semantic drift areas:
  - `writeMeasuredSize` return semantics differ from spec contract (`MessageFlowCollectionView.swift:262-268`).
  - Acceptance gating now depends on renamed identifiers rather than original checklist names.

## Architecture Principles Check

1. **#1 Pattern propagation:**
- Positive: centralized seam methods are visible and likely to be copied (`MessageFlowCollectionView.swift:229-354`).
- Risk: renaming cache families weakens continuity with spec/checklist language and may confuse future agents reading Section 9.2.

2. **#6 State mutation seam discipline:**
- Improved substantially: write paths for targeted cache state now consolidate through seam methods.
- Remaining caveat: because names changed, auditability vs. the explicit 9.2 table is weaker.

3. **#7 No embellishment:**
- Potential violation: bulk renaming of cache fields was not required by Step 1 and appears to be an implementation-side workaround to acceptance grep wording.

## Additional Explicit Checks

1. **Any direct cache writes survived outside seam?**
- For the renamed cache fields, direct write operations appear concentrated in seam helper block (`MessageFlowCollectionView.swift:253-354`).
- Old-name direct writes do not exist (grep empty).

2. **Comment-level invariant exists?**
- Yes: `// Invariant: All bubble cache mutations go through this seam.` at `MessageFlowCollectionView.swift:230`.

3. **Did tests pass?**
- **No.** `test_sim` failed with unrelated pre-existing compile errors in `ios/Clawline/ClawlineTests/ChatLayoutCoordinatorTests.swift` (missing `pageIndicatorClearance` argument), so gate is not satisfied.

## Bottom Line
- Step 1 seam consolidation is largely in place, but this is **not cleanly spec-compliant yet** because:
  1. cache-family renames deviate from spec/checklist intent,
  2. `writeMeasuredSize` contract does not fully match Section 9.1,
  3. tests did not pass.
