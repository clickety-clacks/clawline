APPROVED

This architecture is ticket-closure ready for the mapped T113 scope.

Why approved:
- T099 blocker is resolved with a concrete incomplete-cursor rule: canonical auth cursor = nil when any known stream lacks cursor, max only when all are present; active-session/global fallback explicitly forbidden.
- T100 is explicitly declared out of scope, removing ambiguity from architectural closure claims.
- T105 closure now requires compiler-verifiable zero direct writes outside seam, not just interface design.
- Phase ordering is coherent and non-circular for T113 closure: phase 1 (per-stream-state tickets) + phase 2 (message seam), with phase 3/4 correctly treated as separate hardening/adjacent work.

Minor notes:
1. Keep the T113 closure statement explicit: "T113 closes for mapped tickets; T100 pending separate Flynn decision."
2. Enforce the phase-2 compiler gate mechanically (private backing store + unavailable legacy APIs) before declaring T105 done.
3. In phase 1, ensure the callback-registry + forceReRead wiring are treated as required gates, not optional polish, since T095/T103 depend on them.
