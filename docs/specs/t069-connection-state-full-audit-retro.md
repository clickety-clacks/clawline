# T069 Connection State UI — Full Audit + Architecture Retro

Date: 2026-02-17
Scope: `MessageInputBar`, `ChatViewModel`, connection observers, error-text setters, pulse animation path.
Spec reference: `/Users/mike/shared-workspace/clawline/specs/connection-state-ui.md`

## 1) Input Bar Appearance Mutation Map

### A. Border color mutation seams
- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift`
- `visionOSBorderColor` (computed) feeds:
  - Appearance toggle button stroke
  - Add button stroke
  - Editor chrome stroke (`MessageEditorChrome` overlay)
  - Send control stroke (visionOS only)
- Connection state is *not* currently an explicit input to these border calculations.

### B. Placeholder text mutation seams
- `MessageInputBar` + `RichTextEditor` have no explicit placeholder string path.
- No placeholder setter was found in `MessageInputBar`, `ChatView`, `RichTextEditor`, or `ChatViewModel`.
- `ChatViewModel` writes `inputContent` only in one production path: `clearInput()` (empty string).

### C. Background mutation seams
- Editor background:
  - `MessageEditorChrome`: `.regularMaterial` (visionOS) / `.ultraThinMaterial` (others)
  - No connection-state dependency.
- Send control background:
  - `MessageSendControl.sendBackgroundColor` maps connection state to token colors.
  - This is the intended connection-state visual surface per spec.

### D. Send-button appearance mutation seams
- Inputs: `isSending`, `canSend`, `connectionState`.
- States rendered in `MessageSendControl`:
  - Connected: paperplane (or stop when sending)
  - Reconnecting: yellow dot
  - Disconnected: red reconnect icon

## 2) Connection State Read/Write Path Map

### Read paths driving UI
- `ChatView` passes `viewModel.sendButtonConnectionState` into `MessageInputBar`.
- `MessageInputBar` maps `SendButtonConnectionState` into send control visuals.
- `ChatViewModel.canSend` depends on `sendButtonConnectionState`.

### Write paths (pre-fix)
1. `observeConnectionState()` stream handler:
- `connectionState = state`
- `handleConnectionState(state)`

2. `reconnect()`:
- `connectionState = .reconnecting`

3. `handle(serviceEvent: .connectionInterrupted)`:
- `if sendButtonConnectionState == .connected { connectionState = .reconnecting }`

### Seam count finding
- `connectionState` had **3 independent direct mutation paths**.
- This violates architecture-principles mutation seam discipline (single mutation point).

## 3) Error Text Setter Map (All Paths)

### User-visible toast setters (ChatViewModel)
- `send()` guard failures:
  - `"Could not send; not connected."`
  - `"No stream selected."`
  - `"This stream is unavailable. Switch streams and try again."`
- Send/retry catch paths:
  - `toastManager.show(error.localizedDescription)`
  - `toastManager.show(error: attachmentError)`
- Service event message errors:
  - `toastManager.show(resolved)` when policy allows.

### Error text persistence paths
- `messageFailures[messageId] = MessageFailure(code:, message:)` in service-event and send-failure paths.
- Pre-fix, raw `error.localizedDescription` could be persisted into `MessageFailure.message` for queue failures.

### Input placeholder text setter finding
- No direct input-placeholder setter path found in the audited files.
- Error strings can still be persisted in failure metadata, which is a leak-prone path if any future/alternate renderer consumes that text.

## 4) Pulse Animation Audit

### Intended path
- `MessageSendControl` should pulse reconnecting dot with 0.8s ease-in-out loop.

### Pre-fix implementation
- `@State reconnectPulseOn`
- Starts in `.onAppear` / `.onChange(of: connectionState)` using `withAnimation(...repeatForever...)`

### Why this is fragile
- `MessageInputBar` is hosted in `safeAreaInset`; the file itself warns local state/`onChange` can be unreliable under view recreation.
- Pulse relied on local state toggling and lifecycle callbacks in a churn-prone host context.
- This violates architecture-principles separation/state-ownership guidance for unstable lifecycle boundaries.

## 5) What Was Tried Before + Why Regressions Kept Happening

Recent sequence (from git history):
- `35aca1e59`: send-button state UI introduced.
- `13c89a72c`, `160275ec7`: behavior refinements.
- `2d7002ec0`, `ca2c91197`, `d80cc3b17`: border/placeholder cleanup passes.
- `4b3df48b3`: refactor of `MessageInputBar` structure.

Regression pattern:
- Repeated symptom patches landed across multiple commits without first consolidating state ownership seams.
- Connection state remained mutable from multiple paths while send-button rendering continued to evolve.
- Pulse behavior stayed coupled to local view lifecycle state in a known unstable host context.

## 6) Architecture-Principles Review Findings

Against `/Users/mike/.codex/skills/architecture-principles/SKILL.md`:

1. Separation of concerns first:
- Violated by split connection-state mutation responsibility (stream + manual reconnect + service event).

2. State mutation seam discipline:
- Violated: one state (`connectionState`) had multiple direct writers.

3. Paired deliverables for spaghetti-revealing bugs:
- This retro is the required architecture deliverable B accompanying the bug fix.

4. Right-weight architecture:
- Needed lightweight consolidation (single transition API), not broad framework abstraction.

## 7) Recommended Refactor Boundary (Minimal, Spec-Aligned)

1. Introduce one internal `connectionState` transition method in `ChatViewModel`.
2. Route all connection-state writes through that method.
3. Replace reconnect pulse driver with deterministic time-based rendering that does not require local toggled state in the input bar subtree.
4. Keep editor border/background and placeholder behavior connection-agnostic; connection state remains send-button-only UI.
