# Surf Ace Test Reconciliation Summary

Reconciler: subagent (Claude)  
Date: 2026-02-26  
Spec source: `surf-ace.md` (last updated 2026-02-25)

---

## Process

Two independent impl agents wrote adversarial feedback against the Electron and iOS test suites. This document records every feedback item, the reconciler's ruling, and the rationale. Final test suites are the agreed test contract.

---

## Electron Feedback — Item-by-Item Rulings

### Blocking Disagreements

**1. PAIR-E-12 — TLS pin verification is provider behavior, not screen behavior**  
Ruling: **ACCEPTED**  
Action: Test removed from Electron suite.  
Rationale: §7.3 explicitly states "provider verifies TLS cert public key matches trusted fingerprint." The screen's obligation is only to present a TLS cert derived from its Ed25519 keypair. Verification logic lives in the provider. The Electron suite correctly tests screens, not providers.

**2. EDGE-E-13 / EDGE-E-14 — Provider/discovery-table assertions**  
Ruling: **PARTIALLY ACCEPTED**  
Action: Provider-side assertions removed. Screen-side obligations preserved as rewritten tests.  
Rationale: "Disambiguating same-name screens by fingerprint" is a provider table behavior (§16.3). "Flagging screen as untrusted after factory reset" is a provider trust-store behavior (§16.6). However, the screen-side requirements — publishing a unique `pk`, and generating a new `pk` after factory reset — are spec obligations that belong in the Electron suite. New tests EDGE-E-13 and EDGE-E-14 are rewritten to validate screen-side behavior only.

**3. SESS-E-02 contradicts SESS-E-08 — DELETE /frame vs. session end**  
Ruling: **ACCEPTED**  
Action: SESS-E-02 rewritten to restrict to TTL expiry and app quit only; DELETE /frame excluded.  
Rationale: §8.5 and §8.6 are clear: DELETE /frame → connected-idle, session remains active. SESS-E-08 (DELETE /frame → connected-idle) is correct. The original SESS-E-02 conflated "explicit clear" with "session end," which was incorrect per spec.

**4. TTL tests contradictory — §6.4 says "no TTL" vs §13.3/§14.2 say "5 minutes"**  
Ruling: **PARTIALLY ACCEPTED — spec reconciled**  
Action: Tests kept; spec note added to SESS-E-04.  
Rationale: The feedback correctly identifies textual inconsistency. Reconciler's reading: §6.4's "no TTL" means content does not expire during active use — no arbitrary renewal requirement. The 5-minute inactivity TTL in §13.3 and §14.2 applies when the provider stops communicating (grace period for reconnection). These are compatible: no timer during active use; inactivity timer when provider goes silent. Tests are valid per the reconciled reading.

**5. PENCIL-E-10 — Title says "fires once," expected says "once per 3–5s interval"**  
Ruling: **ACCEPTED**  
Action: Test rewritten. Title changed to "fires periodically during continuous drawing; short debounce does not fire." Expected updated to match §16.11.  
Rationale: §16.11 says "Long debounce fires once at the 3–5s mark, then again at the next idle gap." During 30s of continuous drawing, long debounce fires at each ~3–5s boundary — periodic, not once. Both the title and expected were wrong. Corrected in PENCIL-E-10.

**6. PENCIL-E-11 — White-box, requires internal test hook**  
Ruling: **PARTIALLY ACCEPTED**  
Action: Test kept; annotated as requiring instrumented test hook.  
Rationale: The change stack is a genuine spec requirement (§13.4, §13.6) that underpins CLU-driven undo. The behavior must be tested. However, the feedback is correct that "via test hook or observable state" is not a spec-defined interface. Test is kept but marked as requiring defined test instrumentation. This is a white-box test by necessity, not a defect in the requirement itself.

**7. RENDER-E-04/05/06 — Overconstrain implementation by asserting library names**  
Ruling: **ACCEPTED**  
Action: Library-name assertions removed from required pass criteria. Tests now validate observable behavior only (visibleText, rendering correctness).  
Rationale: The spec does name xterm.js, pdf.js, and marked (§14.5), but a conformance test suite should validate the protocol contract (what the screen produces), not the implementation choice. If an implementer achieves correct behavior with a different library, the contract is still met.

**8. EDGE-E-18 — `events` field may not be explicitly required per spec**  
Ruling: **REJECTED (test kept)**  
Action: Test kept as EDGE-E-15 (renumbered).  
Rationale: §9.2 shows POST /watch with both `callbackUrl` and `events`. A POST /watch without `events` is semantically meaningless — the screen wouldn't know what to send. The spec design implies `events` is required. While §17.7 doesn't enumerate required fields explicitly, the absence of `events` renders the subscription inoperative, which is a contract violation. Test is valid.

**9. DISC-E-01 — "Exactly one record" is fragile**  
Ruling: **ACCEPTED**  
Action: Test rewritten to assert this instance is present and well-formed, not global uniqueness.  
Rationale: On shared LANs or in environments with multiple Surf Ace instances, "exactly one" is not a product contract. Correct assertion is that this instance appears.

### Quality Problems

**10. Status assertions too permissive (401 or 403, 400 or 422)**  
Ruling: **PARTIALLY ACCEPTED**  
Action: Auth failures pinned to `401 Unauthorized`. Malformed JSON pinned to `400`. Semantic errors (missing required fields, invalid type) pinned to `422`. Where spec doesn't specify, a note is added but test is not broadened.  
Rationale: The feedback is right that "401 or 403" hides regressions. Standard HTTP: 401 = unauthenticated (missing/invalid credential), 403 = authenticated but forbidden. Since endpoints require a Bearer token and no token = unauthenticated, 401 is correct for missing/invalid auth.

**11. Redundant auth coverage — HTTP-E-02 and EDGE-E-15**  
Ruling: **ACCEPTED**  
Action: EDGE-E-15 (missing auth) removed. HTTP-E-02 retained as canonical auth test. New test HTTP-E-02b added for malformed auth header variants (the coverage EDGE-E-15 was supposed to provide but didn't).  
Rationale: Redundant tests reduce signal. Repurposed coverage to malformed auth, which was missing from both.

### Missing Tests (Accepted Additions)

**12. Pairing nonce binding failure (correct PIN, wrong nonce)**  
Ruling: **ADDED** as PAIR-E-12  
Rationale: §7.4 defines pin_hash = SHA-256(pin + nonce). Nonce mismatch must be rejected. This is a real security property that the spec implies.

**13. PIN challenge rotation invalidates previous challenge**  
Ruling: **ADDED** as PAIR-E-13  
Rationale: §7.4 says PIN is valid for 60 seconds and auto-rotates. The old PIN+nonce pair must be invalid after rotation. This is a meaningful security boundary test.

**14. Malformed Authorization header variants**  
Ruling: **ADDED** as HTTP-E-02b  
Rationale: Testing missing header only is insufficient. Common malformed auth patterns (no token after Bearer, wrong scheme, whitespace-only) should be tested.

**15. Live update error event callback payload schema**  
Ruling: **ADDED** as EDGE-E-16 (behavior) and EDGE-E-17 (schema)  
Rationale: §6.7 specifies error shape. EDGE-E-16 in the original only tested that an error event happened; EDGE-E-17 tests the envelope fields.

**16. POST /frame/patch invalid action handling**  
Ruling: **ADDED** as EDGE-E-19  
Rationale: §8.4 enumerates valid patch actions. An unknown action should produce a 422. This is an explicit API contract.

**17. POST /frame/append payload shape validation**  
Ruling: **ADDED** as EDGE-E-20  
Rationale: The append endpoint has a required `append.lines` field (§8.4). Missing or invalid field should produce 422.

**18. mDNS busy propagation timing bound**  
Ruling: **ADDED** as DISC-E-13  
Rationale: §6.1 says "`busy` is updated in real-time as sessions start and end." A timing bound test (within ~1 second) is a reasonable and testable interpretation of "real-time."

---

## iOS Feedback — Item-by-Item Rulings

### Blocking Disagreements

**1. SESS-I-03/04 conflict with SESS-I-08/12 and spec — TTL contradiction**  
Ruling: **PARTIALLY ACCEPTED — spec reconciled**  
Action: SESS-I-02 rewritten to cover TTL/quit only, not DELETE /frame. Spec note added to SESS-I-03.  
Rationale: Same reconciliation as Electron item #4 above. DELETE /frame → connected-idle. 5-minute inactivity TTL applies to provider absence, not to explicit frame operations.

**2. SPAWN-I-01..05 are out of scope for iOS Surf Ace app test suite**  
Ruling: **ACCEPTED**  
Action: All SPAWN-I-xx tests removed from iOS suite.  
Rationale: These tests validate the Clawline app sending `surf ace_spawned` / `surf ace_submitted` messages over its WebSocket. The system under test is the Clawline iOS app, not the Surf Ace app. A failing SPAWN test tells you nothing about Surf Ace compliance. These belong in a Clawline/provider integration suite.

**3. EDGE-I-14 — Provider-side callback security, not screen-side behavior**  
Ruling: **ACCEPTED**  
Action: EDGE-I-14 (watch mode callback security) removed.  
Rationale: §15.6 says "The provider validates that incoming events match an active watch subscription." This is provider behavior on TARS, not iOS app behavior. The iOS app just sends events to the callbackUrl — it has no knowledge of validation logic.

**4. DISC-I-15 — visionOS multiple windows is not iOS suite scope**  
Ruling: **ACCEPTED**  
Action: DISC-I-15 removed from iOS suite.  
Rationale: visionOS is a separate platform with distinct behavioral characteristics. Mixing it into the iOS suite creates cross-platform false negatives. visionOS should have its own platform matrix suite. Removed.

**5. PENCIL-I-13 — Expected behavior incorrect vs spec §16.11**  
Ruling: **ACCEPTED**  
Action: Test rewritten. Expected now states: long debounce fires at first ~3–5s debounce boundary and again at next idle boundary after pencil lifts.  
Rationale: §16.11 says "once at the 3–5s mark, then again at the next idle gap." The original expected said "approximately every 3–5s" during continuous drawing, implying a repeating periodic cadence. The spec describes a boundary-fire model: fires once per idle-gap crossing. Corrected in PENCIL-I-13.

**6. DISC-I-13 — Assumes reinstall clears Keychain**  
Ruling: **ACCEPTED**  
Action: Test rewritten. Expected now states key is stable across restarts; key regeneration requires explicit Keychain purge.  
Rationale: iOS Keychain may persist across app reinstall. Asserting "only changes if deleted and reinstalled" is a false assertion on many devices. The spec requirement is stability across reboots (§6.2). Correct test: key is stable across normal restarts; changes only when Keychain is explicitly purged.

**7. HTTP-I-15 — Structurally flaky; all five patch actions against same DOM fixture**  
Ruling: **ACCEPTED**  
Action: Test rewritten. Each action runs in isolation with a freshly pushed frame.  
Rationale: `replace_outer` and `remove` destroy the selector element, making subsequent actions against the same selector fail. This is a test design flaw, not an implementation flaw. Each action must run in an isolated subtest.

**8. EDGE-I-12 — Allows 204 during render, weakens spec requirement**  
Ruling: **ACCEPTED**  
Action: Test rewritten to require `200` with snapshot once a frame has been accepted.  
Rationale: §16.8 says "screen returns the snapshot of whatever is currently visible (may be partial render)." Once POST /frame returns 200 (frame accepted), GET /snapshot must return 200 with a snapshot. `204` is only valid when no frame is active. Allowing `204` during render masks regressions.

**9. EDGE-I-10 — Malformed JSON status code underspecified**  
Ruling: **PARTIALLY ACCEPTED**  
Action: Test kept; status code pinned to `400 Bad Request` only.  
Rationale: The spec's error model in §6.7 covers content errors (422). Malformed JSON is an HTTP-level error for which `400` is the standard. The feedback is right that the test should not be status-code-agnostic. Pinned to 400.

**10. RENDER-I-03/04/05 — Over-index on implementation internals**  
Ruling: **ACCEPTED**  
Action: Library-name assertions removed from required pass criteria. Tests validate observable behavior only.  
Rationale: Same reasoning as Electron item #7. Protocol compliance is about what the screen produces, not which library produces it.

**11. DISC-I-04 — Viewport TXT anchored to UIScreen instead of scene bounds**  
Ruling: **ACCEPTED**  
Action: Test rewritten. Expected now compares `w/h` to actual Surf Ace scene/window viewport bounds.  
Rationale: On iPad in Split View or Slide Over, the Surf Ace window is not the full screen. The TXT record should reflect the app's rendering viewport, not the physical display dimensions. §6.1 says `w`/`h` are "viewport width/height in points" — viewport is the app's window, not the screen.

### Untestable / Ambiguous Cases

**12. DISC-I-10 / PAIR-I-14 — Keychain access requires instrumentation**  
Ruling: **ACCEPTED**  
Action: Tests kept; annotated as privileged instrumentation tests.  
Rationale: These are valid spec requirements (§6.2, §14.2). They require a test-mode hook to access Keychain material. Annotated accordingly.

**13. PAIR-I-08 — pin_hash labeled Unit but depends on runtime state**  
Ruling: **ACCEPTED**  
Action: Test reclassified as Integration with test harness override for deterministic PIN/nonce.  
Rationale: The test can be made reliable with a test-mode RNG override. It's a valid spec requirement (§7.4) worth testing.

**14. CB-I-07 — region event lacks defined UX gesture path**  
Ruling: **ACCEPTED**  
Action: Test updated with explicit gesture description (touch-and-hold, then drag to form rectangle).  
Rationale: Without a defined gesture, the test is ambiguous. Added gesture spec to the test setup.

**15. CB-I-06 — tap/long-press too broad**  
Ruling: **PARTIALLY ACCEPTED**  
Action: Test split into actions (a) and (b) within one test for clarity, rather than separate tests.  
Rationale: Both tap and long-press should produce `point` events per §9.3. Splitting into two clearly labeled actions within one test provides clarity without unnecessary proliferation.

### Missing Tests (Accepted Additions)

**16. Nonce mismatch rejection**  
Ruling: **ADDED** as PAIR-I-15  
Same rationale as Electron item #12.

**17. Expired PIN rejection**  
Ruling: **ADDED** as PAIR-I-16  
Same rationale as Electron item #13.

**18. Malformed Authorization header variants**  
Ruling: **ADDED** as HTTP-I-02b  
Same rationale as Electron item #14.

**19. mDNS busy timing bound**  
Ruling: **ADDED** as DISC-I-15  
Same rationale as Electron item #18.

**20. TLS enforcement test (plain HTTP rejected)**  
Ruling: **ADDED** as EDGE-I-21  
Rationale: §15.2 says all Surf Ace API requests use HTTPS. The spec requires TLS — a test that plain HTTP is rejected validates this. The feedback correctly identified this gap.

**21. POST /frame/patch invalid action handling**  
Ruling: **ADDED** as EDGE-I-20  
Same rationale as Electron item #16.

**22. POST /frame/append missing/invalid lines field**  
Ruling: **ADDED** as EDGE-I-22  
Same rationale as Electron item #17.

**23. Live update error event on callback (watch mode)**  
Ruling: **ADDED** as EDGE-I-15  
Rationale: §6.7 specifies error reporting in watch mode. Original test EDGE-I-16 only checked that an error happened; EDGE-I-15 in the final suite verifies the payload structure.

### Missing Tests (Rejected Additions)

**24. frameId format enforcement (`fr_[0-9a-f]{8}` prefix)**  
Ruling: **REJECTED as a gate**  
Rationale: §8.1 specifies "frameId generated by the provider (8 lowercase hex chars, prefixed `fr_`)." The frameId is generated by the provider and sent to the screen — the screen receives it, it doesn't validate its format. The provider is responsible for generating valid frameIds. Testing that the screen rejects malformed frameIds would be testing provider-generated inputs, which the screen has no reason to reject by format. The screen's obligation is to echo the frameId in snapshots and check staleness — both are already tested.

**25. POST /watch transport security (reject non-HTTPS callback URLs)**  
Ruling: **REJECTED as explicit gate for v1**  
Rationale: The spec says "All outbound POSTs from the screen go to this URL" (§6.3) and that the provider's server uses HTTPS. However, the spec doesn't explicitly state the screen must validate the callbackUrl scheme. This would be defense-in-depth, not a spec requirement. The HTTPS test added (EDGE-I-21) covers TLS from the screen's server side. Callback URL validation is a potential future addition when explicitly specified.

**26. Append beyond 10k line scrollback constraint**  
Ruling: **REJECTED as in-scope for this suite**  
Rationale: The spec specifies the limit (10,000 lines) for a frame push (§8.2). Behavior when appending beyond that limit during an active session is not specified. This is an implementation-quality question, not a spec compliance question. It can be added if the spec clarifies the behavior.

---

## Tests Kept Despite Feedback Objection

**PENCIL-E-11 / PENCIL-I-14 — Change stack (white-box)**  
The change stack is a first-class spec requirement (§13.4, §13.6) that enables CLU undo. Removing the test because it requires instrumentation would leave a spec obligation untested. Kept, with explicit annotation that test instrumentation (internal test hook) must be defined.

**SESS-E-04/05, SESS-I-03/04 — TTL tests**  
The 5-minute inactivity TTL is stated in §13.3 screen states and §14.6. While §6.4 appears contradictory, the reconciler's reading (active-use vs. inactivity) makes them compatible. Tests kept with clarifying spec note.

**EDGE-E-15 (formerly EDGE-E-18) — POST /watch without `events`**  
The test was challenged as "spec-open." Kept because a POST /watch without `events` is semantically empty — the screen could not know what to report. The design of §9.2 implies `events` is required.

---

## Summary Counts

### Electron Suite
| Category | Count |
|---|---|
| Tests in original | 97 |
| Tests removed (provider scope) | 2 (PAIR-E-12 original, EDGE-E-15 original) |
| Tests rewritten (modified) | 10 |
| Tests added (new) | 8 (DISC-E-13, HTTP-E-02b, PAIR-E-12 new, PAIR-E-13, EDGE-E-16–20, renumbering) |
| Tests in final | 111 |

### iOS Suite
| Category | Count |
|---|---|
| Tests in original | 131 |
| Tests removed (out of scope) | 7 (SPAWN-I-01–05, EDGE-I-14, DISC-I-15) |
| Tests rewritten (modified) | 11 |
| Tests added (new) | 9 (DISC-I-15 new, HTTP-I-02b, PAIR-I-15, PAIR-I-16, EDGE-I-15 restructured, EDGE-I-20–22, SESS-I-12 retained) |
| Tests in final | 132 |

---

## Open Spec Questions Surfaced

These are spec ambiguities or gaps identified during reconciliation. They should be resolved in the spec before the relevant tests become hard gates:

1. **Session TTL vs "no TTL" (§6.4 vs §13.3/§14.6):** Reconciler's reading makes them compatible, but the spec should be made explicit. Recommend: clarify §6.4 to say "no arbitrary renewal requirement during active use; 5-minute inactivity TTL applies when no requests are received."

2. **POST /watch required fields (§17.7/§9.2):** `events` field is treated as required by test suites. Spec should explicitly state required vs. optional fields.

3. **Change stack test instrumentation (§13.4):** Spec does not define a test-hook interface for the change stack. Should be specified if white-box testing is required.

4. **POST /watch callback URL scheme enforcement:** Spec implies HTTPS everywhere but doesn't explicitly require the screen to reject non-HTTPS callbackUrls. Clarify.

5. **PENCIL-E-10 / PENCIL-I-13 — Long debounce cadence during continuous drawing:** Spec §16.11 says "fires once at the 3–5s mark, then again at the next idle gap." This is open to interpretation (fires once total vs. fires at every debounce boundary during continuous drawing). The test suites interpret it as boundary-fire during continuous drawing. Spec should clarify.
