# T113 Spec Gap Analysis

**Date:** 2026-02-25
**Scope:** Why the per-stream-state-encapsulation spec allowed 14 transition surface findings (TS-1 through TS-14) to exist. What's missing from the spec as a model.

---

## What the spec covers well

The spec is strong in four areas:

1. **The seam contract.** Steps 1-8 of the stream-context switch seam are precise, correctly ordered, and cover the first-activation, switch, and same-key re-read cases. Every implementation of the seam itself has been correct across all audit rounds. No seam-internal bugs.

2. **Per-stream state inventory.** The `PerStreamRuntimeState` contents list is exhaustive. Every field that needed to be per-stream was identified and migrated. No field was missed.

3. **Timer/queue ownership.** The spec explicitly requires (sessionKey, generation) capture at schedule time and validation in callbacks. All 5 timer types comply. Every timer-related acceptance check passes.

4. **Mutation seam rule.** The `readState(for:)` / `mutateState(for:_:)` API requirement and the "no fallback to active key" guardrail are clear and correctly implemented.

These four areas are why the *new code* passes all 25 acceptance checks when evaluated in isolation.

---

## What the spec does not cover

Every transition surface finding maps to one of five missing models. In order of impact.

### Gap 1: No caller inventory for migrated APIs

**Findings caused:** TS-1 (BLOCKING)

The spec defines `update(...)`'s new contract: explicit `sessionKey`, explicit callbacks, explicit `forceReReadGeneration`. It then specifies the migration strategy as "rely on compiler errors to find remaining direct references" (step 7).

Swift default parameters defeat this strategy. `update(... sessionKey: String? = nil ...)` compiles identically before and after the migration. A caller that was valid in the single-session world remains valid (compiles, runs, produces no warnings) in the per-stream world — but with silently broken semantics because `nil` now means "fall back to engine active key" instead of "there is only one key."

`viewDidLayoutSubviews` was never touched by the migration because it compiled without errors. It called `update()` with 9 of 14 parameters, relying on defaults for the rest. Before the branch, those defaults were harmless. After the branch, they broke session isolation.

**What the spec should have said:**

> For any public or internal method whose parameter set is extended by this migration, the implementation must enumerate ALL existing call sites (not only new ones) and verify that default parameter values preserve the pre-migration behavioral contract for each caller. Swift default parameters are invisible contract changes — a compiling call site is not proof of correctness.

Or more directly: session-critical parameters on `update()` should not have defaults. Forcing every caller to pass them explicitly would have made `viewDidLayoutSubviews` a compile error, caught instantly.

---

### Gap 2: No async continuation contract (beyond timers)

**Findings caused:** TS-2, TS-4/TS-10, TS-8, TS-11, TS-12, final verification stale-morph

The spec has a Timer / Queue Ownership section that requires generation-gated callbacks. But its scope is narrow: it names timers, deferred queues, and scroll-to-bottom retry work items. It does not generalize to ALL async continuations.

The controller has at least four additional async patterns that the spec does not address:
- `DispatchQueue.main.async` for layout/reconfigure scheduling (TS-2, TS-11)
- `DispatchQueue.main.async` + `UIView.animate` completion for morph (TS-4/TS-10)
- `DispatchQueue.main.async` for viewport anchor compensation (TS-8)
- Animated scroll completion via `scrollViewDidEndScrollingAnimation` (TS-12)

Each of these reads or writes per-stream state after yielding the main actor, without the (sessionKey, generation) guards the spec requires for timers.

**What the spec should have said:**

> **Async continuation rule (universal).** Any closure, callback, animation completion, or deferred block that (a) executes after yielding the current main-actor turn, AND (b) reads or writes per-stream state, must capture `(sessionKey, generation)` at schedule time and validate both before any state access. This applies to `DispatchQueue.main.async`, `UIView.animate` completions, `DispatchWorkItem` callbacks, `NotificationCenter` observers, and `scrollViewDidEndScrollingAnimation`. The Timer / Queue Ownership section is a specialization of this rule, not the whole rule.

This single sentence would have prevented TS-2, TS-4, TS-8, TS-10, TS-11, and TS-12.

---

### Gap 3: No async operation lifecycle model (setup → yield → cleanup)

**Findings caused:** TS-10 guard-failure stale state (final verification)

Even after the morph guards were added (correctly validating session + generation), the early-return paths leave `morphTargetMessageId` and `deferScrollToBottomUntilMorphCompletes` stale. This is because the morph has a multi-phase lifecycle:

1. **Setup (synchronous):** Set `morphTargetMessageId`, set `deferScrollToBottomUntilMorphCompletes`.
2. **Yield:** `DispatchQueue.main.async` → `UIView.animate`.
3. **Cleanup (async completion):** Clear `morphTargetMessageId`, clear `deferScrollToBottomUntilMorphCompletes`.

The spec has no model for this pattern. It says "validate before mutating" but doesn't address "clean up pre-conditions set before the yield." When a guard fires in step 3, the cleanup is skipped, but the setup from step 1 persists in per-stream state.

**What the spec should have said:**

> **Multi-phase async operation contract.** When a per-stream operation sets state in a synchronous phase and defers cleanup to an async completion, ALL exit paths in the async phase — including guard-failure early returns — must clean up the synchronously-set state. Setting `morphTargetMessageId` synchronously and clearing it only in the success path is a spec violation. Pattern: capture pre-set values at setup time, restore/clear them in every async exit path.

---

### Gap 4: No property shim safety model

**Findings caused:** TS-2, TS-5, TS-7 (minor/cosmetic)

The spec requires explicit session-keyed access (`readState(for:)`, `mutateState(for:_:)`). The implementation uses property shims that route through `activeStateKey()` for convenience — e.g., `morphTargetMessageId` is a computed property that reads from `readState(for: activeStateKey()).morphTargetMessageId`.

The spec doesn't address shims at all. It doesn't say they're allowed or forbidden. It doesn't classify which contexts shim access is safe (synchronous single-line reads during a bound update cycle) vs. dangerous (inside async closures where `activeStateKey()` may have changed).

The findings here are all minor because shim access in sync context is generally correct (the session key is stable within a single main-actor turn). But shim access in async closures is the root of TS-2, and shim access in `deinit` is the root of TS-5.

**What the spec should have said:**

> **Shim access rule.** Property shims (computed properties routing through `activeStateKey()`) are permitted only in synchronous call paths where `activeStateKey()` is guaranteed to be stable (within a single `update()` → apply → layout cycle). Any closure that may execute in a different main-actor turn must use explicit `readState(for: capturedSessionKey)` / `mutateState(for: capturedSessionKey)`, not shim properties. Shim access inside `DispatchQueue.main.async`, animation completions, timer callbacks, or `deinit` is a spec violation.

---

### Gap 5: No emission frequency / idempotency contract

**Findings caused:** TS-3, TS-13 (performance / minor)

The spec defines WHAT SBB events should be emitted and their ownership rule, but not HOW OFTEN. There's no guidance on:
- Whether `force: true` emissions are appropriate on every update cycle (TS-3) or only on actual state transitions.
- Whether the same-key re-read path needs a forced emission (TS-13) or whether change-detection is sufficient.

These are performance issues, not correctness bugs, but they were flagged because the spec gave no basis for deciding.

**What the spec should have said:**

> **Emission idempotency rule.** SBB and scroll event emissions must be idempotent. Emissions on the steady-state (no-switch, no-re-read) path must use change detection (`lastReportedHideIndicator != shouldHide`), not forced emission. Forced emission (`force: true`) is permitted only on session switch (new session's state must be reported regardless of prior emission cache) and on transitions that invalidate the emission cache (e.g., `lastReportedHideIndicator` reset). This prevents per-frame dictionary mutations in SwiftUI state.

---

## The meta-gap: the spec models new code, not the boundary

All five gaps share one root cause: **the spec models the behavior of new per-stream code, not the contract between new code and existing code.**

The spec answers: "How should per-stream state work?" It never answers: "What obligations does per-stream state impose on the code that was already there?"

Specifically:

| The spec defines | The spec does not define |
|---|---|
| `PerStreamRuntimeState` contents | Which existing callers must change their call signatures |
| The seam contract (steps 1-8) | Which existing async patterns must add session guards |
| Timer ownership rules | That these rules apply to ALL async continuations, not just timers |
| `readState(for:)` / `mutateState(for:_:)` | When property shims are safe vs. dangerous |
| What events to emit | How often to emit them |

This is a **boundary specification gap**. The spec is a complete description of a subsystem. It is not a complete description of the subsystem's integration surface. Every finding in the audit lived at the integration surface.

---

## What would have prevented most findings by construction

A single additional spec section — **Transition Surface Contract** — defining three rules:

1. **No silent defaults on session-critical parameters.** Any method parameter that controls session binding must be required (no default value) or must have a default that is provably safe for ALL existing callers. If a safe default is impossible, the parameter must be required.

2. **Universal async continuation rule.** Any closure executing after yielding the main actor that touches per-stream state must capture and validate `(sessionKey, generation)`. This is not limited to timers. This applies to every `DispatchQueue.main.async`, every `UIView.animate` completion, every `scrollViewDidEnd*` delegate.

3. **Async lifecycle cleanup invariant.** Any per-stream state set synchronously as a pre-condition for an async operation must be cleaned up in ALL exit paths of the async continuation, including guard-failure early returns.

Rule 1 prevents TS-1 (the only BLOCKING finding). Rule 2 prevents TS-2, TS-4, TS-8, TS-10, TS-11, TS-12. Rule 3 prevents the stale-morph cleanup gap. Together they cover 10 of 14 findings by construction. The remaining 4 (TS-3, TS-5, TS-6, TS-7) are performance/cosmetic issues that require domain-specific judgment, not structural rules.

---

## Recommendation

Add a **Transition Surface Contract** section to `per-stream-state-encapsulation.md` containing the three rules above, so future changes to this controller — and future specs that restructure shared state behind new keying models — carry the integration obligations alongside the subsystem design.
