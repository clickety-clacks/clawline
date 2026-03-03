# T113 T104 Retro — Why SBB/Scroll Regressed After Per-Stream Migration
Date: 2026-02-25
Branch: `per-stream-state`

## Summary
Two user-visible bugs were linked:
1. Stream sometimes reopens near top (far from where Flynn left it).
2. SBB hidden on entry to a scrolled-up stream until additional user scroll activity.

These are not random. They come from specific ordering/emit gaps in the current implementation.

## Root Cause (confirmed, not guess)

### A) Stale snapshot reuse on fallback caused "opens near top"
Per-stream restore relies on persisted snapshot + `lastKnownScrollSnapshot` fallback when live geometry is unavailable at switch-time flush.

Problem:
- Multiple programmatic scroll paths use `setContentOffset(..., animated: false)`.
- Non-animated programmatic scroll does **not** trigger `scrollViewDidEndScrollingAnimation`.
- The code previously refreshed `lastKnownScrollSnapshot` mainly on user scroll/deceleration paths.
- Result: `lastKnownScrollSnapshot` could remain stale (older near-top distance).
- If switch-time flush hits geometry-unavailable path, fallback writes stale snapshot, and next reopen restores to stale near-top position.

This explains intermittent behavior: only repros when switch flush cannot use live geometry.

### B) SBB state existed per-stream, but switch entry did not guarantee event emission
`prepareIncomingStateOnSwitch` sets per-stream `sbbState` correctly from persisted state.

Problem:
- UI SBB visibility in `ChatView` is driven by `.isAtBottomChanged` scroll events.
- On stream switch entry, event emission was not guaranteed immediately after key/state selection.
- If no subsequent scroll/layout callback produced an emit, UI could keep stale hidden state until user interaction.

So T104's data ownership change was correct, but event propagation on switch entry was incomplete.

## Classification
- Architecture concept (per-stream SBB ownership): correct.
- Implementation: incomplete in two places (snapshot refresh coverage + switch-entry event emission).
- This is primarily an implementation conformance gap, not proof that the architecture is wrong.

## Why T104 looked "not fixed"
Because visibility is not just state ownership; it is ownership **plus deterministic publication** to the UI event channel. We fixed ownership, but publication still depended on later callbacks.

## Fixes applied
1. Added immediate `emitHideIndicatorIfChanged(force: true)` on stream-context seam key selection paths in `runStreamContextSwitchSeam`.
2. Added `lastKnownScrollSnapshot` refresh after non-animated programmatic offset changes, including:
   - restore attempt apply path
   - restore fallback-to-bottom path
   - non-animated `scrollToBottom`
   - non-animated `scrollToMessageCentered`
   - `adjustContentOffsetForBottomInsetChange`

These changes ensure:
- switch-time fallback has fresher per-stream snapshot data,
- SBB visibility is published immediately on stream entry.

## Honest assessment
I am not guessing on these two bugs.
- The failure mechanisms are directly traceable in code paths and callback semantics.
- The fixes target those exact gaps rather than broad defensive changes.
