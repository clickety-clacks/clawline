# T113 Phase 1 — CCX Rerun R3 (Codex)
Date: 2026-02-24
Scope:
- `/Users/mike/shared-workspace/clawline/specs/per-stream-state-encapsulation.md`
- `/Users/mike/shared-workspace/clawline/specs/t113-architecture-plan.md`
Code baseline: `per-stream-state` @ `77b38fcc8`

## Verdict
Overall status: **PASS**
- Prior blocking Gate 4 issue (scroll debounce timer cancel + generation guard) remains fixed.
- Prior blocking Gate 2 issue (callback registration drop during transitions) is fixed.
- Prior spec/impl mismatch on re-read signal semantics is fixed in `per-stream-state-encapsulation.md`.

## Gate Check (Phase 1)
1. Gate 1: re-read signal flows ChatViewModel → ChatView → controller
- **PASS**
- Evidence: generation-based signal is wired (`forceReReadGeneration`) and consumed by controller seam logic.

2. Gate 2: one-shot callback registry implemented and used for restore
- **PASS**
- Evidence:
  - Registration now stores deterministically by target key/message and no longer drops on active-key mismatch (`MessageFlowCollectionView.swift:2353`).
  - Fire path remains key-scoped/materialization-gated (`MessageFlowCollectionView.swift:2378`).
  - Expiry remains explicit on switch-away/delete.

3. Gate 3: canonical auth cursor rule (nil when any stream lacks cursor; max when all present; no active bias)
- **PASS**
- No regression found relative to interim pass baseline.

4. Gate 4: timer callbacks validate `(sessionKey, generation)` and outgoing timers are canceled on switch
- **PASS**
- Evidence:
  - Outgoing cancel path invalidates `scrollStateWriteDebounceTimer` (`MessageFlowCollectionView.swift:1307`).
  - Debounce callback validates captured generation before persist (`MessageFlowCollectionView.swift:2260`).

5. Gate 5: per-stream-state spec text aligned with implemented contract
- **PASS**
- Evidence: spec now defines generation-based re-read seam (`forceReReadGeneration`) and increment semantics (`per-stream-state-encapsulation.md:207`, `:278`, `:387`, `:426`).

6. Gate 6: per-stream-state acceptance checks 1–25
- **PASS (adversarial rerun scope)**
- No new blocker against acceptance contracts found in this rerun scope.

## Blocking Findings
- None.

## Nits
1. `t113-architecture-plan.md` still contains legacy wording in one section that references passing `forceReRead: true` conceptually under Phase 1 itemization. The implemented seam is generation-based. This is editorial and non-blocking because canonical behavior is now correct in `per-stream-state-encapsulation.md` and code.

## Delta From Interim Rerun
- Fixed blocker: callback registration no-op during transition removed.
- Fixed blocker: spec re-read signal wording now matches generation-based implementation.
- Former timer blocker remains fixed and validated.
