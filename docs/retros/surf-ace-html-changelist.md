# Surf Ace HTML Overview Document — Change Log

Sections changed since Pass 15 freeze.
Covers: cleanup pass, pass 16 nits, pass 17 fixes, tab spec addition, pass 18/19 fixes.

Use this to update the section overview HTML document.

---

## Change Table

```
SECTION   | STATUS  | SUMMARY
----------+---------+-----------------------------------------------------------------------
§1        | CHANGED | Major rewrite. Replaced minimal placeholder with complete Purpose and
          |         | Goals section: 7 numbered core goals, Actors block (CLU/Surfaces/Users),
          |         | Architecture Overview with 5 key design decisions. The old §1 had no
          |         | goals enumeration; this is a full new narrative.
----------+---------+-----------------------------------------------------------------------
§2.3      | CHANGED | Delivery Phasing expanded significantly. Phase 1 done checklist now
          |         | has 10 items (was shorter). Items 9 and 10 are new: tab model active
          |         | (content.set auto-creates tab, surf_ace_push returns tabId, tab.list
          |         | and tab.close operable, tab lifecycle events fire) and annotation
          |         | buffer keyed by (surfaceId, paneId, tabId). Phasing note for tab
          |         | support added: tabs ship with Phase 1 topology, before annotation
          |         | work (Phase 2).
----------+---------+-----------------------------------------------------------------------
§2.4      | CHANGED | Dropped "(Flynn-directed)" suffix from section title. Removed git
          |         | branch reference. Text unchanged otherwise.
----------+---------+-----------------------------------------------------------------------
§2a       | NEW     | New "Concepts" section inserted between §2 and §3. Defines all
          |         | key protocol terms: Surface, Endpoint, Provider, Content, Annotations,
          |         | Event, Local buffer, Connection job, Tab. Tab concept is new and
          |         | substantial: describes auto-creation, one-per-session-per-pane rule,
          |         | tabId assignment, CLU routing transparency, and echoing semantics.
----------+---------+-----------------------------------------------------------------------
§3.1.1    | CHANGED | Section renamed to "Multi-Window, Multi-Pane, and Multi-Tab Topology
          |         | (iPad + Electron)". Topology hierarchy extended: Surface → Window →
          |         | Pane → Tab. Phasing note added. Tab rules block added (13 rules):
          |         | auto-creation on first push, one-per-session-per-pane, sessionId
          |         | injection model, tabId echoing, user tab switching, tab.close,
          |         | annotation tab-scoping, sessionId injection MUST NOT accept from wire.
          |         | Rule 13 added: tab switch during active annotation exits annotation
          |         | mode immediately.
----------+---------+-----------------------------------------------------------------------
§4.2      | CHANGED | Added multi-session CLU contention note under Single-Connection Rule:
          |         | "Two CLU sessions pushing to the same surface/pane each own their own
          |         | tab — sessions never overwrite each other." Cross-references §A.13
          |         | and §3.1.1 Tab rules.
----------+---------+-----------------------------------------------------------------------
§6.1.1    | CHANGED | Tab operations added to Pane and Tab Lifecycle Operations. New
          |         | subsections: tab.list (request/response fields, label, focused),
          |         | tab.close (request/response including closedFramesDiscarded), and
          |         | three new always-on tab lifecycle events: event.tab_created,
          |         | event.tab_removed, event.tab_focused. These events are explicitly
          |         | not profile-gated and do not appear in pair.response eventConfig.
----------+---------+-----------------------------------------------------------------------
§6.2      | CHANGED | Content Set prose expanded with sessionId injection rules. New
          |         | normative block added: provider injects sessionId from authenticated
          |         | WS session context; CLU does not pass sessionId explicitly; surface
          |         | MUST NOT accept sessionId from wire payload; sessionId is NOT a wire
          |         | field. Rule 6 updated: successful set returns tabId. Rule 7 added:
          |         | CLU does not need to reference tabId for subsequent pushes.
----------+---------+-----------------------------------------------------------------------
§6.10     | NEW     | New section: Annotation Mode. Defines annotation mode as surface-level
          |         | UX lock (no wire protocol concept). Specifies: scroll disabled, link
          |         | following disabled, drawing enabled. Platform implementations: iPad
          |         | (pencil-contact enters; finger sketching button always visible; Done
          |         | exits) and non-pencil platforms (Annotate button vim-style toggle).
          |         | Tab switch during annotation mode: exits immediately, in-flight
          |         | strokes assigned to active tab, new tab in view-only mode. Explains
          |         | why annotation mode is UX-only (wire protocol does not distinguish).
----------+---------+-----------------------------------------------------------------------
§7.3      | CHANGED | Event Audit table extended with tab lifecycle events:
          |         | event.tab_created, event.tab_removed, event.tab_focused — all marked
          |         | "Lifecycle — not profile-gated", always active, do not appear in
          |         | activeEvents. Rationale column entries added for each.
----------+---------+-----------------------------------------------------------------------
§10       | CHANGED | JSON Schema block updated with:
          |         | (1) TabId type definition added (string, 1–128 chars, surface-assigned,
          |         |     opaque to providers, echoed in push responses).
          |         | (2) EventType enum extended: event.tab_created, event.tab_removed,
          |         |     event.tab_focused added.
          |         | (3) ProfileControlledEventType enum unchanged (tab/pane lifecycle
          |         |     events are always-on, correctly excluded).
          |         | (4) ContentSetRequest payload: tabId optional property added
          |         |     (not in required); sessionId removed (was present, now absent).
          |         | (5) MutationAckResponse payload: tabId added to required array;
          |         |     tabId typed as oneOf [TabId, null]; description clarifies
          |         |     non-null on content.set, null on append/patch/clear.
          |         | (6) TabListRequest, TabListResponse schemas added (full definitions).
          |         | (7) TabCloseRequest, TabCloseResponse schemas added (full definitions).
          |         | (8) TabCreatedEvent, TabRemovedEvent, TabFocusedEvent schemas added.
          |         | (9) Top-level oneOf updated to include all new Tab* types.
----------+---------+-----------------------------------------------------------------------
§12       | CHANGED | Implementation Readiness Checks: tab model checks are implied by
          |         | Phase 1 done checklist in §2.3. No separate new entries in §12
          |         | itself, but the Phase 1 done checklist (§2.3 items 9–10) effectively
          |         | gates the readiness declaration. Spec still declares "ready for
          |         | implementation" with Phase 1 as committed scope.
----------+---------+-----------------------------------------------------------------------
§13.2     | CHANGED | Buffer scoping section updated with tab model. "Buffer scoping (tab
          |         | model)" paragraph added: annotation buffer key is
          |         | (surfaceId, paneId, tabId). surf_ace_read is already session-keyed;
          |         | provider derives tabId from sessionId transparently. Existing callers
          |         | continue to work unchanged.
----------+---------+-----------------------------------------------------------------------
§A.13     | NEW     | New appendix entry: "Multi-Session CLU Contention (Resolved)".
          |         | Documents the problem (Chat A vs Chat B overwrite), the resolution
          |         | (tab model: sessions never overwrite each other, each owns a tab),
          |         | and the reframing: contention question becomes "which tab is active"
          |         | not "who owns the pane", answered at surface UI layer via tab
          |         | lifecycle events. Cross-references §3.1.1, §6.1.1, §6.2, §13.2.
```

---

## Notes for HTML Document Editor

1. **§1** — The HTML overview for §1 should be substantially updated. It now covers Purpose & Goals as a first-class section, not just a brief intro.

2. **§2a** — This is a new inter-section insertion (between §2 and §3). The HTML overview may need a new row/card for "Concepts" as a distinct section.

3. **§6.10** — Annotation Mode is an entirely new section. Add a new entry in the HTML section list between §6.9 (Content Type Characteristics) and §7 (Always-On Event Delivery).

4. **§A.13** — New resolved appendix entry. Add to the Appendix A table in HTML.

5. **Tab operations in §6.1.1** — The §6.1.1 HTML card should be updated to reflect tab.list, tab.close, and tab lifecycle events alongside the pane operations.

6. **Schema section (§10)** — The HTML overview for §10 can note that TabId, Tab* schemas, and tab lifecycle event schemas are now included in the full schema block.

---

*Generated: 2026-03-04 | Pass 20*
