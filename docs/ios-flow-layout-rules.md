# Flow layout rules & implementation decisions

## Layout stability rules (agreed)
- Bubble dimensions must be a deterministic function of **message content** + **pre-measured screen width**.
- The only width-dependent rule is the comfortable reading width cap; once computed for the current device width, it should remain stable.
- Bubbles should not change size or invalidate their layout rect after initial layout unless **device width changes** (e.g., rotation).
- Rotation is the only expected trigger for recomputing widths; this should be a one-way recalculation to a new stable size.
- As long as the device width stays constant, the layout must remain stable (no reflow/invalidation caused by internal view state).

## Invariants
- For a fixed device width, each message resolves to a **single stable size** (width, height).
- Width/height changes are allowed **only** for content changes or device width changes; internal measurement jitter must be **debounced**.
- SwiftUI may perform multiple internal passes, but the **external layout must converge**.
- Collection view layout is the only owner of placement; SwiftUI does not reposition items.
- Horizontal placement honors the flow rules (row wrapping); vertical gaps come only from row spacing.
- Bubble visual bounds **must match** the layout bounds (no invisible trailing space).
- Padding is **only** the standard flow gap, applied evenly horizontally and vertically.
- Overlaps are never allowed.

## Current implementation decisions
- Use `UICollectionViewFlowLayout` with **delegate sizing**:
  - `estimatedItemSize = .zero` (self-sizing disabled).
  - `collectionView(_:layout:sizeForItemAt:)` returns a cached size per message.
- Size measurement pipeline (UIKit-native):
  - `sizeForItem` uses `MessageBubbleUIKitView` for sizing via `systemLayoutSizeFitting`.
  - Text measurement uses `NSAttributedString.boundingRect` for single source of truth.
  - Line balancing for medium messages uses UIKit text measurement (not SwiftUI).
  - The measured size is clamped to max width, snapped to pixel, and cached per message.
- Debounce measurement-driven invalidations:
  - Cells re-measure in `layoutSubviews` and only invalidate when deltas exceed ~1pt.
  - Mismatch reports update the cache and call `invalidateLayout`.
- Width changes (rotation / bounds changes) clear cached sizes by re-running `updateLayout()` and reconfiguring items.

## Open items / to verify
- Ensure message sizing uses only content + width (no post-layout state changes).
- Confirm that link preview / image loading does not change measured height after initial size (if it does, consider fixed-height placeholders or precomputed sizing).
- Recheck width computation when device rotates; this is the sole allowed cause of size changes.

---

## Appendix: Preserved Notes

### From: above-bar-gap-analysis.md

**Above-bar gap root cause:**
The visible gap between the last bubble's bottom edge and the input bar's top edge is determined by **two independent layout systems** that must agree:
1. **Collection view content inset** (`collectionView.contentInset.bottom = listBottomInset`)
2. **Auto Layout constraints** (`KeyboardPinnedContainer` against `keyboardLayoutGuide`)

The gap formula (`ChatView.swift`):
```swift
let listBottomInset = keyboardInset + belowBarGap + resolvedInputHeight
    + metrics.flowGap - metrics.containerPadding
```

**Race condition:** All four inputs (`keyboardHeight`, `inputBarHeight`, `geometry.safeAreaInsets.bottom`, `horizontalSizeClass`) start at zero/default and update asynchronously:
- `keyboardHeight`: updated via `KeyboardLayoutGuideObserverView` notification callback
- `inputBarHeight`: updated via `DispatchQueue.main.async` from `KeyboardPinnedContainer.Coordinator`
- `safeAreaInsets.bottom`: from SwiftUI `GeometryProxy`, may be 0 on first frame
- `horizontalSizeClass`: from trait collection

The gap is wrong on first load because the two layout systems compute from different snapshots of these shared inputs. It self-corrects after any interaction that triggers a layout pass from both systems.
