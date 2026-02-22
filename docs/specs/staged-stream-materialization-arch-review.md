# Architecture Review: Staged Stream Materialization

**Reviewer:** Adversarial arch review (subagent)
**Date:** 2026-02-18
**Spec:** `staged-stream-materialization.md`
**Verdict:** REVISE

---

## Principle Review

### 1. Pattern Propagation — **Pass**
The staged tail-first pattern is clean and generalizable. Future agents encountering similar "too much data in one shot" problems can copy this approach. The stage/epoch/cancel pattern composes well with the existing epoch cancellation from the UI/engine separation spec.

### 2. Right-Weight — **Fail**
The spec bundles three independent concerns (staged apply, no-op suppression, warm cache) into one spec. Each has different risk profiles and can ship independently. This increases review surface and implementation risk unnecessarily.
**Change needed:** Split into one spec (staged apply) with no-op suppression and warm cache as separate follow-on specs.

### 3. Separation of Concerns — **Pass**
Staged materialization lives cleanly inside the engine-active render path. It doesn't re-couple UI intent to heavy work. The spec correctly identifies that it operates after `engineActiveSessionKey` commit, preserving the UI/engine boundary.

### 4. Paired Deliverables — **Warning**
The spec addresses the performance regression (first-visit stall) but doesn't include an architecture retro explaining why full-history apply was the original design. Understanding *why* it was done that way prevents future agents from accidentally reverting to full-snapshot behavior.
**Change needed:** Add a brief "Why it was this way" section or reference to a retro.

### 5. Refactor Workflow — **Pass**
Spec-first, requesting review before implementation. Correct workflow.

### 6. State Mutation Seam Discipline — **Warning**
The spec introduces new state (materialization stage metadata, warm cache, expansion lifecycle) but doesn't define mutation seams with the same rigor as the UI/engine separation spec. Who owns the stage metadata? What's the single write path for advancing stages? Can a new message arrival and an expansion stage race on the snapshot?
**Change needed:** Add explicit mutation seam table for new state: stage metadata owner, single write path for stage advancement, and ordering guarantee between incoming messages and expansion applies.

### 7. No Embellishment — **Fail**
Two of the three components are embellishment given measured data:
- **No-op apply suppression:** Measured cost is 0.2-1.6ms for `changed=0` applies. This is sub-millisecond. Optimizing this saves nothing perceptible and adds code complexity. The spec's own framing ("eliminates repeated apply/layout churn") overstates the problem.
- **Warm cache:** Revisited streams are already smooth per instrumentation. The spec acknowledges this ("Revisited streams are smooth (already materialized)"). Adding an LRU cache with eviction policy is solving a problem that doesn't exist yet.
**Change needed:** Remove sections 2 and 3 entirely. Ship staged apply only. If no-op suppression or warm cache become needed later, spec them separately with data justifying the work.

---

## Specific Questions

### Staged window sizing (why 100?)
**Not justified.** The spec says "for example last N=100 messages; exact N configurable" — this is hand-waving. Given the measured data (500 items = 1.4-2.7s), linear extrapolation suggests 100 items ≈ 280-540ms. That's still perceptible. Should this be 50 (≈140-270ms, under perceptual threshold)? The spec needs measured or reasoned justification for the initial window size, not "for example."

### Expansion strategy (100 → 250 → full)
**Arbitrary.** No rationale for why three stages, why these sizes, or why not just two (tail → full with a RunLoop idle dispatch). The intermediate 250 stage adds complexity — what's the measured benefit over going straight to full after first paint? This needs data or at least a stated hypothesis.

### Unread markers and anchor preservation
**Adequate but underspecified.** The spec correctly identifies the edge case (unread marker outside tail window) and states the requirement (don't clear unread state). However, it doesn't specify *how* the unread marker position is communicated to the UI when expansion brings it into view. "Anchor/indicator behavior must remain correct" is a requirement, not a design. Given this is a known hard problem in chat UIs, more detail is warranted.

### No-op apply suppression needed?
**No.** 0.2-1.6ms is noise. Remove it.

### Warm cache in this spec?
**No.** Revisits are already smooth. Separate spec if data shows a regression.

### Interaction with UI/engine separation
**Safe.** The spec correctly scopes all staged work inside the engine commit path. The epoch cancellation from the parent spec handles mid-expansion stream switches. No re-coupling risk.

### Risk of visible content jumping during expansion
**Underspecified.** The spec says "preserve viewport anchor using existing anchor compensation primitives" but doesn't confirm these primitives exist and work for prepending content above the viewport. Prepending messages above current scroll position is notoriously tricky with `UICollectionView` — the spec should confirm the specific API or technique (e.g., `contentOffset` adjustment in `performBatchUpdates` completion, or `UICollectionViewLayout.targetContentOffset`).

### New messages during staged expansion
**Addressed but fragile.** The spec says "new messages append to current stage snapshot correctly" and "expansion should merge without dropping or duplicating message IDs." This is stated as a requirement, not a mechanism. The interaction between an in-flight expansion apply and a concurrent new-message apply on the same diffable data source needs a concrete ordering guarantee (serial dispatch? epoch check? snapshot queuing?).

---

## Summary of Required Changes

1. **Remove sections 2 (no-op suppression) and 3 (warm cache).** They are embellishment unsupported by data.
2. **Justify or instrument the window size.** Don't ship "for example 100" — pick a number with reasoning, or spec an instrumentation pass to find the right number.
3. **Simplify expansion to two stages** (tail → full) unless there's a measured reason for three. Less state, fewer edge cases.
4. **Add mutation seam table** for stage metadata and expansion lifecycle state.
5. **Specify the anchor preservation mechanism** for content prepended above viewport.
6. **Specify ordering guarantee** between expansion applies and incoming message applies.

## Verdict: **REVISE**

The core idea (staged tail-first apply) is sound and well-motivated by data. But the spec is 60% good idea and 40% embellishment/underspecification. Strip it to the one thing that matters (staged apply), nail the edge cases with mechanisms not just requirements, and it's an approve.
