# Opus Adversarial Review: `web-port-recon.md`

Date: 2026-03-30

Primary lens: internal consistency. Secondary lens: architectural weakness, ambiguity, and implementation traps.

Runtime decision note:

- The later settled product decision is that each browser tab is its own device/socket.
- The old leader/follower runtime criticized below was removed from the main spec. Any references to that coordinated-tab model are historical review context, not current architecture.

## Blocking Findings

1. **The spec says two incompatible things about stream selection and activation.**  
   The feature inventory still tells the implementer to preserve the iOS `uiSelectedSessionKey` / `engineActiveSessionKey` split ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L344)), while the SSOT matrix says selected session is owned by URL state only ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L565)). Then the conventions section reintroduces a `UI vs engine stream split` as a grounded rule ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L2085)). An engineer cannot tell whether the web app should have one selected-session concept or a deliberately split UI/engine model. This is exactly the kind of iOS-pattern transplant the spec was supposed to eliminate.

2. **State ownership for stream/session state contradicts itself between the architecture seam and the Phase 1 build sheet.**  
   The architecture says `chatDomainStore` is the authoritative owner for send eligibility, provisioning state, stream metadata, and stream ordering ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L566), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L567)). The Phase 1 build sheet then creates a separate `sessionCatalog` owner for stream inventory, provisioned session keys, and selected-session normalization ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1882), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1895)). Those are not the same architecture. One version centralizes stream/session truth in `chatDomainStore`; the other splits it into `sessionCatalog` plus `conversationStore`. The spec needs one ownership model, not both.

3. **Replay cursor behavior is both unresolved and treated as settled.**  
   The mismatch table says `replayCursorsBySessionKey` is the target shape but provider acceptance is still unconfirmed ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1157)). The typed protocol table repeats that this is not yet settled behavior ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1356)), and the unresolved decisions table says it blocks full Phase 2 fidelity ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L2066)). But the UX/state spec still says bootstrap sends `auth` with the latest processed server cursor ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1775)) and reconnect resumes with all known per-stream cursors ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1803)). That is two incompatible auth/resume stories: singular cursor vs per-stream cursors, unresolved vs required.

## Important Findings

4. **Terminal protocol and lifecycle guidance drift across sections.**  
   The typed terminal appendix says to include those event names only if the advanced rich-surface phase is in scope ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1610)), but the Phase 1 build sheet still requires `src/protocol/terminal-wire.ts` from day one ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1879)) even though Phase 1 explicitly omits rich surfaces. Separately, the terminal contract says terminal bubbles bind/teardown with normal view reuse and do not preserve offscreen runtime ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1760)), while the conventions section globally says React mount/unmount must not own socket teardown semantics ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L2088)). That convention may be right for the main chat transport, but it is not right as a global rule when the terminal section says the opposite.

5. **Resolved historical finding: the earlier coordinated-tab runtime model was removed.**  
   This review originally flagged a contradiction where the spec chose a leader/follower runtime but deferred proving that runtime until later phases. That finding is no longer active. The current spec now treats each browser tab as its own device/socket, which removes the old `leaderElection.ts` and multi-tab coordination requirement from the critical path. The remaining expectation is simpler: phase and acceptance language should only require independent-tab behavior, not shared-transport leadership.

6. **Several “open decisions” are phrased elsewhere as if the spec already picked a winner.**  
   The feature inventory says auth persistence should use secure cookies if possible, else local storage with accepted risk ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L335)), but the unresolved decisions table still says the browser auth storage model blocks Phase 1 ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L2063)). The feature inventory also says link cards likely prefer server-backed metadata fetch ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L358)), while preview-fetch topology remains unresolved ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L2067)). Recommendations are fine, but they need to be explicitly marked as provisional; otherwise the “unresolved” table is not trustworthy.

7. **The state-boundary story is mostly ownership-first, then briefly regresses into old “bucket” language.**  
   The architecture correctly rejects a junk-drawer `uiStore` and says selected session belongs in URL state while local route state should stay local ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L605), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L606), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L611), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L612)). But the product-decisions section later summarizes the target as `connection state`, `stream/session state`, `message state`, and `UI state` ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1083), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1088)). That sounds like the older bucketed-store framing the spec supposedly replaced. It is not a contradiction as sharp as the stream/session ownership conflict, but it weakens the seam language at exactly the point where the spec should stay precise.

## Secondary Findings

1. **Phase 1 persistence scope is still easy to misread.**  
   The Phase 1 build sheet requires IndexedDB persistence and pending-send persistence scaffolding ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L1883)), while the high-level phase plan puts persisted transcript snapshots and durable reload behavior in Phase 2 ([web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L943), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L945), [web-port-recon.md](/Users/mike/shared-workspace/clawline/specs/web-port-recon.md#L946)). The likely intended reading is “Phase 1 lays the persistence boundary; Phase 2 expands it to full transcript fidelity,” but the spec should say that explicitly.

2. **The document still carries some inventory-language in implementer-critical sections.**  
   The architecture section is much stronger than before, but the implementer appendix occasionally drops back into file-listing and bucket naming instead of preserving the boundary principle. The `sessionCatalog` introduction is the clearest example, but the same pattern shows up in the Phase 1 kickoff table generally: it names modules before fully reconciling their ownership model with the seams above.

3. **Terminal and interactive HTML are appropriately gated, but the gating logic is split across too many sections.**  
   The spec currently spreads their status across the executive assessment, high-level phases, protocol appendix, Phase 1 omissions, and unresolved decisions. The overall direction is understandable, but an implementer can still miss whether terminal is “documented because it exists,” “must be typed now,” or “must not be built until scope is confirmed.”

## Overall Judgment

The spec is close to handoff-ready, but the remaining contradictions are concentrated in high-leverage places:

- state ownership
- stream selection semantics
- replay cursor resume semantics
- terminal gating/lifecycle
- runtime-model sequencing

Those are not editorial nits. They affect where an engineer puts the first real seams in code. If left unresolved, the implementation can follow the spec faithfully and still build the wrong architecture.

## Recommended Revision Order

1. Choose one stream/session ownership model and rewrite both the seam section and Phase 1 build sheet to match it.
2. Remove or explicitly reinterpret every surviving `uiSelectedSessionKey` / `engineActiveSessionKey` transplant.
3. Rewrite replay-cursor behavior so unresolved provider support is reflected consistently in the protocol appendix, state-transition specs, and phase criteria.
4. Scope `Visibility is not lifecycle` to the main chat runtime, or rewrite the terminal lifecycle section so the two no longer conflict.
5. Make every “preferred” auth/preview choice visibly provisional until the unresolved-decision table is actually resolved.
