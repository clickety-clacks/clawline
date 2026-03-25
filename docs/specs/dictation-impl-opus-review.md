# Dictation Implementation Opus Review

Date: 2026-03-17

Review target:
- transcript-ownership cutover in `DictationCoordinator`
- `DictationTranscriptApplicator` compose-surface rebind replay
- `MessageInputBar` intent adapter and `ChatView` translation seam
- race conditions and invariant violations not caught by tests

## Execution Proof

Model:
- `claude-opus-4-5-20251101`

CLI:
- `/Users/mike/.claude/local/claude`

Invocation mode:
- inline prompt via stdin
- non-interactive review mode
- no tool/file reads exposed to the model

Exact command path and flags:

```bash
cat "$prompt_file" | /Users/mike/.claude/local/claude \
  --model claude-opus-4-5-20251101 \
  --print \
  --output-format text \
  --permission-mode bypassPermissions \
  --tools ""
```

Local prompt/output artifacts from the run:
- `/tmp/20260317-125912-dictation-impl-opus-prompt.txt`
- `/tmp/20260317-125912-dictation-impl-opus-output.txt`

Direct Opus output excerpt:

> ## BLOCKERS
>
> ### 1. Replay Plan Race Condition in Surface Rebind (DictationTranscriptApplicator.swift:69-73)
>
> **Issue:** When `setComposeTextView` is called during a rebind, `replayPlanProvider` is invoked synchronously.

And Opus verdict:

> ## Verdict: **Needs Fixes**

## Opus Findings

### Blockers

1. Replay-plan race on compose-surface rebind
   - Opus called out `DictationTranscriptApplicator.setComposeTextView(_:)` and the synchronous `replayPlanProvider` lookup as vulnerable to replaying stale or invalid session data if rebind happens after interaction teardown.
   - Evidence cited by Opus:
     - `DictationTranscriptApplicator.swift:69-73`
     - `DictationCoordinator.swift:384-386`

2. Missing re-entrancy guard in user-edit callback handling
   - Opus flagged `DictationCoordinator.noteComposeUserEditDuringDictation(...)` for not checking whether a programmatic update is in flight before mutating transcript ownership.
   - Evidence cited by Opus:
     - `DictationCoordinator.swift:557-559`
     - paired with applicator suppression flags at `DictationTranscriptApplicator.swift:154-159`

3. Selection-callback suppression timing may be too short
   - Opus flagged the applicator’s `dictationProgrammaticUpdateInFlight` lifecycle as potentially ending before UIKit finishes asynchronous selection callbacks.
   - Evidence cited by Opus:
     - `DictationTranscriptApplicator.swift:154-159`

### Non-Blockers

1. `walkieOrigin` may read as spec embellishment if the spec excerpt is treated narrowly.
2. Nil-tolerant host fallback in the applicator may mask host-lifetime bugs.
3. Some empty-string session-key guards may be redundant.

### Positive Findings

1. Opus explicitly agreed that the `MessageInputBar` intent seam is now clean.
2. Opus explicitly agreed that `ChatView` is translating intents rather than co-owning dictation state.
3. Opus did not find transcript ownership split across helper/view layers after the cutover.

## Adjudication

### Valid

1. Re-entrancy guard gap in `noteComposeUserEditDuringDictation(...)`
   - This is a real structural hole relative to the spec’s required suppression invariant.

2. Applicator suppression lifetime is probably too narrow
   - This is plausible and worth fixing defensively at the machine/applicator seam because the spec explicitly requires correct suppression of re-entrant user-edit and selection callbacks.

### Needs local verification before fixing

1. Replay-plan race on rebind
   - The general concern is valid, but the exact failure mode needs verification against current coordinator teardown semantics before changing code.
   - The current implementation only asks the coordinator for a replay plan; the coordinator remains the state owner. The open question is whether stale replay can actually happen in the current sequencing or whether the plan provider already returns `nil` in the only relevant teardown states.

### Rejected / downgraded

1. `walkieOrigin` as embellishment
   - Rejected. The canonical spec explicitly includes `walkieOrigin` in `TranscriptSession`, so this is not an unspecced addition.

2. Redundant empty-string guard
   - Downgraded to nit. It is not a compliance blocker.

## Current Step-6 Status

Step 6 adversarial review has produced blocking findings, so the review cycle is not exited yet. The next implementation pass should validate/fix the two confirmed suppression issues first, then rerun Opus for the next round.
