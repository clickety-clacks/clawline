# Config Flip Investigation (2026-02-23)

## Question
What code in OpenClaw writes `openclaw.json` during gateway restart that could flip channel `enabled` flags to `false`?

## Findings

### 1) `openclaw gateway restart` path itself does **not** write channel flags
- Restart CLI/service flow is process control only (launchctl/systemd/SIGUSR1), no config mutation in restart path:
  - `src/cli/daemon-cli/lifecycle.ts`
  - `src/cli/daemon-cli/lifecycle-core.ts`
  - `src/cli/gateway-cli/run-loop.ts`
- Conclusion: restart command itself does not set `channels.*.enabled=false`.

### 2) Gateway startup **can** write config, but not by disabling channels
On gateway boot, `startGatewayServer` may call `writeConfigFile(...)` in three places:
- Legacy migration write:
  - `src/gateway/server.impl.ts` (after `migrateLegacyConfig(...)`)
- Plugin auto-enable write:
  - `src/gateway/server.impl.ts` (after `applyPluginAutoEnable(...)`)
  - `src/config/plugin-auto-enable.ts` only sets plugin entries `enabled: true` and allowlists; it does not set entries false.
- Startup auth token bootstrap write:
  - `src/gateway/server.impl.ts` -> `ensureGatewayStartupAuth(..., persist: true)`
  - `src/gateway/startup-auth.ts` may write `gateway.auth.token` when missing.

None of these startup writes contain logic to flip channel enabled flags to false.

### 3) The code path that can flip channel flags is config write APIs/commands, not restart
Any actor using config mutation methods can write arbitrary channel/plugin enabled fields:
- Gateway control-plane methods:
  - `src/gateway/server-methods/config.ts`
  - `config.set`, `config.patch`, `config.apply` all persist via `writeConfigFile(...)`.
- CLI commands that mutate config also call `writeConfigFile(...)` (config/plugins/channels/doctor/update/etc):
  - Examples from `src/cli/config-cli.ts`, `src/cli/plugins-cli.ts`, `src/commands/channels/*.ts`, `src/commands/doctor.ts`, `src/cli/update-cli/update-command.ts`.

Given logs showing broad changed paths including `channels.discord.enabled` and `plugins.entries.*.enabled`, this pattern matches a config mutation write, not a plain restart.

### 4) Forensics support exists: config write audit log
`writeConfigFile` appends JSONL audit records including `pid`, `ppid`, `cwd`, `argv`, watch session fields, hashes:
- `src/config/io.ts` (`appendConfigWriteAuditRecord`)
- Audit file path resolves to:
  - `~/.openclaw/logs/config-audit.jsonl`

This is the authoritative source to identify which process/command wrote the flip.

## Bottom line
- `openclaw gateway restart` is not the code that flips channel enabled flags to false.
- The likely source is a separate config mutation (gateway config API call or CLI command) that wrote those fields, then restart/reload applied them.
