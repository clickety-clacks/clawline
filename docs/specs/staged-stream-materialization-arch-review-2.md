# Architecture Review 2: Staged Stream Materialization (Revised)

**Reviewer:** Adversarial arch review (subagent)
**Date:** 2026-02-18
**Spec:** `staged-stream-materialization.md` (revised)
**Prior review:** `staged-stream-materialization-arch-review.md`
**Verdict:** APPROVE

---

## First Review Findings — Disposition

| # | Finding | Addressed? |
|---|---------|------------|
| 1 | Remove no-op suppression and warm cache (Right-Weight / No Embellishment) | ✅ Both explicitly listed under Non-Goals. Spec is staged-apply only. |
| 2 | Justify window size with math | ✅ N=50 justified from measured 500-item timings via linear extrapolation (140–270ms target). |
| 3 | Simplify expansion to 2 stages | ✅ Exactly two stages: tail → full. No intermediate 250 stage. |
| 4 | Add mutation seam table | ✅ Owned state enumerated, single write seam (`advanceMaterialization`), ordering guarantee via serialized MainActor dispatch. |
| 5 | Specify anchor preservation + ordering mechanisms concretely | ✅ Anchor: explicit `(anchorMessageId, anchorFrameMinY, contentOffsetY)` capture + offset compensation. Ordering: single serialized seam, epoch cancellation for stale work. New messages queued into same seam. |

All five findings addressed.

---

## Principle Review

| Principle | Status |
|-----------|--------|
| 1. Pattern propagation | **Pass.** Tail-first staged pattern is clean and reusable. |
| 2. Right-weight | **Pass.** Single concern (staged apply). No cache, no suppression. |
| 3. Separation of concerns | **Pass.** Operates after engine commit; no UI/engine re-coupling. |
| 4. Paired deliverables | **Pass.** "Why Current Design Existed" section added per review. |
| 5. Refactor workflow | **Pass.** Spec-first, reviewed before impl. |
| 6. State mutation seam discipline | **Pass.** Single seam method, owned state explicit, no external writes. |
| 7. No embellishment | **Pass.** Stripped to exactly what's needed. |

---

## New Issues Introduced by Revision

None blocking.

### Nits (non-blocking)

1. **Linear extrapolation assumption.** The 50-item estimate assumes linear cost scaling. UIKit diffable apply has some fixed overhead, so actual savings may be slightly less than 10×. Not blocking — instrumentation during rollout will validate, and the spec already calls for measuring tail-stage apply duration.

2. **Full-stage apply still blocks main thread.** The spec moves the big apply to after first paint, which is correct, but a 500-item apply still takes 1.4–2.7s on main thread during the full stage. User scrolling up during that window could hitch. This is an acceptable tradeoff for v1 (first paint is the priority), but worth noting for a future background-apply follow-on if needed.

3. **`expansionLifecycleBySessionKey` cleanup.** Spec doesn't mention when entries are removed from the three dictionaries (e.g., on stream deletion or session teardown). Minor — impl agent can handle this, but worth a comment in code.

---

## Verdict: **APPROVE**

The revised spec addresses all five findings from the first review. Mutation seams are explicit, edge cases have concrete mechanisms, embellishment is removed, and the window size is justified with measured data. The three nits above are implementation-level and don't require spec revision.
