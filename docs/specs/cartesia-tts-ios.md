# Cartesia TTS iOS Integration (Issue #118)

Status: Draft (implementation-grade)
Last updated: 2026-02-27
Owner: iOS spec agent
Canonical path: `/Users/mike/shared-workspace/clawline/specs/cartesia-tts-ios.md`

## 1. Goal

Add Cartesia Sonic-3 text-to-speech to Clawline chat on Apple platforms (iOS, iPadOS, visionOS) with:

1. Client-direct Cartesia WebSocket streaming (no provider proxy), mirroring Soniox's client-direct pattern.
2. Settings support for Cartesia API token + Verify button, matching Soniox token row behavior.
3. Chat UI speaker toggle (speaker icon) to the left of page indicator, centered as one horizontal control group, visible only when a verified Cartesia token exists.
4. Read-aloud for assistant responses.
5. AVSpeechSynthesizer fallback when no verified Cartesia token is available.
6. iOS WatchConnectivity push of Cartesia API key + Cartesia voice ID to Watch via `transferUserInfo`.

## 2. Read Context and Cross-Spec Alignment

This spec is aligned to:

- `/Users/mike/shared-workspace/clawline/provider-architecture.md`
- `/Users/mike/shared-workspace/clawline/specs/multi-stream.md`
- `/Users/mike/shared-workspace/clawline/specs/clawline-invariants.md`
- Existing secure storage pattern in `ios/Clawline/Clawline/Services/{SecureStore,KeychainSecureStore,AuthManager}.swift`
- Soniox key UX contract in `docs/specs/voice-dictation.md` and `docs/specs/dictation-architecture.md` (`Get Key`/`Verify`, status text contract, single owner key store)
- Watch key sync contract in `/Users/mike/shared-workspace/clawline/specs/watch-app.md` (Key Bootstrapping section)

Note: `/Users/mike/shared-workspace/clawline/specs/watch-ios-support.md` does not currently exist. Coordination for this issue is therefore against `watch-app.md`.

## 3. Scope and Non-Goals

### 3.1 In scope

1. Cartesia Sonic-3 streaming playback from assistant text.
2. Cartesia API token persistence + verification UX.
3. Chat chrome speaker toggle + read-aloud pipeline.
4. AVSpeechSynthesizer fallback path.
5. iOS WatchConnectivity credential sync for `cartesiaApiKey` + `cartesiaVoiceId`.
6. Test coverage for token verification, toggle visibility/layout contract, playback routing, and sync payload.

### 3.2 Out of scope

1. Watch app implementation (separate feature/spec).
2. Provider-side TTS proxying/endpoints.
3. Voice picker UI (this issue uses one configured voice ID source).
4. Transcript/STT changes.
5. Changing stream/session routing semantics.

## 4. Binding Decisions

1. **Client-direct only.** Cartesia traffic goes from app -> Cartesia cloud directly; provider is not in TTS path.
2. **Sonic-3 only for this issue.** Model ID is fixed to `sonic-3`.
3. **One write seam for Cartesia credentials.** A dedicated store owns API key, verification status, and voice ID.
4. **One write seam for read-aloud state machine.** A single coordinator owns playback backend selection and cancellation.
5. **Speaker control visibility gate:** visible only when key status is `validated`.
6. **Fallback selection rule:** if read-aloud is enabled and token is not `validated`, use AVSpeechSynthesizer.
7. **iOS-only WatchConnectivity transport:** sync runs on iOS/iPadOS host app; visionOS excludes WatchConnectivity codepaths.
8. **Playback conflict rule:** if a new assistant response arrives while speaking, cancel current utterance and start the newest one (latest-message-wins).
9. **Replay rule:** auto-read-aloud applies to live assistant arrivals only; replay/history hydration must not trigger TTS.

## 5. Architecture

### 5.1 Components

1. `CartesiaKeyStore` (`@Observable`, `@MainActor`)
- SSOT for token + verification status + voice ID.
- Persists token through `SecureStoring` using AuthManager-style Keychain-first pattern.
- Exposes CTA/status derivations used by Settings row.

2. `CartesiaKeyVerifier`
- Performs real network verification.
- Updates `CartesiaKeyStore.keyStatus` to `validating` -> `validated|invalid`.

3. `CartesiaTTSClient`
- Handles Cartesia WebSocket lifecycle and chunk decoding.
- Streams PCM chunks to playback sink.

4. `AssistantReadAloudCoordinator`
- SSOT for read-aloud runtime state (`idle`, `connecting`, `speaking`, `fallbackSpeaking`, `failed`).
- Chooses backend: Cartesia vs AVSpeechSynthesizer fallback.
- Dedupes by assistant message ID so a message is spoken once.
- Owns interruption policy (`latest-message-wins`) and explicit stop on toggle-off/background.

5. `WatchCredentialSyncService` (iOS only)
- Owns WatchConnectivity `transferUserInfo` pushes for Cartesia credentials.

### 5.2 State Ownership Map (SSOT)

| Product concept | Owner | Writers | Readers |
| --- | --- | --- | --- |
| Cartesia API key | `CartesiaKeyStore` | `setKey(_:)` only | Settings UI, read-aloud coordinator, watch sync service |
| Cartesia key status (`missing/unverified/validating/invalid/validated`) | `CartesiaKeyStore` | `setKey(_:)`, `verify()` only | Settings UI, chat toggle visibility gate, read-aloud coordinator |
| Cartesia voice ID | `CartesiaKeyStore` | store init/default assignment (this issue) | Cartesia client, watch sync service |
| Read-aloud enabled preference | `AssistantReadAloudCoordinator` | `setEnabled(_:)` only | Chat UI toggle, ChatViewModel incoming assistant handler |
| Playback backend state | `AssistantReadAloudCoordinator` | `speakAssistantMessage(...)`, `stop()` only | ChatViewModel, diagnostics |
| Spoken-message dedupe set | `AssistantReadAloudCoordinator` | coordinator internals only | none (opaque) |
| Watch credential push debounce/in-flight | `WatchCredentialSyncService` | service internals only | none (opaque) |

No other type may persist or gate these concepts independently.

## 6. Cartesia Credential and Verification Contract

### 6.1 Data model

```swift
enum CartesiaKeyVerificationStatus: String, Codable {
    case missing
    case unverified
    case validating
    case invalid
    case validated
}
```

`CartesiaKeyStore` stored state:

- `apiKey: String?`
- `keyStatus: CartesiaKeyVerificationStatus`
- `voiceId: String`
- `editableKey: String` (UI scratch)

Derived state:

- `hasKey: Bool`
- `isVerified: Bool` (`keyStatus == .validated`)
- `ctaTitle: String` (`Get Key` when empty, `Verify` when non-empty)
- `statusText: String?` (`Invalid` / `Validated`)

### 6.2 Persistence pattern (match existing secure-store pattern)

1. Token uses Keychain via `SecureStoring` key `cartesia.apiKey`.
2. Migration fallback: if legacy value exists in `UserDefaults` key `cartesia.apiKey`, migrate to Keychain on init.
3. Verification status + voice ID persist in `UserDefaults` (`cartesia.keyStatus`, `cartesia.voiceId`).
4. `setKey(_:)` always resets status to `.unverified` unless key is empty (`.missing`).
5. Voice ID key is `cartesia.voiceId`; default value comes from one constant `CartesiaVoiceDefaults.defaultVoiceId` (no voice picker UI in this issue).

### 6.3 Verification behavior

`verify()` rules:

1. Reject empty key locally as `.missing` (no network call).
2. For non-empty key, perform real network verification (no regex/length-only acceptance).
3. Success -> `.validated`.
4. Any auth/network/server verification failure -> `.invalid`.
5. Status text contract is exact: `Validated` or `Invalid`.

Verification must be cancel-safe; if user edits key during verify, stale result must be ignored.

Verification transport contract:

1. Use real Cartesia auth/network validation through Cartesia API surface (no local-only validation).
2. Timebox verify request to 5 seconds.
3. Any timeout is treated as `invalid` for UI purposes.

## 7. Cartesia Streaming Contract

### 7.1 Endpoint and request shape

WebSocket endpoint (watch-app aligned):

`wss://api.cartesia.ai/tts/websocket?api_key=<KEY>&cartesia_version=2025-04-16`

Generation request:

```json
{
  "model_id": "sonic-3",
  "transcript": "<assistant text>",
  "voice": { "mode": "id", "id": "<voice-id>" },
  "language": "en",
  "context_id": "<unique utterance id>",
  "output_format": {
    "container": "raw",
    "encoding": "pcm_s16le",
    "sample_rate": 24000
  },
  "continue": false
}
```

Chunk response:

```json
{
  "type": "chunk",
  "data": "<base64 pcm>",
  "done": false,
  "context_id": "<same>"
}
```

Cancellation request for barge/stop:

```json
{
  "context_id": "<same>",
  "cancel": true
}
```

### 7.2 Playback

1. Primary path uses `AVAudioEngine` + `AVAudioPlayerNode` for streamed PCM (`pcm_s16le`, 24kHz mono).
2. On no verified token, fallback path uses `AVSpeechSynthesizer`.
3. `AssistantReadAloudCoordinator` normalizes both paths behind one API so ChatViewModel has one call site.
4. When read-aloud is disabled mid-utterance, coordinator immediately stops current playback and transitions to `idle`.
5. App/background transition stops active playback; foreground does not auto-replay already received messages.

## 8. Settings UX Contract

Add a **Cartesia API Key** row that matches Soniox row interaction model:

1. Secure text field for key entry.
2. Companion CTA button in same row.
3. CTA behavior:
- empty key -> `Get Key` opens Cartesia dashboard/signup URL in browser.
- non-empty key -> `Verify` triggers real verification.
4. Inline status text renders `Invalid` or `Validated`.
5. Editing the key clears previous validated state to `.unverified` immediately.

No additional settings controls are introduced in this issue.

## 9. Chat UI Contract

### 9.1 Speaker toggle placement and visibility

1. Add a speaker toggle control with speaker icon.
2. Position it **to the left of the page indicator control**.
3. Speaker + page indicator must be wrapped in one horizontal group whose **combined width is centered**.
4. Toggle is visible only when `CartesiaKeyStore.keyStatus == .validated`.
5. When hidden, page indicator remains centered (no stale spacing placeholder).

### 9.2 Toggle semantics

1. Toggle controls `AssistantReadAloudCoordinator.isEnabled`.
2. Icon states:
- enabled: `speaker.wave.2.fill`
- disabled: `speaker.slash.fill`
3. State persists across launches.

### 9.3 Read-aloud trigger rules

1. Trigger only on assistant messages (`role == .assistant`) that are finalized (`streaming == false`).
2. Speak only once per server message ID.
3. Do not speak if read-aloud toggle is off.
4. If toggle is on:
- verified key -> Cartesia path
- not verified -> AVSpeechSynthesizer fallback path

### 9.4 Live-vs-replay gating

1. Replay/hydrated history must not trigger read-aloud.
2. `ChatViewModel` must call read-aloud only from the live incoming-message path (not from cache restore, replay restoration, or stream switch hydration paths).
3. If service layer does not currently expose replay boundaries, this issue adds the minimum boolean seam required for ChatViewModel to distinguish replayed vs live assistant events.

## 10. WatchConnectivity Sync Contract (iOS only)

### 10.1 Payload keys

When Cartesia credential state changes, iOS sends:

```swift
WCSession.default.transferUserInfo([
  "cartesiaApiKey": cartesiaKeyStore.apiKey ?? "",
  "cartesiaVoiceId": cartesiaKeyStore.voiceId
])
```

If a broader credential payload already exists, these keys must be merged into the existing transfer dictionary (not sent as a competing schema).

Semantics:

1. Empty string for `cartesiaApiKey` means "clear key on watch".
2. `cartesiaVoiceId` is always sent (non-empty).

### 10.2 Push triggers

Call sync on:

1. API key change (`setKey`).
2. Successful verification (status flips to `validated`).
3. Voice ID change.
4. App launch bootstrap if paired watch exists (best-effort refresh).

### 10.3 Platform guard

- Compile/run WatchConnectivity sync only for iOS/iPadOS host app.
- visionOS excludes WatchConnectivity references.

## 11. Platform Scope Matrix

| Platform | In scope behavior |
| --- | --- |
| iPhone | Full feature set (Cartesia + fallback + toggle + settings + watch sync when paired) |
| iPad | Same as iPhone |
| visionOS | Cartesia + fallback + toggle + settings; no WatchConnectivity sync |
| watchOS | Out of scope in this issue |

## 12. Implementation Guidance (File-Level)

Paths relative to `ios/Clawline/Clawline` unless stated.

### 12.1 New files

1. `Services/CartesiaKeyStore.swift`
2. `Services/CartesiaKeyVerifier.swift`
3. `Services/CartesiaTTSClient.swift`
4. `Services/AssistantReadAloudCoordinator.swift`
5. `Services/WatchCredentialSyncService.swift`

### 12.2 Existing files to update

1. `ClawlineApp.swift`
- Instantiate/inject key store, read-aloud coordinator, watch sync service.

2. `Environment/EnvironmentKeys.swift`
- Add environment keys for Cartesia key store and read-aloud coordinator.

3. `Settings/SettingsView.swift`
- Add Cartesia key row with Soniox-pattern CTA/status behavior.

4. `Views/Chat/ChatView.swift`
- Replace standalone page dots host content with centered horizontal group (speaker toggle + page dots).
- Gate speaker control visibility on verified token.

5. `ViewModels/ChatViewModel.swift`
- Inject read-aloud coordinator + key store.
- On incoming finalized live assistant message, call single read-aloud seam.
- Do not invoke from replay/cache hydration paths.

6. `Views/RootView.swift`
- Pass new dependencies into `ChatViewModel` initialization.

### 12.3 Optional small protocol seams (if needed for testability)

If direct concrete wiring blocks unit tests, add minimal protocols:

1. `CartesiaTTSPlaying` for Cartesia client.
2. `SpeechSynthesizing` wrapper for `AVSpeechSynthesizer`.

Do not add additional abstraction layers beyond test seam needs.

## 13. Testing Requirements

### 13.1 Unit tests

1. `CartesiaKeyStoreTests`
- Keychain-first load + UserDefaults migration.
- `setKey` status transitions.
- CTA/status text derivation.

2. `CartesiaKeyVerifierTests`
- valid key -> `validated`
- invalid/unauthorized -> `invalid`
- stale verify result dropped after key edit.
- verify timeout -> `invalid`

3. `AssistantReadAloudCoordinatorTests`
- backend selection (Cartesia vs fallback).
- dedupe by message ID.
- toggle disabled suppresses playback.
- new message while speaking cancels prior and speaks newest.
- toggle-off while speaking stops playback.

4. `WatchCredentialSyncServiceTests`
- `transferUserInfo` payload contains `cartesiaApiKey` + `cartesiaVoiceId`.
- sync triggers on key/status/voice changes.

5. `ChatViewModelTests`
- finalized assistant messages invoke coordinator once.
- streaming assistant updates do not invoke until finalized.
- replay/cache hydration paths never invoke coordinator.

### 13.2 UI/layout tests

1. Chat control group layout: speaker toggle left of page indicator, group centered.
2. Toggle hidden when key not validated.
3. Toggle visible when validated.
4. Settings row CTA semantics (`Get Key` vs `Verify`) and status text rendering.

## 14. Acceptance Criteria

1. Cartesia TTS requests are client-direct over WebSocket to Cartesia; provider is not used as a proxy.
2. Settings includes Cartesia token input + companion CTA row matching Soniox pattern.
3. Empty key CTA opens Cartesia key page; non-empty CTA runs network verification.
4. Verification result displays exact inline text: `Invalid` or `Validated`.
5. Chat shows a speaker toggle with speaker icon left of page indicator.
6. Speaker + page indicator are horizontally centered as one group.
7. Speaker toggle is only visible when Cartesia key is verified.
8. Finalized assistant responses can be read aloud when toggle enabled.
9. Read-aloud uses Cartesia when key is verified.
10. Read-aloud falls back to AVSpeechSynthesizer when key is not verified.
11. iOS pushes `cartesiaApiKey` and `cartesiaVoiceId` to Watch via `transferUserInfo` on credential changes.
12. Empty `cartesiaApiKey` sync payload clears watch-side key state.
13. Live assistant messages can trigger read-aloud; replay/history hydration never does.
14. Feature works on iOS/iPadOS/visionOS; watch app implementation remains out of scope.

## 15. Open Questions

None blocking for issue #118.

## 16. Implementation Handoff

1. Implement exactly this scope; do not add provider endpoints, watch app UI, or voice picker UI in this issue.
2. If Cartesia verification API behavior differs from assumptions at runtime, update this spec before changing behavior.
3. Keep the spec agent session available for implementation clarifications.
