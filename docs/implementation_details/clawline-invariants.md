# Clawline Invariants — Non-Obvious Details

## Deadlock-causing `resolveGlobalLane` invariant (B1 — CRITICAL)
`run.ts` must NOT have any process-wide mutex or serialization guard beyond lane queue semantics. `resolveGlobalLane` must stay bare — `params.lane` only, **no `?? sessionLane` fallback**. The fallback form causes deadlock when session lane and global lane collide. This is invisible from reading any single file; it requires knowing the lane interaction model.

## WS auth handshake — non-obvious tightened constraints (v2026.3.2)
- Device nonce is required whenever device identity is present — **no local-client nonce exemption** (was allowed before, now removed).
- Legacy v1 device signature fallback is removed; v2/v3 path only.
- Device signature skew tightened from 10m → 2m.
- `connect.challenge` nonce is now **mandatory** — if missing, client closes with connect error.
- These are breaking changes; old clients fail auth silently if not updated.

## Plugin HTTP contract — old `registerHttpHandler` removed
`registerHttpRoute` now requires `auth` (`"gateway" | "plugin"`) and `match` (`"exact" | "prefix"`) fields. Old `registerHttpHandler` removed. Extensions that registered HTTP handlers need updating.

## Session routing canonicalization — Clawline opt-out requirement
`mainDmOwnerPin` is **never** passed by Clawline. Stream keys are structurally distinct from `agent:main:main`. The canonicalization skip path is opt-in only; Clawline-registered sessions must not hit it. If this invariant breaks, messages route to wrong sessions silently.

## Model aliases must survive upstream merges
`sonnet-4.5` and `sonnet-4.6` alias entries in `src/config/defaults.ts` are fork-only additions. They must be explicitly preserved after any upstream defaults migration — upstream will not know about them.

## Plugin-SDK Clawline exports — required by extension
`ClawlineDeliveryTarget` and `sendClawlineOutboundMessage` must remain exported from `src/plugin-sdk/index.ts`. These are required by `extensions/clawline/src/channel.ts` and `outbound.ts`. Removing them breaks the extension without a compile error in the core.
