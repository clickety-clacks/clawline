# TARS Clawline Smoke Runbook

Use this runbook when validating OpenClaw/Clawline provider changes on TARS or a TARS-like branch-deploy host. It consolidates the live checks we have been doing manually: deploy health, prompt roundtrip, `/alert` targeting, session-key routing, replay/memory-pressure indicators, and log review.

This runbook intentionally does not cover external channel or VM smoke lanes.

## Scope

This is a smoke runbook, not a full release gate.

It should prove:

- the intended OpenClaw checkout is the running gateway checkout,
- the gateway and Clawline provider are reachable,
- live model/auth state can produce a real assistant reply,
- Clawline prompt sends and replies land in the correct session,
- `/alert` wakes the exact existing session key it targets,
- alert replies appear in the targeted stream and not the currently visible or most recently used stream,
- replay, stale-socket, and alert lookup behavior match the memory-pressure fixes,
- logs do not show regressions such as gateway restarts, zombie reconnect exceptions, repeated alert timeouts, or runaway replay sends.

## Safety Rules

- Start host work by running `hostname`; do not treat local output as evidence about TARS unless the hostname is TARS.
- Use `~/openclaw` for TARS deploy/runtime checks.
- For branch deploys, check out the branch directly in `~/openclaw`; do not merge or cherry-pick it into TARS `main`.
- Do not edit, regenerate, bootstrap, or reinstall TARS LaunchAgents/plists as part of smoke testing.
- Do not delete, truncate, reset, or destructively modify anything under `~/.openclaw/` unless Flynn explicitly authorizes that exact action.
- If auth is stale, sync the current logged-in CLI token into the active OpenClaw auth store using the credential-sync runbook. Do not invent a new token shape.

## 1. Local Code Gate

Run these before deploying a branch or declaring a local ref ready for live smoke:

```bash
pnpm test extensions/clawline/src/runtime/server.test.ts
pnpm check
```

For memory-pressure/refactor work, the Clawline runtime test file must cover:

- per-stream replay selection, with a busy stream unable to crowd out quiet streams,
- stable replay ordering after per-stream selection,
- aborting replay after the first failed socket send,
- removing or ignoring stale sockets after failed sends,
- `/alert` routing to main, native Clawline streams, and existing non-Clawline session-store keys,
- rejecting malformed or missing session keys without enqueueing,
- no fallback to the current or last-used route when an alert targets a specific session key.

## 2. Deploy Health

On the host being tested:

```bash
hostname
cd ~/openclaw
git status -sb
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
```

For a branch deploy, follow the TARS branch-deploy policy:

```bash
git fetch origin --prune
git status -sb
git checkout <branch>
git pull --ff-only origin <branch>
pnpm install --frozen-lockfile
pnpm build
pnpm openclaw gateway restart
```

For a main deploy, follow the main TARS deploy workflow for the currently intended OpenClaw/Clawline runtime.

Verify listeners and provider health:

```bash
lsof -nP -iTCP:18789 -sTCP:LISTEN
lsof -nP -iTCP:18800 -sTCP:LISTEN
curl -sf http://127.0.0.1:18789/health
echo
curl -sf http://127.0.0.1:18800/version
```

Success criteria:

- one gateway process owns `18789`,
- the same gateway process owns `18800`,
- `18789/health` returns JSON,
- `18800/version` returns `{"protocolVersion":1}`.

## 3. Runtime And Auth Sanity

Check the runtime and auth before interpreting slow or missing replies as a Clawline bug:

```bash
cd ~/openclaw
node --version
pnpm --version
openclaw models status --json
```

The shell `node` version is not necessarily the already-running gateway process. If there is a mismatch, record both before acting:

```bash
ps -axo pid,command | rg 'openclaw|gateway' | head -20
```

If model status shows stale or missing provider auth, fix credentials first, then restart the gateway through the approved deploy/restart path and rerun health checks. A smoke test is not successful until a real prompt receives a real assistant reply.

## 4. Clawline Prompt Roundtrip

Use a fresh Clawline chat/session for each run when possible.

1. Create or select a Clawline stream.
2. Send a prompt containing a nonce, for example:

   ```text
   Smoke <timestamp>: reply with exactly "clawline-smoke-ok <nonce>".
   ```

3. Wait for an assistant reply.
4. Confirm the reply appears in the same stream that sent the prompt.
5. Send two or more repeated prompts to the same stream and confirm they are not ignored or delayed behind unrelated streams.

Success criteria:

- the assistant reply arrives,
- the reply content proves the current prompt was processed,
- the reply lands in the originating stream,
- repeated prompts do not sit for several minutes without visible progress,
- logs do not show unexpected lane waits, orphaned user-message cleanup, or prompt rerouting for that session.

Failure criteria:

- no assistant reply,
- reply appears in a different stream,
- reply only appears after a large unexplained delay,
- logs show `gateway timeout`, repeated lane waits for the target session, or stale auth/model errors.

## 5. `/alert` Targeting Smoke

Run this after prompt roundtrip is healthy.

Test at least three targets:

- `agent:main:main`,
- an existing native Clawline stream key such as `agent:main:clawline:<user>:<stream>`,
- an existing non-Clawline `agent:*` session-store key if one is available.

For each target, send an alert with an explicit `sessionKey` and a nonce. The mechanism can be the Clawline alert client, CLU, or a local authenticated HTTP request, but the payload must explicitly name the target session key.

Expected behavior:

- `/alert` enqueues exactly for the requested existing session key,
- malformed session keys fail with `invalid_session_key`,
- syntactically valid but non-existing session keys fail with `stream_not_found`,
- there is no fallback to the current visible stream, the main stream, or core `lastTo`,
- the assistant produces a reply for the alert,
- the reply appears in the targeted stream.

Check gateway logs for the alert run phases:

```bash
tail -n 300 ~/.openclaw/logs/gateway.log | rg 'alert_received|alert_payload_received|alert_run_phase|announce queue drain failed|gateway timeout'
```

Success requires an alert phase sequence for the target session key ending in a reply:

```text
phase=queued
phase=wake-dispatched
phase=agent-run-start
phase=agent-run-end ... status=ok ... payloadCount=1
phase=replied ... payloadCount=1
```

A `no-reply` phase is not a successful smoke for this runbook.

## 6. Cross-Session Alert Placement

Use this when validating session-key routing or after any alert/refactor work.

1. Create two fresh Clawline streams, A and B.
2. Capture their exact session keys.
3. While viewing or recently using B, send `/alert` to A with a nonce.
4. Confirm the assistant reply lands in A only.
5. While viewing or recently using A, send `/alert` to B with a different nonce.
6. Confirm the assistant reply lands in B only.
7. Repeat once against `agent:main:main` if the change touched main/global routing.

Success criteria:

- each alert wakes the exact existing session key in the payload,
- no reply follows UI focus, last-used stream, or `lastTo`,
- each run has `payloadCount > 0`,
- no fallback path is visible in logs or behavior.

## 7. Memory-Pressure Regression Smoke

These checks look for the fixes working in the live process. They do not replace unit tests.

### Replay Cap

Reconnect Clawline with multiple streams that have history. Then inspect logs:

```bash
tail -n 500 ~/.openclaw/logs/gateway.log | rg 'replay_request|replay_start|replay_send|replay_complete|stream_snapshot'
```

Success criteria:

- replay remains bounded per subscribed stream,
- quiet streams still replay their eligible messages,
- a busy stream does not dominate the replay window,
- replay delivery order remains stable enough that the client view is coherent.

### Stale Socket Abort

During or immediately after reconnect churn, inspect for stale socket handling:

```bash
tail -n 500 ~/.openclaw/logs/gateway.log | rg 'send_json_socket_not_open|stale|socket_not_open|ws_connection_close|replay'
```

Success criteria:

- a closed socket does not continue receiving a long sequence of replay sends,
- other connected devices for the same user still receive messages,
- gateway PID remains stable.

### Alert Lookup Pressure

Run repeated `/alert` checks against unchanged session stores and inspect logs/runtime behavior:

```bash
tail -n 500 ~/.openclaw/logs/gateway.log | rg 'alert_|loadSessionStore|skipCache|gateway timeout|heap|memory'
```

Success criteria:

- repeated alert lookups do not trigger repeated fresh full-store scans,
- store changes are still observed before a newly existing session key is accepted,
- missing session keys return miss semantics instead of falling back.

## 8. Surf Ace Coexistence Check

Use this only when Surf Ace is suspected to be affecting Clawline/OpenClaw health.

Observe Surf Ace logs while running the prompt and `/alert` smokes:

```bash
tail -n 500 ~/.openclaw/logs/gateway.log | rg 'surf-ace|zombie|snapshot.get|invalid_resume|socket_closed|reconnect_error|gateway timeout|alert_run_phase'
```

Success criteria:

- Clawline prompt roundtrip still works while Surf Ace is connected, busy, timing out, or reconnecting,
- `/alert` still reaches the targeted session key and gets a reply,
- the gateway process does not restart,
- no new uncaught `zombie connection` exception appears,
- no new repeated `gateway timeout after 300000ms` alert drain failures appear.

This check is observational. Do not disable Surf Ace, reset state, or change runtime config unless Flynn explicitly authorizes that exact action.

## 9. Final Log Review

Capture the final deploy/runtime state:

```bash
cd ~/openclaw
git status -sb
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
lsof -nP -iTCP:18789 -sTCP:LISTEN
lsof -nP -iTCP:18800 -sTCP:LISTEN
tail -n 120 ~/.openclaw/logs/gateway.log
tail -n 120 ~/.openclaw/logs/gateway.err.log
```

Report:

- tested host,
- branch and commit,
- local gates run,
- health result,
- prompt roundtrip result,
- `/alert` result for each target session key,
- cross-session placement result,
- memory-pressure indicators observed,
- any auth/runtime fixes made,
- unresolved failures or suspicious logs.

Do not call the smoke successful if any required prompt or alert lacks a successful assistant reply.
