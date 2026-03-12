# Per-Stream State Encapsulation (T095 / T099 / T103 / T104 / T105)

## Goal
Define one architectural system that fixes the shared failure surface behind:
- T095 / #98: scroll position not preserved on stream re-read/initial populate.
- T099 / #99: initial login streams stale/empty due to global replay cursor ownership.
- T103 / #104: stream switch lands mid-stream instead of bottom/last position.
- T104 / #105: SBB missing after stream switch until full scroll cycle.
- T105 / #113: canonical message insertion seam dependency for per-stream ownership coherence.

This spec unifies these as a single session-ownership and lifecycle problem in `MessageFlowCollectionViewController`, not three independent bugs.

## Non-Goals
- No reset-on-switch patches.
- No global behavior changes outside scroll/SBB and directly-coupled runtime state.
- No new read/unread product semantics beyond existing SBB/unread invariants.

## Architectural Primitive: Stream-Context Switch Seam

### Definition
A **stream-context switch seam** is the single transition path that moves controller runtime ownership from one `sessionKey` to another.

`sessionKey` is the ownership seam. Switching streams selects a different state entry. It does not reset global controller fields.

### Trigger Conditions
The seam fires whenever the effective render session for this controller instance changes, including:
1. `update(...)` resolves a different effective `sessionKey` than the last applied one.
2. A previously offscreen/prewarm page becomes eligible to apply active updates and its effective key is resolved.
3. A forced re-read event for the same key requests a new restore attempt generation.

Case split:
- `outgoingSessionKey != incomingSessionKey`: full switch handoff contract applies.
- `outgoingSessionKey == incomingSessionKey` (same-key re-read): run re-read rearm path only (no switch flush).

Effective render key definition:
- For this controller, `effectiveSessionKey` is the explicit `sessionKey` passed into `MessageFlowCollectionViewController.update(...)` from the coordinator/page wiring.
- The switch seam fires only when this `effectiveSessionKey` differs from the last applied effective key.
- The controller does not derive switch ownership from `uiSelectedSessionKey` directly.
- Coordinator requirement: this `sessionKey` must be sourced from `engineActiveSessionKey`, not `uiSelectedSessionKey`.

### Required Ordering (Contract)
The seam must execute this order atomically on main actor:
1. Identify `outgoingSessionKey` and `incomingSessionKey`.
   - `outgoingSessionKey` is `lastAppliedEffectiveSessionKey`.
   - `incomingSessionKey` is current `effectiveSessionKey` from `update(...)`.
   - First-activation path: if `lastAppliedEffectiveSessionKey == nil`, treat as no-outgoing-key case, skip step 2 and step 3, and continue at step 4.
2. Flush outgoing scroll persistence immediately (`persistScrollStateNow(outgoingSessionKey)`) before any key mutation.
3. Cancel outgoing per-stream timers/queued deferred actions owned by the outgoing key.
4. Resolve/create incoming per-stream runtime entry.
5. Load incoming persistence key + pending restore metadata into that incoming entry.
6. If persisted state is validly loaded in step 5:
   - initialize incoming SBB state from persisted `atBottom` (`.atBottom` when true, `.scrolledUp`/`.scrolledUpUnread` when false and unread is present),
   - set incoming `restorePhase` by stage:
     - `.pendingTail` when incoming materialization stage is tail-first,
     - `.pendingFullConfirmation` when staging is not active or stage is already full.
   Otherwise apply deterministic bottom fallback and set incoming `restorePhase = .none`.
7. Continue normal update/materialization flow.
8. Set `lastAppliedEffectiveSessionKey = incomingSessionKey` at the end of step 6 (before step 7 heavy render work).

No step in this contract may be bypassed by debounce timers.

Flush requirement detail: outgoing persistence must be computed from outgoing-key geometry/state captured before rebinding incoming key. Reading effective key after mutation is forbidden for switch-time flush.

Same-key re-read rule: when `outgoingSessionKey == incomingSessionKey`, skip step 2 and do not run full step-3 cancellation; cancel only that key's `scrollStateWriteDebounceTimer` so pre-re-read debounce writes cannot overwrite the persisted anchor.

### Offscreen / Frozen Rule
The seam preparation (steps 1-6 above) must run before any offscreen early return path. Offscreen/prewarm pages may skip heavy snapshot apply, but may not skip ownership normalization and restore preparation.

`isRenderPolicyFrozen` must suppress only heavy render work. It must not suppress stream-context ownership transitions, restore-phase bookkeeping, or outgoing flush-on-switch.
Implementation ordering constraint: in `update(...)`, stream-context seam steps 1-6 execute before `isRenderPolicyFrozen` and offscreen early-return guards. Those guards apply only to step 7 and later heavy render work.
Coordinator obligation: when `isRenderPolicyFrozen` transitions from `true` to `false`, coordinator must schedule a follow-up `update(...)` for the same controller context so suspended step-7 work resumes.

### Adversarial Review Resolution Notes
The following blocking review items are normative and incorporated in this spec:
- `lastAppliedEffectiveSessionKey` is the authoritative seam key and is set at step 8 above (before heavy render work).
- Scroll delegate callback writes are bound to `lastAppliedEffectiveSessionKey` (no dynamic key fallback during seam execution).
- Restore phase initialization is stage-aware (`pendingTail` for tail stage, `pendingFullConfirmation` when tail stage is skipped/full-only).
- Incoming SBB initialization derives from persisted `atBottom` on switch-in.
- Frozen render/unfreeze requires coordinator-driven follow-up `update(...)` to resume suspended step-7 work.

## State Ownership Model

## Per-stream aggregate
Introduce `PerStreamRuntimeState` in `MessageFlowCollectionViewController` and store it by `sessionKey`:
- `perStreamStateBySessionKey: [String: PerStreamRuntimeState]`

Flynn seam requirement is explicit: SBB ownership is `sbbStateBySessionKey[sessionKey]`. In this architecture, that seam is preserved via the per-stream entry (`perStreamStateBySessionKey[sessionKey].sbbState`) and never via controller-global SBB fields.

### `PerStreamRuntimeState` contents (required)
- SBB runtime
  - `sbbState`
  - `lastReportedHideIndicator`
  - `lastSeenBottomInsetForSBB`
- Unread/flash anchors
  - `firstUnreadMessageId`
  - `unreadCount`
  - `firstUnreadWasBelowViewportCenter`
  - `didCrossAndClearFirstUnreadId`
  - `pendingFlashMessageId`
  - `pendingFlashIsUnreadTap`
- Scroll persistence runtime
  - `pendingScrollRestoreState`
  - `restorePhase` (`none | pendingTail | pendingFullConfirmation | confirmed`)
    - `none`: no restore pending (initial state and no-persisted-state path after bottom fallback)
    - `pendingTail`: persisted state exists and tail-stage restore attempt is pending
    - `pendingFullConfirmation`: tail attempt could not confirm; full-stage retry pending
    - `confirmed`: restore confirmed or bounded fallback applied
  - `restoreGeneration` (monotonic per-stream restore token incremented on switch-in and same-key re-read)
  - `restoredScrollGenerations` (generation-aware replacement for one-shot `restoredScrollKeys`)
  - `lastKnownScrollSnapshot` (latest `(atBottom, distanceFromBottom, timestamp)` for owner key)
  - `scrollStateWriteDebounceTimer`
  - `registeredMessageLoadCallbacksByMessageId` (one-shot callback registry keyed by `(sessionKey, messageId)`)
- Scroll-to-bottom/deferred scroll flags
  - `lastMessageId`
  - `pendingScrollToBottomAfterInteractionEnd`
  - `pendingScrollToBottomAttempts`
  - `pendingScrollToBottomAnimated`
- Typing/morph handoff state
  - `wasShowingTypingIndicator`
  - `morphTargetMessageId`
  - `deferScrollToBottomUntilMorphCompletes`
- Message-id keyed sizing/runtime caches
  - `fingerprints`
  - `sizeCache`
  - `lastMeasuredSizes`
  - `pendingReconfigureIds`
  - `dirtySizeIds`
  - `pendingEntranceAnimationIds`
- BubbleSizingV2 per-stream state
  - `bubbleSizingV2KeysByMessageId`
  - `bubbleSizingV2LinkPreviewStateVersionByMessageId`
  - `bubbleSizingV2RemeasureBatchStartTime`
  - `bubbleSizingV2RemeasureDeferredUntilNearBottom`
  - `bubbleSizingV2PendingRemeasureIds`
  - `bubbleSizingV2RemeasureDebounceTimer`
  - `bubbleSizingV2DeferredFlushTimer`
- Bottom inset remeasure state
  - `deferredBottomInsetRemeasureIds`
  - `bottomInsetRemeasureTimer`
  - `bottomInsetRemeasureBypassInputGates`
  - `pendingBottomInsetHeightCapInvalidation`
- Per-stream pending work queues (deferred autoscroll and related actions)

Message-id keying strategy:
- Use per-stream maps inside `PerStreamRuntimeState` as the default strategy for message-id keyed state.
- Where a shared controller-global cache exists (for example BubbleSizingV2 measurement LRU), cache keys must include `sessionKey` in their identity so stream cleanup cannot evict another stream's active entries.

### Already per-stream (no ownership change)
- `materializationStateBySessionKey`
- `lastMaterializationPlanBySessionKey`

### Controller-scope only (must remain controller/view-instance scoped)
- UIKit objects/delegates: `collectionView`, `dataSource`, `flowLayout`, `uiKitBubbleSizer`
- Environment/layout inputs: `isCompact`, `isActiveSession`, `isRenderPolicyFrozen`, `isInputActive`, `topInset`, `truncationBottomInset`, `lastBoundsSize`, `currentBottomInset`, `currentIsDark`
- Global telemetry: `bubbleSizingV2LastScrollActivityTime`, `isPostingSalientScrolling`
- Controller update-cycle flags: `forceReconfigureAll`, `invalidationScheduled`
- Switch seam tracking: `lastAppliedEffectiveSessionKey`
- Layout engine internal caches owned by `MessageFlowLayout`

## Mutation Seams (Single-path Rule)

### Required APIs
All per-stream mutable runtime access must go through explicit session-keyed seams:
- `readState(for sessionKey: String) -> PerStreamRuntimeState` (read-only snapshot)
- `mutateState(for sessionKey: String, _ body: (inout PerStreamRuntimeState) -> Void)`

Read/write seam rule:
- Any read that gates a write must happen inside `mutateState(for:_:)` to avoid read-then-write TOCTOU drift.
- Callers must not cache `readState(...)` results and later mutate via a separate path.

All transition/event APIs that mutate per-stream runtime must take explicit `sessionKey`:
- `handleUserScrolled(sessionKey:)`
- `schedulePersistScrollState(sessionKey:)`
- `persistScrollStateNow(sessionKey:)`
- `attemptRestoreScrollIfNeeded(sessionKey:stage:)`
- `scheduleScrollToBottom(sessionKey:...)`
- `performPendingScrollToBottomIfNeeded(sessionKey:)`

Direct writes to migrated fields outside these seams are boundary violations.

### Canonical message write seam dependency (T105 / #113)
This spec governs per-stream runtime ownership for read/query/runtime-state behavior in `MessageFlowCollectionViewController` and related coordinator wiring.

Canonical message-store writes (insert/update/remove/clear) are owned by **T105**:
- `/Users/mike/shared-workspace/clawline/specs/message-stream-seam.md`

Coherence rule between specs:
- Per-stream-state-encapsulation owns runtime state selection/read behavior keyed by `sessionKey`.
- Message-stream-seam (T105) owns all message collection writes via canonical insertion protocol keyed by `(sessionKey, id)` with server-wins and cache gap-fill.
- Any code path that mutates message collections directly outside T105 seam is a spec violation, even if session-keyed.
- Per-stream runtime logic in this spec must consume message state produced by T105 seam; it must not introduce alternative message write paths.

UIKit delegate key-binding rule:
- Scroll delegate callbacks (`scrollViewDidScroll`, drag/end callbacks, programmatic-scroll completion hooks) must route through `lastAppliedEffectiveSessionKey`, not dynamic `resolvedSessionKey()` fallback, so callbacks during seam execution cannot target incoming key early.

## Reload/Re-read Trigger Contract

All full reload/re-read paths are explicit and normalized through one re-read seam.

Normalized reload triggers:
1. Cache restore apply path (`restoreCachedMessagesIfNeeded` applies a full array).
2. Reconnect replay path (transport reconnect/bootstrap replay).
3. Cursor-clear path (cursor reset for one stream after cache miss/invalid cache/delete).
4. Siri intent connect path (intent-driven connect without prior in-process stream context).

Rule:
- `forceReReadGeneration` is the single manual/same-key re-read entry point into `MessageFlowCollectionViewController.update(...)`.
- Trigger sources above must explicitly increment `forceReReadGeneration` for the affected `sessionKey`.
- No other path may infer re-read implicitly from global state.

## Scroll Persistence + Restore Lifecycle

### Flush-on-switch contract (fix RC-B)
- Debounce timers are allowed only as a batching optimization while staying in one key.
- On stream-context switch, outgoing key must always flush immediately and cancel its debounce timer.
- Debounce callback must execute with captured `sessionKey` and no implicit reliance on mutable active key.
- If live geometry is unavailable at flush time, write `lastKnownScrollSnapshot` from outgoing state entry instead of skipping flush.
- `lastKnownScrollSnapshot` must be refreshed on every successful persist write and every user/programmatic scroll-settle event for that owning key.

### Stage-aware restore contract (fix RC-A)
Restore is two-phase with explicit confirmation:
1. `pendingTail`: load persisted target and attempt best-effort restore during tail stage.
2. If target cannot be validated (anchor not materialized or offset clamped by tail window), move to `pendingFullConfirmation` instead of `confirmed`.
3. On tail->full expansion completion (or first full-stage layout pass), retry restore.
4. First restore attempt is event-driven: trigger on the configured message-appearance callback (not blind timer retry loops).
5. Mark `confirmed` only when full-stage geometric confirmation succeeds, or a deterministic fallback is applied.
6. If async size changes (image/link preview remeasure) move geometry after full-stage retry, keep `pendingFullConfirmation` and retry on the next eligible layout pass.
7. Confirmation window is bounded (max 3 confirmation retries per restore generation); if still unresolved, apply deterministic bottom fallback and mark `confirmed`.

One-shot restore lockout is forbidden.

### One-shot on-message-load callback registry

Purpose: deterministic message-materialization-triggered actions without polling loops.

Ownership:
- Per-stream inside `PerStreamRuntimeState`.
- Keyed by `(sessionKey, messageId)`.

Required behavior:
1. Register one-shot callback for `(sessionKey, messageId)`.
2. Fire callback after layout pass completes for that message.
3. Fire immediately at registration if message is already materialized/layout-resolved.
4. Auto-expire callbacks on stream switch-away and on message deletion/removal.
5. One-shot semantics: callback fires at most once.

Allowed uses:
- Scroll-to-message targeting.
- Flash/highlight targeting.
- Unread-anchor targeting.

Disallowed uses:
- Geometric bottom/distance restore fallback logic.
- General-purpose cross-feature event bus.

### Restore/switch race guard
Every restore attempt carries `(sessionKey, restoreGeneration, materializationStage)` token.
- Completion callbacks must verify token matches current per-stream state entry before mutating.
- If stream-context seam switches away during pending restore, outstanding restore callbacks for prior key no-op.
- Full-stage retry for prior key must not run after a different key becomes active in this controller context.

### Fallback semantics
If persisted state is absent, invalid, or stale for incoming stream:
- Initialize incoming stream to deterministic bottom fallback.
- Initialize SBB state as pinned-at-bottom for that stream.
- Do not inherit prior stream pinned/scrolled intent.

### Same-key re-read semantics
A same-session re-read/initial-repopulate must be able to re-arm restore even when key is unchanged.
- Replace single `restoredScrollKeys` behavior with per-stream restore generation token.
- Re-read increments generation and allows restore attempt for that generation.
- Same-key re-read must reset restore phase to `pendingTail` for the new generation before tail apply begins.
- Re-read path must reload persisted state for that key from durable storage before first restore attempt of the new generation.
- Re-read path must not persist current in-memory geometry until the new generation reaches `confirmed` (or deterministic fallback confirmation).
- If the user scrolls during pending restore for that generation, cancel pending restore, set `restorePhase = .confirmed`, and resume normal persistence immediately (user intent overrides restore intent).

Re-read signal definition:
- Same-key re-read is explicitly signaled by a `forceReReadGeneration` advance on `update(...)`.
- Normal same-key `update(...)` calls with unchanged `forceReReadGeneration` must not rearm restore generation.

## SBB Encapsulation + Threshold Alignment

### Ownership rule (fix RC-C)
SBB state is session-owned and selected by key. Stream switch is key selection, not state reset.

### Required behavior
- Visibility is derived from per-stream SBB state machine only.
- Only explicit user upward scroll transitions out of pinned-at-bottom.
- Non-user geometry/content mutations while pinned must not force scrolled-up state.

### Threshold semantic alignment (critical)
Use one semantic definition for “at bottom” across:
- SBB hide/show logic.
- Auto-scroll eligibility logic for appended messages.
- Restore fallback-to-bottom checks.

Any threshold split (different constants/interpretations) is a spec violation.

Implementation constraint: all three call sites above must use a shared helper and threshold source, not duplicated constants.

## Timer / Queue Ownership

All timers and deferred queues that influence scroll/SBB must be owned by `PerStreamRuntimeState` entry.

Rules:
1. Timer creation stores owning `sessionKey`.
2. Timer callback validates both owning `sessionKey` and owning generation token before mutating state.
3. Stream switch cancels only outgoing stream timers/queues.
4. Incoming stream timers/queues remain intact unless explicitly replaced by incoming events.
5. Deferred work scheduled on main queue must be cancellable (`DispatchWorkItem`) and generation-gated in callback body.
6. `DispatchWorkItem.cancel()` is cooperative; callback body must check `isCancelled` before any state mutation.

Known hot path requirement:
- Pending scroll-to-bottom retry work (currently recursive main-queue scheduling) must be converted to cancellable or generation-gated work items so retries from stream A cannot execute in stream B.

The same ownership rule applies to deferred async work items (for example tail->full promotion and restore retries): schedule by session-owned token and key-validate before apply.

This prevents deferred work from stream A mutating stream B (RC-D).

## Transport Replay Cursor Encapsulation (T099 / #99)

### Problem statement
Initial login and early stream activation can present stale/empty streams when replay progress is tracked in one global cursor instead of per-stream ownership.

Replay cursor ownership follows the same seam rule as UI runtime ownership: cursor state must be keyed by `sessionKey`, never global.

### Ownership rule
- Replay cursor state is transport-layer per-stream runtime and must be stored as:
  - `replayCursorBySessionKey[sessionKey]` (or equivalent per-stream store entry).
- A single global replay cursor for multiple streams is a spec violation.
- Storage location is transport-layer (`ProviderChatService` or equivalent), not `ChatViewModel` UI runtime state.

### Mutation seam rule
- All replay cursor writes and reads must take explicit `sessionKey`.
- Transport APIs that request replay/fetch/continuation must accept `sessionKey` and resolve cursor only from that key's entry.
- Missing explicit key must no-op (same key-resolution guardrail as UI seams); no fallback to active/global key.
- Reconnect snapshot must read all per-stream cursors from transport snapshot state, not only active-session cursor.

### Switch and bootstrap behavior
- Stream switch does not reset or overwrite other streams' replay cursors.
- Login/bootstrap may start multiple stream replays concurrently, but each replay advances only its own cursor entry.
- Same-key re-read/bootstrap refresh for one stream may replace only that stream cursor, not siblings.
- Stream deletion must prune that stream cursor entry.

### Apply safety
- Replay result apply callbacks must be tokened with `(sessionKey, generation)` and key-validated before applying messages/cursor updates.
- Late replay completions for stream A must no-op when routed into stream B context.

### T099 acceptance checks
- Initial login with multiple streams restores each stream from its own replay cursor; no cross-stream stale/empty contamination.
- Switching streams during replay cannot advance or reset another stream cursor.
- Recreated stream keys start replay from their own fresh bootstrap path; deleted keys retain no live cursor callbacks.

## Per-Stream Lifecycle Cleanup

`perStreamStateBySessionKey` must be pruned when `orderedSessionKeys` changes.

Rules:
1. On stream deletion, remove that stream's runtime entry and cancel all timers/work items owned by that key.
2. If a deleted key is later recreated, it starts with fresh runtime entry (except persisted scroll state loaded through normal restore path).
3. Any callback targeting a missing key after prune must no-op.

## Integration with Existing Stream Switch Architecture

This spec is compatible with two-key stream switching in `ChatViewModel`:
- `uiSelectedSessionKey` remains immediate intent.
- `engineActiveSessionKey` remains heavy activation key.

Controller state transitions in this spec are keyed by the `effectiveSessionKey` definition above and do not alter two-key ownership in `ChatViewModel`.

`ChatView`/coordinator wiring must continue passing explicit `sessionKey` into list events and callbacks so per-stream mutation seams stay explicit.

Key-resolution guardrail: migrated mutation paths must not fall back to `engineActiveSessionKey` when explicit `sessionKey` is missing. If key is unavailable, mutation must no-op and wait for a resolved key.

Message write/read boundary guardrail:
- `ChatViewModel` message mutations must route through T105 canonical seam operations only.
- `MessageFlowCollectionViewController` and `ChatView` must treat message arrays as seam outputs and must not perform direct write surgery on session message collections.

SBB invariants alignment note:
- Stream switch is a context-selection operation above the per-stream SBB state machine.
- It does not introduce a new SBB transition event; it selects a different per-stream machine instance by key.

## Migration Strategy (Compiler-error-first)

1. Introduce `PerStreamRuntimeState` and storage map in `MessageFlowCollectionViewController`.
2. Add mutation seam helpers (`readState(for:)`, `mutateState(for:_:)`).
   - Extend `update(...)` to include explicit `forceReReadGeneration: Int = 0`.
3. Migrate SBB fields first (`sbbState`, `lastReportedHideIndicator`, `lastSeenBottomInsetForSBB`) and update all write paths.
4. Migrate scroll persistence fields and convert persistence/restore APIs to explicit `sessionKey` args.
5. Migrate timers/queues into per-stream entries; attach owner-key checks in callbacks.
6. Migrate unread/typing/morph/deferred-scroll flags and message-id keyed caches.
7. Remove old controller-global fields; rely on compiler errors to find remaining direct references.
   - Remove `scrollPersistenceKey` as a controller-global field; per-stream restore state replaces it.
8. Implement stream-context switch seam ordering and offscreen normalization ordering.
9. Implement stage-aware restore phases and same-key restore generation support.
10. Add compile-time/remove-old-field sweep and runtime assertions in debug builds for keyless mutation entry points.
11. Build a write-path matrix for each migrated field group (all write call sites must be session-keyed seams).
12. Move replay cursor ownership/persistence from `ChatViewModel` to transport layer seam (`ProviderChatService` or equivalent) and migrate reconnect snapshot reads to transport cursor snapshot API.
13. Run required tests below; resolve any path still mutating without explicit key.

## Required Tests

1. Stream A scrolled-up -> switch B -> switch back A: A restores previous position and SBB state.
2. First activation with tail->full materialization: persisted restore target resolves correctly after full-stage retry.
3. Pending debounce/timers from A do not mutate B after switch.
4. Drag/morph deferral from A does not auto-scroll B.
5. SBB is correct immediately after switch when incoming stream is not at bottom.
6. Same-key re-read re-arms restore and lands at persisted position (or deterministic bottom fallback if invalid).
7. No persisted state path starts at bottom; no inherited pinned/scrolled state from prior stream.
8. Frozen render / unfreeze path does not expose stale prior-stream SBB or scroll runtime.
9. Prewarm/offscreen pages do not mutate active-stream runtime and do not skip context normalization.
10. Message-ID collisions across streams do not cross-contaminate caches/queues.
11. Stream switch while restore is `pendingFullConfirmation` does not apply stale retry into the new stream context.
12. Async size changes after full-stage expansion do not strand restore mid-stream; bounded confirmation retries converge deterministically.
13. Deleted stream keys are pruned; no stale timers/callbacks mutate recreated or other streams.
14. Any mutation callback without explicit resolved `sessionKey` no-ops (no fallback mutation of active stream).
15. Same-key re-read does not overwrite persisted anchor before restore confirmation; persisted prior anchor remains available to the re-read generation.
16. Stream switch from A (with messages) to B (with messages): B update classification uses B's per-stream `lastMessageId` and does not treat A's tail as B append.
17. Frozen->unfrozen transition triggers follow-up `update(...)` and pending restore progresses to completion.
18. Scroll delegate callbacks during seam execution mutate outgoing stream entry (bound by `lastAppliedEffectiveSessionKey`), never incoming stream entry early.
19. Replay cursor progress is isolated per stream on initial login/bootstrap; no global cursor sharing.
20. Concurrent replay across streams cannot advance sibling stream cursor state.
21. Replay callbacks with stale `(sessionKey, generation)` no-op and do not apply into another stream context.
22. Message writes remain exclusively in T105 canonical insertion seam; no direct message-store writes are introduced by per-stream-state migration.
23. On-message-load callback registry fires once per `(sessionKey, messageId)`, fires immediately when already materialized, and expires on stream switch-away and message deletion.
24. Reload trigger normalization: cache restore, reconnect replay, cursor clear, and Siri intent paths each increment the single re-read seam (`forceReReadGeneration`) for the affected stream context.
25. Transport replay cursor storage is owned by transport layer; `ChatViewModel` holds no per-stream replay cursor persistence map.

## Success Criteria by Ticket

### T095 / #98
- Re-read/initial populate no longer strands at incorrect position due to one-shot restore lockout.
- Same-key restore generation enables valid re-restore behavior.

### T103 / #104
- Stream switch deterministically resolves to persisted position or bottom fallback.
- Outgoing pending debounce cannot overwrite incoming key’s persistence state.

### T104 / #105
- SBB state is per-stream and selected by session key.
- Missing/phantom SBB after switch is eliminated by state ownership + threshold alignment.

### T099 / #99
- Replay cursor ownership is per-stream; no global cursor cross-contamination at login or switch time.
- Initial stream load no longer lands stale/empty due to sibling stream replay progress.
- Cursor persistence/mutation ownership resides in transport layer (not UI view model), and reconnect snapshot reads all per-stream cursors.

### T105 / #113 alignment requirement
- Per-stream-state implementation remains coherent with T105 by treating message-store mutation as canonical seam-owned write infrastructure.
- UI/runtime per-stream ownership in this spec does not create or retain competing message write paths.

## Implementation Handoff Notes

Primary implementation surface:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift`
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`

Related behavioral constraints to preserve:
- `specs/scroll-to-bottom-invariants.md`
- `specs/scroll-to-bottom-button.md`
- `specs/staged-stream-materialization.md`
- `specs/stream-switch-coordinator.md`
- `/Users/mike/shared-workspace/clawline/specs/message-stream-seam.md` (canonical write seam for message mutations)

No unspecced defensive additions. If an implementation gap appears, update this spec first.

---

## Appendix: Preserved Notes

### Preserved from deleted non-core doc: per-stream-cv-analysis.md

**TabView vs show/hide for per-stream MessageFlowCollectionView:**

The `per-stream-state` branch used a paged `TabView` (one MFCV per tab). Because `TabView` can recycle off-screen pages, each stream switch behaves like a context hand-off — triggering the full switch-seam pipeline even though each tab has its own MFCV instance.

**Switch-seam complexity introduced by TabView approach (approximate line counts deletable with show/hide):**
The branch added these exclusively to manage the TabView recycling/timing problem:
- `PerStreamRuntimeState` struct (per-stream mutable state centralized)
- `runStreamContextSwitchSeam` (switch ownership handoff function)
- Two-key ChatViewModel split: `uiSelectedSessionKey` vs `engineActiveSessionKey`
- Epoch-based debounced engine activation with pager interaction/settle signals
- `isRenderPolicyFrozen` flag to block heavy render work during pager animation
- Two-phase scroll restore (`pendingTail → pendingFullConfirmation → confirmed`)
- Zero-sections guard in `MessageFlowLayout.prepare()`

**Show/hide proposal advantages:**
- Stream switching becomes a `view.isHidden` toggle — no timing race.
- Large portions of the switch-seam code (several hundred lines in MFCV + ChatViewModel) become deletable.
- `runStreamContextSwitchSeam`, epoch debounce, render-freeze, two-phase scroll restore all become unnecessary.

**Key constraint:** Show/hide requires allocating all stream views up front (memory tradeoff vs TabView's lazy recycling). For typical 2–5 Clawline streams, this is acceptable.

---

### Preserved from deleted non-core docs: t113-spec-gap-analysis.md + t113-transition-surface-audit.md

**Transition Surface Contract (three rules that prevent integration bugs by construction):**

**Rule 1: No silent defaults on session-critical parameters.**
Any method parameter that controls session binding must be required (no default value) or must have a provably safe default for ALL existing callers. If a safe default is impossible, the parameter must be required. (Prevents boundary bugs like TS-1 where `viewDidLayoutSubviews` calls `update()` with missing session-critical parameters.)

**Rule 2: Universal async continuation rule.**
Any closure executing after yielding the main actor that touches per-stream state must capture and validate `(sessionKey, generation)`. This applies to EVERY `DispatchQueue.main.async`, every `UIView.animate` completion, every `scrollViewDidEnd*` delegate — not just timers. Property shims (computed properties routing through `activeStateKey()`) are only safe in synchronous call paths where `activeStateKey()` is stable within a single main-actor turn.

**Rule 3: Async lifecycle cleanup invariant.**
Any per-stream state set synchronously as a pre-condition for an async operation (e.g., setting `morphTargetMessageId`) must be cleaned up in ALL exit paths of the async continuation, including guard-failure early returns.

**Meta principle:** Specs for per-stream state must model the boundary between new and existing code, not just the new subsystem in isolation. Every integration bug found in T113 audit lived at the old↔new boundary, not in the new code itself.

**SBB emission idempotency rule:**
- Forced emission (`force: true`) is permitted only on session switch (new session's state must be reported) and on transitions that invalidate the emission cache.
- Steady-state path must use change detection (`lastReportedHideIndicator != shouldHide`), not forced emission. Prevents per-frame dictionary mutations in SwiftUI state.
