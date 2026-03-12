T113 Omnibus — Final Architectural Analysis
Date: 2026-02-24
Author: Opus (per-stream-state branch agent)
Review history: Opus R1 → Codex R1 (5 blocking) → Opus R2 → Codex R2 (3 refinements) → this final

========================================================================
VERDICT
========================================================================

The four-spec architecture is correct. The child tickets divide into
two implementation phases. Two phases close T113.

Phase 1: Complete per-stream-state-encapsulation → T095, T099, T103, T104
Phase 2: Implement message-stream-seam → T105
Already resolved: T077
Out of scope: T100 (see Section 5)

========================================================================
SECTION 1: ARCHITECTURE
========================================================================

Four specs, four concern boundaries, one unifying principle:
explicit keyed ownership with single-writer mutation and no bypass.

  Transport/connection:  connection-lifecycle.md
  Data/store:            message-stream-seam.md
  UI runtime:            per-stream-state-encapsulation.md
  Compile-time safety:   prewarm-controller-safety.md

These are correctly separated. They share the ownership principle but
operate on different state at different layers. Merging them would
violate separation of concerns. The dependency stack is:

  prewarm-controller-safety (enforcement over phases 1-2)
    ↑
  per-stream-state-encapsulation (UI runtime, depends on T105 coherence)
    ↑
  message-stream-seam (data mutation, writer hosts the seam)
    ↑
  connection-lifecycle (epoch-gating wraps the writer)

For T113 closure, only the middle two layers are required. The top
(prewarm) and bottom (lifecycle) layers add robustness and safety but
no T113 child ticket depends on them.

========================================================================
SECTION 2: TICKET CLOSURE MAP
========================================================================

T077 — Stream switch latency
  Status: RESOLVED. Work is on main.
  Evidence: latency review evidence consolidated into core docs (2026-03-09)
  Action: None.

T095 — Scroll position not preserved on re-read/initial populate
  Root cause: One-shot restore lockout; no re-read signal.
  Phase: 1
  Remaining work: forceReRead wiring, one-shot callback registry.

T099 — Initial login streams stale/empty
  Root cause: Global replay cursor biases replay; non-active streams
  under-replayed.
  Phase: 1
  Remaining work: Cursor migration to transport layer. Removal of
  active-session bias. Safe incomplete-cursor-state rule (Section 3).

T100 — Send button reconnect pulse animation
  Status: OUT OF SCOPE for T113. See Section 5.

T103 — Stream switch lands mid-stream
  Root cause: No per-stream scroll persistence; no flush-on-switch.
  Phase: 1
  Remaining work: Same forceReRead + callback registry as T095.

T104 — SBB missing after stream switch
  Root cause: SBB state is controller-global.
  Phase: 1
  Status: Already implemented on this branch. sbbState is per-stream,
  initialized from persisted atBottom on incoming entry creation.

T105 — Canonical message insertion seam
  Root cause: Multiple direct mutation paths to sessionMessages.
  Phase: 2
  Remaining work: Full message-stream-seam.md implementation with
  compiler-error-first migration proof.

========================================================================
SECTION 3: CURSOR ARCHITECTURE
========================================================================

Two distinct cursor concepts. Two owners.

CONCEPT 1: Per-stream replay cursors
  Owner: Transport layer (ProviderChatService)
  Storage: replayCursorBySessionKey: [String: String]
  Keyed by: sessionKey
  Updated on: Each incoming s_* server message for that stream
  Purpose: Track replay progress per stream for UI populate/re-read
  Spec: per-stream-state-encapsulation.md, T099 section

CONCEPT 2: Canonical auth cursor
  Owner: Currently derived from per-stream cursors at auth time.
         Future (phase 3): ConversationStoreWriter.
  Storage: Single value, computed from per-stream cursor map
  Keyed by: User+device scope (not per-stream)
  Purpose: Single lastMessageId for provider auth/reconnect payload
  Spec: connection-lifecycle.md, Cursor Resume Contract

Canonical auth cursor computation rule:

  Given: replayCursorBySessionKey (transport-owned)
         knownSessionKeys (streams the client knows about)

  If ALL known session keys have a non-empty cursor entry:
    canonicalAuthCursor = max(replayCursorBySessionKey.values)

  If ANY known session key has NO cursor entry:
    canonicalAuthCursor = nil (omit lastMessageId from auth payload)

Rationale for the nil rule: The provider protocol uses a single cursor
over a unified per-user event stream. Sending max-cursor when some
streams have no cursor causes the server to start replay past those
streams' content — exactly the T099 failure mode (non-active streams
appear empty). Sending nil forces full replay, which is more expensive
but guarantees every stream gets its content. This state only occurs
on first connection with a mixed-cursor map (new streams alongside
established ones). Subsequent reconnects where all streams have cursors
use the efficient max-cursor path.

Per-stream cursor payload (replayCursorsBySessionKey) in auth:
  Send when ALL known sessions have cursors. This is forward
  compatibility for provider-side per-stream replay. When the per-stream
  cursor map is incomplete, only the canonical single-cursor rule above
  applies.

Forbidden behaviors:
  - Active-session-first cursor selection (biases replay to one stream)
  - Global fallback to engineActiveSessionKey cursor
  - Sending max-cursor when any stream lacks a cursor entry

========================================================================
SECTION 4: PHASE 1 — COMPLETE PER-STREAM-STATE-ENCAPSULATION
========================================================================

Closes: T095, T099, T103, T104

Work items:

  1a. Wire forceReRead end-to-end.
      ChatViewModel.forceReReadGeneration(for:) exists. ChatView must
      track last-seen generation per sessionKey and pass forceReRead:
      true when generation advances. Currently hardcoded false at
      ChatView.swift call sites.

  1b. Implement one-shot message-load callback registry.
      Add registeredMessageLoadCallbacksByMessageId to
      PerStreamRuntimeState. Implement:
        - Register callback for (sessionKey, messageId)
        - Fire after layout pass completes for that message
        - Fire immediately if message already materialized
        - Auto-expire on stream switch-away and message deletion
        - One-shot: fires at most once
      Allowed uses: scroll-to-message, flash/highlight, unread anchor.
      Disallowed: geometric restore fallback, general event bus.

  1c. Commit cursor migration with safe incomplete-cursor-state rule.
      - Commit transport-layer per-stream cursor changes.
      - Fix resolveAuthLastMessageId per Section 3 rules:
        All streams have cursors → max. Any stream missing → nil.
      - Remove active-session-first bias entirely.
      - Remove WebSocket URL cleanup from diff (embellishment, not
        in any spec — architecture principle 7).

  1d. Timer generation-token validation.
      BubbleSizingV2 and bottom-inset timer callbacks must capture
      (sessionKey, restoreGeneration) at schedule time and validate
      both before mutation. Key-only validation is insufficient for
      same-key re-read scenarios.

  1e. Update per-stream-state-encapsulation.md spec text.
      Incorporate adversarial review blocking findings that the
      implementation addressed but the spec text does not reflect:
        - lastAppliedEffectiveSessionKey definition and update point
        - Scroll delegate callback key-binding rule
        - Restore phase behavior when staging is skipped (full-only)
        - SBB initialization from persisted atBottom
        - Coordinator unfreeze obligation

Phase 1 completion gates (ALL required):
  [ ] forceReRead flows from ChatViewModel → ChatView → controller
  [ ] One-shot callback registry implemented and used for restore
  [ ] Canonical auth cursor: nil when any stream lacks cursor, max
      otherwise. No active-session bias. No global fallback.
  [ ] Timer callbacks validate (sessionKey, generation) not just key
  [ ] Spec text updated with adversarial review resolutions
  [ ] Per-stream-state spec acceptance checks 1-25 pass (manual
      verification against test descriptions)

========================================================================
SECTION 5: T100 DISPOSITION
========================================================================

T100 (GitHub #100: "Send button reconnect pulse should animate size +
color, not just color") is a UI animation concern. It has:
  - No spec coverage in any of the four architectural specs
  - No architectural dependency on per-stream state, message seam,
    connection lifecycle, or prewarm safety
  - No root cause related to keyed ownership or mutation seams

T100 is OUT OF SCOPE for T113 architectural closure.

If T100 must be closed under the T113 omnibus, it requires a separate
product decision from Flynn — either a standalone fix or explicit
removal from the T113 child ticket list. The architecture presented
here makes no claim on T100 and T113 cannot be called fully closed
while T100 remains unresolved, regardless of architectural work.

========================================================================
SECTION 6: PHASE 2 — MESSAGE STREAM SEAM (T105)
========================================================================

Closes: T105

Work items:

  2a. Design ConversationStoreWriter interface.
      Write the writer's public API surface as a contract addendum
      to message-stream-seam.md BEFORE implementation. Include:
        - upsert(sessionKey, message, sourceFlags)
        - remove(sessionKey, messageId, reason)
        - clearSessionMessages(sessionKey, reason)
        - removeSession(sessionKey, reason)
        - clearAllForLogout(reason)
        - Source metadata: isServer, isCache
        - writerCurrentEpoch slot (unused until phase 3, present in
          API shape for forward compatibility)

      This contract is consumed by future phase 3. Freezing it before
      implementation prevents rework coupling.

  2b. Compiler-error-first migration.
      Step 1: Lock sessionMessages, lastServerMessageIdBySession,
      messages, lastServerMessageId, pendingLocalMessages, and
      messageFailures as private to writer. Mark legacy direct-write
      helpers @available(*, unavailable).
      Step 2: Fix every compile break through seam operations.
      Step 3: Remove temporary shims and legacy write paths.

  2c. Adversarial review of implementation.
      Cross-model review (per reviewing-code-with-llms skill).

Phase 2 completion gates (ALL required):
  [ ] Zero direct writes to message backing store outside writer.
      This is a compiler-verifiable property: the backing collections
      are private to the writer, and the project builds.
  [ ] Writer interface includes epoch parameter slots.
  [ ] All message-stream-seam.md acceptance criteria pass:
      - Dedup by (sessionKey, id) enforced
      - Server-wins conflict policy enforced
      - Streaming update-in-place works
      - Cache is gap-fill only
      - Retry appends at tail with new client ID
      - clearSessionMessages vs removeSession distinct
      - Logout clear is atomic across dependent state
      - Send blocked unless active session provisioned
  [ ] No public removeByIdGlobal in final API
  [ ] Cross-model adversarial review completed

========================================================================
SECTION 7: FUTURE PHASES (NOT REQUIRED FOR T113)
========================================================================

Phase 3: Connection lifecycle (separate tracking)
  - ConnectionLifecycleCoordinator (actor)
  - Epoch-gating wrapping existing writer from phase 2
  - Reconnect policy consolidation (single scheduler)
  - Canonical auth cursor ownership migrates to writer
  - Replay gate (started/completed) with replayCount semantics
  Fixes: Rapid reconnect cycling, epoch-gated cache/replay precedence

Phase 4: Prewarm controller safety (separate tracking)
  - ReadHandle / WriteHandle compile-time capability split
  - PageMessageFlowController / PrewarmMessageFlowController
  - MessageFlowRenderCore extraction
  - Factory enforcement
  Fixes: Compile-time prevention of prewarm state mutation

========================================================================
SECTION 8: TRANSITIONAL SHIM PLAN
========================================================================

The computed-property shims in MessageFlowCollectionViewController
(keyless sbbState, fingerprints, sizeCache, etc. routing through
activeStateKey()) exist for incremental migration. They propagate the
old keyless-access pattern that agents will copy.

Rules:
  - Phase 1 ships WITH shims (necessary for 1800+ line file migration).
  - Every shim accessor is marked with:
    // MIGRATION SHIM — remove when all callers pass explicit sessionKey
  - Shim removal is a standalone cleanup task tracked separately,
    not gated on any T113 ticket.
  - New code written during phase 1 must use explicit sessionKey
    access (readState/mutateState), not shim accessors.

========================================================================
SECTION 9: WHAT I GOT WRONG AND CORRECTED
========================================================================

Round 1 errors (corrected in round 2):
  1. Conflated per-stream replay cursors with canonical auth cursor.
  2. Contradicted myself on cursor timing (hold vs commit).
  3. Over-scoped T113 to require phases 3-4.
  4. Did not explicitly handle T077 (resolved) or T100 (unmapped).
  5. Over-claimed phase 1 completeness.

Round 2 errors (corrected in this final):
  6. Did not define safe behavior for incomplete cursor state. Fixed:
     nil canonical cursor when any stream lacks entry.
  7. Left T100 as implicit "needs clarification" instead of explicit
     out-of-scope declaration.
  8. Phase 2 completion gate lacked compiler-error-first migration
     proof requirement. Fixed: zero direct writes is a compiler-
     verifiable gate.

---

## Appendix: Preserved Notes

### Preserved from deleted non-core doc: t113-t104-retro.md

**T104/SBB regression root causes:**

A) Stale snapshot reuse caused "opens near top":
- Non-animated programmatic scroll (`setContentOffset(..., animated: false)`) does NOT trigger `scrollViewDidEndScrollingAnimation`.
- `lastKnownScrollSnapshot` was only refreshed on user scroll/deceleration paths.
- On stream switch, if flush hits geometry-unavailable path, stale near-top snapshot gets used.
- Fix: refresh `lastKnownScrollSnapshot` after ALL non-animated programmatic offset changes (restore apply, restore fallback-to-bottom, `scrollToBottom`, `scrollToMessageCentered`, `adjustContentOffsetForBottomInsetChange`).

B) SBB visibility not emitted on stream switch entry:
- `prepareIncomingStateOnSwitch` correctly sets per-stream `sbbState`.
- But `ChatView` SBB visibility is driven by `.isAtBottomChanged` scroll events.
- Without guaranteed event emission immediately after stream switch, UI retained stale hidden state.
- Fix: add `emitHideIndicatorIfChanged(force: true)` on stream-context seam key selection paths in `runStreamContextSwitchSeam`.

**Architecture was correct; implementation had two conformance gaps.**

### From: specs/t113-architecture-plan-review.md

**T113 architecture review verdict: APPROVED** for ticket-closure scope.

Key constraints from review:
- T099 cursor rule: canonical auth cursor = nil when ANY known stream lacks cursor; max only when ALL have cursors; active-session/global fallback explicitly forbidden.
- T100 is explicitly out of scope for T113 closure.
- T105 closure requires compiler-verifiable zero direct writes outside the seam (private backing store + `unavailable` legacy APIs), not just interface design.
- Callback-registry + `forceReRead` wiring are required gates (not optional polish) for T095/T103.
