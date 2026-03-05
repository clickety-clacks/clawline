# Surf Ace Protocol Spec — Adversarial Consistency Review, Pass 10

**Date:** 2026-03-03
**Reviewer:** Subagent (Pass 10 convergence gate)
**Source:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`
**Prior passes:** 1–9 applied

---

## ⬛ VERDICT: NITS ONLY

No real contradictions were found. The spec is internally consistent on all four targeted checks and across the full document. **The spec is frozen.**

---

## Targeted Checks

### Check 1 — `event.navigation` HTML-only scope rule: consistent in all relevant sections?

**Result: YES — with one minor nit in §7.3.**

The HTML-only constraint is stated clearly and consistently in every load-bearing place:

| Location | Statement |
|---|---|
| §7.1 (Minimum Deep Event Set) | Full authoritative statement: "Applies to `html` content type only. Surfaces MUST NOT emit `event.navigation` for any other content type (`pdf`, `image`, `markdown`, `terminal`, `canvas`, `video`). If the provider receives a NavigationEvent while a non-HTML content type is active, it MUST discard it silently." |
| §6.9 `canvas` characteristics | "Navigation events do not fire." |
| §6.9 `video` characteristics | "Navigation events do not fire." |
| §13.2 `lastNavigation` register | "**HTML only.** Most recent navigation away from CLU-pushed content." |
| §14.3 `surf_ace_read` return | "HTML only: { url, navigatedAt } of most recent navigation, or null." |

**Nit:** §7.3 (Event Audit table), `event.navigation` rationale column reads: "Surface navigated away from pushed content. Carries new URL; signals drawBuffer/annotations are stale." The HTML-only scope is not mentioned in the table's rationale. The constraint is fully stated in §7.1, so this is a missing cross-reference in a summary table, not a contradiction. No spec ambiguity results.

---

### Check 2 — Selection v1 `kind:text` constraint: §13.2 and §14.3 aligned?

**Result: YES — fully aligned.**

**§13.2** (selection register):
> "In v1, surfaces only emit `kind: "text"` selection events. If the provider receives a `kind: "point"` or `kind: "region"` selection from the wire, it MUST discard it and leave this register unchanged."

**§14.3** (`surf_ace_read` selection return):
> "CLU-layer mapping from wire SelectionEvent: wire `text` → `selectedText`; wire `boundingRect` (Rect) → `bounds`; wire `kind` discriminator dropped (always 'text' in v1 — see §13.2)."

§14.3 explicitly cross-references §13.2 and correctly reflects the v1-only-text constraint. Both sections are in agreement. ✅

**Minor nit:** §10 `Selection` schema for `kind: "text"` has `boundingRect` as an optional field (not in `required`). §14.3 maps it to `bounds` but doesn't specify what `bounds` is when `boundingRect` is absent from the wire payload (i.e., whether `bounds` becomes `null` or is omitted). Implementors would need to infer: omit if absent. Not a contradiction, but a small implementation gap.

---

### Check 3 — `lastNavigation.navigatedAt` + `taps.timestamp` ← wire `sentAt`: stated in all the right places?

**Result: PARTIAL — both mappings exist, but placement is asymmetric.**

#### `lastNavigation.navigatedAt` ← wire `NavigationEvent.sentAt`

| Location | Statement |
|---|---|
| §13.2 `lastNavigation` register | "`navigatedAt` maps from the wire `NavigationEvent` envelope `sentAt` field." ✅ |
| §14.3 `surf_ace_read` `lastNavigation` return | States `{ url, navigatedAt }` but does NOT mention the `sentAt` mapping. ❌ (omission) |

**Nit:** A developer reading only §14.3 won't know where `navigatedAt` is sourced. The mapping is authoritative in §13.2, so no ambiguity for a complete reader, but the field description in §14.3 is incomplete. Recommend adding a parenthetical: "`navigatedAt` from wire `sentAt`."

#### `taps.timestamp` ← wire `TapEvent.sentAt`

| Location | Statement |
|---|---|
| §14.3 `surf_ace_read` taps return | "`timestamp` maps from wire TapEvent envelope `sentAt`." ✅ |
| §13.2 `taps` register | Lists register purpose but does NOT mention the `sentAt` → `timestamp` mapping. ❌ (omission) |

**Nit:** The inverse gap — §14.3 has the mapping, §13.2 does not. Asymmetric with how `lastNavigation` is handled (§13.2 has it, §14.3 doesn't). Both are nits, not contradictions.

---

### Check 4 — Any remaining real contradictions anywhere in the full doc?

**Result: NONE FOUND.**

Full-document scan was performed. Findings:

1. **Revision mechanics** (§5.4 vs §6.2/6.3/6.4/6.5): All agree `revision == currentRevision + 1`. ✅
2. **Content.set clears strokes** (§6.2, §6.5, §11 item 14, §A.7): Unanimously stated. ✅
3. **Heartbeat priority** (§4.5, §11 item 16, §12 check 10): Consistent. ✅
4. **Profile-gated vs lifecycle events** (§7.1, §7.3, §4.6, `ProfileControlledEventType` schema): Lifecycle events correctly excluded from `activeEvents`; always-active status stated consistently. ✅
5. **`annotations` register is persistent / not cleared on read** (§13.2, §13.4, §14.3): All three sections agree `annotations` is not cleared on `surf_ace_read`. ✅
6. **`dirty` flag behavior** (§13.2 buffer state fields, §13.3, §13.4): Accumulation rules, alert gate, and read behavior all consistent. ✅
7. **`busy=1` semantics** (§4.2, §3.1 mDNS table, §6.0 `paired` field description, `SurfacesListResponse` schema `paired` description): All agree `busy=1` / `paired=true` means actively paired OR in resume grace, same-provider takeover only during grace. ✅
8. **`resumeGraceMs` default** (§4.4 grace window text vs `limits.resumeGraceMs` schema `default: 20000`): Consistent at 20s. ✅
9. **`idleWindowMs` and `maxIntervalMs` defaults** (§7.1 text, `DrawingFlushConfig` schema): 8000ms and 30000ms in both places. ✅
10. **Canvas/video in v1**: Both listed in `ContentType` schema enum; both get `unsupported_content_type` per §6.9 forward-compat note; §13.2 video registers are explicitly marked `null` in v1. ✅
11. **A.7 context dictionary v1 semantics**: "at most one entry" rule for v1, hard-clear invariant cross-referenced to §6.2 + §6.5. No contradiction with main body. ✅

**One additional nit found (not a contradiction):**

§13.2 `playbackPosition` and `playbackState` register descriptions do not individually state "Cleared on `surf_ace_read`" in their description text, unlike `scrollPosition`, `selection`, `page`, and `lastNavigation` which all include that note. They ARE Latest-wins and ARE covered by the general Latest-wins rule (which defines clear-on-read), but the omission creates an inconsistent description style. No semantic impact.

---

## Summary of Nits (Not Contradictions)

| # | Location | Nit |
|---|---|---|
| N1 | §7.3 event audit table | `event.navigation` rationale doesn't mention HTML-only scope |
| N2 | §14.3 `lastNavigation` return | Missing note that `navigatedAt` maps from wire `sentAt` |
| N3 | §13.2 `taps` register | Missing note that `timestamp` maps from wire `sentAt` |
| N4 | §14.3 `selection` return | No spec for `bounds` when wire `boundingRect` is absent |
| N5 | §13.2 `playbackPosition`/`playbackState` | Missing "Cleared on `surf_ace_read`" note (others have it) |

All five are cross-referencing gaps or style inconsistencies. None changes the meaning of the spec or introduces implementor ambiguity on load-bearing decisions.

---

## Conclusion

**The spec passes the convergence gate.** Passes 1–9 resolved all real contradictions. Pass 10 found zero new contradictions. Five nits remain; none warrant a re-draft. The protocol is consistent, implementable, and ready for use.

**Spec status: FROZEN.**
