# Surf Ace Standalone Feasibility Audit (CCX)

Date: 2026-03-06

Scope note: the user-specified OpenClaw repo path `/Users/mike/openclaw/...` does not exist on this machine. All code evidence below was taken from the live checkout at `/Users/mike/src/clawdbot/...`, which is the OpenClaw repository present here.

## Verdict

YES, with caveats.

Surf Ace can be implemented as a 100% standalone OpenClaw extension with no Clawline dependency and no core patches, assuming:

1. The extension ships its own provider runtime code for mDNS discovery, WS connection management, session/tab routing, and local buffer persistence.
2. The extension uses published plugin SDK surfaces for lifecycle, tools, hooks, skills, state path access, and system wake/event routing.
3. The extension does not try to reuse the current Clawline-specific Surf Ace runtime shim, which is coupled to `startClawlineService`.

The current `extensions/clawline` Surf Ace code is not reusable as-is for that goal, but the exported SDK is sufficient to build the required replacement inside `extensions/surf-ace/`.

## 1. Capability Matrix

| Spec requirement | Extension-local implementation path | Evidence |
|---|---|---|
| mDNS discovery | Run a long-lived Surf Ace daemon via `api.registerService(...)`. Inside that service, implement Bonjour/mDNS browsing with extension-local code and a plugin-local dependency/runtime library. No Clawline import is required. | Spec assigns ownership to `extensions/surf-ace/` for mDNS + connection runtime: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:88-92`, `:133`, `:2834-2840`. Plugin services are first-class API: `/Users/mike/src/clawdbot/src/plugins/types.ts:224-235`, `/Users/mike/src/clawdbot/src/plugins/types.ts:279-280`, `/Users/mike/src/clawdbot/src/plugins/services.ts:34-75`. SDK export surface includes `OpenClawPluginService`/`OpenClawPluginApi`: `/Users/mike/src/clawdbot/dist/plugin-sdk/plugin-sdk/index.d.ts:13-18`. |
| WS client / connection manager | Implement in the same service process. Use extension-local files for endpoint registry, reconnect/backoff, pair handshake, heartbeats, and per-surface jobs. Tool calls talk to that in-memory manager. | Spec makes the provider WS client/reconnect owner and says CLU never manages the socket directly: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:28-35`, `:120-133`, `:201-218`, `:2834-2855`. Plugin service lifecycle exists: `/Users/mike/src/clawdbot/src/plugins/services.ts:34-75`. Current Clawline coupling is only a local extension choice, not a core limitation: `/Users/mike/src/clawdbot/extensions/clawline/index.ts:17-35`, `/Users/mike/src/clawdbot/extensions/clawline/src/surf-ace-runtime.ts:15-52`. |
| CLU tool registration | Register `surf_ace_list`, `surf_ace_push`, `surf_ace_clear`, `surf_ace_read`, `surf_ace_annotations_remove`, pane/tab tools, etc. with `api.registerTool(...)`. Use tool factory context to get `sessionKey` and `sessionId`. | Tool API: `/Users/mike/src/clawdbot/src/plugins/types.ts:58-83`, `/Users/mike/src/clawdbot/src/plugins/types.ts:257-295`. Registry stores plugin tools without core patching: `/Users/mike/src/clawdbot/src/plugins/registry.ts:168-193`. SDK declarations: `/Users/mike/src/clawdbot/dist/plugin-sdk/plugins/types.d.ts:223-254`. `sessionId` and `sessionKey` are available in tool context: `/Users/mike/src/clawdbot/src/plugins/types.ts:63-72`. |
| Session-scoped tab routing / provider-injected `sessionId` | In each Surf Ace tool, read `ctx.sessionId` from `OpenClawPluginToolContext` and stamp it into the extension-local WS request or state lookup. This satisfies the spec's requirement that CLU not pass `sessionId` as a tool arg. | `sessionId` is in plugin tool context: `/Users/mike/src/clawdbot/src/plugins/types.ts:63-66`. Spec requires provider-side injection, not caller-supplied payloads: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:125-126`, `:172-183`, `:454-456`, `:2934-2937`. |
| Alert / wake routing via `enqueueSystemEvent + requestHeartbeatNow` | Use `api.runtime.system.enqueueSystemEvent(text, { sessionKey })` plus `api.runtime.system.requestHeartbeatNow({ sessionKey, reason })` from the Surf Ace service when unread annotation activity first appears. This is enough to route lightweight alerts to the watcher session without Clawline internals. | Runtime exposes both calls to plugins: `/Users/mike/src/clawdbot/dist/plugin-sdk/plugins/runtime/types-core.d.ts:8-19`, `/Users/mike/src/clawdbot/src/plugins/runtime/runtime-system.ts:7-13`. Raw exported contracts: `/Users/mike/src/clawdbot/dist/plugin-sdk/infra/system-events.d.ts:1-17`, `/Users/mike/src/clawdbot/dist/plugin-sdk/infra/heartbeat-wake.d.ts:11-29`. Spec explicitly requires extension-local wake/routing via published SDK surfaces: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:133`, `:2762-2777`, `:3055-3057`, `:3091`. |
| State persistence | Use service `stateDir` for persisted trust store, discovered surface registry, reconnect metadata, and optional buffer snapshots. SDK also exports JSON helpers for atomic writes. Hot event buffers can remain in-memory. | Service context contains `stateDir`: `/Users/mike/src/clawdbot/src/plugins/types.ts:224-235`, `/Users/mike/src/clawdbot/src/plugins/services.ts:18-27`. SDK exports file helpers: `/Users/mike/src/clawdbot/dist/plugin-sdk/plugin-sdk/index.d.ts:73-79`. Spec requires provider-owned local buffers and persistence-friendly reconnect behavior: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:108-112`, `:122`, `:2758-2792`, `:2834-2855`. |
| Skills injection | Declare `skills` in `openclaw.plugin.json`; OpenClaw automatically resolves enabled plugin skill directories and merges them into workspace skill loading. | Manifest supports `skills`: `/Users/mike/src/clawdbot/src/plugins/manifest.ts:11-22`, `:94-118`. Manifest registry keeps them: `/Users/mike/src/clawdbot/src/plugins/manifest-registry.ts:23-40`, `:106-131`. Enabled plugin skill dirs are resolved automatically: `/Users/mike/src/clawdbot/src/agents/skills/plugin-skills.ts:15-89`. Those dirs are merged into workspace skill loading: `/Users/mike/src/clawdbot/src/agents/skills/workspace.ts:327-405`. Existing Surf Ace scaffold already declares a skill path: `/Users/mike/src/clawdbot/extensions/surf-ace/openclaw.plugin.json:1-9`. Spec requires plugin-shipped skills: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:2610-2616`, `:3071-3079`. |
| Agent instruction injection via `before_prompt_build` | Register `api.on("before_prompt_build", ...)` in `extensions/surf-ace/index.ts` and return `{ prependContext: SURF_ACE_AGENT_GUIDANCE }` from `src/agent-instructions.ts`. | Hook API exists on plugins: `/Users/mike/src/clawdbot/src/plugins/types.ts:289-295`, `/Users/mike/src/clawdbot/src/plugins/types.ts:310-334`. Hook result supports `prependContext`: `/Users/mike/src/clawdbot/dist/plugin-sdk/plugins/types.d.ts:284-292`, `:533-536`. Reference extension already does this: `/Users/mike/src/clawdbot/extensions/diffs/index.ts:27-40`. Spec requires exactly this wiring path: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:3071-3091`. |
| Portable standalone install / distribution | Ship Surf Ace as a standard plugin package with `openclaw.plugin.json`, `package.json`, and `openclaw.extensions`. Dev can use `openclaw plugins install -l <path>`; distribution can use `openclaw plugins install ./surf-ace.zip`. | Spec OT-5 says this is the required distribution model: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:3270-3277`. CLI supports `--link`: `/Users/mike/src/clawdbot/src/cli/plugins-cli.ts:199-249`, `:719-727`. Plugin docs show zip and `-l` flows: `/Users/mike/src/clawdbot/docs/tools/plugin.md:321-327`, `/Users/mike/src/clawdbot/docs/cli/plugins.md:41-61`. Archive/path install code supports dirs and `.zip`: `/Users/mike/src/clawdbot/src/plugins/install.ts:379-410`, `:541-571`. |

## 2. Blocker Table

| Requirement | Blocker? | Evidence file+line | Workaround |
|---|---|---|---|
| mDNS discovery daemon inside standalone extension | No | Plugin services are supported generically: `/Users/mike/src/clawdbot/src/plugins/types.ts:224-235`, `/Users/mike/src/clawdbot/src/plugins/services.ts:34-75` | Implement discovery in `extensions/surf-ace/src/discovery.ts` with extension-local code. |
| WS client / reconnect manager | No | No core-only seam is required; the service can host arbitrary runtime logic. Current Clawline runtime coupling is extension-local, not SDK-imposed: `/Users/mike/src/clawdbot/extensions/clawline/src/surf-ace-runtime.ts:15-52` | Rebuild the manager in Surf Ace extension instead of importing Clawline's runtime shim. |
| CLU tool registration | No | `/Users/mike/src/clawdbot/src/plugins/types.ts:257-295`, `/Users/mike/src/clawdbot/src/plugins/registry.ts:168-193` | Register all `surf_ace_*` tools directly from `extensions/surf-ace/index.ts`. |
| Alert/wake routing to watcher session | No | Published plugin runtime exposes `enqueueSystemEvent` and `requestHeartbeatNow`: `/Users/mike/src/clawdbot/dist/plugin-sdk/plugins/runtime/types-core.d.ts:14-19` | Call both from the Surf Ace service with the watcher `sessionKey`. |
| Session-scoped `sessionId` injection for push/read | No | Tool context exposes `sessionId`: `/Users/mike/src/clawdbot/src/plugins/types.ts:63-66` | Use tool factory context, not tool args, to stamp session identity. |
| State persistence | No | `stateDir` is available to plugin services: `/Users/mike/src/clawdbot/src/plugins/types.ts:224-235` | Store plugin files under `path.join(stateDir, "surf-ace", ...)`. |
| Skills injection | No | Enabled plugin skill dirs are auto-resolved: `/Users/mike/src/clawdbot/src/agents/skills/plugin-skills.ts:23-89` | Put required skills under `extensions/surf-ace/skills/` and declare them in manifest. |
| Agent instruction injection | No | `before_prompt_build` is a published plugin hook: `/Users/mike/src/clawdbot/dist/plugin-sdk/plugins/types.d.ts:262-292`, `:533-536` | Add `api.on("before_prompt_build", ...)` in Surf Ace extension. |
| Portable install as link/zip | No | CLI supports `--link`, path install, and archive install: `/Users/mike/src/clawdbot/src/cli/plugins-cli.ts:199-249`, `:719-727`; `/Users/mike/src/clawdbot/src/plugins/install.ts:379-410`, `:541-571` | Use standard `openclaw plugins install` flows. |

Conclusion: no requirement in the requested set appears to require a core patch or a Clawline import. The blockers list is empty.

## 3. Minimal Glue List

These are the small extension-local pieces that still must be written because they are product-specific Surf Ace logic, not published SDK helpers.

1. `src/discovery.ts` (~150-300 LOC)
Implements `_surf-ace._tcp` Bonjour/mDNS browse/resolve, TXT parsing, endpoint up/down events, and stable endpoint records.

2. `src/connection-manager.ts` (~300-500 LOC)
Owns per-endpoint and per-surface WS jobs, exponential backoff, pair handshake, heartbeat ping/pong, reconnect takeover logic, and socket teardown.

3. `src/state-store.ts` (~200-400 LOC)
Maintains in-memory surface registry, local event buffers, pane/tab content metadata, annotation queues/registers, and watcher routing metadata. Persists trust/reconnect metadata under `stateDir`.

4. `src/session-routing.ts` (~80-180 LOC)
Maps OpenClaw `sessionKey`/`sessionId` from tool context to Surf Ace watcher sessions, tab ownership, and per-session read targeting.

5. `src/alert-gate.ts` (~80-180 LOC)
Implements the unread-burst gate, 10-minute rearm timeout, and calls to `api.runtime.system.enqueueSystemEvent` plus `requestHeartbeatNow`.

6. `src/tools.ts` (~200-400 LOC)
Defines the Surf Ace tool schemas and handlers, including local-only reads and write-path validation against connection state.

7. `src/agent-instructions.ts` (~50-120 LOC)
Exports the required instruction text for event semantics and tool usage.

8. `src/index.ts` or extension `index.ts` wiring (~50-120 LOC)
Registers service, tools, and `before_prompt_build` hook, and loads any plugin config defaults.

None of these are evidence of missing SDK surface. They are the expected product-specific implementation that the spec explicitly says belongs to `extensions/surf-ace/`.

## 4. What Is Actually Coupled to Clawline Today

The current code under `extensions/clawline` proves only that the existing scaffold chose a Clawline-backed implementation path, not that such coupling is required.

- `extensions/clawline/index.ts` registers Surf Ace tools and then starts `startClawlineService(...)`: `/Users/mike/src/clawdbot/extensions/clawline/index.ts:15-57`
- `extensions/clawline/src/surf-ace-runtime.ts` is just a mutable global runtime handle around the Clawline provider: `/Users/mike/src/clawdbot/extensions/clawline/src/surf-ace-runtime.ts:15-52`
- `extensions/clawline/src/surf-ace-tools.ts` gates tool availability on Clawline-specific session detection and forwards everything into that runtime handle: `/Users/mike/src/clawdbot/extensions/clawline/src/surf-ace-tools.ts:94-245`

That is a replaceable implementation choice. It does not expose a missing SDK seam.

## 5. Confidence Verdict

YES.

Confidence: medium-high.

Why not absolute:

1. This was a static audit only. I did not build a standalone Surf Ace package or execute a live plugin install.
2. mDNS itself is not a special SDK primitive; the extension must own that code and dependency management cleanly.
3. The spec still leaves some product behavior open outside the audited seams, especially multi-session pane contention policy details.

Why still YES:

1. Every requested seam is already exposed through plugin lifecycle, tool context, hook APIs, plugin skill loading, or plugin runtime system helpers.
2. The only existing Clawline dependency is in current extension code, not in OpenClaw core/plugin architecture.
3. The spec itself explicitly requires a standalone extension outcome and explicitly allows standalone wake/routing via extension-local code and published SDK surfaces: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:133`, `:3091`.

## 6. OT-5 Distribution

Confirmed: yes, OT-5's install/distribution approach is correct.

- Development: `openclaw plugins install -l ~/src/surf-ace`
- Distribution: `openclaw plugins install ./surf-ace.zip`

Evidence:

- Spec OT-5 states exactly this: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md:3272-3277`
- CLI supports `-l/--link`: `/Users/mike/src/clawdbot/src/cli/plugins-cli.ts:213-249`, `/Users/mike/src/clawdbot/src/cli/plugins-cli.ts:719-727`
- CLI/path install supports `.zip`: `/Users/mike/src/clawdbot/src/plugins/install.ts:379-410`, `/Users/mike/src/clawdbot/src/plugins/install.ts:541-571`
- Docs match that behavior: `/Users/mike/src/clawdbot/docs/tools/plugin.md:321-327`, `/Users/mike/src/clawdbot/docs/cli/plugins.md:55-61`

This satisfies the spec's standalone-distribution requirement and does not require Clawline or core patches.
