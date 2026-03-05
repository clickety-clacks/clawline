# Surf Ace review pass 11 — dual ordering consistency check

Scope reviewed:
- §13.3/§13.4 processing-order and alert-gate edits
- §14.3 `surf_ace_read` read-priority + dedupe contract
- A.8 resolved no-forced-flush rules

## Verdict
Mostly coherent, but there are **3 consistency gaps** worth fixing before treating this as closed.

## Findings

### 1) Terminology collision: “no forced flush” (A.8) vs existing forced `event.drawing_flush` cadence (Section 4)
**Where:** A.8 (“No forced flush”), plus earlier flush-gate language (`idleWindowMs` + `maxIntervalMs`, including forced 30s send).

**Issue:** In current wording, “no forced flush” reads like it contradicts the already-specified forced flush-send cadence. A.8 is clearly about **frame finalization**, not transport flush emission, but that distinction is not explicit enough and can be misread as undoing Section 4 behavior.

**Risk:** Implementers may disable max-interval send flushes unintentionally, or reviewers may assume the spec is internally inconsistent.

**Suggested fix:** Rename/clarify A.8 to “No forced frame finalization” and explicitly state: drawing transport flush cadence remains governed by Section 4.

---

### 2) Finalization trigger drift between §13.2 lifecycle and A.8 rule 4
**Where:** §13.2 lifecycle step 4 vs A.8 rule 4.

**Issue:**
- §13.2 lifecycle says prior frame is finalized when annotation starts in a different context.
- A.8 adds explicit finalization on `content.set`/`content.clear`.

These are compatible, but §13.2 never incorporates the `content.set`/`content.clear` trigger, so the core lifecycle and the resolved appendix are now slightly out of sync.

**Risk:** Different readers will treat A.8 as either normative override or non-authoritative note, yielding divergent implementations.

**Suggested fix:** Promote A.8 rule 4 into §13.2 lifecycle text (or cross-reference A.8 inline) so the normative lifecycle has one complete trigger list.

---

### 3) Read-priority policy depends on undefined “idle window” at CLU side
**Where:** §13.4 model processing order policy (“Backlog drains in idle windows”).

**Issue:** “idle windows” is implementation guidance but has no operational definition (time-based, turn-based, queue-depth-based, or user-interaction-based).

**Risk:** Significant behavioral variance across CLU implementations; some may starve backlog, others may over-drain and hurt live responsiveness.

**Suggested fix:** Add a minimal normative heuristic (example: “drain up to N closed frames only when no new `liveSeq` increment has been observed for T ms, then re-check live first”).

---

## What is consistent
- §13.4 and §14.3 align on live-first, backlog-second, and pause-backlog-on-new-live.
- Dedupe guidance is materially consistent across both sections (`strokeId` with frame/context scoping).
- Alert-gate reset on read is consistent with dual-channel unread-burst semantics.

## Bottom line
The dual-channel ordering model is directionally solid; tighten the three wording/contract gaps above to prevent implementer divergence.