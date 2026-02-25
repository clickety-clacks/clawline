# T077 stream switch latency review (2026-02-23)

## Scope
Requested comparison:
- Legacy workspace: `~/src/clawline-stream-switch-latency/`
- Current main: `~/src/clawline/`
- Focus files: `ChatView.swift`, `MessageFlowCollectionView.swift`
- Focus behaviors: offscreen stream deferral + flow layout caching

## 1) Legacy workspace check (`git status` / `git diff`)

I could not run `git status` or `git diff` at the specified path because it does not exist on this machine:

- `git -C /Users/mike/src/clawline-stream-switch-latency status --short` -> `fatal: cannot change to '/Users/mike/src/clawline-stream-switch-latency': No such file or directory`
- `git -C /Users/mike/src/clawline-stream-switch-latency rev-parse --abbrev-ref HEAD` -> same error

I also searched `~/src` and did not find a checkout named `clawline-stream-switch-latency`.

## 2) Main-branch comparison against known T077 change set

Because the legacy cp-r workspace is unavailable, I used the known T077 commit on this repository as the source of truth for that work:

- `77cee9d1764153866811fe4928c638b3faf7f91b`
- Message: `fix: defer offscreen stream layout + cache layout signature (#83)`
- Files changed in that commit:
  - `ios/Clawline/Clawline/Views/Chat/ChatView.swift`
  - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`

### A) Offscreen stream deferral

T077 introduced `isActiveSession` plumbing and an early return for offscreen pages.

Status on `main`: **present and extended**.

Evidence:
- `ChatView.swift` still passes `isActiveSession` into `MessageFlowCollectionView`.
- `MessageFlowCollectionViewController.update(...)` still computes:
  - `let isOffscreenSession = sessionKey != nil && !isActiveSession`
  - then returns early for offscreen sessions before snapshot/layout work.
- Later work strengthened this path:
  - Stream-switch coordinator/frozen render gate now blocks work for all pages while policy is frozen (`60e444f7a`, `437339da9`).
  - Adjacent prewarm shells were added and explicitly rely on offscreen deferral to avoid heavy work while pre-creating UIKit shells (`432d68cfb`).

Conclusion: T077 offscreen deferral is not only on main; it is now part of a broader stream-switch policy.

### B) MessageFlowLayout signature caching

T077 added layout signature caching + rebuild gating (`needsRebuild`, `cachedLayoutSignature`) to avoid unnecessary `prepare()` recomputation.

Status on `main`: **present and improved**.

Evidence:
- `MessageFlowLayout` still contains T077 signature caching core fields and fast-return logic.
- T085 follow-up work expanded this into a richer invalidation model:
  - explicit invalidation modes,
  - incremental append path,
  - item-height delta path,
  - centralized invalidation seam (`3c887bf2b`, `4bc29e9ed`, `46fa718a0`, `524ac4abc`).

Conclusion: the T077 caching concept is fully incorporated and materially improved.

## 3) Classification

### Already on main (possibly in evolved form)
- `isActiveSession` propagation into `MessageFlowCollectionView`.
- Offscreen stream early-return deferral in `MessageFlowCollectionViewController.update(...)`.
- Layout signature caching in `MessageFlowLayout` (`needsRebuild` + `cachedLayoutSignature` guard).

### Modified/improved by later work
- Active-session decision in `ChatView` evolved from direct active-key comparison to `renderPolicySessionKey` integration (stream-switch coordinator behavior).
- Offscreen deferral now coexists with global frozen-render gating.
- Layout caching evolved into T085 invalidation seam + incremental update paths.

### Still needed
- **None identified from the known T077 commit (`77cee9d17`)**.

### Obsolete (superseded forms)
- Any legacy variant that keyed `isActiveSession` only to old active-session selection semantics (without render policy/coordinator context).
- Any legacy layout-cache implementation that only did full rebuild-or-skip without T085 invalidation seam paths.

## Caveat

A strict comparison against **uncommitted** changes in `~/src/clawline-stream-switch-latency/` was not possible because that checkout is missing. The conclusions above are based on the known T077 commit contents and current `main` state.
