# Surf Ace Spec Internal-Consistency Review (Pass 13, adversarial)

## 1) Verdict
**REAL ISSUES**

## 2) Findings

1. **Phase ordering is contradicted by the tool/read surface that remains window-only and effectively annotation-first.**
   - **Refs:** §2.3 lines 37–59, §6.0 lines 232–237, schema `SurfacesListResponse` lines 885–899, §14.3 lines 2022–2054 and 2098+ (`surf_ace_push/clear/read` params).
   - **Problem:** §2.3 says Phase 1 (multi-window + multi-pane targeting) must be done before annotation-priority work, and requires pane-aware tool targeting + pane enumeration. But normative operations/schemas/tool contracts are still single-scope (`surfaceId`/`fingerprint` only), while dual-channel annotation behavior is fully normative in §§13–14. This creates implementation ambiguity about what is actually phase-blocking vs phase-deferred.
   - **Concrete fix text suggestion:**
     - In §2.3, replace:
       - `Constraint: annotation features are not considered implementation-priority work until Phase 1 topology work ...`
     - With:
       - `Constraint: annotation semantics in §§13–14 are normative architecture and may be implemented in parallel, but release/priority gating is: pane-aware topology (Phase 1) must ship before annotation-priority milestones are considered complete.`
     - In §14.3 intro, append:
       - `Pane selector is currently omitted from v1 tool signatures in this document; Phase 1 completion requires adding optional \'paneId\' (default \'root\') to all screen-scoped tools.`
     - In §6.0, append:
       - `Phase 1 profile: surfaces.list MUST optionally include pane summaries per surface (paneId, activeContent) once pane support is enabled.`

2. **A.10 is duplicated with conflicting status semantics (“committed before annotation work” vs “deferred to v2”).**
   - **Refs:** §A.10 lines 2443–2459 and second “A.10 Future Extension” lines 2463–2475.
   - **Problem:** Same section number appears twice with different status language. First says committed phase work and pre-annotation priority; second says deferred to v2 candidate. This is a direct planning contradiction and will cause downstream teams to pick opposite sequencing.
   - **Concrete fix text suggestion:**
     - Rename second header to `### A.11 Future Extension — Multi-Pane Enhancements Beyond Phase 1`.
     - Replace status line:
       - `Status: Deferred to v2...`
     - With:
       - `Status: Base multi-pane topology is Phase 1 committed work (§2.3). This subsection covers additional v2 enhancements beyond Phase 1 (advanced pane layout ops and richer pane lifecycle events).`

3. **Core term “Surface” conflicts with multi-window identity model (physical device vs window-scoped unit).**
   - **Refs:** §2a line 65, §3.1.1 lines 87–94, §14.3 lines 2022–2035.
   - **Problem:** §2a defines Surface as a physical screen/app instance, but §3.1.1 treats each window as an independent surface with unique `surfaceId`; §14.3 maps tool `fingerprint` to window-scoped identity. This mismatch leaks into implementation boundaries (discovery, pairing, caching, ownership).
   - **Concrete fix text suggestion:**
     - Replace §2a “Surface” definition with:
       - `Surface — a render target context addressable by stable identity. In v1 multi-window mode, each window is a distinct surface (`surfaceId`) even when hosted by one app instance/device endpoint. In future multi-pane mode, pane routing is nested under a surface via `paneId` (default `root`).`
     - Add new explicit term:
       - `Endpoint — the app/device WS host:port advertised via mDNS; may host multiple surfaces (windows).`

4. **Selection semantics are internally inconsistent (wire/profile says text|point|region; buffer/read contract says v1 text-only and discard others).**
   - **Refs:** §7.1 line 402, schema `Selection` lines 734–766, §13.2 register table line 1912, §14.3 `selection` return shape lines 2134–2136.
   - **Problem:** Event model and schema allow point/region selection, but provider contract for v1 says discard point/region and preserve only text. Tool read contract is text-centric (`selectedText`, `bounds`) and declares non-HTML always null. Without explicit compatibility rule, implementers will diverge (emit point/region vs drop).
   - **Concrete fix text suggestion:**
     - In §7.1 item 3, change to:
       - ``event.selection` - semantically complete selection event. In v1 interoperability profile, only `kind:"text"` is guaranteed; `point`/`region` are reserved for v2 unless explicitly negotiated.`
     - In schema `Selection`, add description on `point` and `region` variants:
       - `Reserved for v2; v1 providers MAY receive but MUST ignore unless feature-negotiated.`

5. **Stale cross-reference: frame-finalization note points to wrong section for flush-gate timing.**
   - **Refs:** §13.2 line 1831 vs actual flush-gate definition §7.1 lines 415–426.
   - **Problem:** §13.2 says cadence is governed by “Section 4 flush-gate timing,” but flush gates are defined in Section 7. This is a minor but implementation-impacting doc defect during onboarding/review.
   - **Concrete fix text suggestion:**
     - Replace `Section 4` with `Section 7.1` in line 1831.

## 3) Short risk summary
If left as-is, teams can legitimately implement two incompatible roadmaps: (a) topology-first pane-aware tools, or (b) annotation-first dual-channel behavior on window-only selectors. The A.10 status conflict and scope-term drift (surface vs endpoint/window) materially increase integration risk across provider, iOS, and Electron. Selection-model inconsistency further risks silent data loss or incompatible event handling between wire and tool layers.