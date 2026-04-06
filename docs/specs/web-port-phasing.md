# Clawline Web Port Phasing

Date: 2026-03-30
Author: Codex
Status: Implementation planning and tooling research

This document has two jobs:

1. Rewrite the web-port migration into incremental phases where every phase ends with a runnable, testable browser app.
2. Recommend current-state tooling for an agentic build-test-fix loop for the eventual web app.

This plan is grounded in the Clawline iOS/iPad codebase already inspected in the earlier recon:

- Pairing and auth: `PairingViewModel`, `PairingView`, `AuthManager`, `ProviderConnectionService`, `ProviderBaseURLStore`, `DeviceIdentifier`
- Transport and lifecycle: `ProviderChatService`, `ConnectionLifecycleCoordinator`, `StreamAPIClient`
- Chat domain and UI: `ChatViewModel`, `ChatView`, `MessageFlowCollectionView`, `RichTextEditor`, `StreamManagerSheet`
- Rendering and attachments: `MessagePresentation`, `UnifiedMarkdownParser`, `UnifiedMarkdownRenderer`, `LinkCardMetadataFetcher`, `UploadService`
- Rich surfaces: `TerminalBubbleUIKitView`, `TerminalSessionService`, `InteractiveHTMLBubbleUIKitView`, `ExpandedMessageSheet`

The revised main spec in `web-port-recon.md` is assumed here. In particular:

- settings is an in-chat overlay, not a dedicated route
- selected session is URL-owned
- transport is an explicit state machine
- cross-tab behavior treats each browser tab as its own device/runtime
- architecture is ownership-first, with no global `uiStore`

## Part 1: Incremental Phasing Plan

## Planning Rules

Every implementation phase must satisfy all of the following:

- The app is runnable in a browser at the end of the phase.
- A human can use the app meaningfully, not just look at scaffolding.
- The previous phase’s behavior still works.
- Each phase has a clear manual test pass, automated test pass, and done definition.
- Accessibility and security are not deferred to the end if the phase introduces surface area that depends on them.

## Non-Phase Prerequisites

These are not counted as phases because they do not yield a user-visible app by themselves:

- Decide deployment topology: direct browser client vs same-origin gateway/BFF.
- Decide browser auth model: secure cookies vs browser-held tokens vs gateway-brokered auth.
- Decide TLS path: browser-trusted provider endpoint vs trusted gateway termination.
- Freeze protocol fixtures and browser runtime invariants from the revised spec.

Once those are fixed, implementation phases begin. Every phase below ends in a usable browser app.

## Phase 1: Pair, Connect, and Text Chat

### Scope

Port the minimum end-to-end slice of the iOS app that lets a user pair and chat in one browser tab.

iOS source areas covered:

- `PairingViewModel.swift`
- `PairingView.swift`
- `AuthManager.swift`
- `ProviderConnectionService.swift`
- `ProviderBaseURLStore.swift`
- `DeviceIdentifier.swift`
- `RootView.swift`
- `ProviderChatService.swift` text-message subset
- `ConnectionLifecycleCoordinator.swift` basic lifecycle subset
- `ChatViewModel.swift` text send/receive subset

### What The User Can Do

- Open the web app in a browser.
- Enter pairing info and complete first-run pairing.
- Land directly in chat after successful pairing.
- Send and receive plain text messages in the default or first available session.
- Refresh the page and remain signed in.
- Open settings as an in-chat modal/drawer and change appearance/font preferences.
- Log out and return to the pairing screen.

### Included Web Features

- `/pair` and `/chat/:sessionKey?`
- text-only message list
- text composer
- connection status banner
- auth persistence
- basic selected-session URL state
- settings overlay

### Explicitly Not In Scope Yet

- any cross-tab coordination layer
- unread/read projection
- stream CRUD
- markdown/code/table rendering
- file/image attachments
- terminal or interactive HTML
- advanced scroll restoration

### Manual Testing

- Pair from a clean browser profile.
- Refresh and confirm auth/session persistence.
- Send text and confirm echoed/acknowledged messages replace optimistic placeholders.
- Disconnect network briefly and confirm reconnect banner or disabled send state is understandable.
- Open settings overlay without leaving chat.
- Log out and confirm local auth is cleared.

### Automated Testing

- Protocol fixture tests for pairing payloads and auth payloads.
- Transport-machine tests for `idle -> connecting -> authenticating -> live` and failure paths.
- Playwright tests for pair flow, logout, send text, receive text, and settings overlay.

### Done Definition

A new user can pair the web app, hold a basic text conversation, refresh the page, and continue using the app without any manual developer intervention.

## Phase 2: Multi-Session Fidelity and Durable Reload

### Scope

Make the app behave like Clawline rather than a single-threaded demo by porting replay, session selection, unread/read projection, and durable per-tab browser runtime behavior.

iOS source areas covered:

- `ProviderChatService.swift` replay and stream snapshot handling
- `ConnectionLifecycleCoordinator.swift`
- `ChatViewModel.swift` unread/read, active session, reconnect, session provisioning subset
- `StreamSession.swift`
- `SessionRegistry.swift` behavior, but not singleton shape

### What The User Can Do

- Switch between sessions/streams using URL-backed selection.
- See unread indicators when assistant messages arrive in non-active sessions.
- Reload the page and recover prior messages and session selection quickly from durable snapshots plus replay.
- Open a second tab and keep using the app as another independent client runtime without duplicate sends or cross-tab interference.
- Go offline and recover cleanly when network returns.

### Included Web Features

- durable replay cursor handling
- persisted transcript snapshots
- unread/read projection
- per-tab selected session, per-tab live transport
- reconnect/offline handling

### Manual Testing

- Open two tabs, send from each, and confirm both behave as independent client runtimes.
- Switch sessions in each tab independently.
- Receive assistant messages in a background session and verify unread state.
- Reload either tab and verify it recovers from persisted snapshots plus replay without corrupting the other tab.
- Toggle offline/online and confirm no duplicate-send or message-order corruption.

### Automated Testing

- State-machine tests for replay and reconnect transitions.
- Projection tests for unread/read behavior and provisioning state.
- Multi-tab Playwright tests for independent per-tab connections, divergent selected-session routing, and unread/read behavior.
- Reload/reconnect tests using persisted snapshots.

### Done Definition

The app is no longer a demo chat window. It behaves like a real multi-session chat client with durable reload and stable independent-tab behavior.

## Phase 3: Stream Management and Session Provisioning

### Scope

Port the stream-management feature set so the user can control conversation structure from the browser.

iOS source areas covered:

- `StreamManagerSheet.swift`
- `StreamAPIClient.swift`
- `ProviderChatService.swift` stream events
- `ChatViewModel.swift` create/rename/delete/adopt/untrack and provisioning logic

### What The User Can Do

- View the full stream list.
- Create a new stream.
- Rename a stream.
- Delete or untrack a stream where allowed.
- Adopt/track sessions exposed by the provider.
- See when a session is provisioned, waiting, or unavailable for sending.

### Included Web Features

- stream sidebar/popover
- stream management overlay
- create/rename/delete/adopt/untrack flows
- provisioning banners and disabled-send rules

### Manual Testing

- Create, rename, and delete a stream.
- Adopt or untrack a session and verify the list updates without page reload.
- Attempt to send in a waiting or unavailable session and confirm the UI explains why.
- Reload after mutations and verify stream order/state persists.

### Automated Testing

- REST/transport contract tests for stream CRUD payloads.
- Domain-store tests for stream mutation projections and provisioning-state updates.
- Playwright tests for create/rename/delete/adopt/untrack flows.

### Done Definition

The web app can now replace the iOS app for day-to-day stream/session management, even though it still has a plain message renderer.

## Phase 4: Rich Rendering and Common Attachments

### Scope

Port the message-rendering and common-attachment layers that make Clawline conversations readable and useful.

iOS source areas covered:

- `MessagePresentation.swift`
- `UnifiedMarkdownParser.swift`
- `UnifiedMarkdownRenderer.swift`
- `Attachment.swift`
- `WireAttachment.swift`
- `UploadService.swift`
- `LinkCardMetadataFetcher.swift`
- `LinkCardUIKitView.swift`

### What The User Can Do

- Read rendered markdown, code blocks, and tables.
- Open and use link cards for URLs.
- Upload images and files.
- Paste or drag/drop common attachments into the composer.
- Open larger or detailed message content in an expanded overlay where useful.

### Included Web Features

- markdown/code/table renderer
- image/file attachments
- upload/download pipeline
- paste/drop/file-input staging
- link card previews
- expanded message overlay for longer content

### Explicitly Deferred

- full embedded terminal sessions
- interactive HTML attachments
- complex inline web preview parity

### Manual Testing

- Send a markdown-rich message and verify rendering.
- Upload an image and a document.
- Paste an image into the composer.
- Open a link card and verify metadata handling.
- Refresh mid-conversation and confirm attachments remain usable after hydration.

### Automated Testing

- Rendering acceptance tests for markdown/code/table cases.
- Upload pipeline tests for image/document flows.
- Playwright tests for paste, drag/drop, file input, and expanded-message overlay.
- Visual regression coverage for core message surfaces.

### Done Definition

The browser app is now good enough for common real-world Clawline conversations, not just plain text.

## Phase 5: Chat-Surface Maturity

### Scope

Port the hard UI/runtime behaviors that make long conversations usable: virtualization, unread anchors, scroll restoration, keyboard behavior, and responsive browser tuning.

iOS source areas covered:

- `ChatView.swift`
- `MessageFlowCollectionView.swift`
- `RichTextEditor.swift`
- related scroll/unread/layout tests in `ClawlineTests`

### What The User Can Do

- Use the app comfortably with long histories.
- Return to prior conversations without losing scroll position.
- Jump to unread or latest content reliably.
- Use the composer and navigation comfortably on desktop and iPad-class browser layouts.

### Included Web Features

- virtualized message list for large histories
- scroll restoration on reload and stream switch
- unread anchoring
- scroll-to-bottom affordance
- responsive iPad/mobile browser tuning
- keyboard flow and focus handling improvements

### Manual Testing

- Scroll deep into history, reload, and confirm restoration.
- Receive new messages while scrolled away from bottom and confirm unread/jump behavior.
- Use the composer and keyboard navigation without pointer input.
- Verify usable layout on desktop and iPad-sized breakpoints.

### Automated Testing

- Playwright tests for scroll-to-bottom affordance, unread anchors, and restore-on-reload.
- Accessibility checks for focus order, keyboard-only composer use, and announcement coverage.
- Performance smoke tests on large transcript fixtures.

### Done Definition

The web client is comfortable for primary daily use on desktop and iPad browsers, even on long-running conversations.

## Phase 6: Advanced Rich Surfaces

### Scope

Port the optional but high-cost native-rich surfaces only if product requirements justify them.

iOS source areas covered:

- `TerminalBubbleUIKitView.swift`
- `TerminalSessionService.swift`
- `TerminalSessionConnectionPool.swift`
- `InteractiveHTMLBubbleUIKitView.swift`
- `InteractiveHTMLDescriptor.swift`
- `ExpandedMessageSheet.swift`
- `LinkPreviewView.swift`

### What The User Can Do

- Open and use terminal session attachments in-browser.
- Interact with embedded HTML content inside a sandboxed surface.
- Use richer expanded views for content that does not fit the normal message bubble.

### Included Web Features

- `xterm.js`-based terminal surface
- isolated terminal connection lifecycle
- sandboxed iframe-based interactive HTML surface
- richer preview surfaces where security permits

### Manual Testing

- Open a terminal attachment, type into it, resize it, and reconnect it.
- Trigger an interactive HTML attachment and verify the postMessage bridge only allows approved actions.
- Confirm embedded content does not escape the app shell or inherit ambient credentials accidentally.

### Automated Testing

- Terminal lifecycle tests.
- Security contract tests for iframe sandboxing and postMessage handling.
- Playwright tests for terminal open/reconnect and interactive HTML happy paths.

### Done Definition

The browser app reaches near-parity on Clawline’s richest message surfaces, with security constraints tested rather than assumed.

## Cross-Phase Rule

No phase gets a free pass on regression. At the end of every phase:

- all prior automated tests still pass
- the browser app still ships as a usable product, not just a development checkpoint
- unfinished next-phase work stays behind explicit feature flags or absent UI, not half-visible broken affordances

## Suggested Release Cadence

If the team wants usable milestones rather than long branches:

- Release Phase 1 internally as the first real browser client.
- Release Phase 2 when reload, replay, and independent-tab behavior are stable enough for daily engineering use.
- Release Phase 4 as the first version suitable for broad dogfooding.
- Release Phase 5 as the first version that can plausibly replace iPad-web usage for heavy internal users.
- Treat Phase 6 as optional launch-plus scope unless terminal and interactive HTML are confirmed launch-critical.

## Part 2: Agentic Web Testing Tooling Research

Research verified on March 30, 2026, using official vendor docs, pricing pages, and product docs.

## What We Actually Need

For Clawline, an “agentic testing system” is not just a test runner. We need a loop where an agent can:

1. start or connect to a local dev server
2. open a real browser
3. interact with the app deterministically when possible
4. fall back to higher-level agentic browsing when deterministic selectors are not enough
5. capture screenshots, traces, logs, and DOM state
6. use those artifacts to patch code
7. rerun the same flow automatically

That means we need two layers:

- a deterministic regression base
- an exploratory/agent-native browser layer

AI-native test authoring can sit on top of that, but it should not replace the deterministic base.

## Recommendation Summary

If Clawline wants the strongest agent build-test-fix loop with the least architectural regret:

- Baseline deterministic layer: Playwright
- Local agent browser control: Browser Use MCP or Stagehand, depending on whether we want lower-level control or cloud-backed agent workflows
- Optional hosted browser infra: Browserbase or Browser Use Cloud
- Optional AI-authored test accelerator: Shortest first, Momentic second
- Optional passive broad regression layer: Meticulous
- Optional visual AI layer: Applitools
- Managed service option: QA Wolf only if we intentionally want outsourced suite authoring/maintenance

## Tooling Matrix

| Tool | Category | What it gives an agent | Setup complexity | Cost status | Fit for Clawline |
| --- | --- | --- | --- | --- | --- |
| Playwright | Deterministic browser automation and E2E | Real browsers, cross-browser runs, `webServer`, codegen, UI mode, trace viewer, screenshots, CI-friendly runs | Low | Free OSS | Best baseline; should be the core regression layer |
| Puppeteer + `chrome-devtools-mcp` | Lower-level Chrome/CDP automation | Good for Chrome-centric CDP automation and MCP-style control | Low-Medium | Free OSS | Secondary option only; weaker default than Playwright for cross-browser web app testing |
| Stagehand + Browserbase | Agent-friendly browser SDK plus cloud infra | Natural-language actions mixed with deterministic code; good cloud browser backing; AI-generated scripts via Director | Medium | Stagehand OSS; Browserbase plans public | Strong exploratory layer, especially if we want cloud browsers and AI-agent workflows |
| Browser Use | Agent-native browser framework + MCP + cloud browsers | Local MCP server, cloud browsers, CDP access, agent tasks, screenshots, remote sessions, OpenClaw integration docs | Medium | Public pay-as-you-go pricing | Excellent for coding-agent inner loop and remote browser sessions |
| Momentic | AI-native testing platform | Natural-language tests, local MCP server, live-browser sessions, self-healing locators, GitHub Actions support | Medium-High | No public pricing found | Strong if we want AI-native authoring and vendor workflow; less ideal as the only testing substrate |
| Shortest | AI-authored Playwright-adjacent tests | Plain-English test authoring, intelligent fixing, GitHub integration, built on Playwright | Low-Medium | $10/user/month standard | Best lightweight AI test-authoring add-on to a Playwright stack |
| Meticulous | Passive/autonomous regression from recorded flows | Auto-recorded sessions, replay in CI, diff grouping, near-zero manual test maintenance | Medium | No public pricing found | Valuable after the app exists and flows are stable; not the first inner-loop tool |
| Applitools | Visual AI and autonomous testing | AI visual diffing, autonomous/visual testing platform, cross-browser/device visual coverage | Medium-High | Public plans exist, but official page currently shows custom contact pricing | Useful for dense chat UI visual regressions if budget supports it |
| QA Wolf | Hybrid platform + managed service | AI writes deterministic Playwright/Appium code, automated maintenance, managed execution and service layer | High organizational overhead, low local setup | Public pricing model but no public dollar amount | Good if we want a vendor to own broad regression coverage; not the best primary agent loop for in-repo iteration |

## Tool-by-Tool Notes

### Playwright

Why it matters:

- It is still the strongest deterministic base for a React web app.
- Official docs support local dev-server bootstrapping with `webServer`.
- UI Mode, codegen, and Trace Viewer make failed flows inspectable by humans and agents.
- It remains the cleanest path to reproducible CI runs.

What it is best at:

- repeatable regression tests
- cross-browser coverage
- trace/screenshot artifacts
- headless and headed debugging

What it is not:

- not itself an agentic planner
- not self-healing in the vendor-marketing sense

Recommendation:

- Make Playwright the mandatory base layer for Clawline web.
- Every phase in the migration plan should add or extend Playwright coverage.

### Puppeteer + `chrome-devtools-mcp`

Why it matters:

- Puppeteer is still viable for CDP-level browser control.
- Official docs point to `chrome-devtools-mcp`, a Puppeteer-based MCP server for browser automation and debugging.

Limits:

- Chrome/CDP-first posture
- weaker fit than Playwright for cross-browser app regression

Recommendation:

- Useful as a specialized Chrome debugging tool.
- Do not make it the main test stack for Clawline.

### Stagehand + Browserbase

Why it matters:

- Stagehand is explicitly positioned for developers building browser automations and AI agents.
- It lets us mix AI actions with deterministic code instead of forcing one or the other.
- Browserbase gives hosted browser infrastructure, concurrency, session retention, and cloud execution.

Public pricing status:

- Browserbase plans are public: Free `$0`, Developer `$20`, Startup `$99`, Scale custom.
- The plan table exposes browser hours, concurrency, stealth level, and session duration limits.

Strengths for Clawline:

- strong fit for exploratory flows and “go inspect the app and figure out what changed” tasks
- good match when an agent needs a cloud browser instead of local desktop state
- can coexist with Playwright instead of replacing it

Recommendation:

- Strong option if we want an agent-native browser layer with less bespoke setup than rolling our own cloud browser infra.

### Browser Use

Why it matters:

- It now has an official local MCP server and cloud MCP option.
- It supports direct CDP browser sessions, hosted browsers, stealth, proxying, and agent tasks.
- Official docs include OpenClaw integration, which makes it especially relevant to our environment and agent workflows.

Public pricing status:

- task init: `$0.01`
- model step cost: roughly `$0.002` to `$0.05` depending on model
- direct browser sessions: `$0.06/hour` pay-as-you-go, `$0.03/hour` on higher plans

Strengths for Clawline:

- excellent for letting a coding agent open a browser, inspect state, and iterate
- good bridge between local agent tooling and remote browsers
- can pair deterministic Playwright scripts with exploratory agent sessions

Limitations:

- more agentic than deterministic by default
- Chromium/CDP path, not a full cross-browser regression replacement

Recommendation:

- Very strong choice for the exploratory layer in the Clawline agent loop.

### Momentic

Why it matters:

- It is one of the clearest AI-native testing platforms available right now.
- It supports natural-language tests, live-browser sessions, local MCP, and GitHub Actions.
- It positions itself around self-healing locators and autonomous test generation/maintenance.

Important constraints:

- Official docs currently support Chromium, Chrome, and Chrome for Testing, not Safari/Firefox.
- Official site states it does not generate or save code; its runtime stays vendor-shaped.
- No public pricing was found on official pages as of March 30, 2026.

Recommendation:

- Strong candidate if we want a vendor-hosted AI-first workflow.
- Not the best single source of truth for Clawline’s entire browser verification stack.
- Better as an augmentation layer than as the only testing substrate.

### Shortest

Why it matters:

- Built on Playwright.
- Plain-English authoring lowers the cost of spinning up new tests.
- Public pricing is simple and low relative to the enterprise platforms.

Public pricing status:

- Standard: `$10/user/month`
- 14-day free trial
- Enterprise: contact sales

Best fit:

- teams already committed to Playwright that want AI help writing and fixing tests

Recommendation:

- This is the most attractive lightweight add-on if we want AI-authored tests without handing the whole stack to a vendor platform.

### Meticulous

Why it matters:

- It records real interactions and turns them into replayed CI coverage.
- It can provide wide regression coverage with very little hand-authored test code.
- It is especially strong for “did this UI change break any recorded flows?” style protection.

Constraints:

- It is not the best first tool for agent-driven feature iteration on a greenfield web app.
- It is more valuable once the app has enough stable flows to record.
- Official site and docs did not expose public pricing as of March 30, 2026.

Recommendation:

- Add later, after Clawline web has enough real usage or stable internal dogfooding to generate meaningful recorded flows.

### Applitools

Why it matters:

- Strongest mainstream option here for AI-heavy visual testing and visual classification.
- Useful when the UI density is high and screenshot diffs are expensive to triage manually.

Public pricing status:

- official pricing page exposes Starter, Public Cloud, and Dedicated Cloud plans
- the current official page shows contact/custom pricing rather than a public dollar figure
- subscription includes both Autonomous and Eyes capabilities

Recommendation:

- Worth considering once chat rendering and visual polish are a genuine source of regressions.
- Too expensive and heavy for the very first layer unless visual regressions become a major pain quickly.

### QA Wolf

Why it matters:

- Official positioning is now clearly “agentic automated testing,” not just outsourced scripting.
- It generates deterministic Playwright/Appium code from prompts and claims automated maintenance.
- It also brings a managed-service model rather than just a tool.

Pricing status:

- Official pages describe a flat fee per test case and no cost for extra runs.
- No public dollar figure was found on official pages as of March 30, 2026.

Recommendation:

- Best if we eventually decide we want a vendor to own much of the regression-suite creation and maintenance burden.
- Not the best first choice for an in-repo, agent-runs-tests-agent-fixes loop owned by the engineering team.

## Recommended Clawline Stack

### Recommended Inner Loop

For local development and agent iteration:

1. Run the web app locally.
2. Let Playwright start or reuse the dev server.
3. Use Playwright for deterministic smoke/regression runs.
4. On ambiguity or visually messy failures, hand control to Browser Use MCP or Stagehand so the agent can inspect the live app and gather screenshots/state.
5. Patch code.
6. Rerun Playwright.

This gives us:

- deterministic pass/fail for CI
- agent-friendly live browser exploration during development
- trace and screenshot artifacts for debugging

### Recommended CI/CD Pattern

- PR gate 1: fast Playwright smoke suite on every pull request
- PR gate 2: broader Playwright suite on merge queue or protected branches
- Artifact upload: traces, screenshots, HTML reports
- Optional PR gate 3: visual regression on a small set of key chat surfaces
- Optional later gate: Meticulous replay coverage or Applitools visual AI on important surfaces

### Recommended “Agent Builds Feature -> Agent Tests -> Agent Fixes” Loop

The most practical setup for us is:

1. Deterministic substrate
   - Playwright tests live in the repo and run on every change.

2. Agent browser control
   - Browser Use MCP locally, or Stagehand with Browserbase if we want cloud browsers and more hosted infrastructure.

3. Fast artifact feedback
   - traces, screenshots, DOM snapshots, network logs

4. AI-assisted test authoring
   - Shortest first if we want a low-friction Playwright-adjacent layer
   - Momentic only if we deliberately want a deeper vendor workflow

5. Broad later-stage regression
   - Meticulous once internal dogfooding generates useful session coverage

### What I Would Actually Choose

For Clawline specifically:

- Phase 1 choice: Playwright only
- Phase 2 choice: Playwright + Browser Use MCP for agent-driven browser inspection
- Phase 3 choice: optionally add Browserbase if local browsers become a bottleneck
- Phase 4+ choice: evaluate Shortest for test authoring assistance
- Later: add Meticulous or Applitools only if regression/visual maintenance becomes the real bottleneck

I would not start with Momentic, QA Wolf, or Applitools as the first layer. They are legitimate products, but they are heavier than what a greenfield internal web port needs on day one.

## Final Recommendation

The most defensible stack for Clawline web in 2026 is:

- React web app
- Playwright as the deterministic source of truth
- Browser Use MCP or Stagehand as the agent browser-control layer
- Browserbase only if we need hosted browser capacity or better cloud browser ergonomics
- Shortest as the first AI-assisted test-authoring experiment
- Meticulous and Applitools later, after there is a real regression surface worth paying for

That stack best supports the loop we actually want:

- agent builds feature
- agent runs deterministic regression
- agent opens a real browser and inspects failures
- agent patches code
- agent reruns the same checks

without prematurely giving the whole verification stack to a vendor platform.

## Official Sources Consulted

Playwright

- https://playwright.dev/
- https://playwright.dev/docs/running-tests
- https://playwright.dev/docs/codegen
- https://playwright.dev/docs/test-webserver
- https://playwright.dev/docs/next/test-ui-mode
- https://playwright.dev/docs/next/trace-viewer
- https://playwright.dev/docs/docker

Puppeteer

- https://pptr.dev/

Stagehand / Browserbase

- https://docs.stagehand.dev/
- https://docs.browserbase.com/account/plans
- https://www.browserbase.com/blog/free-plan

Browser Use

- https://docs.browser-use.com/open-source/customize/integrations/mcp-server
- https://docs.browser-use.com/open-source/customize/browser/remote
- https://docs.browser-use.com/guides/mcp-server
- https://docs.browser-use.com/cloud/pricing
- https://docs.browser-use.com/cloud/tutorials/integrations/openclaw

Momentic

- https://momentic.ai/docs
- https://momentic.ai/docs/model-context-protocol
- https://momentic.ai/docs/ci/github-actions
- https://momentic.ai/

Shortest

- https://shortest.com/
- https://shortest.com/pricing

Meticulous

- https://www.meticulous.ai/
- https://app.meticulous.ai/docs
- https://app.meticulous.ai/docs/how-to/manually-recording-tests
- https://app.meticulous.ai/docs/how-to/detect-diffs-locally

QA Wolf

- https://www.qawolf.com/automation-ai
- https://www.qawolf.com/solutions/ios-testing

Applitools

- https://applitools.com/platform-pricing/
- https://applitools.com/platform-free-trial/
- https://applitools.com/platform-overview/
