# T099 replay stall diagnosis (revised)

## Revised conclusion
The deterministic “instant load when returning to app” behavior is **not** explained by replay volume alone. The code path shows `sceneActivated` can restore missing observation before it touches the coordinator. If observers were absent/teardown’d, scene activation can immediately make lifecycle events visible again.

This means the likely issue is an **observation continuity problem** (observer not active or torn down), not simply “replay took 28s by chance.”

## 1) What `sceneActivated` does in `.replaying`

### Coordinator layer (still true)
- `sceneActivated()` calls `appDidBecomeActive()`: [ConnectionLifecycleCoordinator.swift:177](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:177)
- `appDidBecomeActive()` only starts connect when `phase == .idle`: [ConnectionLifecycleCoordinator.swift:202](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:202)
- So at coordinator-only level, `.replaying` means no reconnect start.

### Missing piece (what I missed before)
- In `ChatViewModel`, scene-active path is:
  1. `startObservingIfNeeded()`
  2. then `lifecycleCoordinator.sceneActivated()`
- Evidence: [ChatViewModel.swift:645](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:645), [ChatViewModel.swift:646](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:646), [ChatViewModel.swift:651](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:651)

So even if coordinator signal is a no-op in `.replaying`, the **observer startup** in front of it is not a no-op.

## 2) Fresh-login ordering: does `authChanged(token)` happen before/after observation wiring?

### Entry/ordering on fresh login
- `RootView` creates `ChatViewModel` as soon as auth becomes true: [RootView.swift:66](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/Views/RootView.swift:66), [RootView.swift:95](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/Views/RootView.swift:95)
- `ChatViewModel.init` immediately calls `handleAuthStateChange()`: [ChatViewModel.swift:526](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:526)
- Token path does:
  - `await startObservingIfNeeded()` first: [ChatViewModel.swift:612](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:612)
  - then `lifecycleCoordinator.authChanged(token:)`: [ChatViewModel.swift:619](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:619)
- `viewAppeared` comes from `ChatView.onAppear` later: [ChatView.swift:462](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/Views/Chat/ChatView.swift:462), [ChatViewModel.swift:560](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:560)

### Answer
On the intended path, observer wiring happens before `authChanged(token)` and `authChanged(token)` can occur before `viewAppeared`.

## 3) Can observer wiring be absent by the time sceneActivated fires?

Yes, by code shape this is possible if observation was torn down after startup.

### Teardown points
- `onDisappear()` always calls `stopObservingLifecycle()`: [ChatViewModel.swift:568](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:568)
- `stopObservingLifecycle()` nils both lifecycle subscriptions + cancels observer task: [ChatViewModel.swift:725](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:725), [ChatViewModel.swift:730](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:730), [ChatViewModel.swift:731](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:731)
- After teardown, scene-active path can rebuild observers via `startObservingIfNeeded()`: [ChatViewModel.swift:646](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:646)

### Why this fits the deterministic symptom
If observer continuity is broken, returning to app reliably runs scene-active path, which reliably calls `startObservingIfNeeded()`. That gives a deterministic “instantly starts flowing again” effect.

## 4) Replay volume vs transport/delivery

- Replay volume can produce long `.replaying` windows (timeouts are 30s+): [ConnectionLifecycleCoordinator.swift:441](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:441), [ConnectionLifecycleCoordinator.swift:472](~/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:472)
- But replay volume **alone** does not explain “every time it unblocks immediately on scene return.”
- The stronger fit is observer continuity loss + scene-active re-subscription.

## 5) Specific correction to prior report
The prior “coincidental timing / replay backlog likely” conclusion was incomplete. The code contains a deterministic unstick mechanism in the scene-active path (`startObservingIfNeeded`) that can restore missing observation.

## What to verify next (single discriminator)
Capture one fresh-login run with these two lines together:
1. scene-active log shows `startObservingIfNeeded` entering with missing observer (`observationTaskNil=true` and/or `transportSubNil=true` / `outputsSubNil=true`)
2. immediately after, replay/live outputs begin flowing.

If that pair appears, root cause is confirmed as observer continuity break, not replay-volume coincidence.
