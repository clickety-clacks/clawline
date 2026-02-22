# Generative UI Guidance — Review & Contributions

**Reviewer:** Opus (subagent)
**Date:** 2026-02-18
**Source:** generative-ui-guidance.md (draft)

---

## Overall Assessment

The spec is well-structured and the two-layer split is sound. The "when to generate UI" vs "when to stay with text" framing is the right axis. The core principle — "when the user needs to make a choice, make it a tap" — is crisp and correct.

What follows: gaps I found, patterns missing, sharpened answers to the open questions, and new content to add.

---

## 1. Missing Concept: Bubble State Transitions

The spec treats bubbles as static artifacts that are either "active" or "closed." In practice, bubbles have a lifecycle with multiple visual states, and the spec should name them:

**Proposed states:**
- **Active** — interactive, accepting input
- **Pending** — user made a choice, waiting for agent to process (show spinner/disable buttons)
- **Resolved** — action completed, bubble collapses to a compact summary of what happened
- **Expired** — the decision window passed without interaction; visually muted, non-interactive

This matters because right now there's no guidance for what happens *between* the user tapping a button and the agent responding. That gap feels broken — the user taps "Deploy" and... nothing visually changes? The bubble should immediately transition to Pending state (disable buttons, show a subtle indicator) via local JS before the callback even reaches the agent.

**Add to Design Principles:**

> #### Immediate Feedback
> When a user interacts with a bubble, the bubble must visually acknowledge the interaction *before* the callback response arrives. Disable the tapped button, show a subtle loading state, or collapse the options to show only the selected one. Never leave the user wondering if their tap registered. This is local JS — it doesn't require a round-trip.

---

## 2. Missing Pattern: Confirmation Echo

When a user taps a button in a bubble, the agent's next message should briefly confirm what was selected. This creates a readable transcript:

> **Agent:** [Deploy card with device picker]
> **User taps:** ✓ Ansible, ✓ Aleph → Deploy
> **Agent:** "Deploying to Ansible and Aleph. SHA abc123."

Without this, the chat transcript (especially after compaction) becomes incoherent — there's a UI bubble, then an agent response that assumes context the text doesn't carry. The spec's "Graceful Degradation" section gestures at this but doesn't name the pattern explicitly.

**Add to Design Principles:**

> #### Transcript Coherence
> After a bubble interaction, the agent's next text message should echo the user's selection in natural language. The chat transcript must be readable as a conversation even if all bubbles were stripped out. Think of bubbles as accelerators for an interaction that *could* have happened in text — the text version should still exist in the transcript.

---

## 3. Missing Pattern: Mutation Bubbles vs. Read-Only Bubbles

The spec doesn't distinguish between bubbles that *change state* (deploy, approve, advance tracker) and bubbles that *display information* (comparison table, status dashboard). This distinction matters because:

- **Mutation bubbles** should be single-use: interact once, then resolve. Stale mutation bubbles are dangerous (what if the user taps "Deploy" on a bubble from 3 hours ago?).
- **Read-only bubbles** can stay rendered indefinitely. A comparison table is still useful to scroll back to.

**Add to Design Principles:**

> #### Mutation vs. Display
> Bubbles that trigger state changes (deploys, approvals, status transitions) are **mutation bubbles** — they must expire or self-disable after use or after a reasonable timeout. Bubbles that only present information (tables, charts, summaries) are **display bubbles** — they can remain rendered indefinitely. Never leave a mutation bubble active after the action has been taken or the context has changed.

---

## 4. Missing Anti-Pattern: The Premature Widget

The spec says "don't generate UI for UI's sake" but misses a subtler failure: generating UI *too early in the conversation*, before the shape of the decision is clear.

Example: Flynn says "I'm thinking about how to handle the deploy targets." CLU immediately generates a device picker. But Flynn wasn't asking to deploy — he was thinking out loud about the *architecture* of deploy targeting. The widget is irrelevant and interrupts the flow.

**Add to Anti-Patterns:**

> - **Premature widgetization** — don't generate UI for a decision the user hasn't actually reached yet. If the conversation is still in the "thinking about it" phase, stay in text. UI should arrive at the *moment of decision*, not before. When in doubt, ask in text first, then offer the widget: "Want me to pull up the device picker?"

---

## 5. Missing Anti-Pattern: The Unrecoverable Bubble

What happens when a bubble's JS throws an error? Or when the HTML is malformed? The spec mentions graceful degradation but doesn't address the agent's *response* to failure.

**Add to Anti-Patterns:**

> - **Silent bubble failure** — if a bubble fails to render or its JS errors, the user sees a blank or broken space with no way to proceed. Agents should detect missing callback responses (timeout) and follow up with a text fallback: "Looks like the UI didn't load — [here's the same question in text]." The client should also expose a render-failure signal back to the agent.

---

## 6. Missing Pattern: Progressive Enhancement in Chat

The spec positions UI and text as a binary choice. There's a powerful middle ground: **enhanced text** — messages that are primarily text but include small interactive elements.

Examples:
- A text explanation with an inline "Show me" button that expands a code block
- A status update with a single "Mark verified" button at the bottom
- A summary with a "See details" expander

This reduces the all-or-nothing feel. Not every interaction needs a full widget; sometimes you just need one button after two sentences.

**Add to "When to Generate UI":**

> #### Lightweight Enhancement
> Not every interactive moment needs a full UI bubble. When the message is primarily text but has one actionable element, use a minimal bubble: text content with a single button or a small interactive element. This avoids the cognitive overhead of a full widget while still eliminating the "type yes" friction. Think of it as a text message with a button stapled on.

---

## 7. Open Questions — Proposed Answers

### Q1: Bubble lifecycle — when does a bubble become stale?

**Answer:** Two rules:
1. **Mutation bubbles expire on action or timeout.** Once the user interacts, the bubble resolves immediately. If no interaction occurs, expire after a configurable window (suggest: 10 minutes for time-sensitive actions like deploys, 1 hour for low-stakes choices, never for display-only). The agent can set this via a `_ttl` hint in the bubble metadata.
2. **The client retires bubbles on scroll-away + time.** If a mutation bubble has scrolled off-screen and more than N messages have passed without interaction, auto-mute it (grey out, show "expired"). Don't silently delete — the user should see that a question was asked.

### Q2: Text response to a UI bubble — should the agent retire the bubble?

**Answer:** Yes, almost always. If the user types a text response instead of using the buttons, the agent should:
1. Interpret the text response as the answer
2. Send a `_close` to the bubble with a summary reflecting the text answer
3. Continue normally

The bubble was an *accelerator*, not a gate. If the user routes around it, respect that. The one exception: if the text response is clearly unrelated to the bubble's question (topic change), leave the bubble active — the user may come back to it.

### Q3: Should some bubbles survive compaction?

**Answer:** No. Compaction is a hard boundary. Any bubble that needs to persist beyond compaction should be externalized — written to a file, hosted as a page, or reconstructed from state. The agent can regenerate a settings panel from persisted config. Trying to preserve live interactive HTML across compaction creates ghost state that will eventually break.

### Q4: Template library?

**Answer:** Yes, strongly recommended, but as a *vocabulary* not a constraint. Ship 5-8 parameterized templates covering the most common patterns:
- Yes/No confirmation
- Multiple choice (buttons)
- Multiple choice (checklist + submit)
- Status card with actions
- Expandable detail card
- Comparison table
- Rating input
- Progress/status indicator

Agents can use these templates by reference (less tokens, faster, consistent look) or generate custom HTML when needed. Templates should be versioned and shipped with the extension. This also solves the "every agent generates slightly different button styles" problem.

### Q5: Cost/latency tradeoff?

**Answer:** The break-even is surprisingly low. Consider:
- A yes/no confirmation in text: agent asks (50 tokens) → user types "yes" (1 token + latency of typing + sending) → agent acknowledges (20 tokens). Total: ~70 tokens + human typing time.
- Same as UI: agent sends template reference + params (30 tokens) → user taps (0 tokens, instant) → agent acknowledges (20 tokens). Total: ~50 tokens, faster.

Templates make UI *cheaper* than text for structured interactions. Custom HTML generation is more expensive (~200-500 tokens for a simple widget), so the break-even is around 2-3 round-trips saved. Rule of thumb: if the UI eliminates even one clarification round-trip, it's worth it.

### Q6: Accessibility minimum?

**Answer:** Enforce these as hard requirements:
- All interactive elements must have accessible names (aria-label or visible text)
- Focus order must follow visual order
- Buttons must be keyboard-activatable (use `<button>`, not `<div onclick>`)
- Color must not be the only differentiator (add icons or text labels)
- Minimum contrast ratio 4.5:1 for text (use theme variables, which should already meet this)

Don't require full WCAG AA for generated bubbles — that's unrealistic for dynamic content. But the above five rules catch 90% of real-world accessibility failures and are easy to follow in generation.

### Q7: Mixed mode — text + bubble in one message?

**Answer:** Yes, allow it. The most natural pattern is text *followed by* an interactive element: "Here are the three deploy targets. Pick which ones:" → [checklist bubble]. Forcing these into separate messages creates an awkward gap. Implementation note: the message format should support a `parts` array where each part is either text or interactive HTML, rendered in sequence.

---

## 8. Missing Section: Error States & Recovery

The spec has no guidance for what agents should do when things go wrong with bubbles. Add:

> ### Error Handling
>
> **Callback timeout:** If the agent sends a bubble and receives no callback within a reasonable window (and the user has sent other messages), assume the bubble was ignored or broken. Follow up in text.
>
> **Invalid callback data:** If callback data is malformed or references stale state, don't silently fail. Acknowledge the interaction and explain: "That option isn't available anymore — here's the current state."
>
> **Bubble too complex to generate:** If the agent would need to generate >32KB of HTML, it's too complex for a bubble. Host it as a full page and send a link instead. The spec mentions the size limit but doesn't say what to do when you hit it.
>
> **Client doesn't support interactive HTML:** The agent should detect this (via client capabilities) and fall back to text + markdown. Never send interactive HTML to a client that can't render it.

---

## 9. Missing Section: Conversation Rhythm

This is the UX/HCI insight I think the spec most needs. Chat has a *rhythm* — a back-and-forth cadence that feels natural. UI bubbles can disrupt this rhythm if used carelessly.

> ### Conversation Rhythm
>
> UI bubbles change the turn-taking pattern of chat. In normal text chat, the rhythm is: agent speaks → user speaks → agent speaks. Bubbles introduce a different rhythm: agent presents → user interacts (silently) → agent responds.
>
> This matters because:
> - **Multiple bubbles in sequence feel like a form, not a conversation.** If you're sending 3+ bubbles back-to-back, you've built a wizard. Consider whether a single richer bubble (or a hosted page) would be better.
> - **A bubble after a long text explanation feels like a pop quiz.** Give the user a beat — maybe a one-line summary — before presenting the decision widget.
> - **Mixing bubble responses with text responses is jarring.** If the agent asks a question via bubble, responds to the callback, then asks the next question in plain text, the UX feels inconsistent. Try to maintain a consistent interaction mode within a conversation segment.
>
> The goal is that bubbles feel like a natural part of the conversation, not like the agent suddenly switched to a different application.

---

## 10. Layer 2 Addition: The "Show Me" Pattern

For CLU + Flynn specifically, there's a powerful pattern not mentioned:

> ### The "Show Me" Pattern
> When Flynn asks "what's the status of X" or "show me Y," the answer is often better as UI than text. CLU should develop the instinct to respond with a visual artifact:
> - "What's active?" → rendered board, not a bullet list
> - "Show me the deploy history" → timeline card, not a text dump
> - "What did agent-X report?" → output card with action buttons
>
> The trigger phrase is any variant of "show me," "what's the status," "where are we on," or "pull up." These are requests for *glanceable state*, and UI serves that better than prose.

---

## 11. Layer 2 Addition: Batch Interaction

> ### Batch Interaction
> Flynn often makes multiple decisions in rapid succession (morning triage, reviewing agent outputs, approving deploys). Optimize for this:
> - **Stack bubbles efficiently** — each one should be compact enough that 3-4 are visible on screen simultaneously
> - **Support "approve all" / "dismiss all"** — when multiple similar decisions are pending, offer a batch action
> - **Remember velocity** — if Flynn is rapidly tapping through approvals, don't slow him down with "are you sure?" confirmations. Save confirmation friction for irreversible or high-stakes actions.

---

## 12. Minor Structural Notes

- The "Design Principles > Payload Size" section mentions a 64KB hard limit on callback data but the 32KB target for HTML. These should be in a "Limits" callout box, not buried in prose.
- "Theming" should list the actual CSS variable names available (or reference where they're documented). Telling agents to "use CSS custom properties" without listing them means each agent will guess different names.
- The Layer 2 "Settings panel" pattern says "stays usable" — this contradicts the general guidance that mutation bubbles should expire. Clarify: a settings panel is a *display + mutation hybrid* that regenerates from persisted state, so it's safe to keep active but should be re-rendered (not preserved) after compaction.

---

## Summary of Recommended Changes

| Section | Change |
|---|---|
| Design Principles | Add: Immediate Feedback, Transcript Coherence, Mutation vs. Display |
| When to Generate UI | Add: Lightweight Enhancement |
| Anti-Patterns | Add: Premature Widgetization, Silent Bubble Failure |
| New Section | Error Handling & Recovery |
| New Section | Conversation Rhythm |
| Open Questions | Replace with proposed answers above |
| Layer 2 | Add: "Show Me" Pattern, Batch Interaction |
| Structural | Extract limits to callout, list CSS variables, clarify settings panel lifecycle |

The spec is solid foundation. These additions mostly fill gaps at the edges — the failure modes, the transitions, the rhythm. The core framing is right.
