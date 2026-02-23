# Prewarm Controller Safety Invariants

## Status
Canonical invariants from Flynn design session. These are required system boundaries, not proposals.

## Context
`ChatView` uses overlay prewarm shells to pre-instantiate adjacent stream controllers so swipe transitions are instant.

`TabView(.page)` lazily creates page controllers on pan gesture, so prewarm exists to force early UIKit controller creation.

Prewarm controllers are separate SwiftUI nodes from `TabView` pages. There is no UIKit promotion path from prewarm node to page node.

## Scope
This spec defines compile-time and runtime invariants for prewarm/page controller safety, parity, and teardown.

## Invariant 1: Capability Split (Compile-Time Enforced)

### Required Types
- Two concrete controller types must exist:
  - `PageMessageFlowController`
  - `PrewarmMessageFlowController`
- This split must be represented by separate Swift types, not an enum gate.

### Required Handles
- Page controller receives both:
  - `ReadHandle`
  - `WriteHandle`
- Prewarm controller receives only:
  - `ReadHandle`

### Write-Surface Restriction
All state mutation APIs are write-surface APIs and must be reachable only through `WriteHandle`:
- `mutateState`
- persistence flush writes
- restore phase mutations
- timer/deferred write scheduling and callback mutation paths
- SBB state mutations

### Cache Write Exception
- Shared layout artifact cache writes are explicitly allowed for both controller types.
- This exception exists because the cache is derived-state only and outside `WriteHandle`-protected runtime/persistence state.

### Handle Minting Restriction
- `WriteHandle` minting is `fileprivate` to the store module/type that owns state.
- Only controller factory code can receive minted handles.
- Prewarm-side code must fail to compile if it attempts to call write seams.

## Invariant 2: Shared Render Core (Algorithmic Parity)

### Core Extraction
- `MessageFlowRenderCore` is the single source of truth for render/read/layout algorithms.
- Both controller types embed this core via composition, not inheritance.

### Core Ownership
Core owns:
- message materialization planning
- sizing/layout algorithm execution

Page-only render path owns:
- snapshot construction
- diffable apply orchestration
- markdown rendering and cell configuration

### Data Source Isolation
- Each controller instance owns its own `NSDiffableDataSource` and backing `UICollectionView` instance.
- `MessageFlowRenderCore` produces snapshots as values; controller code decides when to apply those snapshots to its own data source.
- During overlap (prewarm + page alive for the same `sessionKey`), both controllers may apply snapshots independently, but they must never share a single `NSDiffableDataSource` instance.

### Page-Only Write Behaviors
Write-specific behaviors stay page-only and outside prewarm capability:
- persistence flush and write debounce ownership
- restore phase mutation and confirmation state
- SBB mutable runtime state
- mutable timer/deferred write paths

### Core Purity Constraint
- `MessageFlowRenderCore` must not hold references to write-capable store handles or controller-global mutable singletons.
- Any mutable state inside core must be render/read/layout-only and derivable from `ReadHandle` + `LayoutSnapshot`.

## Invariant 3: Single Geometry Source (Layout Parity Guarantee)

### Provider Ownership
- `LayoutContextProvider` is owned above both controller types (pager/coordinator level).
- Geometry is computed once per update tick from pager container context.

### Snapshot Type Safety
- Provider mints `LayoutSnapshot`.
- `LayoutSnapshot` has no public initializer (unforgeable by controller code).

### Shared Tick Input
- For each tick, both page and prewarm receive the same `LayoutSnapshot` instance.
- Render core APIs require `LayoutSnapshot`; no core API may accept loose width/inset/safe-area scalars.
- Neither controller computes geometry inputs independently.

### Snapshot Identity Semantics
- `LayoutSnapshot` identity for cache keying is value identity, not object/reference identity.
- Cache keying must use geometry-value equivalence (for example: width, safe area, content insets, and other geometry inputs represented by `LayoutSnapshot`).
- Geometrically equivalent snapshots must hit the same cache key.

## Invariant 4: Prewarm Runs Layout-Only Pipeline

### Required Prewarm Work
Prewarm must execute layout-only pipeline:
- flow layout path
- cache lookup path for measured sizes
- placeholder-size fallback for cache misses

### Shared Artifact Cache
- Layout artifacts are stored in shared coordinator-owned cache.
- Cache key identity includes:
  - `sessionKey`
  - `messageId`
  - `LayoutSnapshot` identity
- Page controller reads from this same cache.

### Staleness Guard
- Prewarm layout work must carry dispatch epoch and verify it before cache write.
- If completion epoch is stale versus current coordinator epoch, drop the result instead of writing cache artifacts.

### Prewarm Prohibitions
Prewarm must NOT execute:
- markdown rendering (`UnifiedMarkdownRenderer`)
- UIKit bubble cell configuration (`MessageBubbleUIKitView.configure`, `MessageBubbleUIKitCell.configure`)
- diffable snapshot apply / datasource mutation paths

### Safety Boundary
- Prewarm doing layout-only work does not grant `PerStreamRuntimeState` write capability.
- Prewarm may write only to shared layout artifact cache because that cache is pure derived state from `ReadHandle` + `LayoutSnapshot`.
- `WriteHandle`-protected state is limited to mutable runtime/persistence state (scroll, SBB, timers, deferred writes, restore phase, persistence writes).
- Prewarm must not mutate any `WriteHandle`-protected state in callbacks, observers, completion handlers, or deferred work.

## Invariant 5: Prewarm Teardown Lifecycle

### Teardown Trigger
- Teardown prewarm controller for a session key when page controller completes first successful `dataSource_apply` for that same session key.

### Teardown Actions
Teardown must perform all of:
- cancel timers/work items owned by prewarm controller
- detach datasource/delegate bindings
- remove from SwiftUI prewarm list
- release retained references

### Teardown Atomicity
- Teardown cancels future prewarm work dispatches, but does not interrupt an in-progress single cache-entry write.
- Cache-entry writes must be atomic at entry granularity: fully committed or not committed.
- Page controller must tolerate cache miss/staleness and recompute layout as needed.

### Additional Invalidation Triggers
- Safety TTL auto-expire for residual prewarm controllers.
- Invalidate prewarm controllers on:
  - stream list changes
  - memory warnings

### Safety TTL Definition
- A residual prewarm controller is one that has not been promoted to page creation and has exceeded TTL since construction.
- TTL starts at prewarm controller construction timestamp.
- TTL default is 30 seconds unless Flynn specifies otherwise.
- TTL expiry executes full teardown actions.

### Cache Ownership Rule
- Layout cache survives prewarm teardown.
- Cache is coordinator-owned, not controller-owned.

## Invariant 6: Factory Enforcement

### Sole Construction Path
- `MessageFlowControllerFactory` is the only legal construction path for both controller types.

### Required Factory APIs
- `makePageController(sessionKey:)` injects `ReadHandle` + `WriteHandle` scoped to that immutable `sessionKey`.
- `makePrewarmController(sessionKey:)` injects `ReadHandle` scoped to that immutable `sessionKey`.

### Prohibition
- No other code path may mint or inject `WriteHandle`.

### Construction Visibility
- Constructors/initializers for `PageMessageFlowController` and `PrewarmMessageFlowController` must not be publicly callable from feature code paths that bypass `MessageFlowControllerFactory`.

## Cross-Invariant Enforcement Checklist
- Capability split is compile-time enforced by separate concrete types and handle injection.
- Render parity is enforced by one shared core and one shared geometry snapshot source.
- Prewarm value is preserved (real layout + shared cache), without introducing state mutation surface.
- Lifecycle is bounded by explicit teardown triggers and coordinator-owned cache persistence.
- Controller/data-source ownership is isolated so overlap cannot concurrently mutate the same diffable data source.
- Epoch guards prevent stale async prewarm work from polluting shared cache.

## Prewarm Scope
- Prewarm controller set is exactly immediate pager neighbors of selected stream (`-1` and `+1` when present).
- Maximum simultaneous prewarm controllers is 2 (or 1 at boundaries).
- On selected stream or stream-list changes, recompute adjacency set and apply create/teardown transitions accordingly.

## Implementation Handoff
- This spec defines mandatory boundaries and invariants.
- Implementation must not replace structural ownership with lifecycle reset patches.
- Any discovered gap must be resolved by updating this spec before code broadening.
