# Surf Ace Electron Test Suite — Adversarial Feedback

Target reviewed: `/Users/mike/shared-workspace/clawline/specs/surf-ace-electron-test-suite.md`
Spec source: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`

## Blocking Disagreements (tests that are wrong scope, contradictory, or not reliably testable)

1. `PAIR-E-12` is testing provider behavior, not Electron screen behavior.
- Test location: `surf-ace-electron-test-suite.md:763`
- Why this is wrong: TLS pin verification and trust-store state transitions are provider responsibilities (`surf-ace.md:261-269`, `1129-1137`, `1145-1149`), not screen API behavior.
- Fix: Move this to provider integration tests. Keep Electron suite focused on screen responses and local side effects.

2. `EDGE-E-13` and `EDGE-E-14` are provider/discovery-table assertions, not Electron implementation assertions.
- Test locations: `.../surf-ace-electron-test-suite.md:977`, `987`
- Why this is wrong: Distinguishing same-name screens by fingerprint and handling trust mismatch after reset are provider table/trust-store behaviors (`surf-ace.md:206-220`, `268-269`, `1145-1149`).
- Fix: Move these to provider discovery/pairing tests; Electron suite should only assert `pk` publication and key rotation effects locally.

3. `SESS-E-02` contradicts `SESS-E-08` and encodes ambiguous session-end semantics.
- Test locations: `.../surf-ace-electron-test-suite.md:785`, `845`
- Why this is wrong: `SESS-E-02` says explicit clear can end session to Standby, but `SESS-E-08` says `DELETE /frame` leaves session active/connected-idle. These are mutually inconsistent.
- Spec conflict source: `surf-ace.md:156` and `149-173` vs `422-433` and `1276-1283`.
- Fix: Split into two explicit cases:
  - `DELETE /frame` => connected-idle, token still valid.
  - actual session end trigger (quit/power-cycle/unreachable policy) => standby + token invalid.

4. TTL tests are hard-coded against a spec that contradicts itself.
- Test locations: `.../surf-ace-electron-test-suite.md:805`, `815`
- Why this is wrong: Spec says both “no TTL” (`surf-ace.md:149`) and “5-minute TTL” (`1043`, `1067`, `1100-1104`, `1141`).
- Fix: Mark these as `SPEC-AMBIGUITY` gated tests until the spec is reconciled. Do not fail implementation solely on one side of contradictory spec text.

5. `PENCIL-E-10` title and expected result are internally contradictory.
- Test location: `.../surf-ace-electron-test-suite.md:631`
- Why this is wrong: Title says “fires once during 30s,” expected says “approximately once per 3–5s interval.” Those are incompatible assertions.
- Fix: Decide one requirement. If spec intent is periodic long-debounce during continuous draw, rewrite title and acceptance to match periodic behavior.

6. `PENCIL-E-11` is white-box and untestable as written for black-box conformance.
- Test location: `.../surf-ace-electron-test-suite.md:641`
- Why this is wrong: It requires internal change-stack inspection “via test hook or observable state,” but the spec does not define such hook for Electron testability.
- Fix: Either (a) define required test instrumentation in the spec, or (b) rewrite as black-box behavior (e.g., undo behavior if/when API exists).

7. `RENDER-E-04/05/06` overconstrain implementation internals instead of contract behavior.
- Test locations: `.../surf-ace-electron-test-suite.md:447`, `457`, `467`
- Why this is wrong: “via pdf.js/xterm.js/marked” is an implementation choice from platform mapping (`surf-ace.md:1080-1086`), not directly observable contract behavior.
- Fix: Keep behavior assertions (`visibleText`, rendering correctness, contentType) and avoid failing based on library identity unless instrumentation to prove library selection is explicitly required.

8. `EDGE-E-18` assumes `events` is required, but spec only shows it in example payload.
- Test location: `.../surf-ace-electron-test-suite.md:1027`
- Why this is weak: §9.2 provides example request (`surf-ace.md:499-515`) and §17.7 says “watch config JSON” without strict required-field schema (`1284-1289`).
- Fix: Mark as clarification-needed, or rewrite with explicit spec requirement first.

9. `DISC-E-01` “exactly one record” is fragile and environment-coupled.
- Test location: `.../surf-ace-electron-test-suite.md:11`
- Why this is bad: On shared LANs there may be multiple `_surf-ace._tcp` instances; “exactly one” is not a product contract.
- Fix: Assert that this instance is present and correctly formed; do not assert network-global uniqueness.

## Important Quality Problems (tests are too loose or duplicated)

1. Status assertions are too permissive and reduce signal.
- Affected: `HTTP-E-02`, `HTTP-E-10`, `EDGE-E-04`, `EDGE-E-05`, `EDGE-E-15` (`...:143`, `223`, `887`, `897`, `997`).
- Issue: allowing `401 or 403`, `400 or 422` everywhere hides regressions.
- Fix: choose one canonical status per failure mode from API contract; if truly unspecified, tag explicitly as “spec-open” instead of broad OR assertions.

2. Redundant auth coverage.
- Affected: `HTTP-E-02` and `EDGE-E-15`.
- Issue: both test missing auth on protected endpoints with near-identical expectation.
- Fix: consolidate or repurpose one to malformed auth header coverage.

## Missing Tests (high-value gaps)

1. Pairing nonce binding failure.
- Add test: correct PIN with wrong nonce must fail.
- Why: Spec defines `pin_hash = SHA-256(pin + nonce)` (`surf-ace.md:305`), but suite never verifies nonce mismatch rejection.

2. PIN challenge rotation invalidates previous challenge.
- Add test: after 60s rotation, submitting old PIN+old nonce should fail even if PIN was once correct (`surf-ace.md:304`).

3. Malformed Authorization header variants.
- Add tests for:
  - `Authorization: Bearer` (no token)
  - wrong scheme (e.g., `Basic ...`)
  - extra whitespace/empty token
- Why: current suite only checks missing header, not malformed header handling.

4. Live update error callback payload schema.
- Add test for `/frame/append` and `/frame/patch` render failures in watch mode verifying callback payload fields (`event`, `code`, `message`, `frameId`, `timestamp`) per §6.7 intent (`surf-ace.md:177-199`).
- Why: `EDGE-E-19` checks only “an error event happened,” not envelope correctness.

5. `/frame/patch` invalid action handling.
- Add test: unknown action (e.g., `"action":"explode"`) returns `422` with structured error.
- Why: spec enumerates valid actions (`surf-ace.md:406`), but suite does not test invalid action rejection.

6. `/frame/append` payload shape validation.
- Add tests: missing `append.lines`, non-array lines, non-string line values.
- Why: current suite checks stale id/type gating but not request-shape contract robustness.

7. mDNS busy propagation timing bound.
- Add test: after pair/clear/session-end, `busy` TXT transitions within a bounded time window.
- Why: spec requires real-time busy updates (`surf-ace.md:108`) but current tests don’t enforce any latency envelope.

## Recommended Test Suite Refactor

1. Split suites by ownership:
- `surf-ace-electron-test-suite.md`: screen-only behavior.
- provider suite: trust store, TLS pin verification, discovery disambiguation, reconnect policy.

2. Add a `SPEC-AMBIGUOUS` tag for tests blocked by contradictory spec text (especially session TTL).

3. For every integration test, separate:
- externally observable contract assertions (required)
- optional implementation-specific checks (non-blocking)

Without these corrections, this suite will generate both false positives (failing valid implementations) and false negatives (passing broken behavior behind permissive assertions).
