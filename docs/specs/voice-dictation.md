# Voice Dictation via Soniox Streaming STT

## Goal
Add voice dictation to Clawline compose input using Soniox real-time WebSocket STT, implementing finalized T027 UX:
- Mic icon inside text field.
- Tap/hold/swipe activation modes.
- Border squiggle as "mic is hot" indicator.
- Live partial transcription into compose with no batching UI.
- Settings-managed Soniox key UX with in-app verification and compose-inline fallback.

## Non-Goals
- Re-designing finalized T027 interactions.
- Adding provider-side Soniox proxying or provider endpoint contracts.
- Persisting raw audio.
- Adding translation/rewriting transforms during dictation.

## Architecture Conformance (T027)
This spec follows the T027 architecture decision:
- Client-direct Soniox connection.
- No provider involvement in dictation transport.

T027 includes a note that temporary server-issued keys are a possible future detail. For this spec revision, that detail is explicitly deferred and out of scope. Current in-scope key handling is client configuration only. If future hardening introduces server-issued temp keys, transport remains client-direct (client still connects to Soniox directly).

## Client Configuration

### Soniox key config
- Client config value: `soniox.apiKey`.
- `soniox.apiKey` may be either a regular Soniox API key or a Soniox temporary API key for `transcribe_websocket` usage.
- Optional hardening path (still client-direct, no provider): app may mint a Soniox temporary key directly via Soniox's Create Temporary API Key endpoint (see References), then use that temporary key for the WebSocket session.
- Treated like provider URL config (runtime/environment configuration).
- Dictation affordance visibility is never conditioned on key presence.

### Key verification model
- Persisted key status enum:
  - `missing` (no key value)
  - `unverified` (key present, not yet verified)
  - `validating` (verification in flight)
  - `invalid` (last verification failed)
  - `validated` (last verification succeeded)
- Verification must be real network validation against Soniox auth surface (client-direct), never local format/length checks as the source of truth.
- Required inline status text when a verification attempt completes:
  - `Invalid` on failed verification.
  - `Validated` on successful verification.

### Settings UI: Soniox key row
- Settings contains a Soniox key input and a companion CTA button in the same row/model used by compose inline key prompts.
- CTA behavior:
  - If key is empty: CTA label/action opens Soniox key signup/manage page.
  - If key is present: CTA label is `Verify` and triggers real verification.
- Status text renders inline below/next to the control row using the same copy contract: `Invalid` or `Validated`.

### Mic visibility
- `micVisible = !textFieldFocused && composeText.isEmpty && !dictationActive`

Behavior:
- `idle_mic_visible`: empty + unfocused -> mic visible.
- Focus gain: mic slides out right (700ms, ease-out) and enters `idle_mic_hidden`.
- `idle_mic_hidden` persists while focused or text non-empty.
- Blur + empty returns to `idle_mic_visible`.
- Key-missing or key-invalid states do not modify mic visibility rules.

## Final UX Contract

### Activation and exit
- Tap mic (`idle_mic_visible`) -> sticky mode.
- Hold mic (`idle_mic_visible`) -> walkie-talkie mode; release exits.
- Swipe-left from `idle_mic_hidden`:
  - quick swipe + release -> sticky
  - swipe-left + hold past threshold -> walkie-talkie
- Swipe-right during active dictation -> exit dictation.
- Keyboard/focus behavior during active dictation:
  - entry from `idle_mic_hidden` keeps current text focus and keyboard visibility
  - entry from `idle_mic_visible` keeps keyboard hidden until user explicitly focuses text

Stop affordances in sticky mode:
- swipe-right gesture
- VoiceOver action `Stop Dictation`
- hardware keyboard `Esc`
- send action

### Mic appearance behavior
- Two distinct animations are intentional:
  - focus-gain pedagogical slide-out (teaches where mic moved)
  - post-activation fade-out (icon is trigger, not state indicator)
- Mic icon is trigger only.
- After dictation starts (all entry paths), mic fades out within 1.2s even while dictation remains active.
- Swipe-left retrieval animation: mic slides back in from the right over 350ms, ease-out.

### State indicator and waveform
- Border squiggle is canonical state indicator.
- Border squiggle is the waveform visualization for this design (audio-reactive waveform rendered on input border).
- Audio-reactive parameters:
  - update cadence: 20Hz (every 50ms)
  - input metric: RMS amplitude of captured PCM window
  - displacement mapping: RMS low/high mapped to 1pt to 6pt border perturbation
  - no-audio while mic hot: maintain low-amplitude idle motion at 0.5Hz so active state remains visible

### Live transcription
- No batching.
- Soniox partial/final tokens stream directly into compose text.
- After dictation ends, text remains editable/sendable.

## Client Architecture

### Components
- `DictationCoordinator`
  - Owns state machine + gesture interpretation.
  - Coordinates audio capture + socket lifecycle.
- `DictationAudioCapture`
  - Captures via `AVAudioEngine`.
  - Converts to Soniox wire format.
- `SonioxStreamingClient`
  - Implements Soniox WebSocket protocol.
- `DictationTranscriptBuffer`
  - Maintains final/non-final tokens.
- `ComposeInputDictationBridge`
  - Applies transcript snapshots into compose draft for active session key.

### High-level flow (client-direct)
1. User invokes dictation affordance (tap/hold/swipe), regardless of current key state.
2. If key status is `validated`, client opens Soniox WebSocket directly and starts dictation.
3. If key status is `missing|unverified|invalid`, compose renders inline key prompt (same UI model as Settings row).
4. Inline CTA opens Soniox key signup/manage page if key is empty; with key present, CTA is `Verify`.
5. Inline `Verify` performs real Soniox validation (client-direct); result shows `Invalid` or `Validated`.
6. On inline verify success (`Validated`), flow immediately continues into dictation mode without requiring a second activation gesture.
7. Active dictation streams PCM audio and partial/final tokens into compose text.
8. Client exits dictation (release/swipe-right/send/cancel), finalizes stream, and keeps/discards text per mode.

## Soniox Protocol Contract

### Endpoint and transport
- REST API base: `https://api.soniox.com`
- WebSocket host: `wss://stt-rt.soniox.com`
- WebSocket URL used by client: `wss://stt-rt.soniox.com/transcribe-websocket`
- TLS required (`wss` only).
- ATS remains enabled.

### Authentication
- Auth is in first config payload as `api_key`.
- In client-direct mode, the app can call Soniox's Create Temporary API Key endpoint directly (usage_type: "transcribe_websocket") and then use that returned temporary key as api_key for WebSocket connect.
- No provider hop and no provider endpoint dependency.

### Initial config message
```json
{
  "api_key": "<configured-soniox-key>",
  "model": "stt-rt-preview",
  "audio_format": "s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["en"],
  "enable_endpoint_detection": true,
  "client_reference_id": "<uuid>"
}
```

`client_reference_id` is for client-side diagnostics and run correlation.

### Audio frames
- Binary frames, PCM16LE mono 16kHz.
- Target frame size: 20ms (640 bytes), tolerance up to 100ms.

### Stop/finalize/cancel
- `stop_keep`:
1. Send `{"type":"finalize"}`.
2. Stop microphone capture.
3. Send empty frame (`""`) end-of-audio marker.
4. Wait for `finished=true` up to 1200ms; if absent, stop anyway.
- `stop_discard`:
1. Stop microphone immediately.
2. Close socket (`1000`, `client_cancelled`).
3. Do not wait for additional tokens.

### Response schema
Expected fields:
```json
{
  "text": "hello world",
  "tokens": [
    {
      "text": "hello ",
      "start_ms": 0,
      "end_ms": 450,
      "confidence": 0.98,
      "is_final": true
    }
  ],
  "final_audio_proc_ms": 450,
  "total_audio_proc_ms": 820,
  "finished": false,
  "error_code": null,
  "error_message": null
}
```

Parser rules:
- `tokens` are authoritative for each response.
- Ignore sentinel tokens `text == "<end>"` and `text == "<fin>"` for compose assembly. These are Soniox control markers (endpoint detection and manual finalization respectively) and must never appear in rendered transcript text.
- `error_code` or `error_message` ends dictation session.

## Audio Capture and Session Settings

### Required audio format
- `audio_format = "s16le"`
- `sample_rate = 16000`
- `num_channels = 1`
- 16-bit signed PCM little-endian

### AVAudioEngine conversion
- Capture from `AVAudioInputNode`.
- Convert with `AVAudioConverter` to 16k mono PCM16LE.
- Emit deterministic 20ms frames.

### AVAudioSession
- Category: `.playAndRecord`
- Mode: `.measurement`
- Options: `[.allowBluetooth, .defaultToSpeaker]`

### AVAudioSession interruption handling
- Observe `AVAudioSession.interruptionNotification`, `routeChangeNotification`, and `mediaServicesWereResetNotification`.
- On interruption-began: pause capture, notify coordinator of transport health degradation. Do not close socket (keepalive maintains connection).
- On interruption-ended (with `.shouldResume`): resume capture and audio engine.
- On route change (e.g., headphones unplugged): reconfigure audio engine input and resume capture if dictation is active.
- On media services reset: tear down and recreate audio engine; stop dictation gracefully if recreation fails.

## Transcript Reconciliation

State:
- `finalTokens: [Token]` append-only
- `nonFinalTokens: [Token]` replaced each response

Algorithm:
1. Partition response tokens into final/non-final; exclude sentinel tokens (`text == "<end>"` or `text == "<fin>"`).
2. Append final tokens to `finalTokens`.
3. Replace `nonFinalTokens` with current non-final tokens.
4. Render compose: `concat(finalTokens.text) + concat(nonFinalTokens.text)`.
5. On `finished=true`, clear `nonFinalTokens`, keep `finalTokens`.

## UX State Machine

### States
- `idle_mic_visible`
- `idle_mic_hidden`
- `key_prompt_inline`
- `key_verifying_inline`
- `dictating_sticky`
- `dictating_walkie_talkie`
- `stopping_keep`
- `stopping_discard`
- `error`

### Transitions
1. `idle_mic_visible -> idle_mic_hidden`: focus gained.
2. `idle_mic_hidden -> idle_mic_visible`: focus lost and compose empty.
3. `idle_mic_visible|idle_mic_hidden -> dictating_sticky`: dictation activation resolves to sticky and key status is `validated`.
4. `idle_mic_visible|idle_mic_hidden -> dictating_walkie_talkie`: dictation activation resolves to walkie-talkie and key status is `validated`.
5. `idle_mic_visible|idle_mic_hidden -> key_prompt_inline`: user attempts dictation and key status is `missing|unverified|invalid`.
6. `key_prompt_inline -> key_prompt_inline`: inline CTA tapped with empty key; open Soniox key signup/manage page.
7. `key_prompt_inline -> key_verifying_inline`: user taps `Verify` with non-empty key.
8. `key_verifying_inline -> key_prompt_inline`: verification returns failure (`Invalid` shown inline).
9. `key_verifying_inline -> dictating_sticky|dictating_walkie_talkie`: verification returns success (`Validated` shown inline), then immediately enter pending requested dictation mode.
10. `dictating_walkie_talkie -> stopping_keep`: hold release.
11. `dictating_sticky -> stopping_keep`: swipe-right OR VoiceOver `Stop Dictation` OR `Esc`.
12. `dictating_sticky|dictating_walkie_talkie -> stopping_keep`: send tapped.
13. `dictating_sticky|dictating_walkie_talkie -> stopping_discard`: VoiceOver `Cancel and Discard Dictation` OR long-press `Esc`.
14. `dictating_sticky|dictating_walkie_talkie -> stopping_keep`: socket drops/disconnects (no reconnect attempt).
15. `dictating_sticky|dictating_walkie_talkie -> stopping_keep`: token inactivity timeout (3 minutes with no Soniox tokens).
16. `stopping_keep -> error`: unexpected stop/finalize failure.
17. `stopping_keep -> idle_mic_hidden`: stop complete and (focused or compose non-empty).
18. `stopping_keep -> idle_mic_visible`: stop complete and unfocused and compose empty.
19. `stopping_discard -> idle_mic_hidden|idle_mic_visible`: discard complete.
20. `error -> idle_mic_hidden|idle_mic_visible`: explicit dismiss or auto-dismiss.

No-reconnect rationale:
- Reconnect increases transcript-boundary complexity and can duplicate/drop words.
- Deterministic behavior: stop session on drop; user reactivates with swipe/tap.

## Gesture Mechanics and Conflict Resolution

### Swipe target
- Swipe recognizer attaches to compose-field superview (not `UITextView`) over full field bounds.

### Thresholds
- Horizontal displacement: `>= 28pt`
- Horizontal dominance: `abs(dx) >= 1.4 * abs(dy)`
- Hold threshold for walkie-talkie: `>= 350ms`
- Thresholds are initial tuning values and require UX calibration with Flynn before implementation lock.

### Disambiguation
- If selection handles/loupe are active, dictation swipe recognizer disabled.
- Long-press (>300ms) before horizontal threshold routes to text editing.
- Vertical drag dominance routes to normal text scrolling/selection.

## Send, Cancel, and Stream Switching

### Send while dictating
1. Enter `stopping_keep`.
2. Trigger graceful finalize.
3. Wait up to 500ms for final Soniox response.
4. Send resulting compose text.
5. On timeout/error, send current visible compose text.

### Cancel/discard
- Default stop keeps text.
- `stopping_discard` restores pre-dictation snapshot.
- Snapshot captured when activation gesture resolves to dictation mode (before network/audio start).

### Stream switching
- Dictation binds to one session key.
- If active stream/session key changes during dictation:
  - force `stopping_keep`
  - keep dictated text only in origin draft
  - never migrate text to destination stream

## Accessibility

### VoiceOver actions
- `Start Sticky Dictation`
- `Start Walkie-Talkie Dictation`
- `Stop Dictation`
- `Cancel and Discard Dictation`

### Announcements
- `Dictation started`
- `Dictation stopped`
- `Dictation failed`

### Gesture alternatives
- All swipe actions have VoiceOver/hardware-key alternatives.

### Visual and motion
- Border squiggle is not color-only.
- Under `Reduce Motion`, use alpha pulse (1.0Hz, alpha range 0.65 to 1.0, no positional jitter).
- Border/icon states maintain WCAG contrast.

### Error timing accessibility
- Error auto-dismiss: 4 seconds normally.
- Error auto-dismiss: 8 seconds when VoiceOver is active.

## Security and Privacy

### Key handling
- `soniox.apiKey` is client configuration.
- If absent, dictation affordance still renders; dictation attempt routes to inline key prompt/CTA flow.
- Key must not be hardcoded in source control or included in UI logs/analytics.

### Transport
- Soniox connection is `wss` only.
- ATS/certificate validation remains enabled.

### WebSocket keepalive
- Client must send `{"type": "keepalive"}` messages periodically while the socket is open.
- Cadence: every 5 seconds.
- Keepalive keeps the server-side session alive during audio capture gaps (interruptions, route changes, silence).
- Stop sending keepalive on finalize or socket close.
- Missing keepalive during audio gaps is a known cause of premature server-side disconnection (`input_too_slow`).

### Data handling
- No raw audio persistence by client.
- Transcript remains in compose draft scope.
- Telemetry excludes transcript text and raw audio payload bytes.

## Operational Constraints
- Max dictation session duration: 10 minutes.
- Token inactivity timeout: 3 minutes with no Soniox tokens, regardless of audio level.
- App backgrounding behavior: stop dictation immediately with `stop_keep`.
- Language hints selection:
  - send one language hint in `language_hints[0]`
  - derive from active keyboard primary language
  - fallback to iOS preferred language[0], then `en`
- Haptics:
  - start: light impact on entry to active dictation
  - stop: success notification on transition to idle from `stopping_keep`
  - error: error notification on transition to `error`

### Model lifecycle note
- Default model is `stt-rt-preview`.
- If Soniox deprecates/renames this model, fallback model selection must be updated in config before rollout.

## Analytics Hooks
- `dictation_start` (mode, sessionKeyHash)
- `dictation_stop` (reason, durationMs)
- `dictation_error` (errorCode, stage)
- `dictation_send_while_active` (finalizedWithinTimeout)
- `dictation_socket_drop` (mode, elapsedMs)

No analytics event includes transcript text or raw audio.

`sessionKeyHash`:
- `SHA-256(sessionKey + appSalt)`, 64-char hex.
- `appSalt` is app-install-scoped random salt generated on first launch and stored in Keychain.

## Testability
- Provide Soniox mock WebSocket fixture harness for CI.
- Fixture supports event ordering, delays, disconnect injection, error injection.
- Assertions cover transcript assembly, socket-drop stop behavior, inactivity timeout, send timeout path, discard snapshot restore.
- CI does not require live Soniox credentials.

## Acceptance Checks
1. Settings includes Soniox key input with companion CTA in the same control row.
2. Settings CTA opens Soniox key signup/manage page when key is empty.
3. Settings CTA label/action switches to `Verify` when key is present.
4. `Verify` performs real Soniox validation (client-direct) and renders inline status text `Invalid` or `Validated`.
5. Dictation affordance remains visible under normal mic visibility rules even when key is missing/unverified/invalid.
6. Attempting dictation without a verified key shows compose-inline key prompt using the same UI model as Settings.
7. Compose-inline prompt uses same CTA semantics: empty key opens Soniox signup/manage page, present key runs `Verify`.
8. Successful inline verify immediately enters requested dictation mode (sticky or walkie-talkie) without a second gesture.
9. Architecture remains client-direct Soniox connection with no provider endpoint dependence.
10. WebSocket endpoint is `wss://stt-rt.soniox.com/transcribe-websocket` and audio stream is mono 16kHz PCM16LE.
11. Token assembly uses append-final/replace-nonfinal with `<end>` and `<fin>` sentinel filtering. Neither marker appears in rendered transcript text.
12. Socket drop stops dictation (no reconnect state/machinery).
13. Token inactivity timeout is 3 minutes without Soniox tokens.
14. Send-while-dictating uses 500ms finalize window.
15. Stream switching stops dictation and preserves origin draft only.
16. VoiceOver users can start/stop/discard without swipe gestures.
17. Border waveform follows audio-reactive mapping and keeps low-motion active-state fallback.
18. WebSocket keepalive (`{"type": "keepalive"}`) is sent every 5 seconds while socket is open; stopped on finalize/close.
19. AVAudioSession interruption/route-change/media-reset notifications are observed and handled without crashing or leaving socket orphaned.
20. Soniox `error_code` is parsed robustly (numeric or string) so server-side close reasons (e.g., `input_too_slow`) surface in analytics and error state.

## References
- WebSocket API: https://soniox.com/docs/stt/api-reference/websocket-api
- Real-time transcription: https://soniox.com/docs/stt/rt/real-time-transcription
- Manual finalization: https://soniox.com/docs/stt/rt/manual-finalization
- Connection keepalive: https://soniox.com/docs/stt/rt/connection-keepalive
- Temporary API keys: https://soniox.com/docs/stt/api-reference/auth/create_temporary_api_key
- Endpoint detection: https://soniox.com/docs/stt/rt/endpoint-detection

## Implementation Handoff
- Scope boundary: no UX redesign beyond finalized T027 model.
- Architecture boundary: client-direct Soniox with client-configured key.
- Any future provider-side key service or transport change requires spec update first.
