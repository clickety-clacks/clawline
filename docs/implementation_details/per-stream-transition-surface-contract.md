# Per-Stream Transition Surface Contract — Non-Obvious Details

## The universal rule: capture session generation token at schedule time, validate before any access
Every closure executing after a yield boundary must capture `(sessionKey, generation)` at schedule time and validate both before any per-stream read or write. Using a shim property after a yield boundary routes through `activeStateKey()` which reflects whatever session is current — not necessarily the one the closure was scheduled for. This is the single most common source of wrong-stream mutations.

## Property shims are safe in bound-epoch context ONLY
Property shims (computed properties routing through `activeStateKey()`) are safe only within the same synchronous `update()` call or its synchronous continuations (layout, `cellForItem`, snapshot build), and in UIKit delegate callbacks that fire in the same runloop turn. After any yield boundary, shims are a spec violation.

## `dataSource.apply` completions are yield boundaries even for non-animated applies
When `animatingDifferences: false`, the completion fires in the same runloop turn — but it must still be treated as a yield boundary and guarded. The spec's rationale: future changes to animation mode should not silently break the guard semantics.

## Cleanup obligations survive guard failure
Any per-stream state set in the capture phase (before a yield) must be cleared in ALL exit paths after the yield, including guard-failure paths. Example: `morphTargetMessageId` set before an animation — if the session switches during the animation, the guard fires and returns, but `morphTargetMessageId` must be set to `nil` in the guard-failure branch. Stale values in `PerStreamRuntimeState` cause willDisplay to suppress cell alpha indefinitely.

## `viewDidLayoutSubviews` must pass ALL stored parameters to `update()`
`viewDidLayoutSubviews` is not a new call site — it predates per-stream migration. It must explicitly pass `sessionKey: channelOverride`, `onScrollEvent: onScrollEvent`, `onExpand: onExpand`, `isDark: currentIsDark`, and `forceReReadGeneration: 0`. Relying on defaults from an internal re-entry loses state. Same rule for any internal `update()` call site.

## Default-parameter hazard on `update()` extension
When migration extends `update()`'s parameter set with session-critical parameters that have default values, the compiler will not flag existing callers. Every existing caller silently inherits the default, which may be semantically wrong. The rule: enumerate all call sites and verify each default is safe; or remove the default to force compile errors.

## `deinit` must cancel deferred work for ALL streams, not just the active one
`deinit` runs in an unbound context — `activeStateKey()` returns whatever was last bound. `deinit` must iterate `perStreamStateBySessionKey` and cancel all deferred work for every session. Missing a cancellation is harmless (callbacks no-op on deallocation) but wastes runloop work.

## SBB emission: forced vs change-detection — get this wrong and you get per-frame SwiftUI mutations
Steady-state path uses `emitHideIndicatorIfChanged(force: false)` — change detection, not forced. Forced emission (`force: true`) is used only by `setSBBState(_:)` on every SBB state transition, and by the switch seam on incoming session bind. Forcing emission on the steady-state path causes per-frame dictionary mutations in SwiftUI state containers.

## `scheduleTailToFullPromotionIfNeeded` uses live `engineActiveSessionKey` — generation guard needed
This GCD async uses a compound guard that checks `engineActiveSessionKey` live (not `callbackSessionKey()`), and has no generation guard. A generation bump during tail→full could cause a stale promotion to apply. Marked as "needs generation guard" in the contract.

## `scrollToMessageCentered` callback needs generation guard
This registered one-shot fires scroll targeting which can land at the wrong position if triggered after a same-key re-read that changed the restore generation. Marked as needing generation guard in the contract.
