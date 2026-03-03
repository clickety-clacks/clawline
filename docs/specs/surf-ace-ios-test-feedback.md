# Surf Ace iOS Test Suite Feedback (Adversarial)

This suite is directionally strong, but it currently mixes spec compliance with platform internals, has scope contamination (provider/spawned flows), and contains contradictory expectations that will produce false failures.

## Blocking Disagreements (Fix Before Using This as a Gate)

1. **SESS-I-03 / SESS-I-04 conflict with SESS-I-08 / SESS-I-12 and with the spec itself.**
- Problem: One set asserts strict 5-minute inactivity expiry; another asserts frame/session can persist indefinitely when provider is unreachable.
- Why bad: This is mutually inconsistent and will make the suite non-deterministic.
- Suggested fix: Split lifecycle into explicit scenarios: foreground active, background-suspended iPhone grace, explicit clear, app quit. Mark TTL behavior as **spec-clarification required** before gating.

2. **SPAWN-I-01..05 are out of scope for an iOS Surf Ace app test suite.**
- Problem: These validate Clawline WebSocket spawn/submission protocol, not the standalone Surf Ace app target.
- Why bad: Wrong system under test. Failures won’t tell you whether Surf Ace app is compliant.
- Suggested fix: Move to a separate `clawline-spawned-surf-ace-integration-suite.md` owned by Clawline/provider integration tests.

3. **EDGE-I-14 is provider-side security, not screen-side behavior.**
- Problem: It tests callback endpoint validation on TARS/provider.
- Why bad: Not testable from iOS app in isolation.
- Suggested fix: Move to provider test suite.

4. **DISC-I-15 (visionOS multiple windows) is not iOS suite scope.**
- Problem: Platform-specific visionOS behavior in an iOS suite.
- Why bad: Pollutes pass/fail for teams not running visionOS targets.
- Suggested fix: Move to a cross-platform matrix suite or visionOS-specific suite.

5. **PENCIL-I-13 expected behavior is wrong vs spec §16.11.**
- Problem: Test expects long debounce callbacks "approximately every 3–5s" during continuous drawing.
- Why bad: Spec says long debounce fires at 3–5s and then again at next idle gap, not periodic continuous cadence.
- Suggested fix: Assert: no short debounce while pencil never lifts; long debounce at first debounce boundary and at next idle boundary.

6. **DISC-I-13 assumes app reinstall clears Keychain.**
- Problem: "only changes if app deleted and reinstalled (Keychain cleared)" is not reliable on iOS.
- Why bad: Keychain often persists across reinstall.
- Suggested fix: Phrase as: key remains stable across restarts; key regeneration requires explicit keychain purge/factory-reset path.

7. **HTTP-I-15 is structurally flaky.**
- Problem: It applies all five patch actions to the same DOM fixture/selector.
- Why bad: `replace_outer`/`remove` can invalidate selector for subsequent actions, causing false failures.
- Suggested fix: Run each action in an isolated subtest with fresh frame fixture.

8. **EDGE-I-12 allows `204` during render, which weakens a spec requirement.**
- Problem: It accepts `200` *or* `204` during active render.
- Why bad: Spec §16.8 says snapshot should return whatever is visible for active frame; permissive `204` can mask regressions.
- Suggested fix: Require `200` with snapshot once a frame has been accepted, allowing partial visible text.

9. **EDGE-I-10 status-code expectation is underspecified and can drift from spec error contract.**
- Problem: Expects `400` for malformed JSON but doesn’t require structured error contract.
- Why bad: Spec error model is explicit (`render_failed`, `content_too_large`, `unsupported_type`, `decode_failed`).
- Suggested fix: Assert error envelope + code (`decode_failed`) rather than broad status-only assertion.

10. **RENDER-I-03/04/05 over-index on implementation internals.**
- Problem: They assert native image view / PDFKit / NSAttributedString implementation details.
- Why bad: This is brittle and not necessary for protocol-level compliance.
- Suggested fix: Keep observable contract checks (rendered output + snapshot + interactions). Put implementation-introspection checks in optional white-box tests.

11. **DISC-I-04 incorrectly anchors viewport TXT to full `UIScreen` dimensions.**
- Problem: On iPad split view/windowed modes, viewport != full screen dimensions.
- Why bad: False failures in valid multi-window/multitasking modes.
- Suggested fix: Compare TXT `w/h` to actual Surf Ace scene viewport bounds in points.

## Untestable / Ambiguous Cases (Need Harness Clarification)

1. **DISC-I-10 / PAIR-I-14 keychain/public-key verification**
- Current text implies black-box access to key material.
- Suggestion: Require a deterministic test hook or fixture-only build mode for identity export; otherwise mark as privileged instrumentation test.

2. **PAIR-I-08 pin_hash verification labeled "Unit" but depends on UI PIN + runtime nonce.**
- Suggestion: Convert to integration test with deterministic RNG/test override for PIN/nonce generation.

3. **CB-I-07 region event trigger lacks a defined UX gesture path in suite.**
- Suggestion: Define exact input method (e.g., rectangular drag gesture on overlay) and expected tolerance bounds.

4. **CB-I-06 tap/long-press point event is too broad.**
- Suggestion: Split into `point-tap` and `point-long-press` tests with explicit gesture synthesis and timing tolerance.

## Tests Missing Critical Coverage

1. **Missing frameId format enforcement test (`fr_[0-9a-f]{8}`).**
- Add: reject malformed `frameId` with `decode_failed`.

2. **Missing `/watch` transport security test for callback URL scheme.**
- Add: reject non-HTTPS callback URLs (spec transport is HTTPS both directions).

3. **Missing `/pair` PIN edge-case tests.**
- Add: nonce mismatch rejection; expired PIN rejection; lockout exact transition semantics on third failure.

4. **Missing append/terminal cap behavior test.**
- Add: append beyond scrollback/10k line constraints and verify deterministic retention behavior.

5. **Missing patch failure signaling test details.**
- Add: selector-not-found and invalid action should return explicit error code/message; if watch mode is active, assert error callback event shape.

6. **Missing callback retry timing precision test.**
- Add: exactly one retry, approximately 1s delay, then drop.

7. **Missing TLS mode test.**
- Add: positive HTTPS handshake + cert fingerprint match; negative plain-HTTP attempt on same endpoint path should fail.

8. **Missing auth header strictness tests.**
- Add: malformed bearer format, wrong scheme, empty token, stale token.

9. **Missing `DELETE /frame` semantic clarification test.**
- Add once spec clarified: either "connected-idle with valid token" vs "session end". Current suite assumes connected-idle; spec text is ambiguous.

## Suggested Suite Restructure

1. **Core iOS Surf Ace app suite:** discovery, pair/session, frame APIs, snapshot/watch, pencil payloads.
2. **Provider integration suite:** callback auth/source validation, spoof rejection, retry handling verification from provider perspective.
3. **Spawned surf ace suite (Clawline-owned):** WebSocket spawn/submitted lifecycle and ephemeral server behavior.
4. **Platform matrix suites:** iOS/iPadOS vs visionOS vs macOS behaviors kept separate to avoid cross-platform false negatives.

## Overall Assessment

Use this suite as a starting point, but do **not** use it as a strict release gate until the contradictory lifecycle expectations and scope leaks are fixed. Right now it will fail compliant implementations for the wrong reasons and miss some true protocol breaks.
