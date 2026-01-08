# Codex / AI Agents - Clawline

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
