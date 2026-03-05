# Codex / AI Agents - Clawline

> The role of this file is to describe common mistakes and confusion points that agents might encounter as they work in this project. If you ever encounter something in the project that surprises you, please alert the developer working with you and indicate that this is the case in the AgentMD file to help prevent future agents from having the same issue.

> This is a greenfield app with no users. Feel free to suggest structural and breaking refactors to help bend this codebase into the right shape.


Follow the shared instructions in [COMMON.md](./COMMON.md).

## Code Reviews

Use **Claude** for code reviews (cross-validation with Opus):

```bash
$HOME/.claude/local/claude --model claude-opus-4-5-20251101 \
  -p "ultrathink Review the code changes from: $(git diff HEAD~1). Look for bugs, security issues, and adherence to the DI pattern in COMMON.md."
```

Alternative (staged changes):
```bash
$HOME/.claude/local/claude --model claude-opus-4-5-20251101 \
  -p "ultrathink Review the code changes from: $(git diff --staged)."
```

Note: "ultrathink" is appended to the prompt to enable extended thinking mode.

## Swift Safety Rules

- Do not use `try? await Task.sleep(...)` in cancellable flows unless the next line is an explicit cancellation guard before any side effect.
- Prefer `do { try await Task.sleep(...) } catch is CancellationError { return }` for cancellable delay paths.
- Avoid postfix force unwraps (`!`) in production code, except static URL literals with explicit code-review sign-off.
- In protocol/message handlers, do not silently drop decode/transform failures; log or surface an explicit failure path.

## GitHub Issue Hygiene

When working on GitHub issues, follow these rules:

1. **NEVER close an issue.** Only Flynn closes issues after testing.
2. **Comment when starting.** When you begin work on an issue, comment on it noting that you're starting.
3. **Post progress updates.** Comment on the issue as you work — what you found, what you changed, what you committed.
4. **Comment when done, don't close.** When finished, comment with a final summary (commit hash, what changed, deploy status) but do NOT close the issue.

## Shipping Discipline

- **Main-only shipping.** Only ship/deploy from `origin/main`. Do not deploy from pinned/local-only commits or non-main branches.

## Shipping Policy (Main Only)

- Ship only from `origin/main`. Do not request or expect deploys of pinned commits or branch SHAs.
- When reporting a fix, always state `pushed to origin/main @ <hash>` or `not on main yet`.

## iOS Git Workflow (Flynn Rule)

- Use a dedicated git worktree for each agent workspace, with each worktree on its own branch.
- `~/src/clawline/` stays the canonical deployer baseline; create agent worktrees under `~/src/worktrees/` (for example: `git worktree add ~/src/worktrees/clawline-{agent-name} -b {agent-name}`).
- Tear down with `git worktree remove <path>` (not `rm -rf`).
- YOLO on `main` is still allowed; agents can push to `origin/main` from their branch context when directed.

## Legacy Workspace Note (Before 2026-02-14)

- Legacy `cp -r` workspaces may still exist on eezo (for example `~/src/clawline-{name}/`) and are full repo copies rather than worktrees.
- Do not panic if you encounter one.
- If unstaged changes are yours, commit and push that work first, then proceed.
- If unstaged changes were inherited from a different agent, do not commit them; flag it so the owning agent can resolve it.
- New workspaces are always created with `git worktree add ~/src/worktrees/clawline-{agent-name} -b {agent-name}`.
