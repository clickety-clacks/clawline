---
name: spec-homing
description: Find and place technical specs. Use when writing a new spec, looking for an existing spec, or referencing spec conventions.
---

# Spec Homing

Where specs live, how to find them, how to name them.

## Process Model (Spec-First)

Specs are a dedicated step before implementation.

- **Spec agent session:** `tmux` session named `{project}-{feature}-spec`
- **Spec output path:** `~/shared-workspace/{project}/specs/{specname}.md`
- **Implementation agents:** separate sessions/agents that consume the spec
- **SME continuity:** spec agent stays alive after handoff for clarification

## Canonical Location

All specs live on the NFS shared workspace, visible from both Provider-host and development-host:

```
~/shared-workspace/{project}/specs/{specname}.md
```

**Projects:**
- `clawline` — Clawline iOS client + provider
- `helm` — Helm app
- `floatty` — Floatty app
- `shared` — Cross-project or infrastructure specs

**Do NOT put specs in:**
- `scratch/` (ephemeral, not preserved)
- Git repo `docs/` directly (synced FROM shared workspace, not the other way)
- Agent workspace files

## Finding a Spec

To find a spec by topic:
```bash
ls ~/shared-workspace/*/specs/
grep -rl "search term" ~/shared-workspace/*/specs/
```

Archived/superseded specs go in `specs/archive/` within each project.

## Naming

- Lowercase, hyphenated: `terminal-bubbles.md`, `bubble-sizing-v2.md`
- Name describes the feature or system, not the ticket number
- Version suffix (`-v2`) only when superseding a prior spec

## Writing a New Spec

1. Create the file at the canonical path
2. No mandatory template — structure should fit the problem
3. Include at minimum: Goal, Non-Goals, Architecture/Design, Open Questions

## Handoff Contract (Spec Agent -> Impl Agent)

1. Spec agent publishes canonical path under `~/shared-workspace/{project}/specs/`
2. Impl agent reads that spec before coding
3. Impl questions route back to the still-running spec agent SME session
4. Spec changes happen in the canonical spec file, not in scratch notes

## Role Boundaries

- Spec agents do **not** implement code as part of spec drafting.
- Impl agents do **not** rewrite spec scope/design unless explicitly directed.
- Do not terminate the spec agent immediately after spec delivery; keep it available for SME support.

## Syncing to Repos

Specs sync from the shared workspace into git repos via cron jobs (e.g., `sync-clawline-docs`). The shared workspace is the source of truth — edit there, not in the repo.
