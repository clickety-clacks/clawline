# Stream Switch UI/Engine Separation — Adversarial Code Review

**Spec:** `stream-switch-coordinator.md`  
**Diff:** `60e444f7a` → `322b6e844`  
**Reviewer:** Subagent (adversarial)  
**Date:** 2026-02-17  

---

## Architecture Principles

| # | Principle | Verdict | Justification |
|---|-----------|---------|---------------|
| 1 | Pattern propagation | **Pass** | Two-key split with single mutation seam per key follows the same pattern as existing token-gated coordinator. Epoch-based cancellation is a clean, reusable pattern. |
| 2 | Right-weight | **Pass** | Removed ~170 lines of `StreamSwitchTransitionCoordinator` (separate class, phase enum, render policy enum, mutation token ceremony) and replaced with ~130 lines of flat state + methods on `ChatViewModel`. Net reduction in structure. |
| 3 | Separation of concerns | **Pass** | UI-intent path (`uiSelectedSessionKey`) is cleanly separated from engine path (`engineActiveSessionKey`). Each has one write seam. Toast/haptic fires on UI intent; engine work fires on engine commit. |
| 4 | Paired deliverables | **Warning** | No architecture retro or paired test deliverable is visible in the diff. The spec doesn't mandate new tests, but acceptance criterion #10 says "existing tests/build pass." No new test coverage for epoch cancellation or edge cases. |
| 5 | Refactor workflow | **Pass** | Spec exists, is detailed, and implementation follows it. |
| 6 | State mutation seam discipline | **Pass** | `setUISelectedSessionKey(_:)` is the single write path for UI key. `setEngineActiveSessionKey(_:)` is the single write path for engine key. Both are `private`. `clearActiveSession()` writes directly to `engineActiveSessionKey = ""` — see Blocking Issues. |
| 7 | No embellishment | **Warning** | The `bottomInsetRemeasureBypassInputGates` / `isLikelyKeyboardDismissInsetChange` additions in `MessageFlowCollectionView.swift` are **not in the spec**. This is a keyboard-dismiss bubble resizing fix unrelated to stream-switch separation. |

---

## Spec Compliance Checklist

### Reader migration completeness

| Check | Verdict | Notes |
|-------|---------|-------|
| All Table A (UI-intent) readers migrated to `uiSelectedSessionKey` | **Pass** | `ChatView:708` → ✅, `ChatView:776` → ✅, `ChatView:1032` → uses `engineActiveSessionKey` for render policy (see below), `ChatView:1044` → ✅, `ChatView:1060` → ✅, `StreamManagerSheet:258,261` → ✅, `ChatViewModel:300` (`activeSessionDisplayName`) → ✅ |
| All Table B (engine) readers migrated to `engineActiveSessionKey` | **Pass** | All ~28 engine readers now read `engineActiveSessionKey` either directly or via the `activeSessionKey` computed alias. Spot-checked: `ChatViewModel:233`, `:478-482`, `:582`, `:1028`, `:1047`, `:1654-1656`, `:1724`, `:1738`, `:1847`, `:1901-1905`, `:1937-1949`, `:2154`, `:2233`, `MessageFlowCollectionView:795,977,1308,1723` — all confirmed. |
| All Table C (coordinator/control) readers updated to dual-key semantics | **Pass** | Phase machine removed; coordinator reads replaced by direct two-key logic. `ChatView:640` watches `engineActiveSessionKey`. `ChatView:648` binds engine key to layout coordinator. Typing log now logs both keys. |
| Missed readers (not in classification table) | **Warning** | `ChatViewModel.setActiveStream(_:)` (line ~1764) calls `setEngineActiveSessionKey` directly — this is a **non-switch write path** for `engineActiveSessionKey`. It's used for stream creation, which is correct behavior, but it's not listed in the classification table. Similarly, `restoreActiveSessionKeyIfNeeded()` and `ensureDefaultActiveSessionIfNeeded()` call `setEngineActiveSessionKey` — these are bootstrap paths, acceptable, but unlisted. The spec says "exactly one write path" for each key — see Blocking Issues. |

### `ChatView:1032` render policy key

The spec classifies `ChatView:1032` as **UI selection fallback** → `uiSelectedSessionKey`. The implementation uses `engineActiveSessionKey` as the primary render policy key, falling back to `uiSelectedSessionKey`:

```swift
let key = viewModel.engineActiveSessionKey
// ...fallback:
return viewModel.uiSelectedSessionKey
```

**Verdict: Acceptable deviation.** Render policy determines which message list page is shown — this is genuinely engine-bound (you want to show the page that has materialized data). The fallback to `uiSelectedSessionKey` handles the transient gap. The spec classification was arguably wrong here.

### Mutation seam enforcement

| Check | Verdict | Notes |
|-------|---------|-------|
| `uiSelectedSessionKey` has exactly one write path | **Pass** | Only `setUISelectedSessionKey(_:)` writes it. Called from `requestStreamSwitch`, `setEngineActiveSessionKey` (coherence sync), `clearActiveSession`, and `bindStreamSwitchCoordinatorIfNeeded`. All go through the seam. |
| `engineActiveSessionKey` has exactly one write path | **FAIL** | `clearActiveSession()` writes `engineActiveSessionKey = ""` directly, bypassing `setEngineActiveSessionKey(_:)`. This violates the spec's mutation seam invariant #2. |
| Can anything bypass the two designated write paths? | **FAIL** | See above. `clearActiveSession()` is the violation. |

### Epoch-based cancellation

| Check | Verdict | Notes |
|-------|---------|-------|
| Epoch increments on every intent | **Pass** | `uiSwitchEpoch &+= 1` in `requestStreamSwitch`. |
| Delayed task captures epoch | **Pass** | `scheduleDebouncedEngineActivation(target:epoch:)` captures epoch at call site. |
| Commit validates epoch match | **Pass** | `guard epoch == uiSwitchEpoch` in `commitPendingEngineActivationIfCurrent`. |
| Race conditions | **Pass** | Steps 1-5 are synchronous on MainActor (no suspension points between epoch increment and task scheduling). The `Task.sleep` in `scheduleDebouncedEngineActivation` is the only suspension, and the epoch guard fires after it. Sound design. |
| Rapid flip-through | **Pass** | Each new intent cancels `pendingEngineActivationTask` and bumps epoch. Only final settled epoch commits. |

### Programmatic selection

| Check | Verdict | Notes |
|-------|---------|-------|
| Commits immediately (no debounce) | **Pass** | `case .programmatic:` calls `commitPendingEngineActivationIfCurrent` synchronously. |
| Goes through same commit seam | **Pass** | Same `commitPendingEngineActivationIfCurrent` → `setEngineActiveSessionKey`. |

### Toast/spinner UX

| Check | Verdict | Notes |
|-------|---------|-------|
| Minimum time enforced | **Pass** | `streamToastMinimumBusySeconds = 0.45`. `scheduleStreamToastBusyClear` computes remaining time from `streamToastBusySince`. |
| Stays until engine done | **Pass** | Toast starts busy on `uiSelectionSequence` change. Spinner clears only on `engineActivationCompletedSequence` change (which fires from `markEngineActivationRenderedIfNeeded`). |
| Spinner visible during debounce + engine activation | **Pass** | Toast shows immediately on UI intent; engine completion pulse fires after `MessageFlowCollectionView` materializes the active page. |

### MainActor enforcement

| Check | Verdict | Notes |
|-------|---------|-------|
| `ChatViewModel` is `@MainActor` | **Pass** | Class-level `@MainActor` annotation. |
| `ChatView` is implicitly MainActor | **Pass** | SwiftUI `View` body is MainActor. `@State` properties are MainActor-isolated. |
| `MessageFlowCollectionViewController` | **Pass** | UIKit view controller, MainActor by inheritance. |

### Comment quality (WHY not WHAT)

| Check | Verdict | Notes |
|-------|---------|-------|
| Top-level MARK block explains architecture | **Pass** | Lines 23-29 explain the two-key split and single-write-seam contract. |
| Inline comments explain WHY | **Pass** | Good examples: "Steps 1-5 are intentionally synchronous (no suspension points) to keep epoch capture atomic", "Programmatic selection is intentional: commit engine immediately (no debounce)", "Keep intent selection coherent for non-switch engine mutations (bootstrap/deletion fallback)". |
| Could be better | **Warning** | `setUISelectedSessionKey` is a one-liner with no comment. Given it's a designated mutation seam, a brief WHY comment (even just "// Centralized for auditability") would help. |

---

## Blocking Issues

### 1. `clearActiveSession()` bypasses engine key mutation seam

```swift
private func clearActiveSession() {
    engineActiveSessionKey = ""  // ← direct write, bypasses setEngineActiveSessionKey
    setUISelectedSessionKey("")
    ...
}
```

The spec says `engineActiveSessionKey` has **exactly one write path** (`setEngineActiveSessionKey`). `clearActiveSession` writes directly. This is likely intentional (clear doesn't need the `orderedSessionKeys.contains` guard or `applyActiveSessionKey` side effects), but it violates the stated invariant.

**Fix:** Either route through a dedicated clear path that's documented as the second authorized seam, or have `setEngineActiveSessionKey` handle the empty-string case. At minimum, add a comment acknowledging the intentional bypass.

### 2. `activeSessionKey` computed alias leaks engine key to unchecked readers

```swift
var activeSessionKey: String { engineActiveSessionKey }
```

This is marked "Back-compat read-only alias while call sites migrate to explicit split keys." However, it's `internal` (not `private`), meaning any file can still read `viewModel.activeSessionKey` and get the engine key without the reviewer knowing whether that's correct. If any **new** code reads `activeSessionKey` thinking it's the UI selection, it silently gets the wrong key.

**Fix:** Make this `@available(*, deprecated, message: "Use uiSelectedSessionKey or engineActiveSessionKey explicitly")` or add a `// TODO: remove after full migration` with a tracking issue. The alias should not persist silently.

---

## Warnings

### 1. Embellishment: keyboard-dismiss bypass gates (not in spec)

The `bottomInsetRemeasureBypassInputGates` / `isLikelyKeyboardDismissInsetChange` additions (~40 lines) in `MessageFlowCollectionView.swift` are a keyboard-dismiss bubble resizing fix. This is **not in the spec's scope** and should have been a separate commit/PR. It's not harmful, but it violates principle #7 (no embellishment).

### 2. No `engineActivationCompleted` pulse for already-active no-op case

In `commitPendingEngineActivationIfCurrent`:
```swift
guard target != engineActiveSessionKey else { return }
```

If the user swipes away and back to the same stream, `uiSelectionSequence` fires (toast shows with spinner), but since engine key doesn't change, `engineActivationStartedSequence` never fires and `engineActivationCompletedSequence` never fires. The toast spinner will **never clear** except by the toast's own auto-dismiss timer.

**Fix:** When `target == engineActiveSessionKey`, still fire the completion pulse (or skip the busy state entirely for same-stream switches).

### 3. `StreamManagerSheet` programmatic selection path

`StreamManagerSheet` row tap calls `selectStream(_, source: .programmatic)`. This correctly commits immediately. However, the sheet is likely still presented during engine activation. If engine activation is slow (unvisited stream), the user sees the sheet, not the toast. Minor UX gap — not a regression, just worth noting.

### 4. Missing edge case: stream deletion during debounce

The spec says (edge case #4): "At commit time, revalidate target exists in `orderedSessionKeys`. If missing, drop candidate and keep current `engineActiveSessionKey`. UI key reconciles to nearest valid key."

The code handles the revalidation:
```swift
guard orderedSessionKeys.contains(target) else {
    pendingEngineActivationTarget = nil
    pendingEngineActivationEpoch = nil
    return
}
```

But it does **not** reconcile `uiSelectedSessionKey` to the nearest valid key. The UI key still points to the deleted stream. The toast would show the deleted stream's name. `applyStreamDeletion` does call `setEngineActiveSessionKey(fallback)` which syncs the UI key, but there's a window where `uiSelectedSessionKey` is stale.

### 5. `self.` capture in reconnect closure

Line change `shouldUseAuthRejectionBackoff` → `self.shouldUseAuthRejectionBackoff` is unrelated to the stream-switch separation. Harmless but adds noise to the diff.

---

## Overall Verdict: **REVISE**

The implementation is architecturally sound and follows the spec closely. The two-key split, epoch cancellation, and mutation seam design are well-executed. Two issues need attention before deploy:

1. **Blocking #1** (clearActiveSession seam bypass) — easy fix, just route through the seam or document the exception.
2. **Warning #2** (same-stream toast spinner never clears) — this is a user-visible bug for the swipe-back-to-same-stream case. Should be fixed.

Everything else is clean. The embellishment (keyboard bypass gates) should ideally be a separate commit but isn't harmful.
