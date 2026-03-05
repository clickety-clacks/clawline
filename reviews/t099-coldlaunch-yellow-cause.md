# T099 Cold Launch Yellow Pulse Root Cause

## Verdict
Root cause is a startup observer race in `ChatViewModel`: multiple concurrent calls to `startObservingIfNeeded()` create duplicate lifecycle observer tasks on cold launch, which can drop/reorder lifecycle phase events. When `.live` is lost, UI stays in `.reconnecting` (yellow pulse) indefinitely.

## File:line evidence

1. **Cold-launch has 3 concurrent startup paths that all call observation setup**
- `onAppear()` calls `startObservingIfNeeded()` at [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:473](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:473)
- Auth-change path calls it at [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:513](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:513)
- Scene-active path calls it at [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:543](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:543)

2. **`startObservingIfNeeded()` is not concurrency-safe**
- It guards `observationTask == nil` at entry, then suspends (`await ensureLifecycleOutputsSubscription()`) before setting `observationTask`.
- See [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:558](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:558) through [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:563](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:563).
- That suspension allows re-entrant calls to pass the same nil guard and create multiple observer groups.

3. **Duplicate observers consume the same lifecycle streams**
- Transport observer loop: [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:594](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:594)
- Lifecycle-output observer loop: [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:602](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:602)
- Because multiple tasks iterate these subscriptions concurrently, lifecycle event delivery ordering/completeness is no longer reliable.

4. **Yellow pulse only clears on `.live` phase event**
- Mapping is explicit: `.live -> .connected`; `.connecting/.authenticating/.replaying/.recovering -> .reconnecting`.
- See [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1198](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1198) through [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1201](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1201).
- If `.live` output is dropped, UI remains yellow.

## Simulator trace evidence (no device dependency)
In cold-launch simulator logs, the same VM instance started observation multiple times in the same tick:
- `ChatViewModel startObserving id=A7599403-F6A8-41F1-BB59-3542381C5414` (repeated 3 times at `22:16:46.555xxx`)

That is direct runtime confirmation of the race above.

## Why this appears specifically on cold launch
Cold launch triggers all three startup paths close together (`auth change`, `scene active`, `onAppear`), maximizing the window where re-entrant `startObservingIfNeeded()` calls can race before `observationTask` is set.
