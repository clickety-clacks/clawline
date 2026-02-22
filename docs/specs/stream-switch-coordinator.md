# Stream Switch UI/Engine Separation

## Goal / Problem Statement
Stream switching has two different workloads that are currently coupled to the same `activeSessionKey` mutation:
- Immediate UI intent updates (pager selection, stream label/placeholder, haptic, toast label)
- Expensive engine activation work (cache restore, snapshot/materialization, layout/measurement, collection updates)

That coupling causes first-visit stalls to leak into interaction/animation paths. The fix is a two-key split so UI intent updates are immediate while engine activation is independently gated.

## Scope
In scope:
- Replace the prior single-key stream-switch coordinator model with a two-key model.
- Classify all current `activeSessionKey` readers into UI-intent vs engine.
- Introduce epoch-based cancellation for delayed engine activation.
- Define read ownership and transition flow.

Out of scope:
- Bubble sizing algorithm changes.
- Message diffing algorithm changes.
- Unrelated chat pipeline refactors.

## State Model (Two-Key Split)
1. `uiSelectedSessionKey`
- Meaning: latest user/pager/programmatic selection intent.
- Update timing: immediate on switch intent.
- Allowed consumers: UI-only surfaces.

2. `engineActiveSessionKey`
- Meaning: session currently activated for message engine and heavy rendering pipeline.
- Update timing: only after settle + debounce gate and epoch validation.
- Allowed consumers: data/restore/snapshot/layout/collection pipeline.

3. `uiSwitchEpoch`
- Monotonic integer/token incremented on each switch intent.
- Used to cancel stale delayed engine activations.

## Mutation Seam Invariants
1. `uiSelectedSessionKey` has exactly one write path: switch intent handling (flow step 3).
2. `engineActiveSessionKey` has exactly one write path: engine commit (flow step 9 for pager, flow step 7 for programmatic immediate path).
3. Direct assignment to either key outside those paths is a boundary violation.

Compatibility note:
- Existing `activeSessionKey` is split into the two keys above.
- Any code currently reading `activeSessionKey` must be re-bound per classification below.

## Reader Classification (Every Current `activeSessionKey` Reader)

### A) Current readers that become UI-intent readers (`uiSelectedSessionKey`)

| Current location | Current read purpose | Classification | Post-split key |
|---|---|---|---|
| `ChatView.swift:708` | visionOS scroll button session context | UI intent/view chrome | `uiSelectedSessionKey` |
| `ChatView.swift:776` | input bar/session-local controls context | UI intent/view chrome | `uiSelectedSessionKey` |
| `ChatView.swift:1032` | render policy fallback key | UI selection fallback | `uiSelectedSessionKey` |
| `ChatView.swift:1044` | `TabView` binding fallback selection | pager selection | `uiSelectedSessionKey` |
| `ChatView.swift:1060` | page dots active dot | pager indicator | `uiSelectedSessionKey` |
| `StreamManagerSheet.swift:258` | selected-row accent dot | stream picker UI | `uiSelectedSessionKey` |
| `StreamManagerSheet.swift:261` | selected-row font weight | stream picker UI | `uiSelectedSessionKey` |
| `ChatViewModel.swift:300` | `activeSessionDisplayName` for UI labels/placeholder | UI label source | `uiSelectedSessionKey` |

### B) Current readers that become engine readers (`engineActiveSessionKey`)

| Current location | Current read purpose | Classification | Post-split key |
|---|---|---|---|
| `ChatViewModel.swift:233` | resolve `activeStream` | engine/session routing | `engineActiveSessionKey` |
| `ChatViewModel.swift:478` | auth restore guard for active session | engine bootstrap | `engineActiveSessionKey` |
| `ChatViewModel.swift:479` | restore cursor for active | engine restore | `engineActiveSessionKey` |
| `ChatViewModel.swift:480` | restore message cache for active | engine restore | `engineActiveSessionKey` |
| `ChatViewModel.swift:482` | restore non-active sessions loop filter | engine restore partition | `engineActiveSessionKey` |
| `ChatViewModel.swift:582` | outbound send session fallback | engine send routing | `engineActiveSessionKey` |
| `ChatViewModel.swift:1028` | mirror `messages` for active session in `setMessages` | engine active dataset | `engineActiveSessionKey` |
| `ChatViewModel.swift:1047` | mirror `lastServerMessageId` for active session | engine active cursor | `engineActiveSessionKey` |
| `ChatViewModel.swift:1654` | restore-last-message guard | engine restore | `engineActiveSessionKey` |
| `ChatViewModel.swift:1655` | restore-last-message for active | engine restore | `engineActiveSessionKey` |
| `ChatViewModel.swift:1656` | copy active cursor | engine active cursor | `engineActiveSessionKey` |
| `ChatViewModel.swift:1724` | cache-restore post-apply active check | engine restore completion | `engineActiveSessionKey` |
| `ChatViewModel.swift:1738` | clear-cursor active check | engine cursor mutation | `engineActiveSessionKey` |
| `ChatViewModel.swift:1847` | default stream initialization guard | engine bootstrap | `engineActiveSessionKey` |
| `ChatViewModel.swift:1901` | snapshot validity check for active key | engine snapshot apply | `engineActiveSessionKey` |
| `ChatViewModel.swift:1902` | delete invalid active stream | engine stream lifecycle | `engineActiveSessionKey` |
| `ChatViewModel.swift:1904` | assign active messages after snapshot | engine dataset | `engineActiveSessionKey` |
| `ChatViewModel.swift:1905` | assign active cursor after snapshot | engine dataset | `engineActiveSessionKey` |
| `ChatViewModel.swift:1937` | stream deletion active check | engine stream lifecycle | `engineActiveSessionKey` |
| `ChatViewModel.swift:1947` | fallback branch guard | engine stream lifecycle | `engineActiveSessionKey` |
| `ChatViewModel.swift:1948` | refresh active messages after non-active deletion | engine dataset | `engineActiveSessionKey` |
| `ChatViewModel.swift:1949` | refresh active cursor after non-active deletion | engine dataset | `engineActiveSessionKey` |
| `ChatViewModel.swift:2154` | no-reply ack session fallback | engine message routing | `engineActiveSessionKey` |
| `ChatViewModel.swift:2233` | connection snapshot cursor session | engine reconnect snapshot | `engineActiveSessionKey` |
| `MessageFlowCollectionView.swift:795` | resolve effective session when no override | engine feed session | `engineActiveSessionKey` |
| `MessageFlowCollectionView.swift:977` | resolved session key for scroll events | engine/list event session | `engineActiveSessionKey` |
| `MessageFlowCollectionView.swift:1308` | typing indicator storage key | engine/list rendering data | `engineActiveSessionKey` |
| `MessageFlowCollectionView.swift:1723` | typing indicator measurement key | engine/list sizing data | `engineActiveSessionKey` |

### C) Coordinator/control reads that must be updated to dual-key semantics

| Current location | Current read purpose | Classification | Post-split behavior |
|---|---|---|---|
| `ChatViewModel.swift:121` | freeze from-current-active during pager transition | control-plane | read `engineActiveSessionKey` |
| `ChatViewModel.swift:176` | idle sync guard | control-plane | sync against `engineActiveSessionKey` |
| `ChatViewModel.swift:179` | no-op if target already active | control-plane | compare target vs `engineActiveSessionKey` |
| `ChatViewModel.swift:187` | transition `from` for commit bookkeeping | control-plane | read `engineActiveSessionKey` |
| `ChatViewModel.swift:240` | coordinator bind initial key | control-plane | initialize from both keys |
| `ChatViewModel.swift:257` | coordinator idle sync API | control-plane | engine-key sync only |
| `ChatViewModel.swift:264` | avoid redundant active-session mutation | control-plane | compare against `engineActiveSessionKey` |
| `ChatView.swift:640` | on-change hook for active key | control-plane/UI bridge | watch `engineActiveSessionKey` for engine listeners; UI listeners move to `uiSelectedSessionKey` |
| `ChatView.swift:648` | layout coordinator active session sync | control-plane/layout | bind to `engineActiveSessionKey` |
| `ChatViewModel.swift:1533` | typing log line | diagnostic | log both keys |

## Read Ownership Table

| Concern | Owner key | Notes |
|---|---|---|
| Pager selection (`TabView`) | `uiSelectedSessionKey` | Must update immediately on intent |
| Stream toast display name | `uiSelectedSessionKey` | Label must not wait for engine gate |
| Input placeholder stream name | `uiSelectedSessionKey` | Placeholder reflects intent, not engine completion |
| Haptic feedback on switch | `uiSelectedSessionKey` | Fire on intent change |
| Active message list (`messages`) | `engineActiveSessionKey` | Expensive updates gated |
| Cache restore (`restoreCachedMessagesIfNeeded`) | `engineActiveSessionKey` | First-visit heavy path |
| Snapshot apply / diff materialization | `engineActiveSessionKey` | Heavy path |
| Layout invalidation/measurement | `engineActiveSessionKey` | Heavy path |
| Collection view updates | `engineActiveSessionKey` | Heavy path |
| Layout coordinator active list binding | `engineActiveSessionKey` | Scroll/inset operations target engine-active page |

## Transition UX (Debounce Window)
1. Previously unvisited stream:
- During settle+debounce and while engine activation is still running, keep the stream toast visible with busy spinner as the loading indicator.
- Toast duration is `max(minimumToastDuration, actualEngineActivationDuration)`.
- Message page may be empty until engine activation materializes first data/snapshot; this is expected and intentionally covered by the toast+spinner.

2. Already visited stream:
- Engine activation is typically fast; toast+spinner still appears but usually only for minimum toast duration.

## Switch Flow (Numbered)
1. Intent received (pager drag target change or programmatic switch).
2. Increment `uiSwitchEpoch`.
3. Immediately set `uiSelectedSessionKey`.
4. Immediately update UI-intent consumers (toast label, placeholder source, haptic).
5. Schedule engine activation candidate `(target: uiSelectedSessionKey, epoch, source)`.
6. Branch by source:
- Pager swipe path: wait for pager settle signal, then debounce 500ms.
- Programmatic path: skip debounce and proceed to immediate commit.
7. Validate epoch; if stale, cancel.
8. If valid, commit `engineActiveSessionKey = target`.
9. Trigger engine pipeline using `engineActiveSessionKey` (restore/snapshot/layout/list updates).

Concurrency note:
- Steps 1-5 execute synchronously on `MainActor` with no suspension points.
- `uiSwitchEpoch` increment and candidate scheduling are atomic within that synchronous turn.

## Epoch-Based Cancellation
- `uiSwitchEpoch` increments on every intent.
- Any delayed engine-activation task captures the epoch at scheduling time.
- Commit is allowed only when `capturedEpoch == currentEpoch`.
- On mismatch, task exits without side effects.

Guarantee:
- Rapid flip-through activates only the final settled stream for engine work.

## Edge Cases
1. Rapid flip-through across many streams
- UI updates every intent immediately.
- Engine commit occurs once for the last settled epoch.

2. Re-drag during settling/debounce
- New intent bumps epoch; in-flight delayed commit becomes stale and self-cancels.

3. Programmatic selection
- Uses same two-key contract but skips debounce.
- UI key updates immediately, then engine commit executes immediately through the same commit seam.

4. Target stream removed before commit
- At commit time, revalidate target exists in `orderedSessionKeys`.
- If missing, drop candidate and keep current `engineActiveSessionKey`.
- UI key reconciles to nearest valid key (first available) via intent update.

5. Empty stream list
- Both keys become empty.
- No engine activation scheduled.

## Acceptance Criteria
1. `uiSelectedSessionKey` and `engineActiveSessionKey` both exist and are semantically distinct.
2. All readers listed in classification table are migrated to the specified key.
3. No heavy engine operations are directly triggered by mutating `uiSelectedSessionKey`.
4. UI intent surfaces (pager selection, toast name, placeholder, haptic) remain immediate even when engine activation is delayed.
5. Pager-swipe engine activation occurs only after settle + debounce + epoch validation.
6. Programmatic selection commits engine immediately (no debounce), still through the single commit seam.
7. Toast+spinner remains visible for at least minimum duration and extends until engine activation finishes for unvisited streams.
8. Stale delayed activations are canceled via epoch mismatch with no side effects.
9. Unvisited stream switch performs heavy work only on engine commit, not on raw intent change.
10. Existing tests/build pass after migration.

## Files Touched
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift`
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- `ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift`
- `ios/Clawline/Clawline/Views/Chat/ChatLayoutCoordinator.swift` (binding/read source updates)
- `ios/Clawline/Clawline/Views/Chat/StreamPageDotsView.swift` (input source change only if required)
