# Surf Ace Protocol Spec — Adversarial Review Pass 8

**Date:** 2026-03-03  
**Reviewer:** subagent (adversarial consistency pass)  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
**Prior passes:** 1–7 applied  
**Verdict:** **NOT NITS ONLY** — three real issues found

---

## Checklist Results

### ✅ Check 1 — `ProfileControlledEventType` vs `activeEvents`

**Clean.** The enum and its usage are consistent throughout the spec.

- `PairResponse.eventConfig.activeEvents` correctly references `ProfileControlledEventType` (the 7-value subset that excludes lifecycle events).
- `capabilities.eventTypes` correctly references `EventType` (the full 9-value set including `event.surface_appeared` / `event.surface_removed`).
- §7.3 audit table correctly states: `event.snapshot_hint` appears in `activeEvents` (it is profile-controlled); lifecycle events do NOT appear in `activeEvents` and are not profile-gated.
- `ProfileControlledEventType.$defs` description is accurate: "Excludes lifecycle events (event.surface_appeared, event.surface_removed) which are always active and never appear in activeEvents."
- §4.6 Rule 6 and §7.3 lifecycle row entries are consistent with this distinction.

No issues.

---

### ✅ Check 2 — `bounds {x, y, width, height}` — no remaining w/h abbreviations

**Clean.** All JSON object field names use the full `width`/`height` spelling:

- `Rect` schema: `required: ["x", "y", "width", "height"]` ✅
- `SurfaceViewport` schema: `required: ["width", "height", "scale"]` ✅
- `Viewport.contentSize`: `required: ["width", "height"]` ✅
- `annotations` register description: `bbox: {x,y,width,height}` ✅
- `surf_ace_read_buffer` params: `{ x, y, width, height }` ✅
- `surf_ace_list` returns: `viewport: { width, height, scale }` ✅

The only `w` / `h` abbreviations in the spec are in the §3.1 mDNS TXT key table (`w`, `h`, `s`) — these are intentional mDNS TXT record conventions (brevity is standard there) and are not JSON protocol field names. Correct as-is.

---

### ✅ Check 3 — `paired`/`takeover` prose consistency (§4.2, §6.0, schema)

**Clean.** All three locations are consistent.

| Location | Says |
|---|---|
| §4.2 Rule 4 | Same-provider + `takeover=true` → surface accepts new socket, closes old with `superseded`. |
| §6.0 Rule 2 | `paired: true` → `takeover=true` required, but only same `providerId` succeeds during grace; different provider gets `busy`. |
| Schema `SurfacesListResponse.surfaces[].paired` description | "pair.request requires takeover=true, but only same-provider takeover succeeds during grace. A different provider will receive busy." |
| §8.2 close code `1000 + superseded` | "Same-provider takeover accepted." |
| §11 hardening item 1 | "busy rejection for non-owner providers; explicit same-provider `takeover=true` closes stale socket." |

All five locations agree. §4.2 doesn't explicitly address the different-provider-takeover rejection case (it only defines what takeover IS), but §6.0 and the schema both supply the clarifying text. Not a contradiction — additive.

---

## Real Issues

### 🔴 Issue 1 — `event.navigation` fires alerts but CLU has no register to read the URL

**Severity: Real functional gap.**

`event.navigation` is part of `minimum_deep`, it fires the alert cycle (§13.3), and its primary payload is the new URL. When CLU receives the alert and calls `surf_ace_read`, the navigation URL is not available in any register.

**Where it breaks down:**

- §7.3 table: `event.navigation` — "Carries new URL; signals drawBuffer/annotations are stale."
- §13.2 registers: No `navigation`, `currentUrl`, or `lastNavigation` register is defined.
- §14.3 `surf_ace_read` returns: `taps`, `scrollPosition`, `selection`, `page`, `playbackPosition`, `playbackState`, `annotations` — no navigation URL.

**What CLU sees when navigation fires an alert:** dirty flag goes true, alert fires. CLU calls `surf_ace_read`. It observes that `annotations` is empty (evicted by §A.7 context switch) and all latest-wins registers are null. It does not know *what URL was navigated to* or *that navigation was the cause*.

§A.7 confirms that navigation creates a new context record keyed by the new URL, but this is internal provider state — the URL is never surfaced to CLU via any tool.

**Expected fix:** Add a `lastNavigation` (or `currentUrl`) register entry — e.g. `lastNavigation: { url: string, navigatedAt: epochMs } | null` — to `surf_ace_read` returns. Cleared on read (append-once semantics) or latest-wins. This is the missing piece that lets CLU decide whether to push replacement content or just observe.

---

### 🟡 Issue 2 — `surf_ace_read` selection field names don't match wire schema

**Severity: Implementor confusion / inconsistency.**

The `surf_ace_read` return format (§14.3) describes the selection register as:
```
selection: { selectedText, bounds, anchorStart?, anchorEnd? }
```

But the wire `Selection` schema (§10) for the `text` kind is:
```json
{ "kind": "text", "text": string, "boundingRect": Rect }
```

Mismatches:
1. `selectedText` (CLU tool) ≠ `text` (wire schema) — renamed without documentation.
2. `bounds` (CLU tool) ≠ `boundingRect` (wire schema) — renamed without documentation.
3. `anchorStart` / `anchorEnd` — not present in wire schema at all; origin undefined.
4. `kind` (discriminator) is dropped in the CLU tool layer representation without explanation.

The spec never documents that the CLU tool layer renames or transforms wire fields. An implementor reading both sections would not know how to map one to the other.

**Expected fix:** Either (a) align names between wire schema and CLU tool layer doc, or (b) add an explicit mapping note in §14.3 explaining that the CLU tool layer normalizes and enriches the wire payload, and document the field-by-field mapping.

---

### 🟡 Issue 3 — `surf_ace_read` taps return drops `kind` and renames `nearestContent`

**Severity: Information loss + implementor confusion.**

Wire `TapEvent` payload:
```json
{ contentId, revision, kind: "tap"|"long_press", position: {x,y}, nearestContent?: string }
```

`surf_ace_read` taps return per-entry:
```
{ eventId, timestamp, x, y, nearestText?, elementRole? }
```

Issues:
1. `kind` (tap vs long_press) is **dropped** — CLU cannot distinguish a long-press from a tap. Long-press has distinct semantic intent (context menu, emphasis, hold).
2. `nearestContent` (wire) → `nearestText` (CLU) — renamed without documentation.
3. `elementRole` — not present in wire schema; origin undefined (presumably DOM ARIA role, but not stated).

**Expected fix:** Add `kind` to the taps entry. Document the `nearestContent`→`nearestText` rename and the `elementRole` enrichment source in §14.3.

---

## Summary

| Check | Result |
|---|---|
| ProfileControlledEventType / activeEvents | ✅ Clean |
| bounds {x,y,width,height} — no w/h abbreviations | ✅ Clean |
| paired/takeover prose §4.2 / §6.0 / schema | ✅ Clean |
| Navigation URL register gap | 🔴 Real gap |
| selection field naming (wire vs CLU layer) | 🟡 Real inconsistency |
| taps field naming / kind dropped | 🟡 Real inconsistency |

**Three real issues. Spec should not be frozen until Issue 1 (navigation URL register) is resolved and Issues 2–3 are documented or corrected.**

The core wire protocol (§§3–11) is solid. Issues are confined to the §13–14 CLU tool surface layer (provider↔CLU seam). No contradictions found in the wire message contracts, schema types, or session lifecycle.
