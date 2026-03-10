# Surf Ace Spec — Adversarial Consistency Review Pass 16 (Overnight)
**Date:** 2026-03-04  
**Reviewer:** Subagent (automated adversarial pass)  
**Scope:** New/changed sections from 2026-03-03/04 review session only  
**Verdict: REAL ISSUES FOUND (8 real issues, 10 nits)**

---

## Sections Reviewed

- §2.4 — Extension isolation invariant
- §3.1.1 — Pane rules + window/pane naming system
- §4.2 — Multi-session contention open question
- §4.5 — Surface UI connectivity indicator
- §6.1.1 — Pane lifecycle ops
- §6.10 — Annotation mode UX
- §A.12 — Model-side markup open topic

Cross-referenced against: §2.3 phasing, §7.3 event audit, §10 JSON schema, §13.2 dual-channel, §14.3 tool surface, §A.7, §A.10.

---

## REAL ISSUES

### ISSUE 1 — §6.1.1 / §10: Pane operations and events entirely absent from JSON schema

§6.1.1 defines five new wire operations (`panes.list`, `pane.split`, `pane.focus`, `pane.rename`, `pane.close`) and four new events (`event.pane_created`, `event.pane_removed`, `event.pane_focused`, `event.pane_renamed`). None of these appear anywhere in §10 (JSON Schema):

- No request/response schema defs for any `pane.*` ops
- `EventType` enum does not include `event.pane_created`, `event.pane_removed`, `event.pane_focused`, `event.pane_renamed`
- `oneOf` list in §10 root schema does not include these event types
- No `PaneId` type defined (analogous to `SurfaceId`, `ContentId`, etc.)
- The `ErrorResponse.op` enum in §10 doesn't include `panes.list` or `pane.*` ops
- The `ProfileControlledEventType` vs always-on distinction for pane events is not reflected in schema

§6.1.1 also says pane lifecycle events are "always-on (not profile-gated), analogous to `event.surface_appeared`/`event.surface_removed`" — but §7.3's event audit table doesn't list them either.

**Impact:** Wire protocol is formally incomplete. Implementers have prose but no schema to validate against, and schema validation (§12 readiness check #14) cannot pass.

---

### ISSUE 2 — §4.2 cross-reference to §A.12 is factually wrong

§4.2 (multi-session contention open question) says: *"Decision needed before implementing `surf_ace_push` multi-session behavior. See also §A.12 and UI open topics (chat name indicator on surface)."*

§A.12 is about **model-side markup and point-outs** — the model drawing on the surface. It has no content about multi-session CLU contention, session ownership, or chat name indicators. These are completely unrelated topics.

**Impact:** Anyone following the cross-reference looking for guidance on multi-session ownership will find model markup instead. The real topic (chat name / session-ownership indicator on surface UI) has no home in the spec at all — it's referenced but doesn't exist.

---

### ISSUE 3 — §14.3 has no CLU tools for pane lifecycle operations

§6.1.1 defines `pane.split`, `pane.focus`, `pane.rename`, `pane.close` as wire-level operations the model needs to invoke. But §14.3 (CLU Tool Surface) has no corresponding CLU tools for any of these. The only acknowledgment is a note:

> *"pane selector is currently omitted from v1 tool signatures in this document; Phase 1 completion requires adding optional `paneId` (default `root`) to all screen-scoped tools."*

That note is about adding a `paneId` param to existing tools — it doesn't address the pane management operations themselves. CLU has no way to call `pane.split`, `pane.focus`, `pane.rename`, or `pane.close`. §3.1.1 says "The model may create, split, rename, and close panes in conversation with the user" — but the tool surface doesn't exist to do that.

**Impact:** §2.3 Phase 1 done checklist item 2 ("Pane lifecycle exists: create/split, resize, focus/select, close") cannot be satisfied without these tools. The spec commits to this as Phase 1 work but omits the tool surface definition.

---

### ISSUE 4 — paneId format for non-root panes is undefined

§3.1.1 says panes have auto-assigned numbers (0, 1, 2...) as display labels, and the v1-compat default is `paneId="root"`. §6.1.1 `panes.list` returns `paneId` and `autoLabel` (e.g. `0`) as separate fields — implying `paneId` is a stable opaque identifier, not the number itself.

But:
- What does the `paneId` string look like for non-root panes? Like `surfaceId` (`sf_xxx`)? Like `contentId` (`ct_<8hex>`)? Numeric? Prefixed?
- No `PaneId` type is defined in §10 schema (no pattern, no example)
- §6.1.1 `pane.split` request says `"paneId" (pane to split, default "root")` — implying `"root"` is a valid paneId literal. Is `"root"` a special-case keyword or a regular paneId that happens to be assigned that value for the first pane?
- §6.1.1 `pane.rename` says "CLU tools accept either form in the `paneId` selector field" (name or number) — but if paneId is an opaque identifier, how does number addressing map to paneId at the wire layer?

**Impact:** Without a defined paneId format and addressing scheme, iOS, Electron, and provider implementations will diverge. This is directly blocking Phase 1 interop tests.

---

### ISSUE 5 — §13.2 dual-channel buffer is not pane-scoped, contradicting §A.10

§A.10 (committed Phase 1 design direction) says:

> *"Scope all mutable state by `contextScope = { surfaceId, paneId }`."*

And: *"Default single-pane v1 behavior maps to `paneId='root'`."*

But §13.2's per-screen local buffer (live dirty channel, closed frame queue, all registers) is described entirely in terms of per-`surfaceId` scope. There is no `paneId` scoping anywhere in §13.2's buffer model, frame structure, alert gate, or `surf_ace_read` return shape. 

Specifically:
- `surf_ace_read(fingerprint)` takes only `fingerprint` (surfaceId), no paneId
- The frame structure has `contentId`, `contextKey`, `url` — but no `paneId`
- The alert gate fires per-screen, not per-pane
- Registers (`taps`, `scrollPosition`, `selection`, etc.) are per-screen

In a multi-pane window, Pane A and Pane B share the same `surfaceId`. `surf_ace_read` on that surface would return a commingled buffer from all panes. This is incorrect — §3.1.1 rule 3 says each pane has independent capture frame queue, taps, selection, scroll, and annotation state.

**Impact:** §13.2 needs a `paneId` dimension threaded through the buffer model before Phase 1 is done. The scope mismatch between §A.10 and §13.2 is a concrete architecture gap, not a nit.

---

### ISSUE 6 — §6.1.1 `pane.close` fate of unread closed frames is unspecified

§6.1.1 says: *"Content and annotation state for the closed pane are discarded. Surface emits `event.pane_removed`."*

§13.2 defines a closed-frame queue that is "consumed-on-read" (dequeued after `surf_ace_read` returns them). If a pane has 5 closed frames queued and is then closed, the spec is silent on what happens:

- Are those unread frames silently dropped?
- Are they drained into the surface-level queue?
- Does `surf_ace_read` still return them?

Given §13.2's statement that "Closed frames are guaranteed context-preserved records and MUST remain deliverable," silent discard on `pane.close` would violate that guarantee.

**Impact:** Data loss ambiguity. CLU could miss annotation context that was queued but not yet read before a pane was closed.

---

### ISSUE 7 — §2.4 extension isolation doesn't resolve which extension owns the provider

§2.4 establishes that `extensions/surf-ace/` and `extensions/clawline/` are peers with no cross-imports. But §§13–14 describe a "provider" that:
- Manages persistent WS connections to surfaces (§14.1)
- Maintains per-screen local buffers (§13.2)
- Registers CLU tools (`surf_ace_push`, `surf_ace_read`, etc.) (§14.3)
- Fires alerts to CLU sessions (§13.3, §14.4)

Which extension implements this? If the provider lives in `extensions/surf-ace/`, that's clean — surf-ace owns the WS client, buffer, and tools. If it lives in `extensions/clawline/`, clawline would need to import surf-ace protocol types (wire schema, message defs), violating §2.4.

§2.4 says "Surf Ace has its own `openclaw.plugin.json` manifest and registers its own tools and services independently" — which implies surf-ace is the provider. But §13.1 Design Principle 1 says "Normal Clawline message dispatch must have zero knowledge of Surf Ace" — which could be read as surf-ace being in a separate extension (confirming provider-in-surf-ace), but the provider↔CLU alert channel (§14.4) routes to `agent:main:main` by default. Who fires that alert? If surf-ace, it needs to communicate into Clawline dispatch — which may require some cross-extension boundary crossing.

**Impact:** Without resolving this, the impl agent picking up Phase 1 will make an architecture call that may need to be reversed.

---

### ISSUE 8 — §4.2 `surf_ace_push` multi-session behavior unresolved but tool is fully specced

§4.2 explicitly says: *"Unresolved. Decision needed before implementing `surf_ace_push` multi-session behavior."*

But §14.3 fully specs `surf_ace_push` with no mention of session ownership mechanics, no error code for second-session contention, and no placeholder behavior. The tool as written implies last-write-wins (option 1 from §4.2). Implementers following §14.3 will bake in last-write-wins by default.

This is a conflict between an explicitly unresolved open question (§4.2) and a complete tool spec that implicitly resolves it (§14.3).

**Impact:** Either §14.3 should document the interim behavior ("last-write-wins pending §4.2 resolution") or §4.2 should be resolved before §14.3 is implemented.

---

## NITS

### N1 — §3.1.1 and §4.5 both have dangling "UI section" reference

Both sections reference "UI section" or "UI open topics" for details:
- §3.1.1: "exact placement defined in the UI section (see UI open topics)"
- §4.5: "Details to be fully specified in the UI section"

No such section exists in this spec and no cross-reference to a separate UI spec is given. Should say "TBD — separate UI spec" or cite a concrete appendix.

---

### N2 — §4.5 yellow transition threshold undefined from surface perspective

The connectivity indicator says yellow triggers when "a ping was expected but has not yet arrived." But the surface doesn't have a configured heartbeat interval from the provider (it's provider-side). The spec doesn't define the grace margin: yellow after 10s (one missed ping)? 12s? 15s? Without an explicit threshold, surface implementations will diverge on when yellow fires.

Suggested fix: add "Surface transitions to yellow if no ping received within `heartbeatIntervalMs + heartbeatGraceMs` (suggested default: 13s = 10s interval + 3s grace)."

---

### N3 — §4.2 section heading mismatch

The section heading is "4.2 Single-Connection Rule" but the body now contains both the original single-connection rules and a substantial new "Open: multi-session CLU contention" block. The open question should be in a sub-section (e.g., §4.2.1) for navigation clarity. Currently the heading misleads readers into thinking it's only about the single-connection rule.

---

### N4 — §6.1.1 `pane.split` "count" field is ambiguous

`count (number of resulting panes, min 2)` — does "resulting" mean:
(a) total panes in the window after split (including the original), or
(b) number of new panes created?

"Splits an existing pane into N panes" with min 2 suggests (a), meaning `count=2` splits one pane into two. But "min 2" could also mean you can't request fewer than 2 new panes, implying (b). Should say explicitly: "total pane count after the split, including the source pane that is retained."

---

### N5 — §6.1.1 `pane.focus` has no response fields

`panes.list`, `pane.split`, `pane.rename`, `pane.close` all describe response fields. `pane.focus` only lists its request fields (`paneId`) and defines no response. Does it return anything? An ack? The newly focused pane's state? Should be explicit.

---

### N6 — §6.1.1 `pane.split` response is undefined

`pane.split` defines request fields and describes behavior (new panes created, event emitted) but doesn't define response fields. The response must at minimum return the new paneIds and autoLabels so the caller can target the new panes. Without a defined response, the caller has no way to learn what paneIds were created except by listening for `event.pane_created`.

---

### N7 — §6.10 Electron "Done" button is ambiguous

"Tapping the button again (or Done) exits annotation mode" — on Electron, is there:
(a) one toggle button that says "Annotate" to enter and "Done" to exit (relabeled), or
(b) two buttons: an "Annotate" toggle + a separate "Done" button?

The iPad flow is explicit: "finger sketching" button + "Done" button are distinct. The Electron flow is ambiguous. Should be explicit.

---

### N8 — §3.1.1 window letter labels have no wire representation

§3.1.1 defines window letter labels (A, B, C...) as "displayed prominently on surface." But no API field carries this label:
- `surfaces.list` response has `surfaceId`, `name`, `viewport`, `paired` — no letter label
- `pair.response` has `surfaceName` — this is the user-assigned mDNS name, not the letter label
- `event.surface_appeared` has `surfaceId`, `name`, `viewport` — no letter label

If the model or user refers to "Window A," there's no programmatic way to resolve that reference to a `surfaceId`. Either the letter label needs a wire field (e.g., `autoLabel` in `surfaces.list` and `surface_appeared`) or the spec should explicitly say label assignment is UI-only and CLU uses `surfaceId`/`name` exclusively.

---

### N9 — §A.12 model markup exclusion from frames stated normatively without a mechanism

§A.12 says: *"Model markups are NOT captured in capture frames / screenshot buffers (they are provider-originated, not user-originated, so they must not pollute the surface-observation loop)."*

This is stated as a requirement, but no mechanism exists in v1 for the surface to distinguish model-originated strokes from user strokes. The `Stroke` schema has no `source` field. The note is in an "open" section about future design, so this is appropriate — but the language reads normative ("MUST NOT"). Should be softened to "intent: must not pollute" pending wire protocol design.

---

### N10 — §6.1.1 `event.pane_created` missing `parentPaneId`

`event.pane_created` payload: `{ surfaceId, paneId, autoLabel, fromSplit: bool }`. The `fromSplit: bool` indicates a split, but doesn't say which pane was split. A receiver cannot reconstruct pane topology from events alone (e.g., to maintain a local pane tree). Consider adding `parentPaneId` (the pane that was split).

---

## Summary Table

| # | Type | Sections | Description |
|---|---|---|---|
| 1 | REAL | §6.1.1, §7.3, §10 | Pane ops + events missing from JSON schema and event audit |
| 2 | REAL | §4.2, §A.12 | §4.2 cross-ref to §A.12 is factually wrong topic |
| 3 | REAL | §6.1.1, §14.3 | No CLU tools for pane lifecycle operations |
| 4 | REAL | §3.1.1, §6.1.1, §10 | paneId format for non-root panes is undefined |
| 5 | REAL | §13.2, §A.10 | Dual-channel buffer not pane-scoped, contradicts §A.10 |
| 6 | REAL | §6.1.1, §13.2 | `pane.close` fate of unread closed frames unspecified |
| 7 | REAL | §2.4, §13–14 | Which extension owns the provider? |
| 8 | REAL | §4.2, §14.3 | `surf_ace_push` multi-session behavior unresolved but tool is specced |
| N1 | NIT | §3.1.1, §4.5 | Dangling "UI section" reference |
| N2 | NIT | §4.5 | Yellow indicator transition threshold undefined |
| N3 | NIT | §4.2 | Section heading misleads, open question needs sub-section |
| N4 | NIT | §6.1.1 | `pane.split` count ambiguous (total vs new) |
| N5 | NIT | §6.1.1 | `pane.focus` response undefined |
| N6 | NIT | §6.1.1 | `pane.split` response fields undefined |
| N7 | NIT | §6.10 | Electron "Done" button flow ambiguous |
| N8 | NIT | §3.1.1, §10 | Window letter labels have no wire representation |
| N9 | NIT | §A.12 | Model markup exclusion normative without mechanism |
| N10 | NIT | §6.1.1 | `event.pane_created` missing `parentPaneId` |

---

## Priority Guidance

**Block Phase 1 impl:** Issues 1, 3, 4, 5 (schema gaps and missing tool surface prevent interop tests from passing).

**Block Phase 1 planning:** Issues 7 (provider ownership) and 8 (push behavior default) should be decided before impl starts, or the impl agent will make silent architectural choices.

**Pre-ship fixes:** Issues 2, 6. Issue 2 is a bad cross-reference; issue 6 is a data-loss edge case.

**Can land with spec TODO markers:** All nits (N1–N10).

---

*Generated by automated adversarial pass. All findings reference spec text as of 2026-03-03 last-updated timestamp.*
