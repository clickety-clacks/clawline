# T100 Post-fix Go/No-Go (ae7933d18)

## Scope
- Commit under review: `ae7933d18`
- Focus: connecting/yellow-dot symptom only (stuck in reconnecting/connecting on device)
- Methods:
  - Local code-path audit
  - Fresh simulator runtime log capture (`XcodeBuildMCP` session `7ebd1d2b-6b40-4854-8e73-ef02dabddb4b`)
  - Claude Opus adversarial pass (`scratch/opus-review-20260227-000127.txt`)

## Adversarial findings

### 1) Lifecycle regression risk (connect/reconnect/auth-success path)
- Connect path: no regression from stale-listener fix.
  - Active token is assigned before lifecycle listener/event emission:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:537`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:540`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:541`
- Reconnect path: ordering is correct; subscriptions are established before manual retry dispatch.
  - `reconnect()` calls `startObservingIfNeeded()` before `manualRetry()`:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:491`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:492`
  - `startObservingIfNeeded()` installs lifecycle outputs and transport subscriptions before coordinator start paths:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:551`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:552`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:575`
- Auth success path: auth result still reaches service and coordinator path; stale sockets are suppressed.
  - Lifecycle auth event emission:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:656`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:659`
  - Stale token drop gate:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:940`
  - Stale close ignore:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:1034`

### 2) Re-check of prior failing points (for T100 symptom triage)
- Reconnect subscription ordering:
  - **Classification for yellow-dot symptom:** `NON-BLOCKER (fixed)`
  - Evidence: reconnect/manual retry path and subscription setup ordering cited above.
- Single-writer seam status (cursor ownership):
  - **Classification for yellow-dot symptom:** `NON-BLOCKER`
  - **Classification for full spec conformance:** `BLOCKER (structural debt remains)`
  - Evidence that service still owns cursor storage APIs in non-lifecycle path:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:379`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:391`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:910`
  - Evidence lifecycle mode now bypasses legacy decode/cursor write path for message events:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:695`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:703`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:715`

### 3) Runtime evidence focused on yellow-dot symptom
- Fresh simulator logs show stale-close suppression is active:
  - `ignoring stale lifecycle socket close` emitted after fallback switch.
- Logs also show lifecycle progressed out of connecting:
  - `idle -> connecting -> authenticating` then auth success message.
  - This means it is not hanging permanently in connecting in this run.
- In same run, a subsequent transition to `recovering -> failed` still occurs after auth success, indicating there is likely an additional post-auth transport-close issue unrelated to stale listener leakage.

## Opus pass status
- Claude Opus pass executed successfully (not rate-limited) and output captured at:
  - `/Users/mike/src/worktrees/per-stream-state/scratch/opus-review-20260227-000127.txt`
- Opus agreed stale-listener fix is non-regressing for connect/reconnect/auth path and classified reconnect-ordering + single-writer seam as non-blockers for the specific yellow-dot symptom.

## Recommendation (device deploy retest decision)
- **GO for targeted device retest of T100 connection symptom** on `ae7933d18`.
- **NO-GO for declaring final connection fix** based on this commit alone.
- Rationale:
  - Known stale-listener race is patched and verified by runtime log behavior.
  - But simulator logs still show a separate post-auth close/failure path that may still affect device behavior and needs device-log confirmation.
