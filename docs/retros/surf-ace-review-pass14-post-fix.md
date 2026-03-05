# Surf Ace Spec Adversarial Consistency Check — Pass 14 Post-Fix

Spec reviewed: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`  
Review scope: targeted re-check of five repaired areas from pass 13.

## Verdict

**REAL ISSUES** (1)

Most repaired items are now internally consistent; one material inconsistency remains in selection semantics across normative sections.

## Findings

1. **Selection contract conflict between normative buffer rules and CLU read contract**  
   - **Refs:** §7.1 (`event.selection` is in `minimum_deep`, v1 guarantees `kind:"text"`; `point`/`region` reserved), schema `$defs.Selection` in §10 (allows `text|point|region|null` with v1 ignore guidance for `point/region`), §13.2 Non-Annotation Registers (`selection` register stores current text selection; MUST discard only `point/region`), §14.3 `surf_ace_read` returns (`selection ... Non-HTML: always null`).  
   - **Issue:** §13.2 defines filtering by **selection kind** (discard only `point/region`), while §14.3 adds filtering by **content type** (`Non-HTML: always null`) that is not stated in §7.1 or §13.2. That creates a normative mismatch in what the provider should expose for e.g. non-HTML text selections.  
   - **Why it matters:** Implementers can make opposite choices and still believe they conform, causing interoperability drift in `surf_ace_read.selection` behavior.

## Area-by-area re-check (requested 5 repairs)

- **(1) §2.3 phase-gating vs §§13–14 semantics:** **Pass (no issue).** Current wording now cleanly separates architecture normativity from release/priority gating.
- **(2) Appendix numbering/status conflict (A.10/A.11):** **Pass.** Duplicate A.10 conflict resolved; A.11 is distinct and status text is coherent.
- **(3) Surface/Endpoint terminology in §2a + multi-window identity:** **Pass.** Definitions align with §3.1.1 window-scoped `surfaceId` and endpoint-scoped host:port.
- **(4) Selection semantics across §7.1/schema/§13.2/§14.3:** **Fail (Finding #1).**
- **(5) Flush-gate stale cross-reference now pointing to §7.1:** **Pass.** Cross-refs now point to §7.1 where checked (notably §13.2 note and Appendix transport note).

## Recommended minimal fix

In §14.3 `surf_ace_read` selection return contract, replace or qualify **"Non-HTML: always null"** so it matches §13.2’s kind-based rule (v1 accepts `kind:"text"`, discards only `point/region` unless negotiated), or explicitly add the non-HTML null rule to §7.1 + §13.2 if that stricter behavior is intended.