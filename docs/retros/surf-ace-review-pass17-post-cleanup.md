# Surf Ace Spec Review — Pass 17 (Post-Cleanup Adversarial Check)

**Date:** 2026-03-04
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`
**Scope:** Adversarial internal consistency check after full editorial cleanup pass.
**Cleanup actions reviewed:** Added §1 Purpose and Goals; removed historical/replacement language; stripped attribution suffixes from section headings; reframed resolved appendix items as settled decisions.

---

## Verdict: REAL ISSUES (3) + NITS (5)

---

## Real Issues

### Issue 1 — Schema/prose divergence: `autoLabel` missing from `SurfacesListResponse` in §10

**Section refs:** §6.0, §10 (`SurfacesListResponse` $def)

**Problem:** §6.0 prose states that `surfaces.list` response items contain `{ surfaceId, name, autoLabel, viewport, paired }[]`, explicitly defining `autoLabel` as the auto-assigned window letter label displayed on the surface and used for CLU addressing. The JSON Schema in §10 for `SurfacesListResponse.payload.surfaces` items lists only `surfaceId`, `name`, `viewport`, and `paired` in both `required` and `properties`. `autoLabel` is absent.

An implementation reading only the schema would not include `autoLabel` in the response. A consumer reading the prose would expect it. This is a real wire contract bug.

**Fix:** Add `autoLabel` to the `SurfacesListResponse` schema in §10:

```json
"required": ["surfaceId", "name", "autoLabel", "viewport", "paired"],
"properties": {
  "surfaceId": { "$ref": "#/$defs/SurfaceId" },
  "name": { "type": "string" },
  "autoLabel": { "type": "string", "description": "Auto-assigned window letter label (e.g. \"A\", \"B\", \"AA\"). Displayed prominently on the surface and used for CLU window addressing." },
  "viewport": { "$ref": "#/$defs/SurfaceViewport" },
  "paired": { "type": "boolean", ... }
}
```

---

### Issue 2 — Phase 1 pane operations and events entirely absent from §10 schema

**Section refs:** §6.1.1, §10 (main `oneOf`, `EventType` enum, `ErrorResponse` op enum)

**Problem:** §6.1.1 defines five normative pane operations with full request/response field specs (`panes.list`, `pane.split`, `pane.focus`, `pane.rename`, `pane.close`) and four pane lifecycle events (`event.pane_created`, `event.pane_removed`, `event.pane_focused`, `event.pane_renamed`) — all described as Phase 1 committed work (§2.3). None of these appear anywhere in §10:

- Not in the main `oneOf` (no request/response schema defs).
- Not in the `EventType` enum (four pane events are untyped at schema level).
- Not in the `ErrorResponse.op` enum (pane ops can't produce typed errors per schema).
- Not as `$defs` entries.

This means §10 is materially incomplete relative to the protocol as spec'd. An implementation built purely from §10 would have no pane topology support; pane lifecycle events would fail `EventType` validation; pane op errors would be unrepresentable.

§12 readiness check #14 says "All messages validate against the schema in Section 10" — this check cannot pass for pane operations.

**Fix:** Either:
- (Preferred) Add `$defs` for all five pane operations (request + response) and four pane lifecycle events; add them to the main `oneOf`; extend `EventType` and `ErrorResponse.op` enums; add a `PaneId` string $def.
- (Acceptable if Phase 1 schema is deliberately deferred) Add an explicit note in §10 and §6.1.1 that pane operation schemas are added in the Phase 1 schema revision, and remove §12 check #14 as a gating readiness check until that schema is complete. As written, §12 #14 implies all pane messages already validate — they do not.

---

### Issue 3 — §1 misrepresents v1 obligations for `video` and `canvas` content types

**Section refs:** §1 (Core Goal #2), §6.9

**Problem:** §1 Core Goal #2 says:

> "CLU pushes content to surfaces in the following types: `html`, `image`, `pdf`, `terminal`, `markdown` (and `video`, `canvas` reserved for v2)."

The phrase "reserved for v2" implies these types have no normative status in v1. But §6.9 says:

> "The `video` and `canvas` content types are included in the `ContentType` schema enum in v1 so that implementations can reject them with `unsupported_content_type` rather than `invalid_payload`. This preserves forward compatibility: a v1 surface that does not implement these types still handles the message gracefully."

This is an active v1 wire contract obligation, not a deferral. A v1 surface that omits `video` and `canvas` from its `ContentType` enum would be non-conformant per §6.9, yet §1's "reserved for v2" language would lead an implementor to conclude they're safe to skip these entirely — including from the enum.

**Fix:** Update §1 Core Goal #2 to:

> "CLU pushes content to surfaces in the following types: `html`, `image`, `pdf`, `terminal`, `markdown`. The types `video` and `canvas` are included in the v1 schema enum for forward compatibility (surfaces MUST handle them gracefully with `unsupported_content_type`); full behavioral implementation is deferred to v2."

---

## Nits

### Nit 4 — §4.2.1 "Unresolved" design question embedded in a normative section

**Section ref:** §4.2.1

**Problem:** §4.2.1 "Open: Multi-Session CLU Contention" ends with:

> "**Unresolved.** Decision needed before implementing `surf_ace_push` multi-session behavior."

The spec's Appendix A exists specifically for open questions. An unresolved design question with listed options (last-write-wins, session ownership, idle-auto-release, etc.) in a numbered normative section (§4) creates reader confusion about what is normative and what is open. The heading says "Open:" which helps, but the item structurally belongs in the appendix.

**Fix:** Move §4.2.1 content to a new `A.13 Multi-Session CLU Contention` appendix section. Replace §4.2.1 with a forward reference: "Multi-session CLU contention at the tool layer is an open design question; see §A.13."

---

### Nit 5 — Residual historical/migration phrases not removed by cleanup

**Section refs:** §13.2, §14.3

**Problem:** The following phrases survived the cleanup and carry changelog or transition-tracking character inconsistent with a clean forward-looking spec:

1. **§13.2** ("Tool surface continuity" paragraph):
   > "`surf_ace_read_buffer` remains deprecated/removed. No new mandatory read tool is introduced for v1 dual-channel; the existing `surf_ace_read` response shape is extended."
   "Remains deprecated/removed" and "response shape is extended" are migration-tracking phrases.

2. **§14.3** (`surf_ace_read` "Migration notes" block):
   > "**Migration notes (frame-queue-only → dual-channel):**"
   Migration notes should not appear in a clean forward-looking spec.

3. **§14.3** (`surf_ace_read_buffer` section):
   > "It is documented here only for historical reference."
   "Historical reference" is a changelog phrase.

4. **Appendix A.1** (near bottom):
   > "`surf_ace_read_buffer` (the old composite buffer read tool) is deprecated and removed."
   "Old" is historical language.

5. **Appendix A.7** (context dictionary note):
   > "Note: the old `annotations`/`drawBuffer` fields are replaced by dual annotation channels…"
   "Old" and "replaced by" are replacement/changelog phrases.

**Fix:** 
- §13.2: rewrite as "The `surf_ace_read_buffer` tool is removed. `surf_ace_read` is the sole buffer read tool."
- §14.3 migration notes block: convert bullets to declarative statements about current behavior without migration framing, or remove if the points are already covered in the API description above.
- §14.3 `surf_ace_read_buffer` section: remove "historical reference" language; the section is already short and its content speaks for itself.
- A.1 and A.7: replace "old" with the specific name; replace "replaced by" with "is" / are now" as appropriate.

---

### Nit 6 — §1 Core Goals silent on multi-pane (Phase 1 committed work)

**Section refs:** §1 Core Goal #6, §2.3, §3.1.1, §6.1.1

**Problem:** §1 Core Goal #6 states: "CLU can manage multiple surfaces simultaneously. Each surface has a stable identity and independent content and annotation state." This describes multi-window but says nothing about panes within a surface, even though §2.3 commits multi-pane topology as Phase 1 work and §3.1.1 / §6.1.1 define it in full detail. A reader of §1 gets no indication that pane-scoped content and annotation targeting is a design goal.

**Fix:** Extend Goal #6 to:
> "CLU can manage multiple surfaces simultaneously. Each surface has a stable identity and independent content and annotation state. Within each surface, multiple panes can be independently targeted by `{surfaceId, paneId}` (Phase 1 committed; single-pane `paneId=\"root\"` is the v1 default)."

---

### Nit 7 — §2a non-standard section numbering

**Section ref:** §2a (Concepts)

**Problem:** The "Concepts" section uses the identifier `§2a`, an alphanumeric scheme that appears nowhere else in the spec (all other sections use decimal integers: §1–§14, §A.1–A.12). This makes it awkward to reference (`§2a` vs. `§2.5`), could confuse tooling that parses section numbers, and is visually inconsistent.

**Fix:** Renumber to `§2.5` (fits between §2 and §3 naturally) and update any cross-references. No cross-references to `§2a` by number were found in the current doc, so renaming only requires the heading change.

---

## Cross-Reference Integrity Summary

All explicit `§` cross-references checked and resolved correctly:
- §2.3 → §§13–14 ✓
- §3.1.1 → §2.3 ✓
- §6.0 → §4.2 ✓
- §6.1.1 → §2.3, §3.1.1 ✓
- §6.9 → §13.2 ✓
- §6.10 → §13.2 ✓
- §7.3 lifecycle event table vs. `ProfileControlledEventType` enum ✓
- §11 items → §7.1, §4.4 ✓
- §13.2 → §6.10 ✓
- §14.3 `surf_ace_read` → §7.1, §13.2 ✓
- Appendix A.1, A.2 → §6.10, §13.2 ✓
- Appendix A.7 → §6.10 ✓
- Appendix A.8 → §7.1 ✓
- Appendix A.9 → §6.9 ✓
- Appendix A.10 → §2.3 ✓

No broken cross-references found. The heading rename/cleanup did not introduce any dangling references.

---

## §1 Goals Completeness Check

| Goal | In §1? | Notes |
|---|---|---|
| CLU-managed surface | ✓ | Goal #1 |
| Content display (5 types) | ✓ | Goal #2 (video/canvas characterization needs fix — Issue 3) |
| User annotation | ✓ | Goal #3 |
| CLU annotation interpretation | ✓ | Goal #4 |
| Zero-config discovery (mDNS) | ✓ | Goal #5 |
| Multi-surface management | ✓ | Goal #6 |
| Standalone app | ✓ | Goal #7 |
| Multi-pane topology | ✗ | Phase 1 committed work; absent from §1 (Nit 6) |
| Content persistence across disconnects | ✗ | Key invariant in §4.4; not called out as a goal in §1 |
| Dual-channel annotation model | ✗ | Not expected at goal-summary level; implementation detail |

The content persistence invariant (§4.4: "content MUST NOT be affected by connection state") is arguably significant enough to warrant a mention in §1 — it's one of the few true invariants called out in bold. However, it could also be characterized as an implementation quality constraint rather than a system goal. Not raised as a required fix; flagged for author judgment.

---

## Normative Content Loss Check

No evidence of normative rule or schema detail removal during cleanup. All hardening decisions (§11), readiness checks (§12), pane lifecycle rules (§6.1.1), dual-channel buffer model (§13.2), and tool API shapes (§14.3) appear intact. The three real issues above are pre-existing schema omissions (pane schema was never in §10) or newly visible prose-schema divergence (autoLabel, video/canvas framing) — not cleanup-introduced regressions.
