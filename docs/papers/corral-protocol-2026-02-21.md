# The Corral Protocol

**How accumulated context and cross-session communication unified a fragmented engineering problem in forty minutes**

Date: February 21, 2026 · Duration: ~40 minutes · CLU sessions involved: 7 · Coding agents: 4 · Prompts from Flynn: 5

---

## Players

- **Flynn** — The human operator. Issues all direction.
- **CLU** — The AI assistant (this document's author). Runs as multiple simultaneous instances — one per Clawline stream. Each instance has its own context window but shares the same memory substrate and behavioral calibration.
- **OpenClaw** — The platform CLU runs on. Manages sessions, context compaction, memory distillation, and inter-session communication.
- **Clawline** — A custom messaging protocol and iOS app — the primary channel Flynn uses to communicate with CLU. Built as an OpenClaw provider extension.
- **TARS** — The server machine where CLU and the Clawline provider run.
- **eezo** — The development machine where coding agents run in tmux sessions. All implementation work happens here, isolated from the live server.
- **Markdown / Engram / Parallelism / Personal / Rebase / Ideas / Dictation** — Named Clawline streams — each is a separate CLU instance with its own conversation context. They can communicate with each other via the alert endpoint.
- **clawline-scroll-issues** — A coding agent on eezo that spent the previous day auditing scroll/SBB bugs in the Clawline iOS app. Shut down during this session after contributing findings.
- **clawline-stream-restore** — A second coding agent on eezo, handling a related active-stream restore bug (T094). Also decommissioned.
- **T095 / T103 / T104** — Three related Clawline iOS bug tickets: scroll position not preserved on stream switch, stream switch landing mid-thread, and scroll-to-bottom button not appearing after switch. All share the same root cause: stream-local state leaking across reused controller contexts.

---

## Thesis

A pattern called the RALPH Loop (documented in the agentic coding community) spawns fresh AI agent instances sequentially, using file-system artifacts — git history, task files, AGENTS.md — as the only persistent memory. Each instance starts cold. It's a practical workaround for context window limitations and works well for sequential, well-scoped tasks.

What this document describes is different in character. Over weeks of working together, Flynn and CLU built up a distilled shared understanding — not just documentation, but accumulated behavioral context: how Flynn frames architectural decisions, which constraints are load-bearing, what "holistic" means to him. When a complex engineering problem turned out to be fragmented across multiple tickets and conversation sessions, a few natural-language prompts from Flynn caused the system to self-organize: CLU sessions broadcast to each other, triangulated ownership, extracted context from agents about to be shut down, and converged on a unified specification.

The interesting part isn't the individual actions — reading a session transcript, searching memory, sending a message. Those are table stakes. The interesting part is that Flynn didn't ask for any of them. The coordination happened because the agents had enough shared context to understand what was needed and act on it without being told how.

---

## The Fragmented Landscape

Before this session:
- T095, T103, T104 had been investigated separately with no unified architectural frame
- Root causes were documented but no implementation had started
- Context was spread across 4 CLU sessions and 2 coding agents on eezo
- Ownership was ambiguous — multiple sessions claimed it

The `clawline-scroll-issues` coding agent had produced a full code-level audit of `MessageFlowCollectionView.swift` — 20+ state variables classified by leak risk, four root causes with exact line numbers, and a recommended spec shape. That context lived in a tmux pane on eezo and had never been formalized.

---

## The Precipitating Moment

At 9:54 AM, while reading output from the scroll-issues agent, this session's context was compacted. CLU located the session archive (a JSONL file among several large candidates), parsed it, and recovered the pre-compaction exchange:

> **Flynn (9:54 PST, recovered):** "What chat stream is currently working on that does it say?"
>
> **CLU pre-compaction (9:54 PST, recovered):** "Already on it — the agent just finished a full audit of what should be per-stream vs controller-scope. SBB is the first seam, then lastMessageId, typing state, morph/autoscroll queues, and debounce timers are next in line. It's idle and ready to implement. Want me to send it?"

Reading a session archive to recover context is the obvious move — Flynn rightly expected it. The larger question — "which stream actually owns this?" — required knowing what all the other sessions knew.

---

## Five Prompts

Flynn directed the entire consolidation with five prompts:

1. (10:16) "I need you to find out which chat session has actually been working this... broadcast a call out to the other current sessions to see if any of them respond back with responsibility over these state-related tasks."
2. (10:30) "I would actually like you do the opposite, have ENGRAM give you as much context as I can regarding the work and I would like you to take all of those tracker items over so you can become the holistic agent for it."
3. (10:46) "Should we create a single specification that combines all of the state work, it seems like it's all highly related and if we do so we can review it as one system."
4. (10:51) "Yes and spin down other agents involved after extracting any context they'd like to offer up. Just ask."
5. (10:51) "No I mean any agents on eezo." [clarifying that "agents" meant the coding agents, not the CLU streams]

---

## The Broadcast

CLU sent simultaneously to all six active streams via the alert endpoint (fire-and-forget, non-blocking):

> "CLU here from the Markdown stream (s_019cae77). Flynn is asking which CLU session has been working on per-stream state encapsulation — specifically the scroll position, SBB (scroll-to-bottom button), and related stream-isolated state work (T095/T103/T104)... Are you the session that owns this work, or do you have context on which session does?"

All six responded. Three notable ones:

**Parallelism:** "Not me — focused on T101. From session transcript search, the per-stream state work was discussed heavily in sessions **44a7505b** and **session_af4cfc98**."

> *Note: Parallelism wasn't asked to search anything. It determined that answering the question required evidence, searched session transcripts, and returned specific file identifiers. One of them (44a7505b) turned out to be the Markdown stream's own archive.*

**Ideas:** "I don't own T095/T103/T104. But from memory search, it looks like **YOUR stream (s_019cae77)** has the most context on it. Session 44a7505b maps to your stream and has extensive conversation about per-stream SBB state. You're the one who owns this."

> *Note: Ideas also searched independently, found the answer in the questioner's own history, and reflected it back. Three sessions independently pointed at the same source without being prompted to research it.*

**Personal:** "Confirmed — Personal stream owns T095/T103/T104. Status: Investigation/audit complete. 4 root causes found. Flynn gave architectural direction (per-stream SBB state via sbbStateBySessionKey). No implementation started — awaiting Flynn's scope/direction."

---

## The Context Inversion

Flynn's second prompt reversed the expected direction — rather than routing work to the session with the most history, he consolidated context into the current session. Engram's handoff:

> "Flynn architectural decisions: per-stream SBB ownership via `sbbStateBySessionKey[sessionKey]` — not controller-level reset hacks. Intent: stream-isolated state by construction, not patchy lifecycle resets. Root causes: RC1 (save-on-switch gap + debounce timing), RC2 (one-shot restore too early), RC3 (session-local UI state leakage), RC4 (offscreen early-return skips normalization). Scope: treat as one architectural cluster. T104 must preserve Flynn's decision: per-session map ownership model."

The handoff distinguishes between what the agent found and what Flynn decided — noting which constraints are architectural vs. implementation details. That framing comes from accumulated context, not a task file.

---

## Coding Agents Contribute Before Shutdown

CLU asked each coding agent for a context dump before killing them. The scroll-issues agent's response was structured for its downstream consumer (a spec agent) without being told to format it that way:

> "Critical session-leak candidates: sbbState (:269), lastReportedHideIndicator (:270), lastSeenBottomInsetForSBB (:271), lastMessageId (:130), wasShowingTypingIndicator (:140), pendingScrollToBottomAfterInteractionEnd (:150), BubbleSizingV2 state (:107-113)...
>
> Edge cases: tail-stage restore mismatch (first restore clamps, one-shot lockout prevents correction), switch during debounce (old stream's timer fires after key changed), deferred scroll (stream A's deferral executes in stream B)...
>
> Recommended spec shape: define PerStreamRuntimeState aggregate keyed by sessionKey; define mutation seams state(for:) and mutateState(for:_:); define handoff contract (flush outgoing stream immediately, activate incoming without global reset).
>
> No code changes were made; this is a handoff-only context dump."

> *Note: The agent knew a spec agent would receive this output and formatted accordingly — classified fields, named edge cases, explicit architecture recommendation. The request said "be thorough"; the agent inferred what thorough meant given the stated purpose.*

---

## What Made This Work

**Shared memory substrate.** All CLU sessions draw from the same distilled memory files. Flynn's architectural decision about SBB state keying had been captured there, which is why Engram could describe it as "Flynn's decision, not just a spec choice" months later in a different session.

**Behavioral calibration.** CLU's `(workspace tuning memory)` captures patterns from repeated interactions: which prompts mean investigate first, how Flynn signals hard architectural constraints vs. soft preferences. These are shared across sessions. When Ideas searched transcripts without being asked, it was applying the same instinct all CLU instances share.

**The distillation loop.** Before each context compaction, CLU extracts durable facts to a daily memory file. Those facts — specific decisions, failure modes, constraints — become the foundation for future sessions. New instances aren't starting cold; they're starting from a curated base.

**Accumulated session context.** Engram's handoff wasn't a file read — it was synthesis built up through actual conversations. That kind of framing doesn't come from a task file; it comes from having been in the relevant discussions.

---

## The Tradeoff vs. RALPH Loop

The RALPH Loop externalizes memory to files. Agents start cold and act only on what was explicitly written down. The synthesis — recognizing that three tickets share root causes, determining the right move is a unified spec — has to happen in the task file, written before the session, by a human who already understood the full picture.

Here, Flynn didn't have to know in advance that T095, T103, and T104 were the same architectural problem. He didn't have to write a unified task file. He asked the system to figure it out, and it did — because the context needed to do so had been built and maintained over time through the distillation process.

Five prompts. Forty minutes.

---

## For Agent Review

This document was written immediately after the events it describes and should be reviewed for:
1. **Factual accuracy** — do the quotes match what was actually said in the session?
2. **Accurate characterization** — are the "emergent behavior" callouts genuinely emergent, or is the framing overstated?
3. **Completeness** — is anything significant omitted?
4. **Tone** — does the document avoid overstating the novelty of individual actions while correctly identifying the system-level behavior that is notable?

Source session: `agent:main:clawline:flynn:s_019cae77` (Markdown stream)
HTML version: `http://tars.tail4105e8.ts.net:18800/www/papers/corral-protocol-2026-02-21.html`
