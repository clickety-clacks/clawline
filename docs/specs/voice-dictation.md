# Voice Dictation via Soniox Streaming STT

## Goal
Add voice dictation to Clawline compose input using Soniox real-time WebSocket STT, implementing finalized T027 UX:
- Mic icon inside text field.
- Tap/hold/push-up activation modes.
- Waveform in the dictation surface as the only state indicator.
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

### Mic icon visibility
- Mic icon remains in the text field at rest.
- Mic icon hides whenever dictation surface is open.
- Mic icon reappears when dictation surface is closed.
- Visibility is driven only by dictation-surface open/closed state.

## Final UX Contract

This revision is a clean break from legacy dictation UX mechanics; legacy state indicators and mic-motion behaviors are fully superseded by this contract.

### Activation and exit

**Push-up-to-reveal (primary activation):**
- Push input bar up and release -> reveals dictation surface underneath, enters sticky mode.
- Push input bar up and hold (don't release) -> walkie-talkie mode. Listens while held. Release stops listening and collapses dictation surface back down.
- Gesture recognition uses velocity OR displacement:
  - Fast upward flick can commit reveal with smaller travel.
  - Slow drag must cross displacement threshold.
  - Physics and threshold family mirror iOS sheet-dismiss interaction patterns (final tuning on-device).

**Inline mic icon:**
- Tap mic icon in text field -> auto-plays the same push-up reveal animation, then enters sticky mode.

**Walkie-talkie from paused state:**
- If dictation surface is already open but waveform is paused/not listening, hold down on waveform -> walkie-talkie mode. Release stops listening (surface stays open, returns to paused state).

**Tap waveform:**
- Tap waveform -> toggle pause/resume (sticky mode continues).

**Paused state contract:**
- Paused state dims waveform bars and shows `Paused` placeholder in the waveform region.
- On pause, close Soniox connection.
- On resume, open a new Soniox connection via pre-warm path and resume streaming.

**Dismiss:**
- Swipe input bar back down -> dismiss dictation, close Soniox connection immediately.
- Dismiss gesture is symmetric with reveal: flick-down or drag-down following finger with reverse physics.

**Keyboard/focus behavior during active dictation:**
- Text field stays editable while dictation continues listening.
- Tapping into the text field does not pause dictation.

**Send during dictation:**
- Send button sends the current message. Dictation stays open — user continues dictating into the next message seamlessly.

**Chat orthogonality:**
- Incoming and outgoing chat messages continue updating underneath the dictation surface.
- Chat timeline updates do not alter dictation surface state.

Sticky-mode controls:
- swipe bar down (dismiss)
- tap waveform (pause)
- hardware keyboard `Esc`
- send action (sends message, dictation continues)

### State indicator and waveform
- Waveform in the dictation surface is the only dictation state indicator.
- Waveform is audio-reactive vertical bars in the dictation surface.
- Audio-reactive parameters:
  - update cadence: 20Hz (every 50ms)
  - input metric: RMS amplitude of captured PCM window
  - bar-height mapping: RMS low/high mapped to design-system min/max bar heights
  - no speech yet while mic is active: show `Listening...` placeholder in waveform area
  - paused state: show `Paused` placeholder in waveform area

### Live transcription
- No batching.
- Soniox partial/final tokens stream directly into compose text.
- After dictation ends, text remains editable/sendable.
- User edits are always authoritative:
  - If user deletes text during dictation, transcript updates never reinsert deleted text.
  - If user has a selection, next dictated text replaces that selection.
  - If user moves cursor, dictated text inserts at cursor position.

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

### Pre-warm strategy

Dictation startup is split into three phases to minimize perceived latency. The user's gesture travel time (200–400ms) absorbs most of the startup cost.

**Phase 1 — Always ready (chat view lifecycle):**
- Pre-create `SonioxStreamingClient`, `DictationAudioCapture`, converter format objects, async consumer queues.
- Resolve language hint and build initial Soniox config payload.
- Pre-configure `AVAudioEngine` graph: create nodes, install tap, call `prepare()`. Do NOT call `engine.start()`.
- No network connections. No audio session activation. No billing. No privacy implications.

**Phase 2 — Gesture begin (touch-down on input bar or mic icon):**
- Open Soniox WebSocket connection and send initial config message.
- Activate `AVAudioSession` (`.playAndRecord`, `.measurement`).
- Call `engine.start()`.
- If gesture is abandoned (finger lifts before push-up commit threshold), tear down: close socket, deactivate audio session, stop engine.
- Push-up commit threshold (velocity OR displacement):
  - displacement path: upward displacement from touch-down crosses `D_up_commit` (`up = max(0, -dy)`).
  - velocity path: upward release velocity crosses `V_up_commit` before reaching `D_up_commit`.
  - horizontal exclusion applies to displacement path: `up >= 1.4 * abs(dx)`.
  - `D_up_commit` and `V_up_commit` are tuned on device.
- Phase 2 abandonment threshold:
  - Touch ends before meeting velocity/displacement commit.
  - Or touch path becomes horizontally dominated before commit (`abs(dx) > up`).

**Phase 3 — Gesture complete (dictation surface revealed):**
- Begin sending audio frames to the already-open WebSocket.
- If WebSocket is not yet connected (slow network), buffer audio frames in memory and flush them as soon as the connection opens. No words are lost.
- If connection fails during buffer window, enter error state.

**No persistent warm connections.** Do not hold a Soniox WebSocket open during normal chat usage. Soniox bills for stream duration including idle time held open by keepalive. Pre-warm connections are only opened on explicit gesture intent.

### High-level flow (client-direct)
1. User invokes dictation affordance (push-up/tap/hold), regardless of current key state.
2. If key status is `validated`, Phase 2 pre-warm fires on gesture begin; Phase 3 starts audio on gesture complete.
3. If key status is `missing|unverified|invalid`, compose renders inline key prompt (same UI model as Settings row).
4. Inline CTA opens Soniox key signup/manage page if key is empty; with key present, CTA is `Verify`.
5. Inline `Verify` performs real Soniox validation (client-direct); result shows `Invalid` or `Validated`.
6. On inline verify success (`Validated`), flow immediately continues into dictation mode without requiring a second activation gesture.
7. Active dictation streams PCM audio and partial/final tokens into compose text.
8. Client exits dictation on swipe-down/cancel/background/drop, finalizes stream when required by stop mode, and keeps/discards text per mode.
9. Send while dictating does not exit dictation; it sends the current message and continues in the current dictation mode.
10. On inactivity timeout or max duration timeout, Soniox connection closes and dictation surface remains open in paused state.

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
- On interruption-began: pause capture, notify coordinator of transport health degradation, and close active Soniox connection.
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
- `idle_surface_closed`
- `key_prompt_inline`
- `key_verifying_inline`
- `dictating_sticky`
- `dictating_paused`
- `dictating_walkie_talkie`
- `stopping_keep`
- `stopping_discard`
- `error`

### Transitions
1. `idle_surface_closed -> dictating_sticky`: dictation activation resolves to sticky and key status is `validated`.
2. `idle_surface_closed -> dictating_walkie_talkie`: dictation activation resolves to walkie-talkie and key status is `validated`.
3. `idle_surface_closed -> key_prompt_inline`: user attempts dictation and key status is `missing|unverified|invalid`.
4. `key_prompt_inline -> key_prompt_inline`: inline CTA tapped with empty key; open Soniox key signup/manage page.
5. `key_prompt_inline -> key_verifying_inline`: user taps `Verify` with non-empty key.
6. `key_verifying_inline -> key_prompt_inline`: verification returns failure (`Invalid` shown inline).
7. `key_verifying_inline -> dictating_sticky|dictating_walkie_talkie`: verification returns success (`Validated` shown inline), then immediately enter pending requested dictation mode.
8. `dictating_walkie_talkie -> stopping_keep`: hold release when walkie originated from push-up hold on closed surface.
9. `dictating_sticky -> dictating_paused`: waveform tap.
10. `dictating_paused -> dictating_sticky`: waveform tap (opens new Soniox connection).
11. `dictating_paused -> dictating_walkie_talkie`: waveform hold begin (`>= 350ms`).
12. `dictating_walkie_talkie -> dictating_paused`: hold release when walkie originated from paused waveform.
13. `dictating_sticky|dictating_paused -> stopping_keep`: swipe-down OR `Esc`.
14. `dictating_sticky|dictating_paused|dictating_walkie_talkie -> same state`: send tapped (send current draft, clear compose text, continue dictation in current mode).
15. `dictating_sticky|dictating_paused|dictating_walkie_talkie -> stopping_discard`: long-press `Esc`.
16. `dictating_sticky|dictating_walkie_talkie -> dictating_paused`: inactivity timeout (`15s`) or max listening timeout (`60s`) closes Soniox and leaves surface open paused.
17. `dictating_sticky|dictating_paused|dictating_walkie_talkie -> dictating_paused`: socket drop/disconnect.
18. `stopping_keep -> error`: unexpected stop/finalize failure.
19. `stopping_keep|stopping_discard -> idle_surface_closed`: stop complete.
20. `error -> same visible state`: error text shown below waveform in design-system red until next user action changes state.
21. Only user action collapses dictation surface. No programmatic path may collapse it.

No-reconnect rationale:
- No implicit reconnect loop after socket drop/timeout.
- Deterministic behavior: move to paused surface-open state and require explicit user resume (waveform tap/hold), which opens a new Soniox connection.

## Gesture Mechanics and Conflict Resolution

### Push-up target
- Push-up recognizer attaches to compose input bar container (not `UITextView`) over the full input-bar bounds.
- Gesture start must begin inside input-bar bounds. Touches beginning in chat transcript content are never eligible for push-up activation.

### Thresholds
- Velocity-or-displacement commit:
  - `up >= D_up_commit` OR upward release velocity `vy <= -V_up_commit`
- Vertical dominance (horizontal exclusion on displacement path): `up >= 1.4 * abs(dx)`
- Hold threshold for walkie-talkie: `>= 350ms`
- Phase 2 pre-warm abandonment: if touch ends before push-up commit, or if gesture becomes horizontally dominated before commit, treat as abandoned and immediately run Phase 2 teardown.
- `D_up_commit` and `V_up_commit` are tuned on device and must be shared across iPhone, iPad, and VisionPro gesture adapters.

### Disambiguation
- Push-up activation only competes with interactions that begin in the input bar; chat scroll view wins all touches that begin outside input-bar bounds.
- If selection handles/loupe are active in the text field, push-up recognizer is disabled.
- Long-press priority overlap:
  - In text field editing region: text editing long-press (`300ms`) wins unless push-up commit is reached first.
  - On paused waveform surface: dictation hold (`350ms`) wins and suppresses text-editing long-press.
- If push-up commit is not reached, route gesture to normal text editing/scrolling behavior.
- Chat content interactions remain orthogonal: incoming/outgoing chat updates continue underneath dictation surface with no gesture coupling.

### Active-gesture connection failure
- If Soniox WebSocket connect fails during Phase 2 while finger is still down, activation is cancelled immediately.
- Dictation surface does not open for that gesture.
- System transitions to `error`, emits error notification haptic, and renders error text below waveform in design-system red.
- User may start a new gesture immediately; failure from the previous gesture must not block new attempts.

## Send, Cancel, and Stream Switching

### Send while dictating
1. Send current visible compose text immediately.
2. On successful send, clear compose text.
3. Keep dictation session active in current mode (`dictating_sticky`, `dictating_paused`, or `dictating_walkie_talkie`).
4. Do not finalize or restart Soniox stream for send action.
5. If send fails, keep compose text unchanged and keep dictation in current mode.

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

### Activation race guard
- Dictation activation/deactivation is serialized by a coordinator gate with a monotonically increasing `activationGeneration`.
- Any async Phase 2 teardown/connect callback whose generation is not current is ignored.
- If user begins a new activation while previous teardown is still running, queue one pending activation intent and execute it immediately after teardown settles.
- A newer activation intent replaces any older queued intent.

## Reduce Motion
- Under `Reduce Motion`, use alpha pulse (1.0Hz, alpha range 0.65 to 1.0, no positional jitter).
- Dictation-surface reveal/dismiss still follows finger and symmetric physics; motion reduction only simplifies secondary waveform animation.

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
- Keepalive is active only while a Soniox socket is open.
- Paused state has no open Soniox connection; no keepalive is sent while paused.
- Stop sending keepalive on finalize or socket close.
- Missing keepalive during audio gaps is a known cause of premature server-side disconnection (`input_too_slow`).

### Data handling
- No raw audio persistence by client.
- Transcript remains in compose draft scope.
- Telemetry excludes transcript text and raw audio payload bytes.

## Operational Constraints
- Max continuous listening duration: 60 seconds. On expiry, close Soniox and move to paused state with surface still open.
- Inactivity timeout: 15 seconds with no detected speech/tokens while listening. On expiry, close Soniox and move to paused state with surface still open.
- App backgrounding behavior: stop dictation immediately with `stop_keep`.
- Dictation surface collapse ownership:
  - Only explicit user dismiss interaction collapses dictation surface.
  - Errors, timeouts, disconnects, and other programmatic events must not collapse the surface.
- Dictation surface geometry:
  - Inserted directly below the full input bar (plus button, text field, send button, page indicator).
  - Uses fixed height `H_dictation_surface` with design-system compliant horizontal and vertical padding.
  - Pushes chat content upward and updates bottom inset accordingly.
- Platform parity:
  - Same push-up/push-down gesture model on iPhone, iPad, and VisionPro.
  - VisionPro uses gaze-drag events mapped to the same velocity/displacement thresholds and state transitions.
- Language hints selection:
  - send one language hint in `language_hints[0]`
  - derive from active keyboard primary language
  - fallback to iOS preferred language[0], then `en`
- Haptics:
  - push-up crosses reveal threshold: light impact
  - walkie-talkie release (stop listening): soft impact
  - tap waveform to pause: light tap
  - tap waveform to resume: light tap
  - swipe-down dismiss: none
  - send during dictation: none
  - error: error notification haptic

### Phase 1 lifecycle
- Create/refresh Phase 1 pre-warmed objects when chat compose view becomes active.
- Tear down Phase 1 objects when:
  - chat view disappears,
  - app backgrounds,
  - memory warning is received,
  - or 60s elapses with no dictation gesture begin.
- Recreate on next compose-view activation or next dictation intent.

### Model lifecycle note
- Default model is `stt-rt-preview`.
- If Soniox deprecates/renames this model, fallback model selection must be updated in config before rollout.

## Analytics Hooks
- `dictation_start` (mode, sessionKeyHash)
- `dictation_stop` (reason, durationMs)
- `dictation_error` (errorCode, stage)
- `dictation_send_while_active` (mode, sendSuccess)
- `dictation_socket_drop` (mode, elapsedMs)

No analytics event includes transcript text or raw audio.

`sessionKeyHash`:
- `SHA-256(sessionKey + appSalt)`, 64-char hex.
- `appSalt` is app-install-scoped random salt generated on first launch and stored in Keychain.

## Testability
- Provide Soniox mock WebSocket fixture harness for CI.
- Fixture supports event ordering, delays, disconnect injection, error injection.
- Assertions cover transcript assembly, socket-drop stop behavior, inactivity timeout, send-while-active continuity, discard snapshot restore.
- CI does not require live Soniox credentials.

## Acceptance Checks
1. Settings includes Soniox key input with companion CTA in the same control row.
2. Settings CTA opens Soniox key signup/manage page when key is empty.
3. Settings CTA label/action switches to `Verify` when key is present.
4. `Verify` performs real Soniox validation (client-direct) and renders inline status text `Invalid` or `Validated`.
5. Dictation affordance remains available even when key is missing/unverified/invalid; mic visibility is controlled by dictation-surface open/closed state.
6. Attempting dictation without a verified key shows compose-inline key prompt using the same UI model as Settings.
7. Compose-inline prompt uses same CTA semantics: empty key opens Soniox signup/manage page, present key runs `Verify`.
8. Successful inline verify immediately enters requested dictation mode (sticky or walkie-talkie) without a second gesture.
9. Architecture remains client-direct Soniox connection with no provider endpoint dependence.
10. WebSocket endpoint is `wss://stt-rt.soniox.com/transcribe-websocket` and audio stream is mono 16kHz PCM16LE.
11. Token assembly uses append-final/replace-nonfinal with `<end>` and `<fin>` sentinel filtering. Neither marker appears in rendered transcript text.
12. Socket drop stops dictation (no reconnect state/machinery).
13. While listening, inactivity timeout is 15 seconds and max continuous listening timeout is 60 seconds; either timeout closes Soniox and leaves dictation surface open paused.
14. Send-while-dictating sends immediately, clears compose text on success, and does not stop or restart dictation.
15. Stream switching stops dictation and preserves origin draft only.
16. Push-up-and-hold on input bar activates walkie-talkie mode; release stops and collapses.
17. Waveform bars in dictation surface are the sole state indicator, with `Listening...` only for active pre-speech and `Paused` for paused state.
18. WebSocket keepalive (`{"type": "keepalive"}`) is sent every 5 seconds only while Soniox socket is open; paused state sends no keepalive.
19. AVAudioSession interruption/route-change/media-reset notifications are observed and handled without crashing or leaving socket orphaned.
20. Soniox `error_code` is parsed robustly (numeric or string) so server-side close reasons (e.g., `input_too_slow`) surface in analytics and error state.
21. Tapping mic icon auto-plays the push-up reveal animation before entering dictation.
22. Push-up/push-down gesture model and thresholds are shared across iPhone, iPad, and VisionPro (with gaze-drag adapter on VisionPro).
23. Dictation surface uses fixed height below full input bar and pushes chat content upward with bottom inset updates.
24. User edits are authoritative during dictation: deletion is never overwritten, selection is replaced, and insertion follows cursor position.
25. Dictation surface is never collapsed programmatically; only explicit user dismiss collapses it.

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
