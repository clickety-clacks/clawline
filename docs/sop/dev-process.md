# Development Process SOP

**Canonical location:** `/Users/mike/shared-workspace/clawline/sop/dev-process.md`  
**Applies to:** All Clawline development (iOS client, provider, any repo with coding agents)  
**Created:** 2026-02-10  
**Updated:** 2026-02-14 — switched from `cp -r` clones to git worktrees

---

## Principles

1. **Each agent gets its own worktree.** Clean checkout from HEAD, no dirty state bleed.
2. **Trunk-based development.** Direct commits to `main` unless Flynn explicitly approves a branch.
3. **Push is the coordination mechanism.** Agents push to `origin/main`; others pull to sync.
4. **Verified = done.** The feature lifecycle ends when Flynn verifies on device, not when code is committed.
5. **Context is valuable.** Capture impl knowledge before killing sessions.
6. **Tags mark stability.** Main is always moving; tags mark verified-good commits.

---

## Agent Workspace Setup

Each coding agent works in its own git worktree from the canonical repo:

```
~/src/clawline/                  ← canonical repo (deployer baseline, worktree parent)
~/src/worktrees/clawline-{agent-name}/     ← agent's worktree
```

### Naming Convention

**All folder names and tmux session names MUST be prefixed with the project name.**

- Project prefix for Clawline: `clawline-`
- Folder: `~/src/worktrees/clawline-{role}/` (e.g., `~/src/worktrees/clawline-ios-1/`)
- tmux session: `clawline-{role}` (e.g., `clawline-ios-1`)
- Folder name and tmux session name should match.

Examples:
- `clawline-ios-1` → `~/src/worktrees/clawline-ios-1/`
- `clawline-provider` → `~/src/worktrees/clawline-provider/`
- `clawline-deployer` → `~/src/clawline/` (deployers use the canonical repo directly)

### Creating an agent workspace

```bash
cd ~/src/clawline
git worktree add ~/src/worktrees/clawline-{agent-name} -b {agent-name}
```

- Worktrees check out clean from the current HEAD — no dirty/uncommitted state bleeds in.
- Each worktree gets its own branch (git enforces this).
- The worktree shares `.git` objects with the parent — fast setup, no disk duplication.
- For provider repos: same approach, `cd ~/src/clawdbot && git worktree add ...`

### Moving an agent to a new directory (preserving context)

If an agent needs to relocate (e.g., moving out of the hub into its own worktree):

1. Send `/exit` to the Codex agent — it prints a session UUID
2. Create the new worktree
3. Resume from the new directory: `cd ~/src/worktrees/clawline-{agent} && ccx resume <uuid>`

This preserves full conversation context while changing the working directory.

### Worktree gotchas

- **Teardown must use `git worktree remove`**, not `rm -rf`. Orphaned worktrees leave stale locks and block branch deletion.
- **Each worktree must be on its own branch.** Git enforces this — you can't have two worktrees on `main`.
- **Agents work on their branch, then merge to main** (or push directly to main if YOLO).

### Legacy cp-r workspaces

Before 2026-02-14, agent workspaces were created via `cp -r ~/src/clawline ~/src/worktrees/clawline-{agent}/`. These full copies may still exist on eezo with dirty/unstaged changes from prior work. Don't panic if you see them — they're the old system.

If you're in a legacy cp-r workspace:
- If the unstaged changes are YOUR work, commit and push them to main (or the appropriate branch) before anything else.
- If the unstaged changes belong to a DIFFERENT agent (you inherited them via cp-r), do NOT commit them. Flag it so the owning agent can deal with its own work.
- Once all work is committed by its rightful owner, the old directory can be removed with `rm -rf`.
- New workspaces should use `git worktree add` going forward.

### Why not a shared checkout?

- Uncommitted work collides silently.
- Stash/rebase/reset becomes dangerous (destroys other agents' work).
- `git status` is meaningless when multiple agents touch the same files.

---

## Development Lifecycle

There are two different lifecycle modes. Do **not** collapse them.

### Long feature branches — verified before final teardown

Use this when the branch represents a substantial feature branch that has already been deployed, tested, and verified before final closure.

```
0. SPEC       — CLU spins up spec agent to write technical spec (stays alive as SME)
1. SETUP      — create worktree, spin up impl agent in its folder
2. WORK       — impl agent implements per spec, commits, pushes branch/main as directed
3. DEPLOY     — deployer pulls intended source, builds, installs to device
4. VERIFY     — Flynn tests on device
5. DEBRIEF    — impl agent records impl notes (exit interview)
6. CLEANUP    — kill impl session, remove worktree (spec agent stays alive)
```

### Small feature / review-only branches — merge, rehome, keep agent

Use this when the branch was merged after compile/tests/review but **before Flynn has done full device verification**. This is common for small Clawline feature slices.

In this mode, merging is **not** the end of the agent's useful life. The agent still owns the feature's latent verification bugs.

```
0. SETUP      — create worktree, spin up impl agent
1. WORK       — implement, test/build, run review cycle
2. MERGE      — merge to main when accepted for next deploy
3. REHOME     — remove feature worktree/branch, but resume the same agent on canonical main
4. VERIFY     — Flynn tests when main is next deployed
5. FOLLOW-UP  — if bugs surface, reuse the same rehomed agent
6. FINAL KILL — kill only after Flynn verifies the feature or explicitly says to end that agent
```

If a follow-up bug is small, the original rehomed agent may YOLO/fix directly on main when Flynn directs that. If the follow-up is larger or needs isolation, create a new worktree/branch and **move the original agent into that worktree** using `/exit` + `ccx resume <id>`. Do not spawn a fresh agent just because the original branch was merged/deleted.

### Step 0: Spec (CLU-orchestrated)

Before impl agents are created, CLU spins up a dedicated **spec agent** to write the technical spec.

**Session naming convention:** `{project}-{feature}-spec`
- Example: `clawline-bubble-height-spec`, `helm-widget-spec`

**Agent type:** `ccx high` (extended context for comprehensive spec writing)

**Workspace:** Spec agents write directly to the shared workspace spec folder:
```
/Users/mike/shared-workspace/{project}/specs/{feature-name}.md
```

Spec agents don't need their own worktree — they work in the shared spec directory.

**Role:** The spec agent:
1. Writes the technical specification
2. Stays alive as the **subject matter expert (SME)**
3. Impl agents reference the spec (and can ask the spec agent for clarifications)

**Lifecycle:** Spec agents persist until Flynn explicitly directs them to be killed. They outlive impl agents.

See `/Users/mike/.codex/skills/spec-homing/SKILL.md` for spec placement conventions.

### Step 1: Setup (Impl Agent)

```bash
# Create worktree
cd ~/src/clawline
git worktree add ~/src/worktrees/clawline-{agent}/ -b {agent}

# Spin up agent session
# (use spinup script or manual tmux new-session)
```

### Step 2: Work

- Impl agent works in `~/src/worktrees/clawline-{agent}/` exclusively.
- Impl agent references the spec written by the spec agent.
- Commits go to `main` (YOLO mode, unless Flynn specifies a branch).
- Push to `origin/main` when work is ready:
  ```bash
  git add -A && git commit -m "descriptive message" && git push origin main
  ```
- If another agent pushed first, pull before pushing:
  ```bash
  git pull --ff-only origin main
  ```
  If `--ff-only` fails (diverged), **stop and ask Flynn**. Do not merge or rebase.

### Step 3: Deploy

- **Only with Flynn's explicit approval.** Never auto-deploy.
- Deploy from the **canonical repo** (`~/src/clawline/`): `git pull --ff-only origin main`, then build + install.
- Report: SHA deployed, build result, install result, launch result.

### Step 4: Verify

Flynn tests on device. Two outcomes:

- **🐛 Bug found before branch cleanup** → send bug report to the agent (it still has its worktree + session context). Agent fixes in-place, pushes again. Return to Step 3.
- **🐛 Bug found after merge/rehome** → use the original rehomed feature agent. Either let it fix on canonical main if Flynn directs a small YOLO fix, or create a follow-up worktree/branch and resume that same agent there. Do **not** create a fresh agent for same-feature verification bugs unless the original agent is unavailable or Flynn explicitly asks.
- **✅ Verified** → proceed to Step 5/final cleanup as appropriate.

### Step 4.5: Tag (Optional)

When Flynn confirms a build is good and says "tag it":

```bash
# From the canonical repo
cd ~/src/clawline
git tag v{YYYY-MM-DD} HEAD    # or v{short-desc} if Flynn specifies
git push origin v{YYYY-MM-DD}
```

- **Only Flynn decides when to tag.** Deployers and agents never tag on their own.
- Tags mark verified-good commits. Anyone wanting stable code checks out the latest tag.
- Tag naming: `v{YYYY-MM-DD}` by default, or `v{descriptive-name}` if Flynn specifies.

### Step 5: Debrief (Exit Interview)

**Before killing the session**, ask the agent to produce impl notes:

> "Before we close out, write implementation notes covering:
> 1. Key architectural decisions and why you made them
> 2. Gotchas / non-obvious behavior in your implementation  
> 3. What you tried that didn't work (and why)
> 4. Files touched and what each change does
> 5. Anything a future developer should know about this code
> 
> Write to /tmp/{ticket}-impl-notes.md"

- Append these notes to the GitHub issue or tracking file.
- These notes serve as onboarding material if bugs surface later.

### Step 6: Cleanup vs Rehome

For **long feature branches that Flynn has verified**, final cleanup may kill the tmux session and remove the worktree:

```bash
# Kill the tmux session
tmux kill-session -t {agent-name}

# Remove the worktree (not rm -rf!)
cd ~/src/clawline && git worktree remove ~/src/worktrees/clawline-{agent}/
```

For **small/review-only branches merged before full device verification**, do **not** kill the feature agent. Remove the worktree/branch if appropriate, then rehome the same agent to canonical `~/src/clawline` main so it can fix verification bugs with its preserved context.

**Final kill happens ONLY after Flynn says the feature is verified or explicitly says to end that agent.** Merged is not verified.

---

## Stability Model

Main is a **moving target**. Agents push freely, so HEAD may contain unverified work at any time.

**Tags are the stability mechanism:**
- `main` HEAD = latest code, possibly broken or incomplete
- Latest tag = last commit Flynn verified on device and explicitly tagged
- If you need known-good code, check out the latest tag, not HEAD

**Tagging flow:**
1. Deployer builds from `main` HEAD, installs to device
2. Flynn tests on device
3. If good, Flynn says "tag it"
4. Deployer runs `git tag v{name}` + `git push origin v{name}`

**Who can tag:** Only the deployer, on Flynn's explicit instruction. Agents never tag.

**Tag naming:** `v{YYYY-MM-DD}` by default (e.g., `v2026-02-10`). Flynn may specify a descriptive name instead (e.g., `v-sbb-state-machine`).

---

## Multi-Agent Coordination

When multiple agents are working simultaneously:

- **Different features**: no coordination needed. Each has its own worktree/branch.
- **Same feature, different files**: push/pull to sync. Communicate via CLU.
- **Same feature, same files**: serialize. One agent at a time. Code review between handoffs.

### Pull before work

Agents should `git pull --ff-only` before starting new work to pick up other agents' pushes.

### Conflict resolution

If `git pull --ff-only` fails → **stop and ask Flynn**. Never merge, rebase, or force-push.

---

## The Canonical Repo (Deployer Baseline)

The canonical repo (`~/src/clawline/`) is the **hub**:
- All agent worktrees are created from it.
- It's always on `main`, always clean — no uncommitted work.
- **Deploy happens here**: pull `origin/main`, build, install to devices.
- The canonical repo has a **deployer session** (`clawline-ios-deployer` / `clawline-provider-deployer`) — a long-lived agent for pull + build + deploy.
- Deployer sessions are permanent. They don't do feature work — only deploy.

---

## TARS Away Mode

When working in away mode (agents on TARS instead of eezo):

- Same process applies: worktrees from the TARS canonical repo (`~/src/clawline/`).
- TARS agents use `notify` (on PATH) for alerts.
- Deploy from TARS canonical repo when devices are reachable; otherwise deploy from eezo.
- Gateway restart policy (provider deploys): use service-managed restart only (`openclaw gateway restart`), never manual `node ... gateway` starts.
- Post-restart verification is required: exactly one process owns TCP `18789`, and the launchd job (`ai.openclaw.gateway` or legacy `bot.molt.gateway`) reports healthy state.
- If split ownership is detected, run recovery in order: `openclaw gateway stop` -> confirm `18789` is free -> `openclaw gateway start` -> re-verify single ownership.
- Failure signature to recognize: `already running`, `port/address in use`, or repeated launchd restart churn.

---

## Session Lifecycle Rules

- **Never mass-kill sessions.** Always list exactly which sessions to kill, get explicit confirmation.
- **Personal sessions (`flynn-*`) are never killed** without Flynn explicitly naming them.
- **Project sessions (Floatty, Helm, etc.) are never killed** without Flynn explicitly naming them.
- **Agent sessions persist until Flynn verifies** the feature they were working on.
- **Rehomed feature agents remain responsible for same-feature verification bugs.** Reuse the original agent; do not spawn a fresh one by default.
- **Canonical repos are never deleted** — they're the source of truth and deploy point.

---

## Checklist (for CLU / orchestrator)

Before spinning up an agent:
- [ ] Create worktree: `cd ~/src/clawline && git worktree add ~/src/worktrees/clawline-{agent} -b {agent}`
- [ ] Create tmux session with agent in that directory
- [ ] Include notify instruction in dispatch prompt

Before cleaning up or rehoming:
- [ ] Classify lifecycle: long verified branch final teardown, or small/review-only branch that still needs later device verification
- [ ] If final teardown: Flynn has verified on device or explicitly said to end the agent
- [ ] If small/review-only: rehome the same agent to canonical main instead of killing it
- [ ] Exit debrief completed when doing final teardown, notes saved to ticket
- [ ] Confirm with Flynn which session(s) to kill when killing is actually intended
- [ ] Remove worktree: `cd ~/src/clawline && git worktree remove ~/src/worktrees/clawline-{agent}`
- [ ] Delete branch local/remote only after merge/subsumption is confirmed

---

*This SOP supersedes any prior guidance about shared checkouts or `cp -r` clones for coding agents.*

---

## Appendix: Preserved Notes

### From: retros/rebase-2026-03-03-debrief.md

**v2026.3.2 rebase learnings (2026-03-03):**

Key conflicts that required active refactoring (not just upstream accept):

**A) `plugin-auto-enable.ts`:** Under raw upstream behavior, configured `channels.clawline` would be auto-enabled too aggressively. Fix: explicit Clawline handling registers configured Clawline in plugin entries as disabled by default (`plugins.entries.clawline.enabled = false`). Preserve this in future rebases.

**B) `message-action-params.ts`:** Added buffer-object compatibility normalization for `sendAttachment` (`Buffer`, `Uint8Array`, `{type:"Buffer",data:[...]}` forms) + explicit loopback SSRF allowance for localhost media fetches. Both are Clawline-specific additions inside the upstream media-policy structure.

**C) `server-methods/agent.ts`:** Preserved Clawline request-channel fallback (`channel: entry?.channel ?? requestChannel`) in the new ingress flow. Has regression test in `agent.test.ts`. Must preserve in future rebases.

**D) `plugin-sdk/index.ts`:** Must manually restore after rebase: `ClawlineDeliveryTarget`, `sendClawlineOutboundMessage`, `startClawlineService`/`ClawlineServiceHandle` (B13 invariant). These exports get dropped by upstream merges.

**E) `ws-connection/*`:** Upstream split the monolithic `message-handler.ts` into `auth-context.ts`, `connect-policy.ts`, `unauthorized-flood-guard.ts`. Device signature skew tightened from 10m → 2m. Client challenge nonce now mandatory.

**Rebase process:** Use spec agent for collision zone recon before writing merge code. Pre-analyze conflict areas with `git diff aba15763b v2026.3.2`. Write migration specs per collision zone. Verify each with tests before moving to next.
