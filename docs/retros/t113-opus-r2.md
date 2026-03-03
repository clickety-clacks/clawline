T113 Omnibus — Revised Architectural Analysis (Round 2)
Date: 2026-02-24
Author: Opus (per-stream-state branch agent)
Input: Codex cross-review of round 1 (5 blocking gaps)

========================================================================
SECTION 1: DO THE GAPS REVEAL AN ARCHITECTURE DEFICIENCY?
========================================================================

No. The four-spec architecture is sound. The gaps reveal deficiencies in
my PLAN, not in the design itself.

Here is what each gap actually reveals:

Gap 1 (cursor contradiction): I was conflating two distinct cursor
concepts that both specs already model separately. The per-stream-state
spec defines per-stream replay cursors (transport layer, keyed by
sessionKey). The connection-lifecycle spec defines a canonical auth
cursor (single value, latest server event across all sessions, for
reconnect auth). These are different things serving different purposes.
My plan wobbled because I treated them as one decision.

Gap 2 (global cursor fallback): The unstaged `resolveAuthLastMessageId`
has active-session-first bias:

    if let activeCursor = replayCursorSnapshot[trimmedActiveSessionKey] {
        return activeCursor
    }
    return replayCursorSnapshot.values.max()

This violates both specs. The per-stream-state spec says "no fallback to
active/global key." The connection-lifecycle spec says "canonical cursor
value is the latest successfully applied server s_* event id across all
session keys" and "engineActiveSessionKey cursor is never used as
fallback for auth snapshot." The correct single-cursor auth value is
`replayCursorSnapshot.values.max()` — always. No active-session bias.

Gap 3 (seam contract freeze): Real coupling risk, but solvable by
designing the writer interface spec before implementing either the
message seam or the lifecycle coordinator. Not an architecture problem —
a sequencing discipline problem.

Gap 4 (T077/T100 unmapped): T077 is resolved (retro confirms all work
is on main). T100 (GitHub #100: "Send button reconnect pulse should
animate size + color, not just color") is a UI animation concern with no
architectural footprint and no spec. It either doesn't belong in T113
or needs Flynn clarification.

Gap 5 (phase 1 over-claimed): Accurate. The branch is ~75% done, not
closeable. Three items remain.

None of these point to a missing abstraction or a wrong decomposition.
The four specs partition correctly by concern boundary. The gaps are in
how I mapped specs to tickets and phased the implementation.

========================================================================
SECTION 2: TICKET-BY-TICKET CLOSURE MAP
========================================================================

T077 — Stream switch latency (offscreen deferral + layout caching)
  Status: RESOLVED. Already on main.
  Evidence: Retro at ~/shared-workspace/clawline/retros/t077-latency-review-2026-02-23.md
  confirms: "Still needed: None identified."
  Phase: None. Already done.

T095 — Scroll position not preserved on re-read/initial populate (#97)
  Root cause: One-shot restore lockout prevents re-restore on same key.
  Fix mechanism: Per-stream restore generation token + stage-aware
  restore phases (pendingTail -> pendingFullConfirmation -> confirmed).
  Current branch status: Restore phases implemented. forceReRead
  parameter exists in update() but ChatView hardcodes false. One-shot
  callback registry absent.
  Closure requires:
    1. Wire forceReRead from ChatViewModel through ChatView.
    2. Implement one-shot message-load callback registry.
  Phase: 1.

T099 — Initial login streams stale/empty (#99 equivalent)
  Root cause: Global replay cursor biases replay to one stream.
  Fix mechanism: Per-stream cursor isolation in transport layer +
  canonical auth cursor with no active-session bias.
  Current branch status: Per-stream cursor map in ProviderChatService
  (unstaged). But resolveAuthLastMessageId has active-session-first
  fallback — this is a spec violation.
  Closure requires:
    1. Commit cursor migration to transport layer.
    2. Remove active-session bias from resolveAuthLastMessageId.
       Replace with: always use max(replayCursorSnapshot.values).
    3. Remove WebSocket URL cleanup (embellishment, not in spec).
  Phase: 1.

T100 — Send button reconnect pulse animation (#100)
  Status: NO SPEC COVERAGE. GitHub issue is a UI animation concern.
  Not architecturally related to per-stream state, message seams, or
  connection lifecycle. Either excluded from T113 scope or needs
  Flynn direction.
  Phase: Unmapped. Needs clarification.

T103 — Stream switch lands mid-stream instead of bottom/last position (#104)
  Root cause: No per-stream scroll persistence + broken flush-on-switch.
  Fix mechanism: Stream-context switch seam with flush-on-switch
  contract + per-stream restore with generation gating.
  Current branch status: Switch seam implemented with ordered steps 1-8.
  Flush-on-switch with lastKnownScrollSnapshot fallback present.
  Restore phase machine present with bounded confirmation retries.
  Closure requires: Same forceReRead wiring and callback registry as
  T095 (restore event-driven trigger depends on callback registry for
  deterministic message-appearance targeting).
  Phase: 1.

T104 — SBB missing after stream switch (#105)
  Root cause: SBB state is controller-global, not per-stream.
  Fix mechanism: sbbState inside PerStreamRuntimeState, selected by
  sessionKey on switch. SBB initialized from persisted atBottom on
  incoming entry creation.
  Current branch status: Implemented. sbbState is per-stream, selected
  via activeStateKey(). Incoming state initialized from persisted data
  in prepareIncomingStateOnSwitch.
  Closure requires: No additional work beyond what exists.
  Phase: 1 (already done for this ticket specifically).

T105 — Canonical message insertion seam (#113 alignment)
  Root cause: Multiple direct mutation paths to sessionMessages.
  Fix mechanism: ConversationStoreWriter with upsert/remove/
  clearSessionMessages/removeSession/clearAllForLogout.
  Current branch status: Not implemented. sessionMessages still mutated
  directly from many ChatViewModel call sites.
  Closure requires: Full message-stream-seam.md implementation.
  Phase: 2.

========================================================================
SECTION 3: REVISED PHASE PLAN
========================================================================

PHASE 1: Complete per-stream-state-encapsulation (this branch)
Closes: T095, T099, T103, T104
Already closed: T077
Needs clarification: T100

Remaining work items (5):

  1a. Wire forceReRead signal end-to-end.
      ChatViewModel.forceReReadGeneration(for:) exists but ChatView
      passes false. ChatView must track last-seen generation per
      sessionKey and pass true when generation advances.

  1b. Implement one-shot message-load callback registry.
      Add registeredMessageLoadCallbacksByMessageId to
      PerStreamRuntimeState. Implement register, fire-on-layout,
      fire-if-already-materialized, auto-expire-on-switch, one-shot
      semantics per spec.

  1c. Commit cursor migration with no global fallback.
      - Commit the transport-layer per-stream cursor changes.
      - Fix resolveAuthLastMessageId: remove active-session-first
        bias. Canonical auth value = max across all per-stream cursors.
        No fallback to active key. No fallback to global key.
      - Remove the WebSocket URL cleanup from this diff (not in spec).
      - Keep the "send replayCursorsBySessionKey in auth payload when
        all sessions have cursors" conditional — this is forward compat
        for provider-side per-stream replay, not a fallback.

  1d. Add generation-token validation to BubbleSizingV2 and
      bottom-inset timer callbacks.
      Currently these timers route through activeStateKey() which
      could be wrong if timer fires during/after switch. Callbacks
      must capture (sessionKey, restoreGeneration) at schedule time
      and validate before mutation.

  1e. Update per-stream-state-encapsulation.md spec text.
      Incorporate adversarial review blocking findings that the
      implementation already addressed but the spec text does not
      reflect. Spec is source of truth; code should not be ahead
      of spec.

Phase 1 completion gate (all must pass before claiming done):
  - forceReRead flows from ChatViewModel to ChatView to controller.
  - One-shot callback registry exists and is used for restore targeting.
  - Cursor auth value is always max-across-all, never active-session-first.
  - Timer callbacks validate (sessionKey, generation) not just key.
  - Spec text matches implementation.
  - All 25 required tests from spec pass conceptually (manual
    verification against test descriptions, not necessarily automated).

PHASE 2: Message stream seam (T105)
Closes: T105

  2a. Design ConversationStoreWriter interface.
      Before implementing, write the writer's public API surface as a
      contract addendum to message-stream-seam.md. Include:
        - upsert/remove/clearSessionMessages/removeSession/clearAllForLogout
        - Source metadata (isServer, isCache)
        - writerCurrentEpoch tracking (designed for lifecycle, but
          initially epoch is always "current" without a coordinator)
        - Canonical auth cursor ownership (migrated from transport
          layer to writer when lifecycle coordinator arrives — for now,
          transport layer retains cursor and writer consumes it)

      WHY: This contract is consumed by phase 3. Freezing it before
      implementation prevents rework coupling. The writer must be
      epoch-AWARE in interface even if epoch-GATED behavior comes later.

  2b. Compiler-error-first migration.
      Lock sessionMessages/lastServerMessageIdBySession as private
      to writer. Fix all compile breaks through seam operations.

  2c. Adversarial review of implementation.
      Cross-model review before declaring done.

Phase 2 completion gate:
  - Zero direct writes to message backing store outside writer.
  - Writer interface includes epoch parameter slots (unused until
    phase 3 but present in API shape).
  - All message-stream-seam.md acceptance criteria pass.

PHASE 3 (FUTURE — not required for T113 closure): Connection lifecycle
  Introduces ConnectionLifecycleCoordinator.
  Wraps existing writer with epoch-gating.
  Consolidates reconnect scheduling.
  Migrates canonical auth cursor from transport snapshot to
  writer-owned canonical state.

PHASE 4 (FUTURE — not required for T113 closure): Prewarm safety
  ReadHandle/WriteHandle compile-time enforcement.
  PageMessageFlowController/PrewarmMessageFlowController split.

========================================================================
SECTION 4: WHY TWO PHASES CLOSE T113 (NOT FOUR)
========================================================================

The T113 child tickets are: T077, T095, T099, T100, T103, T104, T105.

- T077: Already resolved.
- T095, T099, T103, T104: All per-stream-state-encapsulation bugs.
  Phase 1 closes all four.
- T105: Message-stream-seam. Phase 2 closes it.
- T100: No spec. Needs Flynn clarification.

ConnectionLifecycleCoordinator (phase 3) fixes reconnect cycling,
epoch-gated cache/replay precedence, and formal lifecycle phases.
These are real bugs but they are NOT in the T113 child ticket set.
They live in the connection-lifecycle spec under different tracking.

Prewarm controller safety (phase 4) is compile-time enforcement over
behavioral correctness established in phases 1-2. Valuable but not
required for any T113 child ticket.

T113 omnibus closure = phase 1 + phase 2 + T100 clarification.

========================================================================
SECTION 5: CURSOR ARCHITECTURE (RESOLVING THE CONTRADICTION)
========================================================================

There are two cursor concepts. My round-1 analysis conflated them.

CONCEPT 1: Per-stream replay cursors
  Owner: Transport layer (ProviderChatService)
  Storage: replayCursorBySessionKey: [String: String]
  Keyed by: sessionKey
  Updated: On each incoming s_* server message for that stream
  Purpose: Track replay progress per stream for UI populate/re-read
  Spec: per-stream-state-encapsulation.md, T099 section

CONCEPT 2: Canonical auth cursor
  Owner: Currently transport layer (resolveAuthLastMessageId).
         Future: ConversationStoreWriter (connection-lifecycle.md).
  Storage: Single value, derived as max across all per-stream cursors
  Keyed by: User+device scope (not per-stream)
  Updated: After each server message apply (debounced)
  Purpose: Single lastMessageId for provider auth/reconnect payload
  Spec: connection-lifecycle.md, Cursor Resume Contract

PHASE 1 ACTION: Per-stream cursors move to transport layer (done in
unstaged work). Canonical auth cursor is computed as max-across-all
per-stream values — no active-session bias. This is correct ownership
for now and compatible with future writer migration in phase 3.

PHASE 3 ACTION (future): Canonical auth cursor migrates from transport
computation to writer-owned state with epoch-gated persistence. The
per-stream cursors remain in transport layer.

There is no contradiction. Per-stream cursors: commit now (phase 1).
Canonical auth cursor: compute correctly now (max, no bias), migrate
ownership later (phase 3).

========================================================================
SECTION 6: TRANSITIONAL SHIM REMOVAL PLAN
========================================================================

Architecture principle 1 (pattern propagation) flags that the computed-
property shims (keyless sbbState, fingerprints, sizeCache, etc. that
route through activeStateKey()) propagate the old pattern. Agents will
copy keyless access because it compiles.

Plan:
- Phase 1 ships WITH shims (they are necessary for incremental
  migration of the 1800+ line file).
- Phase 1 completion gate includes: document every shim accessor with
  // MIGRATION SHIM — remove when all callers pass explicit sessionKey
- Phase 2 (message-stream-seam) does not touch MessageFlowCollectionView
  so shims persist.
- Shim removal is a standalone cleanup task after phase 2, tracked
  separately. It is not gated on any ticket closure.

========================================================================
SECTION 7: RESPONSE TO ARCHITECTURE PRINCIPLES
========================================================================

Principle 3 (separation of concerns first): Satisfied. The four specs
separate transport, data, UI runtime, and compile-time enforcement.

Principle 6 (state mutation seam discipline): Satisfied by design.
Each spec introduces exactly one mutation seam for its domain.

Principle 7 (no embellishment): Requires removing the WebSocket URL
cleanup from the unstaged cursor diff. It is not in any spec.

Principle 9 (SSOT): The cursor contradiction violated this. Resolved
by distinguishing two concepts with two owners. Per-stream cursors
have one owner (transport). Canonical auth cursor has one owner
(currently transport-computed, future writer-owned). No dual authority.

Principle 5 (spec -> review -> implement): The per-stream-state spec
needs adversarial review findings folded back in before phase 1
completion. This is work item 1e.

========================================================================
SECTION 8: WHAT I GOT WRONG IN ROUND 1
========================================================================

1. Conflated per-stream replay cursors with canonical auth cursor.
   These are different concepts, different owners, different specs.

2. Wobbled on cursor timing ("hold" then "commit"). The correct answer
   was always "commit per-stream cursors in phase 1" because they are
   part of the per-stream-state spec (step 12, acceptance checks 19-21).
   I overcomplicated this by worrying about epoch-gating, which applies
   to the canonical auth cursor (phase 3), not per-stream cursors.

3. Over-scoped the T113 closure requirements. T113 does not require
   ConnectionLifecycleCoordinator or prewarm safety. Those are
   separate work tracked elsewhere. T113 closes with phase 1 + phase 2.

4. Did not explicitly acknowledge T077 as resolved or T100 as unmapped.

5. Over-claimed phase 1 completeness. The branch is ~75% done with
   three significant items remaining (forceReRead, callback registry,
   cursor fallback removal).
