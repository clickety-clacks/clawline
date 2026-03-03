# T113 P0 Regression Investigation — Slowdown + Connection Instability
Date: 2026-02-25
Branch analyzed: `per-stream-state` (`30b4a4158`)
Baseline compared: `origin/feature/voice-dictation` (`33f3228005a0140e1ddc73e987b7cbcdb2b6757b`)

## Scope
Investigated regression report from Ansible after latest per-stream-state deploy:
- severe app slowdown
- provider connection instability
- rollback to dictation restored normal behavior

No deploy actions were taken.

## Diff Surface vs Dictation Baseline
Changed files vs dictation baseline:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift` (+1188/-260)
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift` (+109/-?)
- `ios/Clawline/Clawline/Services/ProviderChatService.swift` (+78/-?)
- `ios/Clawline/Clawline/Views/Chat/StreamSwitchTiming.swift`
- minor protocol/stub/siri/bubble sizing adjustments

Per-stream-state commit line includes:
- `f514449da` add T095 diagnostics
- `4145c0fe3` switch stream diagnostics to `print()`
- `aaa80e76a` add persist-geometry diagnostics
- `c110f5618` phase 1 cursor migration + callback/timer changes
- `30b4a4158` latest scroll flush adjustment

## Findings (Likely Root Causes)

### 1) High-frequency stdout logging in hot UI paths (High confidence)
`StreamSwitchTiming.log` was changed from `NSLog` to `print`.

- Baseline (`feature/voice-dictation`): `NSLog` in `StreamSwitchTiming.swift`
- Current (`per-stream-state`): `print` in `StreamSwitchTiming.swift`

This logger is invoked in high-frequency locations:
- `MessageFlowLayout.prepare()` start/end (`MessageFlowCollectionView.swift` lines ~4151, ~4168, ~4226)
- snapshot build/apply sequencing
- newly added scroll persist/restore diagnostics (`scroll_persist_geometry`, `scroll_restore_attempt`, etc.)

Why this matters:
- `print` to stdout in tight layout/scroll loops is significantly more expensive than structured logging.
- This can saturate main-thread time during scroll/layout churn.
- Main-thread starvation can indirectly destabilize provider connection handling (missed timely processing/ack scheduling windows).

### 2) Duplicate replay-cursor persistence on incoming messages (High confidence)
Replay cursor writes moved to transport layer (`ProviderChatService`), but writes are now occurring in two places:

- `ProviderChatService.handleMessagePayload(...)` calls `setReplayCursor(...)` for every `s_*` message.
- `ChatViewModel.updateLastServerMessageIdIfNeeded(...)` also calls `chatService.setReplayCursor(...)` for every `s_*` message.

`setReplayCursor(...)` persists snapshot to `UserDefaults` each call (`persistReplayCursorSnapshot()`), so incoming message traffic causes repeated encode+write cycles on the main actor.

Why this matters:
- Extra synchronous persistence in message hot path increases CPU and I/O pressure.
- Duplicated writes amplify overhead during streaming-heavy chats.
- This can contribute to both UI sluggishness and transport timing instability.

### 3) Added diagnostic log volume specifically for T095 tracing (Medium confidence)
New logs introduced in `persistScrollStateNow(...)` and restore path include large formatted geometry payload strings and fire frequently during interaction.

On top of finding #1 (`print` backend), this further increases runtime overhead.

## What Did NOT Look Like Primary Cause
- Latest commit `30b4a4158` (prefer live geometry over cached when available) is a targeted branch adjustment and unlikely by itself to create systemic provider instability.
- Force re-read generation plumbing appears architecturally aligned and not an obvious direct source of connection churn.

## Minimal Rollback-Safe Patch Plan (No Architectural Reversal)

### Patch A (first, lowest risk): disable hot-path stdout diagnostics
1. Change `StreamSwitchTiming.log` backend back to `NSLog` (or gate `print` behind explicit runtime debug flag default OFF).
2. Remove or gate T095-specific verbose geometry logs in `persistScrollStateNow` and restore attempt/confirm logs.
3. Keep only sparse lifecycle logs (switch enter/exit) if needed.

Expected impact: immediate CPU reduction during scroll/layout; reduced main-thread pressure.

### Patch B (second, low risk): eliminate duplicate cursor writes
1. Keep transport-layer ownership in `ProviderChatService` as SSOT.
2. Remove `ChatViewModel.updateLastServerMessageIdIfNeeded -> chatService.setReplayCursor(...)` write path.
3. In `ProviderChatService.setReplayCursor(...)`, add no-op fast path if cursor unchanged before persisting.

Expected impact: reduces per-message encode/write overhead and avoids double persistence.

### Patch C (optional safety hardening if instability persists)
1. Debounce cursor snapshot persistence (short interval) while keeping in-memory cursor map current.
2. Flush immediately on disconnect/background transitions.

Expected impact: further I/O reduction without changing replay semantics.

## Verification Plan After Patch (before redeploy)
1. Profile startup + active chat scroll with logging disabled/gated.
2. Verify provider session stability over 10+ minutes under message streaming load.
3. Confirm no regressions in T095/T103 switch restore behavior.
4. Confirm replay cursor semantics unchanged (per-stream map still advances; auth snapshot remains spec-compliant).

## Conclusion
Most likely regression mechanism is cumulative hot-path overhead introduced after dictation baseline:
- stdout-heavy diagnostics in frequent layout/scroll paths, plus
- duplicated per-message replay-cursor persistence writes.

A minimal rollback-safe fix is to first remove/gate diagnostics and de-duplicate cursor persistence writes without undoing per-stream-state architecture.
