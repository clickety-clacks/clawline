# T099 Login Flow Trace (per-stream-state)

## Scope
Compared:
- **Flow 1**: app already running unauthenticated, user logs in (token set mid-session).
- **Flow 2**: cold app launch with token already present.

Files traced:
- `ios/Clawline/Clawline/Views/RootView.swift`
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
- `ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift`
- `ios/Clawline/Clawline/Services/ProviderChatService.swift`

---

## 1) Entry point for each flow

### Flow 1 (fresh login while app is already open)
1. User becomes authenticated; `auth.isAuthenticated` flips true.
2. `RootView` `.task(id: auth.isAuthenticated)` runs and calls `ensureChatViewModel()` (`RootView.swift:53-68`).
3. `ensureChatViewModel()` creates `ChatViewModel` (`RootView.swift:92-103`).
4. `ChatViewModel.init` immediately calls `handleAuthStateChange()` (`ChatViewModel.swift:429-483`).
5. Auth-path task inside `handleAuthStateChange` runs:
   - `startObservingIfNeeded()`
   - `lifecycleCoordinator.setAuthToken(auth.token)`
   - `seedCanonicalCursor`
   - `lifecycleCoordinator.startIfNeeded()`
   (`ChatViewModel.swift:561-573`)
6. When `ChatView` appears, `.task` also runs `handleSceneActiveStateChanged(...)` then `onAppear()` (`ChatView.swift:458-460`), which can also call:
   - `startObservingIfNeeded()`
   - `setAuthToken`
   - `startIfNeeded`
   (`ChatViewModel.swift:492-516`)

### Flow 2 (cold launch already authenticated)
1. `RootView` immediately goes authenticated branch (`RootView.swift:40-47`).
2. `ProgressView.task` and `.task(id: auth.isAuthenticated)` can both call `ensureChatViewModel()`; nil guard makes creation single-shot (`RootView.swift:46`, `53-68`, `92-103`).
3. Same as Flow 1 from VM creation onward:
   - `ChatViewModel.init` -> `handleAuthStateChange()` (`ChatViewModel.swift:429-483`)
   - auth-path task with observer setup + token + `startIfNeeded` (`ChatViewModel.swift:561-573`)
   - `ChatView.task` runs `sceneActive` + `onAppear` (`ChatView.swift:458-460`)

---

## 2) Where the flows diverge

Primary divergence is **before VM creation**:
- Flow 1 reaches VM creation from an auth-state transition while app is live (`RootView.swift:53-68`).
- Flow 2 reaches VM creation during initial authenticated render (`RootView.swift:40-47`, `53-68`).

Secondary divergence is trigger ordering/races after VM creation:
- `handleAuthStateChange()` starts connection path from init (`ChatViewModel.swift:482`, `548-573`).
- `onAppear()` and `sceneDidBecomeActive` can start similar work near-simultaneously (`ChatViewModel.swift:492-516`, `587-600`; `ChatView.swift:458-467`).

So divergence is mostly **timing/order of triggers**, not logic differences.

---

## 3) Where flows converge

They converge at `ChatViewModel` auth-path startup and remain shared through transport:

1. `ChatViewModel.handleAuthStateChange` auth branch (`ChatViewModel.swift:561-573`)
2. `ConnectionLifecycleCoordinator.startIfNeeded` -> `startConnecting` (`ConnectionLifecycleCoordinator.swift:210-217`, `592-623`)
3. Coordinator `startAttempt` calls service `startConnectionAttempt(epoch:lastMessageId:token:)` (`ChatViewModel.swift:452-455`, `ProviderChatService.swift:356-361`)
4. Service lifecycle connect path (`ProviderChatService.swift:500-564`):
   - socket connect
   - `startLifecycleListening`
   - emit `transportOpened`
   - `sendAuth`
5. Coordinator consumes lifecycle events (`ConnectionLifecycleCoordinator.swift:259-287`):
   - `transportOpened` -> `.authenticating` (`289-303`)
   - `authResult` -> `.replaying`/`.live` (`322-397`, `404-418`, `547-558`)
6. Bubble loading begins from:
   - `restoreCacheRequested` -> `restoreCachedMessagesIfNeeded` (`ConnectionLifecycleCoordinator.swift:611`, `ChatViewModel.swift:1338-1341`, `1864+`)
   - replay/live `serverMessage` -> `handleLifecycleServerMessage` -> `handleIncoming` (`ChatViewModel.swift:1346-1348`, `1059-1075`, `998-1057`)

---

## 4) Is divergence necessary, or duplicated work?

Some divergence is necessary (different app states: unauthenticated live session vs authenticated cold start), but **connection bootstrap work is duplicated**:
- `handleAuthStateChange` auth path does observer+token+start (`ChatViewModel.swift:561-573`)
- `onAppear` does observer+token+start again (`ChatViewModel.swift:510-516`)
- `sceneDidBecomeActive` also does observer then coordinator foreground start (`ChatViewModel.swift:595-599`)

Current guards/single-flight reduce damage:
- `startObservingIfNeeded` single-flight (`ChatViewModel.swift:627-633`, `666-669`)
- coordinator phase guard in `startIfNeeded` (`ConnectionLifecycleCoordinator.swift:212-216`)

But this is still multiple entry points into the same startup sequence.  
**Recommendation**: unify connection bootstrap to one startup seam (auth-token path), and keep `onAppear`/scene-active focused on foreground resume semantics.

---

## 5) Is there a pre-login ChatViewModel that can later disconnect after post-login connect starts?

For a clean unauthenticated session, **no**:
- `RootView` shows `PairingView` when unauthenticated (`RootView.swift:40-41`).
- `ChatViewModel` is only created in authenticated path via `ensureChatViewModel()` (`RootView.swift:42-47`, `92-103`).

So there is no distinct "pre-login VM" created before auth in this flow.

However, stale prior authenticated VMs can exist across auth transitions if not retired. Current code mitigates this:
- `RootView` calls `prepareForReplacement()` before dropping VM (`RootView.swift:61-62`, `69-70`)
- `prepareForReplacement` cancels observers and only owner can disconnect (`ChatViewModel.swift:687-696`)
- `onDisappear` disconnect is owner-gated (`ChatViewModel.swift:519-531`)

So the current stale-VM protection is explicit and should prevent old generations from tearing down shared transport after new connect starts.
