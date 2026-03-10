# WebPage Bubble Measurement

Started: 2026-03-04
Updated: 2026-03-04

## Goal

Replace Clawline's offscreen WKWebView-driven bubble height measurement with iOS 26+ `WebPage`-based headless measurement, then improve interactive HTML JS communication using WebKit for SwiftUI-era APIs where they are concretely available.

Priority order:
1. Bubble measurement replacement (primary)
2. Interactive HTML JS bridge cleanup (secondary)

## Scope

In scope:
- Bubble height measurement paths currently coupled to WKWebView/offscreen UIKit sizing and inset-driven invalidation.
- `BubbleSizingV2.BubbleHeightPolicy` coupling points that trigger remeasurement/invalidation churn.
- `InteractiveHTMLBubbleUIKitView` JS execution and callback bridge cleanup where `WebPage`/modern async JS APIs provide a clearer path.

Out of scope:
- Rewriting visible link-preview rendering (`LinkPreviewView`) from UIKit to SwiftUI `WebView` in this pass.
- Changing provider callback wire format (`interactive-callback`) or server routing semantics.
- Non-HTML bubble types.
- Unrelated top-inset/full-layout architecture changes beyond HTML measurement decoupling.

## Current State (Code Map)

Note: there is no standalone `BubbleHeightPolicy.swift` file in this worktree. `BubbleHeightPolicy` is a nested type in `BubbleSizingV2.swift`.

### 1) Bubble policy is keyed by inset-sensitive environment

`BubbleSizingV2.Environment` includes:
- `topInset`
- `bottomInset`
- `truncationBottomInset`

Source:
- `ios/Clawline/Clawline/Views/Chat/BubbleSizingV2.swift:15-24`

`BubbleHeightPolicy.resolve(...)` computes `heightCap` from those inset values via `availableHeightCap(...)`.
Source:
- `ios/Clawline/Clawline/Views/Chat/BubbleSizingV2.swift:79-138`
- `ios/Clawline/Clawline/Views/Chat/BubbleSizingV2.swift:247-255`

The environment is built from live collection view + layout coordinator insets:
- `topInset` (safe-area driven)
- `currentBottomInset` (keyboard/input-bar driven)
- `truncationBottomInset`

Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2439-2457`

### 2) Top/bottom inset changes feed layout churn

`update(...)` marks `needsFullLayout` when `topInset` changes, then runs `updateLayout()`.
Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:1177-1193`

`updateLayout()` sets insets then invalidates environment/layout.
Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2041-2062`

`setBottomInset(...)` schedules deferred height-cap invalidation for affected bubbles.
Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:677-817`

Specifically, bottom-inset changes enqueue remeasurement for single-link preview bubbles and can bypass input gates on keyboard-dismiss deltas.
Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:738-817`

### 3) Offscreen sizing path still instantiates WKWebView-backed components

`MessageFlowCollectionViewController` uses a controller-owned offscreen bubble sizer:
- `private let uiKitBubbleSizer = MessageBubbleUIKitView()`

Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:102`

Both V1 and V2 sizing call `uiKitBubbleSizer.configure(...)` during measurement.
Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2352-2435`
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:2628-2783`

`MessageBubbleUIKitView.configure(...)` builds dynamic content views including:
- `LinkPreviewView`
- `InteractiveHTMLBubbleUIKitView`

Source:
- `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:851-921`

`LinkPreviewView` creates a `WKWebView` at init (`BubbleSafeAreaNeutralWebView`).
Source:
- `ios/Clawline/Clawline/Views/Chat/LinkPreviewView.swift:18-56`
- `ios/Clawline/Clawline/Views/Chat/LinkPreviewView.swift:250-260`

So the offscreen measurement system is still WKWebView-backed at construction level even when actual page loading is deferred to `window != nil`.

### 4) Link preview remeasurement relies on live visible cell WKWebView state

Current V2 correction path:
- Find visible `LinkPreviewView`
- Read `reportedHeight`
- Write cache
- Invalidate/reconfigure with debounce

Source:
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:3135-3279`

This explicitly depends on a visible attached cell and is coupled to scroll-rest gating and deferred timers.

### 5) Interactive HTML JS execution is callback-style `evaluateJavaScript`

Interactive HTML height measurement and auxiliary JS rely on callback-based `WKWebView.evaluateJavaScript`.
Source:
- `ios/Clawline/Clawline/Views/Chat/InteractiveHTMLBubbleUIKitView.swift:375-405`

Bridge callbacks rely on `WKScriptMessageHandler` parsing raw dictionary payloads.
Source:
- `ios/Clawline/Clawline/Views/Chat/InteractiveHTMLBubbleUIKitView.swift:451-517`

## Constraints From iOS 26 SDK (verified)

Verified from local iOS 26.1 SDK interfaces:
- `WebPage` is an `@MainActor` observable class in `WebKit`.
- `WebPage` supports `load(html:baseURL:)` and async `callJavaScript(...)`.
- `WebPage` supports async navigation events (`WebPage.NavigationEvent`) and `NavigationDeciding`.
- SwiftUI `WebView` and view modifiers (`webViewScrollPosition`, etc.) are exposed via `_WebKit_SwiftUI` overlay.

Verified interface files:
- `/Applications/Xcode.app/.../WebKit.framework/Modules/WebKit.swiftmodule/*swiftinterface`
- `/Applications/Xcode.app/.../_WebKit_SwiftUI.framework/Modules/_WebKit_SwiftUI.swiftmodule/*swiftinterface`

Important note:
- WWDC transcript references higher-level JS communication concepts, but symbols like `JavaScriptValue` / `JavaScriptEventBridge` are not present in the public iOS 26.1 interfaces available in this workspace.
- This spec therefore targets concrete, build-verifiable APIs (`WebPage.callJavaScript`, async navigation, existing message handlers) and treats any typed bridge as optional future work once public symbols exist.
- Implementation must not directly `import _WebKit_SwiftUI` in app code. Use public `WebKit` + `SwiftUI` surface only.

## Proposed Architecture

### A) New headless measurement service (primary change)

Add a dedicated `WebPageBubbleMeasurer` owned by `MessageFlowCollectionViewController`.

Responsibilities:
- Perform headless HTML measurement with `WebPage`.
- Return deterministic content height for bubble layout planning.
- Cache by stable measurement inputs.
- Avoid visible-view dependency.

Proposed API shape:
- `measureHTML(html: String, width: CGFloat, maxHeight: CGFloat, cacheKey: WebPageMeasurementKey) async -> CGFloat`
- `measureURL(url: URL, width: CGFloat, maxHeight: CGFloat, cacheKey: WebPageMeasurementKey) async -> CGFloat` (phase-gated; see migration)

Mandatory precondition (before replacing any production path):
- Run a spike proving that headless `WebPage` returns stable, non-zero layout heights for representative HTML without attaching a visible `WebView`.
- The spike must verify:
  1. Navigation `.finished` timing is sufficient (or define additional readiness checks)
  2. `callJavaScript` height probe yields deterministic values across repeated runs
  3. Results are comparable to current visible-cell measurement within tolerance
- If this precondition fails, phase 1 is blocked and the spec must be amended before implementation.

Measurement execution:
1. Create `WebPage(configuration:)` with required content policy.
2. Load content (`load(html:baseURL:)` or URL request).
3. Await completion event (`.finished`) via load async sequence.
4. Call JS via `callJavaScript` to compute robust rendered content bottom (not only `scrollHeight`).
5. Clamp to `[minHeight, maxHeight]` and return.

### A1) `WebPageMeasurementKey` and invalidation semantics

Define `WebPageMeasurementKey` explicitly (no implicit keying):
- `sourceKind`: `html` or `url`
- `sourceIdentityHash`: stable hash of HTML payload (for `html`) or normalized URL string (for `url`)
- `contentWidthPx`: rounded width in pixels
- `maxHeightPx`: rounded cap in pixels
- `metricsFingerprint`: typography/dynamic-type fingerprint (existing `BubbleSizingV2.metricsFingerprint`)
- `appearance`: light/dark
- `policyVersion`: manual version integer to bust cache on algorithm changes

Invalidation rules:
- Invalidate when any key field changes.
- Do not invalidate on keyboard/safe-area inset changes alone.
- For streaming/edited HTML payloads, any payload change must produce a new `sourceIdentityHash`.
- In-flight requests are deduped by key; stale results must be dropped by generation token.

### A2) Concurrency model

Measurement execution is centralized behind a single actor/service with:
- in-flight dedupe map by `WebPageMeasurementKey`
- bounded parallelism (initial cap: 2 concurrent `WebPage` measurements)
- cancellation of stale jobs when message/session generation changes
- FIFO queue for pending jobs beyond concurrency cap

Rationale:
- avoids unbounded headless page creation
- prevents duplicate work for identical keys
- keeps memory/process pressure predictable

### B) Decouple bubble measurement keying from dynamic insets (HTML paths)

For HTML bubble measurement keys, remove keyboard/safe-area bottom coupling.

Current coupling:
- `topInset`, `bottomInset`, `truncationBottomInset` participate in environment/hash.

Proposed for HTML measurement:
- Key by explicit `WebPageMeasurementKey` (section A1), which includes content identity, width/cap, metrics fingerprint, appearance, and policy version.
- Do not key by live keyboard/input insets.

Result:
- Keyboard show/hide does not invalidate HTML measurement cache.
- Inset updates remain a scroll viewport concern, not a content remeasurement trigger.
- Existing top-inset-driven `needsFullLayout` behavior can remain for now; this spec's required win is removing bottom-inset-driven HTML measurement churn and visible-WKWebView dependency.

### C) Keep visual cap policy explicit, but stop remeasure loops on inset churn

`BubbleHeightPolicy` remains the visual cap authority, but HTML measurement no longer depends on visible WKWebView state.

For HTML bubble types:
- Inset changes should not force remeasurement work.
- If a cap change is still needed for presentation semantics, apply via lightweight constraint update using cached intrinsic HTML height (no new measurement).

### D) JS bridge cleanup (secondary change)

Interactive HTML bridge improvements:
1. Replace callback-style `evaluateJavaScript` usage with async wrapper path where possible.
   - Prefer `WebPage.callJavaScript` in new headless measurement code.
   - For WKWebView runtime-only cases that remain, use centralized async helper and consistent decoding.
2. Consolidate reserved action handling (`_close`, `_resize`) and payload validation into a single bridge parser utility.
3. Keep wire protocol unchanged (`interactive-callback`).

This improves readability/testability and removes scattered ad-hoc JS evaluation callbacks.

## Migration Path

### Phase 0: Add seams and feature flag

- Add `WebPageBubbleMeasuring` protocol and concrete `WebPageBubbleMeasurer`.
- Add runtime flag: `CLAWLINE_WEBPAGE_MEASUREMENT=1` (off by default initially).
- Keep existing paths as fallback.
- Add explicit rollback path: one-flag return to current WKWebView measurement behavior.
- Gate: complete the mandatory headless-layout spike (section A) before any production switch.

Exit criteria:
- Builds on iOS 26 SDK with feature flag both ON/OFF.
- Spike report confirms headless measurement viability.

### Phase 1: Interactive HTML headless measurement (low risk)

- Route `InteractiveHTML` bubble sizing measurement through `WebPageBubbleMeasurer`.
- Remove offscreen sizing dependence on `InteractiveHTMLBubbleUIKitView` WKWebView state.

Exit criteria:
- No behavior regression in interactive HTML rendering/callback delivery.
- No new inset-driven remeasurement for interactive HTML bubbles.

### Phase 2: Link preview headless measurement integration

- Introduce optional `measureURL(...)` path for preview height estimation/finalization without requiring visible cell probing.
- Replace or reduce `handleBubbleSizingV2LinkPreviewLayout` live-view lookup dependence.

Exit criteria:
- `findLinkPreviewView(...)/reportedHeight` is no longer required for correctness.
- Remeasure debounce/timer load is materially reduced.

### Phase 3: Remove inset-driven HTML remeasure invalidation

- Remove/limit bottom-inset-triggered HTML bubble remeasure queueing.
- Preserve only scroll inset updates and optional cap-only relayout logic.
- Keep non-HTML and non-WebPage sizing invalidation behavior unchanged in this phase.

Exit criteria:
- Keyboard show/hide does not trigger HTML measurement cache invalidation or full layout rebuilds.

### Phase 4: Bridge cleanup rollout

- Land async JS helper and centralized bridge parsing for interactive HTML bubble.
- Keep callback protocol semantics unchanged.

Exit criteria:
- Same callback payloads and reserved action semantics as before.

## Risks

1. API availability mismatch
- `WebPage` is iOS 26+ only. Must keep fallback path for lower deployment targets if any runtime path can execute there.

2. Behavior drift vs existing single-link full-height policy
- Existing spec text (`bubble-sizing-v2.md`) codifies single-link full-available-height behavior tied to insets.
- This plan reduces inset coupling for measurement. Any visual policy change must be explicit and tested.

3. Link preview network duplication (phase 2)
- If both headless measurement and visible preview each load remote content, network/process cost can rise.
- Must gate and evaluate before full rollout.

4. Security-policy parity
- Existing `LinkPreviewView` has navigation/delegate hardening logic.
- `WebPage`-based URL measurement must preserve equivalent policy decisions where required.

5. Cancellation/race complexity
- Async measurement jobs can become stale during stream switches, message removal, width changes.
- Must tie jobs to message/session generation token before applying results.

6. Existing spec conflict risk
- `bubble-sizing-v2.md` and `interactive-html-bubbles.md` include assumptions that may conflict with this migration (single-link inset-tied cap semantics, strict WKWebView isolation wording).
- Before implementation, those specs must either be explicitly amended or this spec marked as superseding the overlapping sections.

7. Headless-layout assumption failure
- If `WebPage` in headless mode does not produce reliable layout metrics for target content, phase 1 architecture is invalid.

8. Concurrency/memory pressure
- Unbounded concurrent `WebPage` measurements can regress performance/memory; bounded concurrency is required.

## Acceptance Checks

1. Measurement correctness
- HTML bubble measured heights are produced without requiring visible attached WKWebView state.

2. Keyboard performance behavior
- Keyboard show/hide does not enqueue HTML remeasurement invalidations for visible bubbles.

3. Layout stability
- No full collection layout rebuild caused solely by HTML measurement updates.

4. JS bridge behavior parity
- `_close`, `_resize`, and normal callback action delivery semantics are preserved.

5. Build gate
- iOS target builds successfully with feature flag ON/OFF.

6. Concrete regression checks
- Existing tests continue to pass, especially:
  - `BubbleScrollTests` single-link cap/inset behavior checks (`ios/Clawline/ClawlineTests/BubbleScrollTests.swift:220-240`)
  - interactive HTML load/visibility checks (`ios/Clawline/ClawlineTests/InteractiveHTMLBubbleUIKitViewTests.swift:16-88`)
- New tests added for:
  - keyboard show/hide does not enqueue HTML remeasurement for WebPage-measured bubbles
  - headless measurement returns stable height without a window-attached WKWebView

7. Rollback criteria
- Feature flag must be turned OFF immediately if any of these are observed in rollout:
  - measurable increase in keyboard-transition jank or main-thread stalls versus baseline
  - repeated zero/invalid headless measurements for production HTML payloads
  - significant layout instability (oscillating bubble heights) attributable to WebPage measurement

## Open Questions

1. Should phase 2 (URL measurement for link previews) ship in same PR as phase 1, or behind separate flag rollout?
2. Do we formally supersede/patch the single-link height policy language in `bubble-sizing-v2.md` as part of this change?
3. If typed WebKit JS bridge symbols become public in a later SDK, should we add a compile-time adapter layer now or defer?
4. Should phase 2 be deferred until a shared-load strategy exists to avoid double URL fetches (headless + visible preview)?

## Adversarial Self-Review (2026-03-04)

Blocking issues found and resolved in this revision:
1. Scope ambiguity around top-inset/full-layout behavior
- Resolved by explicitly marking that as out-of-scope for this spec and clarifying the required win is bottom-inset HTML measurement decoupling.

2. Private API/module usage risk
- Resolved by adding an explicit constraint: no direct `_WebKit_SwiftUI` import in app code.

3. Insufficient regression verification detail
- Resolved by adding concrete regression checks tied to existing tests and required new coverage.

4. File-location assumption mismatch risk
- Resolved by explicitly documenting that `BubbleHeightPolicy` is nested in `BubbleSizingV2.swift`, not a separate file.

5. Underspecified cache/concurrency behavior
- Resolved by explicitly defining `WebPageMeasurementKey`, invalidation semantics, and bounded concurrency model.

6. Headless-layout assumption risk
- Resolved by adding a mandatory pre-implementation spike gate with explicit pass/fail criteria.

## Implementation Handoff

In-scope implementation boundary:
- Only bubble measurement and interactive HTML JS bridge cleanup related to this spec.
- No unrelated layout/pager/session routing changes.

Non-goal guardrails:
- Do not alter provider wire formats.
- Do not refactor unrelated WKWebView features outside measurement/bridge scope.

## History

- 2026-03-04: Initial draft created from codebase audit, iOS 26.1 SDK interface verification, and WWDC25 Session 231 reference.
- 2026-03-04: Adversarial self-review pass applied; clarified scope boundaries, private-module constraint, and concrete acceptance/regression checks.
- 2026-03-04: Re-audited source paths for T140; documented that `BubbleHeightPolicy` is nested in `BubbleSizingV2.swift` and reran adversarial self-review.
- 2026-03-04: Incorporated Opus adversarial findings: added headless-layout validation gate, explicit measurement-key semantics, bounded concurrency model, rollback criteria, and phase-2 network-duplication question.

---

## Appendix: Preserved Notes

### From: retros/webpage-bubble-measurement-adversarial-20260304.md

**Blocking issues identified in adversarial review:**

1. **Headless `WebPage` layout not verified:** The spec assumes `WebPage` renders content and completes layout before the `.finished` navigation event. This is unverified against SDK interfaces. `WKWebView` requires view attachment for accurate intrinsic sizing — if `WebPage` has the same requirement, the headless measurement premise fails. Must be verified empirically before implementation.

2. **Cache key design underspecified:** The replacement key (after removing inset coupling) is described vaguely. Must explicitly define `WebPageMeasurementKey` components: what constitutes "content identity" (HTML hash? URL? Message ID?), what is "typography/metrics fingerprint" (Dynamic Type category? Font size? Scale factor?), and invalidation semantics for streaming/edited HTML messages.
