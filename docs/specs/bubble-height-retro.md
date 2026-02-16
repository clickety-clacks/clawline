# Bubble Height Retro (T081)

Date: 2026-02-15  
Owner: Codex (implementation agent)

## Summary

Flynn reported that single-link web preview bubbles sometimes render at a legacy shorter height on first render, then correct to full-height after scrolling away/back.

Root cause was architectural, not just numeric:

1. Height policy was implemented in multiple places (V2 plan, V2 measurement/cache, UIKit configure path, and legacy V1 fallback path).
2. The V2 measurement cache key did not include enough layout semantics (single-link/full-height mode, header visibility, failure badge state), so stale measurements could survive across shape-equivalent message fingerprints.
3. Bottom-inset changes (which directly change single-link height cap) did not force reconfigure of visible single-link cells, so initial and relayout paths could diverge until reuse/reconfigure happened later.

## 1) All code paths that determine single-link bubble height

### Active (BubbleSizingV2 enabled)

1. `MessageFlowCollectionView.bubbleSizingV2Plan(...)`
Path: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- Determines `plan.isSingleLinkPreview`.
- For single-link, sets `plan.heightCap = effectiveSingleLinkPreviewHeightCap(...)`.

2. `MessageFlowCollectionView.bubbleSizingV2Measure(...)`
Path: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- For single-link, hard-sets `cellHeight = plan.heightCap (+ badge)`.
- This is the functional "single-link must fill available height" invariant.

3. `MessageFlowCollectionView.bubbleSizingV2LayoutState(...)` cache path
Path: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- Returns cached measurement when cache key matches.
- If key is underspecified, stale non-invariant measurements can leak into initial layout.

4. `MessageBubbleUIKitView.configure(...)` viewport sizing
Path: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift`
- Uses V2 state (`linkPreviewMaxHeight`, `outerScrollViewportHeight`) to size preview viewport and wrapper constraints.
- This applies what flow sizing decided; it does not own the cap policy.

### Legacy fallback (BubbleSizingV2 disabled)

5. `truncationHeightOverrideForMessageBubble(...)` + `measureUIKitBubbleSize(...)` + `applyMeasuredSize(...)`
Path: `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- Single-link height can still be forced via truncation override.
- This is a separate implementation of the same rule (architectural duplication).

## 2) Initial layout vs re-layout divergence

### Initial layout path

`sizeForItem -> bubbleSizingV2LayoutState (cache or measure) -> measuredCellSize`

Potential divergence conditions previously:
- Cache key collisions across different layout semantics (single-link/full-height policy not explicitly encoded).
- Inset-driven cap changes did not reconfigure visible cells, so on-screen bubble constraints could stay on prior configuration even after list inset changed.

### Re-layout path

Triggered by cell reuse/reconfigure (`scroll away/back`, link preview height callbacks, explicit reconfigure paths):
- Re-enters `configureDataSource` and applies fresh `bubbleSizingV2` state to cell constraints.
- Result appears "fixed" after reuse/reconfigure.

## 3) Encapsulation assessment

Current state before fix:
- Not a strict single source of truth.
- Policy duplicated across V2 and V1.
- Cache identity concerns lived outside policy concerns.
- Inset changes influenced cap policy but were not consistently hooked to both sizing and visible-cell reconfigure.

So the architecture had competing paths and weak encapsulation boundaries for a critical invariant.

## 4) Implemented fix

### A) Strengthened V2 cache identity (eliminate stale-policy reuse)

Files:
- `ios/Clawline/Clawline/Views/Chat/BubbleSizingV2.swift`
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`

Changes:
- Added `layoutFingerprint` to `BubbleSizingV2.CacheKey`.
- `layoutFingerprint` now hashes layout-defining semantics:
  - single-link/full-height plan fields (`sizeClass`, `isSingleLinkPreview`, `maxWidth`, `heightCap`, etc.)
  - `showsHeader`
  - failure badge presence

Effect:
- Cache reuse now tracks policy shape, not just message+environment+link-version.

### B) Inset-change reconfigure for single-link bubbles (sync initial and live paths)

File:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`

Changes:
- `setBottomInset(...)` now calls `handleBottomInsetHeightCapChange(...)`.
- On meaningful bottom inset change:
  - identifies single-link messages,
  - invalidates their sizing cache entries,
  - schedules item reconfigure,
  - invalidates flow layout.

Effect:
- When available-height inputs change, both item sizing and live cell configuration update together.
- Removes "initial short, corrected only after scroll/reuse" behavior.

## 5) Refactor recommendation (prevent recurrence)

Yes, a focused refactor is warranted:

1. Introduce a dedicated `BubbleHeightPolicy` type
- Inputs: presentation traits, environment, chrome flags.
- Outputs: authoritative `heightCap`, viewport cap, and invariant markers.

2. Move both V2 and V1 single-link decisions behind policy APIs
- V1 should call policy instead of duplicating rule math.
- Long-term: retire V1 single-link path once V2 is universally enabled.

3. Make cache-key construction policy-owned
- Prevents future drift between "what influences size" and "what keys measurement reuse".

4. Add invariant assertions/tests
- Example: if `plan.isSingleLinkPreview`, measured cell height must equal cap (+ badge).
- Add inset-transition tests that verify visible-cell reconfigure path, not just offscreen measure.

## Deliverables completed

1. Code fix for T081 (cache identity + inset-change reconfigure).
2. Architecture retro document (`docs/specs/bubble-height-retro.md`).
