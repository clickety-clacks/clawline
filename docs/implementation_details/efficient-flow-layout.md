# Efficient Flow Layout — Non-Obvious Details

## Why optimization work cannot start before mutation seam is consolidated (hard gate)
All six separate size caches must be routed through the seam before ANY optimization work (y-shift path, etc.) begins. The spec is explicit: "No optimization work may begin until the mutation seam is fully consolidated and verified." Skipping ahead recreates the split-mutation problem that causes defensive full-rebuild invalidation. The seam steps 1-3 gate step 4.

## Bottom inset changes during dictation/typing: NO immediate layout recalc
The action for bottom inset change is **no immediate layout recalculation**. Do not invalidate layout, do not reconfigure bubbles, do not recompute height caps during the change. This is counterintuitive — you'd expect inset changes to update heights. The rationale: the change is ephemeral and high-frequency, producing ~950ms stalls that break interaction. Deferred recalc fires when scrolling stops and viewport settles.

## Dark mode toggle: ZERO sizing or layout work (colors only)
Current code clears caches and forces reconfigure on dark mode change. This is overly aggressive. Dark mode changes colors, not dimensions. No bubble needs remeasuring on dark mode toggle. Adding layout invalidation here produces unnecessary full rebuilds.

## Session switch is NOT a geometry event — no layout rebuild
A session switch loads different message content via diffable snapshot. It is a data change, not a geometry or sizing event. The current code triggers full rebuild on session switch; this is wrong. New messages get measured as they appear; existing bubbles retain their cached heights.

## Width stability invariant — the y-shift optimization depends on it
Bubble widths are stable after initial measurement. `.short` bubbles (≤3 words) use content-fit width but cannot contain link previews or media. The only async width updates are from link preview loads, which only occur in already-full-width large bubbles. Therefore no bubble changes width after initial measurement. If any new bubble type introduces async width changes, the y-shift optimization is invalid for those bubbles.

## Single-message append must be a fast path — no full rebuild
A new message arriving at the end of the list must: measure the new bubble once, append its frame, update content size, touch NO existing bubbles. This is the most frequent mutation in normal use. If this path triggers full rebuild, it's a performance regression on every incoming message.

## `handleBottomInsetHeightCapChange()` targets are incomplete
The current targeted handler only reconfigures single-link-preview bubbles, but still calls `flowLayout.invalidateLayout()` which triggers a global rebuild. Additionally, it misses other inset-sensitive types: tables, images, galleries, terminal sessions (anything with `prefersScreenAwareTruncationHeight`). The fix defers all such recalculation to viewport-settle time instead of trying to be targeted while still rebuilding globally.

## Multiple simultaneous height changes: sort and single forward pass
When multiple items change height in one pass (e.g., batch of link previews loading), sort changed indices ascending and process in a single forward pass, accumulating deltas. Each item's shift includes the accumulated delta from all preceding changes. Repeated tail scans for each item would be O(n²).

## Capped bubble recalculation timing: visible AND scrolling stopped
Capped bubbles (link previews, tables, images, galleries, terminal sessions) only need height recalculation when BOTH conditions hold: (1) the bubble is visible on screen, AND (2) scrolling has stopped. No recalculation while scrolling, offscreen, or while input bar is animating.
