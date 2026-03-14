# Staged Stream Materialization — Non-Obvious Details

## Why staged apply — what the original design assumed
Full-history apply kept chat semantics simple but produced 1.4–2.7s main-thread stalls on iPhone for 500-message streams. The original design assumed the cost was acceptable; measurements proved it blocks gesture recognition and dictation. Staged apply trades complexity for correctness under real device conditions.

## Tail window size rationale: N=50, not 100
Linear approximation: 500 items → 1.4–2.7s. 50 items → ~140–270ms. 100 items → ~280–540ms (still too visible for first paint). The choice of 50 is derived from measurement, not arbitrary. Changing this threshold should re-run the measurement.

## New messages during expansion are queued in the serialized seam — not dropped
New messages that arrive during tail→full expansion do NOT bypass the staged seam. They are enqueued in the same serialized apply seam. The full-stage snapshot is built from the **authoritative message source at execution time**, so it includes messages that arrived during tail stage. This prevents dropped or duplicated IDs.

## Unread marker outside tail window: never auto-clear just because marker cell isn't materialized
Unread metadata stays in logical state even if the marker cell is outside the tail window. The badge/count shows correctly without requiring marker cell presence. Auto-clearing unread because the marker isn't visible yet is wrong — it must wait for full-stage expansion.

## Anchor compensation mechanism for tail→full expansion
Before tail→full apply: capture anchor as `(anchorMessageId, anchorFrameMinY, contentOffsetY)` for the top fully-visible non-typing item. After layout, resolve new anchor frame and set `contentOffset.y += (newMinY - oldMinY)` (clamped to content bounds). This is explicit contentOffset compensation, not heuristic scrolling. Skipping this produces visible jump on expansion.

## `advanceMaterialization(sessionKey:event:)` is the single write seam — no direct external mutation
All staged-state transitions (`materializationStageBySessionKey`, `windowBoundsBySessionKey`, `expansionLifecycleBySessionKey`) go through this one seam. No external direct writes. Stage transitions and snapshot applies are serialized on MainActor through a single apply queue/dispatcher. Violating this ordering causes "UICollectionView consistency" assertion crashes.

## Staged materialization applies only for first activation of large unvisited streams
Revisits remain on the existing path. The staged path is gated on `messageCount > 50` AND first activation. Adding staged logic to revisit paths introduces unnecessary complexity and risks regressions in the smooth revisit flow.
