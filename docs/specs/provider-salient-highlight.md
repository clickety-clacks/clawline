# Provider-Side Salient Highlighting (#72)

Status: Draft
Last updated: 2026-02-11
Source issue: clickety-clacks/clawline#72

## 1. Goal

Apply salient highlighting to assistant messages on the provider before delivery so users can quickly scan long responses for:
- key decisions
- direct answers
- important facts/constraints
- actionable items

This is server-side for Clawline assistant output and must not delay message delivery.

## 2. Non-Goals (v1)

1. No inline text rewriting of assistant content.
2. No provider-side markdown mutation (no inserting `**`/`_` markers).
3. No change to existing salience colors or client visual style rules.
4. No hard dependency on model availability for message send.
5. No requirement that highlights are stable across model/prompt version changes.

## 3. Current Provider Reality (Code References)

The current Clawline provider flow is the baseline this spec extends:

1. Assistant messages are produced in two paths:
- Agent reply path: `createReplyDispatcherWithTyping(... deliver ...)` -> `persistAssistantMessage(...)` -> `broadcastToSessionKey(...)` in `src/clawline/server.ts:3635`, `src/clawline/server.ts:3673`, `src/clawline/server.ts:3680`.
- Outbound/API path: `sendOutboundMessage(...)` builds assistant `ServerMessage`, appends event, broadcasts in `src/clawline/server.ts:3257`, `src/clawline/server.ts:3353`, `src/clawline/server.ts:3368`.

2. Message protocol shape is defined by `ServerMessage` in `src/clawline/server.ts:629`.
- Current fields: `type/id/role/sender/content/timestamp/streaming/sessionKey/attachments/deviceId`.
- No salience-specific field exists.

3. Protocol transport is WebSocket `/ws` with message types `pair_request`, `auth`, `message`, `interactive-callback` in `src/clawline/server.ts:4317` and `src/clawline/server.ts:4342`.

4. Session bootstrap and replay:
- `auth_result` + replay + `session_info` in `src/clawline/server.ts:2989`, `src/clawline/server.ts:3011`, `src/clawline/server.ts:1044`.
- Events are stored as raw JSON (`events.payloadJson`) and replayed via `parseServerMessage(...)` in `src/clawline/server.ts:1193`, `src/clawline/server.ts:1393`, `src/clawline/server.ts:956`.

5. Provider already has a generic realtime event envelope (`type: "event"`) used for activity signals, proving a patch channel exists in current protocol in `src/clawline/server.ts:3625` and `src/clawline/server.ts:4001`.

## 4. Requirements

1. Do not delay assistant message delivery for salience generation.
2. Keep message content unchanged.
3. Preserve replay correctness across reconnects.
4. Be backward-compatible with old clients.
5. Keep provider CPU and model spend bounded.

## 5. Design

### 5.1 Out-of-Band Metadata (No Inline Markup)

Salience must be attached as metadata, not injected into message text.

Rationale:
- avoids markdown corruption
- keeps copy/paste exact
- avoids prompt/style side effects
- keeps protocol additive

Proposed additive field on assistant `ServerMessage`:

```ts
type SalienceKind = "decision" | "answer" | "fact" | "action";
type SalienceTier = "primary" | "secondary";

type ServerSalience = {
  version: number;
  algorithmVersion: number;
  generatedAt: number;
  source: "heuristic" | "model" | "hybrid";
  candidates: Array<{
    text: string;
    kind: SalienceKind;
    tier: SalienceTier;
    confidence?: number;
  }>;
};

// additive extension
salience?: ServerSalience;
```

Notes:
- Provider remains source of truth for assistant salience metadata.
- Client applies existing color palette only (dark amber and light rust), no bold/italic mutation.

### 5.2 Substring-Based Highlights (No Provider Offsets)

Provider sends substring candidates, not character offsets.

Rationale:
- offset mapping is brittle across rendering transforms
- client already owns final rendered text and should resolve exact ranges there
- robust against markdown/link-processing differences

Rules:
1. Each `candidate.text` MUST be an exact substring of provider message `content`.
2. Candidate length SHOULD be short (phrase-level).
3. Duplicate candidates SHOULD be deduped provider-side.
4. Client resolves to rendered ranges and applies color styling.

### 5.3 Hybrid Delivery (Fast + Async Refinement)

Delivery is two-phase to satisfy latency constraints:

1. Fast path (in-band, zero additional roundtrip):
- run cheap deterministic extraction in-process
- attach baseline salience immediately on initial assistant message

2. Async refinement (best effort):
- enqueue model-based extraction with strict timeout/budget
- if improved result is produced, emit a patch event and persist updated payload

Latency guardrails:
- message send path MUST NOT await model extraction
- refinement queue must be bounded and drop on overload

### 5.4 Patch Mechanism for Post-Hoc Updates

Use protocol event envelope for salience updates:

```json
{
  "type": "event",
  "event": "message_salience",
  "payload": {
    "messageId": "s_...",
    "sessionKey": "agent:main:clawline:<user>:main",
    "salience": { "version": 1, "algorithmVersion": 1, "source": "model", "generatedAt": 0, "candidates": [] }
  }
}
```

Behavior:
1. If client receives `message_salience`, it updates that bubble's salience state.
2. Provider persists refined salience by updating `events.payloadJson` for the same message id so replay returns latest salience.
3. If patch delivery fails, message still remains valid (best effort).

### 5.5 Streaming Considerations

Current Clawline assistant events are persisted/sent with `streaming: false` for assistant outputs (`src/clawline/server.ts:3248`, `src/clawline/server.ts:3360`).

Design implications:
1. v1 salience is generated per delivered assistant message bubble.
2. For future streaming assistant chunks, salience generation should trigger only on final chunk (or post-final merge), not per token/chunk.
3. Tool/block/final dispatcher kinds already exist (`src/auto-reply/reply/reply-dispatcher.ts:8`); final responses are the primary salience target.

### 5.6 Second-Pass Extraction (Not Self-Highlight in Model Output)

Prefer a second-pass extractor over asking the assistant to self-mark salient text in its response.

Rationale:
- decouples answer quality from salience task
- avoids prompt pollution and fragile formatting instructions
- makes salience independently versionable

Proposed extraction modes:
1. `heuristic` only (fallback)
2. `model` only (if explicitly enabled)
3. `hybrid` (default): heuristics now, model refinement later

Operational safeguards:
- strict timeout per refinement task
- max in-flight tasks
- per-user/task queue depth cap
- drop/skip behavior when overloaded

### 5.7 Capability Rollout and Backward Compatibility

Rollout must be explicit and additive:

1. Introduce client capability token: `assistant_salience_v1`.
2. Provider advertises support in `auth_result.features` (currently `features: ["session_info"]` at `src/clawline/server.ts:2998`) by appending `assistant_salience_v1` when enabled.
3. Provider emits `message_salience` patch events only to capability-matching clients.
4. Optional: include `salience` inline field on `message` only for capability-matching clients in phase 1; later make unconditional once all clients are tolerant.

Compatibility principle:
- Unknown fields/events must be ignorable; assistant message rendering must still work without salience.

## 6. Data Lifecycle and Persistence

1. Initial assistant event is appended via existing event insert transaction.
2. If refinement result differs materially, provider updates stored `payloadJson` for that event id.
3. Replay path (`sendReplay`) naturally rehydrates latest salience because it replays event JSON.

This preserves reconnect consistency without a separate salience table in v1.

## 7. Error Handling and Degradation

1. If salience generation fails, send message without salience.
2. If refinement fails or times out, keep baseline salience (or none).
3. If patch broadcast fails, do not retry indefinitely; rely on persisted replay state.
4. If capability unknown, do not send patch event unless client declared support.

## 8. Security and Privacy Notes

1. Salience extraction runs on assistant output already destined for client.
2. No additional user-visible content is introduced; only metadata.
3. Provider logs should avoid raw content in salience debug lines by default.

## 9. Implementation Plan (High-Level)

1. Extend `ServerMessage` with optional `salience` in `src/clawline/server.ts`.
2. Add salience extractor service interface (heuristic + optional model refinement).
3. Call fast extractor in both assistant creation paths:
- `persistAssistantMessage(...)` call site in reply dispatcher deliver path
- `sendOutboundMessage(...)` path
4. Add `message_salience` event emission helper using existing `sendJson(...)` event channel.
5. Add persistence update routine for refined salience (`events.payloadJson` by message id).
6. Add capability negotiation wiring in auth/result features.
7. Add tests for:
- baseline inline salience inclusion
- no-delay behavior when model refinement stalls
- patch event delivery and replay persistence
- capability-gated behavior

## 10. Open Questions

1. Should initial fast-path salience be sent inline on `message` for all clients or only capability-gated clients during migration?
2. What exact material-change threshold should trigger a patch (candidate set diff, confidence delta, or both)?
3. Should refinement run for outbound manual sends (`sendOutboundMessage`) by default, or only agent-generated replies?

## 11. Acceptance Criteria

1. Assistant messages can carry salience metadata without content mutation.
2. Message delivery latency is unaffected by model refinement availability.
3. Clients can update salience post-hoc via protocol patch event.
4. Replay after reconnect returns latest salience state.
5. Old clients continue functioning without protocol breakage.
