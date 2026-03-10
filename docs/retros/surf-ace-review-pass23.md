# Surf Ace Spec — Pass 23 Consistency Review

**Date:** 2026-03-04  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
**Scope:** Post-pass-22 fix validation on four targeted issues  
**Verdict: NITS ONLY — spec is ready**

---

## Check 1: §6.10 Electron exit behavior vs §15.4 (toggle only, no Done)

**Result: ✅ Fully aligned.**

§6.10 (normative):
> *"Non-pencil platforms (Electron, non-pencil touch): An 'Annotate' button must be tapped to enter annotation mode; finger then draws strokes. Tapping the button again exits annotation mode. This is vim-style (press once to enter, press again to exit)…"*

§15.4 (UI):
> *"An 'Annotate' button MUST be persistently visible at all times. Tapping it toggles annotation mode on and off. There is no separate Done button on Electron — the Annotate button itself is the toggle."*

Both sections agree: toggle only, no Done button on Electron. No contradiction.

---

## Check 2: §6.1 prose field list includes providerName and matches §10 PairRequest schema

**Result: ✅ Fully aligned.**

§6.1 prose lists 9 `pair.request` fields:
1. `providerId`
2. `connectionId`
3. `surfaceId`
4. `resume`
5. `takeover`
6. `providerName` ← confirmed present
7. `eventProfile`
8. `drawingFlushConfig`
9. `protocolVersion`

§10 `PairRequest.payload` schema properties: `providerId`, `connectionId`, `surfaceId`, `providerName`, `protocolVersion`, `takeover`, `eventProfile`, `drawingFlushConfig`, `resume` — same 9 fields, no extras or omissions on either side.

Minor: §6.1 prose describes `resume` as "optional prior sessionId" (simplified). The schema models it as `{sessionId: SessionId}`. This is intentional prose summarization, not a contradiction.

---

## Check 3: No remaining real contradictions between §15 UI section and earlier normative sections

**Result: ✅ No real contradictions found.**

- §15.4 iPad subsection (Done button, auto-entry on pencil contact) matches §6.10 iPad prose exactly.
- §15.4 Electron subsection (toggle-only, no Done) matches §6.10 non-pencil prose exactly.
- §15.4 behavioral-constraints-while-in-annotation-mode block (scroll locked, link follow disabled, drawing layer active) matches §6.10 "When annotation mode is active" enumeration exactly.
- Tab switch behavior (exit on tab switch, strokes assigned to prior tab) is consistent between §6.10, §15.4's constraint-lifted note, and the duplicate at §6.1.1 rule 13.

**Nit:** §15.4's constraint-lifted sentence reads: *"lifted immediately upon exiting annotation mode (Done button or automatic exit on tab switch)."* The parenthetical says "Done button" without qualifying it as iPad-only. On Electron, exit is via toggle, not a Done button. This sentence is accurate for iPad but slightly imprecise for Electron. Because the platform-specific UI breakdown directly above this sentence already disambiguates, this is a prose nit, not a normative contradiction. A future pass could tighten it to: *"(Done button on iPad / Annotate toggle on Electron, or automatic exit on tab switch)."*

---

## Check 4: No schema/prose mismatch introduced by latest edits

**Result: ✅ No mismatches found.**

- `providerName` now appears in both §6.1 prose (item 6) and §10 `PairRequest` schema. Previously absent from prose; now consistent.
- No new schema fields were introduced without corresponding prose documentation.
- No schema fields were removed that are still referenced in prose.
- §15.x UI references to `providerName` (§15.2 tab label rule, §15.3 session name indicator) both correctly cite `pair.request` / §6.1, which now documents the field.

---

## Summary

| Check | Result |
|-------|--------|
| §6.10 / §15.4 Electron toggle alignment | ✅ Clean |
| §6.1 providerName in prose + schema match | ✅ Clean |
| §15 vs earlier normative contradictions | ✅ None (one nit) |
| Schema/prose mismatch from latest edits | ✅ None |

**Nits (non-blocking):**
1. §15.4 constraint-lifted parenthetical says "Done button" generically — could specify iPad-only vs Electron toggle. Very minor, context is clear from surrounding text.

**Verdict: NITS ONLY. Spec is internally consistent and ready for implementation.**
