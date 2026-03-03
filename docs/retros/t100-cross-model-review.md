# T100 Cross-Model Review (Opus)

Date: 2026-02-27
Branch: `per-stream-state`
HEAD: `b82df6659`
Spec: `/Users/mike/shared-workspace/clawline/specs/connection-lifecycle.md`

## Method
- Ran Claude Opus adversarial review via:
  - `cat scratch/t100-cross-model-prompt-small.txt | ~/.claude/local/claude --model claude-opus-4-5-20251101 --print > scratch/t100-cross-model-opus-output.md`
- Cross-model output: `/Users/mike/src/worktrees/per-stream-state/scratch/t100-cross-model-opus-output.md`
- Then manually validated line references for the requested checks.

## Requested Checks

### Race fix (b82df6659): observer subscribed before first `startIfNeeded` on ALL paths
- **FAIL** (not complete on all startup paths).
- Good paths:
  - `onAppear()` calls `startObserving()` before `startIfNeeded()` ([ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:439](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:439), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:441](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:441)).
  - auth-change path also calls `startObserving()` before `startIfNeeded()` ([ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:474](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:474), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:480](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:480)).
- Break path:
  - Chat view `.task` calls scene-active handler before `onAppear()` ([ios/Clawline/Clawline/Views/Chat/ChatView.swift:458](ios/Clawline/Clawline/Views/Chat/ChatView.swift:458), [ios/Clawline/Clawline/Views/Chat/ChatView.swift:460](ios/Clawline/Clawline/Views/Chat/ChatView.swift:460)).
  - Scene-active path calls `appDidBecomeActive()` ([ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:515](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:515), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:505](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:505)).
  - Coordinator can start connecting from `appDidBecomeActive()` while phase is `idle` ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:171](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:171), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:181](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:181)).
  - If this runs before `onAppear` re-subscribes, first transport events can emit before subscriber setup.

### Epoch ownership: coordinator owns, service echoes
- **PASS**.
- Coordinator is single epoch authority (`currentEpoch += 1`) and dispatches start attempt with epoch ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:541](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:541), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:551](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:551)).
- Service receives epoch via `startConnectionAttempt(epoch:...)` ([ios/Clawline/Clawline/Services/ProviderChatService.swift:353](ios/Clawline/Clawline/Services/ProviderChatService.swift:353)).
- Service emits lifecycle events only through `emitLifecycleEvent(epoch:payload:)` ([ios/Clawline/Clawline/Services/ProviderChatService.swift:895](ios/Clawline/Clawline/Services/ProviderChatService.swift:895), [ios/Clawline/Clawline/Services/ProviderChatService.swift:896](ios/Clawline/Clawline/Services/ProviderChatService.swift:896)); examples: [536](ios/Clawline/Clawline/Services/ProviderChatService.swift:536), [628](ios/Clawline/Clawline/Services/ProviderChatService.swift:628), [665](ios/Clawline/Clawline/Services/ProviderChatService.swift:665), [723](ios/Clawline/Clawline/Services/ProviderChatService.swift:723), [1021](ios/Clawline/Clawline/Services/ProviderChatService.swift:1021).
- Coordinator drops stale epoch and phase-gated events ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:236](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:236), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:240](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:240)).
- No independent epoch counter found in `ProviderChatService` (no epoch state variable).

### Terminal events handled from any active phase
- **PASS** for `auth_failed`/`token_revoked`/`session_replaced` paths.
- Coordinator handles failure reasons before auth-phase guard in `handleAuthResult` ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:302](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:302), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:320](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:320)).
- `fail(...)` transitions to `.failed` with legal transitions covering active phases ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:522](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:522), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:627](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:627), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:638](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:638)).
- Service maps terminal server errors into lifecycle auth failures ([ios/Clawline/Clawline/Services/ProviderChatService.swift:720](ios/Clawline/Clawline/Services/ProviderChatService.swift:720), [ios/Clawline/Clawline/Services/ProviderChatService.swift:738](ios/Clawline/Clawline/Services/ProviderChatService.swift:738), [ios/Clawline/Clawline/Services/ProviderChatService.swift:756](ios/Clawline/Clawline/Services/ProviderChatService.swift:756)).

### Background does not transition `failed -> idle`
- **PASS**.
- Background flow calls `moveToIdleIfNeeded(.appBackgrounded)` ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:184](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:184)).
- `moveToIdleIfNeeded` excludes `.failed` ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:617](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:617)).

## Prior Review Failures (F3/F4/F5/F6/F7 + C1)

- **F3: No `ConversationStoreWriter` formal type**
  - **Still a bug**.
  - No `ConversationStoreWriter` type exists in `ChatViewModel`.
  - Direct mutations of writer-owned stores are still in `ChatViewModel` methods (for example [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:899](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:899), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:901](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:901), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1091](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1091)).

- **F4: No canonical cursor persistence (debounced 500ms)**
  - **Still a bug**.
  - Cursor seed still comes from service replay snapshot (`replayCursorSnapshot().values.max()`) ([ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:476](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:476)).
  - No writer-owned canonical cursor persistence key/debounced write path implemented in `ChatViewModel`.

- **F5: `StreamSwitchCoordinator.reset()` not called on history reset**
  - **Still a bug**.
  - History reset handler clears state and acks coordinator but has no `StreamSwitchCoordinator.reset()` call ([ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:899](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:899)-[ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:909](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:909)).

- **F6: No user mutation queue (50-cap)**
  - **Still a bug**.
  - No pending user mutation queue structure present.
  - User mutations apply immediately (examples: optimistic send at [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:620](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:620)-[ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:622](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:622); resend mutation at [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:667](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:667)-[ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:674](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:674)).

- **F7: Cursor writes outside writer seam**
  - **Still a bug**.
  - `ProviderChatService.handleMessage` still writes replay cursor directly ([ios/Clawline/Clawline/Services/ProviderChatService.swift:678](ios/Clawline/Clawline/Services/ProviderChatService.swift:678)).
  - Service cursor API still exposed on `ChatServicing` ([ios/Clawline/Clawline/Protocols/ChatServicing.swift:65](ios/Clawline/Clawline/Protocols/ChatServicing.swift:65)-[ios/Clawline/Clawline/Protocols/ChatServicing.swift:67](ios/Clawline/Clawline/Protocols/ChatServicing.swift:67)).
  - ChatViewModel still writes cursors through service in cache/stream paths ([ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1723](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1723), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1935](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1935)).

- **C1: ProviderChatService dual event paths**
  - **Still a bug**.
  - In lifecycle mode, service both emits lifecycle event and performs legacy decode/broadcast path in `handleMessage` ([ios/Clawline/Clawline/Services/ProviderChatService.swift:665](ios/Clawline/Clawline/Services/ProviderChatService.swift:665), [ios/Clawline/Clawline/Services/ProviderChatService.swift:680](ios/Clawline/Clawline/Services/ProviderChatService.swift:680)).

## Acceptance Criteria Matrix (Spec § "Acceptance Criteria")

1. Exactly one phase-transition write seam exists (coordinator transition API)  
   - **PASS** ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:596](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:596)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:607](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:607)).

2. `ChatViewModel` no longer schedules reconnect directly  
   - **PASS** (delegates to coordinator at [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:464](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:464), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1502](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1502)).

3. All lifecycle event entrypoints are epoch-scoped; stale epoch events ignored  
   - **PASS** ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:236](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:236)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:243](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:243)).

4. Replay gate prevents `live` until replay completion  
   - **PASS** (`live` transition from `completeReplay` path: [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:509](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:509)).

5. `auth_result` replay metadata decoding is present and validated  
   - **PASS** ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:335](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:335)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:343](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:343)).

6. `replayCount=0` path deterministically emits start+complete and enters `live`  
   - **PASS** ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:367](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:367), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:377](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:377), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:508](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:508)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:509](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:509)).

7. Late cache restore cannot overwrite replay-applied messages/cursor in same epoch  
   - **PASS** ([ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:877](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:877), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1689](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1689), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1719](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1719)).

8. Cursor for reconnect snapshot is read from canonical writer-owned state (no split source)  
   - **FAIL** (still seeded from service replay snapshot at [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:476](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:476); no writer-owned canonical persistence seam).

9. `session_replaced` transitions to `failed` and does not auto-reconnect  
   - **PASS** ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:304](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:304)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:306](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:306), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:525](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:525)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:528](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:528)).

10. App background/foreground transitions follow coordinator contract  
   - **PASS** for failed-background rule and reconnect gating ([ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:184](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:184)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:189](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:189), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:617](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:617), [ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:171](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:171)-[ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:181](ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:181)).

11. Single-writer audit: message/cursor writes confined to `ConversationStoreWriter`  
   - **FAIL** (no formal writer type; direct store mutations remain in `ChatViewModel`, e.g. [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:899](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:899)-[ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:904](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:904), [ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1091](ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1091)).

12. iOS app target builds after integration  
   - **NOT VERIFIED** in this review pass (no build executed during this cross-model audit).

## Cross-Model Result Summary
- Claude Opus independently flagged:
  - observer/start ordering race risk,
  - missing formal single-writer seam.
- Manual validation confirms those, and additionally confirms unresolved structural items F4/F5/F6/F7/C1.

## Final Verdict
- The T100 implementation is **not fully spec-compliant** yet.
- Blocking unresolved items before next deploy attempt:
  1. race path in scene-active before onAppear observer setup,
  2. F3/F4/F5/F6/F7,
  3. C1 dual lifecycle+legacy message path.
