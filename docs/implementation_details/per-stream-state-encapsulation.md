# Per-Stream State Encapsulation — Non-Obvious Details

## The seam fires before offscreen early-return guards
Steps 1-6 of the stream-context switch seam execute **before** `isRenderPolicyFrozen` and offscreen early-return guards. Those guards apply only to step 7 (heavy render work). An offscreen controller that skips the seam entirely loses scroll persistence flush and restore-phase setup — both of which must happen even for frozen/offscreen pages.

## Outgoing scroll persistence must flush using outgoing key captured BEFORE mutation
The flush in step 2 (`persistScrollStateNow(outgoingSessionKey)`) must capture the outgoing-key geometry/state before rebinding the incoming key. Reading effective key after mutation is forbidden for switch-time flush. This is a TOCTOU bug if done wrong — the flush would capture the incoming stream's geometry.

## Debounce timers are batching optimizations only — not lifecycle gates
Debounce timers are allowed while staying in one key, but on switch they must always flush immediately and cancel. Any debounce callback must execute with a captured `sessionKey`, never with an implicit reference to the "current active" key.

## One "at bottom" definition must be shared across three sites
SBB hide/show logic, auto-scroll eligibility for appended messages, and restore fallback-to-bottom checks must use a **shared helper and threshold source** — not duplicated constants. Any threshold split between these three call sites is a spec violation that produces inconsistent SBB behavior where the button hides at a different point than when auto-scroll triggers.

## `forceReReadGeneration` is the only valid same-key re-read trigger
A normal same-key `update(...)` with unchanged `forceReReadGeneration` must not re-arm restore. Only an explicit `forceReReadGeneration` advance triggers re-read. Without this, any re-render re-arms restore and loops.

## Deferred work from stream A must never execute in stream B context
All timers and deferred queues store their owning `sessionKey` at creation and validate it at execution. Pending scroll-to-bottom retry work (currently recursive main-queue scheduling) must be converted to cancellable or generation-gated work items. This is the RC-D failure mode: a deferred scroll retry fires after a stream switch and scrolls the wrong stream to bottom.

## Replay cursor belongs to transport layer, not ChatViewModel UI state
Per-stream replay cursors (`replayCursorBySessionKey`) must be stored in `ProviderChatService` (transport layer), NOT in `ChatViewModel` UI runtime state. A single global replay cursor for multiple streams means the non-active stream's replay is under-fed at login, causing the T099 "stale/empty streams" bug.

## `lastAppliedEffectiveSessionKey` set at step 8 (before heavy render)
The seam key is committed before step-7 heavy render work begins. UIKit scroll delegate callbacks must route through `lastAppliedEffectiveSessionKey`, not a dynamic `resolvedSessionKey()` fallback, so callbacks during seam execution cannot target the incoming key prematurely.

## Same-key re-read must NOT persist geometry until `confirmed`
The re-read path must reload persisted state from durable storage and must not write current in-memory geometry until the new restore generation reaches `confirmed` (or deterministic fallback). Writing geometry during a re-read poisons the persisted scroll anchor with a stale position.

## Per-stream state cleanup on session delete
`perStreamStateBySessionKey` entries must be pruned when `orderedSessionKeys` changes. Timers and work items owned by the deleted key must be cancelled. A deleted key that is later recreated starts with a fresh runtime entry — no leakage from the prior incarnation.

## BubbleSizingV2 cache keys must include `sessionKey`
Where a shared controller-global LRU cache exists, cache keys must include `sessionKey` in their identity. Stream cleanup must not evict another stream's active entries. Failing this, switching streams invalidates the visible stream's measured heights and triggers unnecessary full rebuilds.
