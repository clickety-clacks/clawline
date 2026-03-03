T113 CCX Review — Round 2 (against /tmp/t113-opus-r2.txt)
Date: 2026-02-24
Lens: ticket closure viability (T077, T095, T099, T100, T103, T104, T105), dependency correctness, contradiction/cycle check.

Overall verdict
- Round 2 is substantially better than round 1.
- The five corrections fix most blocking architecture issues.
- Remaining blocking point: T099 closure is still fragile/incomplete unless global auth-cursor fallback behavior is fully removed in practice (not just active-session bias removed).
- T100 remains intentionally unresolved/unmapped, so strict "all listed tickets closed" still requires scope clarification.

What improved correctly
1) Cursor contradiction
- Resolved: distinction between per-stream replay cursor vs canonical auth cursor is valid and matches specs.
- This removes the prior plan-level contradiction.

2) T113 scope compression to phase 1 + phase 2
- Reasonable if T113 is defined as per-stream-state tickets + T105 seam.
- Phase 3/4 can remain separate, provided no T113 ticket explicitly depends on lifecycle coordinator/prewarm safety.

3) T077/T100 handling
- T077 marked already resolved: acceptable if Flynn agrees closure source is prior main-line work.
- T100 explicitly unmapped: acceptable as a scope decision, but it means T113 cannot be claimed "fully closed" without explicit T100 disposition.

4) Phase 1 completion gates
- Good and necessary: forceReRead wiring, callback registry, timer generation validation, spec update.
- These gates align with concrete known gaps in current branch state.

5) Phase 2 contract freeze
- Good correction. Freezing writer interface before implementation reduces phase-2/phase-3 coupling risk.
- No hard circular dependency if this is done first.

Remaining blocking/important gaps
A) T099 risk: global fallback may still exist semantically even after active-key bias removal
- Round 2 says keep conditional per-stream replay cursor payload only when "all sessions have cursors" and otherwise rely on canonical lastMessageId (max across cursors).
- This can still under-replay non-cursor streams during mixed-cursor states, which is exactly the class of T099 failure (blank/stale non-active streams).
- For T099 closure, requirement should be stricter:
  - No global single-cursor fallback for multi-stream replay decisions, OR
  - If server capability forces fallback, use safe full replay behavior when per-stream set is incomplete (not partial/global bias).
- Without that explicit rule, T099 closure remains at risk.

B) T100 still unresolved in closure math
- Round 2 correctly marks T100 unmapped/non-architectural, but user asked closure across listed tickets including T100.
- So closure statement should be: "T113 architecture closes all mapped tickets; T100 requires separate product/scope decision." 
- Otherwise this reads as a silent scope drop.

C) T105 seam acceptance must include migration proof, not only API freeze
- Round 2 includes contract freeze (good) but closure must still require compiler-error-first migration proof: no direct `sessionMessages` writes outside seam.
- This is critical because current branch still has many direct write sites.

Dependency/cycle assessment
- No hard circular dependency remains.
- Ordering is valid if enforced as:
  1. Phase-1 spec+impl gates complete (including T099-safe cursor semantics)
  2. Phase-2 writer contract freeze
  3. Phase-2 compiler-error-first migration
- Hidden soft dependency to watch: if phase-2 writer API is not finalized before code migration, phase-3 lifecycle needs may force seam churn.

Ticket closure assessment
- T077: acceptable as already resolved (external to this branch), pending owner confirmation.
- T095: closable in phase 1 only if forceReRead wiring + callback registry are actually implemented.
- T099: NOT safely closable yet unless incomplete-cursor-state behavior removes global fallback risk.
- T100: intentionally unresolved/unmapped.
- T103: closable with same phase-1 gates as T095.
- T104: likely already satisfiable by per-stream SBB ownership.
- T105: closable only after full seam migration (not just contract design).

Bottom line
- Round 2 is mostly sufficient and materially improved.
- Required amendment before I would call architecture "ticket-closure ready":
  1) strengthen T099 rule to eliminate global fallback in incomplete per-stream cursor states,
  2) explicitly mark T100 as out-of-scope pending Flynn decision,
  3) keep T105 closure tied to compile-time migration proof, not design contract alone.
