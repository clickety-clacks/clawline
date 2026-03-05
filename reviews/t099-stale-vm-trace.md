# T099 stale ChatViewModel trace (logout -> login)

## Verdict
**Hypothesis confirmed.** A non-current `ChatViewModel` instance can fire `onDisappear()` during login and call `chatService.disconnect()` after connection startup has already begun, interrupting the shared transport.

## What I traced
- Added temporary probe logs around connection start triggers and disconnect call sites in `ChatViewModel`.
- Ran simulator flow: logged-in -> `/logout` -> login.
- Captured timeline from simulator log store (`log show`) and UI state after login.
- Removed all temporary probe logs from code after capture.

## Relevant code paths
- `ChatViewModel.onDisappear()` calls shared disconnect: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:471-487`.
- `handleAuthStateChange()` unauthenticated path also calls shared disconnect: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:502-528`.
- `logout()` also calls shared disconnect: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:749-763`.
- Auth observer lifetime is tied to deinit (`addObserver` in init, remove in deinit): `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:398-457`.

## Evidence (ordered timeline)
Source file: `/tmp/t099-stalevm-timeline.txt`

1. Multiple VM instances are active on login and all receive auth-start trigger:
- `id=AF4CD600...` and `id=A3665309...` start triggers at lines `459-460`.
- New instance `id=822EC543...` is initialized and also starts at lines `464-469`.

2. Connection startup begins before the stale-disconnect event:
- `lifecycle phase-transition from=idle to=connecting` at lines `475`, `476`, `478`.

3. Then `onDisappear` from `id=822EC543...` fires and disconnects shared transport while state is reconnecting:
- `ChatViewModel onDisappear id=822EC543...` at line `524`.
- `[T099-STALEVM] disconnect trigger=onDisappear ... state=reconnecting` at line `525`.
- `ProviderChatService disconnect requested` at line `526`.
- Immediate service disconnect and coordinator collapse to idle follow at lines `527-531`.

4. After that interruption, another instance restarts recovery/connecting:
- `phase-transition from=recovering to=connecting epoch=5` at line `532`.
- Connection events then proceed again under a different VM id (`AF4CD600...`), indicating ownership churn.

5. Deinit evidence:
- No `ChatViewModel deinit` entries in the same trace window (`log show --last 15m` grep count = `0`).

## Symptom reproduction state
Post-login UI snapshot (`/tmp/t099-stalevm-pass2-after-login.json`) still shows reconnecting:
- `AXLabel: "Reconnecting"` (line 195)
- Active stream key remains `agent:main:clawline:qa_sim:dm` (line 48)

## Raw excerpt
```text
475: ... lifecycle phase-transition from=idle to=connecting epoch=4
476: ... lifecycle phase-transition from=idle to=connecting epoch=2
478: ... lifecycle phase-transition from=idle to=connecting epoch=1
524: ... ChatViewModel onDisappear id=822EC543-D9C8-4E43-991C-1E1D045E6A33
525: ... [T099-STALEVM] disconnect trigger=onDisappear id=822EC543... state=reconnecting
526: ... ProviderChatService disconnect requested
531: ... lifecycle phase-transition from=recovering to=idle epoch=1
532: ... lifecycle phase-transition from=recovering to=connecting epoch=5
```
