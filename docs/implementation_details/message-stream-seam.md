# Message Stream Seam — Non-Obvious Details

## Why compiler-error-first migration order is mandatory
The spec mandates deleting/marking unavailable all legacy direct-write APIs **before** routing them through the seam — not after. Skipping this order means you build the migration list by guessing, not by reading compile errors. Ad-hoc direct writes left in callers silently bypass the seam and re-introduce the race conditions the spec exists to fix.

## Cache is gap-fill only — not an update source
Cache-restored messages may **only insert IDs absent from current session set**. Cache can never delete, reorder, or overwrite an existing ID. This means cache restore that arrives after live replay must no-op for any message ID already present. Violating this silently discards in-progress streaming updates.

## Retry appends at tail — NOT in-place
Retry of a failed message uses a **new client ID** and appends at the end. It does not re-use the original bubble position or ID. Code that expects the retried message to appear at the original location is wrong and will never find it.

## Streaming update-in-place vs initial insert
Repeated server events for the same streaming message ID must update in-place, not append. This must be tested separately from initial insert — the code paths look similar but have different outcomes if the ID collision is mishandled.

## Logout clear atomicity — what "atomic" means here
`clearAllForLogout` must atomically reset: all per-session message collections, active session selection state (`engineActiveSessionKey` + UI key), reconnect cursor state (global and per-session), pending local message tracking, and message failure tracking. Partial clears leave stale cross-references that surface as ghost messages or wrong-stream state on next login.

## Provisioning gate — no send before provisioned
`canSend` requires both connected transport **and** active session key in `provisionedSessionKeys`. The input composer must stay ghosted until provisioning readiness. No optimistic placeholder creation before this gate. Violating this produces placeholders that can never be replaced, because the seam won't accept them into a provisioned session.

## `removeSession` vs `clearSessionMessages` are behaviorally distinct
`clearSessionMessages` removes messages but keeps the session key in stream/session metadata. `removeSession` removes everything including cursor state. Using the wrong one leaves orphaned cursor state (for clear-only) or destroys metadata needed for future stream enumeration (for remove when clear was intended).

## `replaceSession` is NOT part of the public seam
This is an internal seam operation only. Callers must not submit full-session replacements. Callers express intent via `upsert/remove/clear/logout` operations; the seam decides merge strategy internally.
