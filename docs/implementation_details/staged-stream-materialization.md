# Bounded Stream Materialization — Non-Obvious Details

## Why the collection view owns only a window

An exact 500-message switch profile showed the main thread blocked inside diffable apply while `MessageFlowLayout.prepare` synchronously requested exact Bubble Sizing V2 geometry for every snapshot item. The view model therefore remains authoritative for the full transcript, while the collection controller materializes a fixed projection window: 50 normal messages or 100 Show Only User Messages entries.

## There is no tail-to-full promotion

The old first-visit tail snapshot promoted the complete transcript on the next main runloop and revisits skipped staging entirely. Both paths reintroduced transcript-sized synchronous layout. A bounded window is now permanent: first visits start at the tail, revisits retain their projection-relative location, and settled physical-edge navigation shifts by half a window with overlap.

## Projection indexes are built at the mutation seam

`ChatViewModel.applyMessagesWrite` maintains transcript ID lookup and ordered user-message transcript indexes. Search captures the Sendable indexed input, computes matches off MainActor, and publishes only for the matching transcript revision. A switch consumes an O(1) cached projection plus an O(W) slice; it never builds transcript-wide maps, fingerprints, or filters.

## Unread truth is logical

An unread message outside the active window remains unread. Missing a cell is expected while its logical ID still exists in the projection index. Navigation moves the bounded window to the target before center/flash behavior runs.

## Window shifts preserve geometry

All window bounds mutate through `advanceMaterialization(sessionKey:event:)`. A settled edge shift captures the existing fully visible viewport anchor, applies one bounded snapshot through the serialized diffable seam, and then uses the existing generation/session-checked anchor compensation. Shifts do not run while dragging, tracking, or decelerating.

## Auxiliary items are bounded too

Dates are derived only from the window. Web bubbles are selected only for window parents plus parentless items and are capped to the active message-window count. The footer appears only at the active projection tail. Including a typing row, the snapshot invariant is `snapshot.count <= 3W + 2`.

## Bubble sizing and activation completion stay separate

Bubble Sizing V2 remains exact for every materialized item, including T1377 settled HTML/link-preview convergence. Window shifts, search publication, web refresh, and later remeasurement do not attempt engine-activation completion. The only completion attempts remain the unchanged-identity active fast return and the first changed activation snapshot completion; the view model self-gates exactly once.
