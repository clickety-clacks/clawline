# Same-Stream Dispatch Serialization Retro

## Symptom

TARS logs showed two Clawline prompts entering the same stream close together. The first, longer prompt started an agent run at `12:36:21`; a second 5-character prompt started another run at `12:36:57` before the first run ended. The second run produced substantive assistant output first, while the first run ended with only a 6-character assistant delivery.

## What Was Tangled

The per-stream task queue was tested in isolation and correctly serialized tasks with the same `streamKey`. The server message path, however, only used that queue for message setup. It built a `runAgentDispatch` closure inside the queue and then executed the actual model dispatch after the queue had released.

That made the apparent invariant misleading: setup was serialized, but the full user-prompt lifecycle was not.

## Boundary Fix

The authoritative stream-ordering boundary should cover the complete inbound prompt lifecycle: validation after stream resolution, persistence, session recording, model dispatch, reply delivery, and final message state update. The fix keeps agent dispatch inside the same per-stream queue scope.

## Regression Coverage

The regression test uses the production WebSocket server path, not only the queue helper. It blocks the first same-stream dispatch, sends a second message, and asserts that the second dispatch does not start until the first reply is released.

## Follow-Up

If ack latency becomes a product concern for queued same-stream prompts, design a separate explicit "queued locally" client state. Do not regain responsiveness by persisting or dispatching later same-stream prompts before earlier runs have finalized.
