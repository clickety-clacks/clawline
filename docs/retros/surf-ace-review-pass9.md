# Surf Ace Protocol — Adversarial Consistency Review Pass 9

**Date:** 2026-03-03  
**Reviewer:** subagent (Pass 9 — final adversarial)  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
**Prior passes:** 1–8 applied  
**Verdict:** ⚠️ NOT NITS ONLY — 3 real implementation-blocking gaps, 3 nits

---

## Verdict

**Cannot freeze yet.** Three real specification gaps exist that would produce ambiguous or incorrect implementations. All three are small fixes (1–2 sentences each). Nit items are below the bar for blocking.

---

## Focus Area 1: `lastNavigation` Register Consistency (§13.2, §14.3, Event Model)

### Real Gap 1-A: `navigatedAt` source is never stated

**§13.2** defines the register as `{ url: string, navigatedAt: EpochMs }`.  
**§14.3** repeats this structure: `{ url, navigatedAt }`.  
**Wire `NavigationEvent` payload (§10)** contains only: `contentId`, `revision`, `url`.  

`navigatedAt` does not appear in the `NavigationEvent` payload. It must be derived from the wire event envelope's `sentAt` field — but this mapping is **never stated** anywhere in §13.2 or §14.3. An implementor reading only §13.2 or §14.3 has no way to know where `navigatedAt` comes from.

**Same pattern in taps (§14.3):** The CLU taps entry has `{ eventId, timestamp, x, y, kind, ... }`. The wire `TapEvent` payload has `contentId`, `revision`, `kind`, `position`, `nearestContent` — no `timestamp` field. The taps `timestamp` must also come from the wire envelope `sentAt`, but this is likewise never stated.

**Fix:** In §13.2 and §14.3, add one sentence: "`navigatedAt` maps from the wire `NavigationEvent` envelope `sentAt`." Same pattern for taps `timestamp`.

### Assessment: §13.2 ↔ §14.3 ↔ event model internal consistency

- `lastNavigation` is Latest-wins in §13.2; §13.4 clears all latest-wins on `surf_ace_read` — **consistent** ✓  
- §13.2 says "Cleared when CLU calls `surf_ace_read`" — matches §13.4 — **consistent** ✓  
- Structure `{ url, navigatedAt }` is identical in §13.2 and §14.3 — **consistent** ✓  
- "HTML only" designation is consistent between §13.2 and §14.3 — **consistent** ✓ (but see Gap 3-A below)  
- Populated by `event.navigation` — NavigationEvent exists in schema and is in the `minimum_deep` profile — **consistent** ✓  
- Dirty-flag/alert cycle works correctly with navigation events per §13.3 — **consistent** ✓

---

## Focus Area 2: Taps Entry `kind` Field and CLU-Layer Mapping

### Assessment

**`kind` field:**  
Wire `TapEvent.payload.kind` is `"tap" | "long_press"`. CLU taps entry §14.3 declares `kind: "tap" | "long_press"` — **consistent** ✓.

**`nearestContent` → `nearestText` rename:**  
Stated in §14.3 — **complete** ✓.

**`elementRole`:**  
Correctly described as provider-computed (not in wire schema) with derivation method stated — **unambiguous** ✓.

**`position` decomposition:**  
Wire `position: { x, y }` → CLU `x, y` flat fields. Decomposition is obvious and implied by the field listing. Not a gap.

**`timestamp` source:**  
Covered in Gap 1-A above — same issue.

**Dropped fields not stated:**  
Wire `TapEvent` payload carries `contentId` and `revision`. The CLU taps entry (`{ eventId, timestamp, x, y, kind, nearestText?, elementRole? }`) drops both without explanation. These are reasonably inferrable (CLU doesn't need wire-level revision tracking in the register), but the spec never says "contentId and revision are dropped." This is a nit, not a blocking gap.

**Overall:** Taps CLU-layer mapping is complete and unambiguous modulo Gap 1-A (`timestamp` source) and the nit above.

---

## Focus Area 3: Selection CLU-Layer Mapping

### Real Gap 3-A: "Always text in v1" is an undocumented constraint, not a schema rule

**§14.3** states: "wire `kind` discriminator dropped (always 'text' in v1)."  
**Wire `Selection` schema (§10)** defines four variants: `null`, `kind: "text"`, `kind: "point"`, `kind: "region"`.

The claim "always text in v1" is an **implementation assumption**, not a constraint anywhere in the schema or event sections. No rule states that surfaces will only emit `kind: "text"` selections. No rule states what the provider does if it receives a `kind: "point"` or `kind: "region"` selection from the wire — drop silently? Map to text? Return an error?

Additionally, **§13.2** describes the selection register as "Current text or region selection; `null` if none" — explicitly mentioning "region", contradicting the §14.3 claim that only text occurs in v1.

**Fix options (pick one):**  
a) Add a prose rule: "In v1, surfaces only emit `kind: 'text'` selection events. If a `kind: 'point'` or `kind: 'region'` arrives, the provider discards it and leaves the selection register unchanged." Update §13.2 description to drop "or region."  
b) Define CLU-layer mappings for point and region variants.

Option (a) is simpler and consistent with the v1 scoping approach used elsewhere in the spec.

### Real Gap 3-B: `anchorStart`/`anchorEnd` undefined for non-HTML content types

**§14.3** defines `anchorStart`/`anchorEnd` as "provider-computed DOM character offsets — derived from browser selection API on render side." DOM character offsets have no meaning for `pdf`, `markdown`, `image`, `terminal`, or `canvas` content types. The spec gives no guidance on whether these fields are `null`, omitted, or undefined for non-HTML content.

**Fix:** Add one sentence: "For non-HTML content types, `anchorStart` and `anchorEnd` are always `null`."

---

## Focus Area 4: Other Real Contradictions

### Real Gap 4-A: `event.navigation` has no content-type scope restriction

**§13.2** `lastNavigation` is marked "HTML only" — correct.  
**Wire `NavigationEvent` schema (§10)** has no `contentType` constraint — it can structurally carry any `contentId`.  
**§7.1** describes `event.navigation` without restricting it to HTML content type.  
**§6.9** explicitly states "Navigation events do not fire" for `canvas` and `video` — but makes **no equivalent statement for `markdown`, `image`, `terminal`, or `pdf`**.

The implicit assumption is that navigation only applies to HTML content (the only type with live URL navigation), but this is never formally stated as a protocol rule. If the provider receives a navigation event while `markdown` or `image` content is active, the behavior is undefined — does it populate `lastNavigation` (which is "HTML only") or silently discard it?

**Fix:** In §7.1 or §6.9, add an explicit statement: "`event.navigation` applies only to `html` content type. Surfaces MUST NOT emit `event.navigation` for any other content type. If received by the provider for non-HTML content, it MUST be discarded."

---

## Nits (below the bar for blocking)

**Nit 1:** §6.9 explicitly says navigation events don't fire for `canvas` and `video`, but the same statement is absent for `markdown` (which is rendered HTML but typically has no live links). Harmless omission given Gap 4-A fix above will cover it globally, but the `markdown` exclusion could be made explicit in §6.9 for completeness.

**Nit 2:** §14.3 taps entry drops `contentId` and `revision` from the wire without explanation. An implementor reading the wire schema might wonder whether these are supposed to appear. Worth a parenthetical: "(wire `contentId`/`revision` not forwarded to CLU layer)."

**Nit 3:** §13.2 `lastNavigation` gets an explicit "Cleared when CLU calls `surf_ace_read` (consumed on read)" callout in the register table, but `scrollPosition`, `selection`, and `page` (all also Latest-wins, all also cleared on read per §13.4) do not get this callout. Minor documentation style inconsistency. Either add the callout to all Latest-wins registers in the table or remove it from `lastNavigation` and rely on §13.4.

---

## Summary

| # | Area | Severity | Description |
|---|------|----------|-------------|
| 1 | `lastNavigation` + taps | **Real** | `navigatedAt` and taps `timestamp` source (wire envelope `sentAt`) never stated |
| 2 | Selection CLU mapping | **Real** | "Always text in v1" undocumented as constraint; no rule for point/region on wire; §13.2 contradicts §14.3 on kinds |
| 3 | Selection CLU mapping | **Real** | `anchorStart`/`anchorEnd` undefined for non-HTML content types |
| 4 | `lastNavigation` / NavigationEvent | **Real** | `event.navigation` has no content-type scope restriction; `lastNavigation` "HTML only" vs. wire |
| N1 | §6.9 | Nit | Markdown nav exclusion unstated |
| N2 | §14.3 taps | Nit | Dropped wire fields not explained |
| N3 | §13.2 register table | Nit | "Consumed on read" callout style inconsistency |

All 4 real gaps are small fixes (1–3 sentences each). No structural redesign required. Once patched, spec is ready to freeze.
