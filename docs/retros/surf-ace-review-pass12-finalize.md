# Surf Ace Spec Consistency Review — Pass 12 (Finalize/Flush Focus)

Result: **NITS ONLY**

Reviewed deltas for consistency against existing flush-gate transport rules:
1. §13.2 lifecycle now finalizes on `content.set`/`content.clear`.
2. A.8 renamed to “No forced frame finalization” with transport flush note.
3. §13.4 backlog policy now uses `liveSeq` quiescent heuristic (1000ms).

## Findings

No normative contradictions found between frame-finalization semantics and Section 4 flush-gate transport semantics. The split remains coherent:
- **Frame finalization boundaries** are governed by §13.2/A.8 (context switch, `content.set`, `content.clear`; no timeout/size-based forced finalization).
- **`event.drawing_flush` send cadence** remains governed by Section 4 (`idleWindowMs` / `maxIntervalMs`).
- **Backlog draining** in §13.4 is a model-side processing heuristic (`liveSeq` quiescence), not a transport or finalization trigger.

## Nit (terminology collision)

- In A.4, the sentence at the “With context-keyed frames” paragraph says: “...context-switch boundary, **or whichever flush policy is selected in A.8**...”.
- Since A.8 now explicitly specifies **no forced frame finalization** (and is not a flush policy section), this wording is stale/ambiguous.
- Suggested wording: “...context-switch boundary, or whichever **frame-finalization policy/boundary** is selected in A.8...”.

Everything else in the targeted sections is internally consistent.