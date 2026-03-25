# Scroll-To-Bottom Invariants — Non-Obvious Details

## "At bottom" threshold must be shared across SBB, auto-scroll, and restore — any split is a spec violation
SBB hide/show logic, auto-scroll eligibility for appended messages, and restore fallback-to-bottom checks MUST use one shared helper and threshold constant. Any split (different constants or interpretations at these three sites) causes inconsistent behavior: SBB hides but auto-scroll doesn't fire, or vice versa. This is a non-obvious cross-cutting constraint.

## Auto-scroll while user is actively interacting: deferred until drag ends
When at bottom, receiving a new message auto-scrolls — UNLESS `wasUserInteracting` (finger on screen/dragging). In that case, auto-scroll is deferred until interaction ends. `wasAtBottomBeforeUpdate` must be captured at the start of `update(...)` before snapshot apply. Capturing it after the snapshot apply loses the pre-update state.

## Initial load / backfill / stream reset must NOT generate unread count
Only messages that appear after a previously-known last message ID (that is still present in the new list) count as unread. This guards against counting the entire message history as unread on first visit or after stream switch. The "previously-known ID is still present" check prevents backfill/reset scenarios from incorrectly triggering the unread path.

## `firstUnreadMessageId` is set ONCE — kept stable until cleared
On first unread, `firstUnreadMessageId` is captured and held stable even as more unread messages arrive. It is cleared only when user returns to bottom, taps in unread mode, OR the bubble's top edge crosses the viewport vertical center. Do not overwrite `firstUnreadMessageId` as each new unread arrives.

## Crossing the viewport center while scrolled up: the bubble flashes AND unread clears
When the user manually scrolls and the top edge of `firstUnreadMessageId` crosses the viewport vertical center, two things happen simultaneously: the bubble flashes/highlights, and the unread state clears. The flash is the signal to the user that "this was the boundary." Clearing without flashing, or flashing without clearing, breaks the UX contract.

## Positioning: indicator is anchored to the input bar / keyboard-pinned container
The indicator must track keyboard show/hide and input bar movement. It must NOT float mid-screen after keyboard dismiss. Implementation that anchors to the collection view or screen coordinates will drift during keyboard transitions.

## Typing indicator insertions must NOT count as unread
Typing indicator cells are ephemeral system cells. They must be excluded from the "newly appended messages" count. Including them would increment the unread badge on every typing indicator insertion.
