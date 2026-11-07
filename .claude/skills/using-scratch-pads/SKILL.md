---
name: using-scratch-pads
description: Using scratch/ for temporary files. Triggers on creating temp files, notes, scripts.
---

# Using Scratch Pads

## Purpose

Use `scratch/` for:
- Throwaway scripts
- Debug output
- External LLM review captures
- Temporary implementation notes

## NOT for specs

**Technical specs do NOT go in scratch/.** Use the `spec-homing` skill — specs live at `~/shared-workspace/{project}/specs/{specname}.md`.

In the spec-first workflow:
- Scratch can hold temporary brainstorming notes only.
- Final spec decisions must be promoted to the canonical shared spec file.
- Implementation agents must treat the canonical spec file as source of truth, not scratch files.

## Rules

- **NEVER COMMIT ANYTHING IN `scratch/`**
- If something needs versioning, move it to a tracked location first
- Clean up scratch files when done with a task
- Do not hand off scratch notes as authoritative spec artifacts

## Naming Convention

```
scratch/
├── review-2026-01-10.txt      # External LLM review output
├── debug-auth-flow.md          # Debug notes
├── test-script.swift           # Throwaway script
└── keyboard-fix-iterations.md  # Implementation exploration
```
