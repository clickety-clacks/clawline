# Clawline Session Status + Control API Requirements

## Goal

Expose agent/session mode information from the OpenClaw/Clawline provider to Clawline clients, and provide typed control APIs so the UI can stop a running prompt and change mutable session settings such as model or reasoning level without sending magic slash-command text as normal chat input.

## Product intent

The client should be able to show “what mode am I talking to?” and provide safe controls for supported changes.

The UI should display available metadata, but only show controls when the provider says that capability is mutable for the current session/harness.

Slash commands may remain a human fallback, but the Clawline client should use typed provider control-plane APIs rather than sending `/stop`, `/model`, or similar as regular messages.

## Required status information

For each stream/session where available, provider should expose a compact status payload:

- session key / stream key
- busy/idle/running state
- current model
- fallback model(s), if available
- provider/backend/harness identity
- auth/source label if safe to expose
- reasoning/thinking level
- fast/normal mode
- verbosity/text detail mode, if available
- context usage / compaction count, if available
- current run started-at / elapsed, if available
- queue depth / pending alert count, if relevant
- approval/blocker state, if currently waiting on approval
- sandbox/elevated/tool availability summary, if safe and useful
- last error / cancellation state, if relevant

All fields should be nullable/optional. External or adopted sessions may expose partial metadata.

## Capability model

The status response must include a `capabilities` section so clients do not infer mutability.

Example capability flags:

- `canCancelCurrentRun`
- `canChangeModel`
- `canChangeReasoning`
- `canChangeFastMode`
- `canChangeVerbosity`
- `canResetModelDefault`
- `canCompact`
- `requiresRestartForFastMode`
- `readOnlyStatus`

If a control is unsupported for a session/harness, the UI should either hide it or render it disabled with a reason.

## Control actions

Provider should expose typed actions, ideally over the existing authenticated provider HTTP/WebSocket control plane:

- `GET /api/sessions/:sessionKey/status`
- `POST /api/sessions/:sessionKey/cancel`
- `POST /api/sessions/:sessionKey/model` with `{ model }`
- `POST /api/sessions/:sessionKey/reasoning` with `{ level }`
- `POST /api/sessions/:sessionKey/fast-mode` with `{ enabled }` if mutable
- `POST /api/sessions/:sessionKey/verbosity` with `{ level }` if available
- optional `POST /api/sessions/:sessionKey/reset-model-default`

Endpoint names may change to match provider routing conventions, but semantics should remain typed and structured.

## Why not slash-command text

Do not implement the client controls by sending ordinary chat messages like `/stop` or `/model`.

Reasons:

- stop/cancel must work while a prompt is running; chat input may not be processed until after the run finishes
- magic text pollutes transcript unless specially intercepted
- typed APIs return structured success/error/capability data
- UI can disable unsupported controls safely
- provider can apply authorization and audit logic consistently

Internally, provider may call the same handlers used by slash commands if those handlers already exist, but the external client contract should be typed control-plane actions.

## Events / updates

Provider should emit status updates when:

- run starts
- run stops/completes/errors/cancels
- model/reasoning/fast/verbosity changes
- capability set changes
- approval/blocker state changes
- context/compaction state materially changes

Client should not have to poll aggressively.

## Safety / permissions

- Only authenticated/authorized users can inspect or mutate a session.
- Mutations must be scoped to sessions the user can access.
- If a mutation affects billing/capability/safety posture, provider should return explicit confirmation/error metadata.
- Do not expose secrets, raw provider tokens, hidden prompts, or internal safety instructions.
- For adopted/external sessions, treat missing metadata as unknown, not false.

## Acceptance criteria

1. Client can request status for a visible session and receive a structured payload with model/reasoning/fast/busy metadata where available.
2. Client can determine which controls are available via capabilities.
3. Cancel action can stop an active run or return a clear unsupported/not-running response.
4. Model/reasoning changes either apply and emit updated status, or return a structured unsupported/requires-restart error.
5. No slash-command text is injected into the conversation for UI controls.
6. Existing chat sending and stream snapshots continue to work.
7. Tests or documented smoke cover at least one supported OpenClaw-managed session and one read-only/partial-metadata path.

## Open questions for implementation

- Which internal OpenClaw status/control APIs already exist behind `session_status`, `/model`, `/reasoning`, and cancellation?
- Is fast mode mutable at runtime for current runners, or only launch-time/resume-time?
- Should status be attached to stream snapshots, exposed separately, or both?
- What is the exact client route naming convention for provider APIs?
