# Clawline Web Integration Test Procedure

Date: 2026-05-07
Status: executable test procedure and coverage matrix

## Purpose

Validate Clawline Web as a parity client for the current Clawline iOS behavior and provider protocol. This procedure covers automated Playwright regression, manual browser/device checks where automation is weak, and evidence required before a web build is ready for Flynn verification.

This document is source material only. It does not authorize product-code changes.

## Source Baseline

Use these sources when updating the suite:

- `/Users/mike/shared-workspace/clawline/architecture.md`
- `/Users/mike/shared-workspace/clawline/ios-architecture.md`
- `/Users/mike/shared-workspace/clawline/specs/web-port-recon.md`
- `/Users/mike/shared-workspace/clawline/specs/web-port-phasing.md`
- `/Users/mike/shared-workspace/clawline/specs/clawline-replay-and-memory-pressure-invariants.md`
- `/Users/mike/shared-workspace/clawline/specs/clawline-session-status-control-api.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/clawline-invariants.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/chat-information-architecture.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/multi-stream.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/connection-lifecycle.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/connection-state-ui.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/unread-indicators.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/scroll-to-bottom-invariants.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/interactive-html-bubbles.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/terminal-bubbles.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/unified-markdown.md`
- `/Users/mike/src/clawline/ios/Clawline/Clawline/`
- `/Users/mike/src/clawline/ios/Clawline/ClawlineTests/`
- `/Users/mike/src/clawline/playwright/tests/`

Current web commands from `/Users/mike/src/clawline/package.json`:

```bash
npm run build
npm run test
npm run test:e2e
```

## Test Environment

Run from `/Users/mike/src/clawline`.

Required local tools:

- Node dependencies installed with the repo lockfile.
- Playwright browsers installed.
- Local ports available in the `18800-24999` range for fixture servers.
- No live production Clawline provider required for deterministic Playwright tests; each spec should own its HTTP and WebSocket fixture server.

Browser matrix:

- Required automated: Chromium desktop through Playwright.
- Required automated mobile emulation: iPhone-width Chromium at `390x844`.
- Required automated tablet emulation: `820x1180`.
- Required compatibility smoke: Edge Android user agent and viewport, covered by `playwright/tests/phase5-edge-compat.spec.ts`.
- Required manual: Safari on iPadOS, Safari on iPhone, and one desktop browser against the deployed smoke URL.

State isolation:

- Each Playwright scenario must use a new context or explicitly clear `localStorage`, IndexedDB, and service-worker state.
- Each fixture server must generate unique ports and deterministic `sessionKey` values.
- Fixture session keys must preserve canonical identity: `sessionKey` is the stream identity; labels and delivery targets are display/routing metadata only.

## Standard Fixtures

Every new automated scenario should start from one of these fixture shapes.

### Pair/Auth Fixture

Provide `/ws` with:

1. `pair_request` returns `pair_result` with `success`, `token`, and `userId`.
2. `auth` returns `auth_result` before stream metadata or replay.
3. Send `session_info`.
4. Send `stream_snapshot`.
5. Send replay messages oldest-to-newest.
6. Send `sync_complete` when the scenario exercises replay/live barriers.

Assertions:

- Auth payload includes `protocolVersion`, `deviceId`, `token`, and known per-stream cursors when available.
- Web never constructs DM session keys locally; it consumes provider-provided stream keys.
- On replay, `stream_snapshot` precedes replay messages.

### Stream Fixture

Provide:

- `GET /api/streams`
- `POST /api/streams`
- `PATCH /api/streams/:sessionKey`
- `DELETE /api/streams/:sessionKey`
- `GET /api/trackable-sessions`
- `POST /api/streams/adopt`
- WebSocket events: `stream_created`, `stream_updated`, `stream_deleted`, `session_info`, `stream_snapshot`

Assertions:

- Created custom streams use server-returned session keys.
- Send remains disabled until `session_info` provisions the target key.
- Delete/untrack reconciles selected URL to a valid stream.

### Attachment Fixture

Provide:

- `POST /upload` requiring `Authorization: Bearer <token>`.
- `GET /download/:assetId` requiring the same auth header.
- Inline image/document payloads over replay/live WebSocket messages.

Assertions:

- File input, paste, and drag/drop stage user-visible attachments.
- Upload response maps into outgoing message attachments.
- Downloads use authenticated display paths.

### Rich Surface Fixture

Provide message attachments:

- Interactive HTML: `application/vnd.clawline.interactive-html+json`.
- Terminal: `application/vnd.clawline.terminal-session+json`.
- Terminal WebSocket at `/ws/terminal`.

Assertions:

- Interactive HTML renders in an iframe sandbox without `allow-same-origin`.
- Network fetch from embedded HTML is blocked.
- `_resize` is honored at most once.
- Terminal uses `/ws/terminal`, not chat `/ws`.
- Terminal reconnect creates a new terminal auth attempt without changing chat connection state.

## Requirement-To-Test Matrix

| Area | Requirement / parity expectation | Existing automated coverage | Add or verify next |
| --- | --- | --- | --- |
| Pairing/auth | Clean browser pairs over `/ws`, persists token/user/device identity, routes to first provisioned stream. Auth receives `auth_result` before replay. | `playwright/tests/phase1-pairing-and-chat.spec.ts` covers pair/auth/send/reload. | Add negative auth cases: pending pairing, denied pairing, malformed protocol version, expired/revoked token UI. Assert user-facing recovery and no silent transcript mutation. |
| Provider URL/TLS | Browser can store provider address, but cannot match iOS self-signed trust or certificate pinning. | Partial via pairing address in phase specs. | Add manual browser-deployment check for HTTPS/TLS topology. Record whether same-origin gateway, trusted provider cert, or browser-held token model is in use. |
| Stream/session list | Stream list is provider-owned, ordered by provider metadata, selected session is URL-owned, and session key is identity. | `phase2-multitab.spec.ts`, `phase3-stream-management.spec.ts`, `phase5-responsive-keyboard.spec.ts`. | Add direct assertion that display rename does not change stored history key or URL session key. |
| Routing | Every send to a non-default stream includes exact provider `sessionKey`; Clawline must not use `mainDmOwnerPin` or reconstruct DM keys. | `phase2-multitab.spec.ts`, `phase5-responsive-keyboard.spec.ts` test selected-session routing. | Add Playwright fixture with provider-supplied DM key that does not match client-derived patterns. Send must target the supplied key. |
| Message history/replay | Replay cursors are per stream; finalized `s_*` events advance cursors; partial streaming events do not. `stream_snapshot` precedes replay. | `phase2-multitab.spec.ts`, `phase7-live-bug-regressions.spec.ts`. | Add `sync_complete` barrier test: live message created during replay arrives after replay with no duplicate IDs; missing-final cleanup waits for `sync_complete`. |
| Send/receive | Optimistic send is acked, echoed user message replaces local placeholder, streaming assistant updates in place, final message clears streaming state. | `phase1-pairing-and-chat.spec.ts`, `phase5-typing-indicator.spec.ts`. | Add failure/resend test: socket error marks bubble failed, resend creates a new outgoing bubble/id at tail rather than mutating the failed bubble. |
| Same-stream ordering | Same stream is FIFO; different streams can progress independently. | Partial via multi-tab send and phase1 streaming. | Add fixture with two sends to same stream and one send to side stream. Assert same-stream replies remain ordered while side-stream reply may arrive in between. |
| Read/unread | Unread is client-local. Non-active assistant messages mark unread; selecting stream clears unread to tail. Initial load/backfill does not mark whole history unread. | `phase2-multitab.spec.ts`, `phase5-scroll-unread.spec.ts`. | Add two-browser-context test proving unread is not cross-device synchronized. Add typing-indicator insertion does not increment unread. |
| Status/network state | Chat UI has only connected, reconnecting, disconnected; failed maps to disconnected. Session status API displays run/model/capability dots without inventing heartbeat state. | `phase7-live-bug-regressions.spec.ts` covers `/api/session-status` status dots and short-chat stability. | Add socket close/reconnect/offline scenario asserting no dismissible error banner and no "unresponsive" state. Add unsupported session-control response rendering if controls are exposed. |
| Attachments upload | File input, paste, and drag/drop stage attachments; uploads use `/upload`; outgoing message carries uploaded asset refs. | `phase4-attachment-upload.spec.ts`. | Add upload failure matrix: `auth_failed`, `payload_too_large`, network interruption, and retry/remove staged attachment UX. |
| Attachments display | Inline images, asset audio/video, documents, and downloads use authenticated `/download` path. | `phase4-attachment-display.spec.ts` with screenshots. | Add missing asset `404` display path and reload-after-hydration check for existing attachment URLs. |
| Rich markdown/link rendering | Markdown blocks preserve source order; code blocks, tables, highlight marks, typography classes, timestamps, and expanded overlay render consistently. Link cards ignore code-block URLs. | `phase4-rich-rendering.spec.ts`, `phase4-link-cards.spec.ts`, `phase5-flow-layout.spec.ts`. | Add streaming markdown test where code fence/table is incomplete during partials and finalizes without dropped or reordered blocks. |
| Interactive HTML | HTML surface is sandboxed, blocks network, bridge is allowlisted, `_resize` once, size lock prevents layout feedback. | `phase6-interactive-html.spec.ts`. | Add malformed/empty descriptor fallback, 256KB client rejection, iframe crash/reload equivalent if browser implementation exposes a crash hook. |
| Terminal bubbles | MIME-detected terminal attachments render via dedicated terminal runtime and `/ws/terminal`, authenticate separately, reconnect honestly. | `phase6-terminal-bubbles.spec.ts`. | Add resize message assertion, detach behavior, binary frame echo, offscreen unmount/remount behavior, and terminal auth failure UI. |
| Composer/keyboard/mobile | Keyboard send, Shift+Enter newline, Escape blur, tap-send while focused or blurred, mobile keyboard inset, popup focus retention, round send target, viewport fit. | `phase5-responsive-keyboard.spec.ts`, `phase5-edge-compat.spec.ts`. | Add manual iOS Safari keyboard checks because virtual keyboard and pointer event behavior differ from Chromium emulation. |
| Virtualization | Large transcripts keep bounded DOM, old offscreen bubbles are not mounted, active viewport remains usable. | `phase5-virtualization.spec.ts`. | Add scroll-to-specific-history-anchor with 500+ messages and rich attachments; verify DOM window bound and no duplicate IDs after hydrate. |
| Scroll restoration | Stream switch and reload preserve scroll state; scroll-to-bottom affordance appears only when scrolled away; short chats do not drift. | `phase5-scroll-unread.spec.ts`, `phase7-live-bug-regressions.spec.ts`. | Add first-activation large-stream tail-to-full expansion test with unread marker outside tail window. |
| Reconnect/offline | Offline/reconnect sends all known per-stream cursors; no duplicate sends or message-order corruption. | Partial via `phase2-multitab.spec.ts`, `phase7-live-bug-regressions.spec.ts`. | Add explicit `browserContext.setOffline(true)` flow: send disabled or queued per product rule, restore online, reconnect once, no duplicate optimistic message. |
| Multi-tab | Each tab has independent socket/runtime and selected URL; no cross-tab interference; unread is local to tab. | `phase2-multitab.spec.ts`. | Add local storage/token revocation test: logout in one tab must not silently mutate another active tab without an explicit cross-tab policy. |
| Permissions/provisioning | Send gated by provider `session_info`/provisioned keys; unprovisioned streams show unavailable/waiting state. | `phase3-stream-management.spec.ts`. | Add provisioned-to-unprovisioned live downgrade while composer contains draft; draft must remain but send disabled. |
| Stream CRUD/adopt/untrack | Create, rename, delete, track, untrack persist through reload and reconcile provider events. | `phase3-stream-management.spec.ts`. | Add 409/delete-requires-user-action and 404 stale stream responses if web exposes those errors. |
| Deep links | `/chat/:sessionKey` opens target if provisioned; invalid/unavailable keys reconcile to first valid stream with clear state. | Partial in most phase specs via URL assertions. | Add direct navigation test for valid side stream, deleted stream, unknown stream, and encoded colon-containing key. |
| Settings/theming | Appearance/font settings persist and visual surfaces remain readable in light/dark. | Phase 4/5 visual tests set `clawline-web:settings`. | Add user-facing settings overlay flow: open, change appearance/font scale, reload, verify persisted CSS variables and no layout overflow. |
| Deployment smoke | Built web artifact can pair/auth/send against live staging/production topology and preserve session routing. | Not in deterministic Playwright suite. | Add manual deployment smoke below; keep production data minimal and record exact deployed commit/URL/provider. |
| Accessibility | Chat list has live region, composer is keyboard reachable, controls have labels. | Partial in `phase5-scroll-unread.spec.ts` and `phase5-responsive-keyboard.spec.ts`. | Add axe/playwright accessibility pass for pairing, chat, stream popover, attachment controls, terminal, and interactive HTML fallback states. |

## Playwright Scenarios To Add

Add these as new specs or extend the existing phase specs. Keep fixture servers local and deterministic.

### `phase1-auth-negative.spec.ts`

Procedure:

1. Fixture returns `pair_result` failures for `pair_pending`, `pair_denied`, and `pair_rejected`.
2. Fixture returns `auth_result` failures for `auth_failed`, `token_revoked`, and `rate_limited`.
3. Navigate from clean `/pair`.
4. Assert visible actionable state, no chat route, no transcript cache, no socket retry loop faster than the expected backoff.

Pass gate:

- User sees the correct pairing/auth state.
- Stored token is absent after failed pairing/auth.
- No uncaught console errors.

### `phase2-replay-barrier-offline.spec.ts`

Procedure:

1. Pair/auth with two streams.
2. Persist cursor `s_main_1` and `s_side_1`.
3. Reload. Fixture delays replay after `auth_result` and emits a live message while replay is in progress.
4. Emit replay messages, then the live gap-fill, then `sync_complete`.
5. Use `context.setOffline(true)`, close socket, attempt a send, restore online.

Assertions:

- Auth sends `replayCursorsBySessionKey` for both streams.
- Replay messages render before live gap-fill.
- No duplicate message IDs appear.
- Missing-final/partial cleanup does not run before `sync_complete`.
- Offline state shows reconnecting/disconnected only; no "unresponsive" state.
- On online restore, reconnect happens once and sends do not duplicate.

### `phase2-cross-device-unread.spec.ts`

Procedure:

1. Open two separate browser contexts with same fixture account, not just two pages in one context.
2. Put context A on Main and context B on Side.
3. Broadcast assistant message to Side.
4. Verify context A unread increments for Side; context B active Side does not show unread.
5. Select Side in context A and verify unread clears to tail.

Pass gate:

- Unread is local runtime state, not server/global state.

### `phase3-deep-link-provisioning.spec.ts`

Procedure:

1. Navigate directly to `/chat/<encoded-side-session-key>` after auth is already stored.
2. Fixture includes that key in `stream_snapshot` and `session_info`.
3. Assert selected stream is Side and send targets Side.
4. Reload with fixture removing that key via `stream_deleted`.
5. Navigate directly to deleted/unknown key.

Pass gate:

- Valid deep link selects target.
- Deleted/unknown stream reconciles to a valid stream and explains unavailable state if applicable.

### `phase4-upload-errors.spec.ts`

Procedure:

1. Stage image, document, and pasted file.
2. Make `/upload` return `401`, `413`, `500`, then success after retry.
3. Exercise remove/retry controls.

Pass gate:

- Failed uploads do not send malformed message attachments.
- User can remove failed attachment or retry.
- Successful retry sends one message with one attachment list.

### `phase4-streaming-markdown.spec.ts`

Procedure:

1. Send partial assistant message with open code fence and `streaming: true`.
2. Update same `id` with partial table rows.
3. Finalize same `id` with complete markdown, table, code block, link, and `==highlight==`.

Pass gate:

- One message bubble updates in place.
- Final render preserves strict source order.
- Code-block URLs do not create link cards.

### `phase6-terminal-resize-detach.spec.ts`

Procedure:

1. Render terminal attachment.
2. Capture `/ws/terminal` auth payload.
3. Resize viewport and/or terminal container.
4. Click detach if exposed.
5. Close terminal socket and reconnect.

Pass gate:

- Terminal auth uses same chat token but separate `/ws/terminal`.
- Resize sends `terminal_resize` with positive rows/cols.
- Detach sends `terminal_detach` without closing chat socket.
- Reconnect increments terminal auth only.

## Manual Device Procedure

Run these after automated pass and before reporting a deployment as ready for Flynn verification.

### iPad Safari

1. Open deployed Clawline Web URL.
2. Pair or use a test account.
3. Open chat with at least Main and one side stream.
4. Focus composer; verify keyboard does not cover newest bubble or send button.
5. Tap Manage streams while keyboard is up; popover opens and composer focus behavior remains intentional.
6. Switch stream from popover; send a message; verify provider receives selected session key.
7. Rotate iPad; verify bubbles and terminal/interactive HTML do not overflow.
8. Scroll deep, switch streams, switch back; verify scroll restoration.

Evidence:

- Screenshot before and after keyboard.
- Screenshot after rotation.
- Provider/log excerpt showing `sessionKey` on send.

### iPhone Safari

1. Open same URL on iPhone-size Safari.
2. Send with round send target while composer focused.
3. Dismiss keyboard and tap send again.
4. Paste image from clipboard if available.
5. Open link card and expanded markdown overlay.
6. Verify no horizontal page scroll.

Evidence:

- Screenshot of composer with keyboard.
- Screenshot of pasted/staged attachment.
- Screenshot of rich markdown/link card.

### Desktop Deployment Smoke

1. Run or open deployed artifact.
2. Pair/auth.
3. Send `web smoke <timestamp>` to Main.
4. Send to a side/custom stream.
5. Reload and verify both messages remain.
6. Open second tab and verify independent selected session and socket.
7. Toggle network offline in devtools, then online; verify reconnect and no duplicate message.

Evidence:

- Deployed URL.
- Git commit under test.
- Browser/version.
- Screenshot of Main and side stream after reload.
- Provider log excerpt for auth, stream snapshot, send, and reconnect.

## Evidence Required For A Pass

Attach or record:

- `npm run build` output result.
- `npm run test` output result.
- `npm run test:e2e` output result.
- Playwright HTML report or trace archive for failures.
- Screenshots generated by visual specs.
- Manual Safari screenshots listed above.
- Provider fixture/live logs for pairing, auth, stream snapshot, sends, replay cursors, and terminal auth when relevant.
- Exact commit hash and deployment URL for deployment smoke.

## Pass/Fail Gates

Automated pass gate:

- `npm run build` exits 0.
- Unit tests exit 0.
- Playwright exits 0 on the required browser matrix.
- No uncaught page errors in any Playwright scenario.
- No test relies on production network except explicit deployment smoke.

Functional pass gate:

- Pairing/auth works from clean state.
- User can send/receive in Main and at least one non-default stream.
- Send payloads include the exact selected `sessionKey`.
- Reload sends per-stream cursors and restores transcripts without duplicates.
- Unread behaves locally and clears on stream visit.
- Stream CRUD/adopt/untrack behaves according to provider state.
- Attachments upload/display through authenticated paths.
- Markdown/link rendering preserves content order and avoids code-block link previews.
- Interactive HTML and terminal surfaces are sandboxed/separate-channel respectively.
- Mobile composer/keyboard is usable on real Safari devices.

Hard fail conditions:

- Any message routes to the wrong session.
- Any replay loses finalized messages or duplicates server IDs.
- Client constructs a DM key instead of consuming provider key.
- Send is enabled for an unprovisioned stream.
- Attachment download works without auth.
- Interactive HTML iframe has `allow-same-origin` or can fetch fixture network URL.
- Terminal traffic uses chat WebSocket.
- Browser shows an unsupported fourth chat liveness state such as "unresponsive."
- Mobile keyboard covers the send button or newest sent bubble.

## Current Coverage Summary

Already strong:

- Happy-path pair/auth/send/reload.
- Independent same-context tabs, routing, unread, and per-stream replay cursors.
- Stream CRUD/adopt/untrack/provisioning.
- Attachment upload and display happy paths.
- Markdown, link cards, visual rich rendering.
- Responsive/mobile keyboard basics, Edge Android compatibility.
- Scroll unread restoration, bounded virtualization, short-chat stability.
- Interactive HTML sandbox happy path.
- Terminal render/reconnect happy path.

Primary gaps:

- Negative pairing/auth and token revocation UX.
- Replay/live `sync_complete` barrier and explicit offline recovery.
- Cross-device unread independence using separate browser contexts.
- Provider-supplied non-pattern DM/deep-link routing.
- Upload/download error recovery.
- Streaming markdown finalization.
- Terminal resize/detach/binary/auth failure.
- Real Safari virtual keyboard and deployment smoke evidence.
- Accessibility audit across pairing/chat/popover/rich surfaces.

## Maintenance Rule

When a client feature is added or changed, update this document in the same shared-workspace location and add one of:

- a cited existing Playwright test file,
- a new exact Playwright scenario,
- or a named manual device check with required evidence.

Do not treat iOS-only integrations such as Watch relay, Siri/App Intents, Keychain, cert pinning, UIKit haptics, or FoundationModels salience as web parity blockers unless a web-specific requirement is written for them.

## Test Run Checklist - 2026-05-07 09:36 PDT

Correction note added 2026-05-07: this run stopped too conservatively. Unrelated iOS dirty files in canonical main are not a blocker for Clawline Web integration testing when web/package/playwright/shared test inputs are clean. See the continued run checklist below for the resumed automated gates.

Baseline:

- [x] Canonical repo: `/Users/mike/src/clawline`
- [x] Branch: `main`
- [x] Starting commit: `cd119413781d8d76dc76ddbdc94fdc916845675c`
- [x] Procedure source read before gates.
- [x] Clawline invariants read from `/Users/mike/shared-workspace/clawline/implementation_details/clawline-invariants.md`.

Automated gates:

- [x] Fetch/sync preflight attempted.
  - Command: `git status --short --branch && git rev-parse --abbrev-ref HEAD && git rev-parse HEAD`
  - Result: failed preflight before fetch/sync because the canonical checkout had uncommitted product-code changes not made by this test runner.
  - Evidence:

```text
## main...origin/main
 M ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift
 M ios/Clawline/ClawlineTests/SessionMetadataFooterHitTestingTests.swift
main
cd119413781d8d76dc76ddbdc94fdc916845675c
```

- [ ] `npm run build` - not executed; stopped after failed sync preflight.
- [ ] `npm run test` - not executed; stopped after failed sync preflight.
- [ ] `npm run test:e2e` - not executed; stopped after failed sync preflight.
- [ ] Deployed TARS smoke/hash check for `http://100.85.66.60:4173/`, `/chat/test`, and `/pair` - not executed; stopped after failed sync preflight.

Manual/device gates:

- [ ] iPhone Safari manual check - not executed; manual pending.
- [ ] iPad Safari manual check - not executed; manual pending.
- [ ] Desktop browser manual deployment check - not executed; stopped after failed sync preflight.

Failures:

- Fetch/sync preflight failed due to pre-existing uncommitted changes in product/test code under `ios/Clawline/...`. Per repo safety rules, the test runner did not fetch, pull, stash, restore, clean, or otherwise manipulate those changes.

Gaps and notes:

- No product code was edited by this test run.
- No build, unit, Playwright, or deployed smoke evidence was collected after the failed preflight.
- Deployed URL/hash evidence remains pending.

## Test Run Checklist - 2026-05-07 09:56 PDT

Baseline and scoped sync check:

- [x] Canonical repo: `/Users/mike/src/clawline`
- [x] Branch: `main`
- [x] Commit under test: `bbeecc3171d9afa5ae273cacb3acf42cbdfc6258`
- [x] Fetch/sync check passed.
  - Command: `git fetch origin && git status --short --branch && git rev-parse HEAD && git rev-parse origin/main && git rev-list --left-right --count origin/main...HEAD`
  - Evidence:

```text
## main...origin/main
bbeecc3171d9afa5ae273cacb3acf42cbdfc6258
bbeecc3171d9afa5ae273cacb3acf42cbdfc6258
0	0
```

- [x] Web-scoped dirty check passed.
  - Command: `git status --short -- package.json package-lock.json playwright.config.ts playwright src/app src/features src/lib src/main.tsx src/vite-env.d.ts src/test playwright/tests`
  - Evidence: no output.
- [x] Unrelated non-web state recorded.
  - The previous stopped run observed dirty iOS files:

```text
 M ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift
 M ios/Clawline/ClawlineTests/SessionMetadataFooterHitTestingTests.swift
```

  - Correction: those files are unrelated non-web state and are not a blocker for Clawline Web integration testing. They were not touched by this run.

Automated gates:

- [x] `npm run build` passed.
  - Command: `npm run build`
  - Evidence:

```text
> clawline-web@0.1.0 build
> tsc --noEmit && vite build

vite v7.3.1 building client environment for production...
✓ 2049 modules transformed.
dist/index.html                   0.42 kB │ gzip:   0.27 kB
dist/assets/index-DR6FtkEm.css   44.16 kB │ gzip:   8.48 kB
dist/assets/index-Q4EOroHn.js   888.25 kB │ gzip: 255.40 kB
✓ built in 1.22s
```

- [x] `npm run test` passed.
  - Command: `npm run test`
  - Evidence:

```text
Test Files  23 passed (23)
Tests       170 passed (170)
Duration    1.75s
```

  - Note: Vitest printed the known jsdom canvas warning: `Not implemented: HTMLCanvasElement's getContext() method: without installing the canvas npm package`.

- [x] `npm run test:e2e` passed.
  - Command: `npm run test:e2e`
  - Evidence:

```text
Running 29 tests using 8 workers
29 passed (15.9s)
```

- [x] Deployed TARS smoke/hash check passed for `http://100.85.66.60:4173/`.
  - Command: `curl -sS -D /tmp/clawline-web-root.headers http://100.85.66.60:4173/ -o /tmp/clawline-web-root.html; rg -o "assets/[A-Za-z0-9._/-]+" /tmp/clawline-web-root.html; shasum -a 256 /tmp/clawline-web-root.html`
  - Evidence:

```text
HTTP/1.1 200 OK
Content-Length: 415
Content-Type: text/html; charset=utf-8
Etag: "dice5d9q3rtbbj"
Last-Modified: Thu, 07 May 2026 11:00:37 GMT
Server: Caddy

assets/index-Q4EOroHn.js
assets/index-DR6FtkEm.css
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  /tmp/clawline-web-root.html
```

- [x] Deployed TARS smoke/hash check passed for `http://100.85.66.60:4173/chat/test`.
  - Command: `curl -sS -D /tmp/clawline-web-chat-test.headers http://100.85.66.60:4173/chat/test -o /tmp/clawline-web-chat-test.html; rg -o "assets/[A-Za-z0-9._/-]+" /tmp/clawline-web-chat-test.html; shasum -a 256 /tmp/clawline-web-chat-test.html`
  - Evidence:

```text
HTTP/1.1 200 OK
Content-Length: 415
Content-Type: text/html; charset=utf-8
Etag: "dice5d9q3rtbbj"
Last-Modified: Thu, 07 May 2026 11:00:37 GMT
Server: Caddy

assets/index-Q4EOroHn.js
assets/index-DR6FtkEm.css
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  /tmp/clawline-web-chat-test.html
```

- [x] Deployed TARS smoke/hash check passed for `http://100.85.66.60:4173/pair`.
  - Command: `curl -sS -D /tmp/clawline-web-pair.headers http://100.85.66.60:4173/pair -o /tmp/clawline-web-pair.html; rg -o "assets/[A-Za-z0-9._/-]+" /tmp/clawline-web-pair.html; shasum -a 256 /tmp/clawline-web-pair.html`
  - Evidence:

```text
HTTP/1.1 200 OK
Content-Length: 415
Content-Type: text/html; charset=utf-8
Etag: "dice5d9q3rtbbj"
Last-Modified: Thu, 07 May 2026 11:00:37 GMT
Server: Caddy

assets/index-Q4EOroHn.js
assets/index-DR6FtkEm.css
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  /tmp/clawline-web-pair.html
```

- [x] Deployed asset hashes match local build output.
  - Commands:
    - `shasum -a 256 dist/index.html dist/assets/index-Q4EOroHn.js dist/assets/index-DR6FtkEm.css`
    - `curl ... /assets/index-Q4EOroHn.js ...; shasum -a 256 /tmp/clawline-web-index-Q4EOroHn.js dist/assets/index-Q4EOroHn.js`
    - `curl ... /assets/index-DR6FtkEm.css ...; shasum -a 256 /tmp/clawline-web-index-DR6FtkEm.css dist/assets/index-DR6FtkEm.css`
  - Evidence:

```text
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  dist/index.html
2cad5fa61b48afef65a90d1c4ee0900d24dadbdd65c28a424b4fe1e43e46472c  /tmp/clawline-web-index-Q4EOroHn.js
2cad5fa61b48afef65a90d1c4ee0900d24dadbdd65c28a424b4fe1e43e46472c  dist/assets/index-Q4EOroHn.js
c6a4ebc77e85504995c1bba4e3533a90bc8ed815c3f440ac197f2217cb3d5cdc  /tmp/clawline-web-index-DR6FtkEm.css
c6a4ebc77e85504995c1bba4e3533a90bc8ed815c3f440ac197f2217cb3d5cdc  dist/assets/index-DR6FtkEm.css
```

Manual/device gates:

- [ ] iPhone Safari manual check - not executed; manual pending.
- [ ] iPad Safari manual check - not executed; manual pending.
- [ ] Desktop browser manual deployment check - not executed beyond HTTP smoke/hash; manual pending if visual/browser interaction evidence is required.

Failures:

- None in the automated gates run here.

Gaps and notes:

- No product code was edited.
- Only this shared-workspace procedure document was updated.
- Deployed smoke verifies HTTP reachability, SPA route fallback, served asset fingerprints, and deployed asset byte hashes matching the local build. It does not prove live provider pairing/send behavior.

## Comprehensive Integration Test Run - 2026-05-07 17:07 PDT

Scope:

- Canonical repo: `/Users/mike/src/clawline`
- Branch: `main`
- Commit under test: `d679721a9fd79444e784fd22a94351061b41954d`
- Deployment URL: `http://100.85.66.60:4173`
- Live provider URL used for desktop pairing attempt: `ws://100.85.66.60:18800/ws`
- Topology source used: `/Users/mike/shared-workspace/environment/environments.md`
  - TARS tailnet: `100.85.66.60`
  - TARS Clawline provider/WS port: `18800`
  - Web preview port: `4173`

Preflight:

- PASS - Fetch/sync check.
  - Command: `git fetch origin && git status --short --branch && git rev-parse HEAD && git rev-parse origin/main && git rev-list --left-right --count origin/main...HEAD`
  - Evidence:

```text
## main...origin/main
d679721a9fd79444e784fd22a94351061b41954d
d679721a9fd79444e784fd22a94351061b41954d
0	0
```

- PASS - Web-scoped dirty check.
  - Command: `git status --short -- package.json package-lock.json playwright.config.ts playwright src/app src/features src/lib src/main.tsx src/vite-env.d.ts src/test playwright/tests`
  - Evidence: no output.
- NOT RUN - Repository-wide cleanup.
  - Reason: not part of web integration scope and would touch unrelated agent state.
  - Observed unrelated state: `?? .build/DerivedData_ansible_t217_d679721a9f/`

Automated baseline gates:

- PASS - Build.
  - Command: `npm run build`
  - Evidence:

```text
> clawline-web@0.1.0 build
> tsc --noEmit && vite build

vite v7.3.1 building client environment for production...
✓ 2049 modules transformed.
dist/index.html                   0.42 kB │ gzip:   0.27 kB
dist/assets/index-DR6FtkEm.css   44.16 kB │ gzip:   8.48 kB
dist/assets/index-Q4EOroHn.js   888.25 kB │ gzip: 255.40 kB
✓ built in 1.21s
```

- PASS - Unit tests.
  - Command: `npm run test`
  - Evidence:

```text
Test Files  23 passed (23)
Tests       170 passed (170)
Duration    1.71s
```

  - Note: Vitest printed the known jsdom canvas warning: `Not implemented: HTMLCanvasElement's getContext() method: without installing the canvas npm package`.

- PASS - Playwright e2e.
  - Command: `npm run test:e2e`
  - Evidence:

```text
Running 29 tests using 8 workers
29 passed (17.8s)
```

- PASS - Required automated Chromium desktop matrix.
  - Evidence: full Playwright suite passed under Chromium.
- PASS - Required automated iPhone-width Chromium emulation.
  - Evidence: `phase5-responsive-keyboard.spec.ts`, `phase5-edge-compat.spec.ts`, and `phase5-flow-layout.spec.ts` mobile-width cases passed in the full Playwright run.
- PASS - Required automated tablet emulation.
  - Evidence: `phase5-responsive-keyboard.spec.ts` and `phase5-flow-layout.spec.ts` tablet-width cases passed in the full Playwright run.
- PASS - Edge Android compatibility smoke.
  - Evidence: `phase5-edge-compat.spec.ts` passed in the full Playwright run.
- PASS - No uncaught page errors in supported Playwright scenarios.
  - Evidence: full Playwright run passed; specs with page-error capture did not fail.

Requirement matrix checklist:

- PASS - Pairing/auth happy path.
  - Evidence: `phase1-pairing-and-chat.spec.ts` passed.
  - NOT RUN - Negative auth cases (`pair_pending`, denied pairing, malformed protocol version, expired/revoked token UI) because the procedure lists them as future scenarios and no such spec exists.
- NOT RUN - Provider URL/TLS manual browser-deployment check for HTTPS/TLS topology.
  - Reason: deployed smoke URL is plain HTTP on tailnet and the procedure asks for manual topology evidence beyond the deterministic suite. No supported TLS/certificate-pinning browser path was available in this run.
- PASS - Stream/session list provider ownership.
  - Evidence: `phase2-multitab.spec.ts`, `phase3-stream-management.spec.ts`, and `phase5-responsive-keyboard.spec.ts` passed.
  - NOT RUN - Explicit display-rename-does-not-change-history-key assertion because no dedicated scenario exists.
- PASS - Routing to selected provider `sessionKey`.
  - Evidence: `phase2-multitab.spec.ts` and `phase5-responsive-keyboard.spec.ts` passed.
  - NOT RUN - Provider-supplied non-pattern DM key scenario because no dedicated scenario exists.
- PASS - Message history/replay baseline.
  - Evidence: `phase2-multitab.spec.ts` reload replay cursor case and `phase7-live-bug-regressions.spec.ts` passed.
  - NOT RUN - `sync_complete` replay/live barrier scenario because no dedicated scenario exists.
- PASS - Send/receive happy path and streaming settle.
  - Evidence: `phase1-pairing-and-chat.spec.ts` and `phase5-typing-indicator.spec.ts` passed.
  - NOT RUN - Failure/resend matrix because no dedicated scenario exists.
- PASS - Same-stream and cross-stream baseline ordering.
  - Evidence: `phase1-pairing-and-chat.spec.ts` and `phase2-multitab.spec.ts` passed.
  - NOT RUN - Explicit two-same-stream plus side-stream interleaving scenario because no dedicated scenario exists.
- PASS - Read/unread baseline.
  - Evidence: `phase2-multitab.spec.ts` and `phase5-scroll-unread.spec.ts` passed.
  - NOT RUN - Two-browser-context cross-device unread proof and typing-indicator unread proof because no dedicated scenario exists.
- PASS - Status/network state baseline.
  - Evidence: `phase7-live-bug-regressions.spec.ts` passed.
  - NOT RUN - Explicit socket close/reconnect/offline and unsupported-control response scenarios because no dedicated scenario exists.
- PASS - Attachment upload happy path.
  - Evidence: `phase4-attachment-upload.spec.ts` passed.
  - NOT RUN - Upload error matrix because no dedicated scenario exists.
- PASS - Attachment display happy path.
  - Evidence: `phase4-attachment-display.spec.ts` passed.
  - NOT RUN - Missing asset `404` and reload-after-hydration attachment URL checks because no dedicated scenario exists.
- PASS - Rich markdown/link rendering.
  - Evidence: `phase4-rich-rendering.spec.ts`, `phase4-link-cards.spec.ts`, and `phase5-flow-layout.spec.ts` passed.
  - NOT RUN - Streaming markdown finalization scenario because no dedicated scenario exists.
- PASS - Interactive HTML happy path.
  - Evidence: `phase6-interactive-html.spec.ts` passed.
  - NOT RUN - Malformed descriptor, 256KB rejection, and iframe crash/reload cases because no dedicated scenario exists.
- PASS - Terminal bubble happy path.
  - Evidence: `phase6-terminal-bubbles.spec.ts` passed.
  - NOT RUN - Terminal resize/detach/binary/auth failure cases because no dedicated scenario exists.
- PASS - Composer/keyboard/mobile Chromium coverage.
  - Evidence: `phase5-responsive-keyboard.spec.ts` and `phase5-edge-compat.spec.ts` passed.
  - NOT RUN - Real iOS Safari keyboard checks because no supported physical-device Safari automation path was available in this run.
- PASS - Virtualization.
  - Evidence: `phase5-virtualization.spec.ts` passed.
  - NOT RUN - 500+ message scroll-to-history-anchor with rich attachments because no dedicated scenario exists.
- PASS - Scroll restoration baseline.
  - Evidence: `phase5-scroll-unread.spec.ts` and `phase7-live-bug-regressions.spec.ts` passed.
  - NOT RUN - Large-stream first-activation tail-to-full expansion because no dedicated scenario exists.
- PASS - Reconnect/offline baseline.
  - Evidence: `phase2-multitab.spec.ts` and `phase7-live-bug-regressions.spec.ts` passed.
  - NOT RUN - Explicit `browserContext.setOffline(true)` recovery scenario because no dedicated scenario exists.
- PASS - Multi-tab baseline.
  - Evidence: `phase2-multitab.spec.ts` passed.
  - NOT RUN - Token revocation/logout cross-tab policy because no dedicated scenario exists.
- PASS - Permissions/provisioning baseline.
  - Evidence: `phase3-stream-management.spec.ts` passed.
  - NOT RUN - Live provisioned-to-unprovisioned downgrade with draft preserved because no dedicated scenario exists.
- PASS - Stream CRUD/adopt/untrack baseline.
  - Evidence: `phase3-stream-management.spec.ts` passed.
  - NOT RUN - 409/delete-requires-user-action and 404 stale stream response scenarios because no dedicated scenario exists.
- PASS - Deep-link baseline.
  - Evidence: Playwright route assertions across phase specs passed.
  - NOT RUN - Direct valid side stream, deleted stream, unknown stream, and encoded colon-containing key matrix because no dedicated scenario exists.
- PASS - Settings/theming visual baseline.
  - Evidence: Phase 4/5 visual tests that set `clawline-web:settings` passed.
  - NOT RUN - User-facing settings drawer persistence flow because no dedicated scenario exists.
- NOT RUN - Full live deployment pair/auth/send against production topology.
  - Reason: desktop Chromium could reach the deployed web app and provider, but live pairing stopped at external approved-device/admin approval.
  - Evidence: see live/deployed desktop section below.
- PASS - Accessibility baseline.
  - Evidence: partial label/live-region coverage passed through existing Playwright and unit tests.
  - NOT RUN - Axe/accessibility audit across pairing/chat/popover/rich surfaces because no axe scenario or supported a11y audit harness is present in this procedure.

Future Playwright scenarios listed by the procedure:

- NOT RUN - `phase1-auth-negative.spec.ts`; missing spec file/scenario.
- NOT RUN - `phase2-replay-barrier-offline.spec.ts`; missing spec file/scenario.
- NOT RUN - `phase2-cross-device-unread.spec.ts`; missing spec file/scenario.
- NOT RUN - `phase3-deep-link-provisioning.spec.ts`; missing spec file/scenario.
- NOT RUN - `phase4-upload-errors.spec.ts`; missing spec file/scenario.
- NOT RUN - `phase4-streaming-markdown.spec.ts`; missing spec file/scenario.
- NOT RUN - `phase6-terminal-resize-detach.spec.ts`; missing spec file/scenario.

Live/deployed desktop checks:

- PASS - HTTP deployment smoke for `/`, `/chat/test`, and `/pair`.
  - Commands:
    - `curl -sS -D /tmp/clawline-web-root.headers http://100.85.66.60:4173/ -o /tmp/clawline-web-root.html`
    - `curl -sS -D /tmp/clawline-web-chat-test.headers http://100.85.66.60:4173/chat/test -o /tmp/clawline-web-chat-test.html`
    - `curl -sS -D /tmp/clawline-web-pair.headers http://100.85.66.60:4173/pair -o /tmp/clawline-web-pair.html`
  - Evidence:

```text
/            HTTP/1.1 200 OK  Etag: "dice5d9q3rtbbj"  Last-Modified: Thu, 07 May 2026 11:00:37 GMT
/chat/test   HTTP/1.1 200 OK  Etag: "dice5d9q3rtbbj"  Last-Modified: Thu, 07 May 2026 11:00:37 GMT
/pair        HTTP/1.1 200 OK  Etag: "dice5d9q3rtbbj"  Last-Modified: Thu, 07 May 2026 11:00:37 GMT
assets/index-Q4EOroHn.js
assets/index-DR6FtkEm.css
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  /tmp/clawline-web-root.html
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  /tmp/clawline-web-chat-test.html
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  /tmp/clawline-web-pair.html
```

- PASS - Deployed asset hashes match local build output.
  - Evidence:

```text
075f20212b2ad0e5ef49c8911cd37dbd120ff11f76d9682d8fba8b4391452763  dist/index.html
2cad5fa61b48afef65a90d1c4ee0900d24dadbdd65c28a424b4fe1e43e46472c  dist/assets/index-Q4EOroHn.js
c6a4ebc77e85504995c1bba4e3533a90bc8ed815c3f440ac197f2217cb3d5cdc  dist/assets/index-DR6FtkEm.css
2cad5fa61b48afef65a90d1c4ee0900d24dadbdd65c28a424b4fe1e43e46472c  /tmp/clawline-web-index-Q4EOroHn.js
c6a4ebc77e85504995c1bba4e3533a90bc8ed815c3f440ac197f2217cb3d5cdc  /tmp/clawline-web-index-DR6FtkEm.css
```

- PASS - Provider version endpoint reachable.
  - Command: `curl -sS -D /tmp/clawline-provider-version.headers http://100.85.66.60:18800/version -o /tmp/clawline-provider-version.json`
  - Evidence:

```text
HTTP/1.1 200 OK
{"protocolVersion":1}
```

- PASS - Desktop Chromium route/browser smoke.
  - Command: `node scratch/clawline-web-comprehensive-smoke.mjs`
  - Artifact: `scratch/clawline-web-comprehensive-smoke.json`
  - Screenshots:
    - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-root.png`
    - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-chat-test.png`
    - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-pair.png`
    - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-pairing-after-submit.png`
  - Evidence:

```json
{
  "browser": "Playwright Chromium",
  "routes": {
    "/": { "status": 200, "title": "Clawline Web", "url": "http://100.85.66.60:4173/pair" },
    "/chat/test": { "status": 200, "title": "Clawline Web", "url": "http://100.85.66.60:4173/pair" },
    "/pair": { "status": 200, "title": "Clawline Web", "url": "http://100.85.66.60:4173/pair" }
  },
  "pairing": {
    "attempted": true,
    "result": "not-completed",
    "details": [
      "AWAITING APPROVAL\n\nClawline is waiting on an approved device.\n\nThe provider accepted the request but has not approved this browser yet."
    ]
  },
  "consoleMessages": [],
  "pageErrors": []
}
```

- NOT RUN - Live provider send to Main and side/custom stream.
  - Reason: live pairing did not complete; the deployed app reached the provider and entered `AWAITING APPROVAL`, requiring an approved device/admin action outside this automation session. Without a token and provisioned stream, sending would be fake or would require manipulating provider state.
- NOT RUN - Desktop live reload transcript persistence after send.
  - Reason: depends on successful live provider send.
- NOT RUN - Desktop live second-tab independent socket after send.
  - Reason: depends on successful live provider auth/send.
- NOT RUN - Desktop live devtools offline/online reconnect.
  - Reason: depends on successful live provider auth/session.
- NOT RUN - Provider log excerpt for live send/reconnect.
  - Reason: no live send/reconnect occurred; `rg` against `/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log` for the generated pairing name returned no matching excerpt.

Manual/device checks:

- NOT RUN - iPad Safari procedure.
  - Missing capability: no supported real iPad Safari automation/control path was available in this session, and the procedure requires real Safari keyboard, rotation, screenshots, stream switching, and provider log evidence.
- NOT RUN - iPhone Safari procedure.
  - Missing capability: no supported real iPhone Safari automation/control path was available in this session, and the procedure requires real Safari keyboard, round send target, paste, rich overlay, and no-horizontal-scroll checks.
- NOT RUN - Desktop manual browser procedure beyond automated Chromium smoke.
  - Missing capability: manual desktop procedure requires completed live pairing/auth, live Main and side-stream sends, reload persistence, second-tab behavior, devtools offline/online recovery, screenshots, and provider logs. Automation reached live provider pairing but stopped at external approval.

Artifacts:

- Desktop smoke JSON: `scratch/clawline-web-comprehensive-smoke.json`
- Desktop smoke helper script: `scratch/clawline-web-comprehensive-smoke.mjs`
- Desktop screenshots:
  - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-root.png`
  - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-chat-test.png`
  - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-pair.png`
  - `scratch/clawline-web-comprehensive-2026-05-08T00-05-50-457Z-pairing-after-submit.png`
- Playwright failure report: not produced; the Playwright run passed.
- `test-results/`: present, no failure artifacts recorded for this run.

Failures:

- None in supported automated/local/deployed checks.

Gaps and notes:

- No product code was edited.
- Only this shared-workspace procedure document and untracked `scratch/` artifacts were created/updated by this comprehensive run.
- Live provider pairing was executable and attempted, but completion and send were not executable without external admin approval from an already approved device.
- The comprehensive result is therefore: automated baseline PASS, deployed HTTP/browser smoke PASS, provider reachability PASS, live provider send NOT RUN due missing approval capability, real Safari device procedures NOT RUN due missing supported device automation path.

## Live Provider Integration Continuation - 2026-05-07 17:23 PDT

Scope:

- Continued from canonical repo: `/Users/mike/src/clawline`
- Commit under test: `d85081cdaa495fd472afc4d567b7b951497f4892`
- Deployed URL: `http://100.85.66.60:4173`
- Provider URL used by the web client: `ws://100.85.66.60:18800/ws`
- Approved device ID supplied by Flynn: `9be5a139-4a76-40fc-a9d4-537c28c6e56b`
- Product code edited: none

Follow-up results:

- FAIL - Pair/auth continuation.
  - Command: `node scratch/clawline-web-live-provider-continuation.mjs`
  - Result artifact: `scratch/clawline-web-live-provider-continuation.json`
  - Proof that approval took effect once: `scratch/clawline-web-live-provider-2026-05-08T00-18-14-164Z-paired-chat.png`
  - Proof of retry failure: `scratch/clawline-web-live-provider-2026-05-08T00-19-49-237Z-pair-auth-failed.png`
  - Evidence from the second run:

```json
{
  "approvedDeviceId": "9be5a139-4a76-40fc-a9d4-537c28c6e56b",
  "baseUrl": "http://100.85.66.60:4173",
  "providerUrl": "ws://100.85.66.60:18800/ws",
  "timestamp": "2026-05-08T00-19-49-237Z",
  "pairAuth": {
    "status": "fail",
    "details": [
      "page.waitForURL: Timeout 15000ms exceeded",
      "AWAITING APPROVAL\n\nClawline is waiting on an approved device.\n\nThe provider accepted the request but has not approved this browser yet."
    ]
  }
}
```

- NOT RUN - Send to Main.
  - Reason: the first post-approval run reached authenticated chat, but the automation left the session popover open and crashed before send. The retry did not regain auth.
- NOT RUN - Send to side/custom stream.
  - Reason: depends on authenticated live chat; auth was not recoverable on the retry.
- NOT RUN - Reload persistence.
  - Reason: depends on successful live send/auth state.
- NOT RUN - Second tab independent session/socket.
  - Reason: depends on successful live auth.
- NOT RUN - Offline/online reconnect and no duplicate after reconnect.
  - Reason: depends on successful live auth and send.

Diagnosis:

- Approval was not the remaining blocker. It took effect once. The first continuation run reached the authenticated chat screen, and TARS allowlist state showed `tokenDelivered=true` for device `9be5a139-4a76-40fc-a9d4-537c28c6e56b`.
- The first run failed due an automation issue: the session popover backdrop intercepted the send button click, so no Main send evidence was produced before the ephemeral Playwright context was lost.
- Retrying with the same approved device ID but no persisted auth token did not redeliver auth. The gateway classified the request as an account switch and returned to pending approval.
- TARS allowlist evidence:

```json
{
  "deviceId": "9be5a139-4a76-40fc-a9d4-537c28c6e56b",
  "userId": "flynn",
  "isAdmin": true,
  "tokenDelivered": true,
  "lastSeenAt": 1778199525713
}
```

- TARS pending evidence after retry:

```json
{
  "entries": [
    {
      "deviceId": "9be5a139-4a76-40fc-a9d4-537c28c6e56b",
      "claimedName": "web comprehensive",
      "deviceInfo": { "platform": "Web", "model": "MacIntel" },
      "requestedAt": 1778199620680
    }
  ],
  "version": 1
}
```

- Gateway log excerpt:

```text
2026-05-07T17:18:45.681-07:00 [plugins] [clawline:http] pair_request_allowlist_entry web comprehensive 2026-05-08t00-05-50-457z (Web/MacIntel) [deviceId: 9be5a139-4a76-40fc-a9d4-537c28c6e56b] userId=flynn isAdmin=true tokenDelivered=undefined lastSeenAt=1778199393855
2026-05-07T17:20:20.678-07:00 [plugins] [clawline:http] pair_request_allowlist_entry web comprehensive 2026-05-08t00-05-50-457z (Web/MacIntel) [deviceId: 9be5a139-4a76-40fc-a9d4-537c28c6e56b] userId=flynn isAdmin=true tokenDelivered=true lastSeenAt=1778199525713
2026-05-07T17:20:20.680-07:00 [plugins] [clawline:http] pair_request_account_switch
```

- Provider health also degraded during continuation:
  - Command from eezo: `curl --max-time 3 -sS -D - http://100.85.66.60:18800/version -o -`
  - Result: timed out after 3002 ms.
  - Command on TARS: `curl --max-time 3 -sS -D - http://127.0.0.1:18800/version -o -`
  - Result: timed out after 3002 ms.
  - TARS process evidence: `node` PID `54460` was still listening on `*:18800`, but the `/version` endpoint was not servicing requests.

Notes:

- I did not restart the gateway, modify provider state, or touch launchd/LaunchAgents.
- The next executable live-provider step needs either a fresh approval/token delivery path for a new browser device ID or a supported way to reuse the token delivered during the first successful post-approval auth.

## Live Provider Integration Retry - 2026-05-07 17:33 PDT

Scope:

- Continued from canonical repo: `/Users/mike/src/clawline`
- Commit under test: `7fbef63f02b1f0c70c4d3e39a1b8a7a4b44828da`
- Deployed URL: `http://100.85.66.60:4173`
- Deployed assets observed: `assets/index-Q4EOroHn.js`, `assets/index-DR6FtkEm.css`
- Provider URL used by the web client: `ws://100.85.66.60:18800/ws`
- Approved device ID: `9be5a139-4a76-40fc-a9d4-537c28c6e56b`
- Product code edited: none
- Test automation updated only under `scratch/` to dismiss popovers before send, write Playwright storage state immediately after auth, and reuse that state for authenticated follow-up steps.

Provider health:

- PASS - Deployed web app root responded.
  - Command: `curl --max-time 5 -sS -D - http://100.85.66.60:4173/ -o /tmp/clawline-web-root.retry.html`
  - Evidence: `HTTP/1.1 200 OK`
- PASS - Provider `/version` responded from eezo.
  - Command: `curl --max-time 5 -sS -D - http://100.85.66.60:18800/version -o -`
  - Evidence: `HTTP/1.1 200 OK`, body `{"protocolVersion":1}`
- PASS - Provider `/version` responded locally on TARS.
  - Command: `ssh mike@tars 'curl --max-time 5 -sS -D - http://127.0.0.1:18800/version -o -'`
  - Evidence: `HTTP/1.1 200 OK`, body `{"protocolVersion":1}`

Live browser results:

- PASS - Pair/auth after approval.
  - Fresh post-approval run command: `node scratch/clawline-web-live-provider-continuation.mjs`
  - Authenticated screenshot: `scratch/clawline-web-live-provider-2026-05-08T00-27-04-203Z-paired-chat.png`
  - Storage state saved immediately after auth: `scratch/clawline-web-live-provider-2026-05-08T00-27-04-203Z-storage-state.json`
  - Follow-up authenticated command: `CLAWLINE_STORAGE_STATE=scratch/clawline-web-live-provider-2026-05-08T00-29-24-592Z-storage-state.json node scratch/clawline-web-live-provider-continuation.mjs`
  - Follow-up result artifact: `scratch/clawline-web-live-provider-continuation.json`
  - Evidence:

```json
{
  "pairAuth": {
    "status": "pass",
    "details": [
      "url=http://100.85.66.60:4173/chat/agent:main:clawline:flynn:s_41b510d1",
      "reusedStorageState=scratch/clawline-web-live-provider-2026-05-08T00-29-24-592Z-storage-state.json",
      "session={\"claimedName\":\"Web Comprehensive\",\"deviceId\":\"9be5a139-4a76-40fc-a9d4-537c28c6e56b\",\"isAdmin\":true,\"serverUrl\":\"ws://100.85.66.60:18800/ws\",\"userId\":\"flynn\",\"tokenPresent\":true}"
    ]
  }
}
```

- PASS - Send to Main.
  - Message: `web live main 2026-05-08T00-30-56-012Z`
  - Screenshot: `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-main-send.png`
  - Browser evidence: `visibleCount=1`, URL `http://100.85.66.60:4173/chat/agent:main:clawline:flynn:s_41b510d1`
  - TARS gateway log evidence:

```text
2026-05-07T17:31:17.580-07:00 [plugins] [clawline:http] ws_message_received
2026-05-07T17:31:17.596-07:00 [plugins] [clawline] processClientMessage_stage: persist_user_message
2026-05-07T17:31:17.598-07:00 [plugins] [clawline] processClientMessage_stage: send_ack
2026-05-07T17:31:17.600-07:00 [plugins] [clawline] processClientMessage_stage: broadcast_user_message
2026-05-07T17:31:17.602-07:00 [plugins] [clawline] outbound_delivery_send_ok
```

- NOT RUN - Send to side/custom stream.
  - Reason: automation tried every listed non-active stream and then a newly created custom stream; the composer send control remained disabled for all candidates.
  - Screenshot: `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-side-send-disabled.png`
  - Evidence excerpt:

```json
{
  "sideSend": {
    "status": "not-run",
    "details": [
      "selected={\"sessionKey\":\"agent:main:clawline:flynn:s_905e4dd1\",\"text\":\"created stream\"}",
      "attempted=[{\"text\":\"Harness\",\"sessionKey\":\"agent:main:clawline:flynn:s_4a2b448d\",\"sendEnabled\":false},{\"text\":\"Rebase\",\"sessionKey\":\"agent:main:clawline:flynn:s_105e446e\",\"sendEnabled\":false},{\"text\":\"Clawline Web\",\"sessionKey\":\"agent:main:clawline:flynn:s_fb998034\",\"sendEnabled\":false},{\"text\":\"Personal\",\"sessionKey\":\"agent:main:clawline:flynn:main\",\"sendEnabled\":false},{\"text\":\"Global DM1\",\"sessionKey\":\"agent:main:main\",\"sendEnabled\":false}]",
      "Send disabled for selected stream"
    ]
  }
}
```

- FAIL - Reload persistence after Main send.
  - Expected: reloading the Main URL should replay or restore `web live main 2026-05-08T00-30-56-012Z`.
  - Actual: message disappeared after reload.
  - Screenshot: `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-after-reload.png`
  - Browser evidence: `mainCount=0`, URL `http://100.85.66.60:4173/chat/agent:main:clawline:flynn:s_41b510d1`
  - Gateway replay evidence:

```text
2026-05-07T17:32:03.071-07:00 [plugins] [clawline:http] ws_message_received
2026-05-07T17:32:03.073-07:00 [plugins] replay_request
2026-05-07T17:32:03.073-07:00 [plugins] replay_start
2026-05-07T17:32:03.097-07:00 [plugins] replay_complete
2026-05-07T17:32:03.115-07:00 [plugins] replay_send
```

- PASS - Second tab independent session/socket.
  - Screenshot: `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-second-tab.png`
  - Evidence: URL `http://100.85.66.60:4173/chat/agent:main:clawline:flynn:s_41b510d1`, `sessionDevice=9be5a139-4a76-40fc-a9d4-537c28c6e56b`

- FAIL - Offline/online reconnect and no duplicate after reconnect.
  - Expected: after offline/online, the Main message count should remain stable with no duplicate or disappearance.
  - Actual: `mainMessageCountBefore=1`, `mainMessageCountAfter=0`.
  - Screenshot: `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-after-offline-online.png`

Additional diagnostics:

- The direct re-pair after the first successful auth still returned `AWAITING APPROVAL` because the provider had already marked the token as delivered for this device. This did not block the continuation because the saved Playwright storage state was reused.
- TARS allowlist after the retry showed the approved device with `userId=flynn`, `isAdmin=true`, `tokenDelivered=true`, and updated `lastSeenAt`.
- TARS pending state was repopulated by the direct re-pair attempt for the same device ID:

```json
{
  "entries": [
    {
      "deviceId": "9be5a139-4a76-40fc-a9d4-537c28c6e56b",
      "claimedName": "web comprehensive",
      "deviceInfo": { "platform": "Web", "model": "MacIntel" },
      "requestedAt": 1778200126961
    }
  ],
  "version": 1
}
```

- Browser console warnings during live auth/replay repeatedly included:

```text
clawline transport dropped payload Error: Unsupported server payload type: sync_complete ... {"type":"sync_complete"}
```

Artifacts:

- Script: `scratch/clawline-web-live-provider-continuation.mjs`
- Latest JSON result: `scratch/clawline-web-live-provider-continuation.json`
- Latest command output: `scratch/clawline-web-live-provider-continuation-output.txt`
- Latest storage state: `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-storage-state.json`
- Latest screenshots:
  - `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-paired-chat.png`
  - `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-main-send.png`
  - `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-side-send-disabled.png`
  - `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-after-reload.png`
  - `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-second-tab.png`
  - `scratch/clawline-web-live-provider-2026-05-08T00-30-56-012Z-after-offline-online.png`

Notes:

- I did not restart the gateway, change provider state, touch launchd/LaunchAgents, or edit product code.
- The remaining failures appear to be live app/provider behavior rather than approval availability: Main send is accepted and acked, but the new message does not survive reload/reconnect in the browser replay path; side/custom sends are not executable because all tested non-active/custom streams were unprovisioned or otherwise composer-disabled.

## Account Isolation Correction / Fresh Device Pending - 2026-05-07 22:19 PDT

Scope:

- Flynn primary account/browser-token traffic is stopped for Clawline Web live integration validation.
- Existing scratch storage-state files produced under `userId=flynn` are treated as contaminated and will not be reused.
- Live validation is moved to a fresh non-primary device under the dedicated test account path.
- No launchd/systemd/cron/LaunchAgent/persistence changes were made.

Code/test/deploy evidence before fresh live approval:

- Repo: `/Users/mike/src/clawline`
- Commit pushed to `origin/main`: `c92577f429` (`Provision confirmed stream mutations for web sends`)
- Product change: provider-confirmed stream upserts now add the stream key to `provisionedSessionKeys`, so created/adopted stream rows are immediately send-capable instead of remaining composer-disabled.
- Local account isolation cleanup: `playwright/tests/phase3-stream-management.spec.ts` now uses `clawline_web_test` session/user identifiers, not Flynn identifiers.
- Gates:
  - `npm run build` PASS; deployed bundle asset `assets/index-DXwkBTdM.js`.
  - `npm run test` PASS; 23 files, 171 tests.
  - `npm run test:e2e` PASS; 30 tests.
- TARS deploy command: `rsync -a --delete dist/ mike@tars:'/Users/mike/Library/Application\\ Support/ClawlineWeb/dist/'`
- Deployed root/hash check:
  - Command: `curl --max-time 5 -sS -D - http://100.85.66.60:4173/ -o /tmp/clawline-web-root.c92577f.html && rg -o 'assets/[A-Za-z0-9._/-]+' /tmp/clawline-web-root.c92577f.html && shasum -a 256 /tmp/clawline-web-root.c92577f.html dist/index.html dist/assets/index-DXwkBTdM.js dist/assets/index-DR6FtkEm.css`
  - Evidence: HTTP 200; assets `assets/index-DXwkBTdM.js`, `assets/index-DR6FtkEm.css`
  - `index.html` SHA-256: `eca0d190936280c29fe4238cab282c8c1aa743b2db373b19408638524dda1f0b`
  - JS SHA-256: `d1c0ed781767d74b29196692bc329a3cf18d66c471b81f4bd8161c9ffaf9c680`
  - CSS SHA-256: `c6a4ebc77e85504995c1bba4e3533a90bc8ed815c3f440ac197f2217cb3d5cdc`

Fresh dedicated live-device attempt:

- Command: `DEVICE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]'); echo "$DEVICE_ID" > scratch/clawline-web-test-device-current.txt; CLAWLINE_DEVICE_ID=$DEVICE_ID CLAWLINE_CLAIMED_NAME='Clawline Web Test Fresh' node scratch/clawline-web-live-provider-continuation.mjs`
- Fresh device ID: `da49d87f-60a5-4a72-b543-4f1da80200db`
- Claimed name: `clawline web test fresh`
- Result: NOT RUN past auth; provider accepted pair request but requires approval.
- Browser evidence:

```json
{
  "approvedDeviceId": "da49d87f-60a5-4a72-b543-4f1da80200db",
  "pairAuth": {
    "status": "fail",
    "details": [
      "page.waitForURL: Timeout 15000ms exceeded",
      "AWAITING APPROVAL ... The provider accepted the request but has not approved this browser yet."
    ]
  }
}
```

- TARS pending evidence:

```json
{
  "deviceId": "da49d87f-60a5-4a72-b543-4f1da80200db",
  "claimedName": "clawline web test fresh",
  "deviceInfo": { "platform": "Web", "model": "MacIntel" },
  "requestedAt": 1778217578078
}
```

Artifacts:

- Pending run screenshot: `scratch/clawline-web-live-provider-2026-05-08T05-19-05-375Z-pair-auth-failed.png`
- Latest live JSON artifact: `scratch/clawline-web-live-provider-continuation.json`
- Fresh device marker: `scratch/clawline-web-test-device-current.txt`

Next supported step:

- Approve fresh device `da49d87f-60a5-4a72-b543-4f1da80200db` for `userId=clawline_web_test` / admin test account, then rerun live pair/auth, Main send, reload persistence, second tab, offline/online reconnect, and side/custom only if the dedicated account receives or can create a provisioned non-primary stream.

## Fresh Dedicated Account Live Validation - 2026-05-07 22:26 PDT

Scope:

- Live validation used only the fresh non-primary Clawline Web test device/account:
  - `deviceId=da49d87f-60a5-4a72-b543-4f1da80200db`
  - `userId=clawline_web_test`
  - claimed name `Clawline Web Test Fresh`
- No Flynn browser token, Flynn storage state, or Flynn account was used for this run.
- Existing Flynn-derived scratch storage-state files remain treated as contaminated and were not reused.
- No launchd/systemd/cron/LaunchAgent/persistence changes were made.

Commit/deploy under test:

- Repo: `/Users/mike/src/clawline`
- Commit: `c92577f42935ab50b39cef43a1e5eee362ad07cc`
- `origin/main...HEAD`: `0 0`
- Deployed URL: `http://100.85.66.60:4173`
- Deployed assets:
  - `assets/index-DXwkBTdM.js`
  - `assets/index-DR6FtkEm.css`
- Deployed hash evidence:
  - `/`, `/chat/test`, and `/pair` each returned HTTP 200 from Caddy.
  - `index.html` SHA-256 for all three routes: `eca0d190936280c29fe4238cab282c8c1aa743b2db373b19408638524dda1f0b`
  - JS SHA-256: `d1c0ed781767d74b29196692bc329a3cf18d66c471b81f4bd8161c9ffaf9c680`
  - CSS SHA-256: `c6a4ebc77e85504995c1bba4e3533a90bc8ed815c3f440ac197f2217cb3d5cdc`

Local gates:

- PASS - `npm run build`
  - Evidence: Vite built `dist/assets/index-DXwkBTdM.js`; chunk-size warning only.
- PASS - `npm run test`
  - Evidence: 23 files, 171 tests passed.
  - Note: jsdom still logs `HTMLCanvasElement.getContext()` not implemented; test exit was green.
- PASS - `npm run test:e2e`
  - Evidence: 30 Playwright tests passed.
- PASS - Focused phase 3 stream-management e2e after account isolation/test contract update.
  - Evidence: `npm run test:e2e -- playwright/tests/phase3-stream-management.spec.ts` passed.

Fresh live run command:

```bash
CLAWLINE_STORAGE_STATE=scratch/clawline-web-live-provider-2026-05-08T05-21-47-988Z-storage-state.json \
CLAWLINE_DEVICE_ID=da49d87f-60a5-4a72-b543-4f1da80200db \
CLAWLINE_CLAIMED_NAME='Clawline Web Test Fresh' \
CLAWLINE_EXPECTED_USER_ID=clawline_web_test \
node scratch/clawline-web-live-provider-continuation.mjs
```

Fresh live result artifact:

- JSON: `scratch/clawline-web-live-provider-continuation.json`
- Storage state produced under the test account only: `scratch/clawline-web-live-provider-2026-05-08T05-25-39-920Z-storage-state.json`
- Screenshots:
  - `scratch/clawline-web-live-provider-2026-05-08T05-25-39-920Z-paired-chat.png`
  - `scratch/clawline-web-live-provider-2026-05-08T05-25-39-920Z-main-send.png`
  - `scratch/clawline-web-live-provider-2026-05-08T05-25-39-920Z-after-reload.png`
  - `scratch/clawline-web-live-provider-2026-05-08T05-25-39-920Z-second-tab.png`
  - `scratch/clawline-web-live-provider-2026-05-08T05-25-39-920Z-after-offline-online.png`

Fresh live results:

- PASS - Pair/auth.
  - URL: `http://100.85.66.60:4173/chat/agent:main:clawline:clawline_web_test:main`
  - Session evidence:

```json
{
  "claimedName": "Clawline Web Test Fresh",
  "deviceId": "da49d87f-60a5-4a72-b543-4f1da80200db",
  "isAdmin": true,
  "serverUrl": "ws://100.85.66.60:18800/ws",
  "userId": "clawline_web_test",
  "tokenPresent": true
}
```

- PASS - Main send.
  - Message: `web live main 2026-05-08T05-25-39-920Z`
  - Browser evidence: `visibleCount=1`, URL `http://100.85.66.60:4173/chat/agent:main:clawline:clawline_web_test:main`
  - TARS log evidence around the fresh run included:

```text
2026-05-07T22:26:16.981-07:00 [plugins] [clawline] processClientMessage_stage: persist_user_message
2026-05-07T22:26:16.983-07:00 [plugins] [clawline] processClientMessage_stage: send_ack
2026-05-07T22:26:16.983-07:00 [plugins] [clawline] processClientMessage_stage: broadcast_user_message
2026-05-07T22:26:16.984-07:00 [plugins] [clawline] outbound_delivery_send_ok
```

- PASS - Reload persistence.
  - Evidence: `mainCount=1`, `sideCount=0`, URL stayed `http://100.85.66.60:4173/chat/agent:main:clawline:clawline_web_test:main`.
- PASS - Second tab independent session/socket.
  - Evidence: second tab URL `http://100.85.66.60:4173/chat/agent:main:clawline:clawline_web_test:main`, `sessionDevice=da49d87f-60a5-4a72-b543-4f1da80200db`.
- PASS - Offline/online reconnect and no duplicate/disappearance.
  - Evidence: `mainMessageCountBefore=1`, `mainMessageCountAfter=1`.
  - The live runner now waits for the specific message to reappear after reconnect instead of taking a fixed early sample.
- NOT RUN - Side/custom live send.
  - Reason: under the dedicated `clawline_web_test` account, the live provider exposed only `Personal` and `Global DM`.
  - Evidence:

```json
{
  "streams": [
    { "text": "Personal", "sessionKey": null },
    { "text": "Global DM", "sessionKey": null }
  ],
  "sideSend": {
    "status": "not-run",
    "details": [
      "No dedicated test-account side/custom stream was available; stream creation skipped to avoid primary-account leakage",
      "attempted=[{\"text\":\"Global DM\",\"skipped\":\"global stream is not a dedicated test-account side/custom stream\"}]"
    ]
  }
}
```

Notes:

- The scratch live runner was guarded so side/custom sends only target session keys containing `:clawline_web_test:` and does not create provider streams during live validation by default.
- A diagnostic non-primary run confirmed the provider replay eventually returns the dedicated account messages; an earlier offline failure was a fixed-short-wait sampling issue, not a remaining disappearance once reconnect/replay settled.
- Comprehensive procedure status is green for supported automated/local/deployed/live desktop checks. Side/custom live send remains explicitly unproven for the dedicated account because the provider did not expose a dedicated side/custom stream without risking primary-account leakage.

## Dedicated Side/Custom Stream Proof - 2026-05-08 00:15 PDT

Scope:

- Continued the side/custom gap under the fresh non-primary test account only:
  - `deviceId=da49d87f-60a5-4a72-b543-4f1da80200db`
  - `userId=clawline_web_test`
- No Flynn account, Flynn storage state, Flynn token, or Flynn/non-test stream was used.
- No launchd/systemd/cron/LaunchAgent/persistence changes were made.

Provider/API findings:

- Direct stream API calls with the dedicated token return `auth_failed: No connected sessions` when no fresh browser WebSocket session is connected.
- With the fresh `clawline_web_test` browser session connected, `POST /api/streams` safely created test-owned custom streams under the dedicated account namespace.
- Created stream used for proof:
  - `agent:main:clawline:clawline_web_test:s_41b3bdb1`
  - Display name: `Web live side 2026-05-08T07-04-18-970Z`
- Safety guard: the live runner aborted/declined targeting unless the route key contained `:clawline_web_test:`.

Product fix shipped for side reload persistence:

- Commit pushed to `origin/main`: `86aa173b016f6ba088417426ac5111ac529aef42`
- Change: replay reset now preserves already-authoritative server transcript rows as a bridge when replay sends no rows for a session; if replay does send rows for that session, preserved server rows are discarded and rebuilt from replay so stale history still clears.
- Prior deployed behavior on the same test-owned side stream:
  - side send visible: PASS
  - side route reload: FAIL, ready-card/no-message state (`reloadCount=0`)
  - side reconnect: PASS
- This matched the product invariant that replay must not strand chats at the ready card.

Local gates after fix:

- PASS - `npm run build`
  - Built asset: `dist/assets/index-C4oNo-t-.js`
- PASS - `npm run test`
  - 23 files, 171 tests passed.
- PASS - focused tests:
  - `npm run test -- src/runtime/chat/chatDomainStore.test.ts src/runtime/transport/transportMachine.test.ts`
  - `npm run test:e2e -- playwright/tests/phase7-live-bug-regressions.spec.ts playwright/tests/phase3-stream-management.spec.ts`
- PASS - full e2e rerun:
  - `npm run test:e2e`
  - 30 tests passed.
- Note: the first full e2e run had one unrelated 25-pixel responsive screenshot mismatch; immediate focused rerun of that test passed, and the subsequent full e2e run passed.

TARS deploy/hash evidence:

- Deploy command: `rsync -a --delete dist/ mike@tars:'/Users/mike/Library/Application\\ Support/ClawlineWeb/dist/'`
- Root check: `curl --max-time 5 -sS -D - http://100.85.66.60:4173/ -o /tmp/clawline-web-root.86aa173b.html`
- HTTP evidence: `HTTP/1.1 200 OK`, `Server: Caddy`
- Deployed assets:
  - `assets/index-C4oNo-t-.js`
  - `assets/index-DR6FtkEm.css`
- SHA-256:
  - `index.html`: `23abd8a1183f46ea81c8bb6a7edb9be7a4c2c1b13ba9993d42a743143c59f15a`
  - JS: `2b582fadd47d4a31af324f4ac0bf93460e13d2a364e96dc6e504832d6d183630`
  - CSS: `c6a4ebc77e85504995c1bba4e3533a90bc8ed815c3f440ac197f2217cb3d5cdc`

Live side/custom proof:

- Side send command:

```bash
CLAWLINE_STORAGE_STATE=scratch/clawline-web-live-provider-2026-05-08T07-03-25-837Z-storage-state.json \
CLAWLINE_DEVICE_ID=da49d87f-60a5-4a72-b543-4f1da80200db \
CLAWLINE_CLAIMED_NAME='Clawline Web Test Fresh' \
CLAWLINE_EXPECTED_USER_ID=clawline_web_test \
CLAWLINE_ALLOW_TEST_STREAM_CREATE=1 \
node scratch/clawline-web-live-provider-continuation.mjs
```

- Side send result before the reload fix:

```json
{
  "sideSend": {
    "status": "pass",
    "details": [
      "selected={\"sessionKey\":\"agent:main:clawline:clawline_web_test:s_41b3bdb1\",\"text\":\"Web live side 2026-05-08T07-04-18-970Z\",\"createdViaApi\":true}",
      "visibleCount=1",
      "url=http://100.85.66.60:4173/chat/agent:main:clawline:clawline_web_test:s_41b3bdb1"
    ]
  }
}
```

- Focused deployed side reload/reconnect proof after `86aa173b016f6ba088417426ac5111ac529aef42`:
  - Storage state: `scratch/clawline-web-live-provider-2026-05-08T07-04-18-970Z-storage-state.json`
  - URL: `http://100.85.66.60:4173/chat/agent:main:clawline:clawline_web_test:s_41b3bdb1`
  - Message: `web live side 2026-05-08T07-04-18-970Z`
  - Result:

```json
{
  "status": "pass",
  "commit": "86aa173b01",
  "sideKey": "agent:main:clawline:clawline_web_test:s_41b3bdb1",
  "sideMessage": "web live side 2026-05-08T07-04-18-970Z",
  "session": {
    "deviceId": "da49d87f-60a5-4a72-b543-4f1da80200db",
    "userId": "clawline_web_test",
    "isAdmin": true,
    "tokenPresent": true
  },
  "initialCount": 1,
  "reloadCount": 1,
  "beforeReconnectCount": 1,
  "afterReconnectCount": 1
}
```

- Focused screenshots:
  - `scratch/clawline-web-side-focused-2026-05-08T07-14-86aa173b-initial.png`
  - `scratch/clawline-web-side-focused-2026-05-08T07-14-86aa173b-after-reload.png`
  - `scratch/clawline-web-side-focused-2026-05-08T07-14-86aa173b-after-reconnect.png`
- TARS log evidence around the side run included:

```text
2026-05-08T00:04:25.948-07:00 [plugins] [clawline] processClientMessage_stage: persist_user_message
2026-05-08T00:04:25.951-07:00 [plugins] [clawline] processClientMessage_stage: send_ack
2026-05-08T00:04:25.953-07:00 [plugins] [clawline] processClientMessage_stage: broadcast_user_message
2026-05-08T00:15:12.922-07:00 [plugins] replay_request
2026-05-08T00:15:12.926-07:00 [plugins] replay_send
```

Status:

- PASS - Dedicated test-account side/custom stream can be provisioned safely via provider API while the test browser session is connected.
- PASS - Dedicated side/custom send under `clawline_web_test`.
- PASS - Dedicated side/custom reload persistence after deployed web fix.
- PASS - Dedicated side/custom offline/online reconnect persistence after deployed web fix.
- Remaining manual gap: real iPhone/iPad Safari checks are still not executed in this automated pass.

## Manual Safari Verification Packet - 2026-05-08 01:00 PDT

Purpose: make the remaining real-device Safari gap executable without reopening automated/product-code work.

Current deployed target:

- URL: `http://100.85.66.60:4173/`
- TARS route checks to use on device: `/`, `/pair`, `/chat/agent:main:clawline:clawline_web_test:main`
- Deployed assets observed: `assets/index-C4oNo-t-.js`, `assets/index-DR6FtkEm.css`
- Source checkout observed on eezo: `/Users/mike/src/clawline` at `8d92da26432531a0119cbb0c3b4af29ae518c448` (`origin/main...HEAD = 0 0`)
- Prior automated/live proof already green under `clawline_web_test`: build, unit, e2e, Main send/reload/reconnect, and dedicated side/custom send/reload/reconnect.

Account/device rule:

- Do not use Flynn primary account/token/storage for these checks.
- Pair as a dedicated test device/account, preferably `userId=clawline_web_test`.
- If a new device appears in `pending.json`, approve only that exact test device ID as `clawline_web_test` and record it here.

### iPhone Safari manual checklist

- [ ] Open `http://100.85.66.60:4173/` in Safari on iPhone.
- [ ] Pair as a fresh non-primary test device.
- [ ] Confirm the app lands in `clawline_web_test` chat, not Flynn.
- [ ] Send a Main message with text `iphone safari web smoke <timestamp>`.
- [ ] Reload Safari page; confirm the message remains visible.
- [ ] Toggle airplane mode or disconnect/reconnect network; confirm the message remains visible with no duplicate.
- [ ] Confirm the round send button works while keyboard is focused.
- [ ] Dismiss keyboard and tap send again on a new draft; confirm no keyboard-cover/send-button regression.
- [ ] Confirm there is no horizontal page scroll.
- [ ] Capture screenshot of composer with keyboard and screenshot after reload/reconnect.

### iPad Safari manual checklist

- [ ] Open `http://100.85.66.60:4173/` in Safari on iPad.
- [ ] Pair as a fresh non-primary test device.
- [ ] Confirm the app lands in `clawline_web_test` chat, not Flynn.
- [ ] Send a Main message with text `ipad safari web smoke <timestamp>`.
- [ ] Reload Safari page; confirm the message remains visible.
- [ ] Rotate iPad; confirm bubbles/composer do not overflow.
- [ ] Focus composer; confirm keyboard does not cover newest sent bubble or send button.
- [ ] Open Manage streams while keyboard is up; confirm popover/drawer focus behavior stays usable.
- [ ] If a dedicated test side/custom stream is available, switch to it and send a message; reload/reconnect and confirm persistence.
- [ ] Capture screenshot before/after keyboard and after rotation.

Pass rule:

- Real-device Safari proof passes only when both iPhone and iPad checklists are completed with screenshots and no Flynn-account traffic.
- Until then, comprehensive Clawline Web status is: automated/local/deployed/live desktop PASS; real iPhone/iPad Safari manual proof PENDING.

## 02:00 Readiness Snapshot - 2026-05-08

Purpose: preserve the hourly post-fix state before manual Safari execution.

- Eezo source checkout: `/Users/mike/src/clawline`
- Observed HEAD: `2e1db64698398a29b87d368d220c9d7e40b38270`
- `origin/main...HEAD`: `0 0`
- Working tree note: no tracked changes; unrelated untracked `.build/DerivedData_*` and docs artifacts were present and not touched.
- Deployed URL: `http://100.85.66.60:4173/`
- HTTP status: `200 OK` from Caddy.
- Deployed assets still serving the verified Clawline Web bundle from the integration fix:
  - `assets/index-C4oNo-t-.js`
  - `assets/index-DR6FtkEm.css`
- `index.html` SHA-256: `23abd8a1183f46ea81c8bb6a7edb9be7a4c2c1b13ba9993d42a743143c59f15a`
- Pending Clawline devices: none.
- Dedicated test devices remain in allowlist under `userId=clawline_web_test`.

Status: automated/local/deployed/live desktop checks remain ready for manual Safari follow-up. Real iPhone/iPad Safari proof is still pending physical/manual execution.

## 03:00 Physical Safari Capability Check - 2026-05-08

Purpose: determine whether CLU can execute the remaining real iPhone/iPad Safari proof without Flynn physically driving devices.

Result:

- `xcrun devicectl list devices`: no physical iPhone/iPad devices found from this host context.
- `xcrun simctl list devices booted`: one booted iOS simulator was visible (`T001 Reload iPad`), but simulator Safari is not the same as the required real-device Safari keyboard/rotation proof.
- `safaridriver --enable`: requires an interactive admin password; not used.

Conclusion:

- CLU cannot truthfully complete the remaining real iPhone/iPad Safari checklist from the current control path.
- The automated/local/deployed/live desktop proof remains green; real iPhone/iPad Safari proof still requires physical/manual execution or a separately provided supported device-control path.

## 05:00 Manual Safari Checklist Published - 2026-05-08

Purpose: make the remaining physical-device verification easy to run from iPhone/iPad.

Published checklist URL:

- `http://100.85.66.60:18800/www/clawline-web-safari-checklist.html`

Contents:

- Current deployed Clawline Web URL.
- Dedicated-account rule: use `clawline_web_test`, not Flynn primary.
- iPhone Safari checklist.
- iPad Safari checklist.
- Screenshot requirements.
- Pass rule.

Verification:

- Local provider webroot served the checklist with `HTTP/1.1 200 OK`.

Status: automated/local/deployed/live desktop checks are green. Real iPhone/iPad Safari proof remains pending until the checklist is executed on physical devices.

## 06:00 Safari Readiness Recheck - 2026-05-08

Purpose: keep the remaining physical-device Safari verification ready and verify no new test-device approval is waiting.

- Safari checklist URL rechecked: `http://100.85.66.60:18800/www/clawline-web-safari-checklist.html`
- Clawline Web URL rechecked: `http://100.85.66.60:4173/`
- Both URLs returned HTTP 200 during the 06:00 check.
- Deployed web assets still observed: `assets/index-C4oNo-t-.js`, `assets/index-DR6FtkEm.css`.
- Pending Clawline devices: none at recheck time.
- Dedicated `clawline_web_test` devices remain allowlisted.

Status: device-side Safari execution is ready; no pending approval currently needs CLU action.

## 07:00 Safari QR Launch Page Published - 2026-05-08

Purpose: make physical iPhone/iPad execution easier by giving Flynn a scannable launch page.

Published QR page:

- `http://100.85.66.60:18800/www/clawline-web-safari-qr.html`

It links to the manual Safari checklist:

- `http://100.85.66.60:18800/www/clawline-web-safari-checklist.html`

Verification:

- Provider webroot served the QR launch page with `HTTP/1.1 200 OK`.

Status: remaining proof still requires physical iPhone/iPad execution, but the checklist is now one scan away.

## Safari Scroll-Up Regression Fix - 2026-05-08 12:44 PDT

Purpose: record the live Safari/WebKit regression found during physical/plain Safari testing: transcript could scroll down but could not scroll back up.

Product meaning:

- This was confirmed as a Clawline Web bug because it reproduced in plain Safari, not only inside Surf Ace.
- Surf Ace was told to stand down on this specific scroll issue; Surf Ace ownership/pane-label bugs remain separate.

Root cause reported by implementation agent:

- Safari/WebKit could report wheel/touch scroll intent before the list's scroll event updated bottom-stickiness.
- Pending bottom-restore animation frames and the virtual window's bottom-follow path could snap the transcript back down while the user tried to scroll up.

Fix summary:

- `src/features/chat/MessageList.tsx`: treats wheel/touch as active user scroll intent, suspends bottom-follow, and lets bottom-restore settle loops yield during active user scrolling.
- `src/features/chat/useVirtualMessageWindow.ts`: exposes `suspendBottomFollow()`.
- `src/features/chat/MessageList.test.tsx`: adds regression coverage for active upward wheel scroll not being forced back to bottom.

Shipped/deployed state:

- Commit: `324d6fc27f0d1fa6aef9940fb059ce319e34e15c` (`Fix Safari transcript scroll restoration`).
- TARS web target: `http://100.85.66.60:4173/`.
- Deployed JS asset: `assets/index-ZvAdaZQK.js`.
- CSS asset: `assets/index-DR6FtkEm.css`.

Evidence:

- `npm run build`: PASS.
- `npm run test`: PASS (`23 files / 172 tests`).
- `npm run test:e2e`: PASS (`30 tests`).
- Targeted WebKit scroll checks: PASS (`phase5-responsive-keyboard`, `phase5-scroll-unread`, `phase7-live-bug-regressions`).
- Deployed dedicated-account WebKit check used `userId=clawline_web_test` / `deviceId=da49d87f-60a5-4a72-b543-4f1da80200db`: scroll moved from `1715` to `1315` and stayed at `1315`.

Status:

- Automated/deployed WebKit evidence is green.
- Final experiential check remains Flynn/physical Safari: open `http://100.85.66.60:4173/`, scroll down in a long chat, then scroll back up and confirm it no longer snaps down.
