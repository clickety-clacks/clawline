# Clawline Invariants (Canonical)

## Invariants
1. **Session keys are the only routing identifiers.** Every message, delivery, and reply uses the session key (e.g., `agent:main:main` or `agent:main:clawline:{userId}:main`). Do not invent or parse alternate identifiers; keep delivery routing anchored in the session store or plugin adapter.
2. **No deployment-specific configuration in tracked repo files.** Core OpenClaw code ships everywhere. Clawline routing semantics, session key guidance, and deployment overrides belong in runtime config like this file—not in shared `src/` or `docs/` files under version control.
3. **Rebase merge philosophy:** minimize shared/core divergence, adopt upstream patterns, avoid inventing new core hooks, and confine Clawline-specific behavior to extension/plugin directories unless a shared change is absolutely necessary.

---

## Appendix: Preserved Notes

### From: specs/rebase-2026-03-03/ (rebase migration specs, 2026-03-03)

**Key invariants preserved through v2026.3.2 rebase:**

**B1 — Parallel multi-stream ingress:** `run.ts` must NOT reintroduce any process-wide mutex/serialization guard beyond lane queue semantics. `resolveGlobalLane` must remain bare (`params.lane` only, no `?? sessionLane` fallback) — the fallback form causes deadlock when session lane and global lane collide.

**B10 — Model aliases:** `sonnet-4.5` and `sonnet-4.6` alias entries must resolve correctly in `src/config/defaults.ts`. These are fork-only additions and must be preserved through any upstream defaults migration.

**B13 — Plugin-SDK Clawline exports:** `ClawlineDeliveryTarget` and `sendClawlineOutboundMessage` must remain exported from `src/plugin-sdk/index.ts`. These are required by `extensions/clawline/src/channel.ts` and `outbound.ts`.

**WS auth handshake contract changes in v2026.3.2:**
- Device nonce is now required whenever device identity is present (no local-client nonce exemption).
- Legacy v1 device signature fallback removed; v2/v3 path only.
- Device signature skew tightened from 10m → 2m.
- `connect.challenge` nonce is now mandatory — if missing, client closes with connect error.
- Device auth payload upgraded to `buildDeviceAuthPayloadV3` (adds `platform` and `deviceFamily`).

**Plugin HTTP contract change in v2026.3.2:**
- New `registerHttpRoute` signature includes `auth` (`"gateway" | "plugin"`) and `match` (`"exact" | "prefix"`) fields.
- Old `registerHttpHandler` signature removed.

**Session routing canonicalization (v2026.3.2):**
- `mainDmOwnerPin` is NEVER passed by Clawline; stream keys are structurally distinct from `agent:main:main`.
- Skip logic is opt-in only; Clawline-registered sessions must not hit the canonicalization skip path.
