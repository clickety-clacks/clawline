# Surf Ace Spec — Adversarial Consistency Review Pass 21 (§15 Surface UI Design)

**Date:** 2026-03-04  
**Reviewer:** CLU (subagent, pass21)  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
**Focus:** §15 Surface UI Design and its interactions with existing sections  
**Verdict:** ⚠️ REAL ISSUES (3 real, 4 nits)

---

## Summary

§15 is well-structured and mostly consistent with the rest of the spec. However, there are three real issues — two are genuine contradictions, one introduces an undefined term that implementors cannot satisfy from the wire protocol alone.

---

## Real Issues

### REAL-1: §15.1 introduces "session name" — undefined and unsourceable from wire protocol

**Location:** §15.1, Tab indicator section  
**Text:** "Each tab MUST display a short label. The label is derived from **the session name of the CLU session** that owns the tab, if available; otherwise a sequential number is used."

**Conflict:** §6.1.1 (tab.list response, TabCreatedEvent, TabListResponse) consistently says the tab label is "surface-assigned human-readable label **derived from sessionId**" — e.g., "Chat A", "Chat B." The surface only receives `sessionId` (format: `sa_<opaque>`). It has no access to a human-readable CLU session name (like "Engram", "Dictation", or "Chat").

"Session name" is a CLU-layer concept — the stream display name visible in the Clawline UI. The wire protocol does not deliver it. A surface implementor following §15.1 literally would have no way to obtain the "session name"; they'd need to derive a label from `sessionId` (which is what §6.1.1 already specifies).

**Impact:** Real — implementors following §15.1 will either be confused or inconsistent with §6.1.1. The surface's label-generation contract is defined in §6.1.1; §15.1 should defer to that rather than introduce a new sourcing concept.

**Fix:** Replace "derived from the session name of the CLU session that owns the tab, if available; otherwise a sequential number is used" with "the surface-assigned label for that tab (see §6.1.1 — derived from `sessionId`)."

---

### REAL-2: §15.4 Electron exit path omits vim-style toggle — contradicts §6.10

**Location:** §15.4, Electron section  
**Text:** "An 'Annotate' button MUST be persistently visible at all times. Tapping it enters annotation mode. A 'Done' button MUST appear while annotation mode is active; tapping it exits annotation mode."

**Conflict:** §6.10 explicitly states: "Tapping the button again (or Done) exits annotation mode. **This is vim-style (press once to enter, press again to exit)**."

§15.4's Electron section only lists the Done button as the exit mechanism. It doesn't say tapping Annotate again also exits. This directly contradicts §6.10's dual-exit model.

**Impact:** Real — an implementor following only §15.4 would build a broken exit UX on Electron. The surface would have no way to exit annotation mode without a separate Done button; the Annotate button would be inert while annotation is active.

**Fix:** Add to §15.4 Electron section: "Tapping the Annotate button a second time while annotation mode is active MUST also exit annotation mode (vim-style toggle). The Done button is an equivalent alternative exit path."

---

### REAL-3: §15.3 wrong cross-reference for tab switch events

**Location:** §15.3, Requirements, bullet 3  
**Text:** "When the active tab changes (including tab switch events **per §6.10**), the label MUST update immediately to reflect the owning session of the newly focused tab."

**Conflict:** §6.10 is the Annotation Mode section. It discusses what happens *during* annotation mode when a tab switch occurs (mode exits, strokes finalized). It is not the defining reference for tab switch events in general.

Tab switch events — `event.tab_focused` — are defined in §6.1.1 (Tab lifecycle events, "always-on, not profile-gated") and §3.1.1 Tab rule 7 ("User tab switching: the user can switch between tabs within a pane (browser-style UI on the surface). `event.tab_focused` fires when the user switches to a different tab.").

Referencing §6.10 here implies that tab switch events only matter during annotation mode — which is wrong. The indicator should update on any tab switch.

**Impact:** Real — implementors reading §15.3 might infer the active session indicator only changes during annotation mode tab switches, not all tab switches. The wrong reference is misleading.

**Fix:** Change "per §6.10" to "via `event.tab_focused`, see §6.1.1." Optionally note: "§6.10 describes the annotation mode exit behavior triggered by a tab switch, which is a specific case of the general tab switch event."

---

## Nits

### NIT-1: §4.5 still references dead-end tracking file instead of §15.2

**Location:** §4.5, Surface UI connectivity indicator paragraph  
**Text:** "Visual design TBD in separate UI spec (see tracking/surf-ace-ui-open-topics.md)"

**Issue:** `tracking/surf-ace-ui-open-topics.md` doesn't exist. §15.2 is now the normative UI spec for this indicator. The reference in §4.5 should be updated.

**Fix:** Replace "Visual design TBD in separate UI spec (see tracking/surf-ace-ui-open-topics.md)" with "Visual design is specified in §15.2."

---

### NIT-2: §3.1.1 (Naming system rule 6) also references the dead-end tracking file

**Location:** §3.1.1, Naming system rule 6  
**Text:** "Labels and names are displayed prominently on the surface — exact placement and visual style TBD in the separate UI spec (see tracking/surf-ace-ui-open-topics.md)."

**Issue:** Same as NIT-1. §15.1 now specifies placement and visibility requirements for window and pane labels.

**Fix:** Update to reference §15.1.

---

### NIT-3: §6.10 and §7.4 don't reference §15 (reverse cross-references missing)

**Location:** §6.10 header prose; §7.4  
- §6.10 says: "Visual design TBD in separate UI spec" (paraphrased — doesn't appear directly but the UI aspects defer)
- §7.4 says: "Surface must show a subtle visual send indicator while a drawing flush is in-flight to provider."

**Issue:** §7.4 defines the normative behavior but doesn't reference §15.5 where that requirement is formally presented to UI implementors. §15.5 correctly says "cross-referenced from §7.4" but the reverse link (§7.4 → §15.5) is absent.

**Fix:** Add "See §15.5 for the required UI treatment" to §7.4.

---

### NIT-4: §15.5 rules list has 4 items vs §7.4's 5 items — coverage gap on "subtle but noticeable"

**Location:** §15.5, Required behavior list  
**Issue:** §7.4 rule 4 says "Indicator must be subtle but noticeable (for example corner badge, pulsing icon, or brief overlay)." §15.5's required-behavior list has 4 rules but doesn't include this as a numbered rule — it appears only in the intro prose ("Examples of acceptable treatments: a small pulsing dot, a corner status chip, or a brief overlay"). Normative requirements embedded in prose can be missed.

**Fix:** Add a 5th numbered rule to §15.5: "5. The indicator MUST be subtle but noticeable — sufficient for the user to observe transmission activity without dominating the display."

---

## Checklist Results (per task)

| # | Question | Verdict |
|---|---|---|
| 1 | §15.4 vs §6.10 (annotation mode UI vs behavioral spec) | ⚠️ REAL — Electron exit path omits vim-style toggle (REAL-2) |
| 2 | §15.2 vs §4.5 (connectivity indicator) | ✅ Consistent in substance; NIT-1 (dead reference in §4.5) |
| 3 | §15.5 drawing flush indicator cross-references §7.4 | ✅ Cross-reference present; NIT-3/4 (reverse link missing, list count mismatch) |
| 4 | §15.3 active session indicator vs §3.1.1 / §2a tab model | ⚠️ REAL — wrong cross-reference §6.10 vs §6.1.1 (REAL-3); also REAL-1 (session name) |
| 5 | Normative statements in §15 conflicting with wire protocol | ⚠️ REAL — §15.1 "session name" unsourceable from wire (REAL-1) |
| 6 | Missing cross-references | NIT-1 (§4.5 → §15.2), NIT-2 (§3.1.1 → §15.1), NIT-3 (§7.4 → §15.5) |
| 7 | §15.1 tab bar vs §6.1.1 / §3.1.1 tab lifecycle | ✅ Consistent (single-tab hide rule not in conflict); session name issue covered in REAL-1 |

---

## Recommended Fix Priority

1. **REAL-2** first — clear behavioral contradiction that would cause broken Electron UX
2. **REAL-1** — terminology mismatch that would confuse implementors and cause label inconsistency across platforms
3. **REAL-3** — misleading cross-reference, lower risk but creates ambiguity about when indicator updates
4. **NITs** — housekeeping, batch into next pass
