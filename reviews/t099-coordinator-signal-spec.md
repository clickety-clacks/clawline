# T099 Spec: Unify Startup Triggers Into Coordinator Signals

## Goal
Replace three duplicated startup call paths in `ChatViewModel` with three dumb coordinator signals:

- `authChanged(token: String?)`
- `sceneActivated()`
- `viewAppeared()`

Coordinator becomes the single owner of startup decision logic (connect/no-op/token update), instead of `ChatViewModel` deciding separately in:
- `handleAuthStateChange` (`ChatViewModel.swift:548-585`)
- `onAppear` (`ChatViewModel.swift:492-517`)
- `handleSceneDidBecomeActive` (`ChatViewModel.swift:587-600`)

## Current behavior trace (baseline)

### Current trigger sites
- `handleAuthStateChange` auth path:
  - `startObservingIfNeeded()`
  - `setAuthToken(auth.token)`
  - `seedCanonicalCursor(...)`
  - `startIfNeeded()`
  (`ChatViewModel.swift:561-573`)
- `onAppear`:
  - `startObservingIfNeeded()`
  - `setAuthToken(auth.token)`
  - `startIfNeeded()`
  (`ChatViewModel.swift:510-516`)
- `sceneDidBecomeActive`:
  - `startObservingIfNeeded()`
  - `appDidBecomeActive()`
  (`ChatViewModel.swift:595-599`)

### Existing coordinator gates
- `startIfNeeded` only starts when `phase == .idle` and reconnect enabled (`ConnectionLifecycleCoordinator.swift:210-217`).
- `appDidBecomeActive` only starts when `phase == .idle` and reconnect enabled (`ConnectionLifecycleCoordinator.swift:175-200`).
- `setAuthToken(nil)` clears token and moves active phases to `.idle` (`ConnectionLifecycleCoordinator.swift:149-160`, `688-695`).
- `startConnecting` hard-requires non-empty token (`ConnectionLifecycleCoordinator.swift:592-597`).

---

## Proposed API semantics (spec only)

Add coordinator signal API:
- `func authChanged(token: String?)`
- `func sceneActivated()`
- `func viewAppeared()`

`ChatViewModel` should call only those signals from the three current startup call sites (no direct `setAuthToken/startIfNeeded/appDidBecomeActive` from those sites).

### Action terms used in decision table
- **Ignore**: no state transition attempt (no connect/reconnect call).
- **Update token only**: call existing `setAuthToken(token)` only.
- **Connect**: attempt initial connection from idle:
  - existing equivalent: `startIfNeeded()` (or `appDidBecomeActive()` for scene policy).
- **Reconnect**: force a retry from failed/recovering:
  - existing equivalent: `manualRetry()`.

---

## Coordinator decision algorithm

## Signal: `authChanged(token: String?)`
1. Always sanitize/store token via existing `setAuthToken(token)`.
2. If token is `nil`: stop here.
   - effect from existing coordinator logic: if phase is active, transition to idle via explicit teardown.
3. If token is non-nil:
   - If phase is `.idle`: **Connect** (`startIfNeeded()`).
   - If phase is `.failed` or `.recovering`: **Ignore** (preserve current behavior; retry remains explicit/manual).
   - If phase is `.connecting/.authenticating/.replaying/.live`: **Update token only** (no new connect attempt).

## Signal: `viewAppeared()`
1. If token missing: **Ignore**.
2. If token present:
   - If phase is `.idle`: **Connect** (`startIfNeeded()`).
   - Any other phase: **Ignore**.

## Signal: `sceneActivated()`
1. If token missing: **Ignore**.
2. If token present:
   - Delegate to existing foreground policy (`appDidBecomeActive()`), which currently:
     - Connects if idle.
     - Ignores non-idle phases.
     - Applies the <2s delayed reconnect heuristic after background.

---

## Decision table by phase + signal

Legend:
- `U` = update token only (`setAuthToken`)
- `C` = connect (`startIfNeeded` or `appDidBecomeActive` idle path)
- `I` = ignore

| Phase | `authChanged(nil)` | `authChanged(nonNil)` | `viewAppeared()` (token present) | `sceneActivated()` (token present) |
|---|---|---|---|---|
| `.idle` | U (stays idle) | U + C | C | C (via `appDidBecomeActive`) |
| `.connecting` | U (teardown to idle) | U | I | I |
| `.authenticating` | U (teardown to idle) | U | I | I |
| `.replaying` | U (teardown to idle) | U | I | I |
| `.live` | U (teardown to idle) | U | I | I |
| `.recovering` | U (teardown to idle) | U (no forced retry) | I | I |
| `.failed` | U (no transition) | U (no forced retry) | I | I |

Notes:
- `authChanged(nil)` semantics are inherited from existing `setAuthToken(nil)` behavior.
- No startup signal performs reconnect today from `.failed/.recovering`; reconnect path remains transport/manual retry.

---

## Where complexity is real

1. **Signal burst ordering at startup**
- `authChanged(nonNil)`, `viewAppeared`, and `sceneActivated` can arrive close together.
- Coordinator actor serialization + `phase == .idle` guard prevents duplicate connect attempts.
- Expected behavior: first connect wins, later signals are no-op.

2. **Subscription-before-signal invariant**
- If a connect-capable signal is sent before lifecycle output/transport observers are subscribed, early events can be lost.
- Existing guard today is outside coordinator in `ChatViewModel.startObservingIfNeeded` (`ChatViewModel.swift:613-717`).
- Refactor must preserve this invariant:
  - either ensure observers are ready before first signal dispatch,
  - or move observer ownership to coordinator-facing seam as a separate architectural change.

3. **Failed/recovering behavior**
- Table preserves current behavior (no auto reconnect on startup signals in `.failed/.recovering`).
- If product wants token change to immediately retry from failed/recovering, that is a separate policy change (would use `manualRetry()`).

---

## Conformance target (what this refactor should guarantee)

1. ChatViewModel startup call sites become dumb signal forwarders.
2. Coordinator is SSOT for startup trigger arbitration.
3. First connect attempt after auth is initiated at most once per idle epoch.
4. No behavior regression for foreground re-activation delay policy currently in `appDidBecomeActive`.
