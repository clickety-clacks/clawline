# Architecture Review: Stream Switch UI/Engine Separation

**Reviewer:** subagent (adversarial arch review)
**Date:** 2026-02-17
**Spec:** `stream-switch-coordinator.md`

---

## Principle-by-Principle Assessment

### 1. Pattern Propagation — **Pass**
The two-key split (UI intent vs engine activation) with epoch gating establishes a clean, replicable pattern. Any future feature needing immediate-UI + deferred-heavy-work can copy this shape directly. The reader classification table makes the pattern unambiguous for future agents.

### 2. Right-Weight — **Pass**
Three pieces of state (`uiSelectedSessionKey`, `engineActiveSessionKey`, `uiSwitchEpoch`) plus a debounce gate. No protocol hierarchies, no coordinator objects beyond what's implied, no type-level ceremony. This is the minimum structure to express the split.

### 3. Separation of Concerns — **Pass**
UI-intent readers and engine readers are cleanly partitioned with an exhaustive classification table. The coordinator/control reads (Section C) are explicitly called out as dual-key, not swept under either category. Responsibilities are clearly split.

### 4. Paired Deliverables — **Warning**
The spec itself is Deliverable A (the fix design). However, there is no explicit architecture retro artifact called out — no "what was tangled, why it regressed" narrative. The Problem Statement hints at it ("coupling causes first-visit stalls to leak into interaction/animation paths") but a paired retro doc explaining the regression history would complete this principle.

**Change needed:** Add a brief "Architecture Retro" section (or a separate paired doc) documenting: what the original coupling was, what regression it caused, and why the two-key invariant prevents recurrence.

### 5. Refactor Workflow — **Pass**
Spec-first, now under adversarial review, implementation deferred. This is the correct sequence.

### 6. State Mutation Seam Discipline — **Warning**
`uiSelectedSessionKey` has a clear single mutation point (step 3 of the switch flow). `engineActiveSessionKey` has a clear single mutation point (step 9, after epoch validation). Good.

**However:** The spec does not explicitly state that these are the *only* write paths. It doesn't say "no other code path may set `engineActiveSessionKey` directly." For a spec whose entire purpose is seam discipline, this invariant should be stated as a hard rule, not just implied by the flow diagram.

**Change needed:** Add an explicit invariant statement: "`engineActiveSessionKey` MUST only be mutated through the epoch-validated commit path (step 9). Direct assignment outside this path is a boundary violation." Same for `uiSelectedSessionKey` — only via intent receipt (step 3).

### 7. No Embellishment — **Pass**
Everything in the spec is necessary. The reader classification is exhaustive (every line number cited). No speculative features, no defensive additions beyond what's needed. The scope/out-of-scope section is tight.

---

## Additional Checks

### Reader Classification Completeness

**Warning:** `ChatView.swift:640` is classified as "control-plane/UI bridge" and says "watch `engineActiveSessionKey` for engine listeners; UI listeners move to `uiSelectedSessionKey`." This is a split-responsibility site — the spec should be more precise about what exactly happens at this line post-migration. Does this `onChange` hook split into two separate hooks? Or does it only watch one key? As written, an implementer could interpret this ambiguously.

**Potential misclassification:** `MessageFlowCollectionView.swift:977` ("resolved session key for scroll events") is classified as engine. But scroll events can be UI-interactive (e.g., user scrolling during a transition). If the collection view needs to know which page is visually selected for scroll-position purposes during the settle window, it might need `uiSelectedSessionKey`. Worth a second look — if the collection view is showing the *old* engine-active session's content during the debounce window, is that correct? The spec should explicitly state what the user sees during the 500ms debounce gap.

### Edge Cases

**Insufficient — missing edge case:** What happens during the 500ms debounce window? The user has swiped to stream B (`uiSelectedSessionKey = B`), but `engineActiveSessionKey` is still A. The collection view (bound to engine key) is still showing stream A's messages. What does the user see? A stale message list for 500ms? This is the central UX question of the entire spec and it's not addressed.

**Change needed:** Add an edge case or a "Transition UX" section that specifies what the message list shows during the gap between UI intent and engine commit. Options: (a) cached/placeholder content keyed to UI selection, (b) the old engine content until commit, (c) a loading state. The spec must pick one.

**Missing edge case:** App backgrounding during the debounce window. Does the delayed engine activation survive? Should it be cancelled? Restarted on foreground?

### Epoch-Based Cancellation Race Conditions

The epoch scheme is sound *if* the increment (step 2) and the UI key set (step 3) are atomic with respect to the scheduling (step 5). In Swift/MainActor context, if all of steps 2-5 execute synchronously on MainActor before yielding, there's no race. The spec should state this assumption explicitly: **"Steps 1-5 execute synchronously on MainActor without suspension points."**

If any async/await boundary exists between step 2 and step 5, a concurrent switch could increment the epoch between scheduling and capture, creating a lost-update race. The spec doesn't mention actor isolation.

**Change needed:** Add a concurrency note: "Steps 1-5 are synchronous on MainActor. No suspension point between epoch increment and task scheduling."

### Programmatic Selection

The spec says programmatic selection "uses same two-path contract" with engine key going through gating, with a parenthetical "(or explicit immediate policy if product requires, but still via same seam)."

**Warning:** This parenthetical is ambiguous. Either programmatic selection always goes through the debounce gate, or there's an immediate-commit path. If there's an immediate path, it needs to be specified (does it skip debounce but still validate epoch? Or bypass epoch entirely?). The parenthetical hedges rather than deciding.

**Change needed:** Make a decision. If programmatic selection (e.g., stream creation → auto-select new stream) should commit immediately, specify a `commitImmediately` flag on the intent that skips debounce but still goes through the epoch-validated commit seam. If it always debounces, remove the parenthetical.

---

## Overall Verdict: **REVISE**

The spec is structurally sound and the two-key split is the right design. The reader classification is impressively thorough. But four issues need resolution before implementation:

1. **[Must fix]** Specify what the user sees during the debounce gap (transition UX for message list).
2. **[Must fix]** Add explicit mutation seam invariants (only-write-path statements for both keys).
3. **[Must fix]** Decide on programmatic selection policy — remove the ambiguous parenthetical.
4. **[Should fix]** Add MainActor synchronous execution assumption for steps 1-5.
5. **[Should fix]** Add architecture retro narrative (paired deliverable).
6. **[Minor]** Clarify `ChatView.swift:640` post-migration shape and review `MessageFlowCollectionView:977` classification.
