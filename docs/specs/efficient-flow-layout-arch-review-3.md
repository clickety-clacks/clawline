# Efficient Flow Layout Spec: Architecture Principles Review (Third Pass)

**Date:** 2026-02-17  
**Spec reviewed:** `/Users/mike/shared-workspace/clawline/specs/efficient-flow-layout.md`  
**Rubric:** `~/.claude/skills/architecture-principles/SKILL.md`  
**Cross-model reviewer:** Claude Opus (`claude-opus-4-5-20251101`)

## Third-Pass Check: Prior Clarifications

| Item | Status | Evidence |
|------|--------|----------|
| Seam method contracts | Resolved | Section 9.1 now defines method signatures and return shapes (`CachedMeasurement?`, `HeightDelta?`, `InvalidationPlan`). |
| Bottom-inset policy resolution | Resolved | Section 6.1 now specifies deferred idle recalc for visible capped bubbles; Open Question #4 marked resolved. |
| Width-change guard for split-view | Resolved | Section 6.3 explicitly includes split-view/multitasking window resize as full-rebuild trigger. |

## Findings by Severity

### Critical
1. Epsilon threshold for `HeightDelta?` is not specified in seam contract.
- Spec defines `HeightDelta?` return but not explicit threshold logic.
- This can cause implementation drift across agents.

2. `fingerprints` coupling to invalidation isn’t represented in seam migration checklist.
- Checklist focuses on cache families but misses this invalidation-coupled state.
- Clarify whether it is in-scope for seam control or intentionally out-of-scope.

### High
1. "Visible capped bubbles" rule needs concrete visibility definition.
- Deferred recalc policy requires deterministic visibility criteria (partial vs majority intersection).

### Medium
1. Append fast path should clarify interaction with diffable apply.
- Spec says append path should avoid touching existing bubbles, but diffable updates can still drive invalidation cycles unless guarded in layout logic.

2. Mixed batch fallback threshold remains open.
- Spec correctly allows fallback, but no explicit threshold/decision rule yet.

### Low
1. Terminology should keep "reconfigure" vs "remeasure" sharply distinct.
2. Acceptance grep command in AC#7 should be kept exact with full symbol names to avoid false negatives.

## Architecture Principles Verdict (1-7)

| Principle | Verdict | Rationale |
|-----------|---------|-----------|
| #1 Pattern propagation | Pass | Seam-first write path sets the copied pattern clearly. |
| #2 Right-weight architecture | Pass | Lightweight in-place seam first; no premature subsystem extraction. |
| #3 Separation of concerns | Pass | Ownership/invalidation shape is addressed before optimization path. |
| #4 Paired deliverables | Pass | Spec functions as architecture retro + implementation plan. |
| #5 Refactor workflow | Pass | Spec-first and adversarial review flow is being followed. |
| #6 Mutation seam discipline | Pass | Explicit single mutation seam and migration checklist now present. |
| #7 Spec compliance/no embellishment | Pass | Scope boundaries and hard gating are explicit. |

## Must-Resolve Before Implementation
1. Define and pin the `HeightDelta` epsilon contract in the spec.
2. Resolve `fingerprints` seam relationship (include or explicitly exclude with rationale).
3. Add deterministic visibility rule for deferred capped-bubble recalc.
4. Clarify append fast path behavior under diffable apply.

## Overall
The three previously flagged clarification items are now addressed. Remaining issues are precision-level contract gaps, not structural architecture failures. The spec is close to implementation-ready once the must-resolve items above are clarified.
