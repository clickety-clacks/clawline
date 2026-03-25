# Bubble Sizing V2 — Non-Obvious Details

## Cached measurements must never force a bubble narrower than `minWidth`
`applyMeasuredSize` clamps only to `maxWidth` — no min width floor. A bad measurement (e.g., from an off-screen sizing pass with wrong constraints) can "stick" because the cache prefers cached width. This produces thin/squished bubbles that are hard to reproduce. The fix: `minWidth` is an explicit field in `BubbleLayoutPlan` and all measurements are rejected below this floor.

## `BubbleLayoutPlan` is computed once and shared between `sizeForItem` and `cell.configure`
The same `BubbleLayoutPlan` instance drives both the sizing pass (offscreen) and the actual render configuration. Views apply decisions; they do not re-derive `isWide`, `maxWidth`, `heightCap`, or outer scroll enablement independently. Any code that re-derives these in a view creates divergence between measured size and rendered layout.

## The "two caps" become an explicit `heightCapMode` enum — not an implicit override presence check
The current code distinguishes "screen-aware cap" from "design-system cap" by checking whether a `truncationHeightOverride` is present. The new model makes this explicit: `heightCapMode: .designSystem | .screenAware`. Code that detects cap type by nil-checking an override parameter is the old pattern.

## Link preview's "return cap height immediately" behavior is explicitly eliminated
Old offscreen sizing had a major fork: for link preview + truncation override, it returned the truncation cap height immediately without real measurement. This produced incorrect cached sizes that would stick. Link preview is now a first-class `BubbleMeasurable` that participates in normal measurement with explicit `estimated → final` state.

## `BubbleLayoutEnvironment` is part of the cache key — measurement is invalid if environment fingerprint differs
A measurement cached for one container width/height/metrics is invalid for a different environment. The `metricsFingerprint` must include every metrics/font input that affects measurement results (text fonts, dynamic type category, padding, stack spacing, header row height, failure badge sizing, design-system truncation cap). Forgetting to include a metric in the fingerprint produces stale cached sizes that persist across dynamic type or theme changes.

## visionOS has different width clamp behavior — `platform` is a cache key field
`BubbleLayoutEnvironment` includes a `platform` enum field (`iOS` vs `visionOS`). visionOS uses different width clamping. Two measurements for the same message with the same geometry but different platforms must not share cache entries.
