# T113 Phase 1 — CCX Interim Rerun (Codex)
Date: 2026-02-24
Scope: Adversarial interim rerun against
- `/Users/mike/shared-workspace/clawline/specs/per-stream-state-encapsulation.md`
- `/Users/mike/shared-workspace/clawline/specs/t113-architecture-plan.md`
Code baseline: `per-stream-state` after commits `c110f5618`, `e4306bf5c`.

## Summary
Overall status: **FAIL (interim)**
- Blocking Gate 4 (timer cancel + generation guard) is now fixed.
- Remaining blockers are callback-registry no-op semantics and a spec/implementation naming mismatch for re-read signal type.

## Gate Check (Phase 1)
1. Gate 1: `forceReRead` flows ChatViewModel → ChatView → controller
- **PASS (functional)**
- Evidence:
  - `ChatViewModel.forceReReadGeneration(for:)` exists and is armed on cache/cursor paths.
  - `ChatView` passes `forceReReadGeneration` to `MessageFlowCollectionView` for both page and prewarm shells.
  - Controller seam consumes generation via `runStreamContextSwitchSeam(incomingSessionKey:forceReReadGeneration:)` and `lastSeenForceReReadGeneration`.
- Note: spec text still says `forceReRead == true` (bool). implementation uses generation int.

2. Gate 2: One-shot callback registry exists and is used for restore
- **FAIL (blocking)**
- Implemented pieces exist:
  - `registeredMessageLoadCallbacksByMessageId`
  - register/fire/expire/clear paths
  - restore targeting via `scheduleRestoreAttemptOnMessageAppearance(...)`
- Blocking issue:
  - `registerOnMessageLoad(...)` has `guard callbackSessionKey() == sessionKey else { return }`.
  - This makes registration silently no-op when key is unresolved/transitioning, violating required deterministic behavior for "register then fire when materialized".
  - In effect, callbacks can be dropped during seam transitions rather than expiring by explicit stream-switch/deletion rules.
- Why blocking: gate requires registry to be reliable for restore targeting; silent no-op breaks that contract.

3. Gate 3: Canonical auth cursor rule (nil when any missing, max otherwise; no active/global fallback)
- **PASS**
- Evidence:
  - `resolveAuthLastMessageId(replayCursorSnapshot:knownSessionKeys:)` returns `nil` unless all normalized known keys have non-empty cursor values; otherwise returns max.
  - Active-session fallback removed.
  - Auth payload includes per-stream cursor map only when all known sessions have cursors.

4. Gate 4: Timer callbacks validate `(sessionKey, generation)` and switch cancels outgoing timers
- **PASS (blocker fixed)**
- Evidence:
  - `cancelDeferredWork(for:cancelAll:)` now invalidates and clears `scrollStateWriteDebounceTimer`.
  - `schedulePersistScrollState(sessionKey:)` captures `expectedGeneration` and no-ops if generation changed before persisting.
  - BubbleSizingV2 + bottom inset timer callbacks capture token via `activeSessionGenerationToken()` and validate generation prior to mutation.

5. Gate 5: Spec text updated with adversarial resolutions
- **PASS**
- Evidence:
  - Added "Adversarial Review Resolution Notes" section to per-stream-state spec covering required items.

6. Gate 6: Per-stream-state acceptance checks 1–25
- **FAIL (interim, manual subset only)**
- Not fully executed here.
- From static review, unresolved callback-registry reliability issue (Gate 2 fail) likely impacts acceptance checks around one-shot callback behavior and restore-trigger determinism.

## Blocking Findings
1. Callback registry registration can no-op based on current active key
- File: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- Function: `registerOnMessageLoad(sessionKey:messageId:callback:)`
- Problem: `callbackSessionKey()` guard can drop registrations rather than storing and later expiring/firing under explicit rules.
- Required fix: remove active-key hard no-op for registration, or route through explicit per-session storage even during transitions; keep fire-side key/generation safety.

2. Re-read signal contract mismatch (spec bool vs implementation generation int)
- Spec states `forceReRead == true` trigger semantics.
- Code moved to generation-based seam (`forceReReadGeneration`).
- Required fix: update spec language to match generation-based re-read signal (or adapt implementation back to bool seam).
- Severity: blocking for strict spec compliance review.

## Non-Blocking Nits
1. Transitional shim documentation rule in architecture plan not applied
- Plan says shim accessors should be marked with `// MIGRATION SHIM — remove when all callers pass explicit sessionKey`.
- Current file lacks these markers.
- Non-blocking for runtime behavior; useful for cleanup discipline.

2. Callback invocation actor/ordering robustness
- callbacks fire synchronously once materialized; consider main-actor hop consistency if called from future async paths.
- Non-blocking at present (controller is main-actor context).

## Interim Conclusion
- **Former blocker (timer cancel + generation guard): fixed and passing.**
- **Phase 1 cannot be called ready for final adversarial pass yet** due to callback-registry registration no-op behavior and spec/impl re-read signal mismatch.
