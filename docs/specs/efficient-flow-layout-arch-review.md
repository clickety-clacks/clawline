# Efficient Flow Layout Spec: Architecture Principles Review

**Date:** 2026-02-17  
**Spec reviewed:** `/Users/mike/shared-workspace/clawline/specs/efficient-flow-layout.md`  
**Rubric:** `~/.claude/skills/architecture-principles/SKILL.md`  
**Cross-model reviewer:** Claude Opus (`claude-opus-4-5-20251101`)

## Scope
Evaluated the spec against architecture principles:
- #1 Pattern propagation
- #2 Right-weight architecture
- #3 Separation of concerns first
- #6 State mutation seam discipline
- Additional misses/violations

## Principle Verdicts

### #1 Pattern Propagation
**Pass**
- The spec explicitly identifies the bad pattern (many direct cache writes) and introduces a replacement pattern (single cache mutation seam).
- This is the right direction for establishing what future agents should copy.

### #2 Right-Weight Architecture
**Pass**
- The spec’s updated approach is lightweight first: seam in existing controller, no immediate new subsystem/type hierarchy.
- It defers extraction (`BubbleLayoutStateStore`) until there is actual pressure/second consumer.

### #3 Separation of Concerns First
**Pass**
- The spec treats the performance issue as a shape problem, not just a hotfix.
- It maps current cache/invalidation behavior and separates ownership consolidation from algorithm changes.

### #6 State Mutation Seam Discipline
**Pass with high-risk gap**
- The spec correctly names the current violation and proposes one seam.
- But sequencing clarity is not yet strong enough to guarantee the seam lands before optimization work.

## Findings (Ordered by Severity)

### High
1. Sequencing needs to be explicit enough to be enforceable.
- Risk: Implementers may jump to y-shift optimization before seam consolidation, recreating split mutation paths.
- Needed: lock down implementation order as a hard requirement (seam first, optimization second).

2. Mutation-site audit is implied but not fully enumerated as a checklist.
- Risk: partial migration leaves hidden direct cache writes.
- Needed: explicit "all known writers" list and completion criteria for seam migration.

### Medium
1. Insert/delete fallback language can conflict with append performance intent.
- Spec says insert/delete/move may fall back to full rebuild, but also claims new message append should be cheap.
- Needed: explicit distinction between common append path and complex diff batches.

2. Seam invariant lacks dedicated acceptance/test criteria.
- Current acceptance criteria focus on performance outcomes.
- Needed: add boundary tests that fail if direct cache writes reappear outside the seam.

## Must-Resolve Before Implementation
1. Add explicit sequencing with hard ordering: mutation seam first, behavior parity second, y-shift optimization later.
2. Add a concrete mutation-site migration checklist (all six cache families + known writer paths).
3. Clarify append-vs-batch behavior so common message arrival does not accidentally regress to full rebuild.
4. Add at least one acceptance/test item for seam integrity (single mutation point invariant).

## Concrete Spec Edits Recommended
1. In `9.2 Sequencing`, convert to explicit gated steps:
- Step A: introduce seam + route all cache writes
- Step B: verify no direct cache mutation remains
- Step C: only then implement incremental y-shift layout path

2. In `9.1 Cache Mutation Seam`, add a migration checklist table:
- Cache/store name
- Current writers
- Routed through seam? (yes/no)
- Verification method

3. In `7.2 Insertions and Deletions`, split behavior:
- "Single-message append" fast path
- "Complex mixed batch" fallback path

4. In `8 Acceptance Criteria`, add seam-specific criteria:
- "No direct cache mutation outside seam methods" (enforced by tests/lint/checklist).

## Cross-Model Notes
Claude Opus review aligned with this conclusion: the spec direction is architecturally sound and now mostly right-weight, but it needs stricter sequencing and seam audit/test language to prevent regression into split mutation paths.
