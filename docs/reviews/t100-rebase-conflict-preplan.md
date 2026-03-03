# T100 ProviderChatService Rebase Conflict Preplan

Date: 2026-02-27
Scope: pre-analyze `ProviderChatService.swift` merge conflict between:
- Dictation: `~/src/clawline-dictation` @ `befacb299` (`feature/voice-dictation`)
- T100: `~/src/worktrees/per-stream-state` @ `d450b6941`
- Common base requested: `origin/main` @ `6a2dadb932c3`

File under analysis in all three refs:
- `ios/Clawline/Clawline/Services/ProviderChatService.swift`

## Method
- Extracted all three file versions (`base`, `ours`, `theirs`) with `git show`.
- Ran synthetic 3-way merge (`diff3 -m`) to isolate real text conflicts.
- Reviewed base→ours and base→theirs unified diffs for intent.

## Conflict Summary
`diff3` reports **3 conflicting hunks**, all in the connect-path state/entrypoint area.

Conflict marker locations in synthetic merge output (`/tmp/t100-preplan/merge-preview.swift`):
- Hunk 1: lines `223-233`
- Hunk 2: lines `310-334`
- Hunk 3: lines `336-358`

No other conflict markers found.

## Hunk-by-Hunk Plan

### Hunk 1: Connection gate state fields
Conflict region (synthetic): `/tmp/t100-preplan/merge-preview.swift:223-233`

Relevant source lines:
- Base: `base.swift:215-218`
  - `pendingDisconnectReason`, `isConnecting`, `authToken`
- Ours: `ours.swift:223-226`
  - `isConnecting`, `connectAttemptTask`, `activeLifecycleConnectionToken`
- Theirs: `theirs.swift:240`
  - `connectJoinGate`

Resolution plan:
- Keep from **ours**:
  - `connectAttemptTask` (`ours.swift:224`)
  - `activeLifecycleConnectionToken` (`ours.swift:225`)
- Keep from **theirs**:
  - `connectJoinGate` (`theirs.swift:240`)
- Drop/rewrite:
  - Replace `isConnecting` (`ours.swift:223`, base `217`) with join-gate model for non-lifecycle connect path.

Target merged state block should contain all three concerns:
- `connectJoinGate` (dictation join semantics)
- lifecycle attempt/task token fields (T100 lifecycle semantics)
- existing auth/cursor fields from T100

### Hunk 2: `connect(token:lastMessageId:)` entrypoint body
Conflict region (synthetic): `/tmp/t100-preplan/merge-preview.swift:310-334`

Relevant source lines:
- Ours: `ours.swift:301-303`
  - delegates directly to `connectInternal(...forcedLastMessageId...)`
- Theirs: `theirs.swift:307-324`
  - join behavior via `connectJoinGate.taskForConnect`

Resolution plan:
- Keep from **theirs**:
  - join wrapper (single in-flight connect + joiners await same task)
- Keep from **ours**:
  - forced cursor/last-message semantics in connect helper call
- Reconcile call target:
  - join wrapper should call T100 helper signature (forced last-message variant), not revert to base signature.

Recommended merged shape:
- `connect(token:lastMessageId:)` uses join gate.
- underlying connect worker remains T100-aware (`forcedLastMessageId` behavior).

### Hunk 3: Connect worker signature + `isConnecting` suppression
Conflict region (synthetic): `/tmp/t100-preplan/merge-preview.swift:336-358`

Relevant source lines:
- Ours: `ours.swift:305-345`
  - `connectInternal(token:forcedLastMessageId:)`
  - `isConnecting` guard + `defer` reset
- Theirs: `theirs.swift:326`
  - renamed worker `performConnect(token:lastMessageId:)`
  - no `isConnecting` bool; gate handled above

Resolution plan:
- Keep from **ours**:
  - worker body behavior (including lifecycle-adjacent auth payload handling)
  - `awaitAuthResult(...forcedLastMessageId...)` call path (`ours.swift:334`)
- Keep from **theirs**:
  - remove bool gate logic (`isConnecting` guard/defer), because join gate now owns in-flight suppression
- Naming:
  - either keep `connectInternal` or adopt `performConnect`; either is fine if call sites are updated consistently.

Net requirement:
- Exactly one in-flight control mechanism for non-lifecycle connect path: **ConnectJoinGate**.
- Preserve T100 lifecycle attempt APIs untouched:
  - `startConnectionAttempt` (`ours.swift:354-359`)
  - `stopConnectionAttempt` (`ours.swift:362-366`)

## Non-Conflict but Important Carry-Forward from Dictation
These are not part of the 3-way conflict markers but should be retained when reconciling dictation merge:
- `ConnectJoinGate` actor definition near class top (`theirs.swift:47-68`)
- `scheduleRetry` cancellation-safe sleep handling (`theirs.swift:847-853`)
  - ours still has `try? await Task.sleep(...)` at `ours.swift:1114`

## Fast Rebase Merge Strategy
1. Resolve Hunk 1 by combining fields: keep T100 lifecycle fields + dictation `connectJoinGate`; drop `isConnecting`.
2. Resolve Hunk 2 by taking dictation join-wrapper structure and wiring it to T100 connect worker signature.
3. Resolve Hunk 3 by keeping T100 worker body and removing bool suppression code (`isConnecting` branch/defer).
4. Verify both paths compile and remain distinct:
   - legacy/non-lifecycle connect path uses join gate
   - lifecycle connect path uses `startConnectionAttempt/stopConnectionAttempt` and epoch/token gating.

## Recommendation
Pre-resolution is straightforward: conflicts are localized and semantically compatible. Reconciliation is required (not an auto-merge), but there is a clear deterministic merge with minimal risk if the above hunk plan is followed.
