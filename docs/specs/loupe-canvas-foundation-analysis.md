# Surf Ace Architecture Decision: Is Canvas the Foundation?

Status: analysis memo  
Date: 2026-02-24

## Executive answer

**Recommendation: Do _not_ treat OpenClaw Canvas as the kernel for Surf Ace.**

Use Canvas as a **rendering adapter/prototyping surface**, but build a **dedicated Surface Control Plane** in Gateway/Provider for Surf Ace v1 (surface identity, frame lifecycle, viewport/selection context, routing, policy).

Why: current Canvas is command-oriented (`canvas.present/navigate/eval/snapshot`, A2UI v0.8), foreground-gated on mobile nodes, and optimized for single-node visual control—not multi-surface state orchestration.

---

## 1) Practical feasibility: Canvas-as-kernel for v1

### What is feasible quickly

Canvas can ship a narrow v1 demo quickly if the goal is:
- one or few surfaces,
- mostly HTML/A2UI content,
- best-effort sync,
- user keeps node app foregrounded (mobile),
- low expectations for persistent/replayable surface state.

### What is not a good fit for a kernel

Surf Ace spec requires first-class concepts Canvas does not natively provide today:
- surface registration/discovery model (`surface_register`, capabilities, viewport metadata)
- frame lifecycle as domain objects (`surface_frame`, append/patch/clear)
- surface context table + contextual injection into CLU processing
- reliable multi-surface orchestration semantics independent of node UI implementation

Canvas today is closer to **device UI primitive + remote control RPC** than system foundation.

Verdict: **Feasible as bootstrap renderer, not feasible as long-term architectural kernel.**

---

## 2) Constraints and risks

## Protocol/model risks

1. **Semantic mismatch**
   - Canvas API is imperative commands on node (`present/hide/navigate/eval/snapshot`).
   - Surf Ace needs declarative surface/frame state and context extraction.
   - Risk: bolting Surf Ace semantics onto `canvas.eval` becomes brittle and client-specific.

2. **A2UI ceiling**
   - Current docs indicate A2UI v0.8 only; v0.9 `createSurface` unsupported.
   - Risk: richer compositional UI and multi-surface layout features hit protocol limits early.

3. **No event replay baseline**
   - Gateway event model is non-replay by default; Surf Ace wants coherent “what is visible now” state.
   - Risk: reconnect gaps and stale context unless a dedicated server-side surface state table exists.

## Scalability/state-sync risks

4. **Single gateway multiplexing pressure**
   - Gateway multiplexes WS control plane + HTTP canvas host on same port.
   - Risk: high-frequency viewport/content updates increase coupling and operational contention.

5. **State authority ambiguity**
   - Canvas host serves files/HTML; node renders; provider needs context.
   - Risk: unclear source of truth unless Gateway owns canonical surface state.

## Auth/discovery/security risks

6. **Canvas host is untrusted web content surface**
   - Security docs warn canvas paths should be treated as untrusted HTML/JS.
   - Risk: if treated as core control plane, origin/auth boundaries become harder to reason about.

7. **Node-scoped capability URLs are session-bound/ephemeral**
   - Good for security, but not equivalent to durable surface identity.
   - Risk: weak abstraction for standalone surface clients without explicit `surfaces:connect` model.

## Rendering/mobile/visionOS risks

8. **Foreground-only constraints on iOS/Android node canvas/camera/screen**
   - `NODE_BACKGROUND_UNAVAILABLE` on backgrounded app.
   - Risk: poor reliability for ambient/multi-device “always there” Surf Ace behavior.

9. **Current mac Canvas UX constraints**
   - One visible panel at a time per app session behavior.
   - Risk: not aligned with multi-monitor/multi-window orchestration goals.

10. **VisionOS requires window/spatial semantics**
   - Canvas primitives don’t encode spatial placement/relationships.
   - Risk: architecture debt if these are retrofitted later.

## Ops complexity risks

11. **Port/network/discovery coupling**
   - Canvas host, discovery hints, and node transport are tightly coupled to Gateway deployment topology.
   - Risk: operational complexity increases when expanding to many surfaces/devices.

---

## 3) Recommended v1 architecture

## Decision

**No** on Canvas-as-core kernel.  
**Yes** on Canvas-as-adapter underneath a new Surf Ace Surface Control Plane.

## v1 architecture (practical)

1. **Gateway Surface Service (new core)**
   - Owns canonical surface registry/state:
     - `surfaceId`, capability profile, active frame metadata, last viewport/selection, freshness timestamps.
   - Exposes server APIs for provider prompt injection and orchestration.

2. **WS protocol additions (Surf Ace-native)**
   - Add `surface_register`, `surface_deregister`, `surface_frame`, `surface_viewport`, `surface_selection` (plus append/patch/clear).
   - Keep additive with current protocol versioning.

3. **Provider integration**
   - Add `surface_push` tool/action.
   - Inject compact “active surfaces” context into model system prompt.

4. **Renderer adapters**
   - **Adapter A (first-class):** Clawline iOS/iPad/VisionOS surface view implementation from Surf Ace spec.
   - **Adapter B (compat):** map Surf Ace frame events to legacy node canvas commands where possible.

5. **Canvas host role**
   - Keep as static asset/A2UI content host for renderer clients.
   - Do **not** treat it as state authority or orchestration engine.

This preserves speed (reuse existing canvas renderer path) while preventing architectural lock-in.

---

## 4) Build now vs later (phased)

## Build now (v1)

1. **Surface control plane minimal slice**
   - Registration + one-frame-per-surface.
   - HTML + markdown frames.
   - Viewport settled reports + text selection only.
   - In-memory state table (ephemeral) with provider read API.

2. **iOS embedded surface view**
   - Implement Surf Ace surface view as in current Surf Ace spec (WKWebView first).
   - Keep fallback to chat inline UI when no surfaces available.

3. **Policy guardrails**
   - Per-surface/frame size limits and update rate caps.
   - Basic auth/scope for surface connections.

4. **Compatibility bridge**
   - Optional mapping from `surface_frame(html)` to `canvas.navigate` for existing nodes to accelerate demo/testing.

## Later (v1.5/v2)

1. PDF/image/terminal append/patch sophistication.
2. Durable frame persistence policy (“keep this up” across reconnects).
3. Standalone browser kiosk + delegated `surfaces:connect` scope.
4. Multi-frame layout and spatial/visionOS placement model.
5. Advanced extraction pipeline for `visibleContent` (client-assisted + server normalization).

---

## 5) Decision rubric: Canvas-first vs alternative

Choose **Canvas-first** only if most are true:
- Need to ship fast prototype in days, not weeks.
- ≤2 surfaces, mostly HTML/A2UI.
- Best-effort context is acceptable.
- Mobile foreground interaction is acceptable.
- Limited security/tenant complexity.

Choose **Dedicated Surf Ace Surface Control Plane** if any are true:
- Need reliable multi-device/multi-monitor orchestration.
- Need stable surface identity and contextual state as first-class primitives.
- Need reconnect resilience, policy control, and rate-limited synchronization.
- Need future VisionOS/window topology and richer UI protocols.
- Need clear auth/discovery boundaries for standalone surfaces.

---

## Bottom line

Use Canvas as a **useful renderer and compatibility layer**, not as the architectural center.  
For Surf Ace v1, the right core is a **Gateway-native surface protocol + state service**, with Canvas plugged in underneath where it helps.