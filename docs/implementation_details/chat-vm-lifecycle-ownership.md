# Chat VM Lifecycle Ownership — Non-Obvious Details

## Root cause of login stall: SwiftUI view churn stopping observers
SwiftUI can replace `ChatView` instances during auth transitions and fire `onDisappear` while the app remains active. The old design had `ChatView.onDisappear` stopping the observation pipeline. The VM stays alive but disconnected, and the only recovery is a later lifecycle nudge (scene activation). This is invisible from reading the VM alone — you have to understand that SwiftUI can teardown non-owner views during auth state transitions.

## `activate()` must call `viewAppeared()` — not just observation bootstrap
The async `activate()` method must call both observation bootstrap AND `viewAppeared()`. This is required to arm the coordinator `startIfNeeded()` through the `hasViewAppeared` gate. If `viewAppeared()` is skipped, the coordinator start gate never opens and the connection never establishes, even though observation started.

## `chatService.disconnect()` is intentionally NOT called on transient view disappearance
Post-fix, `ChatView.onDisappear` no longer calls disconnect. This is a deliberate policy change: transient view replacement may leave transport open. This is correct for continuity. Code reviewers who see "disconnect not called on disappear" should not add it back.

## `handleAuthStateChange` and `handleSceneDidBecomeActive` are retained as defensive paths
These paths remain but are now idempotent no-ops when already active. Do not remove them — they still provide coordinator signals for reconnect behavior. Their `startObservingIfNeeded()` calls do nothing when activate has already run.

## `isChatVisible` flag — only for haptic gating, not lifecycle
After this change, `isChatVisible` toggles in `ChatView` must not trigger observation or connection lifecycle changes. The flag is for haptic gating only. Adding a connection trigger here reintroduces the original bug.
