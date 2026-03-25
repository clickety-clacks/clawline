# Prewarm Controller Safety — Non-Obvious Details

## Why two concrete types — not an enum gate
The capability split (prewarm vs page controller) must be **two separate Swift types**, not a runtime flag or enum gate. This is required so that write-surface APIs are unreachable for prewarm controllers at compile time, not just at runtime. An enum gate can be bypassed; missing methods cannot be called at all.

## WriteHandle minting is fileprivate — prewarm code cannot compile if it calls write seams
`WriteHandle` minting is `fileprivate` to the store module/type that owns state. Prewarm-side code that attempts to call any write seam fails to compile. This is the enforcement mechanism — not a runtime assertion.

## Shared layout artifact cache is the ONLY write prewarm is allowed
Prewarm may write only to the shared coordinator-owned layout artifact cache. That cache is pure derived state from `ReadHandle + LayoutSnapshot`. It is coordinator-owned (not controller-owned), so it survives prewarm teardown. Prewarm writing to any `WriteHandle`-protected state is a spec violation.

## Prewarm teardown trigger: page controller's first successful `dataSource.apply`
Teardown is triggered when the page controller for the same session key completes its first successful `dataSource.apply`. Not on page creation, not on prewarm completion — on the page controller's first apply. This is a non-obvious timing requirement.

## Staleness guard: epoch-check before cache write
Prewarm layout work must carry a dispatch epoch token and verify it before writing to the shared cache. If the completion epoch is stale (stream list changed, prewarm was invalidated), the result must be dropped. Page controllers must tolerate cache misses and recompute.

## Two controllers for the same sessionKey during overlap: each owns its own data source
During the overlap window (prewarm + page both alive for the same key), both controllers may apply snapshots independently. They must **never share a single `NSDiffableDataSource` instance**. Sharing a data source causes UIKit assertion failures or silent data corruption.

## Safety TTL: 30 seconds from construction
A residual prewarm controller (never promoted to page) must auto-expire at 30 seconds from construction timestamp. TTL expiry executes full teardown (cancel timers, detach bindings, remove from prewarm list, release references).

## `LayoutSnapshot` identity is value identity — not object identity
Cache keying must use geometry-value equivalence (width, safe area, content insets, etc.), not object reference equality. Geometrically equivalent snapshots must hit the same cache key. Using reference identity produces cache misses for semantically identical geometry, causing unnecessary prewarm recalculation.

## `MessageFlowRenderCore` must not hold write-capable handles
Core purity constraint: `MessageFlowRenderCore` must not hold references to write-capable store handles or controller-global mutable singletons. Any mutable state inside core must be render/read/layout-only. Violating this makes prewarm controllers implicitly capable of writes through the shared core instance.
