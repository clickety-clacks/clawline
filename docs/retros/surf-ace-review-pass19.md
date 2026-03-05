# Surf Ace Spec — Adversarial Review Pass 19

**Date:** 2026-03-04
**Reviewer:** CLU (subagent)
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`
**Prior pass:** Pass 18 fixed 6 real issues + 3 nits (sessionId injection, tabId derivation, pane.close tab cascade, annotation mode tab switch, surf_ace_read tab scoping, §7.3 event table completeness)

---

## Verdict: REAL ISSUES

**1 hard contradiction, 1 undocumented wire-schema gap, 5 nits.**

Not ready for HTML update + impl dispatch as-is. Resolve the contradiction and decide the wire-schema gap first.

---

## Real Issues

### REAL-1 · sessionId: prose vs. schema direct contradiction

**Sections:** §3.1.1 Tab rule 12, §6.2 rule 5, §10 `ContentSetRequest`

The prose says (twice, identically):

> "Surface implementations MUST NOT accept `sessionId` from the wire payload; the provider stamps it before forwarding the request to the surface."

The `ContentSetRequest` JSON schema in §10 marks `sessionId` as a **required** field in the payload:

```json
"required": ["contentId", "revision", "contentType", "content", "sessionId"],
```

These two statements are directly contradictory. A surface implementer reading the prose would derive sessionId from the authenticated WS session context, not the payload. A surface implementer reading the schema would read it from the required wire field. An implementer doing both would not know which to trust.

The schema is probably correct: the provider stamps sessionId into the wire message and the surface reads it. The prose "MUST NOT accept from wire payload" appears to be trying to say "CLU must not be able to supply an arbitrary sessionId (security)" — but as written it forbids what the schema requires.

**Fix options:**
- Option A (preferred): Keep sessionId in the schema as required; reword the prose to: "The provider injects `sessionId` from the authenticated WS session context into the wire payload before forwarding to the surface. CLU does not pass `sessionId` as a tool parameter. The surface MUST verify that the wire payload `sessionId` matches the authenticated session's identity and reject mismatches."
- Option B: Remove sessionId from ContentSetRequest schema; surface derives it from the WS session context established at pair time. The schema description "Surface uses sessionId to route to the correct tab" would change to "Surface uses the sessionId from the authenticated pair session to route to the correct tab."

Either works architecturally. They are incompatible implementations. Must pick one.

---

### REAL-2 · paneId missing from user-interaction event schemas with no note that it needs to be added

**Sections:** §10 `DrawingFlushEvent`, `TapEvent`, `ScrollEvent`, `SelectionEvent`, `PageEvent`, `NavigationEvent`; compare with §14.3 pane note

None of the user interaction event schemas carry `paneId`. In multi-pane mode (Phase 1 committed), the provider receives a `DrawingFlushEvent` and cannot determine which pane was annotated. ContentId-based inference is fragile (same contentId pushed to multiple panes would be ambiguous) and is not stated as the intended approach anywhere.

The spec does acknowledge the paneId gap at the **CLU tool layer** (§14.3): "pane selector is currently omitted from v1 tool signatures; Phase 1 completion requires adding optional `paneId` (default `root`) to all screen-scoped tools." But this note covers CLU tools only. The wire-level event schemas (§10) have no parallel note. An implementer building the surface from §10 alone would not add paneId to events.

**Also affects:** `ContentSetRequest`, `ContentAppendRequest`, `ContentPatchRequest`, `ContentClearRequest`, `AnnotationsRemoveRequest`, `SnapshotGetRequest` — none include `paneId` at the wire level. This is the same gap in the outbound direction.

**Fix:** Either (a) add `paneId` (optional, default `"root"`) to all content operation schemas and user-interaction event schemas now, or (b) add a wire-schema note in §10 parallel to the §14.3 tool-layer note — "paneId is omitted from content operation and event schemas; Phase 1 requires adding optional `paneId` (default `root`) to these schemas before multi-pane impl can proceed." Without one or the other, the schema is misleadingly complete-looking for Phase 1.

---

## Nits

**N1 · tabId derivation language inconsistency (§2a vs §3.1.1.10)**

§2a (Concepts): "The surface **MAY** derive it from `sessionId`… but is not required to."  
§3.1.1 rule 10: "`tabId` format: **derived from** `sessionId`…"  
§10 `TabId` description: "**Derived from** sessionId…"

§2a's "MAY" framing is more accurate (tabId's only hard requirements are stability and pane-uniqueness). §3.1.1 and the schema description use "derived from" as if it's required. Since CLU must use the echoed tabId and never predict it (rule 12), the derivation scheme is implementation freedom — §2a is right, the others are misleading.

**Fix:** Change §3.1.1 rule 10 and the `TabId` schema description to match §2a: "May be derived from `sessionId` (e.g., a stable short hash or the full `sessionId` string), but format is surface-defined."

---

**N2 · PairResponse `activeEvents` description only mentions surface_appeared/removed as excluded**

The `activeEvents` field in the `PairResponse` schema says:

> "Lifecycle events (surface_appeared/removed) are excluded — they are always active regardless of profile."

But pane and tab lifecycle events (`pane_created`, `pane_removed`, `pane_focused`, `pane_renamed`, `tab_created`, `tab_removed`, `tab_focused`) are also excluded from `activeEvents` (confirmed in §7.3 table). The schema description is incomplete.

**Fix:** Update the description to: "Profile-controlled events active for this session. Always-on lifecycle events are excluded: surface_appeared, surface_removed, pane_created, pane_removed, pane_focused, pane_renamed, tab_created, tab_removed, tab_focused."

---

**N3 · `SurfaceAppearedEvent` missing `autoLabel`**

`surfaces.list` response includes `autoLabel` (the window letter label, e.g. "A", "B"). The `event.surface_appeared` schema only carries `{ surfaceId, name, viewport }`. When a new window appears at runtime, the provider learns about it but has to call `surfaces.list` to get the label. This is inconsistent — the event should carry `autoLabel` so the provider doesn't need a follow-up round-trip.

**Fix:** Add `"autoLabel": { "type": "string" }` to `SurfaceAppearedEvent` payload (required), matching `SurfacesListResponse` surface entry shape.

---

**N4 · Historical/migration language in §14.3**

The spec reads as a primary authoritative document in most sections, but §14.3 has three chunks of changelog language:

1. `surf_ace_read_buffer (Deprecated)` subsection — "documented here only for historical reference"
2. "Migration notes (frame-queue-only → dual-channel)" section with "existing callers"/"new callers" framing
3. §A.1: "Note: `surf_ace_read_buffer` (the old composite buffer read tool) is deprecated and removed."

A primary spec should just state the current model. Remove the deprecated tool subsection (or relegate to a true changelog appendix), remove "migration notes," and drop "old" from §A.1.

---

**N5 · §6.10 forward reference to "open live frame" — minor**

§6.10 (Annotation Mode tab switch rule) says: "annotation mode exits immediately (equivalent to tapping Done). Any in-flight strokes are finalized and assigned to the tab that was active when the strokes began." It also refers to "an open live frame exists" — which is terminology defined in §13.2. §6.10 appears before §13.2. Readers encounter the term before its definition.

**Fix:** Add a parenthetical in §6.10: "an open live frame exists (see §13.2 for live frame definition)."

---

## Pass 18 Fix Verification

All six pass 18 fixes are present and land cleanly:

| Fix | Status |
|---|---|
| sessionId injection rule in §3.1.1 and §6.2 | ✅ Present (but creates REAL-1 contradiction with schema) |
| tabId derivation clarified opaque | ✅ Present (rule 12; CLU MUST use echoed tabId) |
| pane.close tab cascade (tab_removed before pane_removed, closedFramesDiscarded sums all tabs) | ✅ Present in prose and schema |
| Annotation mode tab switch behavior | ✅ Present in both §3.1.1 rule 13 and §6.10 (consistent, no duplication issues) |
| surf_ace_read tab scoping | ✅ Present in §14.3; correctly states session-keyed implicit routing |
| §7.3 event table completeness (pane + tab lifecycle rows) | ✅ All 7 new rows present; always-on classification correct; activeEvents exclusion noted |

The three pass 18 nits (tab rule 12 precision, `closedFramesDiscarded` description, `activeEvents` description) were applied. N2 above is a residual of the `activeEvents` nit — the fix made surface_appeared/removed explicit but didn't extend to pane/tab events.

No pass 18 fixes contradict each other. The one new contradiction (REAL-1) is between the sessionId injection prose (new in pass 18) and the schema field that was also added in pass 18 — they were added to describe the same design but landed in tension.

---

## Cross-Reference Check

All internal cross-references resolve:
- §3.1.1 → §A.13 (Resolved): ✅ appendix entry exists
- §2.3 Phase 1 checklist items → §3.1.1, §6.1.1: ✅ all cross-refs valid
- §6.10 → §13.2 (frame finalization): ✅ §13.2 covers this (forward ref only, N5)
- §7.3 activeEvents exclusion notes: ✅ consistent with schema `ProfileControlledEventType` enum
- §14.3 pane note → Phase 1: ✅ consistent with §2.3 done checklist

---

## Summary

| Category | Count |
|---|---|
| Real Issues | 2 |
| Nits | 5 |

**Must fix before impl dispatch:**
1. REAL-1: Resolve the sessionId "MUST NOT accept from wire payload" vs. `required` schema field contradiction. Pick a model and make prose + schema agree.
2. REAL-2: Add a wire-schema parallel to the §14.3 tool-layer pane note (or add `paneId` to content operation and event schemas now). Without this, the §10 schemas appear complete but are Phase-1-incomplete with no warning.

After those two fixes, the spec is clean for HTML update and impl dispatch.
