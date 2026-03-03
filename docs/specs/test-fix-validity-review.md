# Test Fix Validity Review

Date: 2026-02-27
Reviewer intent: launch separate Claude review agent, then audit commit-scoped test-fix validity.

## Scope
Commits reviewed:
- `f7615b1a3`
- `6514f11fa`
- `35ddcaea2`
- `e12959585`
- `37a3efac5`
- `9883e6b93`

## Claude Agent Status
Claude CLI invocation (`claude-opus-4-5-20251101`) was attempted and blocked by account quota (`You've hit your limit · resets 12am (America/Los_Angeles)`).
Manual commit/diff audit was performed as fallback.

## Pass/Fail by Area
| Area | Verdict | Findings |
|---|---|---|
| Markdown / Parsing | PASS | No test assertions were weakened. Fixes are implementation-side and still satisfy behavior intent for inline-code pipes, invisible-scalar fences, and malformed-fence fallback. |
| Messaging / Session | PASS | `Outbound sends respect active session selection` setup was stabilized (less retry churn, explicit connected-state gate) without reducing assertion strength on selected session key. |
| Bubble | PASS | `T089` control path now explicitly removes link-card signals; this strengthens the causal assertion (expand without cards = 1, with cards = 0). |
| Migration | PASS | No migration test weakening. Fix was implementation-side (`nonisolated deinit`) to avoid teardown crash; migration behavior assertion remains intact. |
| Keyboard / UI | PASS | `T093` expectation now matches computed transitional inset behavior. Drag persistence test remains behavior-focused and now handles bidirectional/clamped drags without becoming tautological. |
| Lifecycle / Visibility (incoming haptics fix batch) | PASS | `onAppear` now marks chat visible/foreground before token guard, addressing lifecycle precondition for tests without changing their assertions. |

## Concerns
- External Claude cross-review could not be executed due quota limits; this report is a manual fallback audit.
- Messaging scope note: within these six commits, only the active-session-send test setup changed directly; relaunch-prune/timeout-path fixes may be in neighboring commits outside this exact scope.
- UI drag test still uses fixed `sleep` windows, so residual flake risk is reduced but not eliminated.
