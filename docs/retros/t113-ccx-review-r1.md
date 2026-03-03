T113 CCX Review of /tmp/t113-opus-analysis.txt
Date: 2026-02-24
Reviewer focus: ticket closure viability (not elegance)

Verdict
- The proposed 4-phase architecture is directionally correct, but in its current form it does NOT reliably close all listed tickets (T077, T095, T099, T100, T103, T104, T105).
- Main blockers are phase contradictions and dependency mismatches against the active specs.

What Works
- Layering idea is sound: UI runtime ownership (per-stream), canonical message write seam, lifecycle/epoch authority, then compile-time prewarm safety.
- Keeping prewarm safety last is reasonable; it is enforcement, not core bug-fix behavior.

Blocking Gaps / Contradictions
1) Cursor ownership contradiction inside the Opus analysis itself
- The plan first says "hold cursor changes until phase 3", then later revises to "commit cursor migration now".
- This is not a minor editorial issue; it changes whether T099 is in scope for phase 1 or deferred.
- With the "hold" version, T099 remains open by design.

2) Phase ordering conflicts with per-stream-state spec requirements
- per-stream-state spec explicitly includes transport-layer per-stream cursor encapsulation (step 12 + acceptance checks 19/20/21/25).
- Therefore phase 1 cannot be considered complete without cursor migration.
- A phase plan that defers cursor ownership contradicts the spec and leaves T099 partially unsolved.

3) Phase 2/3 seam ownership overlap is under-specified
- Opus says phase 2 implements a ConversationStoreWriter-like seam (T105), and phase 3 introduces ConnectionLifecycleCoordinator that also depends on/hosts writer behavior.
- This can work, but only if phase 2 defines stable seam contracts explicitly consumed by phase 3.
- Without that contract freeze, this is not a clean dependency chain; it is rework risk and hidden coupling.

4) T077/T100 are not explicitly mapped
- The Opus analysis does not explicitly map T077 and T100 to concrete phase outcomes or acceptance checks.
- If these are connection-lifecycle-class bugs (reconnect churn / replay resume correctness), they remain unresolved until phase 3.
- That is acceptable only if explicitly acknowledged; currently it is implicit.

Ticket-by-ticket closure check
1) T095 (scroll restore after re-read/unload)
- Opus phase intent: likely solvable in phase 1.
- Current branch evidence: still incomplete because same-key re-read arming is not fully wired end-to-end.
  - `ChatView.swift:934` and `ChatView.swift:1078` pass `forceReRead: false`.
  - `ChatViewModel.swift:336`+ has generation arming, but not consumed by view/controller.
  - `MessageFlowCollectionView.swift:36` still uses bool `forceReRead` path.
- Conclusion: architecture can solve T095, but current phase-1 implementation (as analyzed) does not yet.

2) T103 (switch lands wrong position)
- Phase 1 seam/flush/generation model is the correct mechanism.
- Current branch has seam and generation checks (`MessageFlowCollectionView.swift:2130`, `:2154`, `:2299`), so this is mostly on track.
- Remaining risk is missing callback registry/event-driven trigger (below) causing restore timing misses.

3) T104 (SBB missing after switch)
- Per-stream runtime ownership model addresses root cause.
- Current branch appears aligned in principle (per-stream state present), so likely fixable in phase 1.

4) T099 (initial login streams stale/empty from cursor ownership)
- Requires per-stream transport cursor ownership + full-stream replay snapshot semantics.
- Current branch has transport cursor map (`ProviderChatService.swift:221`, `:330`, `:338`) but still gates per-stream cursor auth payload behind "all known sessions have cursors" and otherwise falls back to single `lastMessageId` (`ProviderChatService.swift:862-872`, `:921`).
- That fallback can still bias replay to active/global cursor behavior and leave non-active streams underpopulated.
- Conclusion: not fully closed yet; Opus plan must require removal of this fallback behavior if claiming T099 closure.

5) T105 (canonical insertion seam)
- Opus phase 2 rightly targets this.
- Current branch still has direct `sessionMessages` writes in many places (`ChatViewModel.swift:633`, `:817`, `:913`, `:951`, `:978`, `:991`, `:996` etc.).
- So T105 is currently open. Architecture is correct here, implementation not yet.

6) T077 / T100
- No explicit mapping in Opus analysis to phase acceptance tests.
- If they are lifecycle bugs, phase 3 may solve them, but the plan should declare that explicitly with pass criteria.
- As written, closure claim is weak.

Hidden dependency/circular-dependency check
- No hard circular dependency found if contracts are fixed.
- Potential soft cycle exists between phase 2 and phase 3 unless seam interfaces are frozen first:
  - phase 2 writer API must be lifecycle-aware enough (source metadata, idempotent upsert semantics, clear semantics) so phase 3 can attach epoch gating without redesign.
- Prewarm safety (phase 4) has no blocking reverse dependency into phases 1-3 if kept as enforcement-only.

Spec coherence check vs current code and Opus plan
- Missing in current code vs per-stream-state spec:
  - One-shot on-message-load callback registry (not present; no `registerOnMessageLoad`/`fireRegisteredMessageLoadCallbacksIfMaterialized` in current `MessageFlowCollectionView.swift`).
  - forceReRead last-mile wiring (see hardcoded `false` in `ChatView.swift`).
- This means phase-1 ticket closure is currently over-claimed.

Bottom line
- The architecture is viable, but not yet ticket-complete.
- To make it actually solve the ticket set, Opus plan needs explicit corrections:
  1) pick one cursor strategy (do not keep contradictory "hold" vs "commit" guidance),
  2) make T099 closure require no active/global fallback in auth cursor handoff,
  3) freeze phase-2 seam contracts before phase 3 to avoid rework coupling,
  4) explicitly map T077/T100 to phase-3 acceptance criteria,
  5) require phase-1 completion gates for forceReRead wiring + callback registry before claiming T095/T103 done.
