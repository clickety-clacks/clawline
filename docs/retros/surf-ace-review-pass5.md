# Surf Ace Wire Protocol — Adversarial Consistency Review (Pass 5)

Reviewer: Subagent (adversarial consistency pass)
Date: 2026-03-03
Spec: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`

---

## Preflight Note

The spec file on disk has been updated since the version embedded in the subagent's task context. The new file (current) has a materially stronger invariant in Section 4.4 — content is now preserved indefinitely on ALL disconnects (not just `provider_shutdown`), and the grace window only governs session continuity (same-provider resume), not content lifecycle. Several issues in the original task description (e.g., the `superseded` clear contradiction) have already been resolved. The review below is against the **current file on disk**.

---

## Issues Found

### 1. `event.video_state` is a dangling wire-event reference — undefined everywhere
**Sections:** 13.2 (lines ~1750–1751)

The `playbackPosition` and `playbackState` registers are documented as "Populated by `event.video_state` wire events (v2; not defined in v1 minimum_deep profile)." But `event.video_state`:
- Is **not in the `EventType` enum** (Section 10 schema).
- Has **no schema definition** in Section 10's `$defs`.
- Is **not in the `oneOf` root message list** in Section 10.
- Is **not mentioned** in Sections 7.1, 7.2, or 7.3.

The reference names a specific event type that does not exist anywhere in the v1 spec. The forward-compatibility strategy for `video` and `canvas` types (described in Section 6.9) is to include them in the `ContentType` enum so surfaces can gracefully reject them. The same treatment was not applied to `event.video_state`. Either add a stub `VideoStateEvent` schema (with a note it's v2-only) — analogous to the `ContentType` enum approach — or change the register description to say "populated by a future v2 wire event (not defined in this spec)" without naming a specific event type that implementations would search for and fail to find.

---

### 2. `event.surface_appeared` and `event.surface_removed` absent from Section 7.3 audit table
**Sections:** 4.6 (line ~155), 7.3 (lines ~397–406)

Section 4.6 rule 6 states these events are "not profile-gated — always emitted regardless of `eventProfile` setting." This is a special classification that has no parallel in any other event. But the Section 7.3 Event Audit table lists six events and omits both `event.surface_appeared` and `event.surface_removed` entirely. Given that their always-on nature is more special than the other events (which are at least profile-gated), their absence from the classification table is a gap. An implementor building Section 7.3 as their reference for event behavior will miss this.

**Secondary gap:** the `pair.response.eventConfig.activeEvents` field (schema) is an array of `EventType` items. `EventType` enum includes both surface lifecycle events. The spec never says whether they should appear in `activeEvents` (since they're profile-exempt, it's ambiguous whether the list is the full active set or only the profile-controlled set). This needs a note.

---

### 3. `PairResponse.state` schema does not require `currentContentId` or `contentType`
**Sections:** 6.1 prose (line ~230), 11 item 7, Schema `PairResponse` (line ~1198)

Prose says: "Current content summary (`currentContentId`, `currentRevision`, `contentType` or `null`)."
Section 11 item 7 says: "pair response always returns authoritative current state (`currentContentId`, `currentRevision`, `contentType`)."

But the JSON schema for `PairResponse.state` has:
```json
"required": ["currentRevision"],
"properties": {
  "currentContentId": { ... },   // NOT required
  "currentRevision": { ... },
  "contentType": { ... }          // NOT required
}
```

A schema-valid `pair.response` can omit `currentContentId` and `contentType` entirely. A provider receiving such a response cannot determine whether content is active without special-casing the absence of the field. Both fields should be in `required` (with `oneOf: [ContentId, null]` types, which is already the pattern). This contradicts the adversarial hardening intent (item 7) that demands authoritative state on every pair response.

---

### 4. Annotation register schema is structurally different from wire `Stroke` schema, with no mapping defined
**Sections:** 10 `Stroke` schema (line ~1383), 13.2 annotations register (line ~1748), 14.3 `surf_ace_read` return (line ~1936)

Wire `Stroke` schema (Section 10) defines:
```
required: strokeId, tool, points
optional: videoTimestamp
StrokePoint: { x, y, pressure?, timestamp (required) }
```

The annotations register (Section 13.2) defines each stroke as:
```
{ strokeId, points: [{x, y, pressure}], bbox: {x,y,w,h}, startedAt, endedAt, videoTimestamp? }
```

Differences:
- `tool` is required in the wire schema but **absent from the register schema**
- `timestamp` (on StrokePoint) is required in the wire schema but **absent from the register point format**
- `bbox`, `startedAt`, `endedAt` are in the register schema but **absent from the wire schema** (they are apparently derived, but the derivation is never specified)

The `surf_ace_read` tool return (Section 14.3) further drops `videoTimestamp` from the annotation array, even though Section 13.2 includes it. No mapping from wire format to register format is described anywhere — implementors must infer how `bbox` (bounding box of stroke) and `startedAt`/`endedAt` (derived from `StrokePoint.timestamp` values?) are computed from the wire payload.

This is a two-layer schema drift (wire → register → tool) with no bridging spec.

---

### 5. `surf_ace_read` tool return omits `videoTimestamp` from annotation entries
**Sections:** 13.2 (line ~1748), 14.3 (line ~1936)

Section 13.2 explicitly states the annotations register entry includes `videoTimestamp?` (populated only for video content). The `surf_ace_read` return spec in Section 14.3 shows annotation entries as:
```
[{ strokeId, points:[{x,y,pressure}], bbox:{x,y,w,h}, startedAt, endedAt }]
```
`videoTimestamp` is missing. A CLU caller reading from a video surface (v2) would never receive temporal stroke anchors through `surf_ace_read` as currently specced.

---

### 6. `resumeGraceMs` is never communicated to the provider
**Sections:** 4.4 (line ~124), Schema `PairResponse`

`resumeGraceMs` (default 20000) governs the session continuity window after a disconnect. The value is surface-controlled and could differ per device. But it is never included in `pair.response`. The provider has no way to know the actual grace window, which affects:
- How urgently the provider should attempt reconnect after a crash (too slow = session lost, forced re-pair)
- How long the provider should wait before logging "session likely expired"

`resumeGraceMs` should be added to `pair.response.limits` (or a new `session` object in `pair.response`).

---

### 7. Section 8.2 `provider_shutdown` description is stale after Section 4.4 update
**Sections:** 8.2 (line ~455), 4.4 invariant (line ~130)

Section 8.2 close code table entry for `1000 + provider_shutdown`:
> "Provider-initiated shutdown (gateway restart). Surface enters reconnect grace — content preserved, NOT cleared immediately."

After the Section 4.4 update, ALL disconnects preserve content (indefinitely, not just during grace). The phrase "NOT cleared immediately" implies content will eventually be cleared (at grace expiry), which is now false — content persists past grace expiry until CLU explicitly acts. The description should be updated to: "Provider-initiated graceful shutdown. Content is preserved indefinitely (per invariant); session continuity available to same provider during grace window."

The `provider_shutdown` reason string is still useful to send (for diagnostics and logging), but its behavioral description is no longer accurate.

---

### 8. Section 12 item 6 "hard-resets after grace expiry" — ambiguous against new invariant
**Sections:** 12 (line ~1702)

Item 6: "Reconnect path resumes within grace for same provider and **hard-resets after grace expiry**."

"Hard-resets" is ambiguous. In the old spec, grace expiry cleared content. Under the new invariant, grace expiry only invalidates the session (new providers can connect), not content. A surface implementor reading "hard-resets" may interpret this as clearing content — which would violate the invariant. Should be: "...session expires after grace (new providers may connect; content is unchanged)."

---

### 9. A.7 context record `timestamps` field is undefined
**Sections:** A.7 (line ~2142)

The context record is defined as `{ contentId?, url?, annotations, drawBuffer, scrollPosition, selection, page, timestamps }`. The `timestamps` field is referenced without any definition: no schema, no description, no enumeration of what timestamps are included (e.g., `createdAt`, `lastActivityAt`, `lastReadAt`?). This is a dangling field that implementors cannot act on. Either define it or remove it.

---

### 10. A.7 v2 restore-on-revisit contradicts Section 6.2 surface behavior — unacknowledged protocol conflict
**Sections:** 6.2 (line ~237), A.7 (line ~2145)

A.7 says v2 restore-on-revisit is "a provider-side policy switch only — no protocol changes required."

But Section 6.2 is a **surface** rule, not a provider rule: "`content.set` MUST clear all drawing overlay strokes before rendering the new content." If v2 restore is enabled and the provider sends a `content.set` with a previously-seen `contentId`, the surface will still clear strokes (as required by Section 6.2). The restored context (including annotations) would immediately be wiped by the surface. The provider cannot suppress surface-side stroke clearing — it would require either a protocol change (a `content.set` flag to inhibit stroke clearing) or a new operation (e.g., `content.restore`).

The claim that this is "no protocol changes required" is incorrect. This should be flagged as a known v2 protocol design item rather than presented as a solved provider-only policy switch.

---

### 11. `surfaces.list` response items include no occupancy/paired state
**Sections:** 6.0, Schema `SurfacesListResponse` (line ~802)

The `surfaces.list` response returns `{ surfaceId, name, viewport }[]` per surface. It does not include whether any surface is already paired (busy) or available. When a provider connects to a multi-window endpoint and calls `surfaces.list`, it has no way to know which surfaces are occupiable without attempting `pair.request` and receiving a `busy` error. The mDNS TXT record has a `busy` field for the endpoint, but this doesn't disambiguate per-window. Each surface item in the list should include a `paired` or `available` boolean.

---

### 12. `SnapshotHintEvent` reasons `after_render` and `after_reconnect` not explained in prose
**Sections:** 7.3, Schema `SnapshotHintEvent` (line ~1620)

The schema defines three reason values: `after_render`, `after_reconnect`, `backpressure_drop`. Section 7.3 rule 8 describes only `backpressure_drop`. The conditions under which the surface emits `after_render` and `after_reconnect` are never documented in any prose section. These are not self-evident:
- `after_render`: after completing a complex render? After every content.set? Undefined.
- `after_reconnect`: should be the most predictable, yet it's not mentioned in Section 4.4's reconnect flow or Section 7.3's event rules.

Since `event.snapshot_hint` is labeled "provider-internal," this may be intentional opacity, but implementors need to know WHEN the surface emits each reason to implement the surface correctly.

---

### 13. A.7 navigation context switch behavior is unspecified
**Sections:** A.7 (line ~2137)

A.7 defines the context dictionary with keys for both `contentId` (CLU-pushed) and URL strings (user-navigated). When the user follows a link and `event.navigation` fires:
- Does this trigger a context switch from the `contentId` key to the new URL key?
- What happens to the old `contentId` context entry — evicted, retained, or silently abandoned?
- If the user navigates back to the original content, does its context record survive?

In v1, the dictionary has at most one entry (per the eviction rule), so navigation would discard the old entry and create a new one. But the spec only says `content.set` and `content.clear` evict the active context record — navigation is not mentioned. An implementor following the eviction rule literally would not evict on navigation, and the "at most one entry" invariant would be violated once the user navigates.

---

## Summary

| # | Area | Severity | Type |
|---|---|---|---|
| 1 | `event.video_state` undefined wire event | High | Missing schema / dangling reference |
| 2 | `surface_appeared`/`removed` absent from §7.3 table | Medium | Prose/audit gap |
| 3 | `PairResponse.state` missing required `currentContentId`/`contentType` | High | Schema/prose mismatch |
| 4 | Annotation register ≠ wire `Stroke` schema, no mapping defined | High | Schema mismatch |
| 5 | `surf_ace_read` missing `videoTimestamp` on annotation entries | Medium | Schema/prose mismatch |
| 6 | `resumeGraceMs` not in `pair.response` | Medium | Missing schema field |
| 7 | §8.2 `provider_shutdown` description stale | Medium | Prose contradicts invariant |
| 8 | §12.6 "hard-resets" ambiguous against new invariant | Medium | Prose ambiguity |
| 9 | A.7 `timestamps` field undefined | Medium | Undefined reference |
| 10 | A.7 v2 restore contradicts §6.2 MUST-clear (surface rule, not provider rule) | High | Internal contradiction |
| 11 | `surfaces.list` no per-surface occupancy state | Low | Missing field |
| 12 | `SnapshotHintEvent` `after_render`/`after_reconnect` reasons unexplained | Low | Missing prose |
| 13 | A.7 navigation context switch behavior unspecified | Medium | Missing behavior spec |

**Critical path for implementation:** Issues 1, 3, 4, 10 must be resolved before the schema is used to generate wire parsers or register model code. Issues 7 and 8 must be fixed before documentation is used for surface implementors (risk of incorrect content-clear behavior on grace expiry or takeover).
