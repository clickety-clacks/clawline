# Bubble Sizing Refactor (Step 1 Spec)

Owner: bubble sizing refactor

This spec describes the new architecture for bubble sizing in UIKit chat bubbles (MessageFlowCollectionView + MessageBubbleUIKitView) and how we collapse the current branchy behavior into a single coherent pipeline.

It is written against the current audit: `scratch/bubble-sizing-audit.md`.

## Goals

1. **Single layout state object per message.** Compute once per message (per environment):
   - `isWide`
   - `maxWidth`
   - `heightCap` (and cap mode: design-system vs screen-aware)
   - outer-scroll decision inputs and final decision

2. **Unified measurement + caching policy.**
   - One measurement pipeline for offscreen sizing and live "re-measure after async content" sizing.
   - Cached values must not lock in pathological sizes (explicit min-width floors; reject invalid measurements).
   - Clear invalidation rules keyed off message fingerprint + environment.

3. **Link preview is a first-class measured subcomponent.**
   - No more special-case "return cap height immediately" behavior during offscreen sizing.
   - Link preview participates in measurement like other parts, with an explicit "estimated vs final" measurement state and cache invalidation when it becomes final.

## Non-Goals (Step 1)

- No UI redesign.
- No redefinition of message presentation rules (URL detection / when `.linkPreview` is appended) beyond what is required for sizing correctness.
- No refactor of unrelated flow layout / data source concerns.

## Current System (Problem Summary)

Today there are multiple interacting decision points spread across files:

- **Flow controller** decides wide/narrow and sometimes passes `truncationHeightOverride`.
- **Bubble view** independently decides if outer scroll should be enabled by re-measuring its dynamic content.
- **Offscreen sizing** has a major fork for link preview + truncation override where it returns the truncation cap height immediately, skipping real measurement.
- **Caching** can persist too-small widths because `configureWidth` prefers cached width, and `applyMeasuredSize` clamps only to max width (no min width floor), so a bad measurement can "stick".

This leads to recurring regressions: thin bubbles, squished avatars, missing scroll views, clipped cards.

## Proposed Architecture

Introduce a single "layout planning + measurement" unit that produces **one** authoritative `BubbleLayoutState` for both:

- `sizeForItem(at:)` (cell sizing)
- `cell.configure(...)` / `MessageBubbleUIKitView.configure(...)` (actual rendering)

### Architecture Invariants (Non-Negotiable)

- **One source of truth:** once `BubbleLayoutPlan` is computed for `(message, env)`, no other file recomputes `isWide`, `maxWidth`, `heightCap`, or outer scroll enablement. Views apply decisions; they do not derive them.
- **Cache safety:** cached measurements must never be able to force a bubble narrower than `minWidth` or wider than `maxWidth`, and must never be reused across a different environment (width/height/metrics/platform).
- **Async correctness:** async subcomponents (link preview) must support `estimated -> final` transitions with deterministic invalidation and recomputation; no "bad value sticks" behavior is permitted.

### New Types

All names are working names; exact placement can shift, but the ownership boundaries should not.

#### 1) `BubbleLayoutEnvironment`

Captures inputs that vary by device/layout and must be part of the cache key.

Fields (minimum):
- `containerWidth: CGFloat` (effective content width)
- `containerHeight: CGFloat` (for screen-aware cap)
- `contentInsets / safeArea / bottomInset inputs` (whatever is used today for `effectiveTruncationHeight(metrics:)`)
- `metricsFingerprint: Int` (or stable hash of theme metrics and fonts that affect size)
- `platform: enum { iOS, visionOS }` (visionOS width clamp behavior)

Ownership: constructed by `MessageFlowCollectionViewController`. This environment is part of the cache key; a measurement is invalid unless the environment fingerprint matches exactly.

`metricsFingerprint` must include every metrics/font input that affects measurement results (non-exhaustive examples):
- text fonts and dynamic type category (anything feeding OTW)
- horizontal/vertical bubble padding and stack spacing
- header row height
- failure badge sizing
- design-system truncation cap (`metrics.truncationHeight`)
- any theme-driven max widths (if present)

#### 2) `BubbleLayoutPlan`

Computed once per message + environment (pure function, no UIView work). This is the "contract" shared between controller and bubble view.

Fields:
- `messageId: String`
- `presentationFingerprint: Int` (already in controller logic)
- `sizeClass: MessageFlowRules.SizeClass`
- `maxWidth: CGFloat` (final bubble width constraint used in configure)
- `minWidth: CGFloat` (explicit floor; see policy below)
- `isWide: Bool`
- `heightCap: CGFloat`
- `heightCapMode: enum { designSystem, screenAware }`
- `measurables: [BubbleMeasurable]` (derived from parts; link preview becomes a normal entry)

Notes:
- `heightCap` is always computed and always present. The "two caps" become an explicit mode, not an implicit "override present or not".

#### 3) `BubbleMeasurement`

Result of running measurement for a given `BubbleLayoutPlan`.

Fields:
- `measuredCellSize: CGSize` (what flow layout uses)
- `measuredBubbleWidth: CGFloat` (what bubble view uses; typically equals `maxWidth` after clamping)
- `contentHeight: CGFloat` (sum/stack height of dynamic content, excluding chrome)
- `outerScrollEnabled: Bool`
- `outerScrollViewportHeight: CGFloat` (when enabled, equals `heightCap` adjusted for bubble chrome)
- `isFinal: Bool` (whether async subcomponents have final sizes)
- `debugReasons: [String]` (optional, debug-only)

Key rule: **outer scroll decision is computed here (once), not inside `MessageBubbleUIKitView`.**

#### 4) `BubbleMeasurable` (enum, closed set)

Use a closed enum so measurement is exhaustive and cacheable/serializable.

Minimum required cases:
- text blocks
- media (image/gallery)
- table/code blocks
- link cards
- **link preview** (first-class)

Link preview sizing is allowed to be "estimated" until the live view reports a concrete height.

### Ownership and Flow

Ownership boundaries (explicit):
- `BubbleLayoutEnvironment`: constructed by `MessageFlowCollectionViewController`.
- `BubbleLayoutPlan`: constructed by a pure function owned by `MessageFlowCollectionViewController` (no UIKit view reads).
- `BubbleMeasurement`: produced by a measurer owned by `MessageFlowCollectionViewController` (the only place allowed to run sizing).
- `MessageBubbleUIKitView`: receives `BubbleLayoutPlan` + `BubbleMeasurement` (or merged `BubbleLayoutState`) and applies constraints; it must not derive layout decisions.

#### Single pipeline

1. Build `MessagePresentation` (unchanged).
2. Build `BubbleLayoutEnvironment` from collection view/container + theme metrics.
3. Compute `BubbleLayoutPlan` from (message, presentation, env, metrics).
4. Look up cache by `BubbleCacheKey(plan, env)`.
   - If present and valid, use cached `BubbleMeasurement`.
   - If missing or invalid, run measurement to produce `BubbleMeasurement`.
5. `sizeForItem(at:)` returns `measurement.measuredCellSize`.
6. `cell.configure(...)` uses `plan + measurement` (or a merged `BubbleLayoutState`) and does not recompute layout decisions.

#### Eliminating cross-file implicit contracts

- The controller no longer "sometimes passes truncationHeightOverride"; instead it always passes a `BubbleLayoutState` that includes cap mode and cap height.
- The bubble view no longer inspects content and decides scroll enablement; it receives the decision and only applies constraints.

## Policy: Width, Height Caps, and Outer Scroll

### Width policy

We make width floors explicit and clamp everywhere we store or consume sizes.

- `maxWidth`: computed exactly once in `BubbleLayoutPlan`.
- `minWidth`: computed exactly once in `BubbleLayoutPlan`.

Rules:
- `measuredBubbleWidth = clamp(measuredWidth, minWidth, maxWidth)`.
- Any measurement that produces `measuredWidth < minWidth` is treated as suspect; the system must either:
  - replace it with `minWidth` and mark non-final, or
  - reject caching it.

Initial `minWidth` policy (correctness floors, not typography constraints):
- `.short`: `minWidth = max(metrics.minBubbleWidth ?? 40, 40)`.
- `.medium`: `minWidth = max(containerWidth * 0.25, metrics.minBubbleWidth ?? 80)` (preserving today's intent).
- `.long`: `minWidth = max(metrics.minBubbleWidth ?? 80, 80)`.

Notes:
- `.short` is allowed to be narrow; the floor exists only to prevent pathological single-digit widths from measurement/caching bugs.
- `.long` should never present as a thin strip.

### Height cap policy

- `heightCap` is always computed in plan:
  - `screenAware`: when `isWide == true` (today's behavior).
  - `designSystem`: otherwise.

- Measurement computes `outerScrollEnabled` using:
  - gate conditions (e.g. never enable for single-image-only)
  - AND `contentHeight > heightCap`

### Single-link (web preview) bubble height rule (2026-02-12)

**Single-link bubbles ALWAYS fill the full available vertical space.** No dynamic height based on web content.

- `heightCap` for single-link bubbles = distance from bottom of status bar to top of input bar, minus flow padding.
- The bubble ALWAYS extends to this full height, regardless of whether the web content is shorter.
- The web view inside fills the bubble height minus its top/bottom padding (same inner layout rule — just taller because the bubble is taller).
- This is a **fixed height** — no resize, no shrink-to-fit, no content-dependent height calculation.

**Motivation:** Stop layout flapping and jitter caused by web preview bubbles resizing as content loads/changes. A fixed-size viewport eliminates the feedback loop between web content height changes and flow layout invalidation.

**This rule applies ONLY to single-link (web preview) bubbles.** All other bubble types retain their existing height cap behavior (design-system or screen-aware cap with truncation + "show more").

### Outer scroll decision policy

The decision is centralized and deterministic:

- `outerScrollEnabled = shouldAllowOuterScroll(plan) && contentHeight > heightCap`.
- `outerScrollViewportHeight = max(heightCap - chromeHeight, metrics.minScrollViewportHeight ?? 44)`.

Definition:
- `chromeHeight` is the vertical space consumed by non-scrollable bubble chrome (header row, vertical padding, failure badge area when present). The measurer computes it explicitly from metrics/configuration so the outer scroll viewport height is deterministic and shared.
- Concrete formula (conceptual): `chromeHeight = headerRowHeight + verticalPadding * 2 + (failureBadgeHeight if present else 0)`.

`shouldAllowOuterScroll(plan)` encodes the existing design intent (long + non-media, text+linkPreview, etc.) but is evaluated once in measurement, not re-derived in the view.

## Unified Measurement Strategy

### One measurer, two sources of truth

We stop having "offscreen sizing logic" vs "live cell measuring" as two separate algorithms.

- Offscreen measurement (initial layout): run measurer with the same plan, using "estimated sizes" for async components.
- Live measurement (after async updates): rerun measurer with updated subcomponent measurements (e.g. link preview final height), producing a new `BubbleMeasurement` for the same key (or a bumped key version).

### Link preview measurement (first-class)

Replace the current special-case "if link preview and truncation override exists, return cap height immediately".

New behavior:
- Link preview contributes a measured height like any other component.
- If link preview has no final height yet, it contributes an **estimated height** (skeleton) bounded by `heightCap`.
- When the live `LinkPreviewView` reports a final height change, we:
  - store it in a `LinkPreviewMeasurementCache` keyed by `(url, width, metricsFingerprint)`
  - invalidate/recompute the bubble measurement for affected message id

This ensures:
- Short link previews produce short cells immediately (no forced cap-height).
- Tall link previews participate in outer scrolling correctly (no cap bypass).

### Web preview frame height (invariant) — UPDATED 2026-02-12

The web preview (WKWebView / `LinkPreviewView`) is a **fixed-size viewport**, not an auto-expanding container. It has its own internal scroll for page content.

**For single-link bubbles:** The bubble is ALWAYS at full available height (see "Single-link bubble height rule" above). The web preview fills the bubble height minus standard bubble padding (top + bottom). It never shrinks, even if the web content is shorter than the viewport. Short web content simply has empty space below it within the fixed viewport.

**Max web preview height** = `heightCap` − standard bubble padding (top + bottom).

- The preview is ALWAYS at this max height for single-link bubbles. No content-dependent sizing.
- If the rendered page is taller, the page scrolls **inside** the preview (internal WKWebView scroll).
- If the rendered page is shorter, the preview remains at max height (fixed viewport).

**Interaction with other content (non-single-link bubbles only):**

For messages with text AND a link preview (not single-link), text and other content above/below the web preview are additive to total content height.

- If text + preview + padding ≤ `heightCap` → bubble is shorter than max (sizes to content).
- If text + preview + padding > `heightCap` → bubble is at max height, outer scroll enables, user scrolls through text + preview together.

**Example (single-link):** `heightCap` = 600pt (full available space), padding = 16pt top + 16pt bottom.
- Web preview height = 600 − 32 = 568pt. Always. Regardless of page content height.

### Estimated -> Final State Machine (Required)

Async subcomponents (link preview) follow an explicit lifecycle so updates cannot race or stick.

States:
1. `estimated`: not all async subcomponent sizes are final. Cached as `BubbleMeasurement(isFinal=false)`.
2. `final`: all required async sizes are final. Cached as `BubbleMeasurement(isFinal=true)`.

Transitions:
1. Initial layout: compute plan -> measure with estimated link preview height -> cache `isFinal=false`.
2. Link preview height callback (live view):
   - write `(url, width, metricsFingerprint) -> finalHeight` to `LinkPreviewMeasurementCache`
   - enqueue the message id into a coalescing "needs remeasure" queue (main thread). Repeated callbacks for the same message id coalesce.
   - on the next runloop pass (debounced handler): bump `linkPreviewStateVersion` if the effective link preview height for this message/environment changed (monotonic), invalidate the bubble measurement cache entry for that message/environment, then request a layout update.
   - if the cell is visible, use `performBatchUpdates { reconfigureItems([indexPath]) }`; otherwise `invalidateLayout` is sufficient.
   - if a batch update is already in flight, defer the reconfigure until batch completion, and verify the index path still maps to the same message id (cell recycling safety).
3. Next sizing/configure pass recomputes measurement, now using final link preview height, producing `isFinal=true`. If final height is smaller than the estimate, the cell is allowed to shrink.

## Caching and Invalidation

### Cache keys

Introduce a single cache map from `BubbleCacheKey -> BubbleMeasurement`.

`BubbleCacheKey` must include:
- `messageId`
- `presentationFingerprint` (existing)
- `envFingerprint` (container width/height + metrics hash + platform clamp mode)
- `linkPreviewStateVersion: Int` (non-optional; `0` means "estimated/no final link preview height", `>= 1` means "final link preview height known")

Cache key invariant: **if any input that can affect layout changes, the cache key must change.** There is no "optional" key component.

### `linkPreviewStateVersion` Semantics (Required)

- `linkPreviewStateVersion` is **per message instance**, not per URL. Purpose: it forces a recompute of the bubble measurement when the effective link preview height for this message/environment changes (including the initial "estimated -> first real height" transition).
- `LinkPreviewMeasurementCache` is a shared lookup table keyed by `(url, width, metricsFingerprint)`. It provides candidate final heights, but does not itself define bubble cache identity.
- Storage: `MessageFlowCollectionViewController` maintains `linkPreviewStateVersion` in a controller-local `[messageId: Int]` map (or equivalent) keyed by message id + environment. It is not persisted across app launches.
- Default: `linkPreviewStateVersion = 0` when the plan is built and no cached link preview height is available for this message/environment.
- Default: `linkPreviewStateVersion = 1` when the plan is built and a cached link preview height is already available from `LinkPreviewMeasurementCache`.
- Update rule: if `LinkPreviewMeasurementCache` changes the effective height for this message/environment (beyond an epsilon threshold), bump `linkPreviewStateVersion += 1` (monotonic). Repeated callbacks that do not change the effective height must not bump the version (prevents remeasure loops).
- If we later support multiple independent async measurables per message, this becomes a bitset or a composite version.

### Validity rules

A cached measurement is only used when:
- key matches exactly
- measured sizes are within clamp bounds
- measurement is not "known-bad" (e.g. width below min floor pre-clamp, height == 0, NaN)

### No "cached width drives configure" footgun

`configureWidth = sizeCache[id]?.width ?? maxWidth` is replaced by:
- `configureWidth = measurement.measuredBubbleWidth` (already clamped)

### Invalidation events

Explicitly define what invalidates bubble layout:
- message fingerprint changes
- theme metrics / font changes
- container width/height changes (rotation, visionOS clamp changes)
- link preview final height changes

The invalidation mechanism should:
- drop only the affected keys (not full cache wipe unless layout environment changes globally)
- re-measure deterministically from the same plan

### Cache eviction

Define an eviction policy to avoid unbounded growth:
- LRU keyed by `BubbleCacheKey` with a conservative max entry count (exact number TBD; start around 500-1000).
- Evict aggressively on memory warning.

Correctness must not depend on cache retention.

## How the 8 Code Paths Collapse

From the audit's list (A-H), the refactor target is a single path with parameterization.

### A. Typing indicator

Typing indicator is not a message and must not pollute message sizing caches.

Policy:
- Keep it special in the data source.
- It may use the same measurer API shape via a separate `BubbleLayoutKind.typingIndicator` plan.
- It must not participate in the message `bubbleMeasurementCache` (prefer no caching at all).

Goal: no bespoke width/height cap behavior, and no accidental key collisions with message sizing.

### B. Cached size

Becomes: fetch `BubbleMeasurement` by full key; if valid, use it. No partial reuse (no "cached width only").

### C. Wide content

No longer a cascade of special cases; `isWide` is computed in `BubbleLayoutPlan`, which selects:
- `maxWidth = containerWidth`
- `heightCapMode = screenAware`

### D. LinkPreview + truncationHeightOverride immediate cap-height return

Removed entirely.

Replaced by:
- link preview measurable returns estimated height offscreen
- outer scroll / cap logic applies uniformly to computed `contentHeight`

### E. Non-link wide content capping

Handled by the unified "contentHeight vs heightCap" logic; not a separate branch.

### F. Narrow content / design-system cap

Handled by `heightCapMode = designSystem` in plan; not implicit via `nil` override.

### G. Bubble internal outer-scroll enablement

Moved out of the view. The view receives:
- `outerScrollEnabled`
- `outerScrollViewportHeight`

and only applies constraints.

### H. Live-cell measurement

Becomes: rerun the same measurer with updated subcomponent state and update cache atomically.

## What Changes vs What Stays

### Changes

- Introduce `BubbleLayoutPlan` / `BubbleMeasurement` (single source of truth).
- Replace multiple caches (`sizeCache`, `lastMeasuredSizes`) with a single measurement cache keyed by message+environment.
- Remove link preview cap-height bypass.
- Move outer scroll decision out of `MessageBubbleUIKitView`.
- Add explicit min-width floors and reject/avoid caching invalid measurements.

### Stays

- `MessagePresentation` construction (including URL detection) remains as-is for Step 1.
- `MessageFlowRules.sizeClass(for:)` remains the size class source.
- The visual structure of `MessageBubbleUIKitView` stays; only decision-making shifts.

## Implementation Plan (Follow-up Steps After This Spec)

Shipping strategy (required for safety):
- Implement behind a feature flag `BubbleSizingV2`.
- Use a separate cache namespace for V2 so toggling cannot reuse V1 measurements (prevents cache poisoning and enables rollback).
- Feature flag behavior: read once at app launch and cached.
- Feature flag behavior: mid-session toggle is not supported (restart instead).
- Feature flag behavior: if we ever support mid-session toggles, flush both caches and force full layout invalidation.

Steps:
1. Add new structs/types (plan/env/measurement) in a single location owned by `MessageFlowCollectionViewController`.
2. Move wide/maxWidth/heightCap computations into `BubbleLayoutPlan`.
3. Implement unified measurer that produces `BubbleMeasurement` and computes outer scroll decision.
4. Update `sizeForItem(at:)` to use the unified V2 cache+measurer when the flag is on (V1 untouched).
5. Update `cell.configure(...)` and `MessageBubbleUIKitView.configure(...)` to consume the plan/measurement and stop recomputing scroll decisions (V2 path only).
6. Introduce `LinkPreviewMeasurementCache` and wire `LinkPreviewView.onHeightChange` to update it, bump `linkPreviewStateVersion`, and invalidate/re-measure.
7. Add targeted regression tests / snapshot tests (or a deterministic sizing harness) for:
   - single URL with and without `.linkPreview` part
   - text + link preview (short + long)
   - wide media + tall content (outer scroll)
   - medium size class min width floor
   - cache invalidation on width/metrics/orientation change
   - link preview estimated -> final shrink (previously forced cap-height)
   - outer-scroll gate consistency (no view/controller desync)
   - link preview height race (two `onHeightChange` calls before layout settles)
   - visionOS width clamp behavior (env fingerprint correctness)
   - cache eviction correctness (remeasure after eviction is correct)
   - batch update interleaving (link preview callback during `performBatchUpdates`)

## Open Questions / Decisions Needed

- Exact formula for `minWidth` floors (per size class) derived from theme metrics so they can be tuned without code changes.
- Whether link preview sizing should be cached per URL across messages or only per message instance.
- The epsilon threshold for "effective height changed" when deciding whether to bump `linkPreviewStateVersion` (to avoid jitter/looping).

Resolved in this spec: representing "estimated vs final" is not optional. We use `linkPreviewStateVersion` in the bubble cache key.
