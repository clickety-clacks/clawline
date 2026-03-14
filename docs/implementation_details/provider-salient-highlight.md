# Provider-Side Salient Highlighting — Non-Obvious Details

## Message delivery latency must be unaffected by model refinement — never await refinement in send path
The fast path (heuristic extraction) runs in-process and attaches baseline salience synchronously. The model-based refinement is async and best-effort. The send path must NEVER await model extraction. Refinement queue must be bounded and drop on overload. This is a hard non-negotiable invariant.

## Patch mechanism uses `events.payloadJson` update — replay naturally rehydrates latest salience
The async refinement result updates the stored `payloadJson` for the same event ID. Replay path (`sendReplay`) replays event JSON, so reconnecting clients automatically receive the latest salience state. No separate salience table is needed in v1. This is non-obvious — you'd expect salience state to live in its own table.

## Capability negotiation: patch events only to clients that declared `assistant_salience_v1`
Provider emits `message_salience` patch events only to clients that declared support in their capability token. Old clients receive messages without the `salience` field and continue to function. This is the required additive/backward-compatible rollout path.

## Substring-based highlights — NOT character offsets — because offset mapping is brittle
Provider sends `candidate.text` as an exact substring of message content, not character offsets. The client resolves exact ranges locally. Rationale: offset mapping breaks across markdown/link-processing transforms. The client owns the final rendered text and must resolve ranges there.

## Each `candidate.text` MUST be an exact substring of provider message `content`
This is a protocol invariant, not a recommendation. Candidates that are not exact substrings are invalid. The client will drop them (or produce wrong highlights) if they don't match.

## Second-pass extraction is preferred over asking the assistant to self-mark salience
Asking the assistant to format its own output with salience markers couples answer quality to the salience task, creates prompt pollution, and makes salience non-independently-versionable. The provider runs a separate extraction pass on already-delivered content.
