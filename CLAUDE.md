# Claude Code - Clawline

> The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AgentMD file to help prevent future agents from having the same issue.

> This is a greenfield app with no users. Feel free to suggest structural and breaking refactors to help bend this codebase into the right shape.


Follow the shared instructions in [COMMON.md](./COMMON.md).

## Editing and Viewing Text Files

If I ask you to view or edit a text file, use tmux to create a new pane to the right, and open the text file using nvim:

```bash
tmux split-window -h "nvim <file>"
```

Look out for these key phrases which mean to open the file for editing:
- "Edit [filename]"
- "Edit this file"
- "Edit it"
- "Open [filename]"

## GitHub Issue Hygiene

See global rules in `~/AGENTS.md`. Summary:

1. **NEVER close an issue.** Only Flynn closes issues after testing.
2. **Mark as in-progress** when starting (`gh issue edit <N> --add-label "in-progress"` or comment).
3. **Comment progress updates** on the issue as you work.
4. **Comment final summary** (commit hash, changes, deploy status) when done. Do NOT close.

## iOS Git Workflow (Flynn Rule)

- Use a dedicated git worktree for each agent workspace, with each worktree on its own branch.
- `~/src/clawline/` stays the canonical deployer baseline; create agent worktrees under `~/src/worktrees/` (for example: `git worktree add ~/src/worktrees/clawline-{agent-name} -b {agent-name}`).
- Tear down with `git worktree remove <path>` (not `rm -rf`).
- YOLO on `main` is still allowed; agents can push to `origin/main` from their branch context when directed.

### Legacy Workspace Note (Before 2026-02-14)

- Legacy `cp -r` workspaces may still exist on eezo (for example `~/src/clawline-{name}/`) and are full repo copies rather than worktrees.
- Do not panic if you encounter one.
- If unstaged changes are yours, commit and push that work first, then proceed.
- If unstaged changes were inherited from a different agent, do not commit them; flag it so the owning agent can resolve it.
- New workspaces are always created with `git worktree add ~/src/worktrees/clawline-{agent-name} -b {agent-name}`.

## Code Reviews

Use **Codex** for code reviews (cross-validation with GPT):

```bash
codex exec -m gpt-5.2-codex -c model_reasoning_effort="xhigh" \
  "Review the code changes from: $(git diff HEAD~1). Look for bugs, security issues, and adherence to the DI pattern in COMMON.md."
```

Fallback if gpt-5.2-codex unavailable:
```bash
codex exec -m gpt-5.1-codex-max -c model_reasoning_effort="xhigh" "..."
```

## visionOS Platform Forks — Mandatory Reference

Before writing any `#if os(visionOS)` block in the shared `ios/Clawline/Clawline/` target, read:

**[`docs/visionos-platform-invariants.md`](./docs/visionos-platform-invariants.md)**

That document defines the **complete list** of valid platform differences. It is authoritative.

**Default rule: share the code.**

If your change adds a new platform fork that is not on the list, or removes/modifies an existing one — stop and raise it with Flynn before committing. Do not make a judgment call.
