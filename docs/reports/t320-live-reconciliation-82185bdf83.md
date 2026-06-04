# T320 Live Tracker Reconciliation Evidence

Date: 2026-05-24

Ticket: T320

Reviewed source commit: `82185bdf83674c7787c832370cb180ac9bdd79ac`

Branch: `origin/clawline-message-composer-input`

Product scope: message bubble context menu/references plus compact reply/reference token follow-up.

Review verdict: implementation-owned review approved with no source blockers.

Review artifact: `eezo:/Users/mike/src/worktrees/clawline-message-composer-input/scratch/reviews/t320-reconciliation-review-fallback-20260524-010420.txt`

Focused gates from the reconciliation pass:

- `git diff --check`: passed.
- XcodeBuildMCP focused test `ClawlineTests/T320ReplyIndicatorProofXCTest`: passed, 4/4.
- XcodeBuildMCP Release simulator build: passed.
- Provider source proof in `/Users/mike/src/clawdbot`: `pnpm exec tsgo -p tsconfig.extensions.json --noEmit` passed.
- Provider focused vitest reference bridge tests passed.

Source proof areas covered:

- iOS title-bar tap menu source path.
- Sent user-bubble reply indicator source path.
- Reference-token deletion removes outgoing structured reference context.
- Client structured references plus provider Reference-to-LLM source bridge.

Remaining product proof after source review:

- No deploy, runtime restart, or live device/model proof was run in this pass.
- Flynn can verify after deploy that iOS/iPadOS title-bar tap opens the menu, the compact reply/reference token stays within the composer, sent replies show the in-bubble reply indicator, deletion of the composer token removes outgoing reference context, and the receiving model can use the referenced message.
