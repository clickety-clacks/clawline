# Surf Ace Spec — Review Pass 20

Date: 2026-03-04
Reviewer: CLU subagent (pass20 task)
Spec: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`

---

## Verdict: NITS ONLY

No real issues introduced by the pass 19 fixes. All four checks pass.

---

## Check Results

### 1. ContentSetRequest schema internally consistent with §6.2 prose?

**Pass.**

The `ContentSetRequest` payload schema has:
- No `sessionId` field anywhere — correct per §6.2 rule 5: *"sessionId is NOT a wire field on content.set requests."*
- Required fields: `contentId`, `revision`, `contentType`, `content` — matches §6.2.
- Optional `tabId` with appropriate description for explicit tab targeting — consistent with §6.2 rule 7 and §3.1.1 Tab rule 4.
- No duplicate or conflicting property definitions.

The `additionalProperties: false` guard would correctly reject any stray `sessionId` field. ✓

### 2. Is tabId in MutationAckResponse required and correctly typed?

**Pass.**

`MutationAckResponse.payload.required` = `["currentContentId", "currentRevision", "tabId"]` — `tabId` is in the required array. ✓

Type: `oneOf: [{ "$ref": "#/$defs/TabId" }, { "type": "null" }]` — required but nullable, which is semantically correct: non-null on `content.set`, null on `content.append` / `content.patch` / `content.clear`. The description spells this out explicitly. ✓

### 3. New contradictions introduced by two-agent fix pass?

**No duplicates or conflicts found.**

- `tabId` appears exactly once in `ContentSetRequest.payload.properties` (optional, not in required). No duplication.
- `tabId` appears exactly once in `MutationAckResponse.payload.required` and once in `MutationAckResponse.payload.properties`. No duplication.
- No `sessionId` field anywhere in either schema or anywhere else in §10 schemas where it shouldn't be. `sessionId` appears only in `PairResponse.payload.sessionId` (correct) and the `PairRequest.payload.resume.sessionId` nested object (correct).
- The `ProfileControlledEventType` enum correctly excludes all pane and tab lifecycle events (they are always-on, per §7.3). No conflicts with `EventType` enum (which includes all event types for capability advertisement).

### 4. Any remaining real issues not caught in prior passes?

**None found. Nits only:**

**Nit A** (pre-existing, not pass 19 origin): `MutationAckResponse.payload.required` does not include `contentType`. The field is in `properties` but optional. §6.2 says the successful response is a "rendered content summary" — `contentType` would be useful to require. However, this pre-dates pass 19 and is a policy question, not a schema defect.

**Nit B** (pre-existing, documented): `DrawingFlushEvent`, `TapEvent`, `ScrollEvent`, `SelectionEvent`, `PageEvent`, `NavigationEvent` carry no `paneId` or `tabId`. The provider correlates events to pane/tab context via `contentId` (which is pane+tab scoped). This design is pre-existing and documented by implication in §14.1 (connection daemon model). Not a new issue.

**Nit C** (pre-existing, documented in §14.3): `ContentSetRequest` has no `paneId` field. §14.3 explicitly notes: *"pane selector is currently omitted from v1 tool signatures in this document; Phase 1 completion requires adding optional paneId (default root) to all screen-scoped tools."* Not a defect — a known Phase 1 TODO.

---

## Summary

Pass 19 fixes were applied cleanly with no conflicts:
- `sessionId` is correctly absent from `ContentSetRequest`.
- `tabId` is correctly present as required-but-nullable in `MutationAckResponse`.
- Optional `tabId` in `ContentSetRequest` for explicit tab targeting is correctly typed and described.
- No double-application of fixes detected.

**Spec is consistent and ready for implementation as-is.**

---

*See surf-ace-html-changelist.md for the HTML document update section.*
