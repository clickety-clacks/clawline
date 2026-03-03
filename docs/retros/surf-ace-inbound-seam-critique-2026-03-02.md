# Surf Ace Inbound Seam Critique (2026-03-02)

## Context
This critique explains why the `surf-ace-manual-register` integration can stall Clawline message dispatch, and how to redesign the seam.

## What the branch currently does
In the branch implementation, inbound Clawline message handling calls `surfAceManager.buildContextInjection(...)` inside the message processing path before `agent_run_start`.

`buildContextInjection` iterates discovered/paired screens and performs live `/snapshot` network calls to gather current screen context.

## Why this is risky
1. Optional feature work is placed in the core inbound critical path.
2. A live network dependency is introduced before dispatch state finalization.
3. When this path fails/hangs, messages can be persisted+acked but not advanced to completion, leaving `ackSent=1, streaming=1` rows.
4. A single stuck head item can poison subsequent inbound progression on that per-stream queue.

## Observed failure signature
- Inbound logs show `inbound message routing`.
- No corresponding `agent_run_start` for that message.
- DB row remains `ackSent=1, streaming=1`.
- Gateway/ports remain healthy, so transport appears fine while dispatch is stalled.

## Architectural critique
This integration behaves like a patch at the wrong layer. The feature is valuable, but the seam is too invasive:
- It couples Clawline admission/dispatch correctness to Surf Ace liveness.
- It makes incident diagnosis harder because optional context collection can block core execution.

## Recommended seam
1. Add a formal "inbound context enricher" extension interface with strict contract:
   - bounded timeout,
   - fail-open behavior,
   - never allowed to block finalization.
2. Move Surf Ace snapshot collection to background cache refresh.
3. Inbound path reads cache only (no live network I/O).
4. Keep ack/finalization lifecycle owned by core Clawline path regardless of enricher outcome.

## Practical policy
- "No live network awaits in inbound critical path" for optional enrichers.
- Any enricher failure must degrade context quality, not delivery correctness.

## Bottom line
The problem is not that Surf Ace exists; the problem is where and how it is wired. The seam should isolate optional context from core message lifecycle.
