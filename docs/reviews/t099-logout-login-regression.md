# T099 Logout→Login Regression Findings (Analysis Only)

Date: 2026-02-27
Branch analyzed: `per-stream-state` @ `d450b6941`

## Scope
Investigated only the in-session `logout -> fresh login` flow vs cold launch for:
1. active stream restore
2. post-login connection/startup behavior causing yellow reconnect pulse symptoms

No code changes were made.

## Connection Startup Path (Current)

### Cold launch / authenticated startup
1. `ChatViewModel.init` registers auth observer and calls `handleAuthStateChange()`
   - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:430-449`
2. `handleAuthStateChange` (token present) starts observation + lifecycle startup and restore helpers
   - `.../ChatViewModel.swift:500-512`
3. async startup task path:
   - `startObservingIfNeeded()` -> `lifecycleCoordinator.setAuthToken(...)` -> `startIfNeeded()`
   - `.../ChatViewModel.swift:503-508`
4. coordinator starts connection attempt through `startAttempt` closure:
   - `ChatViewModel` wiring: `.../ChatViewModel.swift:419-425`
   - coordinator dispatch: `.../ConnectionLifecycleCoordinator.swift:560-581`
   - service entrypoint: `.../ProviderChatService.swift:354-359`

### In-session logout -> fresh login
1. `logout()` clears runtime and persisted state, then clears credentials
   - `.../ChatViewModel.swift:747-789`
2. `auth.clearCredentials()` posts auth-change; `RootView` tears down `chatViewModel` when unauthenticated
   - auth post: `ios/Clawline/Clawline/Services/AuthManager.swift:83-96`
   - VM teardown: `ios/Clawline/Clawline/Views/RootView.swift:53-69`
3. fresh login creates a new `ChatViewModel`; startup path re-runs from init as above.

## Root Cause A (Symptom 1: active stream always resets to Personal)

### Exact break
Logout path removes the per-user active stream persistence and stream metadata cache before next login:
- `clearActiveSession()` removes persisted active-session key:
  - `.../ChatViewModel.swift:258-268` (removeObject at line 267)
- `logout()` calls `clearActiveSession()` and wipes stream metadata cache:
  - `.../ChatViewModel.swift:773` and `788`

On next login, restore helpers run immediately, before a server stream snapshot is applied:
- `handleAuthStateChange` calls:
  - `restoreStreamMetadataIfNeeded()` (`...:509`)
  - `restoreActiveSessionKeyIfNeeded()` (`...:510`)
  - `ensureDefaultActiveSessionIfNeeded()` (`...:511`)

Because logout deleted metadata/key, restore has no source and defaults to main/personal:
- default path: `ensureDefaultActiveSessionIfNeeded` -> `streamMainSessionKey`:
  - `.../ChatViewModel.swift:1894-1902`, `1883-1891`

Why cold launch appears correct:
- cold launch keeps prior stream cache/key (no in-session logout wipe), so restore can succeed from disk:
  - metadata restore: `.../ChatViewModel.swift:2080-2094`
  - active key restore: `.../ChatViewModel.swift:1856-1866`

## Root Cause B (Symptom 2: non-active streams show reconnect/yellow behavior after fresh login)

### Exact break
Session provisioning state is reset on every lifecycle phase mapped to `.reconnecting`:
- phase mapping to reconnecting includes `.connecting/.authenticating/.replaying/.recovering`:
  - `.../ChatViewModel.swift:1188-1192`
- reconnecting state reset clears provisioning flags/keys:
  - `.../ChatViewModel.swift:1639-1641`
  - `resetSessionProvisioningState`: `.../ChatViewModel.swift:1653-1659`

Provisioning/session events are set earlier from auth/session messages:
- set provisioning info from service events:
  - `.../ChatViewModel.swift:1563-1591`

In lifecycle mode, these two pipelines are concurrent (`observeLifecycleOutputs` and `observeServiceEvents`), so provisioning can be populated then immediately cleared again during replay transition in same login attempt.
- observers started in parallel task group:
  - `.../ChatViewModel.swift:555-566`

This is most visible right after fresh login (especially after logout wiped fallback state), producing connected transport but lingering reconnect/provisioning behavior for non-active streams.

## Minimal Fix Plan (No implementation yet)

1. Preserve per-user active stream restore source across logout.
- Do not delete `clawline.lastSessionKey.<userId>` during logout path.
- Keep in-memory active session reset, but avoid removing persisted per-user key in this flow.
- Target seam: `clearActiveSession()` usage from `logout()`
  - `.../ChatViewModel.swift:258-268`, `747-789`

2. Stop clearing session provisioning state on intermediate lifecycle reconnecting phases.
- Keep reset on hard terminal states (`.disconnected/.failed`) only, not every reconnecting phase transition in same attempt.
- Target seam:
  - `transitionConnectionState` reconnecting case at `.../ChatViewModel.swift:1639-1641`

3. Verify after fix:
- logout -> login returns to previously active stream (not forced Personal)
- switching to non-active streams after fresh login no longer shows reconnect/yellow stall
- cold launch behavior unchanged

