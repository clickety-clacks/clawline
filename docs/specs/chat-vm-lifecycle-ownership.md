# Chat VM Lifecycle Ownership (T099)

## Goal

Eliminate login-time replay stalls caused by SwiftUI view churn by aligning observer lifecycle with actual `ChatViewModel` ownership.

## Problem Summary

`RootView` owns `ChatViewModel`, but `ChatView` currently starts/stops observation in `.task` / `.onDisappear`.
During auth transition, SwiftUI can replace `ChatView` instances and fire `onDisappear` while the app remains active.
That teardown can stop observers mid-replay, leaving the VM alive but disconnected until a later lifecycle nudge (e.g. scene activation).

## Design

### Ownership Rule

Only the owner of `ChatViewModel` controls observer lifecycle.
- Owner: `RootView` (or whichever top-level container owns VM creation/destruction)
- Non-owner views (`ChatView`) may report visibility only; they must not start/stop observation pipeline.

### Lifecycle Contract

1. VM creation path calls `activate()` exactly once per VM instance.
2. `activate()` is async and must call both observation bootstrap and `viewAppeared()` to arm coordinator start gates.
3. VM replacement/destruction path calls existing teardown (`prepareForReplacement()`) exactly once.
4. `ChatView.onDisappear` no longer calls observer teardown.
5. `ChatView.task` no longer performs VM bootstrap that can race with view identity churn.

### Required Code Changes

1. **ChatViewModel**
   - Add async `activate()` (idempotent) to initialize observation + lifecycle start signals.
   - `activate()` must call `viewAppeared()` so coordinator `startIfNeeded()` can pass the `hasViewAppeared` gate.
   - Keep teardown in `prepareForReplacement()`.
   - Remove reliance on view visibility callbacks for observation ownership.

2. **RootView**
   - After VM creation, call `activate()` immediately from `Task {}`.
   - Keep replacement path calling `prepareForReplacement()` before nil/recreate.

3. **ChatView**
   - Remove observer lifecycle calls from `.task` / `.onDisappear`.
   - Keep purely view-level concerns (UI reset, debug visuals, visibility flag for haptics only).
   - Keep `isChatVisible` toggles if needed for haptic gating, but this flag must not trigger observation/connection lifecycle changes.

4. **Retained parallel entry points**
   - Keep `handleAuthStateChange()` and `handleSceneDidBecomeActive()` paths.
   - After this change, their `startObservingIfNeeded()` calls are defensive/idempotent no-ops when already active.
   - Do not remove these paths; they still provide coordinator signals (`authChanged`, `sceneActivated`) for reconnect behavior.

## Safety / Blast Radius

Must remain unchanged:
- Session selection/stream switching semantics
- Connection ownership arbitration logic
- Pairing/auth rules
- Non-chat screens and navigation behavior

Explicit policy change (intentional):
- `chatService.disconnect()` is no longer called from transient `ChatView.onDisappear` churn.
- Transport teardown is limited to legitimate lifecycle events (e.g. app background policy, VM replacement via `prepareForReplacement()`).
- Transient view replacement may leave transport open; this is expected and desired for continuity.

Potentially affected and must be tested:
- Fresh login from cold launch
- Logout → login within same app session
- Background/foreground transitions
- Stream switching while connected
- Haptic gating if it depends on view visibility flag

## Verification Plan

1. **Regression repro (required)**
   - Re-run the known login pulse scenario; confirm no stalled replay after auth success.

2. **Lifecycle proof**
   - Debug logs/overlay must show no observer teardown from transient `ChatView` replacement.

3. **Behavior parity checks**
   - Stream switching still fast and stateful.
   - No duplicate observer startup.
   - No leaked observers after logout/replacement.

4. **Targeted test coverage**
   - Unit test for idempotent async `activate()`.
   - Unit/integration test that transient view disappearance does not stop observation.
   - Logout → re-login test to confirm new VM `activate()` re-arms `hasViewAppeared` gating correctly.

## Non-Goals

- No refactor of TabView/page architecture.
- No transport/protocol changes.
- No UX redesign beyond lifecycle correctness.

## Rollout

1. Implement lifecycle ownership move.
2. Run targeted tests + build.
3. Device verify login path on Ansible.
4. If stable, keep debug instrumentation off by default and retain only minimal diagnostics hooks.
