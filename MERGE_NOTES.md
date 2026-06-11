# PCS Connect Ownership Refactor

This refactor restructures connect-path ownership in `ProviderChatService`.

It exists because the merge of `origin/main` into `feature/voice-dictation` preserved two different connection-control systems in one service:

- main's `ConnectJoinGate`, which deduplicated direct `connect()` calls
- dictation's lifecycle connect cluster, which coordinated `startConnectionAttempt()` / `stopConnectionAttempt()` for the app runtime

That merge result was a lazy conflict resolution. It kept both systems without choosing one owner or synthesizing one coherent transport control seam.

## What Is Changing

Deprecated:

- `ConnectJoinGate`
- lifecycle cluster variables and their direct control paths:
  - `connectAttemptTask`
  - `activeLifecycleConnectionToken`
  - `pendingLifecycleAuthToken`
  - `lifecycleConnectInFlight`
  - `lifecycleConnectWaiters`

Replacement direction:

- `TransportSessionCoordinator` actor as the single transport state and transition owner
- `ProviderDirectChatClient` as the standalone direct-connect surface

The managed app runtime remains lifecycle-owned. Standalone direct connect becomes a separate public path instead of coexisting inside the shared app service.

## Why It Was Done

This is dictation-motivated work on `feature/voice-dictation`.

The dictation branch introduced a lifecycle-managed connection path. After the upstream merge, that lifecycle path and main's direct-connect dedupe path were both left active in `ProviderChatService`, which created split ownership over the same transport state.

The refactor removes that mixed pattern and replaces it with one explicit ownership model.

## Full Spec

See `scratch/pcs-connect-ownership.md` for the full design and migration plan.
