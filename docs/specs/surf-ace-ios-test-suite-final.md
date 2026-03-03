# Surf Ace — iOS Implementation Test Suite (Final)

> Derived exclusively from `surf-ace.md` spec (last updated 2026-02-26).  
> Reconciled against adversarial feedback. See `surf-ace-test-reconciliation.md` for change log.  
> Platform: iOS / iPadOS (SwiftUI codebase); Keychain for key storage, WKWebView, PDFKit, PencilKit, NSAttributedString terminal.  
> **Scope:** This suite covers the standalone Surf Ace iOS/iPadOS app. visionOS behaviors belong in a separate platform matrix suite. Spawned surf ace (Clawline annotation) flows belong in a Clawline/provider integration suite.

---

## 1. Discovery — mDNS / Bonjour Publish & Resolve

### DISC-I-01 — Bonjour service type advertisement

**Validates:** §6.1 — service type must be `_surf-ace._tcp`  
**Setup:** Surf Ace app launched and in foreground; connected to LAN  
**Action:** Browse the local network for mDNS services (via DNS-SD or `dns-sd -B _surf-ace._tcp local` from another device)  
**Expected:** The running iOS instance appears with service type `_surf-ace._tcp`  
**Type:** Integration

---

### DISC-I-02 — Required TXT record keys present

**Validates:** §6.1 — all required TXT keys must be present  
**Setup:** Surf Ace app in foreground  
**Action:** Resolve the advertised `_surf-ace._tcp` service and inspect TXT records  
**Expected:** TXT records include all of: `name`, `v`, `w`, `h`, `s`, `cap`, `busy`, `pk`  
**Type:** Integration

---

### DISC-I-03 — TXT `v` is protocol version `1`

**Validates:** §6.1 — `v = "1"` for v1 protocol  
**Setup:** Surf Ace app in foreground  
**Action:** Resolve TXT records and read `v`  
**Expected:** `v = "1"`  
**Type:** Integration

---

### DISC-I-04 — TXT `w` and `h` reflect actual Surf Ace viewport dimensions

**Validates:** §6.1 — `w` and `h` are viewport width/height in points  
**Setup:** Surf Ace app on a known device; note actual scene/window bounds  
**Action:** Resolve TXT records; read `w` and `h`  
**Expected:** `w` and `h` match the Surf Ace scene/window viewport bounds in points — not necessarily the full `UIScreen` dimensions (which may differ in split-view or windowed modes on iPad)  
**Type:** Integration

---

### DISC-I-05 — TXT `s` reflects display scale factor

**Validates:** §6.1 — `s` is the display scale factor  
**Setup:** Surf Ace on a known device (e.g. 3× Retina)  
**Action:** Resolve TXT record `s`  
**Expected:** `s` matches `UIScreen.main.scale` (e.g. `"3"` or `"3.0"` for a 3× device)  
**Type:** Integration

---

### DISC-I-06 — TXT `cap` bitmask matches supported content types

**Validates:** §6.1 — `cap` bitmask: bit 1=html, 2=image, 4=pdf, 8=terminal, 16=markdown  
**Setup:** iOS app supports all five content types  
**Action:** Resolve TXT record `cap`  
**Expected:** `cap = "31"` (1+2+4+8+16), or correctly reflects any actual subset  
**Type:** Integration

---

### DISC-I-07 — TXT `busy` starts as `0`

**Validates:** §6.1 — `busy = 0` with no active session  
**Setup:** Surf Ace app launched, no session  
**Action:** Resolve TXT record `busy`  
**Expected:** `busy = "0"`  
**Type:** Integration

---

### DISC-I-08 — TXT `busy` transitions to `1` when session is active

**Validates:** §6.1 — `busy` updated in real-time when session starts  
**Setup:** Surf Ace app in Standby  
**Action:** `POST /pair` successfully; resolve TXT `busy`  
**Expected:** `busy = "1"`  
**Type:** Integration

---

### DISC-I-09 — TXT `busy` transitions back to `0` when session ends

**Validates:** §6.1 / §6.4 — `busy` set to `0` when session ends  
**Setup:** Active session  
**Action:** Session ends (app quits or screen shuts down); resolve TXT `busy`  
**Expected:** `busy = "0"`  
**Type:** Integration

---

### DISC-I-10 — TXT `pk` is first 8 hex chars of SHA-256 of the public key

**Validates:** §6.1 — `pk` is fingerprint; §6.2 — Ed25519 keypair identity  
**Setup:** Surf Ace app launched; retrieve public key from Keychain via instrumented test hook  
**Action:** Resolve TXT `pk`; independently compute SHA-256 of the public key and take first 8 hex chars  
**Expected:** `pk` matches independently computed fingerprint  
**Note:** Requires instrumented build mode or test hook to access Keychain key material.  
**Type:** Unit (privileged instrumentation test)

---

### DISC-I-11 — Bonjour advertisement active only when app is in foreground (iPhone)

**Validates:** §6.1 / §14.6 — when app backgrounds, iOS suspends HTTP server  
**Setup:** Surf Ace app in foreground on iPhone; confirm mDNS broadcast and HTTP reachability  
**Action:** Move app to background (switch to another app)  
**Expected:** HTTP server becomes unreachable or stops responding; broadcasting may cease or reduce. On foreground return, HTTP server resumes and is reachable again.  
**Type:** Integration / E2E

---

### DISC-I-12 — Identity (keypair) persists across app restarts (Keychain)

**Validates:** §6.2 — Ed25519 keypair stored in Keychain, stable across reboots  
**Setup:** Surf Ace app launched; record `pk`; force-quit and relaunch app  
**Action:** Resolve TXT `pk` again  
**Expected:** `pk` is identical to the value before the restart  
**Type:** Integration

---

### DISC-I-13 — Keypair is stable across app restarts; only changes after explicit identity purge

**Validates:** §6.2 — keypair generated once on first launch; persists across normal restarts  
**Setup:** Surf Ace app launched; record `pk`  
**Action:** Force-quit; relaunch (without clearing Keychain); record `pk` again  
**Expected:** `pk` is the same after normal restart  
**Note:** A fresh keypair is generated when the Keychain item is explicitly purged (e.g., via factory reset flow or test harness Keychain clear). Do NOT assert that app reinstall alone clears the Keychain — iOS Keychain may persist across reinstall.  
**Type:** Integration

---

### DISC-I-14 — iPad broadcasts in Split View alongside Clawline

**Validates:** §14.7 — iPad split view: Surf Ace HTTP server keeps serving while Clawline runs on the other side  
**Setup:** iPad with both Surf Ace and Clawline in Split View  
**Action:** Confirm mDNS is broadcasting; attempt HTTP requests to Surf Ace  
**Expected:** Surf Ace HTTP server is reachable; mDNS record is active  
**Type:** Integration / E2E

---

### DISC-I-15 — TXT `busy` transitions within bounded time after session state change

**Validates:** §6.1 — `busy` is updated in real-time as sessions start and end  
**Setup:** App in known state (Standby or active session)  
**Action:** Trigger a state change (pair or session end); poll TXT `busy` repeatedly  
**Expected:** `busy` reflects the new state within approximately 1 second of the state change  
**Type:** Integration

---

## 2. HTTP Server — Endpoints

### HTTP-I-01 — HTTP server starts on advertised port when app is in foreground

**Validates:** §6.3 / §14.2 — iOS app runs HTTP server on the advertised port  
**Setup:** Surf Ace app in foreground; mDNS service resolved to get `host:port`  
**Action:** Attempt TCP connection to `host:port`  
**Expected:** Connection accepted  
**Type:** Integration

---

### HTTP-I-02 — All endpoints except /pair require Bearer token

**Validates:** §6.3 — Authorization required on all endpoints except `POST /pair`  
**Setup:** Surf Ace app in Standby (no active session)  
**Action:** Send `POST /frame`, `GET /snapshot`, `POST /frame/append`, `POST /frame/patch`, `DELETE /frame`, `POST /watch`, `POST /unwatch` — all without Authorization header  
**Expected:** Each returns `401 Unauthorized`  
**Type:** Integration

---

### HTTP-I-02b — Malformed Authorization header rejected

**Validates:** §6.3 — valid Bearer token required  
**Setup:** Active session  
**Action (a):** `GET /snapshot` with `Authorization: Bearer` (no token)  
**Action (b):** `GET /snapshot` with `Authorization: Basic dXNlcjpwYXNz` (wrong scheme)  
**Action (c):** `GET /snapshot` with `Authorization: Bearer   ` (whitespace-only token)  
**Expected:** Each returns `401 Unauthorized`  
**Type:** Integration

---

### HTTP-I-03 — POST /pair without auth is accepted

**Validates:** §6.3 — `POST /pair` does not require Authorization  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair { "mode": "auto" }` with no Authorization header  
**Expected:** `200 OK` with `{ "status": "ok", "sessionToken": "..." }`  
**Type:** Integration

---

### HTTP-I-04 — DELETE /frame returns 204 No Content

**Validates:** §8.5 / §17.5 — clear response is `204 No Content`  
**Setup:** Active session; frame displayed  
**Action:** `DELETE /frame` with valid Bearer token  
**Expected:** `204 No Content`; screen transitions to connected-idle  
**Type:** Integration

---

### HTTP-I-05 — GET /snapshot returns 204 when no frame displayed

**Validates:** §17.6 — `204 No Content` when connected-idle  
**Setup:** Active session; no frame pushed (after DELETE /frame or immediately after pairing)  
**Action:** `GET /snapshot`  
**Expected:** `204 No Content`  
**Type:** Integration

---

### HTTP-I-06 — GET /snapshot returns full snapshot JSON when frame is displayed

**Validates:** §9.1 — snapshot response shape  
**Setup:** Active session; HTML frame pushed  
**Action:** `GET /snapshot`  
**Expected:** JSON with `frameId`, `contentType`, `title`, `viewport` (`scrollOffset`, `visibleRect`, `contentSize`, `zoomLevel`), `visibleText`, `selection`, `annotations`  
**Type:** Integration

---

### HTTP-I-07 — GET /snapshot frameId matches last pushed frame

**Validates:** §9.1 — snapshot identifies the active frame  
**Setup:** Push frame with `frameId: "fr_aabb1122"`  
**Action:** `GET /snapshot`  
**Expected:** Snapshot `frameId = "fr_aabb1122"`  
**Type:** Integration

---

### HTTP-I-08 — GET /snapshot annotations is empty array in v1

**Validates:** §9.1 — annotations reserved, empty in v1  
**Setup:** Active session; frame displayed  
**Action:** `GET /snapshot`  
**Expected:** `annotations: []`  
**Type:** Integration

---

### HTTP-I-09 — POST /frame replaces existing frame

**Validates:** §8.1 — pushing a new frame replaces the old one  
**Setup:** Active session; push frame A  
**Action:** Push frame B; `GET /snapshot`  
**Expected:** Snapshot `frameId` matches frame B's `frameId`; frame A is gone  
**Type:** Integration

---

### HTTP-I-10 — POST /frame with expired session token returns 401

**Validates:** §6.4 / §15.3 — expired session token rejected  
**Setup:** Active session; end the session (quit the app); attempt to reuse old token  
**Action:** `POST /frame` with old token  
**Expected:** `401 Unauthorized`  
**Type:** Integration

---

### HTTP-I-11 — POST /frame/append stale frameId returns 409 Conflict

**Validates:** §8.4 — stale frameId → `409 Conflict { "error": "stale_frame" }`  
**Setup:** Active session; push terminal frame A; push frame B replacing A  
**Action:** `POST /frame/append` using frame A's `frameId`  
**Expected:** `409 Conflict`, body `{ "error": "stale_frame" }`  
**Type:** Integration

---

### HTTP-I-12 — POST /frame/patch stale frameId returns 409 Conflict

**Validates:** §8.4 — stale frameId → `409 Conflict { "error": "stale_frame" }`  
**Setup:** Active session; push HTML frame A; push frame B replacing A  
**Action:** `POST /frame/patch` using frame A's `frameId`  
**Expected:** `409 Conflict`, body `{ "error": "stale_frame" }`  
**Type:** Integration

---

### HTTP-I-13 — POST /frame/append only valid for terminal frames

**Validates:** §8.4 — append only for `terminal`  
**Setup:** Active session; HTML frame displayed  
**Action:** `POST /frame/append` referencing the HTML frame's `frameId`  
**Expected:** `422 Unprocessable Entity`  
**Type:** Integration

---

### HTTP-I-14 — POST /frame/patch only valid for HTML frames

**Validates:** §8.4 — patch only for `html`  
**Setup:** Active session; terminal frame displayed  
**Action:** `POST /frame/patch` referencing the terminal frame's `frameId`  
**Expected:** `422 Unprocessable Entity`  
**Type:** Integration

---

### HTTP-I-15 — POST /frame/patch all five patch actions accepted (isolated subtests)

**Validates:** §8.4 — patch actions: `replace_inner`, `replace_outer`, `insert_before`, `insert_after`, `remove`  
**Setup:** For each action: push a fresh HTML frame with `<div id="t">content</div>`, then apply one action  
**Action:** For each action type independently, push a fresh frame and send `POST /frame/patch` with `selector: "#t"` and that action  
**Expected:** Each returns `200 OK`; screen content changes appropriately for each action  
**Note:** Each action must run in isolation with a fresh frame to prevent selector invalidation from prior actions causing false failures.  
**Type:** Integration

---

### HTTP-I-16 — POST /watch returns 200 OK

**Validates:** §9.2 / §17.7 — watch subscribe response  
**Setup:** Active session  
**Action:** `POST /watch` with valid callbackUrl and events list  
**Expected:** `200 OK`  
**Type:** Integration

---

### HTTP-I-17 — POST /unwatch returns 200 OK and stops events

**Validates:** §9.2 / §17.8 — unsubscribe stops events  
**Setup:** Active session in watch mode  
**Action:** `POST /unwatch`  
**Expected:** `200 OK`; no further event POSTs to callbackUrl  
**Type:** Integration

---

## 3. Provider Callbacks — Watch Mode Events

### CB-I-01 — Screen POSTs text_selected event to callbackUrl

**Validates:** §9.3 — `text_selected` event shape  
**Setup:** Active session in watch mode; HTML or markdown frame with selectable text; callback server listening  
**Action:** User selects text on the screen  
**Expected:** Callback POST with `event: "text_selected"`, `frameId`, `text`, `boundingRect` (`x`, `y`, `width`, `height`), `timestamp`  
**Type:** E2E / Integration

---

### CB-I-02 — text_selected fires immediately (debounce = 0)

**Validates:** §9.2 — default debounce for `text_selected` is `0`  
**Setup:** Watch mode with `text_selected` subscribed and `debounce.text_selected: 0`  
**Action:** User selects text  
**Expected:** Event POSTed without artificial delay  
**Type:** Integration

---

### CB-I-03 — scroll_settle fires after configured debounce (~500ms)

**Validates:** §9.2 — screen debounces per config; `scroll_settle` default 500ms  
**Setup:** Watch mode subscribed to `scroll_settle` at 500ms debounce; scrollable frame  
**Action:** Scroll; stop scrolling; measure time to callback  
**Expected:** Callback arrives ~500ms after scroll stops; not during active scrolling  
**Type:** Integration

---

### CB-I-04 — scroll_settle event shape correct

**Validates:** §9.3 — `scroll_settle` event shape  
**Setup:** Watch mode; scrollable HTML or markdown frame  
**Action:** Scroll; settle  
**Expected:** Callback contains `event: "scroll_settle"`, `frameId`, `viewport` (`scrollOffset`, `visibleRect`, `contentSize`, `zoomLevel`), `visibleText`, `timestamp`  
**Type:** Integration

---

### CB-I-05 — zoom_settle event fires after pinch-zoom

**Validates:** §9.3 — `zoom_settle` event shape  
**Setup:** Watch mode with `zoom_settle` subscribed; zoomable frame  
**Action:** Pinch-zoom; release  
**Expected:** Callback contains `event: "zoom_settle"`, `frameId`, `viewport` with updated `zoomLevel`, `visibleText`, `timestamp`  
**Type:** Integration

---

### CB-I-06 — point event fires on tap or long-press

**Validates:** §9.3 — `point` event  
**Setup:** Watch mode with `point` subscribed; frame displayed  
**Action (a):** User taps on the frame  
**Action (b):** User long-presses on the frame  
**Expected:** Both produce callback containing `event: "point"`, `frameId`, `position` (`x`, `y`), `nearestContent`, `timestamp`  
**Type:** Integration

---

### CB-I-07 — region event fires when user draws a selection rectangle

**Validates:** §9.3 — `region` event shape  
**Setup:** Watch mode with `region` subscribed; frame displayed  
**Action:** User performs a rectangular drag gesture on the overlay (exact gesture: touch-and-hold, then drag to form a rectangle)  
**Expected:** Callback contains `event: "region"`, `frameId`, `rect` (`x`, `y`, `width`, `height`), `containedText`, `timestamp`  
**Type:** Integration

---

### CB-I-08 — page_change event fires on PDF page navigation

**Validates:** §9.3 — `page_change` event  
**Setup:** Watch mode with `page_change` subscribed; multi-page PDF displayed  
**Action:** User navigates to a different page  
**Expected:** Callback contains `event: "page_change"`, `frameId`, `page`, `totalPages`, `pageText`, `timestamp`  
**Type:** Integration

---

### CB-I-10 — Event POST: exactly one retry after ~1 second, then drop

**Validates:** §16.9 — one retry after 1s, then drop; events are best-effort  
**Setup:** Watch mode active; callback server intentionally unreachable  
**Action:** Trigger a watch event  
**Expected:** Screen makes exactly 2 POST attempts (initial + 1 retry approximately 1 second later); no further retries; no infinite retry loop  
**Type:** Integration

---

### CB-I-11 — All events go to the single callbackUrl from POST /watch

**Validates:** §9.2 — single callback URL for all event types  
**Setup:** Watch mode with multiple event types subscribed  
**Action:** Trigger `text_selected`, `point`, and `scroll_settle`  
**Expected:** All three events arrive at the same callbackUrl  
**Type:** Integration

---

## 4. Content Rendering

### RENDER-I-01 — HTML frame renders via WKWebView

**Validates:** §14.5 — iOS renders HTML via WKWebView  
**Setup:** Active session  
**Action:** Push `{ "contentType": "html", "content": { "html": "<html><body><p id='hello'>Hello World</p></body></html>" } }`  
**Expected:** Screen renders HTML; `GET /snapshot` `visibleText` includes "Hello World"  
**Type:** Integration

---

### RENDER-I-02 — HTML frame injects CSS variables

**Validates:** §14.5 — CSS variables: `--surf-ace-bg`, `--surf-ace-fg`, `--surf-ace-accent`, `--surf-ace-font-size`, `--surf-ace-width`, `--surf-ace-height`  
**Setup:** Active session; HTML frame that reads and displays CSS variable values  
**Action:** Push HTML that reads and displays the CSS variables  
**Expected:** All six CSS variables are present and non-empty  
**Type:** Integration

---

### RENDER-I-03 — Image frame renders and reports alt text as visibleText

**Validates:** §8.2 / §9.1 — image rendering; visibleText is alt text  
**Setup:** Active session  
**Action:** Push `{ "contentType": "image", "content": { "data": "<base64 PNG>", "mediaType": "image/png", "alt": "test" } }`  
**Expected:** `GET /snapshot` `visibleText = "test"` (alt text)  
**Note:** Test validates observable behavior (rendered output + snapshot). Implementation choice (native image view) is not a test gate.  
**Type:** Integration

---

### RENDER-I-04 — PDF frame renders and reports page text as visibleText

**Validates:** §8.2 / §9.1 — PDF rendering; visibleText is text on visible page  
**Setup:** Active session  
**Action:** Push `{ "contentType": "pdf", "content": { "data": "<base64 PDF>" } }`  
**Expected:** `GET /snapshot` `contentType = "pdf"`; `visibleText` includes text from the visible page  
**Note:** Test validates observable behavior (rendering output + snapshot). Implementation choice (PDFKit) is not a test gate.  
**Type:** Integration

---

### RENDER-I-05 — Terminal frame renders and reports visible lines as visibleText

**Validates:** §8.2 / §9.1 / §14.5 — terminal rendering; ANSI color support; visibleText is visible lines  
**Setup:** Active session  
**Action:** Push `{ "contentType": "terminal", "content": { "lines": ["\u001b[32mgreen\u001b[0m", "plain"], "scrollback": 100 } }`  
**Expected:** Lines displayed in monospace; ANSI color codes rendered as colors; `GET /snapshot` `visibleText` includes "green" and "plain"  
**Note:** Test validates observable behavior. Implementation choice (NSAttributedString) is not a test gate.  
**Type:** Integration

---

### RENDER-I-06 — Markdown frame renders and reports visibleText

**Validates:** §14.5 / §9.1 — markdown rendering with native markdown rendering  
**Setup:** Active session  
**Action:** Push `{ "contentType": "markdown", "content": { "markdown": "# Heading\n\nParagraph" } }`  
**Expected:** Heading and paragraph render correctly; `GET /snapshot` `visibleText` includes "Heading" and "Paragraph"  
**Type:** Integration

---

### RENDER-I-07 — Terminal append adds lines

**Validates:** §8.4 — append adds lines to terminal frame  
**Setup:** Active session; terminal frame with initial lines  
**Action:** `POST /frame/append` with new lines  
**Expected:** New lines visible; `GET /snapshot` `visibleText` includes appended content  
**Type:** Integration

---

### RENDER-I-08 — HTML patch replace_inner updates WKWebView DOM

**Validates:** §8.4 — `replace_inner` updates inner HTML of selector match  
**Setup:** Active session; HTML frame with `<span id="s">old</span>`  
**Action:** `POST /frame/patch { selector: "#s", action: "replace_inner", html: "new" }`  
**Expected:** Screen shows "new"; `GET /snapshot` `visibleText` reflects the update  
**Type:** Integration

---

### RENDER-I-09 — snapshot visibleText for HTML is DOM textContent of visible elements

**Validates:** §9.1 — HTML `visibleText` is DOM `textContent` of elements intersecting the visible rect  
**Setup:** Active session; HTML frame with known visible text and known off-screen text  
**Action:** `GET /snapshot`  
**Expected:** `visibleText` includes visible text; does not include text scrolled off-screen  
**Type:** Integration

---

### RENDER-I-10 — snapshot visibleText for terminal is visible lines

**Validates:** §9.1 — terminal `visibleText` is the visible lines  
**Setup:** Active session; terminal frame scrolled so only lines 50–80 are visible  
**Action:** `GET /snapshot`  
**Expected:** `visibleText` contains lines 50–80; lines 1–49 not included  
**Type:** Integration

---

### RENDER-I-11 — snapshot visibleText for PDF is text on visible page(s)

**Validates:** §9.1 — PDF `visibleText` is text on visible page(s)  
**Setup:** Active session; multi-page PDF; navigate to page 2  
**Action:** `GET /snapshot`  
**Expected:** `visibleText` contains text from page 2  
**Type:** Integration

---

### RENDER-I-12 — snapshot visibleText for image is alt text

**Validates:** §9.1 — image `visibleText` is `alt` text  
**Setup:** Active session; image frame with `alt: "Architecture diagram"`  
**Action:** `GET /snapshot`  
**Expected:** `visibleText = "Architecture diagram"`  
**Type:** Integration

---

### RENDER-I-13 — snapshot visibleText truncated to 4KB

**Validates:** §9.1 — `visibleText` truncated to 4KB  
**Setup:** Active session; HTML frame with > 4KB of visible text  
**Action:** `GET /snapshot`  
**Expected:** `visibleText` length ≤ 4096 characters  
**Type:** Integration

---

### RENDER-I-14 — snapshot selection is null when no selection

**Validates:** §9.1 — `selection: null` when no user selection  
**Setup:** Active session; HTML frame displayed; no text selected  
**Action:** `GET /snapshot`  
**Expected:** `selection: null`  
**Type:** Integration

---

### RENDER-I-15 — snapshot selection is populated when text is selected

**Validates:** §9.1 — `selection` object with `kind: "text"`, `text`, `boundingRect`  
**Setup:** Active session; HTML frame; user selects a specific text range  
**Action:** `GET /snapshot`  
**Expected:** `selection.kind = "text"`, `selection.text` matches selected text, `selection.boundingRect` present  
**Type:** Integration / E2E

---

### RENDER-I-16 — snapshot selection supports point and region kinds

**Validates:** §9.1 — selection kinds: `text`, `point`, `region`  
**Setup:** Active session; frame displayed  
**Action (a):** User long-presses without selecting text → `GET /snapshot`; expect `selection.kind = "point"`  
**Action (b):** User performs a region draw gesture → `GET /snapshot`; expect `selection.kind = "region"`  
**Expected:** Correct `kind` in each case  
**Type:** E2E

---

### RENDER-I-17 — HTML baseUrl accepted and applied

**Validates:** §8.2 — HTML content shape includes optional `baseUrl`  
**Setup:** Active session  
**Action:** Push HTML with `content: { html: "...", baseUrl: "https://example.com/" }`  
**Expected:** `200 OK`; relative URLs in the page resolve against `baseUrl`  
**Type:** Integration

---

## 5. Pencil / Markup System (Apple Pencil — iOS/iPadOS)

### PENCIL-I-01 — Short debounce fires ~500ms after Apple Pencil lifts

**Validates:** §13.2 — short debounce ~500ms after pencil lifts  
**Setup:** Active session; frame displayed; PencilKit overlay active; callback server listening  
**Action:** Draw a stroke with Apple Pencil; lift pencil; measure time to callback POST  
**Expected:** Callback POST with `event: "strokes"` arrives approximately 500ms after pencil lift  
**Type:** Integration / E2E

---

### PENCIL-I-02 — Short debounce payload shape correct

**Validates:** §13.3 — short debounce payload fields  
**Setup:** Active session; frame displayed; Apple Pencil stroke drawn  
**Action:** Wait for short debounce callback  
**Expected:** Body contains `event: "strokes"`, `frameId`, `strokes` (array with `points` and `tool`), `crop` (base64), `cropRect` (`x`, `y`, `w`, `h`), `timestamp`  
**Type:** Integration

---

### PENCIL-I-03 — Apple Pencil stroke points include pressure

**Validates:** §13.3 — pressure data available for Apple Pencil (`tool: "pencil"`)  
**Setup:** Active session; stroke drawn with Apple Pencil  
**Action:** Inspect short debounce callback `strokes[0].points`  
**Expected:** Each point has `x`, `y`, `pressure` (0.0–1.0), `timestamp`; `tool = "pencil"`  
**Type:** Integration

---

### PENCIL-I-04 — Finger stroke tool is `"finger"` and has no pressure

**Validates:** §13.3 — `tool` is `"finger"` for finger; pressure absent  
**Setup:** Active session; stroke drawn with finger  
**Action:** Inspect short debounce callback  
**Expected:** `strokes[0].tool = "finger"`; no `pressure` field (or absent/null) in each point  
**Type:** Integration

---

### PENCIL-I-05 — Palm rejection active during Apple Pencil use

**Validates:** §13.8 — "The surf ace does handle: Palm rejection."  
**Setup:** Active session; PencilKit overlay active; Apple Pencil in use  
**Action:** Rest palm on screen while drawing with Apple Pencil  
**Expected:** Palm contact does not produce strokes; only Pencil strokes captured  
**Type:** E2E

---

### PENCIL-I-06 — Long debounce fires ~3–5s after last stroke

**Validates:** §13.2 — long debounce ~3–5s of no new strokes  
**Setup:** Active session; frame displayed; draw one stroke; stop  
**Action:** Measure time from last stroke to long-debounce callback  
**Expected:** Long-debounce POST with `event: "surf ace_snapshot"` arrives 3–5 seconds after last stroke  
**Type:** Integration / E2E

---

### PENCIL-I-07 — Long debounce payload shape correct

**Validates:** §13.3 — long debounce payload fields  
**Setup:** Active session; stroke drawn; long debounce fires  
**Action:** Inspect long debounce callback  
**Expected:** Body contains `event: "surf ace_snapshot"`, `frameId`, `image` (base64), `strokesSinceLastSnapshot` (array of stroke objects), `timestamp`  
**Type:** Integration

---

### PENCIL-I-08 — Long debounce `image` is a full-screen screenshot with strokes overlaid

**Validates:** §13.3 — full surf ace screenshot with strokes overlaid  
**Setup:** Active session; HTML frame displayed; strokes drawn  
**Action:** Wait for long debounce callback; decode `image`  
**Expected:** Decoded image dimensions match viewport (in pixels at display scale); shows pushed content AND drawn strokes rendered on top  
**Type:** Integration

---

### PENCIL-I-09 — Short debounce `crop` covers local area around strokes

**Validates:** §13.3 — crop screenshot is local area around strokes  
**Setup:** Active session; frame displayed; draw strokes in a known region (e.g. top-left quadrant)  
**Action:** Wait for short debounce callback; inspect `crop` and `cropRect`  
**Expected:** `cropRect` bounds approximately match the stroke region; decoded `crop` image shows that area with strokes on content  
**Type:** Integration

---

### PENCIL-I-10 — Short debounce fires before long debounce

**Validates:** §13.2 — short (~500ms) fires before long (~3–5s); both fire independently  
**Setup:** Active session; frame displayed  
**Action:** Draw stroke; lift pencil; observe callback sequence  
**Expected:** Short-debounce (`strokes`) callback fires ~500ms after lift; long-debounce (`surf ace_snapshot`) fires 3–5s after last stroke; short always precedes long  
**Type:** Integration

---

### PENCIL-I-11 — Strokes sent to provider callback URL (same as watch events)

**Validates:** §13.3 — stroke payloads POSTed to `/surf-ace/events/<screenId>` (same endpoint as watch events)  
**Setup:** Active session  
**Action:** Draw strokes; observe callback URL in the POST request  
**Expected:** Stroke POSTs go to the same callback URL established via `POST /watch` or provider connection  
**Type:** Integration

---

### PENCIL-I-12 — Strokes buffered during frame push, not lost

**Validates:** §16.10 — strokes drawn during frame push must not be lost  
**Setup:** Active session; frame displayed; begin drawing strokes  
**Action:** Simultaneously push a new frame; check next debounce payload  
**Expected:** Next debounce payload includes strokes drawn before, during, and after the frame push; no strokes dropped  
**Type:** Integration

---

### PENCIL-I-13 — Continuous drawing: nothing fires until idle gap

**Validates:** §16.11 — during continuous drawing (pencil never lifts), NOTHING fires; long debounce timer resets on every new stroke and fires only after drawing stops (idle gap of 3–5s with no new strokes)  
**Setup:** Active session; frame displayed  
**Action:** Draw continuously for 15+ seconds without lifting Apple Pencil; then stop and observe  
**Expected:** No `strokes` (short debounce) events fire during continuous drawing; no long-debounce (`surf ace_snapshot`) events fire during continuous drawing; after pencil lifts, long debounce fires once after the 3–5s idle gap  
**Note:** §16.11 is explicit: the long debounce timer resets on every new stroke. Nothing fires while the user is actively drawing. Long debounce fires only on idle gap (pencil lifts or no new strokes for 3–5s).  
**Type:** Integration / E2E

---

### PENCIL-I-14 — Change stack records frames received in order

**Validates:** §13.4 / §13.6 — surf ace maintains ordered change stack of received frames  
**Setup:** Active session  
**Action:** Push 3 distinct frames; inspect change stack (via test API or observable state)  
**Expected:** Change stack contains all 3 frames in push order; newest is current  
**Note:** Requires instrumented test hook exposing the change stack. This is a spec requirement for CLU-driven undo (§13.4).  
**Type:** Unit (via internal test hook)

---

### PENCIL-I-15 — Strokes render on transparent overlay above content

**Validates:** §13.8 — strokes rendered as-is on a transparent overlay above the content  
**Setup:** Active session; HTML frame displayed  
**Action:** Draw strokes; observe screen  
**Expected:** Strokes appear above the HTML content without obscuring it; underlying content is still visible through the overlay  
**Type:** E2E

---

### PENCIL-I-16 — Surf ace does NOT perform gesture recognition

**Validates:** §13.1 / §13.8 — no circle detector, no arrow detector, no handwriting recognizer on the surf ace  
**Setup:** Active session; frame displayed  
**Action:** Draw a circle gesture; draw an underline; write letters  
**Expected:** Raw stroke points are sent to provider without any pre-processing, classification, or transformation; callback payload shows raw `strokes` with point arrays only  
**Type:** Integration (verify callback payload shows raw points only)

---

## 6. Pairing

### PAIR-I-01 — Auto mode pairing returns sessionToken

**Validates:** §7.3 / §17.1 — auto mode pairing  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair { "mode": "auto" }`  
**Expected:** `200 OK`, `{ "status": "ok", "sessionToken": "<token>" }`  
**Type:** Integration

---

### PAIR-I-02 — Session token is 32 bytes hex-encoded (64 chars)

**Validates:** §15.3 — session token is 32 bytes, hex-encoded  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair { "mode": "auto" }`; inspect `sessionToken`  
**Expected:** 64-character lowercase hexadecimal string  
**Type:** Integration

---

### PAIR-I-12 — Second POST /pair when busy returns 409 Conflict

**Validates:** §6.5 — `409 Conflict { "error": "busy" }` when screen is occupied  
**Setup:** Active session  
**Action:** `POST /pair { "mode": "auto" }` from a second client  
**Expected:** `409 Conflict`, body `{ "error": "busy" }`  
**Type:** Integration

---

### PAIR-I-14 — Keypair stored in iOS Keychain

**Validates:** §6.2 / §14.2 — identity generated on first launch, stored in Keychain  
**Setup:** Fresh install (Keychain item absent)  
**Action:** Launch app; verify Keychain contains the Ed25519 keypair via instrumented test hook; verify `pk` TXT matches Keychain public key  
**Expected:** Keychain item exists for the keypair; `pk` fingerprint matches Keychain key  
**Note:** Requires instrumented build or test hook for Keychain access.  
**Type:** Unit / Integration (privileged instrumentation test)

---

## 7. Session Lifecycle

### SESS-I-01 — Session starts on successful POST /pair

**Validates:** §7.5 — session starts at `POST /pair` success  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair`; observe state  
**Expected:** Session active; `busy=1` in TXT; screen shows Connected (idle) state  
**Type:** Integration

---

### SESS-I-02 — Screen clears content and goes idle when session ends

**Validates:** §6.4 / §7.5 — session end clears content, screen goes idle, `busy=0`, token invalidated  
**Setup:** Active session; frame displayed  
**Action:** Force-quit the app; observe screen and TXT  
**Expected:** Screen shows Standby state; `busy=0`; session token invalid  
**Note:** DELETE /frame does NOT end the session — it transitions to connected-idle (see SESS-I-09). Sessions have no inactivity timeout (§6.4) — they end only on explicit clear or shutdown.  
**Type:** Integration

---

### SESS-I-05 — iPhone backgrounding suspends HTTP server

**Validates:** §14.6 — iOS suspends HTTP server when app is backgrounded  
**Setup:** Surf Ace running in foreground on iPhone; active session; frame displayed  
**Action:** Switch to another app (Surf Ace backgrounds)  
**Expected:** HTTP server becomes unreachable; provider cannot make new requests  
**Type:** Integration / E2E

---

### SESS-I-06 — iPhone foreground resume: session continues

**Validates:** §14.6 / §6.4 — user switches back; HTTP server wakes up; session continues (no TTL)  
**Setup:** Surf Ace backgrounded with active session and frame displayed  
**Action:** Switch back to Surf Ace  
**Expected:** HTTP server becomes reachable again; provider's next request succeeds; session continues; frame reappears  
**Type:** Integration / E2E

---

### SESS-I-08 — Screen holds last frame if provider permanently unreachable

**Validates:** §6.6 — screen holds last displayed frame indefinitely if provider is permanently unreachable  
**Setup:** Active session; frame displayed; disconnect provider  
**Action:** Observe screen over time (without backgrounding app)  
**Expected:** Last frame persists; screen does not self-clear  
**Type:** Integration

---

### SESS-I-09 — DELETE /frame leaves session active (connected-idle)

**Validates:** §8.5 / §8.6 — DELETE /frame → connected-idle; session still active  
**Setup:** Active session; frame displayed  
**Action:** `DELETE /frame`  
**Expected:** Session still active; token still valid; `GET /snapshot` returns `204`; screen shows "Connected" indicator, not Standby  
**Type:** Integration

---

### SESS-I-10 — On app quit, session ends

**Validates:** §7.5 — session ends on screen shutdown  
**Setup:** Active session  
**Action:** Force-quit Surf Ace app  
**Expected:** Session terminated; `busy=0` (or mDNS record removed); HTTP server unreachable  
**Type:** Integration / E2E

---

### SESS-I-11 — Session token invalidated after session ends

**Validates:** §6.4 — session token invalid after session end  
**Setup:** Active session; record token; end session (quit the app)  
**Action:** `POST /frame` with old token  
**Expected:** `401 Unauthorized`  
**Type:** Integration

---

### SESS-I-12 — Frame persists while app is in foreground even if provider goes offline

**Validates:** §6.6 — "If the provider becomes permanently unreachable, the screen holds the last frame indefinitely. It only goes idle on explicit clear or app quit."  
**Setup:** Active session; frame displayed; app in foreground; shut down provider (simulate TARS offline)  
**Action:** Wait longer than 5 minutes without backgrounding Surf Ace  
**Expected:** Frame is still displayed; session does not self-expire due to provider absence alone (sessions have no inactivity timeout — §6.4)  
**Type:** Integration

---

## 8. Edge Cases

### EDGE-I-01 — POST /frame with unsupported content type returns 422 unsupported_type

**Validates:** §6.7 — `unsupported_type` error  
**Setup:** Active session  
**Action:** Push frame with `contentType: "video"` (not in spec's type set)  
**Expected:** `422 Unprocessable Entity`, `{ "error": { "code": "unsupported_type", ... } }`  
**Type:** Integration

---

### EDGE-I-02 — HTML frame exceeding 256KB returns 422 content_too_large

**Validates:** §6.7 / §8.2 — HTML limit 256KB  
**Setup:** Active session  
**Action:** Push HTML frame with `html` field > 256KB  
**Expected:** `422 Unprocessable Entity`, `{ "error": { "code": "content_too_large", ... } }`  
**Type:** Integration

---

### EDGE-I-03 — Image frame exceeding 10MB returns 422 content_too_large

**Validates:** §8.2 — image limit 10MB (base64)  
**Setup:** Active session  
**Action:** Push image frame with `data` > 10MB  
**Expected:** `422 Unprocessable Entity`, `content_too_large`  
**Type:** Integration

---

### EDGE-I-04 — PDF frame exceeding 10MB returns 422 content_too_large

**Validates:** §8.2 — PDF limit 10MB (base64)  
**Setup:** Active session  
**Action:** Push PDF frame with `data` > 10MB  
**Expected:** `422 Unprocessable Entity`, `content_too_large`  
**Type:** Integration

---

### EDGE-I-05 — Markdown frame exceeding 64KB returns 422 content_too_large

**Validates:** §8.2 — markdown limit 64KB  
**Setup:** Active session  
**Action:** Push markdown frame with `markdown` > 64KB  
**Expected:** `422 Unprocessable Entity`, `content_too_large`  
**Type:** Integration

---

### EDGE-I-06 — Terminal frame at 10,000 lines is accepted

**Validates:** §8.2 — terminal limit 10,000 lines  
**Setup:** Active session  
**Action:** Push terminal frame with exactly 10,000 lines  
**Expected:** `200 OK`  
**Type:** Integration

---

### EDGE-I-07 — Invalid base64 image returns 422 decode_failed

**Validates:** §6.7 — `decode_failed`  
**Setup:** Active session  
**Action:** Push image frame with `data: "not-valid-base64!!!"`  
**Expected:** `422 Unprocessable Entity`, `{ "error": { "code": "decode_failed", ... } }`  
**Type:** Integration

---

### EDGE-I-08 — Missing frameId in POST /frame returns error

**Validates:** §8.1 — `frameId` required  
**Setup:** Active session  
**Action:** POST /frame JSON without `frameId`  
**Expected:** `422 Unprocessable Entity`  
**Type:** Unit / Integration

---

### EDGE-I-09 — Missing contentType in POST /frame returns error

**Validates:** §8.1 — `contentType` required  
**Setup:** Active session  
**Action:** POST /frame JSON without `contentType`  
**Expected:** `422 Unprocessable Entity`  
**Type:** Unit / Integration

---

### EDGE-I-10 — Malformed JSON in POST /frame returns 400

**Validates:** HTTP API correctness  
**Setup:** Active session  
**Action:** POST to `/frame` with body `"not json"`  
**Expected:** `400 Bad Request`  
**Type:** Unit / Integration

---

### EDGE-I-11 — Concurrent POST /frame requests handled without crash

**Validates:** §16.8 — concurrent requests handled gracefully  
**Setup:** Active session  
**Action:** Send 5 concurrent `POST /frame` requests with distinct frameIds  
**Expected:** Server handles all without crash; one frame is active; no corrupted state  
**Type:** Integration

---

### EDGE-I-12 — GET /snapshot during active render returns 200 with current state

**Validates:** §16.8 — snapshot during render returns current visible state; no 500 errors  
**Setup:** Active session; push a PDF frame (takes time to load)  
**Action:** `GET /snapshot` immediately after POST /frame (before render completes)  
**Expected:** `200 OK` with snapshot; `frameId` in snapshot identifies the relevant frame; no 500 errors  
**Note:** Once a frame is accepted (POST /frame returns 200), GET /snapshot must return 200 with whatever is currently visible. `204` is only valid when no frame has been pushed or after DELETE /frame.  
**Type:** Integration

---

### EDGE-I-13 — POST /frame/append with unknown frameId returns 409

**Validates:** §8.4 — unknown frameId → `409 Conflict { "error": "stale_frame" }`  
**Setup:** Active session; terminal frame displayed  
**Action:** `POST /frame/append` with a `frameId` never pushed  
**Expected:** `409 Conflict`, `{ "error": "stale_frame" }`  
**Type:** Integration

---

### EDGE-I-14 — Screen factory reset generates new keypair and new pk

**Validates:** §16.6 / §6.2 — factory reset (Keychain purge) causes new identity  
**Setup:** Surf Ace with known identity; record `pk`  
**Action:** Clear Keychain (factory reset flow); relaunch app; resolve TXT `pk`  
**Expected:** `pk` has changed; new value is a valid 8-hex-char fingerprint  
**Note:** Provider-side behavior (detecting mismatch, flagging as untrusted, requiring re-pair) is a provider test. This test validates only the screen-side requirement.  
**Type:** Integration

---

### EDGE-I-15 — Error during live update in watch mode reported as error event on callback

**Validates:** §6.7 — errors during live updates in watch mode reported as error events on callback URL  
**Setup:** Active session in watch mode; HTML frame displayed  
**Action:** `POST /frame/patch` with a selector that fails to match or with malformed HTML causing render error  
**Expected:** Endpoint returns `422`; callback URL receives an error event containing `event`, `frameId`, `timestamp`, and structured error details  
**Type:** Integration

---

### EDGE-I-16 — Content is self-contained (no external network required)

**Validates:** §8.2 — "All content must be self-contained. Screens are local devices with no guaranteed internet access."  
**Setup:** Active session; device with no internet access (airplane mode, WiFi only to LAN)  
**Action:** Push HTML frame with inline styles and no external resources; push image frame with base64 data; push PDF frame with base64 data  
**Expected:** All frames render correctly without internet access  
**Type:** E2E

---

### EDGE-I-18 — Multiple providers: second sees busy=1 and cannot pair

**Validates:** §16.7 — first-come-first-served occupancy  
**Setup:** First provider has active session  
**Action:** Second provider sends `POST /pair`  
**Expected:** `409 Conflict { "error": "busy" }`  
**Type:** Integration

---

### EDGE-I-19 — Pencil strokes during frame push: strokes buffered and not lost

**Validates:** §16.10 — strokes during frame push are buffered and not lost  
**Setup:** Active session; drawing in progress  
**Action:** Provider pushes a new frame mid-stroke; strokes continue after frame renders  
**Expected:** Next debounce payload contains all strokes (before, during, and after frame push); no strokes dropped  
**Type:** Integration

---

### EDGE-I-20 — POST /frame/patch with invalid action returns 422

**Validates:** §8.4 — patch actions are enumerated; unknown action is invalid  
**Setup:** Active session; HTML frame displayed  
**Action:** `POST /frame/patch` with `action: "explode"` (unknown action)  
**Expected:** `422 Unprocessable Entity` with structured error  
**Type:** Integration

---

### EDGE-I-22 — POST /frame/append with missing or invalid lines field returns 422

**Validates:** §8.4 — append payload requires `append.lines` as array of strings  
**Setup:** Active session; terminal frame displayed  
**Action (a):** `POST /frame/append` with body missing `append.lines`  
**Action (b):** `POST /frame/append` with `append.lines` as a non-array value  
**Expected:** `422 Unprocessable Entity` in both cases  
**Type:** Unit / Integration

---

## 9. Standby / Idle Display

### STANDBY-I-01 — Standby shows screen name, network indicator, fingerprint

**Validates:** §14.4 — standby display: name (large, centered), network status icon, fingerprint (small, bottom corner)  
**Setup:** Surf Ace launched, no session  
**Action:** Observe the iOS screen UI  
**Expected:** Screen name prominently centered; network status visible; fingerprint in a bottom corner  
**Type:** E2E

---

### STANDBY-I-02 — Standby shows NO clock, weather, or ambient content

**Validates:** §14.4 — "No clock, no weather, no ambient content."  
**Setup:** Surf Ace launched, no session  
**Action:** Observe standby for 60 seconds  
**Expected:** No clock, weather widget, or ambient content appears  
**Type:** E2E

---

### STANDBY-I-04 — Connected-idle state shows screen name and "Connected" indicator

**Validates:** §8.5 / §13.3 screen states — connected-idle: name + "Connected" indicator  
**Setup:** Active session; no frame pushed  
**Action:** Observe screen after successful pairing before any frame push  
**Expected:** Screen name and subtle "Connected" indicator visible; no content  
**Type:** E2E

---

### STANDBY-I-05 — iPhone: Surf Ace is full-screen when in foreground

**Validates:** §14.6 — "User sees CLU's pushed content full-screen"  
**Setup:** Surf Ace in foreground on iPhone  
**Action:** Push an HTML frame  
**Expected:** Content renders full-screen on the iPhone display  
**Type:** E2E

---
