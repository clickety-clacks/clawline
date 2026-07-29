# Work item — model footer decode resilience + e2e assertion

Filed 2026-07-25 (Flynn, during tightbeam client-e2e scoping). Client-side item;
tightbeam side needs nothing.

## The failure mode

`SessionStatus` (ios/Clawline/Clawline/Models/SessionStatus.swift) declares
`sessionKey`, `display`, `run`, and `capabilities` NON-optional, plus required
fields nested inside them. Swift's synthesized `Decodable` is all-or-nothing: if the
gateway ever stops sending ONE of them — a rename, a field moving behind a flag, a
harness-specific omission — the whole decode throws, the view model's status stays
nil, and the **model footer silently renders empty**. No crash, no error surface,
nothing server-side to notice: the gateway's response was 200 and well-formed by its
own contract.

This is why SMOKE.md §6 step 13 asserts the FOOTER POPULATES after a real model
change, not just that `GET /api/session-status` returns the new ref — the raw-JSON
check passes while the client shows nothing.

## The work

1. **Resilience**: decide and implement the decode posture — either (a) make
   non-essential fields optional with explicit defaults so a partial payload still
   yields a usable status, or (b) keep strict decoding but surface the failure
   (log + a visible degraded state) instead of a silent nil. Not both-and-neither:
   today's behavior is strict-and-silent, the worst pairing.
2. **Regression test**: a decode test per required field — drop that field from a
   captured real payload, assert the chosen posture (usable status with default, or
   a surfaced error). A captured payload, not a hand-written one (tightbeam's
   right-sizing rule: real capture, assert only consumed fields).
3. **Accessibility identifiers** for the model picker entry and the footer label —
   the two the tightbeam client-e2e driver needs for SMOKE §6 step 13 (see
   shared-workspace specs `client-e2e-v1.md`, journey J6). Everything else in J6
   reuses the existing turn-completion oracles.

## Why it matters beyond the footer

The same all-or-nothing decode shape applies to every non-optional model the client
decodes off the wire. If posture (a) or (b) is chosen here, it should be stated as a
client-wide convention, not a one-file patch.
