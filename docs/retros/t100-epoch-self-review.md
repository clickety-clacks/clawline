# T100 Epoch Ownership Self-Review

Spec source reviewed: `/Users/mike/shared-workspace/clawline/specs/connection-lifecycle.md:146-155`.

1. PASS - Coordinator owns epoch as single authority.
- Evidence: `currentEpoch` is owned/mutated only in coordinator (`ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:100`, `:541-543`) and is the value handed to attempt start (`:551`).

2. PASS - `ProviderChatService` receives epoch from coordinator via `startConnectionAttempt(epoch:...)`.
- Evidence: Coordinator start handler signature includes epoch (`ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:88`), wiring forwards epoch to service (`ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:380-383`), protocol requires epoch (`ios/Clawline/Clawline/Protocols/ChatServicing.swift:62`), service entrypoint accepts epoch (`ios/Clawline/Clawline/Services/ProviderChatService.swift:353`).

3. PASS - Service echoes that epoch in all `LifecycleTransportEvent` emissions.
- Evidence: all lifecycle emissions flow through `emitLifecycleEvent(epoch:payload:)` and include explicit epoch in constructed event (`ios/Clawline/Clawline/Services/ProviderChatService.swift:895-897`).
- Call sites use attempt epoch or captured lifecycle epoch (`ios/Clawline/Clawline/Services/ProviderChatService.swift:498-505`, `:512-519`, `:536`, `:543`, `:628-636`, `:665`, `:723-731`, `:741-749`, `:759-767`, `:1021`, `:1035`).
- Coverage check: epoch-echo tests assert emitted epoch matches coordinator-provided epoch (`ios/Clawline/ClawlineTests/ProviderServiceTests.swift:297-335`, `:338-381`).

4. PASS - Service has no independent epoch counter.
- Evidence: `ProviderChatService` stores no epoch state/counter fields in its state block (`ios/Clawline/Clawline/Services/ProviderChatService.swift:199-227`); epoch appears only as method parameters/captured values on lifecycle paths (`:353`, `:496`, `:579`, `:590`, `:625`, `:663`, `:707`, `:981`, `:895`).

5. PASS - No stale epoch events can leak through.
- Evidence: coordinator drops stale events before any handling/side effects (`ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:235-239`) and also drops events when phase is `idle`/`failed` regardless of epoch (`:240-242`).
- Additional guards on downstream handlers prevent stale epoch side effects if called (`ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:278`, `:284`, `:391`, `:403`, `:417`, `:423`).

Conclusion: Epoch ownership and transport scoping conform to the epoch contract in the referenced spec section.
