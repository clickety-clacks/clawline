# Claude Code - Clawline

Follow the shared instructions in [COMMON.md](./COMMON.md).

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
