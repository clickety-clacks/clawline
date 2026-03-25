# Dictation Duplicate Systems Analysis

**Branch:** `feature/voice-dictation`
**Main tip:** `12f8571bb` (T151 share SBB visibility gate)
**Merge base:** `0416d38f0` (prior sync point)
**Date:** 2026-03-17
**Author:** clawline-dictation-v5 agent

---

## Scope

Three main commits not yet on branch:
- `12f8571bb` T151 share SBB visibility gate
- `9ba685da6` Defer RichTextEditor binding writes outside update cycle
- (implicit merge of upstream, `a3b4e9463`)

Analysis covers two domains:
1. **Connection/socket/provider** — ProviderChatService, StreamAPIClient, ChatViewModel
2. **SwiftUI layout** — MessageInputBar, ChatView, ChatLayoutCoordinator

---

## Domain 1: Connection / Socket / Provider

### StreamAPIClient.swift

**Verdict: No conflict.**
`git diff HEAD..main -- StreamAPIClient.swift` produces no output. File is byte-for-byte identical on both sides. No analysis needed.

---

### ProviderChatService.swift

**Branch has:** `TransportSessionCoordinator` (a `fileprivate actor`) embedded inside `ProviderChatService` (declared `class`). The actor manages:
- `AttemptState` + `SessionState` structs
- Managed vs standalone `TransportOwnerMode`
- Generation-UUID-based staleness protection
- Waiter queues (`waitForStandaloneAttemptToFinish`)
- Auth continuation resolution
- Socket/receiveTask lifecycle
- `replayCursorsBySessionKey` in `AuthPayload`
- `replayCount`, `replayTruncated`, `historyReset` in `AuthResultPayload`

**Main has:** `final class ProviderChatService` with no embedded actor. Auth payload omits `replayCursorsBySessionKey`. Auth result payload omits `replayCount`, `replayTruncated`, `historyReset`.

**Duplicate risk: NONE from main.**
Main does not introduce a competing coordinator for connection state. It simply removed the branch's actor. The branch's `TransportSessionCoordinator` is a unique branch addition; main's simplification is the removal of a previous design. When we merge, the actor must come back in its entirety.

**Action on merge:** Re-apply `TransportSessionCoordinator` actor and managed/standalone mode distinction. Reconcile `AuthPayload` to re-add `replayCursorsBySessionKey`. Reconcile `AuthResultPayload` to re-add replay fields. The class must revert from `final` to non-`final` (or verify whether `final` can be retained).

---

### ChatViewModel.swift

**Branch has (not on main):**
- `ConnectionLifecycleCoordinator` (external actor via `lifecycleCoordinator`)
- `SendCommandPort` and `ChatRuntimePort` protocols
- `StreamSwitchCoordinator` struct (reset handler wrapper)
- Connection ownership machinery: `currentConnectionOwnerId` (static), `isConnectionOwner`, `claimConnectionOwnership`, `releaseConnectionOwnershipIfNeeded`
- T099 pinpoint logging: `[T099-COORD]`, `[T099-PIN]`, `coordinatorDiag`, `emitPinpointLog`
- Lifecycle subscriptions: `lifecycleTransportEventsSubscription`, `lifecycleOutputsSubscription`, `lifecycleStartupGateDebugSubscription`
- `isRetired` flag
- `forceReReadGenerationBySession` / `armForceReRead` (int counter per session key)
- Staged attachment protection: `pendingAttachmentStageCount`, `stagedAttachmentProtection`
- `temporarySendButtonOverride` / `temporarySendButtonOverrideTask` (5-second visual feedback)
- `transportSendButtonConnectionState` split (checks `chatService.isTransportReadyForSend`)
- `canSend` gate: `pendingAttachmentStageCount == 0 && transportSendButtonConnectionState == .connected && ...`
- Debug: `imageSendDebugRecords`, `lifecycleDebugPhase`, `lifecycleDebugSignals`, lifecycle observer records, startup gate events

**Main has (not on branch) — new additions:**
- `lastServerMessageIdBySession: [String: String]` — replaces `forceReReadGenerationBySession`
- `lastServerMessageId: String?` — observable property for current session
- `applyActiveSessionKey` now calls `restoreLastServerMessageIdIfNeeded(for:)` and sets `lastServerMessageId` from session map
- `clearActiveSession()` clears `lastServerMessageId` (no longer takes `clearPersistedActiveSessionKey` param)
- Inline reconnect vars: `reconnectTask`, `reconnectBackoff`, `authRejectionInitialBackoff`, `authRejectionMaxBackoff`, `minimumReconnectInterval`, `foregroundReconnectDebounceInterval`, `lastReconnectAttemptAt`, `lastReconnectRequestAt`, `lastForegroundReconnectTrigger`
- Simplified `sendButtonConnectionState`: no override, no transport-readiness gate; maps directly from `connectionState`
- Simplified `canSend`: only checks `sendButtonConnectionState == .connected && !inputContent.isEffectivelyEmpty`
- `ConnectionStateMutationSource` has different cases: `.stateStream`, `.manualReconnect`, `.serviceInterruption` (branch had `.lifecycleCoordinator`)
- `resetStreamSwitchState` and `makeStreamSwitchCoordinator` removed from main

**Duplicate system assessment:**

| Area | Branch | Main | Conflict? |
|---|---|---|---|
| Connection lifecycle | `ConnectionLifecycleCoordinator` actor (external) | Inline `reconnectTask`/backoff | **Yes — architecture split** |
| Message cursor tracking | `forceReReadGenerationBySession` (int counter) | `lastServerMessageIdBySession` (string map) | **Yes — same purpose, different approach** |
| Send button state | Override + transport-readiness gate | Direct connection state map | **Yes — behavior difference** |
| Attachment staging | `pendingAttachmentStageCount` gate | Not present | No conflict; branch adds it |

**Critical findings:**

1. **Connection lifecycle architecture split (HIGH RISK):** Branch uses `ConnectionLifecycleCoordinator` (a separate actor managed externally) as the authority for transport events. Main inlines the reconnect loop directly in CVM. These are mutually exclusive designs. On merge, we must determine which is authoritative. The coordinator actor is tightly coupled to `lifecycleTransportEventsSubscription` and `lifecycleOutputsSubscription`; the inline approach uses `reconnectTask` directly. Merging both without a clear ownership decision will create a double-reconnect race.

2. **Message cursor tracking conflict (MEDIUM RISK):** Branch uses `forceReReadGenerationBySession[key] &+= 1` (an int generation bump to force message re-read). Main uses `lastServerMessageIdBySession[key]` (a string ID persisted across session switches). These serve related but different purposes: branch's counter triggers UI re-reads; main's string ID is a server-side replay cursor. Both must survive the merge — they're not replacements but if the merge applies both carelessly, `applyActiveSessionKey` may call both `restoreLastServerMessageIdIfNeeded` AND `armForceReRead` in unexpected orders.

3. **`canSend` behavior divergence (MEDIUM RISK):** Branch's `canSend` gates on `pendingAttachmentStageCount == 0 && transportSendButtonConnectionState == .connected`. Main's `canSend` only checks `sendButtonConnectionState == .connected`. Dictation's `DictationComposeDraftHosting` sends via `canSend`; if the gate is looser on main, dictation may attempt to send before transport is ready. Must reconcile.

---

## Domain 2: SwiftUI Layout

### MessageInputBar.swift

**Branch has (not on main):**
- `DictationPanGestureInstaller` (UIViewControllerRepresentable + Coordinator + UIPanGestureRecognizer)
- `DictationPanEvent`, `DictationPanIntentDecision`, `DictationPanIntentContext`, `DictationInteractionProjection`
- `DictationInteractionEmitter`, `DictationInteractionIntent` (enum of all interaction intents)
- `DictationGestureCommitIntent`, `DictationStopIntentSource`, `DictationDiscardIntentSource`
- `shouldBeginDictationPanGesture()`, `classifyDictationPanIntent()` (free functions)
- `MessageInputBarTextEditorFramePreferenceKey`, `MessageInputBarFramePreferenceKey`
- `import Combine`

**Main has:** Stripped all of the above. Uses `import Foundation` instead of `import Combine`. The entire file is ~10 lines on main vs ~549 lines on branch.

**Duplicate risk: NONE from main.** Main has no competing gesture system; it just omits the branch's dictation infrastructure. No conflict. On merge, all dictation gesture types and the installer must be re-integrated.

---

### ChatView.swift

**Branch has (not on main):**
- `@State private var dictationCoordinator: DictationCoordinator`
- `@State private var dictationMotion: DictationMotion`
- `@State private var settledInputBarHeight: CGFloat = 0`
- `@State private var dismissRequestID = 0`
- `@State private var messageListDismissModeSummary: String`
- `@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion`
- `runtimeInsetFallbackBarHeight(measuredInputBarHeight:settledInputBarHeight:layoutFrozen:)` free function
- `isKeyboardDictationUITestMode` / `keyboardDictationStateSummary` / `listKeyboardDismissRequest`
- UITestDictation stubs (`UITestDictationAudioCapture`, `UITestSonioxStreamingClient`)
- T099 probe state (`probeTaskEnterCount`, etc.) and `T099OnDisappearProbeStore`
- Debug lifecycle overlay (T099 era)
- DictationCoordinator init in `init(viewModel:toastManager:)` with factory injection
- Dictation UI overlay in `body`
- `chatViewTraceId` state

**Main has (not on branch) — new additions:**
- `ScrollButtonPresentationState` struct (with `unreadCount`, `bounceToken`)
- `scrollButtonPresentation(for:) -> ScrollButtonPresentationState?` — returns `nil` when not visible, used as optional binding gate
- `scrollButtonControl(presentation:containerWidth:onTap:)` — renamed `state` param to `presentation`; `ScrollToBottomButton` now always gets `isVisible: true`
- Both SBB call sites now use `if let presentation = scrollButtonPresentation(...)` — the button view is conditionally included in hierarchy
- `DragGesture(minimumDistance: 2)` now uses default coordinate space (branch used `.global`)
- `try? await Task.sleep(...)` in `scrollButtonTapSuppressionTask` and `scrollButtonSettleTask` (previously used `do/catch is CancellationError`)

**Duplicate system assessment:**

| Area | Branch | Main | Conflict? |
|---|---|---|---|
| SBB visibility gate | `state.isVisible` passed into view | `if let presentation` optional binding | **Yes — logic moved up one level** |
| Drag coordinate space | `.global` | default (`.local`) | **Yes — semantic difference** |
| Task sleep pattern | `do/catch is CancellationError` | `try?` | **Yes — violates .claude/CLAUDE.md rule 1** |
| `settledInputBarHeight` | Present on branch | Absent on main | No conflict; branch adds it |
| Dictation state | Present on branch | Absent on main | No conflict; branch adds it |

**Critical findings:**

1. **SBB visibility gate (MEDIUM RISK):** Main moved visibility gating from inside `ScrollToBottomButton` (via `isVisible` param) to the call site via optional binding. The branch passes `state.isVisible` through to the button. These two approaches must be reconciled. The branch's SBB call sites will need to adopt the new `scrollButtonPresentation` pattern. This is a non-trivial layout change: the branch may have SBB placement code that still uses the old `state`-based approach.

2. **Drag coordinate space regression (LOW-MEDIUM RISK):** Main changed `DragGesture(minimumDistance: 2, coordinateSpace: .global)` to `DragGesture(minimumDistance: 2)`. The branch used `.global` to keep drag translation stable while the scroll button repositions (see comment in branch code). If main's simpler form is brought in, the scroll button drag behavior may be incorrect when the dictation surface shifts the button vertically.

3. **`try? await Task.sleep` regression (RULE VIOLATION):** Main uses `try? await Task.sleep(...)` in two Task bodies inside ChatView. This violates `.claude/CLAUDE.md` Swift safety rule #1: "Do not use `try? await Task.sleep(...)` inside cancellable tasks unless cancellation is explicitly handled before any side effects." The branch correctly used `do { try await } catch is CancellationError { return }`. **This must not be adopted** when merging; branch's pattern should be preserved.

---

### ChatLayoutCoordinator.swift

**Branch has (not on main):**
- `scrollToTop()` (active session) and `scrollToTop(sessionKey:animated:)` — used by dictation surface dismiss
- `applyInsetsImmediately` closure called **before** the `UIView.animate` block AND before the non-animated branch
- `registerListView` early-return when re-registering same view (reapplies inset on re-register)
- `runPendingFallbackIfNeeded()` called from a `Task { @MainActor [weak self] in ... }` body
- Uses `list.isActivelyDraggingOrTracking` property

**Main has (not on branch) — changes:**
- Removed `scrollToTop()` and `scrollToTop(sessionKey:animated:)`
- Removed `applyInsetsImmediately` closure; insets now applied inline inside the animation block only (no separate pre-animation apply)
- Removed `registerListView` early-return guard (re-registering same view always goes through full path)
- Pending fallback now uses `RunLoop.main.perform { [weak self] in ... }` instead of `Task { @MainActor }`
- Uses `list.isUserInteracting` instead of `list.isActivelyDraggingOrTracking`
- Removed `runPendingFallbackIfNeeded()` private method (logic inlined into RunLoop block)

**Duplicate system assessment:**

| Area | Branch | Main | Conflict? |
|---|---|---|---|
| `scrollToTop` | Present | Removed | **Yes — branch needs it for dictation dismiss** |
| Inset application timing | Pre-animation + animated | Animation block only | **Yes — settled-inset timing contract** |
| Fallback scheduler | `Task { @MainActor }` | `RunLoop.main.perform` | **Yes — scheduling semantics differ** |
| Drag/tracking property | `isActivelyDraggingOrTracking` | `isUserInteracting` | **Yes — property rename** |
| Register guard | Short-circuit on same view | Always full path | **Yes — inset reapplication behavior** |

**Critical findings:**

1. **`scrollToTop` removal (HIGH RISK):** Branch uses `scrollToTop()` in dictation surface dismiss path. Main removed both overloads. If main's removal is accepted, dictation dismiss will fail silently (or crash). The method must be re-added on merge.

2. **Inset application timing split (HIGH RISK):** Branch applies insets immediately before animation AND within animation block. This is the "pager-rigid-unit" settled-inset contract: the inset is applied synchronously to prevent visual jump, then animated. Main's change applies insets only within the animation block. If a frame fires between the animation start and the first animation frame, the inset is wrong — the list may scroll before the new inset is established. **This directly risks breaking the settled-inset invariant** that the dictation branch depends on. Must revert to pre-animation apply.

3. **Fallback scheduler change (MEDIUM RISK):** `RunLoop.main.perform` fires in the next run loop turn, synchronously — before async tasks have a chance to run. `Task { @MainActor }` defers until the async executor picks it up, which may be one or more run loop turns later. The branch's `Task` approach gives more room for other layout passes to complete before fallback fires; main's `RunLoop.main.perform` is more aggressive. This could interact with dictation's layout-freeze / settled-inset flow.

4. **Property rename `isActivelyDraggingOrTracking` → `isUserInteracting` (LOW RISK):** Simple rename. Must check `MessageFlowCollectionViewController` to confirm the property was renamed (not removed or semantically changed). If semantically equivalent, safe to adopt.

5. **Register guard removal (LOW RISK):** Re-registering same view was previously a no-op (with inset reapplication). Now it always goes through the full path. May trigger additional layout on each registration. Low risk but should be verified with dictation surface registration timing.

---

## Summary Table

| System | Conflict Type | Risk | Action |
|---|---|---|---|
| StreamAPIClient | None | None | No action |
| PCS `TransportSessionCoordinator` | Branch-only, main stripped it | HIGH | Re-apply on merge |
| PCS replay cursor fields | Branch-only, main stripped them | HIGH | Re-apply on merge |
| CVM connection lifecycle coordinator | Architecture split | HIGH | Resolve ownership before merge |
| CVM message cursor tracking | Same purpose, different approach | MEDIUM | Reconcile `forceReReadGenerationBySession` + `lastServerMessageIdBySession` |
| CVM `canSend` gate | Behavior divergence | MEDIUM | Re-add transport-readiness gate |
| MIB dictation gesture infrastructure | Branch-only, main stripped it | HIGH | Re-apply on merge |
| ChatView dictation state | Branch-only, main stripped it | HIGH | Re-apply on merge |
| ChatView SBB presentation gate | Logic moved to call site | MEDIUM | Adopt new pattern on branch |
| ChatView drag coordinate space | Semantic regression in main | LOW-MEDIUM | Restore `.global` |
| ChatView `try? Task.sleep` | Rule violation in main | RULE VIOLATION | Do not adopt; keep `do/catch` |
| ChatLayoutCoordinator `scrollToTop` | Removed in main, needed by branch | HIGH | Re-add on merge |
| ChatLayoutCoordinator inset timing | Pre-animation apply removed | HIGH | Restore pre-animation apply |
| ChatLayoutCoordinator fallback scheduler | Scheduling semantics differ | MEDIUM | Evaluate; branch's `Task` safer |
| ChatLayoutCoordinator property rename | `isActivelyDraggingOrTracking` → `isUserInteracting` | LOW | Verify and adopt |

---

## Merge Recommendation

**Do not merge main into branch yet.**

The three main commits introduce a mix of:
- Genuine improvements (SBB visibility gate, `lastServerMessageId` tracking)
- Architectural divergence (CVM connection lifecycle, PCS simplification)
- Regressions (inset timing, drag coordinate space, `try?` sleep pattern)
- Losses that must be restored (dictation infrastructure, `scrollToTop`)

Suggested sequence before merge:
1. Resolve connection lifecycle ownership (coordinator actor vs inline reconnect)
2. Decide on `forceReReadGenerationBySession` vs `lastServerMessageIdBySession` (may need both)
3. Merge main's SBB gate pattern into branch's ChatView (safe, additive)
4. Ensure `scrollToTop` stays in ChatLayoutCoordinator
5. Ensure pre-animation inset apply is restored
6. Ensure `do/catch is CancellationError` is used for Task sleep
7. Restore `.global` coordinate space for drag gesture
