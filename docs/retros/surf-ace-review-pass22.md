# Surf Ace Spec Review — Pass 22

**Date:** 2026-03-04  
**Reviewer:** CLU subagent (surf-ace-review-pass22)  
**Scope:** Post-pass-21 consistency check on four targeted items  
**Verdict:** ⚠️ REAL ISSUES (1 real issue, 1 nit)

---

## Checks Performed

### ✅ Check 1 — §15.1 Tab Label Sourcing

**Status: PASS (with nit)**

§15.1 correctly identifies `sessionId` as the primary label source and `providerName` (from `pair.request`, §6.1) as the preferred human-readable override. The JSON schema for `PairRequest` at §8 (schema block) confirms `providerName` is an optional wire field in `pair.request` payload.

**Nit:** `providerName` is present in the JSON schema but is **not listed in the §6.1 prose enumeration** of `pair.request` fields (which lists 8 fields: `providerId`, `connectionId`, `surfaceId`, `resume`, `takeover`, `eventProfile`, `drawingFlushConfig`, `protocolVersion`). The prose and schema are technically consistent — schema is normative — but a reader relying only on the §6.1 prose list will not know `providerName` exists as a valid field. Worth adding a note to §6.1's field list.

---

### ❌ Check 2 — §15.4 Electron Toggle vs §6.10

**Status: REAL ISSUE**

§15.4 (Electron subsection) correctly states:
> "There is no separate Done button on Electron — the Annotate button itself is the toggle."

However, §6.10 (non-pencil platform paragraph) was **not updated** and still reads:
> "Tapping the button again **(or Done)** exits annotation mode."

The parenthetical "(or Done)" in §6.10 implies a Done button may exist on Electron/non-pencil platforms — directly contradicting §15.4's normative statement that no Done button exists on Electron.

**Required fix:** Remove "(or Done)" from the §6.10 non-pencil paragraph. The corrected sentence should read:
> "Tapping the button again exits annotation mode."

This is the only entry/exit mechanism on Electron per §15.4's normative definition.

---

### ✅ Check 3 — §7.4 Reverse Link to §15.5

**Status: PASS**

§7.4 reads:
> "Surface must show a subtle visual send indicator while a drawing flush is in-flight to provider. See §15.5 for the required UI treatment of this indicator."

§15.5 reads:
> "See also §7.4, which defines the flush send timing requirements. This section cross-references that requirement for UI completeness."

Both cross-references are present, accurate, and symmetric. ✓

---

### Check 4 — No New Contradictions from Pass 21 Fixes

**Status: ONE CONTRADICTION FOUND**

The §6.10 "(or Done)" vs §15.4 "no Done on Electron" contradiction (documented above in Check 2) is the only inter-section conflict present. It was either introduced by the pass 21 §15.4 rewrite without updating §6.10, or was a pre-existing gap that §15.4's new normative language has now made visible. Either way, it requires resolution.

No other contradictions were introduced. §15.1's use of `providerName` is consistent with the JSON schema throughout. §15.3 (Active Session Indicator) also references `providerName` from `pair.request` and is internally consistent with §15.1.

---

## Summary

| Check | Result |
|---|---|
| §15.1 tab label sourcing (`sessionId` + optional `providerName`) | ✅ Pass (nit: §6.1 prose doesn't list `providerName`) |
| §15.4 Electron toggle matches §6.10 | ❌ Real issue: §6.10 still says "(or Done)" for Electron |
| §7.4 reverse link to §15.5 | ✅ Pass |
| No new contradictions | ❌ One contradiction (same as Check 2) |

## Required Actions

1. **§6.10** — Remove "(or Done)" from the non-pencil platforms paragraph. Electron exit is toggle-only; no Done button.

## Optional / Nit

1. **§6.1** — Add `providerName` (optional string) to the `pair.request` field enumeration in prose so it matches the JSON schema.
