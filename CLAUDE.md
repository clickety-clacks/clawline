# Claude Code - Clawline

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
