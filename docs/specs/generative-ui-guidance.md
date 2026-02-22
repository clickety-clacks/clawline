# Generative UI Guidance

**Tracker:** T087 | **Status:** Draft (opus-reviewed, merged)

## Target Files

**Layer 1 (all users):**
- Skill: `~/src/clawdbot/extensions/clawline/skills/interactive-html/SKILL.md`
- Always-on nudge: `clawline.systemPrompt` config field (or extension's contributed system prompt)

**Layer 2 (CLU + Flynn):**
- `~/.openclaw/workspace/AGENTS.md` — add section under existing workflow guidance

---

## Layer 1: General Guidance

### Core Principle

Choice = tap. State = scannable + actionable. Text = thinking in words. Everything else → UI.

### When to Use UI

| Pattern | Examples | Why |
|---|---|---|
| **Decisions** | Yes/no, multiple choice, approvals | Typing "yes" is friction |
| **Structured data** | Tables, timelines, ranked lists, multi-dimensional | Markdown tables are unreadable on mobile |
| **Drill-down** | Expandable sections, progressive disclosure | Flat dumps force scrolling past irrelevant content |
| **Forms** | Ratings, date pickers, multi-field input, config panels | Parsing free-text is fragile |
| **Actionable state** | Task lists with toggles, status + action buttons | Showing state without controls forces a round-trip |
| **Lightweight enhancement** | Text message + one button at the bottom | Eliminates "type yes" without a full widget |

### When to Use Text

Conversational reasoning. Single-fact answers. Emotional/tonal content. Exploratory back-and-forth. Pre-decision thinking (UI arrives at the moment of decision, not before).

### Bubble Lifecycle

**States:** Active → Pending (user tapped, awaiting agent) → Resolved (summary) → Expired (timed out)

**Mutation bubbles** (deploy, approve, advance state): single-use, expire on action or timeout (10min time-sensitive, 1hr low-stakes).
**Display bubbles** (tables, charts): stay rendered indefinitely.

### Design Principles

- **Immediate feedback:** On tap, disable buttons / show indicator via local JS before callback arrives.
- **Transcript coherence:** Agent's next message echoes the selection in text. Chat must be readable with all bubbles stripped.
- **Theming:** Use `--clawline-bubble-bg`, `--clawline-fg`, `--clawline-accent`. Never hardcode colors.
- **Viewport:** Always `<meta name="viewport" content="width=device-width, initial-scale=1">`. 44x44pt min touch targets.
- **Limits:** HTML payload <32KB. Callback data <64KB. No external resources. Over 32KB → host as page, send link.
- **Callbacks:** One atomic action each. `data` key (not `value`). Enough context to act without re-asking.
- **Degradation:** Don't put critical info only in HTML. Transcript must stand alone.
- **A11y:** Accessible names on all controls. Visual focus order. `<button>` not `<div onclick>`. Not color-only. 4.5:1 contrast.

### Conversation Rhythm

Multiple bubbles in sequence = form, not conversation. Bubble after long explanation = pop quiz (give a beat first). Mixing bubble and text questions in one segment feels inconsistent.

### Error Handling

- **Callback timeout:** Follow up in text.
- **Stale callback data:** Acknowledge interaction, explain current state.
- **Too large:** Host as page, send link.
- **Client can't render:** Detect via capabilities, fall back to text.
- **Render failure:** If no callback and user sends other messages, offer text fallback.

### Anti-Patterns

- **UI for UI's sake** — don't card-ify "done."
- **Text inputs in bubbles** — use chat input. Bubble forms only for structured/multi-field.
- **Stale mutation bubbles** — `_close` with summary when decision moment passes.
- **Overloaded bubbles** — tabs/nav/scroll regions = too far. Split or host as page.
- **Premature widgetization** — don't UI a decision the user hasn't reached. Text first, widget at decision point.
- **Silent failure** — detect missing callbacks, follow up in text.

### Template Library

Ship parameterized templates with the extension: Yes/No, multiple choice (buttons), multiple choice (checklist + submit), status card with actions, expandable detail, comparison table, rating input, progress indicator.

Agents reference templates (fewer tokens, consistent styling) or generate custom HTML when needed.

---

## Layer 2: CLU + Flynn Workflow Patterns

### Decision Surfaces
- **Deploy:** Device picker with checkboxes + deploy button (one interaction, not three messages).
- **Approvals:** Confirmation card (what will happen + approve/deny) for merges, deploys, deletions.
- **Tracker:** Status card with state buttons (In Progress / Deployable / Verified / Bounced).

### "Show Me" Pattern
Trigger: "show me," "what's the status," "where are we on," "pull up" → respond with visual artifact, not prose. Board for active work, timeline for history, output card with actions for agent reports.

### Batch Interaction
Morning triage, reviewing agent outputs, rapid approvals. Stack bubbles compactly (3-4 visible). Support "approve all" / "dismiss all." No "are you sure?" on reversible actions.

### Agent Oversight
Agent reports back → output card with Approve / Reject / Ask Followup / Deploy buttons. Review findings as expandable cards per finding.

### Settings
Regenerated from persisted config (not preserved across compaction). Current defaults + toggles.

---

## Resolved Questions

1. **Lifecycle:** Mutation bubbles expire on action/timeout. Display bubbles persist. Client auto-mutes scrolled-past mutation bubbles.
2. **Text response to bubble:** Interpret as answer, `_close` bubble, continue. Exception: topic change → leave active.
3. **Compaction:** Bubbles don't survive. Regenerate from state.
4. **Templates:** Yes, 5-8 parameterized. Reference by name.
5. **Cost:** Templates cheaper than text (~50 vs ~70 tokens + typing). Custom HTML breaks even at 2-3 saved round-trips.
6. **A11y:** 5 hard requirements (names, focus order, keyboard, not color-only, contrast).
7. **Mixed mode:** Yes. Text + interactive element in one message via `parts` array.

---

## Non-Goals

Implementation details (T031). UX polish bugs (T086). Bridge API definition (T087 tracking file).
