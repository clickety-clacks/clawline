# T113 Final Verification

**Date:** 2026-02-25
**Branch:** `per-stream-state` @ `2e24a06ae`
**Verifying commit:** `2e24a06ae` — Guard morph async session writes and refresh anchor snapshot

---

## 1. TS-10 (Morph animation session guard) — PASS with caveat

**Token capture:** `activeSessionGenerationToken()` captured at line 2809, BEFORE `morphTargetMessageId` is set at line 2814. Correct ordering.

**Async block guard (lines 2846-2853):** Validates `callbackSessionKey() == morphToken.sessionKey` AND `restoreGeneration == morphToken.generation`. On failure: removes `typingSnapshotView`, returns. PASS.

**Completion block guard (lines 2878-2885):** Same dual validation. On failure: removes `typingSnapshotView`, returns. PASS.

**Caveat — stale per-stream state on guard failure:** Both guard-failure paths skip `morphTargetMessageId = nil` and `deferScrollToBottomUntilMorphCompletes = false`. Compare to the existing "cell not found" guard at line 2855-2858 which correctly clears `morphTargetMessageId`.

Impact of stale `morphTargetMessageId`: The `willDisplay` callback (line 1052) checks `if id == morphTargetMessageId { return }` — suppresses alpha reset for that cell. On switch-back to the original session, the stale ID could leave a cell invisible. No other code path clears it.

Impact of stale `deferScrollToBottomUntilMorphCompletes`: If set to `true` at line 1901 before the morph, stays `true` on guard failure. On switch-back, suppresses auto-scroll-to-bottom until some future morph completes.

**Severity:** Low-Medium. Requires session switch during the 2-second morph window AND switch-back to trigger. The fix is trivial — add `self.morphTargetMessageId = nil` to both guard-failure paths, and consider clearing `deferScrollToBottomUntilMorphCompletes`.

---

## 2. TS-9 (Snapshot refresh in bubble compensation) — PASS

`refreshLastKnownScrollSnapshot(sessionKey: token.sessionKey)` added at line 4174, immediately after `setContentOffset(... animated: false)` at line 4173. Uses `token.sessionKey` from the captured generation token. Correct.

**Completeness check — all `setContentOffset(animated: false)` calls paired:**

| Location | Line | `refreshLastKnownScrollSnapshot` |
|---|---|---|
| Scroll restore attempt | 2559 | Yes (line 2560) |
| Scroll restore fallback | 2620 | Yes (line 2621) |
| scrollToBottom | 3803 | Yes (conditional on !animated, lines 3804-3805) |
| scrollToMessageCentered | 3835 | Yes (conditional on !animated, lines 3836-3837) |
| adjustContentOffsetForBottomInsetChange | 3860 | Yes (line 3861-3862) |
| **scheduleBubbleSizingV2ViewportAnchorCompensation** | **4173** | **Yes (line 4174)** — **this fix** |

All 6 sites covered. No omissions.

---

## 3. New issues introduced — ONE FOUND

**Stale morph state on guard-failure early return** (described in section 1 above). The session/generation guards correctly prevent cross-session writes, but don't clean up the per-stream state that was already set synchronously before the async block. Two values leak:
- `morphTargetMessageId` (set at line 2814, cleared only at lines 2857/2887)
- `deferScrollToBottomUntilMorphCompletes` (set at line 1901, cleared only at line 2891)

No other new issues found. The `refreshLastKnownScrollSnapshot` addition is clean and correctly guarded.

---

## 4. Acceptance checks 1–25 — 25/25 PASS

The fixes in `2e24a06ae` only ADD guards (making async paths more correct) and ADD a snapshot refresh call. No behavioral regressions possible. All 25 checks from the re-audit remain PASS. The stale-morph-state caveat does not flip any check — it is a cleanup gap in the new guard code, not a regression of any existing invariant.

---

## Summary

| Item | Verdict |
|---|---|
| TS-10 fix (morph session guard) | **PASS** — guards correct, but stale `morphTargetMessageId`/`deferScrollToBottomUntilMorphCompletes` on guard failure (low-med severity) |
| TS-9 fix (snapshot refresh) | **PASS** — all 6 `setContentOffset` sites now paired |
| New issues | One: stale morph per-stream state on guard-failure early return |
| Acceptance checks 1–25 | **25/25 PASS** |

**Recommended one-liner fix:** Add `self.morphTargetMessageId = nil` to both guard-failure paths (lines 2847-2848 and 2879-2880), matching the existing pattern at line 2857. Consider also adding `self.deferScrollToBottomUntilMorphCompletes = false` since the morph is abandoned.
