# T206 Source/Review Matrix

Created: 2026-05-23
Worktree: `/Users/mike/src/worktrees/clawline-bubble-constraint-fix`
Commit under review: `e10474380fd2d6bf2c1f32c445bf5284321f5c1a`

## Source Contract

| Source | Requirement Used |
| --- | --- |
| `/Users/mike/shared-workspace/clawline/implementation_details/bubble-sizing-v2.md` | Cached measurements must never force a bubble narrower than `minWidth`; `minWidth` is the explicit BubbleSizingV2 plan floor. |
| `/Users/mike/shared-workspace/clawline/implementation_details/FILTERING-SUMMARY.md` | Preserve BubbleSizingV2 min-width floor and cache-key invariants without widening behavior. |
| `scratch/review-bubble-constraint-current-20260419-040221.txt` | Prior blocking review found the first implementation still left `preferredWidth(maxWidth:)` hardcoded to 120pt and had tests that could pass without exposing that floor. |
| T206 Janus context, retrieved 2026-05-23 | Ticket goal is the Bubble constraint fix plan implementation; current expected state is implementation/review proof, no deploy. |

## Implementation Matrix

| Surface | Current Source | Proof |
| --- | --- | --- |
| UIKit render constraint | `MessageBubbleUIKitView.configure(...)` resolves `effectiveMinWidth = bubbleSizingV2?.plan.minWidth ?? minWidthOverride ?? 120`, then assigns `minWidthConstraint.constant = effectiveMinWidth`. | V2 render path uses `Plan.minWidth`; legacy and non-V2 callers still fall back to `minWidthOverride` or 120pt. |
| Offscreen preferred-width measurement | `MessageBubbleUIKitView.preferredWidth(maxWidth:minWidth:)` accepts a `minWidth` parameter defaulted to 120; V2 measuring calls it with `plan.minWidth`. | Fixes the prior review blocker where the helper itself still imposed 120pt. Legacy callers preserve the 120pt default. |
| V2 measurement passes | `MessageFlowCollectionView.bubbleSizingV2Measure(...)` passes `minWidthOverride: plan.minWidth` in pass 0, provisional pass 1, and provisional pass 2, and clamps preferred width with `BubbleSizingV2.clamp(preferred, plan.minWidth, plan.maxWidth)`. | The shared V2 plan floor reaches the sizing view and measured width result. |
| Live remeasure/apply path | `MessageFlowCollectionView.applyMeasuredSize(...)` derives `plan.minWidth` when BubbleSizingV2 is enabled and feeds it to `enforcedLiveMeasuredWidth(...)`. | Bad live measurements below the V2 floor are clamped to `Plan.minWidth`; non-short bubbles still enforce max width. |
| Regression coverage | `BubbleScrollTests.bubbleSizingV2ShortBubbleUsesPlanMinWidthConstraint` uses `planMaxWidth = 200` and asserts preferred width is below 120; `bubbleSizingV2LiveRemeasureUsesPlanMinWidth` covers live short-bubble clamping below and above plan min. | The test now exposes the old 120pt preferred-width floor because max width is above 120. |

## Review Matrix

| Review/Gate | Result |
| --- | --- |
| Prior review before current patch | `scratch/review-bubble-constraint-current-20260419-040221.txt` found two blockers: hardcoded `preferredWidth` 120pt floor and insufficient regression. Both are addressed in current source. |
| Prior post-patch review | `scratch/review-bubble-constraint-postpatch-20260419-040544.txt` documents the corrected paths and no unresolved blocking finding in the current min-width propagation. |
| Fresh requested Codex review | `scratch/review-t206-current-20260523-142252.txt` failed because `gpt-5.2-codex` is unavailable to this account. |
| Fresh fallback Codex review | `scratch/review-t206-current-20260523-142307-fallback.txt` failed because `gpt-5.1-codex-max` is unavailable to this account. |
| Whitespace gate | `git diff --check` passed. |
| App build gate | XcodeBuildMCP simulator build for scheme `Clawline` on iPhone 17 Pro succeeded on 2026-05-23. |
| Focused test gate | Blocked before execution by unrelated `ClawlineTests` target compile errors: `UnifiedMarkdownRenderer.handleReleaseTriggeredLinkActivation` missing, `.preview`/`.presentActions` inference failures, and `ChatViewModelTests` attempts to assign inaccessible `lastPublishedReadState`. |

## State/Proof Notes

Tracker source disagreement remains:

- Direct local DB row on TARS reports T206 as `Deployable`.
- Janus constrained T206 context retrieved from TARS on 2026-05-23 reports canonical state/workflow lane as `In Progress`.
- Existing deployable proof package `PP_LEGACY_T206_DEPLOYABLE` is rejected as legacy/untrusted provenance.

No tracker transition was performed from this pass because the tracker sources disagree and the assignment explicitly forbids deploy. The exact remaining blocker for a protected deployable transition is trusted build/review proof rows in Tracker, plus resolution of the state-source mismatch.
