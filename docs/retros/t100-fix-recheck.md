# T100 Fix Re-Review

**Commit:** `a7486e4b2` on `per-stream-state`
**Date:** 2026-02-25

## Fix 1: Terminal server events from any active phase — PASS

Lines 302-319 of `ConnectionLifecycleCoordinator.swift`: terminal failure check now runs **before** the `guard phase == .authenticating` gate at line 320. The new block handles `!success` with explicit `failureReason` matching:

- `.sessionReplaced` → `fail(.sessionReplaced)` + return (line 304-306)
- `.tokenRevoked` → `fail(.tokenRevoked)` + return (line 307-309)
- `.rejected` → `fail(.authRejected)` + return (line 310-312)
- `.protocolMismatch` → `fail(.protocolMismatch)` + return (line 313-315)
- `nil` → falls through to phase-gated auth flow (line 316-318)

`fail()` calls `transition(to: .failed, ...)` which accepts transitions from any active phase per `isLegalTransition`. No phase guard precedes this block — terminal events reach `fail()` regardless of whether phase is `connecting`, `authenticating`, `replaying`, `live`, or `recovering`.

**Note:** The old phase-gated failure handling at lines 323-332 is now dead code for any `failureReason` that is non-nil. The `case nil: break` at line 316 falls through to the `guard phase == .authenticating` gate, which then hits the `guard success else { ... }` block. Since `failureReason` is nil in that path, the `default: fail(.authRejected)` at line 330 handles it. Functionally correct but leaves redundant code. Not a bug.

## Fix 2: Background no longer transitions failed → idle — PASS

Lines 613-620 of `ConnectionLifecycleCoordinator.swift`: `moveToIdleIfNeeded` now matches:

- `.connecting, .authenticating, .replaying, .live, .recovering` → transition to idle
- `.idle, .failed` → break (no-op)

`failed` is explicitly in the no-op branch. `appDidEnterBackground()` calls `moveToIdleIfNeeded(reason: .appBackgrounded)` — when phase is `failed`, nothing happens. On subsequent foreground, `appDidBecomeActive()` checks `guard reconnectEnabled, phase == .idle` which won't match `failed`, so no auto-retry occurs.

## Verdict: 2/2 PASS
