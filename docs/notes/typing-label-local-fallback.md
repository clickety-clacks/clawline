# Work item — typing-indicator label: local "Thinking…" fallback

Filed 2026-07-25 (client-e2e run 0e40b93 evidence). Client-side item; tightbeam needs
nothing.

## The finding

On non-tool turns, claude-agent-acp (claude-sonnet-5[medium]) emits NO
`agent_thought_chunk`, so the gateway forwards no `agent_progress` label — by design:
the substrate maps harness-reported events and fabricates nothing. The typing INDICATOR
frames (`typing active=true/false`) arrive correctly and unconditionally; only the
label text is absent. Result: the user sees an unlabeled typing indicator for ordinary
conversational turns. SMOKE step 3 was amended to match (indicator = invariant, label =
harness-reported best-effort; CAP-012 scope).

## The work

Presentation fallback is the CLIENT's call (substrate/product boundary): while the
typing indicator is active and no `agent_progress` label has arrived this turn, render
a local default ("Thinking…"). First harness-reported label replaces it; label clears
with the indicator. One view-level change + a test driving indicator-without-label.

## Why client-side

The substrate exposing neutral truth means it must not invent "Thinking…" when no
thought event exists. Whether an unlabeled indicator is acceptable UX is a product
decision — this note implements the friendly default without corrupting the wire's
honesty.
