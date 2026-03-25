# Dictation State Machine Unification — Opus Adversarial Review v3

## Review Mode

This pass uses the Step 2 review mode from the spec-to-impl-review pipeline:

> spec agent runs Opus adversarial review

This artifact captures a real Round 1 Opus response with the full spec pasted inline to avoid the prior path permission gate.

## Execution Evidence

Command path:

```bash
/Users/mike/.claude/local/claude
```

Model:

```text
claude-opus-4-5-20251101
```

Exact command used:

```bash
spec=$(cat /Users/mike/shared-workspace/clawline/specs/dictation-state-machine-unification.md)
prompt=$(cat <<EOF
Review the following spec adversarially. Return only:
1. Top 4 blockers
2. Verdict: ready to implement, needs revision, or refactor itself is wrong
Keep it concise.

SPEC START
$spec
SPEC END
EOF
)
/Users/mike/.claude/local/claude --model claude-opus-4-5-20251101 -p "$prompt"
```

Direct Opus output excerpt:

```text
## Adversarial Review

### Top 4 Blockers

1. **No rollback plan for Phase 2 cutover.**
2. **`TranscriptSession` threading model unspecified.**
3. **Bridge "stateless" claim conflicts with weak host references.**
4. **Acceptance check 7 is circular.**

### Verdict

**Needs revision.**
```

## Round 1 Findings

Opus returned these blockers:

1. No rollback plan for Phase 2 cutover.
2. `TranscriptSession` threading model is unspecified.
3. The bridge "stateless" claim conflicts with weak host / text view lifecycle binding.
4. Acceptance check 7 is circular because it refers to external invariants without enumerating them.

Verdict from Opus:

```text
Needs revision.
```

## Adjudication

These findings are valid.

### Valid 1: No rollback plan for Phase 2 cutover

Why valid:
- The spec marks Phase 2 as the atomic ownership cutover and highest-risk step, but it does not state how to revert if the new transcript owner misbehaves after the switch.

Action:
- Add an explicit rollback strategy or safe-disable mechanism for the transcript ownership cutover.

### Valid 2: Concurrency / isolation model is unspecified

Why valid:
- The spec moves more state into `DictationCoordinator` but never states whether that unified machine is `@MainActor`, actor-isolated, or otherwise serialized.
- This is a real gap because the current code mixes transport callbacks, coalescing tasks, gesture events, and UI/editor callbacks.

Action:
- Add an explicit serialization rule for all machine mutations.

### Valid 3: Bridge lifecycle rebinding is under-specified

Why valid:
- The helper still depends on weak host / text view references.
- If the compose view is recreated while dictation is alive, the spec does not say how the machine rebinds the helper or how text application behaves while temporarily unbound.

Action:
- Specify rebinding behavior and the contract for "text surface unavailable during active dictation."

### Valid 4: Acceptance check 7 is not self-contained

Why valid:
- `Existing dictation UX invariants from shared workspace implementation details remain true` is not independently testable as written.
- A reviewer should not need to guess which external invariants are in scope.

Action:
- Inline the required dictation invariants or name them precisely in the spec.

## Multi-Round Status

This artifact is Round 1 only.

The Step 2 multi-round exit condition has not been met because:
- Opus returned blocking findings
- the spec has not yet been revised to address them
- no follow-up Opus round has been run against a revised spec

## Current Verdict

Not implementation-ready.

The refactor direction may still be right, but this spec needs revision before it should move to implementation.
