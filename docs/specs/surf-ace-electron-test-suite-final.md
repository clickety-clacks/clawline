# Surf Ace — Electron Implementation Test Suite (Final)

> Derived exclusively from `surf-ace.md` spec (last updated 2026-02-26).  
> Reconciled against adversarial feedback. See `surf-ace-test-reconciliation.md` for change log.  
> Platform: Linux / Electron, using Avahi for mDNS, Node.js HTTP server, Chromium webview, xterm.js, pdf.js, marked.

---

## 1. Discovery — mDNS / Bonjour Publish & Resolve

### DISC-E-01 — Bonjour service type advertisement

**Validates:** §6.1 — service type must be `_surf-ace._tcp`  
**Setup:** Electron app launched, network interface active  
**Action:** Browse the local network for mDNS services via Avahi (`avahi-browse -t _surf-ace._tcp`) or an mDNS client  
**Expected:** The running Electron instance appears in results with service type `_surf-ace._tcp` and a correctly formed record  
**Note:** Do not assert global uniqueness ("exactly one record") — shared LANs may have other Surf Ace instances. Assert this instance is present and well-formed.  
**Type:** Integration

---

### DISC-E-02 — Required TXT record keys present

**Validates:** §6.1 — all required TXT record keys must be present  
**Setup:** Electron app launched  
**Action:** Resolve the advertised `_surf-ace._tcp` service and inspect TXT records  
**Expected:** TXT records include all of: `name`, `v`, `w`, `h`, `s`, `cap`, `busy`, `pk`  
**Type:** Integration

---

### DISC-E-03 — TXT `v` is protocol version `1`

**Validates:** §6.1 — `v` TXT key must be `"1"` for v1 protocol  
**Setup:** Electron app launched  
**Action:** Resolve TXT records and read `v`  
**Expected:** `v = "1"`  
**Type:** Integration

---

### DISC-E-04 — TXT `w` and `h` reflect actual viewport dimensions

**Validates:** §6.1 — `w` and `h` are viewport width/height in points  
**Setup:** Electron app launched in a known window size (e.g. 1920×1080)  
**Action:** Resolve TXT records and read `w` and `h`  
**Expected:** `w` and `h` match the configured viewport dimensions as integers  
**Type:** Integration

---

### DISC-E-05 — TXT `s` reflects display scale factor

**Validates:** §6.1 — `s` is the display scale factor  
**Setup:** Electron app launched on a known display (e.g. HiDPI or 1× monitor)  
**Action:** Resolve TXT record `s`  
**Expected:** `s` is a numeric string matching the screen's pixel ratio  
**Type:** Integration

---

### DISC-E-06 — TXT `cap` bitmask matches supported content types

**Validates:** §6.1 — `cap` bitmask: bit 1=html, 2=image, 4=pdf, 8=terminal, 16=markdown  
**Setup:** Electron app launched (supports all five types)  
**Action:** Resolve TXT record `cap`  
**Expected:** `cap = "31"` (1+2+4+8+16), or a value reflecting only the actually supported types  
**Type:** Integration

---

### DISC-E-07 — TXT `busy` starts as `0`

**Validates:** §6.1 — `busy` is `0` when no session is active  
**Setup:** Electron app launched, no active session  
**Action:** Resolve TXT record `busy`  
**Expected:** `busy = "0"`  
**Type:** Integration

---

### DISC-E-08 — TXT `busy` transitions to `1` when session is active

**Validates:** §6.1 — `busy` is updated in real-time as sessions start  
**Setup:** Electron app launched, no active session  
**Action:** Send `POST /pair` to create a session; then resolve TXT record `busy`  
**Expected:** `busy = "1"` after successful pairing  
**Type:** Integration

---

### DISC-E-09 — TXT `busy` transitions back to `0` when session ends

**Validates:** §6.1 — `busy` updated when session ends; §6.4 — session end clears content and sets busy=0  
**Setup:** Electron app with active session  
**Action:** Session ends (app quits or screen shuts down); resolve TXT record `busy`  
**Expected:** `busy = "0"` after session termination  
**Type:** Integration

---

### DISC-E-10 — TXT `pk` is first 8 hex chars of SHA-256 of the public key

**Validates:** §6.1 — `pk` is the fingerprint; §6.2 — identity via Ed25519 keypair  
**Setup:** Electron app launched; known public key on file  
**Action:** Resolve TXT `pk`; independently compute SHA-256 of the public key bytes and take the first 8 hex chars  
**Expected:** `pk` matches the independently computed fingerprint  
**Type:** Unit (with known key fixture)

---

### DISC-E-11 — Identity (keypair) persists across restarts

**Validates:** §6.2 — Ed25519 keypair is stable across reboots; `pk` fingerprint must remain the same  
**Setup:** Electron app launched; record `pk` TXT value; shut down; relaunch  
**Action:** Resolve TXT `pk` again  
**Expected:** `pk` is identical to the value recorded before the restart  
**Type:** Integration

---

### DISC-E-12 — New keypair generated on first launch only

**Validates:** §6.2 — keypair generated on first launch; only changes if identity files are deleted  
**Setup:** Delete all stored Electron identity files; launch app  
**Action:** Record `pk`; restart app without deleting identity; record `pk` again  
**Expected:** `pk` is the same across the second launch; only changes if identity is deleted (explicit factory reset)  
**Type:** Integration

---

### DISC-E-13 — TXT `busy` transitions within bounded time after session state change

**Validates:** §6.1 — `busy` is updated in real-time as sessions start and end  
**Setup:** Electron app in known state (Standby or active session)  
**Action:** Trigger a state change (pair or session end); poll TXT `busy` repeatedly  
**Expected:** `busy` reflects the new state within approximately 1 second of the state change  
**Type:** Integration

---

## 2. HTTP Server — Endpoints

### HTTP-E-01 — HTTP server starts on advertised port

**Validates:** §6.3 — screen runs an HTTP server on the advertised port  
**Setup:** Electron app launched; mDNS service resolved to get `host:port`  
**Action:** Attempt TCP connection to the advertised `host:port`  
**Expected:** Connection accepted  
**Type:** Integration

---

### HTTP-E-02 — All endpoints require Bearer token (except /pair)

**Validates:** §6.3 — all endpoints except `POST /pair` require `Authorization: Bearer <sessionToken>`  
**Setup:** Electron app launched, no active session  
**Action:** Send `POST /frame`, `GET /snapshot`, `POST /frame/append`, `POST /frame/patch`, `DELETE /frame`, `POST /watch`, `POST /unwatch` — all without Authorization header  
**Expected:** Each returns `401 Unauthorized`  
**Type:** Integration

---

### HTTP-E-02b — Malformed Authorization header rejected

**Validates:** §6.3 — valid Bearer token required  
**Setup:** Active session with valid token  
**Action (a):** Send `GET /snapshot` with `Authorization: Bearer` (no token after Bearer)  
**Action (b):** Send `GET /snapshot` with `Authorization: Basic dXNlcjpwYXNz` (wrong scheme)  
**Action (c):** Send `GET /snapshot` with `Authorization: Bearer   ` (whitespace-only token)  
**Expected:** Each returns `401 Unauthorized`  
**Type:** Integration

---

### HTTP-E-03 — POST /pair without auth is accepted

**Validates:** §6.3 — `POST /pair` does not require Authorization header  
**Setup:** Electron app in Standby (no session)  
**Action:** `POST /pair` with `{ "mode": "auto" }` and no Authorization header  
**Expected:** `200 OK` with `{ "status": "ok", "sessionToken": "..." }`  
**Type:** Integration

---

### HTTP-E-04 — DELETE /frame returns 204 No Content

**Validates:** §8.5 — clear response is `204 No Content`  
**Setup:** Active session with a frame displayed  
**Action:** `DELETE /frame` with valid Bearer token  
**Expected:** `204 No Content`, screen shows connected-idle state  
**Type:** Integration

---

### HTTP-E-05 — GET /snapshot returns 204 when no frame displayed

**Validates:** §17.6 — `GET /snapshot` returns `204 No Content` when connected-idle  
**Setup:** Active session, no frame pushed (or after DELETE /frame)  
**Action:** `GET /snapshot` with valid Bearer token  
**Expected:** `204 No Content`  
**Type:** Integration

---

### HTTP-E-06 — GET /snapshot returns full snapshot JSON when frame is displayed

**Validates:** §9.1 — snapshot response shape  
**Setup:** Active session; push an HTML frame  
**Action:** `GET /snapshot`  
**Expected:** JSON with `frameId`, `contentType`, `title`, `viewport` (with `scrollOffset`, `visibleRect`, `contentSize`, `zoomLevel`), `visibleText`, `selection`, `annotations` fields  
**Type:** Integration

---

### HTTP-E-07 — GET /snapshot `frameId` matches last pushed frame

**Validates:** §9.1 — snapshot `frameId` identifies the active frame  
**Setup:** Push a frame with `frameId: "fr_aabb1122"`  
**Action:** `GET /snapshot`  
**Expected:** Snapshot `frameId = "fr_aabb1122"`  
**Type:** Integration

---

### HTTP-E-08 — GET /snapshot `annotations` is empty array in v1

**Validates:** §9.1 — annotations reserved for future use, empty in v1  
**Setup:** Active session with a frame displayed  
**Action:** `GET /snapshot`  
**Expected:** `annotations: []`  
**Type:** Integration

---

### HTTP-E-09 — POST /frame replaces existing frame

**Validates:** §8.1 — pushing a new frame replaces the old one  
**Setup:** Active session; push frame A with `frameId: "fr_aaaa0001"`  
**Action:** Push frame B with `frameId: "fr_bbbb0002"`; then `GET /snapshot`  
**Expected:** Snapshot `frameId = "fr_bbbb0002"`, frame A is gone  
**Type:** Integration

---

### HTTP-E-10 — POST /frame with unknown session token returns 401

**Validates:** §6.3 — invalid session token rejected  
**Setup:** Active session; record the token; terminate session; try to reuse token  
**Action:** `POST /frame` with expired/invalid token  
**Expected:** `401 Unauthorized`  
**Type:** Integration

---

### HTTP-E-11 — POST /frame/append stale frameId returns 409 Conflict

**Validates:** §8.4 — stale frameId → `409 Conflict` with `{ "error": "stale_frame" }`  
**Setup:** Active session; push terminal frame A; push frame B (replacing A)  
**Action:** `POST /frame/append` using frame A's `frameId`  
**Expected:** `409 Conflict`, body `{ "error": "stale_frame" }`  
**Type:** Integration

---

### HTTP-E-12 — POST /frame/patch stale frameId returns 409 Conflict

**Validates:** §8.4 — stale frameId → `409 Conflict` with `{ "error": "stale_frame" }`  
**Setup:** Active session; push HTML frame A; push frame B (replacing A)  
**Action:** `POST /frame/patch` using frame A's `frameId`  
**Expected:** `409 Conflict`, body `{ "error": "stale_frame" }`  
**Type:** Integration

---

### HTTP-E-13 — POST /frame/append only valid for terminal frames

**Validates:** §8.4 — append only for `terminal`  
**Setup:** Active session; push an `html` frame  
**Action:** `POST /frame/append` referencing the HTML frame's `frameId`  
**Expected:** `422 Unprocessable Entity` with appropriate error code  
**Type:** Integration

---

### HTTP-E-14 — POST /frame/patch only valid for HTML frames

**Validates:** §8.4 — patch only for `html`  
**Setup:** Active session; push a `terminal` frame  
**Action:** `POST /frame/patch` referencing the terminal frame's `frameId`  
**Expected:** `422 Unprocessable Entity`  
**Type:** Integration

---

### HTTP-E-15 — POST /frame/patch all patch actions accepted

**Validates:** §8.4 — patch actions: `replace_inner`, `replace_outer`, `insert_before`, `insert_after`, `remove`  
**Setup:** Active session; push an HTML frame with a target element `#target` for each subtest  
**Action:** For each action type, push a fresh frame with `#target`, then send `POST /frame/patch` with `selector: "#target"` and that action  
**Expected:** Each returns `200 OK`; screen updates accordingly. Each action runs in isolation against a freshly pushed frame.  
**Type:** Integration

---

### HTTP-E-16 — POST /watch returns 200 OK

**Validates:** §9.2 — watch subscribe response  
**Setup:** Active session  
**Action:** `POST /watch` with valid callbackUrl and events list  
**Expected:** `200 OK`  
**Type:** Integration

---

### HTTP-E-17 — POST /unwatch returns 200 OK and stops events

**Validates:** §9.2 — unsubscribe response  
**Setup:** Active session in watch mode  
**Action:** `POST /unwatch`  
**Expected:** `200 OK`; no further event POSTs to callbackUrl after unwatch  
**Type:** Integration

---

## 3. Provider Callbacks — Watch Mode Events

### CB-E-01 — Screen POSTs text_selected event to callbackUrl

**Validates:** §9.3 — `text_selected` event shape  
**Setup:** Active session in watch mode; HTML frame displayed with selectable text; callback server listening  
**Action:** User (or simulated action) selects text on the screen  
**Expected:** Callback server receives a POST with `event: "text_selected"`, `frameId`, `text`, `boundingRect`, `timestamp`  
**Type:** E2E / Integration

---

### CB-E-02 — text_selected fires immediately (debounce = 0)

**Validates:** §9.2 — default debounce for `text_selected` is `0`  
**Setup:** Active session in watch mode with `text_selected` subscribed and `debounce.text_selected: 0`  
**Action:** User selects text  
**Expected:** Event POSTed without artificial delay  
**Type:** Integration

---

### CB-E-03 — scroll_settle fires after configured debounce

**Validates:** §9.2 — screen debounces events per provided config; `scroll_settle` default 500ms  
**Setup:** Active session in watch mode with `scroll_settle` at 500ms debounce; scrollable HTML frame  
**Action:** Simulate a scroll; stop scrolling  
**Expected:** Event POSTed approximately 500ms after scrolling stops; not while actively scrolling  
**Type:** Integration

---

### CB-E-04 — scroll_settle event shape is correct

**Validates:** §9.3 — `scroll_settle` event shape  
**Setup:** Active session in watch mode, scrollable HTML frame  
**Action:** Scroll and settle  
**Expected:** Callback receives `event: "scroll_settle"`, `frameId`, `viewport` (with `scrollOffset`, `visibleRect`, `contentSize`, `zoomLevel`), `visibleText`, `timestamp`  
**Type:** Integration

---

### CB-E-05 — zoom_settle event fires after zoom settles

**Validates:** §9.3 — `zoom_settle` event shape and debounce  
**Setup:** Active session in watch mode with `zoom_settle` subscribed; HTML frame displayed  
**Action:** Simulate pinch-zoom; release  
**Expected:** Callback receives `event: "zoom_settle"`, `frameId`, `viewport` with updated `zoomLevel`, `visibleText`, `timestamp`  
**Type:** Integration

---

### CB-E-06 — point event shape is correct

**Validates:** §9.3 — `point` event shape  
**Setup:** Active session in watch mode with `point` subscribed; frame displayed  
**Action:** User taps/clicks on the screen  
**Expected:** Callback receives `event: "point"`, `frameId`, `position` (`x`, `y`), `nearestContent`, `timestamp`  
**Type:** Integration

---

### CB-E-07 — region event shape is correct

**Validates:** §9.3 — `region` event shape  
**Setup:** Active session in watch mode with `region` subscribed  
**Action:** User draws a selection rectangle  
**Expected:** Callback receives `event: "region"`, `frameId`, `rect` (`x`, `y`, `width`, `height`), `containedText`, `timestamp`  
**Type:** Integration

---

### CB-E-08 — page_change event for PDF (shape validation)

**Validates:** §9.3 — `page_change` event shape  
**Setup:** Active session in watch mode with `page_change` subscribed; PDF frame displayed  
**Action:** User navigates to a different page  
**Expected:** Callback receives `event: "page_change"`, `frameId`, `page`, `totalPages`, `pageText`, `timestamp`  
**Type:** Integration

---

### CB-E-10 — Event POST retry once on failure then drop

**Validates:** §16.9 — screen retries event POST once after 1 second, then drops  
**Setup:** Active watch mode; callback server intentionally unreachable  
**Action:** Trigger a watch event  
**Expected:** Screen makes exactly 2 POST attempts (initial + 1 retry approximately 1 second later), then drops the event; screen does not enter a retry loop  
**Type:** Integration

---

### CB-E-11 — Watch mode events use same callback URL for all event types

**Validates:** §9.2 — all events go to the single `callbackUrl` from POST /watch  
**Setup:** Watch mode subscribed to multiple event types  
**Action:** Trigger multiple different event types (text_selected, point, scroll_settle)  
**Expected:** All events arrive at the same callbackUrl provided in POST /watch  
**Type:** Integration

---

## 4. Content Rendering

### RENDER-E-01 — HTML frame renders in Chromium webview

**Validates:** §14.5 — Electron renders HTML via Chromium webview  
**Setup:** Active session  
**Action:** Push `{ "contentType": "html", "content": { "html": "<html><body><p id='hello'>Hello</p></body></html>" } }`  
**Expected:** Screen renders the HTML; GET /snapshot `visibleText` includes "Hello"  
**Type:** Integration

---

### RENDER-E-02 — HTML frame injects CSS variables

**Validates:** §14.5 — HTML frames use CSS variables: `--surf-ace-bg`, `--surf-ace-fg`, `--surf-ace-accent`, `--surf-ace-font-size`, `--surf-ace-width`, `--surf-ace-height`  
**Setup:** Active session; HTML frame that reads and reports CSS variable values  
**Action:** Push HTML that reads `getComputedStyle(document.documentElement).getPropertyValue('--surf-ace-bg')` and displays the result  
**Expected:** CSS variables are present and non-empty in the rendered page  
**Type:** Integration

---

### RENDER-E-03 — Image frame renders correctly

**Validates:** §8.2 / §14.5 — Electron renders images  
**Setup:** Active session  
**Action:** Push `{ "contentType": "image", "content": { "data": "<base64 PNG>", "mediaType": "image/png", "alt": "test image" } }`  
**Expected:** Screen displays the image; GET /snapshot `visibleText` equals `"test image"` (alt text)  
**Type:** Integration

---

### RENDER-E-04 — PDF frame renders and reports visibleText

**Validates:** §8.2 / §14.5 / §9.1 — PDF rendering; visibleText from visible page  
**Setup:** Active session  
**Action:** Push `{ "contentType": "pdf", "content": { "data": "<base64 PDF>" } }`  
**Expected:** GET /snapshot `contentType = "pdf"`; `visibleText` contains text from the first visible page  
**Note:** This validates observable behavior (rendering output + snapshot), not library selection.  
**Type:** Integration

---

### RENDER-E-05 — Terminal frame renders and reports visibleText

**Validates:** §8.2 / §14.5 / §9.1 — terminal rendering; visibleText from visible lines  
**Setup:** Active session  
**Action:** Push `{ "contentType": "terminal", "content": { "lines": ["line 1", "line 2"], "scrollback": 1000 } }`  
**Expected:** GET /snapshot `visibleText` includes "line 1" and "line 2"  
**Note:** This validates observable behavior (rendering output + snapshot), not library selection.  
**Type:** Integration

---

### RENDER-E-06 — Markdown frame renders and reports visibleText

**Validates:** §8.2 / §14.5 / §9.1 — markdown rendering; visibleText from visible content  
**Setup:** Active session  
**Action:** Push `{ "contentType": "markdown", "content": { "markdown": "# Hello\n\nWorld" } }`  
**Expected:** GET /snapshot `visibleText` includes "Hello" and "World"  
**Note:** This validates observable behavior (rendering output + snapshot), not library selection.  
**Type:** Integration

---

### RENDER-E-07 — Terminal append adds lines to visible display

**Validates:** §8.4 — append adds lines to terminal frame  
**Setup:** Active session; terminal frame pushed with initial lines  
**Action:** `POST /frame/append` with additional lines  
**Expected:** New lines appear in the terminal display; GET /snapshot `visibleText` includes the appended lines  
**Type:** Integration

---

### RENDER-E-08 — HTML patch replace_inner updates DOM content

**Validates:** §8.4 — `replace_inner` replaces inner HTML of matched selector  
**Setup:** Active session; HTML frame with `<div id="status">old</div>`  
**Action:** `POST /frame/patch` with `selector: "#status"`, `action: "replace_inner"`, `html: "new"`  
**Expected:** DOM now shows "new"; GET /snapshot `visibleText` reflects update  
**Type:** Integration

---

### RENDER-E-09 — snapshot visibleText truncated to 4KB

**Validates:** §9.1 — `visibleText` truncated to 4KB  
**Setup:** Active session; HTML frame with more than 4KB of visible text  
**Action:** `GET /snapshot`  
**Expected:** `visibleText` length ≤ 4096 characters  
**Type:** Integration

---

### RENDER-E-10 — snapshot visibleText for image is alt text

**Validates:** §9.1 — for image frames, `visibleText` is the `alt` text  
**Setup:** Active session; image frame with `alt: "A diagram of the architecture"`  
**Action:** `GET /snapshot`  
**Expected:** `visibleText = "A diagram of the architecture"`  
**Type:** Integration

---

### RENDER-E-11 — snapshot visibleText for PDF is text on visible page(s)

**Validates:** §9.1 — for PDF frames, `visibleText` is text on visible page(s)  
**Setup:** Active session; PDF frame with known text on page 1  
**Action:** `GET /snapshot` while page 1 is visible  
**Expected:** `visibleText` contains the known text from page 1  
**Type:** Integration

---

### RENDER-E-12 — HTML frame baseUrl accepted and applied

**Validates:** §8.2 — HTML content shape includes optional `baseUrl`  
**Setup:** Active session  
**Action:** Push HTML frame with `content: { html: "<html>...</html>", baseUrl: "https://example.com/" }`  
**Expected:** `200 OK`; relative URLs in the HTML resolve against `baseUrl`  
**Type:** Integration

---

## 5. Pencil / Markup System

> Note: Electron (Linux) uses mouse/pointer input as the equivalent of pencil/stylus. Apple Pencil is iOS-only. These tests validate the stroke protocol and debounce behavior using available input methods.

### PENCIL-E-01 — Short debounce fires ~500ms after pointer lifts

**Validates:** §13.2 — short debounce ~500ms after pencil/pointer lifts  
**Setup:** Active session; watch mode or stroke callback active; frame displayed  
**Action:** Draw a stroke (mouse down → move → mouse up); measure time to callback POST  
**Expected:** Callback POST with `event: "strokes"` arrives approximately 500ms after mouse up  
**Type:** Integration

---

### PENCIL-E-02 — Short debounce payload shape is correct

**Validates:** §13.3 — short debounce payload: `event: "strokes"`, `frameId`, `strokes`, `crop`, `cropRect`, `timestamp`  
**Setup:** Active session; frame displayed; stroke drawn  
**Action:** Wait for short debounce callback  
**Expected:** Callback body contains `event: "strokes"`, `frameId`, `strokes` (array with `points` and `tool`), `crop` (base64 image string), `cropRect` (`x`, `y`, `w`, `h`), `timestamp`  
**Type:** Integration

---

### PENCIL-E-03 — Stroke points contain x, y, timestamp (pressure absent for mouse)

**Validates:** §13.3 — pressure data absent for `mouse` tool  
**Setup:** Active session; stroke drawn with mouse  
**Action:** Inspect short debounce callback `strokes[0].points`  
**Expected:** Each point has `x`, `y`, `timestamp`; no `pressure` field (or pressure is absent/null) for `tool: "mouse"`  
**Type:** Unit / Integration

---

### PENCIL-E-04 — `tool` field is `"mouse"` for mouse input

**Validates:** §13.3 — `tool` is one of `pencil`, `finger`, `mouse`; Electron uses `mouse`  
**Setup:** Active session; stroke drawn with mouse  
**Action:** Inspect short debounce payload  
**Expected:** `strokes[0].tool = "mouse"`  
**Type:** Integration

---

### PENCIL-E-05 — Long debounce fires ~3–5s after last stroke

**Validates:** §13.2 — long debounce ~3–5s of no new strokes  
**Setup:** Active session; frame displayed; draw a stroke, then stop  
**Action:** Measure time from last stroke to long-debounce callback  
**Expected:** Long-debounce POST arrives between 3000ms and 5000ms after last stroke; no new strokes occur in that interval  
**Type:** Integration

---

### PENCIL-E-06 — Long debounce payload shape is correct

**Validates:** §13.3 — long debounce payload: `event: "surf ace_snapshot"`, `frameId`, `image`, `strokesSinceLastSnapshot`, `timestamp`  
**Setup:** Active session; strokes drawn; long debounce fires  
**Action:** Inspect long debounce callback  
**Expected:** Body contains `event: "surf ace_snapshot"`, `frameId`, `image` (base64 string), `strokesSinceLastSnapshot` (array of stroke objects), `timestamp`  
**Type:** Integration

---

### PENCIL-E-07 — Long debounce `image` is a full-screen screenshot

**Validates:** §13.3 — long debounce sends full surf ace screenshot  
**Setup:** Active session; HTML frame displayed with known layout  
**Action:** Draw strokes; wait for long-debounce callback; decode `image`  
**Expected:** Decoded image dimensions match the screen viewport; shows both the pushed content and the drawn strokes overlaid  
**Type:** Integration

---

### PENCIL-E-08 — Short debounce `crop` covers area around strokes

**Validates:** §13.3 — crop screenshot is a local area around the strokes  
**Setup:** Active session; frame displayed; draw strokes in a known region  
**Action:** Wait for short debounce callback; inspect `crop` and `cropRect`  
**Expected:** `cropRect` bounds are approximately around the drawn stroke region; decoded `crop` image shows that area with strokes rendered on top of content  
**Type:** Integration

---

### PENCIL-E-09 — Strokes buffered during frame push, not lost

**Validates:** §16.10 — strokes drawn during frame push must not be lost  
**Setup:** Active session; frame displayed; begin drawing strokes  
**Action:** Simultaneously push a new frame (simulate concurrent frame push during stroke drawing); check next debounce payload  
**Expected:** Next debounce payload includes all strokes drawn before, during, and after the frame push; no strokes are dropped  
**Type:** Integration

---

### PENCIL-E-10 — Continuous drawing: nothing fires; long debounce fires only on idle gap

**Validates:** §16.11 — during continuous drawing (pointer never lifts), NOTHING fires — short debounce requires pointer lift, long debounce timer resets on every new stroke and fires only after drawing stops (idle gap of 3–5s)  
**Setup:** Active session; frame displayed  
**Action:** Simulate a 30-second continuous mouse drag (button held throughout); then stop and observe  
**Expected:** No short-debounce (`strokes`) events fire during continuous drag; no long-debounce (`surf ace_snapshot`) events fire during continuous drag; after drag stops, long debounce fires once after the 3–5s idle gap  
**Type:** Integration

---

### PENCIL-E-11 — Change stack records frames received from provider

**Validates:** §13.4 / §13.6 — surf ace maintains an ordered change stack of frames received  
**Setup:** Active session  
**Action:** Push 3 distinct frames in sequence; inspect the surf ace's internal change stack (via a test hook or observable state)  
**Expected:** Change stack contains the 3 frames in push order; newest frame is the current active frame  
**Note:** This test requires defined test instrumentation (an internal test hook exposing the change stack). The change stack is a spec requirement (§13.4, §13.6) for CLU-driven undo. This test must be written as a white-box/instrumented test.  
**Type:** Unit (via internal test API or observable state)

---

## 6. Pairing

### PAIR-E-01 — Auto mode pairing returns sessionToken

**Validates:** §7.3 / §17.1 — `POST /pair { "mode": "auto" }` returns `{ "status": "ok", "sessionToken": "..." }`  
**Setup:** Electron app in Standby  
**Action:** `POST /pair` with `{ "mode": "auto" }`  
**Expected:** `200 OK`, body `{ "status": "ok", "sessionToken": "<non-empty string>" }`  
**Type:** Integration

---

### PAIR-E-02 — Session token is 32 bytes hex-encoded (64 chars)

**Validates:** §15.3 — session token is 32 bytes, hex-encoded  
**Setup:** Electron app in Standby  
**Action:** `POST /pair { "mode": "auto" }`; inspect returned `sessionToken`  
**Expected:** `sessionToken` is a 64-character lowercase hexadecimal string  
**Type:** Integration

---

### PAIR-E-11 — Pairing while session active returns 409 Conflict

**Validates:** §6.5 — second `POST /pair` when busy returns `409 Conflict { "error": "busy" }`  
**Setup:** Electron app with active session  
**Action:** Send `POST /pair { "mode": "auto" }` from a second client  
**Expected:** `409 Conflict`, body `{ "error": "busy" }`  
**Type:** Integration

---

## 7. Session Lifecycle

### SESS-E-01 — Session starts on successful POST /pair

**Validates:** §7.5 — session starts at `POST /pair` success  
**Setup:** Electron app in Standby  
**Action:** `POST /pair`; observe session state  
**Expected:** Session is active; `busy=1` in Bonjour TXT; screen shows Connected (idle) state  
**Type:** Integration

---

### SESS-E-02 — Screen clears content and goes idle when session ends

**Validates:** §6.4 — on session end, screen clears content, goes idle, sets `busy=0`  
**Setup:** Active session with frame displayed  
**Action:** Quit the Electron app; observe screen  
**Expected:** Screen shows Standby state (name + network indicator); `busy=0` in Bonjour TXT; session token invalidated  
**Note:** DELETE /frame does NOT end the session — it transitions to connected-idle (see SESS-E-08). Sessions have no inactivity timeout (§6.4) — they end only on explicit clear or shutdown.  
**Type:** Integration

---

### SESS-E-03 — Session token invalidated after session ends

**Validates:** §6.4 — session token invalidated on session end  
**Setup:** Active session; record session token; end session by quitting the app  
**Action:** `POST /frame` with the old session token  
**Expected:** `401 Unauthorized` — token no longer valid  
**Type:** Integration

---

### SESS-E-06 — Screen holds last frame if provider becomes unreachable

**Validates:** §6.6 — screen holds last displayed frame indefinitely if provider is permanently unreachable  
**Setup:** Active session; push a frame; disconnect provider (stop TARS/callback server)  
**Action:** Observe screen over time  
**Expected:** Last frame remains displayed; screen does not go idle spontaneously  
**Type:** Integration

---

### SESS-E-07 — On app quit, session ends and screen goes idle

**Validates:** §7.5 — session ends on screen shutdown  
**Setup:** Active session  
**Action:** Quit the Electron app  
**Expected:** Session terminated; `busy=0` advertised (or service removed from mDNS); screen no longer reachable  
**Type:** Integration

---

### SESS-E-08 — DELETE /frame leaves session active (connected-idle)

**Validates:** §8.5 / §8.6 — DELETE /frame transitions to connected-idle, not Standby  
**Setup:** Active session; frame displayed  
**Action:** `DELETE /frame`  
**Expected:** Session is still active (token still valid); `GET /snapshot` returns `204`; screen shows "Connected" indicator, not Standby  
**Type:** Integration

---

## 8. Edge Cases

### EDGE-E-01 — POST /frame with unsupported content type returns 422 unsupported_type

**Validates:** §6.7 — `unsupported_type` error  
**Setup:** Active session; simulate unsupported type (e.g., push a type not in `cap` bitmask)  
**Action:** Push frame with a content type not supported by this screen  
**Expected:** `422 Unprocessable Entity`, body `{ "error": { "code": "unsupported_type", ... } }`  
**Type:** Integration

---

### EDGE-E-02 — POST /frame exceeding size limit returns 422 content_too_large

**Validates:** §6.7 / §8.2 — `content_too_large` error; HTML limit 256KB  
**Setup:** Active session  
**Action:** Push HTML frame where `html` field is > 256KB  
**Expected:** `422 Unprocessable Entity`, body `{ "error": { "code": "content_too_large", ... } }`  
**Type:** Integration

---

### EDGE-E-03 — POST /frame with invalid base64 image returns 422 decode_failed

**Validates:** §6.7 — `decode_failed` error  
**Setup:** Active session  
**Action:** Push image frame with `data: "not-valid-base64!!!"`  
**Expected:** `422 Unprocessable Entity`, body `{ "error": { "code": "decode_failed", ... } }`  
**Type:** Integration

---

### EDGE-E-04 — POST /frame with missing contentType returns error

**Validates:** §8.1 — frame must include `frameId`, `contentType`, `content`  
**Setup:** Active session  
**Action:** Push frame JSON with `contentType` missing  
**Expected:** `422 Unprocessable Entity`  
**Type:** Unit / Integration

---

### EDGE-E-05 — POST /frame with missing frameId returns error

**Validates:** §8.1 — `frameId` is required  
**Setup:** Active session  
**Action:** Push frame JSON without `frameId` field  
**Expected:** `422 Unprocessable Entity`  
**Type:** Unit / Integration

---

### EDGE-E-06 — POST /frame with malformed JSON returns 400

**Validates:** HTTP API correctness  
**Setup:** Active session  
**Action:** POST to `/frame` with body `"this is not json"`  
**Expected:** `400 Bad Request`  
**Type:** Unit / Integration

---

### EDGE-E-07 — Concurrent POST /frame requests handled without data corruption

**Validates:** §16.7 / §16.8 — concurrent requests and snapshot during render  
**Setup:** Active session  
**Action:** Send 5 concurrent `POST /frame` requests with distinct frameIds  
**Expected:** Server handles all requests; one frame ends up active (last writer wins); no server crash or corrupted state  
**Type:** Integration

---

### EDGE-E-08 — GET /snapshot during active render returns current visible state

**Validates:** §16.8 — snapshot during render returns current visible state; `frameId` identifies the frame  
**Setup:** Active session; push a large HTML frame that takes time to render  
**Action:** `GET /snapshot` immediately after POST /frame (before render completes)  
**Expected:** `200 OK` with a snapshot; `frameId` in snapshot matches the pushed frame (or the previous frame if not yet applied); no 500 errors  
**Type:** Integration

---

### EDGE-E-09 — POST /frame/append with non-existent frameId returns 409

**Validates:** §8.4 — stale/unknown `frameId` → `409 Conflict { "error": "stale_frame" }`  
**Setup:** Active session; terminal frame displayed  
**Action:** `POST /frame/append` with a `frameId` that was never pushed  
**Expected:** `409 Conflict`, body `{ "error": "stale_frame" }`  
**Type:** Integration

---

### EDGE-E-10 — Image frame at 10MB limit accepted

**Validates:** §8.2 — image limit is 10MB (base64)  
**Setup:** Active session  
**Action:** Push image frame with `data` field exactly at 10MB base64  
**Expected:** `200 OK`  
**Type:** Integration

---

### EDGE-E-11 — Image frame exceeding 10MB returns 422

**Validates:** §8.2 — image limit is 10MB (base64)  
**Setup:** Active session  
**Action:** Push image frame with `data` field slightly over 10MB  
**Expected:** `422 Unprocessable Entity`, `content_too_large`  
**Type:** Integration

---

### EDGE-E-12 — Terminal frame at 10,000 lines accepted

**Validates:** §8.2 — terminal limit is 10,000 lines  
**Setup:** Active session  
**Action:** Push terminal frame with exactly 10,000 lines  
**Expected:** `200 OK`  
**Type:** Integration

---

### EDGE-E-13 — Two screens with same name publish distinct `pk` fingerprints

**Validates:** §6.2 — screen identity is the Ed25519 keypair; `pk` is unique per screen  
**Setup:** Two Electron instances with the same `name` in TXT records, generated from different keypairs  
**Action:** Browse mDNS; inspect `pk` TXT records for both  
**Expected:** Both screens are present; their `pk` values are distinct; each can be uniquely identified by fingerprint  
**Note:** Provider-side disambiguation logic (reporting to CLU, asking user to clarify) is a provider test, not an Electron screen test. This test validates only the screen-side requirement: each screen publishes a unique `pk`.  
**Type:** Integration

---

### EDGE-E-14 — Screen factory reset generates new keypair and publishes new `pk`

**Validates:** §16.6 / §6.2 — factory reset (keypair deletion) causes new identity  
**Setup:** Electron app with known identity; record `pk`  
**Action:** Delete identity files (simulate factory reset); relaunch Electron app; resolve TXT `pk`  
**Expected:** `pk` has changed to a new value; the new value is a valid fingerprint (8 hex chars)  
**Note:** Provider-side behavior (detecting mismatch, requiring re-pairing) is a provider test. This test validates only the screen-side requirement: new keypair generates a new `pk`.  
**Type:** Integration

---

### EDGE-E-16 — Error during live update in watch mode reported as error event on callback URL

**Validates:** §6.7 — errors during live updates (append/patch) in watch mode are reported as error events on callback URL  
**Setup:** Active session in watch mode; HTML frame displayed  
**Action:** `POST /frame/patch` with a selector that cannot be found or malformed HTML that causes a render error  
**Expected:** Endpoint returns `422`; callback URL receives an error event containing at minimum: `event`, `frameId`, `timestamp`, and error details  
**Type:** Integration

---

### EDGE-E-17 — Live update error event payload contains structured error fields

**Validates:** §6.7 — error shape: `code`, `message`  
**Setup:** Active session in watch mode; trigger a patch render error as in EDGE-E-16  
**Action:** Inspect the error event payload at the callback URL  
**Expected:** Error event payload includes `event` (error type), `frameId`, `timestamp`, and structured error with at least `code` and `message` fields  
**Type:** Integration

---

### EDGE-E-18 — Multiple providers: second provider sees busy=1 and cannot pair

**Validates:** §16.7 — first-come-first-served occupancy; second provider cannot pair  
**Setup:** Two provider instances; first pairs with the screen  
**Action:** Second provider sends `POST /pair`  
**Expected:** `409 Conflict { "error": "busy" }`  
**Type:** Integration

---

### EDGE-E-19 — POST /frame/patch with invalid action returns 422

**Validates:** §8.4 — patch actions are enumerated: `replace_inner`, `replace_outer`, `insert_before`, `insert_after`, `remove`; unknown actions are invalid  
**Setup:** Active session; HTML frame displayed  
**Action:** `POST /frame/patch` with `action: "explode"` (unknown action)  
**Expected:** `422 Unprocessable Entity` with structured error  
**Type:** Integration

---

### EDGE-E-20 — POST /frame/append with missing or invalid `append.lines` returns 422

**Validates:** §8.4 — append payload requires `append.lines` as an array of strings  
**Setup:** Active session; terminal frame displayed  
**Action (a):** `POST /frame/append` with body missing the `append.lines` field  
**Action (b):** `POST /frame/append` with `append.lines` as a non-array value  
**Expected:** `422 Unprocessable Entity` in both cases  
**Type:** Unit / Integration

---

### EDGE-E-21 — PDF frame exceeding 10MB returns 422

**Validates:** §8.2 — PDF limit is 10MB (base64)  
**Setup:** Active session  
**Action:** Push PDF frame with `data` > 10MB  
**Expected:** `422 Unprocessable Entity`, `content_too_large`  
**Type:** Integration

---

### EDGE-E-22 — Markdown frame exceeding 64KB returns 422

**Validates:** §8.2 — markdown limit is 64KB  
**Setup:** Active session  
**Action:** Push markdown frame with `markdown` field > 64KB  
**Expected:** `422 Unprocessable Entity`, `content_too_large`  
**Type:** Integration

---

## 9. Standby / Idle Display

### STANDBY-E-01 — Standby shows screen name, network indicator, fingerprint

**Validates:** §14.4 — standby display: screen name (large, centered), network status icon, public key fingerprint (small, bottom corner)  
**Setup:** Electron app launched, no session  
**Action:** Observe the screen UI  
**Expected:** Screen name prominently displayed and centered; network status indicator visible; fingerprint visible in a bottom corner  
**Type:** E2E

---

### STANDBY-E-02 — Standby shows NO clock, weather, or ambient content

**Validates:** §14.4 — "No clock, no weather, no ambient content. Surf Ace is a tool, not a dashboard."  
**Setup:** Electron app launched, no session  
**Action:** Observe standby screen for 30 seconds  
**Expected:** No clock, no weather widget, no ambient content appears  
**Type:** E2E

---

### STANDBY-E-03 — Kiosk mode available on Electron

**Validates:** §14.10 — Electron has kiosk mode for dedicated displays  
**Setup:** Launch Electron with kiosk mode flag  
**Action:** Observe window state  
**Expected:** Fullscreen, no title bar, no OS chrome; suitable for dedicated display use  
**Type:** E2E

---
