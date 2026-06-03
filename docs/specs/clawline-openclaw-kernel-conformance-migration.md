# Clawline OpenClaw Kernel Conformance Migration

Date: 2026-05-28

## Purpose

Clawline should preserve its product behavior while conforming to current OpenClaw channel/runtime patterns wherever OpenClaw now has a canonical facility. Clawline code that was originally added to fill gaps in older OpenClaw versions is not an invariant. If upstream has since filled the gap, Clawline should migrate to that pattern rather than carrying bespoke runtime mechanics forward.

This document covers two tracks:

1. Migrate Clawline inbound turns to the current OpenClaw channel/messaging kernel.
2. Adopt adjacent upstream channel patterns so Clawline remains an extension/provider, not a parallel runtime.

Phase 1 is reliability-scoped. The goal is to make normal Clawline prompts reliable: quick acceptance, durable tracking, bounded execution, and explicit completion/failure instead of stalls, repeated error-outs, or infinite spinners. Any change that only improves architectural neatness without materially improving normal prompt reliability is out of scope for Phase 1.

## Problem

Clawline normal inbound user messages currently run through a custom provider path in `extensions/clawline/src/runtime/server.ts`.

Evidence from current TARS OpenClaw `f1ac4138ba9`:

- Normal WS message path starts at `processClientMessage` in `extensions/clawline/src/runtime/server.ts:8971`.
- It manually builds context with `finalizeInboundContext` at `server.ts:9191-9218`.
- It records inbound session manually at `server.ts:9220-9228`.
- It dispatches directly with `dispatchInboundMessage` at `server.ts:9394-9421`.
- The same lifecycle is duplicated for interactive callbacks at `server.ts:9749-10097`.
- The long agent run is awaited inside `runPerUserTask` at `server.ts:9052-9548`, so one long turn can hold the provider queue.

OpenClaw now has shared channel turn facilities:

- `PreparedChannelTurn` in `src/channels/turn/types.ts:365-381`.
- `runPreparedChannelTurn` / turn record-dispatch-cleanup in `src/channels/turn/kernel.ts:400-543`.
- Full `runChannelTurn` ingest/classify/preflight/resolve/finalize pipeline in `src/channels/turn/kernel.ts:545+`.
- Shared inbound context builder in `src/channels/inbound-event/context.ts:148-218`.
- Shared inbound media fact mapping in `src/channels/inbound-event/media.ts:43-96`.

The current shape means Clawline is partially bypassing current OpenClaw channel patterns.

## Product Intent

Clawline should be a first-class OpenClaw channel/provider with Clawline-specific UI edges.

OpenClaw should own common turn lifecycle mechanics. Clawline should own only the parts that are truly Clawline-specific:

- native/WebSocket client protocol
- device/session authentication and stream routing
- client ACK/dedupe/reconnect/replay semantics
- Clawline SQLite UI event persistence
- iOS-visible message IDs and reply references
- local asset storage/upload/download for native attachments
- socket delivery, bubbles, typing/progress presentation, and client no-delivery errors

Everything else should use the upstream pattern when one exists.

## Core Footprint Policy

Clawline should remain extension-homed. Phase 1 may add only the smallest generally useful plugin-SDK exports required for Clawline to use the canonical OpenClaw channel-turn path.

Allowed:

- export an existing generic channel/kernel helper through `openclaw/plugin-sdk/*`
- add a small SDK type or adapter surface that any provider could use
- update SDK entrypoint metadata/tests for that export

Not allowed:

- Clawline production code importing private `src/**` internals directly
- core behavior that is Clawline-specific rather than channel/provider-generic
- broad "export all internals" SDK changes
- core hooks that only exist to preserve an obsolete Clawline mechanism

If the needed seam cannot be expressed as a generic provider/channel SDK surface, stop and escalate instead of expanding Clawline's fork footprint.

Every new SDK export required by this work must have a review artifact in the implementation report:

- export name
- Clawline consumer
- generic provider/channel use case
- why the existing SDK surface is insufficient
- expected compatibility/stability contract
- proof that Clawline production code imports no private `src/**` core internals

Long-term direction: every non-extension Clawline carry should either disappear, become a generic upstreamable SDK/platform seam, or be explicitly justified as a product-level fork requirement. Moving Clawline to the channel kernel and public SDK seams is the path toward making Clawline installable as a separate extension package in a standard OpenClaw install, but that is not assumed until the surviving non-extension deltas are audited.

## Current Responsibility Classification

| Area | Classification | Current evidence | Decision |
|---|---|---|---|
| WS auth/session/routing/stream ACL | Clawline edge | `server.ts:8971-9048`, `9592-9660` | Keep in Clawline. |
| ACK/dedupe/client replay/socket delivery | Clawline edge | `server.ts:9058-9163`, `8080-8168`, `8171-8259`, `9501-9528` | Keep in Clawline. OpenClaw kernel does not provide these semantics. |
| Context construction | Should migrate | Clawline calls `finalizeInboundContext` directly at `server.ts:9191-9218`, `9749-9768`; shared builder exists at `src/channels/inbound-event/context.ts:148-218` | Use `buildChannelInboundEventContext`. |
| Turn lifecycle/record/dispatch/finalize | Should migrate | Clawline records and dispatches manually at `server.ts:9220-9548`, `9779-10097`; kernel exists at `src/channels/turn/kernel.ts` | Use `runChannelTurn` or prepared turn API. |
| Attachments/media storage | Keep mostly Clawline | Clawline validates/materializes inline images/assets and Pi images; shared media only maps facts to context | Keep asset storage/materialization, but feed canonical media facts into shared context. |
| Reply references / visible IDs | Keep resolver, map canonical fields | Clawline resolver in `message-reference-context.ts`; shared context has `ReplyToId*` and quote fields | Keep visible-ID resolution; emit canonical reply fields where possible. |
| Interactive callbacks | Mixed | Callback protocol is Clawline-specific, lifecycle duplicated | Keep callback protocol; migrate duplicated context/turn lifecycle. |
| Queue/lock/run lifecycle | Must change separately | `await runAgentDispatch()` occurs inside `runPerUserTask` | Kernel adoption alone is insufficient; split provider queue from long agent run. |

## Phase 1: Prompt Reliability Migration

### Phase 1 Decision

The Phase 1 target is a `runChannelTurn`-style Clawline adapter plus queue split.

Implementation should happen on the current `.27` upstream merge branch, not older main. The migration target is the latest upstream channel/kernel shape, so implementing against an older runtime risks preserving the wrong seams.

Do not spend a standalone phase on `runPreparedChannelTurn`. It is acceptable only as an internal stepping stone inside the same reliability migration if it helps reach the target safely. By itself, `runPreparedChannelTurn` does not address the product failure: normal Clawline prompts stalling or erroring.

Phase 1 is atomic. It is not acceptable to ship context migration, adapter extraction, or kernel wrapping without also shipping the reliability-critical queue split, terminal-state handling, cancel/control bypass, and quick ACK proof. If those reliability gates do not pass, Phase 1 has not landed.

The target is not "Clawline calls `dispatchInboundMessage` directly with slightly different options." The target is:

1. Clawline receives and validates the client event.
2. Clawline performs provider-edge work: dedupe, local DB persistence, ACK, UI broadcast, attachment ownership/materialization, visible-ID reference resolution.
3. Clawline builds canonical OpenClaw inbound context with `buildChannelInboundEventContext`.
4. Clawline runs the agent turn through an OpenClaw channel-turn adapter shaped like `runChannelTurn`.
5. Long agent execution runs outside the Clawline per-user provider queue.
6. Clawline delivery adapter persists assistant events and broadcasts them back to clients.

### Why This Is The Phase 1 Scope

The current reliability gap is in the normal Clawline prompt path:

- normal Clawline prompts use a custom WS provider path with bespoke context construction, record/dispatch/finalize logic, local UI bookkeeping, and a long-held per-user queue.
- other ingress paths have been observed to continue working during some Clawline prompt failures, which is useful evidence that the issue is specific to the normal prompt path, not proof that those other mechanisms should be copied.

Therefore the Phase 1 fix must directly improve normal prompt reliability. It should use the correct OpenClaw prompt/channel abstractions for this path. A shallow lifecycle wrapper that leaves the long provider queue and bespoke prompt path intact is not sufficient.

### Step 1: Replace Manual Context Construction

Replace direct `finalizeInboundContext` calls in the normal-message and callback paths with `buildChannelInboundEventContext`.

This step is required only as part of the prompt reliability migration. It is not independently sufficient reliability work and must not ship alone as Phase 1.

Required mapping:

- Clawline route/session facts map to `route`.
- Device/user facts map to `sender`.
- Message body, command body, raw body, and message IDs map to `message`.
- Clawline reply target maps to `reply`.
- Existing Clawline reference contexts map to `supplemental.quote` where possible and `supplemental.untrustedContext` where no canonical field exists.
- Materialized media paths/URLs/content types map to shared media facts.

Acceptance checks:

- Existing normal text prompt still reaches the intended session.
- Reply/reference prompt still includes LLM-visible reference context.
- Attachment/image prompt still delivers image input to the model.
- Generated context contains canonical `ReplyToId*`/media fields where applicable.

### Step 2: Extract A Clawline Turn Adapter

Extract the duplicated normal-message and interactive-callback dispatch lifecycle into one Clawline adapter.

The adapter should accept:

- prepared `ctxPayload`
- route/session key facts
- Clawline delivery callback
- active-run/progress callback hooks
- reply correlation facts
- image inputs
- record options such as `updateLastRoute`

The adapter should return a common result that Clawline can use to set local message streaming state.

Acceptance checks:

- Normal messages and interactive callbacks share the same lifecycle implementation.
- No double session recording.
- No skipped session recording.
- Existing callback behavior remains product-equivalent.

### Step 3: Use The OpenClaw Channel Turn Kernel

Use the real OpenClaw channel turn kernel, not a local imitation. The preferred target is `runChannelTurn` with explicit `ingest`, `classify`, `preflight`, `resolveTurn`, and `onFinalize` adapter stages.

If the implementation needs `runPreparedChannelTurn`, it must be justified in the implementation report as an internal compatibility seam inside this same reliability migration. The report must state which kernel stages are actually invoked, which Clawline prep remains outside the kernel, and why the remaining prepared-turn boundary is still safe.

Acceptance checks:

- Kernel log/result stages are visible for Clawline turns.
- Record/dispatch ordering is owned by the kernel.
- Pending-history cleanup happens through the kernel path.
- Dispatch failures surface consistently with other channels.
- Product result is better than current behavior: prompts are accepted quickly, do not spin forever, and finish as delivered, queued, canceled, or failed with a real error.

### Step 4: Split Provider Queue From Long Agent Run

This is required for the observed starvation/error class.

Current bad shape:

```text
runPerUserTask
  validate/dedupe/persist/ACK
  record inbound session
  await full agent dispatch
```

Target shape:

```text
runPerUserTask
  validate/dedupe/persist/ACK
  prepare turn request
release provider queue
run channel turn / agent dispatch
finalize Clawline local streaming state
```

The provider queue should serialize short critical sections: dedupe, local DB writes, ACK state, and local UI event creation. It should not serialize the entire model/tool/compaction run.

### Step 5: Lane Policy

Phase 1 should use a small lane model. The purpose is reliable prompt handling, not speculative prompt classification.

Provider/channel code owns ingress policy: which inbound events are prompts, controls, passive UI events, or interactive callbacks. The OpenClaw turn kernel owns lifecycle only after a turn is admitted.

Required Phase 1 lanes:

- **Prompt turn lane:** normal user prompts, including UI-related natural-language prompts such as Surf Ace requests when they require agent/model/tool interpretation. These are durable prompt-turn events.
- **Control lane:** cancel, stop, model/session controls, and other deterministic Clawline/provider commands. These must not wait behind prompt turns.
- **Local/passive lane:** reconnect, read state, stream tail, pairing, allowlist, and other provider-local state sync. These should not enter the model-turn queue.
- **Interactive callback lane:** if the callback triggers an agent turn, it should use the prompt-turn ordering policy; if it is purely local UI/provider action, it belongs in the control/local lane.

Prompt-turn policy:

- ACK/persist immediately after validation, dedupe, and durable local record.
- ACK means Clawline accepted responsibility for the client message. It does not mean the model run has started or will succeed.
- Execute model/agent turns serially per normalized Clawline stream/session key. Use the same resolved session key that determines where the prompt is persisted and replayed; do not key only by device or user.
- Allow different stream/session keys to run independently.
- Emit a separate running/progress signal when the model/tool turn actually starts.
- Every accepted prompt must eventually reach a terminal visible state: delivered, queued, canceled, or failed with a concrete error.
- If the model turn cannot be admitted after ACK because session recording, context construction, auth, or dispatch setup fails, finalize the already-persisted message as failed with that concrete error. Do not leave an accepted prompt in a transient streaming/running state.

Durable admission and run correlation:

- ACK is allowed only after a durable Clawline message row exists and the prompt-turn lane admission facts are durably reconstructable.
- Durable admission facts must include at least: device ID, client message ID, Clawline event/message row ID, normalized stream/session key, content hash, attachments hash, current prompt state, and a stable prompt-turn/run correlation ID.
- The prompt-turn/run correlation ID must be used in logs, active-run state, cancellation, terminal-state updates, and reconnect/replay recovery.
- If the process crashes after ACK but before model dispatch starts, recovery must be able to identify the accepted prompt and either resume from a durable queued/admitted state or mark it failed with a restart/recovery error.
- In-memory queues are acceptable only as execution accelerators. They are not the sole source of truth for accepted prompts.

Current dedupe shape to preserve:

- client message IDs must be strings beginning with `c_`
- dedupe key is `(deviceId, clientMessageId)`
- stored `contentHash` and `attachmentsHash` must match retry payloads
- duplicate retry with matching payload re-sends ACK and does not re-run the agent turn
- duplicate retry with mismatched payload is rejected
- retry of a message already marked failed is rejected unless a future explicit retry feature defines new semantics
- duplicate retry with matching payload must also replay or expose the current known local state for that message: accepted/queued/running, terminal failure, delivered assistant events, and any visible reply correlation available through normal reconnect/replay surfaces

State transition requirements:

- `accepted`: message is durably persisted and ACKed; it may be waiting in the prompt-turn lane.
- `running`: the model/tool turn has actually started; this is signaled separately from ACK.
- `delivered`: one or more assistant outputs were delivered or a queued final/follow-up was accepted by the runtime.
- `queued`: the runtime accepted the turn for later follow-up delivery; this is not an ambiguous spinner.
- `canceled`: user/system cancellation intentionally stopped a queued or active turn.
- `failed`: the accepted prompt cannot complete; the user-visible bubble carries a concrete error.

Valid state transitions:

| From | To | Meaning |
|---|---|---|
| new client message | accepted | validation, dedupe, durable local record, and ACK succeeded |
| accepted | queued | same-stream prompt turn is waiting behind an earlier prompt turn |
| accepted | running | no earlier same-stream turn is blocking and model/tool turn starts |
| queued | running | earlier same-stream turns finished and this turn starts |
| accepted | failed | post-ACK admission/setup failed before queueing/running |
| queued | canceled | control lane canceled the turn before start |
| queued | failed | queued turn can no longer be admitted after recovery/setup failure |
| running | delivered | assistant output/final delivery succeeded |
| running | queued | OpenClaw runtime accepted a queued final/follow-up for later delivery |
| running | canceled | active-run abort completed |
| running | failed | dispatch/tool/model/delivery failed with no successful final/queued outcome |
| delivered | failed | only if partial output was visible and the final state must reflect incomplete failure; implementation must preserve already-delivered content and show the failure |

Invalid transitions:

- `failed`, `canceled`, and `delivered` must not re-enter `running` without an explicit future retry feature.
- Duplicate retry of an existing prompt must not create a second turn or move terminal state backward.
- A prompt must not remain indefinitely in `accepted` or `running` without a durable active run, queued turn, or terminal state.

Crash/restart recovery:

- On provider startup or reconnect replay, any accepted/running Clawline prompt without a durable active run or terminal state must be reconciled.
- If the run cannot be proven active or queued in OpenClaw runtime state, mark the prompt failed with a restart/recovery error rather than leaving it spinning.
- This recovery rule applies only to Clawline local message state; it must not mutate model transcripts or invent assistant replies.

Control/cancel semantics:

- Control lane events must be admitted independently of the prompt-turn lane.
- Cancel/stop must be able to mark not-yet-started queued prompt turns canceled before they begin.
- Cancel/stop must be able to signal an active run through the existing active-run abort path.
- Cancel/stop failure must also reach a visible terminal state; it must not silently leave the prompt lane blocked.
- The prompt-turn runner must perform an atomic cancellation check at dequeue/start before moving `queued` to `running`.
- Active-run registration must happen before dispatch can produce model/tool side effects.
- Cancel racing with run start must have exactly one owner of the final state: either the queued turn is canceled before start, or the active run is registered and abortable.
- A failed cancel/stop control event must not block subsequent control events.

Context timing:

- Same-stream context for a prompt turn must be finalized inside the stream's model-turn lane immediately before session recording/dispatch, or refreshed there if a draft context was prepared earlier.
- A later same-stream prompt must not dispatch with context that omits an earlier same-stream turn's terminal assistant output or queued/failure state.
- Provider-edge validation, dedupe, local persistence, ACK, attachment ownership, and visible-ID resolution may occur before lane execution, but model-visible context must reflect the stream state at execution time.

Future classification:

- A local classifier, possibly Apple Foundation Models, may later classify prompt intent into scheduling lanes.
- This is out of Phase 1 unless needed for prompt reliability.
- Ambiguous classifications must stay in the normal prompt lane.
- Classification may affect scheduling/priority; it must not silently change prompt meaning.

Acceptance checks:

- A long turn in one Clawline stream does not block ACK/persist for unrelated prompts from the same user.
- Duplicate message handling remains deterministic.
- Duplicate retry while the original is accepted/queued/running re-sends ACK, does not re-run the turn, and exposes current local state through replay/status.
- Reconnect replay still sees correct local event ordering.
- Cancellation still finds and aborts the active run.
- Cancellation of a queued prompt exactly as it starts has deterministic final state.
- Same-stream prompt answers remain ordered.
- A later same-stream prompt builds or refreshes model-visible context after the prior same-stream turn reaches terminal/queued state.
- Control/local events do not wait behind long prompt turns.

## Migration Track 2: Adopt Upstream Patterns

This track is Phase 2 unless a specific item directly contributes to Phase 1 prompt reliability. The purpose is long-term conformance and lower merge drift, not a substitute for fixing the prompt reliability path.

### Context And Supplemental Facts

Clawline should stop manually recreating canonical context fields when OpenClaw provides a builder.

Adopt:

- `buildChannelInboundEventContext`
- shared `SupplementalContextFacts`
- canonical `ReplyToId`, `ReplyToIdFull`, `ReplyToBody`, `ReplyToSender`
- canonical media fields from `buildChannelInboundMediaPayload`

Keep:

- Clawline visible-ID lookup and DB/transcript bridging
- Clawline-specific untrusted structured context when no canonical field exists

### Media

OpenClaw shared media helpers do not replace Clawline's asset system. They only turn provider-owned media facts into canonical prompt context fields.

Keep in Clawline:

- inline base64 validation
- asset IDs and ownership checks
- SQLite asset records
- upload/download endpoints
- outbound media URL fetch/optimization
- Pi/OpenAI image input materialization

Adopt upstream pattern:

- after Clawline materializes/stores the media, express it as shared media facts for context construction.

### Reply References

OpenClaw has canonical context fields for quote/reply facts, but no canonical Clawline visible-ID resolver was found.

Keep in Clawline:

- resolving iOS/client-visible IDs to Clawline events
- any DB/transcript lookup required for those IDs

Adopt upstream pattern:

- feed resolved facts into `ReplyToId*`/quote fields when possible
- reserve `UntrustedStructuredContext` for extra Clawline-specific details only

### Delivery And Replay

OpenClaw kernel does not own Clawline client delivery semantics.

Keep in Clawline:

- ACK frame format
- error frame format
- reconnect replay / gap fill
- local message streaming state
- bubble/event persistence
- socket fanout

Do not try to force these into the kernel unless upstream grows an explicit channel delivery/replay abstraction.

### Queueing

OpenClaw has a shared keyed async queue helper, but the critical conformance issue is not the helper class. It is the lock scope.

Adopt the upstream lifecycle kernel for the turn. Independently reduce Clawline provider queue scope so long agent work is not held under the provider queue.

## Provenance

Relevant upstream/fork commits identified during code recon:

- `9a9cd0c0abd` — added shared channel turn kernel.
- `1ead1b2d181` — completed broad turn kernel migration.
- `ffe67e9cdc9` — routed inbound turns through the kernel.
- `2eee70e0a64` — ran prepared Discord and Slack turns; did not migrate Clawline.
- `5aefc9dda47` — centralized channel turn media facts.
- `07f05e972e2` — moved inbound event classification into core.
- `3bdaf4fa62e` / `c6a73fc87aa` — added Clawline-specific reference handling.
- `f1ac4138ba9` — fixed Clawline visible reply IDs.

No code or commit-message evidence was found that upstream intentionally excluded Clawline from the channel-turn migration. The current evidence supports a simpler conclusion: Clawline was carried as a provider-specific runtime while Discord/Slack were migrated to newer channel facilities.

## Review And Test Gates

### Phase 1 Success Criteria

Phase 1 is successful only if normal Clawline prompt reliability improves in product-visible ways:

- prompt ACK/persist is not blocked by a prior long model/tool/compaction turn
- same-stream prompt answers remain ordered
- unrelated stream/session keys can make progress independently
- control actions such as cancel/stop/model/session controls do not wait behind long prompt turns
- every accepted prompt reaches a visible terminal state: delivered, queued, canceled, or failed with a concrete error
- runtime logs show Clawline turns using OpenClaw channel-turn lifecycle stages
- Clawline production code does not import private `src/**` core internals
- any new SDK export is generic provider/channel surface, not Clawline-specific core behavior

Minimum test coverage for the migration:

- normal inbound text prompt
- duplicate client message ACK
- attachment/image input
- reply reference context
- interactive callback dispatch
- no-delivery error path
- cancellation of current run
- reconnect replay after ACK and after assistant delivery
- visible `replyToMessageId` / `replyToClientMessageId`
- model selection/status update during a turn

Runtime proof required before production deploy:

- Clawline client sends a prompt and receives ACK quickly.
- Model response is delivered.
- A second prompt can ACK while another long turn is in progress.
- Duplicate retry while the original is queued/running does not create a second model turn and replays or exposes current local state.
- A prompt that fails after ACK becomes a visible failed bubble with a concrete error.
- A queued same-stream prompt remains accepted/queued while a prior turn runs, then runs after the prior turn finishes.
- Cancel/stop can cancel a queued turn before it starts and can signal an active turn.
- Cancel/stop racing queued-turn start reaches exactly one terminal state.
- Partial assistant delivery followed by failure preserves delivered content and shows the final failure.
- Restart/reconnect does not leave accepted/running prompts spinning indefinitely.
- Logs show Clawline turn lifecycle using OpenClaw channel kernel stages.
- No duplicate session recording.
- No loss of Clawline replay or visible-ID behavior.

### Adversarial Review Prompts

An adversarial review should attack these questions directly:

- Does the proposed Phase 1 work actually reduce prompt stalls/error-outs, or is any step architecture-only?
- Does the queue split preserve ACK, dedupe, local persistence, replay, and visible message ordering?
- Does same-stream serialization prevent transcript/context races after ACK is decoupled from model execution?
- Can cancel/stop/control events bypass or interrupt prompt turns without corrupting active-run state?
- Does the design use correct prompt/channel abstractions rather than copying behavior from unrelated ingress paths?
- Are any proposed SDK exports generally useful provider/channel seams, or are they Clawline-specific core hooks in disguise?
- Are attachment/media and visible-ID reference behaviors preserved with tests rather than assumed?
- Does the implementation path keep Clawline extension-homed and reduce future merge drift?

## Upstream Merge Guidance Gap

The current `upstream-merge` skill already contains the right principle:

> Prefer Upstream Patterns. Use whatever integration model upstream uses now. Actively look for new patterns.

The problem is that the current verification steps are too broad and can be satisfied by nearby conflict resolution. The recent `rebase-reports/2026-05-28.md` did identify some upstream patterns around progress callbacks, model catalog visibility, gateway auth/session invalidation, and WebSocket handler behavior. It did not surface the channel-turn kernel or compare Clawline's inbound path against Discord/Slack after their migration.

That means the merge process did not fail in principle; it failed in execution depth. The report template allowed "new upstream patterns found" to become a passive list rather than a mandatory parity audit against equivalent upstream providers.

## Required Process Change For Future Upstream Recons

Every upstream merge/rebase recon involving Clawline provider behavior should add this explicit gate:

### Provider Pattern Parity Gate

For each OpenClaw-owned subsystem Clawline touches, identify the current upstream exemplar and compare Clawline against it.

Required comparisons:

- inbound message turn lifecycle: Discord/Slack/channel kernel
- context construction: `src/channels/inbound-event/*`
- media facts: `src/channels/inbound-event/media.ts`
- reply/reference facts: shared inbound context and reply-reference SDK
- gateway/WebSocket ingress: `chat.send` and WS handler paths
- session recording: channel turn kernel record stage
- dispatch/finalize/error semantics: channel turn kernel result shape
- queueing/cancellation/progress: current upstream channel/provider patterns

For every mismatch, classify it as:

- `adopt now`: upstream facility covers Clawline need
- `keep edge`: provider-specific behavior, no upstream equivalent
- `needs seam`: upstream facility almost covers it but needs a public SDK/export
- `blocked`: preserving Clawline behavior conflicts with upstream pattern

The report must include file/function evidence for each classification.

### Anti-Invariant Rule

Do not describe Clawline mechanisms as required merely because they exist today. For each carried Clawline mechanism, answer:

1. What product behavior does it preserve?
2. Does upstream now provide an equivalent or better abstraction?
3. If yes, why are we not adopting it in this merge?
4. If no, what would let us delete this mechanism later?

### Rebase Report Template Additions

Add these fields to future reports:

```markdown
## Provider Pattern Parity

| Clawline area | Upstream exemplar | Match? | Decision | Evidence |
|---|---|---:|---|---|

## Clawline Mechanisms Revalidated

| Mechanism | Product behavior | Upstream replacement checked | Decision |
|---|---|---|---|

## Upstream Patterns Adopted Or Deferred

| Pattern | Adopted now? | If deferred, why | Follow-up |
|---|---:|---|---|
```

## Implementation Handoff

Recommended implementation order:

1. Add/adjust tests around current Clawline inbound behavior before changing runtime structure.
2. Define durable prompt-turn admission, state transitions, run correlation ID, and recovery behavior.
3. Split the Clawline provider queue so long dispatch runs outside `runPerUserTask`; this is not optional for Phase 1.
4. Migrate context construction to `buildChannelInboundEventContext` as required by the kernel path.
5. Extract a shared Clawline turn adapter for normal messages and interactive callbacks.
6. Route the adapter through the OpenClaw channel turn kernel, preferring `runChannelTurn`; justify any internal prepared-turn seam by naming the kernel stages used and the Clawline prep that remains outside.
7. Reduce custom reference/media context once canonical fields prove sufficient.

Non-goals:

- Do not remove Clawline local DB, ACK, replay, or socket delivery semantics.
- Do not rewrite Clawline asset storage as part of the kernel migration.
- Do not change product-visible reply/reference behavior unless an acceptance test proves equivalence.
- Do not add new OpenClaw core hooks unless the upstream public SDK lacks a required seam and Flynn approves that divergence.

Open questions:

- none currently recorded after adversarial review updates; any implementation blocker discovered while coding must be added here before being resolved ad hoc
