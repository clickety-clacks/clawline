# Filtering Summary

## bubble-sizing-v2
Kept: min-width floor gap in `applyMeasuredSize` (causes sticky bad measurements), BubbleLayoutPlan as shared contract between sizing and render, `heightCapMode` enum replacing implicit override-presence check, link preview "return cap immediately" elimination, `BubbleLayoutEnvironment` as cache key including `platform` and `metricsFingerprint`. Stripped: all data model descriptions, measurement pipeline walkthrough, new type field lists.

## chat-information-architecture
Kept: client must never construct DM session keys, delivery target ≠ session identity, `dmScope` effect on Personal DM stream visibility. Stripped: most of the spec is code-evident UI architecture description and session key format tables.

## chat-vm-lifecycle-ownership
Kept: root cause (SwiftUI view churn stopping observers), `activate()` must call `viewAppeared()` (not just observation), `chatService.disconnect()` intentionally NOT called on view disappear, `isChatVisible` scope constraint. Stripped: implementation plan, verification steps, code change descriptions.

## clawline-extension-isolation
Kept: outbound bridge state must be extension-owned, migration rule limiting new core imports, precise move set boundary, plugin-SDK breaking change, five canonical invariants that must not change. Stripped: file lists, migration step descriptions, code structure walkthroughs.

## clawline-inbound-admission-backpressure
Kept: `ack` implies clearable (core invariant), poison-head failure mode, single lifecycle transition seam, lightweight provenance as required invariant, explicit backpressure vs silent limbo. Stripped: data model descriptions, implementation plan, open questions.

## clawline-invariants
Kept: `resolveGlobalLane` deadlock invariant (B1), WS auth tightened constraints (nonce required, skew 2m, v3 only), plugin HTTP contract change, session routing canonicalization Clawline opt-out, model alias preservation requirement. Stripped: obvious routing invariants readable from code.

## connection-lifecycle
Kept: root cause of reconnect loop (no epoch token + late cache restores), coordinator as sole phase writer, reconnect intent filtering rules, manual retry in recovering special treatment, `connectionSnapshot()` must send ALL per-stream cursors, cache restore gap-fill barrier, recovering backoff as sole reconnect mechanism. Stripped: phase descriptions, lifecycle model details, file listing.

## connection-state-ui
Kept: intentional no "unresponsive" state decision and rationale, errorBanner removal, `.failed` mapping to disconnected presentation, resend as new bubble (not retry), terminal ping loop is separate. Stripped: code findings description, state mapping tables, animation specs.

## dictation-architecture
Kept: `.finalizing` is internal and never published, `surfaceTarget` published immediately before finalization completes, two-faces architecture rationale, `originSessionKey` ownership, commands as only mutation seam, `walkieOrigin` internality. Stripped: all command and data structure descriptions readable from code.

## dictation-motion-model
Kept: unlock on ALL exit paths invariant, inset commit forbidden during drag/animation, `settledSurface` as single source of truth, inactivity timer resets on token receipt (not audio), `originSessionKey` restore on resume, pull-to-send as same gesture continuum, walkie origin captured once, all stop paths must enter finalization hold, phone sleep lock/unlock centralization, waveform period vs amplitude different curves, pager indicator rigid coupling, first-attempt vs walkie disambiguation. Stripped: all enumerated invariants that describe what the code does rather than why.

## dictation-ux-v2
Kept: send does NOT close surface (keeps open for rapid-fire), keyboard state preserved on activation, waveform is always amplitude-reactive even when paused, timing parameters unchanged, velocity + displacement both matter for gesture threshold, inbound call vs background different interrupt behaviors. Stripped: layout and design specs, edge case tables, visionOS platform notes.

## efficient-flow-layout
Kept: hard gate (no optimization before seam consolidation), bottom inset → NO immediate layout recalc (counterintuitive), dark mode = zero sizing work, session switch is not a geometry event, width stability invariant (y-shift depends on it), single-message append must be fast path, targeted handler incompleteness, multiple height changes single forward pass, capped bubble recalculation timing (visible AND scrolling stopped). Stripped: problem statement, current architecture description, proposed data structures, implementation approach details.

## interactive-html-bubbles
Kept: complete WKWebView isolation invariant, measure-once-lock protocol (why), `_resize` at-most-one-per-lifetime, callback delivery semantics (at-most-once, ordering not guaranteed under rate limiting), 256KB dual enforcement, security model rationale, base URL nil, crash recovery one-auto-reload policy. Stripped: message payload format, JS bridge API, theming CSS, implementation scope checklists.

## message-stream-seam
Kept: compiler-error-first migration order is mandatory, cache is gap-fill only, retry appends at tail not in-place, streaming update-in-place vs initial insert test distinction, logout clear atomicity definition, provisioning gate (no send before provisioned), `removeSession` vs `clearSessionMessages` distinction, `replaceSession` not public. Stripped: seam operation descriptions, acceptance criteria, migration checklist.

## message-timestamps
Nothing to keep — all content is straightforward display logic and SwiftUI layout structure derivable from code.

## multi-agent-clawline-routing
Kept: exact iOS hardcode locations for `agent:main`, provider parses keys but binds routing to `mainSessionAgentId` (inconsistency), prefix change creates orphaned data requiring migration, `normalizeStoredSessionKey` means storage is not fully opaque. Stripped: phase plans, per-file migration checklists, validation test descriptions.

## multi-stream
Kept: sessionKey IS the stream ID, `agent:main:main` not special-cased, secure random suffix, orderIndex gaps allowed, UNIQUE constraint serialization requirement, stream_snapshot before replay messages, hard-delete transaction order, events.sessionKey backfill prerequisite, idempotency window, deletion is client-initiated ONLY, iOS `isClawlinePersonalDM` hardcodes `parts[1] == "main"`. Stripped: SQL schema tables, API request/response shapes, WS event format details.

## per-stream-state-encapsulation
Kept: seam fires before offscreen guards, outgoing flush uses pre-mutation key, debounce is batching only (must flush on switch), shared "at bottom" threshold across three sites, `forceReReadGeneration` as only valid re-read trigger, deferred work from stream A must not execute in stream B, replay cursor belongs to transport layer, `lastAppliedEffectiveSessionKey` committed before heavy render, re-read must not persist geometry until confirmed, per-stream state cleanup on delete, BubbleSizingV2 cache keys must include sessionKey. Stripped: PerStreamRuntimeState field listings, migration strategy steps, integration notes.

## per-stream-transition-surface-contract
Kept: universal guard rule (capture at schedule, validate before access), shims are safe in bound-epoch only, `dataSource.apply` completions are yield boundaries, cleanup obligations survive guard failure, `viewDidLayoutSubviews` must pass all parameters, default-parameter hazard, `deinit` must cancel all streams' deferred work, SBB emission forced vs change-detection rule, `scheduleTailToFullPromotionIfNeeded` generation guard needed, `scrollToMessageCentered` generation guard needed. Stripped: async boundary classification table, all example code, epoch stability definitions.

## prewarm-controller-safety
Kept: two types not enum gate (compile-time enforcement), WriteHandle minting fileprivate, shared layout cache is ONLY write prewarm can do, teardown trigger is page controller's first apply, staleness epoch check before cache write, two controllers must not share data source, 30s safety TTL, LayoutSnapshot value identity for cache keying, MessageFlowRenderCore must not hold write handles. Stripped: invariant numbering, handle/type descriptions, cross-invariant checklist.

## provider-salient-highlight
Kept: message delivery must never await refinement, payloadJson update for replay (no separate table), capability negotiation required for patch events, substring not offsets (with rationale), candidates must be exact substrings, second-pass extraction vs self-marking rationale. Stripped: API shape definitions, implementation plan, error handling steps.

## salient-highlight
Kept: must run on Rendered Text not raw markdown, don't ask model for offsets (use substrings), cache key includes renderedTextHash, no synchronous model call in configure, span application rules (skip links, skip inline code), per-request LanguageModelSession, concurrency limit and debounce, renderedTextLengthUTF16 sanity check. Stripped: full data model definitions, service protocol definitions, testing plan.

## scroll-to-bottom-button
Nothing to keep beyond what's in scroll-to-bottom-invariants.md.

## scroll-to-bottom-invariants
Kept: shared "at bottom" threshold across three sites, `wasAtBottomBeforeUpdate` capture timing, initial load/backfill must not generate unread, `firstUnreadMessageId` set once and held stable, crossing viewport center triggers flash AND clear simultaneously, indicator anchored to input bar (not screen), typing indicator exclusion. Stripped: state machine table (code-evident), definition section.

## staged-stream-materialization
Kept: why N=50 (measurement-derived), new messages during expansion are queued (not dropped), unread marker outside tail window never auto-clears, anchor compensation mechanism, `advanceMaterialization` as single write seam, staged path gates (first activation + messageCount > 50 only). Stripped: problem statement, non-goal list, UX behavior description.

## stream-switch-coordinator
Kept: why two keys (measured regression rationale), epoch counter atomicity requirement, pager vs programmatic different debounce, epoch-based cancellation semantics, target validation at commit time, toast must remain until engine activation completes, ChatView.onChange key binding classification. Stripped: reader classification table, acceptance criteria, file listing.

## t113-architecture-plan
Kept: dependency stack direction, T104 already implemented on branch, T077 already resolved, T100 out of scope, two cursor concepts must not be conflated. Stripped: architecture overview (derivable from child specs), ticket descriptions, phase plans.

## terminal-bubbles
Kept: separate WebSocket connection (not chat WS), MIME type detection for backward compat, PTY resize must be sent to provider, auth token for terminal WebSocket endpoint, remote tmux architecture (provider SSHes, not client), cell reuse teardown. Stripped: SwiftTerm integration notes, architecture overview, message format specs.

## unified-markdown
Kept: MarkdownRenderPlan built once and shared, block ordering is strict source order (not split by type), `==highlight==` syntax preserved. Stripped: pipeline description, data model field listings, surface option descriptions.

## unread-indicators
Kept: three specific mutation call sites, stream switch clears unread to tail ID, APNS/cross-device sync explicitly out of scope. Stripped: state model description, UI change specs (derivable from code).

## voice-dictation
Kept: client-direct Soniox (no provider), real network validation required, mic icon visibility decoupled from key presence, both regular and temp keys accepted, legacy UX is a clean break (full replacement). Stripped: UX interaction contract, settings UI specs, architecture conformance statement.

## watch-app
Kept: two independent connection categories, route indicator is hard invariant, STT/TTS unavailable in BT-only relay mode, API keys via WatchConnectivity (not provider), audio never through provider or relay. Stripped: connectivity diagram, implementation details.

## watch-ios-support
Kept: Soniox/Cartesia key storage doesn't exist yet (Phase 0 prerequisite), relay is transparent proxy, token refresh relay requirement, background task for relay continuity, no iOS UI required. Stripped: implementation scope lists, code structure details.
