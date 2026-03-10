# Surf Ace Tab Spec — Summary

**Date:** 2026-03-04  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`

---

## What Was Added

### §2a Concepts
- New `Tab` definition: a rendering slot within a pane, owned by a single CLU session. Auto-created on first push, persists until cleared/closed, one per session per pane.

### §3.1.1 — Renamed and expanded
- Heading updated to "Multi-Window, Multi-Pane, and Multi-Tab Topology".
- Added explicit topology hierarchy: Surface → Window → Pane → Tab.
- Added **Tab rules** block (11 rules covering auto-creation, session ownership, one-per-session-per-pane, implicit routing by sessionId, tabId echo in push response, annotation scoping, user tab switching, tab.close, max tabs, tabId format).
- Added phasing note: tab support is Phase 1 scope, before annotation work.

### §2.3 Delivery Phasing
- Phase 1 checklist updated to include tab model (item 4), and two new Phase 1 done-checklist entries (items 9 and 10) covering tab auto-creation, buffer scoping, and tool behaviors.

### §6.1.1 — Renamed and expanded
- Heading renamed to "Pane and Tab Lifecycle Operations".
- Added `tab.list` operation: lists all tabs in a pane with tabId, sessionId, label, activeContentId, contentType, focused.
- Added `tab.close` operation: closes a tab, discards content and annotation state, returns closedFramesDiscarded count.
- Added three always-on tab lifecycle events: `event.tab_created`, `event.tab_removed`, `event.tab_focused`.

### §6.2 Content Set
- Added rule that `sessionId` is required on `content.set` requests; surface routes to the correct tab using it.
- Added that the response echoes `tabId` (the tab created or updated).

### §7.3 Event Audit Table
- Added rows for `event.tab_created`, `event.tab_removed`, `event.tab_focused` — all classified as "Lifecycle — not profile-gated / Always".

### §10 JSON Schema
- Added `TabId` type to `$defs` (opaque string, 1–128 chars, surface-assigned, derived from sessionId).
- Added `TabListRequest` and `TabListResponse` schemas.
- Added `TabCloseRequest` and `TabCloseResponse` schemas.
- Added `TabCreatedEvent`, `TabRemovedEvent`, `TabFocusedEvent` schemas.
- Added `sessionId` field (required) to `ContentSetRequest` payload.
- Added `tabId` field to `MutationAckResponse` payload (present on content.set, null on append/patch/clear).
- Added `event.tab_created`, `event.tab_removed`, `event.tab_focused` to `EventType` enum.
- Added `tab.list`, `tab.close` to `ErrorResponse.op` enum.
- Added all new message types to root `oneOf` array.

### §13.2 Dual-Channel Annotation Buffer
- Added buffer scoping paragraph: buffer key is `(surfaceId, paneId, tabId)`. Both annotation channels and all registers are tab-scoped.
- Made explicit that `surf_ace_read` is session-keyed at the CLU tool layer — tabId is derived from sessionId, no API change needed, existing callers are unaffected.

### §14.3 CLU Tools
- Updated `surf_ace_push` returns block to include `tabId` with explanation that CLU doesn't need to reference it on subsequent pushes.
- Updated `surf_ace_read` description to explicitly state it is tab-scoped and reads the calling session's tab automatically.

### §4.2 Single-Connection Rule
- Replaced "Open design question: multi-session CLU contention" note with a resolved statement pointing to §A.13 and §3.1.1.

### §A.13 Multi-Session CLU Contention
- Status changed from **Unresolved** to **Resolved**.
- Resolution statement added: "Resolved 2026-03-04. Tab model adopted as the v1 resolution. Each CLU session automatically owns a tab in each pane it pushes to. Contention is eliminated by design — sessions never overwrite each other's content."
- Cross-reference added to all relevant sections (§3.1.1, §6.1.1, §6.2, §13.2).

---

## What Was Changed (existing content modified)

- §3.1.1 heading (renamed, not new section)
- §6.1.1 heading (renamed)
- §6.2 Content Set rules (added sessionId requirement and tabId echo)
- §7.3 Event Audit Table (extended with 3 rows)
- §10 JSON Schema — `ContentSetRequest` payload (added `sessionId` to required + properties), `MutationAckResponse` payload (added `tabId`), `EventType` enum (3 new values), `ErrorResponse.op` enum (2 new values), root `oneOf` (7 new refs)
- §A.13 (resolved)
- §4.2 inline note (resolved)

---

## Ambiguities Resolved During Spec Work

1. **`sessionId` on append/patch/clear:** The spec says `sessionId` is required on `content.set`. Append, patch, and clear are follow-on ops on existing content and don't do tab routing — they don't need `sessionId`. Spec left these unchanged. `tabId` in `MutationAckResponse` is `null` for non-set mutations; this was made explicit in the schema description.

2. **Tab lifecycle events: always-on or profile-gated?** Flynn's rules say the user can switch tabs and the surface fires events — these are structural lifecycle signals like pane events, not user interaction data. Classified as always-on (not profile-gated), consistent with pane lifecycle events. They do NOT appear in `pair.response.eventConfig.activeEvents`.

3. **`paneId` on `tab.list`/`tab.close` requests:** Flynn's design says tabs are within a pane, so paneId is required to identify which pane's tabs to list/close. Confirmed: both operations require `paneId`.

4. **TabId schema format:** Flynn said "derived from sessionId (e.g. a stable short hash or the full sessionId string)". The wire schema defines `TabId` as an opaque string (surface-defined format, 1–128 chars) rather than constraining it to a specific pattern. The description documents the derivation intent without over-constraining the surface implementation.

5. **`surf_ace_read` paneId param:** The task says `surf_ace_read` is "already session-keyed" with no API change at the CLU tool layer. The current tool signature takes only `fingerprint`. This was left unchanged; the tab-scoping description makes the implicit session-keyed routing explicit in prose without adding a `tabId` or `paneId` param. (The existing pane-targeting question for read tools is a separate Phase 1 item already noted in §14.3.)

6. **`event.tab_focused` payload:** The wire event needs enough to identify which surface/pane/tab changed. Payload is `{ surfaceId, paneId, tabId }` — consistent with other pane/surface lifecycle event shapes.
