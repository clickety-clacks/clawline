# T099 deeper root cause (logout -> fresh login)

## Repro status
- Reproduced in simulator on `per-stream-state` with temporary `[T099]` logging.
- UI evidence:
  - Pre-logout active stream was `DM` (`/tmp/t099-cycle4-after-switch-dm.json`).
  - Post-login active stream became `Personal` with `Reconnecting` send state (`/tmp/t099-cycle4-after-login.json`, `/tmp/t099-cycle4-after-login-6s.json`).

## 1) Persisted active stream key read/write trace
- Read path is `persistedActiveSessionKey()` and restore path is `restoreActiveSessionKeyIfNeeded()` in [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1861) and [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1880).
- During login bootstrap, `handleAuthStateChange()` calls restore/default immediately in [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:510).
- Defaulting path writes key via `ensureDefaultActiveSessionIfNeeded()` -> `setEngineActiveSessionKey()` -> `applyActiveSessionKey()` -> `persistActiveSessionKey()` in [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1923), [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:248), [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1856).
- Log evidence from this run shows login reading/applying `...:main` repeatedly (`[T099] persistedActiveSessionKey_hit ... stored=agent:main:clawline:qa_sim:main` and `[T099] restoreActiveSessionKeyIfNeeded_applied ... main`).

## 2) Provisioning state trace post-login
- Connection state mutation is centralized in `transitionConnectionState` in [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1644).
- Logs show repeated `state=reconnecting` even after provisioning is fully populated (`supports=true resolved=true received=true provisionedCount=2`).
- Logs also show duplicate VM IDs receiving the same provisioning events in one cycle (example IDs `9111BAA0-...` and `2E6B6228-...`).

## 3) Why active stream defaults to Personal instead of saved key
- Exact clobber path is in login bootstrap order:
  - `handleAuthStateChange()` runs restore/default before stable stream snapshot is guaranteed ([ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:510)).
  - If restore cannot confidently apply desired key yet, `ensureDefaultActiveSessionIfNeeded()` chooses main/personal and persists it ([ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1923)).
- Result: persisted source of truth becomes `main`, so subsequent restore consistently selects Personal.

## 4) Why streams stay reconnecting after fresh login
- The flow breaks at shared-service ownership during instance overlap:
  - `RootView` can create a new `ChatViewModel` on auth change while old one is still alive briefly ([RootView.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Views/RootView.swift:53), [RootView.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Views/RootView.swift:90)).
  - Old instance still has observers and lifecycle hooks (`NotificationCenter` setup + `handleAuthStateChange` in [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:440), [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:510)).
  - `onDisappear()` of stale instance disconnects shared transport (`chatService.disconnect()` and coordinator disconnect) in [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:479).
- Log evidence of break:
  - `ChatViewModel onDisappear id=<stale>` followed by `ProviderChatService disconnect requested`.
  - `lifecycle stale-event-drop eventEpoch=1 currentEpoch=2`.
  - Multiple reconnect phase loops before eventual recovery (`connecting -> recovering -> connecting -> authenticating`).
- User-visible effect: yellow/reconnecting persists during this overlap window; stream rows can appear stuck despite provisioning data being present.

## Real root cause
- Two coupled issues in logout->login path:
  - Active-session key is clobbered to `main` by early defaulting during auth bootstrap.
  - Concurrent/stale `ChatViewModel` instance can tear down shared transport during the new instance’s connect/auth path, producing reconnect loops and stale-epoch drops.

## Minimal fix plan (no code changes applied yet)
1. Prevent active-key clobber during bootstrap:
- In `ensureDefaultActiveSessionIfNeeded()`, do not persist fallback main while `didRestoreActiveSessionKey == false` and a persisted key exists but has not yet been resolved against live snapshot.

2. Enforce single transport owner for logout/login transition:
- Gate `onDisappear()` disconnect path so only the current/owning VM instance can call `chatService.disconnect()` and lifecycle disconnect.

3. Gate auth-change startup for hidden/stale instances:
- In `handleAuthStateChange()`, do not start lifecycle observation/connect for non-visible/non-owner VM instances.
