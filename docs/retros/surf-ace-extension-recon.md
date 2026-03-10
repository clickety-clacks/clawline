# Surf Ace Extension Extraction Recon

**Date:** 2026-03-03  
**Branch:** surf-ace-manual-register  
**Codebase:** eezo:~/src/worktrees/surf-ace-manual-register

---

## Verdict

**Standalone extraction is feasible — no hard blockers — but requires 3 meaningful engineering tasks.**

The OpenClaw plugin model fully supports standalone non-channel extensions that register tools and services. The coupling is real but addressable. The only non-trivial piece is alert routing.

---

## Key Findings

### 1. OpenClaw Extension Model

Non-channel standalone extensions work fine. `phone-control` and `llm-task` are examples. An extension just needs `openclaw.plugin.json` and an `index.ts` with a `register(api)` export. The API surface available to extensions includes:

- `api.registerTool(contextFn)` — register agent tools, called with tool context per request
- `api.registerService({ id, start, stop })` — register a background service (lifecycle-managed)
- `api.runtime.system.enqueueSystemEvent` — inject text into the next prompt for a session
- `api.runtime.system.runCommandWithTimeout` — shell exec (used by the mDNS discovery in surf-ace.ts)

There is no `postAlert`/`wakeGateway` equivalent in the plugin SDK — that's the key gap.

---

## Coupling Points (ranked by extraction difficulty)

### 🟢 Easy — The Tool Layer (`extensions/clawline/src/surf-ace-tools.ts`)

The 5 surf-ace tools (`surf_ace_list`, `surf_ace_push`, `surf_ace_clear`, `surf_ace_read`, `surf_ace_annotations_remove`) only import from:
- `@sinclair/typebox` — external package
- `openclaw/plugin-sdk` — stable extension API
- `./surf-ace-runtime.js` — the local runtime singleton shim

These move verbatim to a new extension. The `isClawlineToolContext()` gating (which returns empty tools for non-Clawline sessions) would need a decision: keep it (still Clawline-specific tool registration), remove it (always register), or make it configurable. Either way it's ~10 lines of logic.

### 🟢 Easy — The Runtime Singleton Shim (`extensions/clawline/src/surf-ace-runtime.ts`)

A 35-line module-level singleton that holds the `SurfAceRuntime` reference. Moves verbatim to the new extension. The interface it defines (`list`, `push`, `clear`, `read`, `annotationsRemove`) is clean — no Clawline imports.

### 🟡 Medium — The `SurfAceManager` Class (`src/clawline/surf-ace.ts`)

This is the core mDNS discovery + WebSocket management class. It lives in the core source tree at `src/clawline/surf-ace.ts`, not in an extension. It imports:

- `ws` — external package
- `node:crypto`, `node:fs/promises`, `node:path` — Node builtins
- `../process/exec.js` (`runCommandWithTimeout`) — available via `api.runtime.system.runCommandWithTimeout`
- `./domain.js` (`Logger`) — just a type; use `RuntimeLogger` from plugin-sdk instead

**Extraction path:** Move `src/clawline/surf-ace.ts` into the new extension's `src/` folder. Swap the two core imports for their plugin-sdk equivalents. The class has no other dependency on Clawline internals — it's self-contained business logic.

### 🔴 Hard — Alert Routing (`postActivityAlert` in surf-ace.ts)

When a Surf Ace screen fires an activity event, it POSTs to:

```
http://localhost:18800/alert
body: { sessionKey: "agent:main:main", message: "...", noOverlay: true }
```

Port `18800` is the Clawline HTTP server. The `/alert` endpoint calls `wakeGatewayForAlert()` → `enqueueAnnounce()` → `callGateway()` to actively wake the agent with the alert message.

**The problem:** `wakeGatewayForAlert`, `enqueueAnnounce`, and `callGateway` are NOT exposed in the plugin SDK `PluginRuntime`. The only system-event mechanism available to plugins is `enqueueSystemEvent`, which queues text for the next prompt — it does not proactively wake the agent.

**Options for extraction:**

1. **Inject an alert callback at service start** — the new extension's `start()` receives the plugin API. Pass an `onAlert(message, sessionKey)` callback into `SurfAceManager` at construction time, and have the Clawline extension (still running) provide that callback. But this creates a new inter-extension dependency, which defeats the goal.

2. **Use `enqueueSystemEvent` only** — degraded behavior: alert is visible when the agent is next spoken to, not on first event. Acceptable if proactive wakeup is not a hard requirement.

3. **Expose a `postAlert` method in the plugin SDK** — the right long-term fix. Add `api.runtime.system.postAlert(message, sessionKey)` backed by the existing `callGateway` / `enqueueAnnounce` logic. This is a new SDK surface area — requires a core change alongside the extraction.

4. **Keep Clawline as the alert sink, surface a shared alert URL in the SDK** — expose the Clawline alert endpoint URL via config or a plugin API. Surf Ace extension continues POSTing to it, but reads the URL from the SDK instead of hardcoding port 18800. This is the cheapest "works today" path.

---

## Recommended Extraction Path

**Phase 1 (low-risk, parallel-workable):**
1. Create `extensions/surf-ace-ext/` (or similar) with its own `package.json`, `tsconfig.json`, `openclaw.plugin.json`.
2. Copy `surf-ace-tools.ts` and `surf-ace-runtime.ts` into the new extension verbatim.
3. Move `src/clawline/surf-ace.ts` → `extensions/surf-ace-ext/src/surf-ace.ts`. Swap core imports: `runCommandWithTimeout` ← `api.runtime.system.runCommandWithTimeout`; `Logger` ← `RuntimeLogger` from plugin-sdk.
4. Wire up `api.registerService` and `api.registerTool` in the new extension's `index.ts`.

**Phase 2 (alert routing decision required first):**
Pick one of the four alert options above. Recommendation: **Option 3** (expose `postAlert` in plugin SDK) if this is planned infrastructure; **Option 4** (read alert URL from config) if you want a clean cut today with no SDK changes.

**Phase 3 (cleanup):**
Remove `surf-ace-tools.ts`, `surf-ace-runtime.ts` from `extensions/clawline/`. Remove the `createSurfAceManager` / `surfAceManager` wiring from `src/clawline/server.ts`. Remove the `setClawlineSurfAceRuntime` call from `extensions/clawline/index.ts`.

---

## Summary Table

| Coupling Point | Location | Difficulty | Notes |
|---|---|---|---|
| Tool definitions | `extensions/clawline/src/surf-ace-tools.ts` | 🟢 Easy | Move verbatim; minor context-gating decision |
| Runtime singleton | `extensions/clawline/src/surf-ace-runtime.ts` | 🟢 Easy | Move verbatim |
| SurfAceManager class | `src/clawline/surf-ace.ts` | 🟡 Medium | Move to extension; swap 2 core imports |
| Alert routing | `postActivityAlert()` → `:18800/alert` | 🔴 Hard | No generic SDK alert API; needs design decision |

**Total coupling = 4 points. Zero hard blockers. Alert routing is the only design decision needed before starting.**
