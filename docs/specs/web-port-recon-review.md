# Review of `web-port-recon.md`

Date: 2026-03-30
Author: Codex
Scope: Architectural review and iOS-pattern transplant audit

## Review Frame

This review is grounded in the following architecture principles:

- Pattern propagation
- Right-weight architecture
- Separation of concerns
- State mutation seam discipline
- Single source of truth

The source under review is the web-port feasibility spec currently mirrored in:

- `/Users/mike/shared-workspace/clawline/specs/web-port-recon.md`
- `/Users/mike/src/clawline/docs/specs/web-port-recon.md`

This review uses two lenses:

1. Standard architectural review: coherence, completeness, contradictions, weak assumptions, and unowned risks
2. iOS-pattern transplant audit: where the proposed web architecture still appears shaped by the existing iOS app instead of web-native defaults

Runtime decision note:

- The browser runtime decision is now settled: each browser tab is its own device/socket.
- Any older ambiguity in this review about leader/follower coordination should be read as resolved in favor of independent per-tab sockets.

## Blocking Findings

### 1. The spec names stores, but it does not define SSOT ownership for the critical runtime concepts

This is the largest architectural gap in the document.

The spec correctly calls out `ChatViewModel` as over-centralized, but its replacement proposal is still mostly a decomposition by noun:

- `authStore`
- `settingsStore`
- `connectionStore`
- `chatStore`
- `streamStore`
- `uiStore`
- TanStack Query
- service clients
- cache repositories

That is not yet an architecture. It is an inventory of containers.

What is missing:

- one authoritative owner for connection readiness
- one authoritative owner for replay cursor advancement
- one authoritative owner for selected session
- one authoritative owner for active transport session
- one authoritative owner for unread/read state
- one authoritative owner for send eligibility / provisioning
- one authoritative owner for message cache truth versus live transport truth

Without this, the spec risks recreating `ChatViewModel` as a distributed failure mode instead of a single file. The iOS app’s core problem is not just “too much in one place”; it is mixed ownership. Splitting that into six stores without an ownership matrix is pattern propagation, not correction.

Required spec change:

- Add an explicit SSOT table listing each critical product concept, its single owner, all readers, and every allowed mutation path.

### 2. The spec does not define the browser runtime model, which is one of the largest divergences from iOS

The spec discusses iOS scene lifecycle and reconnect/replay semantics, but it does not convert that into a web-specific runtime model.

Missing web-specific invariants:

- what happens with multiple tabs open at once
- whether each tab opens its own WebSocket
- how replay cursor advancement works when each tab is independent
- whether read/unread state is intentionally allowed to diverge per tab the way it diverges per device
- how visibility changes affect connection policy
- how focus, blur, online/offline, page refresh, and tab close affect session state
- whether background tabs are allowed to keep live sockets

This is not a secondary hardening detail. On web, this is part of the primary architecture. If left unspecified, different engineers will fill in the blanks differently and the resulting system will violate SSOT immediately.

Required spec change:

- Add a `Web Runtime Invariants` section before the proposed architecture.
- Settle the runtime as independent-per-tab sessions and make the divergence rules explicit.

### 3. The auth, TLS, and deployment topology is still an open question when it should be a prerequisite

The spec identifies the TLS mismatch correctly, but it leaves too much architectural weight hanging on unresolved decisions:

- secure cookies versus token storage
- same-origin versus cross-origin deployment
- browser-safe gateway/proxy versus direct browser-to-provider connection
- who terminates TLS
- whether WebSocket auth is cookie-backed or token-backed

These are not implementation details. They determine the web app shape, hosting model, and even whether the recommended stack should be a plain SPA.

As written, the spec recommends `Vite`, React SPA, and specific client-side storage choices before this prerequisite is resolved. That is backwards.

Required spec change:

- Add a hard prerequisite section:
  - approved browser deployment topology
  - approved auth model
  - approved TLS model
- Move framework/tooling selection after those decisions.

### 4. The proposed web architecture is internally over-layered and risks duplicate authorities

The spec currently recommends all of the following:

- React Router
- Zustand stores
- TanStack Query
- service clients
- cache repositories
- presentational components
- browser storage adapters

Each item is individually reasonable. Together, they create too many overlapping places where truth could live.

Examples of likely duplication:

- stream metadata in TanStack Query and `streamStore`
- messages in `chatStore` and IndexedDB repositories
- connection/replay state in `connectionStore` and `ProviderSocketClient`
- modal state in `uiStore` and route state

This violates right-weight architecture. The spec is trying to be safer by naming more layers, but the result is a web architecture with too many seams and no stated ownership rules.

Required spec change:

- Collapse the proposal into fewer authorities.
- Recommended target shape:
  - URL state for selected session and routable overlays
  - one socket/session state machine for transport + replay
  - TanStack Query for REST-backed remote data
  - IndexedDB persistence only where long-lived transcript caching is needed
  - local component state for view-local UI

## Important Findings

### 5. The caching recommendation still smells like an iOS file-cache transplant

The spec jumps from:

- iOS JSON caches in `Application Support`

to:

- `MessageCacheRepository`
- `StreamCacheRepository`
- IndexedDB tables

That is a direct conceptual transplant, not necessarily the most natural web choice.

What is missing:

- cache invalidation/versioning rules
- hydration precedence rules
- whether caches are authoritative, opportunistic, or offline-first
- whether read/unread markers are persisted in the same cache layer or elsewhere

A more web-native default would be:

- TanStack Query for REST-backed entities
- IndexedDB only for transcript durability and large local history
- explicit cache status semantics such as `live`, `hydrated`, `stale`, `partial`, `replaying`

### 6. The spec does not separate route state, app state, and ephemeral UI state sharply enough

`uiStore` is a warning sign.

The listed responsibilities include:

- sheets and modals
- toasts
- scroll-to-bottom control state
- expanded message state

This is the kind of global UI bucket that grows the same way `ChatViewModel` grew. On web, much of this should be:

- URL state
- component-local state
- route-subtree state

Only truly global overlays should be centralized.

### 7. The spec delays accessibility and security too late in the migration phases

The spec places accessibility and browser hardening in Phase 6 and security review for embedded content near the end.

That is too late for this app.

Why:

- terminal sessions and interactive HTML directly affect architecture
- message virtualization affects accessibility semantics
- the composer, keyboard model, and focus behavior affect accessibility from day one

Accessibility and embedded-content security are design constraints here, not post-build polish.

Required spec change:

- move accessibility acceptance criteria into the initial architecture section
- move embedded HTML/terminal security constraints into the rich-surface design phase, not the final hardening phase

### 8. The spec under-specifies browser-specific failure modes

Examples not addressed clearly enough:

- reload during optimistic send
- duplicate sends on reconnect
- stale tabs replaying old cursors
- attachment upload interrupted by refresh
- tab-to-tab divergence in unread counts
- clipboard/paste permission differences by browser
- iPad Safari versus desktop Chrome keyboard behavior

The feasibility study should call these out explicitly because they affect complexity estimates.

### 9. The framework recommendation is premature relative to the auth/proxy decision

The spec’s recommended stack may still be correct, but it is presented too confidently before the deployment topology is chosen.

If the final answer is:

- same-origin app
- server-assisted auth
- proxying provider access through a web gateway

then a framework with a server boundary may be a better default than a pure client SPA. The document should at least state that the stack recommendation is conditional on the deployment model.

### 10. The migration plan is missing a test strategy

Given how much of the cost sits in replay, unread state, virtualization, and rich attachments, the spec should recommend test categories early:

- protocol fixture tests
- reducer/state-machine tests
- independent-tab behavior tests
- browser automation for chat scroll and composer behavior
- rich-surface security tests

Without that, the estimated effort is optimistic.

## iOS-Pattern Transplant Audit

This section isolates places where the proposed web architecture still looks inherited from the current iOS app.

| Spec proposal | Why it looks iOS-derived | More natural web-native pattern | Review |
| --- | --- | --- | --- |
| Many named global stores (`authStore`, `connectionStore`, `chatStore`, `streamStore`, `uiStore`) | Mirrors iOS manager/viewmodel decomposition after splitting `ChatViewModel` | Use fewer global authorities: URL state, one transport/session machine, query cache, and local UI state | Replace with an ownership matrix first; only create stores that own truly shared mutable state |
| `uiStore` for modals, toasts, expanded message, scroll affordance | Feels like a central coordinator replacing native presentation state | Prefer route-driven overlays and component-local state; keep only global notifications global | Replace |
| `selected session` and `active engine session` as global store fields | Direct carry-over from iOS stream-switch optimization | Make selected session URL-derived; keep an activation controller only if profiling proves the dual-state model is needed on web | Preserve only conditionally |
| `MessageCacheRepository` and `StreamCacheRepository` | Mirrors iOS file-cache/repository shape | Use IndexedDB persistence behind query/store hydration boundaries; do not introduce repository classes unless they hide real complexity | Replace with thinner persistence adapters |
| Service class inventory (`PairingClient`, `ProviderSocketClient`, `UploadClient`, etc.) | Reads like a native service graph | Use feature modules and transport adapters; keep classes only where lifecycle or connection ownership truly needs them | Simplify |
| Client-rendered Vite SPA as default | Assumes the client can own auth and provider connectivity directly | Let deployment topology decide: SPA may be fine, but same-origin proxy/BFF could justify a server-capable framework | Make conditional |
| `Settings` as a dedicated route | Route-per-screen thinking carried over from app shells | Modal or route-driven overlay is more natural unless settings are large enough to deserve a page | Minor; either is acceptable |
| Explicit `ConnectionLifecycleCoordinator`-like transport state machine | Looks inherited from iOS lifecycle code | Still the right idea on web because transport state is genuinely complex | Keep |
| Detailed component noun tree (`MessageList`, `MessageRow`, `MessageBubble`, etc.) | Harmless inheritance from view decomposition | Fine, but module boundaries should be defined by feature ownership, not just component names | Keep, but add feature ownership notes |
| `Theme tokens should map from ChatFlowTheme` | Borrowing iOS design tokens into the web system | Reasonable; token translation is natural and not harmful | Keep |

## Where the Spec Is Strong

The following judgments in the original spec are solid and should remain:

- It correctly identifies the chat surface, not the transport handshake, as the dominant porting cost.
- It correctly treats terminal sessions and interactive HTML as scope multipliers rather than incidental features.
- It correctly rejects literal UIKit/SwiftUI mimicry as a goal.
- It correctly identifies TLS/self-signed behavior as a product constraint for the web, not a UI toggle problem.
- It correctly treats the current iOS client as a behavioral reference rather than a structure to copy.
- It correctly calls for protocol-contract capture before large-scale implementation.

## Required Revisions Before This Spec Should Drive Implementation

1. Add an SSOT ownership matrix for every critical runtime concept.
2. Add a browser runtime invariants section covering multi-tab, visibility, focus, online/offline, replay, and unread behavior.
3. Resolve or explicitly gate the deployment topology, auth model, and TLS model before locking the framework recommendation.
4. Simplify the proposed architecture to reduce duplicate authorities.
5. Reframe caching as a web persistence problem, not an iOS cache transplant.
6. Move accessibility and embedded-content security earlier in the plan.
7. Add a concrete test strategy section.

## Bottom Line

The underlying recon is strong. The feasibility conclusion is directionally correct. The weak point is the proposed web architecture section: it is still too shaped by the existing iOS client and does not yet establish clean SSOT and mutation boundaries.

In practical terms, the current spec is a good recon document but not yet a safe implementation spec. It should be revised once around ownership, browser runtime invariants, deployment topology, and web-native boundary choices before engineering starts.

## Author Adjudication

This section adjudicates the review findings against the original spec.

### Required Revisions

1. Add an SSOT ownership matrix for every critical runtime concept.
   Verdict: `AGREE`
   Why: The review is right. The original spec named domain stores and responsibilities, but it did not name authoritative owners and mutation seams for the hardest concepts. That leaves too much room to recreate `ChatViewModel` as distributed coupling.

2. Add a browser runtime invariants section covering multi-tab, visibility, focus, online/offline, replay, and unread behavior.
   Verdict: `AGREE`
   Why: This is a real omission. The original spec translated iOS transport concerns into web transport concerns, but it did not go far enough on browser runtime semantics. The settled answer is now independent per-tab sockets, but that still had to be stated explicitly because visibility and reload behavior are first-order architectural constraints on the web.

3. Resolve or explicitly gate the deployment topology, auth model, and TLS model before locking the framework recommendation.
   Verdict: `AGREE`
   Why: The original spec correctly identified TLS and auth as open questions, but it still moved too quickly into a concrete React/Vite recommendation. The stack recommendation should be conditional until deployment and auth topology are decided.

4. Simplify the proposed architecture to reduce duplicate authorities.
   Verdict: `PARTIAL`
   Why: I agree with the review’s diagnosis that the proposal can create overlapping authorities if implemented literally. I do not agree that the original spec’s overall direction was wrong. Splitting connection, stream, chat, and settings concerns is still the right instinct. The correction is to define ownership first and then instantiate the minimum number of stores, not to collapse everything back into a smaller but fuzzier shape.

5. Reframe caching as a web persistence problem, not an iOS cache transplant.
   Verdict: `PARTIAL`
   Why: The review is right that repository-style cache naming drifted too close to the iOS file-cache mental model. It is also true that Clawline has real transcript durability needs, so an explicit persistence layer is still warranted. I would revise this part toward thinner persistence adapters and explicit cache semantics rather than remove durable caching from the architecture.

6. Move accessibility and embedded-content security earlier in the plan.
   Verdict: `AGREE`
   Why: The review is correct. Accessibility for a virtualized chat surface and security constraints for interactive HTML and terminal content are architecture inputs, not end-stage hardening tasks.

7. Add a concrete test strategy section.
   Verdict: `AGREE`
   Why: The spec should have named the test categories needed to make the migration credible, especially around protocol fixtures, state machines, independent-tab behavior, browser automation, and rich-surface security behavior.

### iOS-Pattern Transplant Audit Adjudication

| Review row | Adjudication | Why |
| --- | --- | --- |
| Many named global stores (`authStore`, `connectionStore`, `chatStore`, `streamStore`, `uiStore`) | Reviewer changed my mind, partially | I still stand by separating the big concerns, but I no longer stand by predeclaring that many global stores as the default shape. The better version is ownership-first, then only the minimum shared stores. |
| `uiStore` for modals, toasts, expanded message, scroll affordance | Reviewer changed my mind | The review is right. That is too easy to turn into a new dumping ground. Toasts/global overlays can stay global; the rest should prefer URL, subtree, or local state. |
| `selected session` and `active engine session` as global store fields | Reviewer changed my mind, partially | I still think the underlying concern is real. The iOS split exists for a performance reason, not because SwiftUI demanded it. But the review is right that the web spec should not preserve that pattern by default before measuring. |
| `MessageCacheRepository` and `StreamCacheRepository` | Reviewer changed my mind | The persistence need is real, but the repository naming and shape are too inherited from the iOS cache layer. I would now specify persistence boundaries and cache semantics, not repository classes. |
| Service class inventory (`PairingClient`, `ProviderSocketClient`, `UploadClient`, etc.) | Reviewer changed my mind, partially | I still stand by dedicated transport adapters for WebSocket, uploads, terminal sessions, and similar lifecycle-heavy edges. I no longer think the spec should imply a full native-style service graph as the default web architecture. |
| Client-rendered Vite SPA as default | Reviewer changed my mind | This should be conditional. If the final deployment model wants same-origin auth, proxying, or a browser-safe gateway, the framework choice should follow that decision rather than pre-commit to pure SPA. |
| `Settings` as a dedicated route | I still stand by the original proposal | I read this as a minor implementation choice, not a structural transplant. A route, modal, or route-backed overlay can all work. I do not think this materially weakens the spec. |
| Explicit `ConnectionLifecycleCoordinator`-like transport state machine | I still stand by the original proposal | The review also effectively agrees here. This is one of the places where the iOS pattern is not merely inherited; it maps to a real cross-platform complexity seam and should remain explicit. |
| Detailed component noun tree (`MessageList`, `MessageRow`, `MessageBubble`, etc.) | I still stand by the original proposal, with refinement | I still think the component list is useful as an inventory of major view responsibilities. The review is right that feature ownership boundaries should be added so it does not read as mere noun decomposition. |
| `Theme tokens should map from ChatFlowTheme` | I still stand by the original proposal | I agree with the reviewer’s conclusion here. Translating existing design tokens into web tokens is natural and does not represent unhealthy pattern transplant. |

### Final Adjudication

The review materially improved the spec. The biggest corrections are:

- define ownership, not just containers
- define browser runtime invariants explicitly
- make stack recommendations conditional on deployment/auth/TLS decisions
- reduce architecture layers that do not have a clear authority

The review did not change my core conclusions:

- the port is feasible
- the chat surface is the expensive part
- the transport/state seam must stay explicit
- terminal and interactive HTML should be scope-gated
- the iOS client should be treated as a behavioral reference, not a structure to copy
