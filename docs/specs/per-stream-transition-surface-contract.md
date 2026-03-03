# Per-Stream Transition Surface Contract

**Parent spec:** `per-stream-state-encapsulation.md`
**Derived from:** T113 transition surface audit, re-audit, and spec gap analysis (`retros/t113-spec-gap-analysis.md`)

This contract governs the boundary between per-stream state infrastructure and the code that uses it. The parent spec defines how per-stream state works internally. This spec defines the obligations that per-stream state imposes on every caller, old or new.

---

## 1. Temporal Model of Per-Stream State

### 1.1 Definitions

**Synchronous epoch.** A contiguous, non-yielding main-actor execution span. An epoch begins when the main-actor runloop dispatches a unit of work (an `update()` call, a UIKit layout pass, a GCD block, a timer fire) and ends when that unit returns control to the runloop. Within one epoch, `activeStateKey()` and `lastAppliedEffectiveSessionKey` are stable — they cannot change because the seam only runs inside `update()`, and `update()` is not re-entrant.

**Yield boundary.** Any point where execution suspends the current synchronous epoch and resumes in a future one. Yield boundaries include:
- `DispatchQueue.main.async` / `.asyncAfter`
- `UIView.animate` completion blocks
- `Timer` fire callbacks
- `dataSource.apply` completion blocks
- `NotificationCenter` selector/closure dispatch
- Registered one-shot callbacks (e.g., `registeredMessageLoadCallbacksByMessageId`)
- Cell-configure closures that fire on user interaction or async content updates
- `scrollViewDidEndScrollingAnimation` (fires in a later epoch than the `setContentOffset` that triggered it)

**Session binding.** The association between a unit of deferred work and a specific `(sessionKey, generation)` pair captured at the moment the work was scheduled.

**Session generation token.** A `(sessionKey: String, generation: Int)` pair obtained from `activeSessionGenerationToken()` at capture time. The generation is the `restoreGeneration` of the session's `PerStreamRuntimeState` at the moment of capture.

### 1.2 The Epoch Rule

Per-stream state access is classified by its relationship to the epoch in which the state was last bound:

| Access type | When it occurs | Safe access method | Example |
|---|---|---|---|
| **Bound-epoch access** | Within the same `update()` call or its synchronous continuations (layout, `cellForItem`, snapshot build) | Shim properties (`activeStateKey()`) | Reading `sbbState` during snapshot apply |
| **Reactive access** | UIKit delegate callbacks (`scrollViewDidScroll`, `willDisplay`, drag/decelerate end) firing within a layout or scroll pass | `callbackSessionKey()` → explicit `sessionKey` parameter | `handleUserScrolled(sessionKey:)` |
| **Deferred access** | Any closure executing in a future epoch (after a yield boundary) | Captured `(sessionKey, generation)` token, validated before access | Timer callback, GCD async block |

**Invariant: Shim access after a yield boundary is a spec violation.** Property shims route through `activeStateKey()`, which reflects whatever session was most recently bound. After a yield boundary, the bound session may have changed. Any per-stream state read or write in deferred-access context must use an explicitly captured session key, never a shim property.

### 1.3 Epoch Stability Guarantee

Within a single synchronous epoch, the following are guaranteed stable:
- `lastAppliedEffectiveSessionKey`
- `activeStateKey()` return value
- `callbackSessionKey()` return value
- All shim property routing

These guarantees hold because:
1. The stream-context switch seam runs only inside `update()`.
2. `update()` is not re-entrant (it is a synchronous method on `@MainActor`).
3. UIKit layout and scroll callbacks fire within the same runloop turn as the `update()` that triggered them.

The guarantee does NOT extend across yield boundaries. Any of the above may change between the scheduling epoch and the execution epoch of deferred work.

---

## 2. Async Continuation Contract

### 2.1 The Universal Guard Rule

Any closure that executes after a yield boundary and reads or writes per-stream state must:

1. **Capture** a session generation token at schedule time:
   ```swift
   guard let token = activeSessionGenerationToken() else { return }
   ```

2. **Validate** the token at execution time, before any per-stream state access:
   ```swift
   guard self.callbackSessionKey() == token.sessionKey else { return }
   guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
   ```

3. **Use the captured `token.sessionKey`** for all explicit-key API calls within the deferred block. Never re-derive the key from `callbackSessionKey()` or `activeStateKey()` after validation — the validated token is the authority.

This rule applies universally to:
- `DispatchQueue.main.async` / `.asyncAfter` blocks
- `UIView.animate` completion blocks
- `Timer` fire callbacks
- `DispatchWorkItem` execution bodies
- `dataSource.apply` completion blocks
- Registered one-shot callbacks (`registeredMessageLoadCallbacksByMessageId`)
- Cell-configure closures that fire on async content updates (e.g., link preview height changes)

### 2.2 Exceptions to the Universal Guard Rule

Two categories of deferred access are exempt from the full `(sessionKey, generation)` guard:

**Fire-and-forget visual tweens.** `UIView.animate` blocks (not completion blocks) that only modify cell visual properties (`alpha`, `transform`, `frame`) without reading or writing per-stream state. These are cosmetic and self-correcting on the next layout pass. Example: entrance animation at `willDisplay`.

**Resign-active persistence.** `UIApplication.willResignActiveNotification` handlers that persist the current session's scroll state using live `callbackSessionKey()`. This is correct because the purpose is to snapshot whatever session is currently displayed, regardless of whether it matches a previously scheduled intent. There is no "expected" session — the handler always wants the current one.

### 2.3 The `dataSource.apply` Completion Special Case

`dataSource.apply` completions fire in the same runloop turn as the apply call when `animatingDifferences: false`, but in a later turn when `animatingDifferences: true`. Regardless of animation mode, the completion must be treated as a yield boundary and guarded.

The recommended pattern for `dataSource.apply` completions is to capture the `effectiveSessionKey` at schedule time and validate `callbackSessionKey() == capturedKey` in the completion. Generation guards are not required for `dataSource.apply` completions because the apply is the direct continuation of the current `update()` call and the generation cannot change between apply-start and completion within the same update cycle. If the apply uses `animatingDifferences: true`, generation validation is recommended.

---

## 3. Async Operation Lifecycle

### 3.1 The Setup-Yield-Resume-Cleanup Model

Any per-stream operation that sets state synchronously and defers cleanup to an async continuation has four phases:

```
┌─────────────────────────────────────────────────────┐
│ CAPTURE PHASE (synchronous)                         │
│  1. Capture session generation token                │
│  2. Set pre-condition state in per-stream entry     │
│     (e.g., morphTargetMessageId = targetId)         │
│  3. Record what was set (for cleanup obligations)   │
└──────────────────────┬──────────────────────────────┘
                       │ yield boundary
┌──────────────────────▼──────────────────────────────┐
│ RESUME PHASE (async)                                │
│  4. Validate token against current state            │
│  5a. Token matches → proceed with operation         │
│  5b. Token mismatches → ABORT with cleanup          │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│ CLEANUP PHASE (always runs, both paths)             │
│  6. Clear all pre-condition state set in step 2     │
│  7. Release any resources (remove views, etc.)      │
└─────────────────────────────────────────────────────┘
```

**The cleanup invariant:** Every per-stream state value set in the capture phase must be cleared in ALL exit paths of the resume phase. This includes:
- The success path (operation completed normally).
- The guard-failure path (session or generation mismatch).
- The early-return path (data not available, e.g., cell not found).

**Why this matters:** If cleanup is skipped on guard failure, the per-stream state retains values from an abandoned operation. These stale values persist in `PerStreamRuntimeState` and affect future visits to that session. Example: a stale `morphTargetMessageId` causes `willDisplay` to suppress cell alpha indefinitely.

### 3.2 Pattern: Guarded Async with Cleanup

```swift
// CAPTURE PHASE
guard let token = activeSessionGenerationToken() else {
    // Cannot bind — fall back to non-async path
    fallbackBehavior()
    return
}
morphTargetMessageId = targetId  // pre-condition state

// YIELD
DispatchQueue.main.async { [weak self] in
    guard let self else { return }

    // RESUME PHASE — validate
    guard self.callbackSessionKey() == token.sessionKey,
          self.readState(for: token.sessionKey).restoreGeneration == token.generation else {
        // CLEANUP on abort
        self.morphTargetMessageId = nil
        self.deferScrollToBottomUntilMorphCompletes = false
        return
    }

    // ... proceed with operation ...

    // CLEANUP on success
    self.morphTargetMessageId = nil
}
```

### 3.3 Multi-Yield Operations

Operations with multiple yield boundaries (e.g., `DispatchQueue.main.async` → `UIView.animate` → completion) must validate at every yield boundary, not just the first. The session may change between any two yields.

Each yield boundary re-validates the same token captured in the original capture phase. A new token is NOT captured at intermediate yields — the operation is bound to its original session context for its entire lifetime.

Cleanup obligations carry forward across yields: if the second yield's guard fails, cleanup must cover pre-conditions set in the capture phase AND any state set between the first and second yields.

---

## 4. Caller Inventory Obligation

### 4.1 The Default-Parameter Hazard

When a migration extends a method's parameter set with session-critical parameters that have default values, the compiler will not flag existing callers. Every existing caller silently inherits the default, which may be semantically wrong in the new per-stream context.

**Rule:** For any method whose parameter set is extended by a per-stream migration:

1. **Enumerate all call sites** (IDE "Find All References" or text search), including call sites in code that predates the migration.
2. **For each call site**, determine whether the default value preserves the caller's pre-migration behavioral contract.
3. **If the default is unsafe for any caller**, either:
   - Remove the default (make the parameter required, forcing a compile error at every call site), or
   - Add a runtime assertion in debug builds that fires when the default is used from an unsafe context.

### 4.2 Session-Critical Parameters

The following parameters on `MessageFlowCollectionViewController.update(...)` are session-critical:
- `sessionKey` — Controls `effectiveSessionKey` resolution. Default `nil` falls back to `engineActiveSessionKey`, which is wrong for offscreen/prewarm controllers.
- `onScrollEvent` — Default `nil` clears the stored callback, silently dropping all scroll events.
- `onExpand` — Default `nil` clears the stored callback.

These parameters must not have defaults, OR every caller must be verified to pass them explicitly.

### 4.3 The `viewDidLayoutSubviews` Rule

`viewDidLayoutSubviews` (and any other UIKit lifecycle method that calls `update()`) is not a new call site — it predates the per-stream migration. It must pass ALL stored parameters, including those it did not previously need to pass:
- `sessionKey: channelOverride`
- `onScrollEvent: onScrollEvent`
- `onExpand: onExpand`
- `isDark: currentIsDark`
- `forceReReadGeneration: 0` (explicit, not relying on default)

**General rule:** Any internal `update()` call site that re-enters `update()` from a non-coordinator context (layout callbacks, bounds changes, internal refresh passes) must pass through all stored parameters. The coordinator-driven `updateUIViewController` is the canonical external entry point; internal re-entry must not lose state by relying on defaults.

---

## 5. Property Shim Safety Model

### 5.1 What Shims Are

Property shims are computed properties that route through `activeStateKey()`:

```swift
private var morphTargetMessageId: String? {
    get { activeStateKey().flatMap { readState(for: $0).morphTargetMessageId } }
    set { ... mutateState(for: key) { $0.morphTargetMessageId = newValue } }
}
```

Shims provide ergonomic access to per-stream state without threading `sessionKey` through every call. They are a convenience layer over the canonical `readState(for:)` / `mutateState(for:_:)` seams.

### 5.2 When Shims Are Safe

Shims are safe in **bound-epoch context**: any synchronous code path where `activeStateKey()` is guaranteed to return the correct session key. This includes:
- Code executing within `update()` after the seam has run and before the method returns.
- Synchronous continuations of `update()` (snapshot build, `cellForItem`, layout).
- UIKit delegate callbacks that fire within the same runloop turn as a layout pass (`scrollViewDidScroll`, `willDisplay`, drag end, decelerate end).

### 5.3 When Shims Are Unsafe

Shims are unsafe in **deferred-access context**: any closure that executes after a yield boundary. In these contexts, `activeStateKey()` may return a different session than the one the closure was scheduled for.

**Shim access after a yield boundary is a spec violation.** All deferred-access code must use `readState(for: capturedSessionKey)` or `mutateState(for: capturedSessionKey)` with an explicitly captured key.

### 5.4 The `deinit` Special Case

`deinit` runs in an unbound context — there is no current `update()` epoch, and `activeStateKey()` returns whatever session was last bound. Shim access in `deinit` only affects one session's state, leaving other sessions' deferred work uncancelled.

**Rule:** `deinit` must iterate `perStreamStateBySessionKey` and cancel all deferred work for every session, not just the active one. Since all callbacks capture `[weak self]`, missed cancellations are harmless (the callbacks no-op on deallocation), but explicit cancellation prevents wasted runloop work.

---

## 6. Emission Idempotency Contract

### 6.1 Steady-State Emission Rule

SBB and scroll-event emissions on the steady-state path (no switch, no re-read, same `effectiveSessionKey` as last update) must use **change detection**, not forced emission:

```swift
emitHideIndicatorIfChanged()  // force: false (default)
```

Change detection compares `lastReportedHideIndicator` against current `sbbState.shouldHideIndicator` and emits only on actual state change. This prevents per-frame dictionary mutations in SwiftUI state containers.

### 6.2 When Forced Emission Is Used

Forced emission (`force: true`) is used in two contexts:

1. **SBB state transitions.** `setSBBState(_:)` calls `emitHideIndicatorIfChanged(force: true)` on every SBB state change (guarded by `sbbState != newState`). This fires during normal scroll interaction — drag start, scroll settle, unread crossing, etc. — not only on session switch. The rationale is that any SBB state machine transition should immediately synchronize the emitted value with SwiftUI, since the `shouldHideIndicator` derivation may have changed even if `lastReportedHideIndicator` happened to match.

2. **Session switch.** The switch path in `runStreamContextSwitchSeam` calls `emitHideIndicatorIfChanged(force: true)` after binding the incoming session. The incoming session's `lastReportedHideIndicator` may differ from the value last emitted to SwiftUI.

### 6.3 Same-Key Re-Read Emission

The same-key re-read path should use change detection (not forced emission). The re-read reloads persisted state and rearms restore, but the SBB state visible to SwiftUI may not have changed. If it has changed, change detection will catch it. If it hasn't, skipping the emission is correct.

If the re-read causes a visible SBB state change (e.g., re-read reloads `atBottom: false` while the prior state was `atBottom: true`), the change will be detected and emitted when the new `sbbState` is set by `prepareIncomingStateOnSwitch` (called from the re-read path).

---

## 7. Existing Async Boundary Classification

For reference, here is the classification of all async boundaries in `MessageFlowCollectionViewController` as of the branch state that motivated this contract. This table is normative — any new async boundary must be classified and comply with the rules above.

### Fully Guarded (session + generation)

| Boundary | Pattern | Notes |
|---|---|---|
| `pendingBottomInsetHeightCapInvalidation` | `asyncAfter` + `DispatchWorkItem` | Token + `withBoundSessionKey` |
| `pendingScrollToBottomWorkItem` | GCD + `DispatchWorkItem` | Token + `isCancelled` |
| Morph animation escape | `DispatchQueue.main.async` | Token validated at entry |
| Morph completion | `UIView.animate` completion | Token validated (multi-yield) |
| Viewport anchor compensation | `DispatchQueue.main.async` | Token + snapshot refresh |
| Bottom inset remeasure timer | `Timer` | Token + `withBoundSessionKey` |
| Scroll state debounce timer | `Timer` | Session key + generation |
| V2 remeasure debounce timer | `Timer` | Token + `withBoundSessionKey` |
| V2 deferred flush timer | `Timer` | Token + `withBoundSessionKey` |
| Restore attempt callback | Registered one-shot | `RestoreAttemptToken` (session + generation + stage) |

### Session-Guarded Only (no generation)

| Boundary | Pattern | Risk | Recommendation |
|---|---|---|---|
| `scheduleTailToFullPromotionIfNeeded` | `DispatchQueue.main.async` | Compound guard: checks `isActiveSession` AND `(channelOverride ?? engineActiveSessionKey) == capturedSessionKey`. Uses live `engineActiveSessionKey` (view-model property), not `callbackSessionKey()`. No generation guard. Generation bump during tail→full could cause stale promotion. | Add generation guard |
| `dataSource.apply` completion | Completion block | Low risk (same-turn for non-animated) | Acceptable for non-animated; add generation guard for animated applies |
| `requestFlashMessage` callback | Registered one-shot | `performPendingFlashIfPossible()` is called immediately before registration (early-out if already materialized). The callback closure itself has no session guard; session gating is in the `fireRegisteredMessageLoadCallbacksIfMaterialized` fire machinery (`callbackSessionKey() == sessionKey`). Flash targets wrong generation after re-read. | Low severity; generation guard optional |
| `checkFirstUnreadCrossingIfNeeded` callback | Registered one-shot | Registration is conditional: only when the unread anchor message is not yet materialized AND materialization stage is `.tail` AND unread falls outside the tail window. Session guard is in the fire machinery, not the callback closure. Crossing check on stale generation. | Low severity; generation guard optional |
| `scrollToMessageCentered` callback | Registered one-shot | Scroll targets wrong position after re-read | Add generation guard |

### Unguarded (exempt or needs attention)

| Boundary | Pattern | Exempt? | Reason |
|---|---|---|---|
| `scheduleReconfigure` | `DispatchQueue.main.async` | Exempt (self-healing) | Missed reconfigure is re-applied on next update cycle. Adding a guard would be ideal but low priority. |
| `scheduleLayoutInvalidation` | `DispatchQueue.main.async` | Exempt (self-healing) | Same rationale as `scheduleReconfigure`. |
| Entrance animation | `UIView.animate` (no completion) | Exempt (visual-only) | Fire-and-forget tween. No per-stream state writes. |
| `setBottomInset` animation | `UIView.animate` (no completion) | Exempt (pre-captured values) | All values driving the animation block (`shouldPinToBottom`, `delta`, `totalBottomInset`) are pre-captured before `UIView.animate`. The block has no live `callbackSessionKey()` or shim access. Acceptable. |
| `willResignActive` handler | `NotificationCenter` | Exempt (by design) | Always persists current session. See section 2.2. |
| `willDisplay` delegate | UIKit callback | Reactive access | Uses shim access within UIKit layout epoch. Acceptable per section 1.2. |
| `onRequestLayout` cell callback | Cell closure | Needs attention | Fires asynchronously from link preview height changes. Currently uses shim. Should capture session key at configure time if targeting a specific session's cache. Low priority (cache operations are self-healing). |

---

## 8. Compliance Checklist

When adding new code or modifying existing code in `MessageFlowCollectionViewController`:

- [ ] Does this code execute after a yield boundary? If yes, it must capture and validate a session generation token (section 2.1).
- [ ] Does this code set per-stream state synchronously before a yield? If yes, all exit paths after the yield must clean up that state (section 3.1).
- [ ] Does this code add a new parameter to `update()` with a default value? If yes, enumerate all call sites and verify the default is safe for each (section 4.1).
- [ ] Does this code call `update()` from an internal (non-coordinator) context? If yes, it must pass all stored parameters (section 4.3).
- [ ] Does this code use a property shim? If yes, verify it executes in bound-epoch or reactive context, not deferred context (section 5.3).
- [ ] Does this code emit SBB or scroll events? If yes, verify it uses change detection on the steady-state path (section 6.1). Forced emission is used by `setSBBState` on all state transitions and by the switch seam (section 6.2).
