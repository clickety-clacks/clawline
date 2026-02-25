# TARS Alert/Discord/Clawline Retro (2026-02-23)

## Summary
- Alert delivery failures were traced to missing gateway auth token on Clawline's self-call path.
- Discord and Clawline outages were primarily config-state issues (both were disabled in runtime config at different points).
- A model name mismatch (`openai-codex/gpt-5.3`) caused "model not allowed" reply failures.

## Findings

### 1) Alert delivery auth failure
- Symptom: notify CLI returned `curl: (1) Received HTTP/0.9 when not allowed` and alert delivery failed.
- Root cause: `/alert` self-connection path in provider did not pass gateway token while gateway auth was required for that path.
- Code fix: `src/clawline/server.ts` now passes gateway token into `callGateway(...)` for alert wake/drain.
- Commit: `af801150d` (`fix: pass gateway token for alert self-connection`).
- Verification: post-deploy notify test succeeded (`Alert delivered`).

### 2) Discord not connecting/responding
- Immediate blocker found in config: `channels.discord.enabled=false`.
- Additional ingress blocker: `channels.discord.dm.enabled=false`.
- Action taken:
  - Re-enabled `channels.discord.enabled=true`
  - Re-enabled `plugins.entries.discord.enabled=true`
  - Re-enabled `channels.discord.dm.enabled=true`
  - Restarted gateway after changes
- Result: Discord provider returned to running/works state.

### 3) Clawline unable to connect
- Immediate blocker found in config:
  - `channels.clawline.enabled=false`
  - `plugins.entries.clawline.enabled=false`
- Action taken:
  - Set both to `true`
  - Restarted gateway
- Result: Clawline was re-enabled in runtime config.

### 4) Legacy Discord key migration noise
- Repeated doctor warnings:
  - `channels.discord.dm.policy -> channels.discord.dmPolicy`
  - `channels.discord.dm.allowFrom -> channels.discord.allowFrom`
- Action taken: migrated keys in `~/.openclaw/openclaw.json` to new fields.
- Verification: those specific doctor migration warnings no longer appeared.

### 5) "Model not allowed" despite prior usage
- Log evidence: `INVALID_REQUEST ... model not allowed: openai-codex/gpt-5.3`.
- Current codex allow-prefix in code is `gpt-5.3-codex`, not `gpt-5.3`.
- Correct model string: `openai-codex/gpt-5.3-codex`.

## Timeline highlights (local)
- 2026-02-23 09:53: TLS-related config/reload activity.
- 2026-02-23 17:48: bulk config write/reload touched channel/plugin enable flags (including Discord/Clawline-related keys).

## Operational notes
- `0.0.0.0`/`lan` bind itself was not the direct Discord outage cause.
- The concrete outage causes were config toggles disabling channels/plugins and the model-id mismatch.
