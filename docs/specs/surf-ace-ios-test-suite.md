# Surf Ace — iOS Implementation Test Suite

> Derived exclusively from `surf-ace.md` spec (last updated 2026-02-25).  
> These tests validate spec compliance — they catch divergence between the iOS implementation and the protocol contract.  
> Platform: iOS / iPadOS / macOS / visionOS (SwiftUI codebase); Keychain for key storage, WKWebView, PDFKit, PencilKit, NSAttributedString terminal.

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

### DISC-I-04 — TXT `w` and `h` reflect actual viewport dimensions

**Validates:** §6.1 — `w` and `h` are viewport width/height in points  
**Setup:** Surf Ace app on a known device (e.g. iPhone 15 Pro with known point dimensions)  
**Action:** Resolve TXT records; read `w` and `h`  
**Expected:** `w` and `h` match the device's UIScreen point dimensions  
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
**Action:** Session expires or is explicitly cleared; resolve TXT `busy`  
**Expected:** `busy = "0"`  
**Type:** Integration

---

### DISC-I-10 — TXT `pk` is first 8 hex chars of SHA-256 of the public key

**Validates:** §6.1 — `pk` is fingerprint; §6.2 — Ed25519 keypair identity  
**Setup:** Surf Ace app launched; retrieve public key from Keychain  
**Action:** Resolve TXT `pk`; independently compute SHA-256 of the public key and take first 8 hex chars  
**Expected:** `pk` matches independently computed fingerprint  
**Type:** Unit (with known key fixture from Keychain)

---

### DISC-I-11 — Bonjour advertisement active only when app is in foreground (iPhone)

**Validates:** §6.1 / §14.6 — when app moves to background, iOS suspends HTTP server; broadcast behavior  
**Setup:** Surf Ace app in foreground on iPhone; observe mDNS broadcast  
**Action:** Move app to background (switch to another app)  
**Expected:** mDNS advertisement may disappear or the HTTP server becomes unreachable; broadcasting resumes on foreground return  
**Type:** Integration / E2E

---

### DISC-I-12 — Identity (keypair) persists across app restarts (Keychain)

**Validates:** §6.2 — Ed25519 keypair stored in Keychain, stable across reboots  
**Setup:** Surf Ace app launched; record `pk`; force-quit and relaunch app  
**Action:** Resolve TXT `pk` again  
**Expected:** `pk` is identical to the value before the restart  
**Type:** Integration

---

### DISC-I-13 — New keypair generated on first launch only

**Validates:** §6.2 — keypair generated once on first launch  
**Setup:** Fresh install (Keychain item absent); launch app; record `pk`  
**Action:** Force-quit; relaunch (without clearing Keychain); record `pk` again  
**Expected:** `pk` is the same; only changes if app is deleted and reinstalled (Keychain cleared)  
**Type:** Integration

---

### DISC-I-14 — iPad broadcasts in Split View alongside Clawline

**Validates:** §14.7 — iPad split view: Surf Ace HTTP server keeps serving while Clawline runs on the other side  
**Setup:** iPad with both Surf Ace and Clawline in Split View  
**Action:** Confirm mDNS is broadcasting; attempt HTTP requests to Surf Ace  
**Expected:** Surf Ace HTTP server is reachable; mDNS record is active  
**Type:** Integration / E2E

---

### DISC-I-15 — visionOS: multiple Surf Ace windows each broadcast separately

**Validates:** §14.8 — each visionOS window is a distinct surf ace with its own Bonjour advertisement  
**Setup:** Open two Surf Ace windows on visionOS  
**Action:** Browse mDNS for `_surf-ace._tcp`  
**Expected:** Two distinct Bonjour entries appear, each with their own `pk`, `name`, and session state  
**Type:** Integration / E2E (visionOS simulator)

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
**Expected:** Each returns `401 Unauthorized` (or `403 Forbidden`)  
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

### HTTP-I-10 — POST /frame with expired session token returns 401/403

**Validates:** §6.4 / §15.3 — expired session token rejected  
**Setup:** Active session; allow TTL to expire; attempt to reuse old token  
**Action:** `POST /frame` with old token  
**Expected:** `401` or `403`  
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

### HTTP-I-15 — POST /frame/patch all five patch actions accepted

**Validates:** §8.4 — patch actions: `replace_inner`, `replace_outer`, `insert_before`, `insert_after`, `remove`  
**Setup:** Active session; HTML frame with `<div id="t">content</div>`  
**Action:** For each action type, send `POST /frame/patch` with `selector: "#t"` and that action  
**Expected:** Each returns `200 OK`; screen content changes appropriately  
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

### CB-I-06 — point event fires on tap/long-press

**Validates:** §9.3 — `point` event  
**Setup:** Watch mode with `point` subscribed; frame displayed  
**Action:** User taps or long-presses on the frame  
**Expected:** Callback contains `event: "point"`, `frameId`, `position` (`x`, `y`), `nearestContent`, `timestamp`  
**Type:** Integration

---

### CB-I-07 — region event fires when user draws a selection rectangle

**Validates:** §9.3 — `region` event shape  
**Setup:** Watch mode with `region` subscribed  
**Action:** User draws a selection rectangle on the screen  
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

### CB-I-09 — Events not in subscribed list are not sent

**Validates:** §9.2 — screen only sends subscribed event types  
**Setup:** Watch mode subscribed to only `["text_selected"]`  
**Action:** Trigger a scroll_settle event  
**Expected:** No `scroll_settle` POST to callbackUrl  
**Type:** Integration

---

### CB-I-10 — Event POST: retry once after 1 second, then drop

**Validates:** §16.9 — one retry after 1s, then drop; events are best-effort  
**Setup:** Watch mode active; callback server intentionally unreachable  
**Action:** Trigger a watch event  
**Expected:** Screen makes at most 2 POST attempts; no infinite retry loop  
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

### RENDER-I-03 — Image frame renders via native image view

**Validates:** §14.5 — iOS renders images via native image view  
**Setup:** Active session  
**Action:** Push `{ "contentType": "image", "content": { "data": "<base64 PNG>", "mediaType": "image/png", "alt": "test" } }`  
**Expected:** Image displays; `GET /snapshot` `visibleText = "test"` (alt text)  
**Type:** Integration

---

### RENDER-I-04 — PDF frame renders via PDFKit / PDFView

**Validates:** §14.5 — iOS renders PDFs via PDFKit  
**Setup:** Active session  
**Action:** Push `{ "contentType": "pdf", "content": { "data": "<base64 PDF>" } }`  
**Expected:** PDF displays; `GET /snapshot` `contentType = "pdf"`; `visibleText` includes text from the visible page  
**Type:** Integration

---

### RENDER-I-05 — Terminal frame renders via custom monospace NSAttributedString view with ANSI color

**Validates:** §14.5 — iOS uses custom monospace NSAttributedString view with ANSI color support  
**Setup:** Active session  
**Action:** Push `{ "contentType": "terminal", "content": { "lines": ["\u001b[32mgreen\u001b[0m", "plain"], "scrollback": 100 } }`  
**Expected:** Lines displayed in monospace; ANSI color codes rendered as colors (green text); `GET /snapshot` `visibleText` includes "green" and "plain"  
**Type:** Integration

---

### RENDER-I-06 — Markdown frame renders as native markdown

**Validates:** §14.5 — iOS renders markdown with native markdown rendering  
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

**Validates:** §8.4 — `replace_inner` updates inner HTML of selector match in WKWebView  
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
**Action (a):** User long-presses (tap without text selection) → `GET /snapshot`; expect `selection.kind = "point"`  
**Action (b):** User draws a region → `GET /snapshot`; expect `selection.kind = "region"`  
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
**Expected:** Stroke POSTs go to the same callback URL configured via `POST /watch` (or via the provider's established callback)  
**Type:** Integration

---

### PENCIL-I-12 — Strokes buffered during frame push, not lost

**Validates:** §16.10 — strokes drawn during frame push must not be lost  
**Setup:** Active session; frame displayed; begin drawing strokes  
**Action:** Simultaneously push a new frame; check next debounce payload  
**Expected:** Next debounce payload includes strokes drawn before, during, and after the frame push; no strokes dropped  
**Type:** Integration

---

### PENCIL-I-13 — Continuous drawing: short debounce does not fire; long debounce fires periodically

**Validates:** §16.11 — during continuous drawing (pencil never lifts), short debounce does not fire; long debounce fires once per 3–5s idle  
**Setup:** Active session; frame displayed  
**Action:** Draw continuously for 30 seconds without lifting Apple Pencil; observe callbacks  
**Expected:** No `strokes` (short debounce) events fire; long-debounce fires approximately every 3–5s; final long-debounce fires after pencil lifts and 3–5s elapse  
**Type:** Integration / E2E

---

### PENCIL-I-14 — Change stack records frames received in order

**Validates:** §13.4 / §13.6 — surf ace maintains ordered change stack of received frames  
**Setup:** Active session  
**Action:** Push 3 distinct frames; inspect change stack (via test API or observable state)  
**Expected:** Change stack contains all 3 frames in push order; newest is current  
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
**Expected:** Raw strokes are sent to provider without any pre-processing, classification, or transformation; surf ace does not modify content based on gesture patterns  
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

### PAIR-I-03 — PIN mode step 1 returns pin_required with pin_hash and nonce

**Validates:** §7.4 / §17.1 — PIN step 1 response  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair { "mode": "pin" }`  
**Expected:** `200 OK`, `{ "status": "pin_required", "pin_hash": "<sha256>", "nonce": "<32 hex bytes>" }`  
**Type:** Integration

---

### PAIR-I-04 — PIN displayed large and centered on screen

**Validates:** §7.4 — "4-digit numeric displayed large and centered on the screen"  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair { "mode": "pin" }`; observe iOS screen  
**Expected:** A 4-digit number is displayed prominently, large, and centered on the screen; screen is in "Pairing" state  
**Type:** E2E

---

### PAIR-I-05 — PIN is 4-digit numeric (0000–9999)

**Validates:** §7.4 — PIN is 4-digit numeric  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair { "mode": "pin" }`; read the displayed PIN  
**Expected:** PIN is exactly 4 digits (0000–9999); no letters or special characters  
**Type:** E2E

---

### PAIR-I-06 — PIN rotates after 60 seconds

**Validates:** §7.4 — PIN valid for 60 seconds, then auto-rotates  
**Setup:** Observe initial PIN  
**Action:** Wait 61 seconds without submitting; observe screen and attempt the old PIN  
**Expected:** A new PIN is displayed; old PIN returns `403`  
**Type:** Integration / E2E

---

### PAIR-I-07 — Correct PIN submission returns sessionToken

**Validates:** §7.4 / §17.1 — correct PIN → `{ "status": "ok", "sessionToken": "..." }`  
**Setup:** Obtain PIN challenge; read displayed PIN  
**Action:** `POST /pair { "mode": "pin", "pin": "<displayed>", "nonce": "<from challenge>" }`  
**Expected:** `200 OK`, `{ "status": "ok", "sessionToken": "<token>" }`  
**Type:** Integration / E2E

---

### PAIR-I-08 — pin_hash is SHA-256(pin + nonce)

**Validates:** §7.4 — `pin_hash = SHA-256(pin + nonce)`  
**Setup:** Obtain PIN challenge with known nonce  
**Action:** Read displayed PIN; independently compute `SHA-256(pin_string + nonce_hex)`  
**Expected:** Computed hash matches `pin_hash`  
**Type:** Unit (with known PIN fixture)

---

### PAIR-I-09 — Wrong PIN returns 403 Forbidden

**Validates:** §17.1 — incorrect PIN → `403 Forbidden`  
**Setup:** Obtain PIN challenge  
**Action:** Submit with wrong PIN  
**Expected:** `403 Forbidden`  
**Type:** Integration

---

### PAIR-I-10 — 3 failed PIN attempts triggers 30-second lockout

**Validates:** §7.4 — 3 failures → 30-second lockout  
**Setup:** Obtain PIN challenge  
**Action:** Submit wrong PIN 3 times; attempt 4th immediately  
**Expected:** After 3rd failure, `429 Too Many Requests` (or `403` with lockout); lockout lasts 30 seconds  
**Type:** Integration

---

### PAIR-I-11 — Lockout clears after 30 seconds

**Validates:** §7.4 — 30-second lockout duration  
**Setup:** Trigger lockout  
**Action:** Wait 31 seconds; attempt with correct PIN  
**Expected:** Request succeeds  
**Type:** Integration

---

### PAIR-I-12 — Second POST /pair when busy returns 409 Conflict

**Validates:** §6.5 — `409 Conflict { "error": "busy" }` when screen is occupied  
**Setup:** Active session  
**Action:** `POST /pair { "mode": "auto" }` from a second client  
**Expected:** `409 Conflict`, body `{ "error": "busy" }`  
**Type:** Integration

---

### PAIR-I-13 — TLS cert derived from Ed25519 keypair (self-signed)

**Validates:** §6.3 / §15.2 — screen's HTTPS server uses self-signed cert derived from Ed25519 keypair  
**Setup:** Surf Ace running HTTPS server  
**Action:** Inspect the TLS certificate presented by the server  
**Expected:** Certificate is self-signed; public key fingerprint matches the `pk` TXT record  
**Type:** Integration (TLS inspection)

---

### PAIR-I-14 — Keypair stored in iOS Keychain

**Validates:** §6.2 / §14.2 — identity generated on first launch, stored in Keychain  
**Setup:** Fresh install  
**Action:** Launch app; verify Keychain contains the Ed25519 keypair; verify `pk` TXT matches Keychain public key  
**Expected:** Keychain item exists for the keypair; `pk` fingerprint matches Keychain key  
**Type:** Unit / Integration

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

**Validates:** §6.4 / §7.5 — session end clears content, screen goes idle, `busy=0`  
**Setup:** Active session; frame displayed  
**Action:** Let session expire or explicitly clear; observe screen and TXT  
**Expected:** Screen shows Standby state; `busy=0`; session token invalid  
**Type:** Integration

---

### SESS-I-03 — TTL is 5 minutes of no requests

**Validates:** §13.3 screen states / §14.6 — 5-minute TTL  
**Setup:** Active session; no requests for 5 minutes  
**Action:** Wait 5+ minutes; check session state  
**Expected:** Session expired; screen in Standby; `busy=0`  
**Type:** Integration (can time-accelerate in unit test)

---

### SESS-I-04 — Any request resets the TTL

**Validates:** §6.6 — provider's next request resets TTL  
**Setup:** Active session  
**Action:** Wait 4 minutes; send `GET /snapshot`; wait another 4 minutes; check state  
**Expected:** Session still active at 8 minutes (TTL reset at 4 minutes)  
**Type:** Integration

---

### SESS-I-05 — iPhone backgrounding suspends HTTP server

**Validates:** §14.6 — iOS suspends HTTP server when app is backgrounded  
**Setup:** Surf Ace running in foreground on iPhone; active session; frame displayed  
**Action:** Switch to another app (Surf Ace backgrounds)  
**Expected:** HTTP server becomes unreachable; provider cannot make new requests  
**Type:** Integration / E2E

---

### SESS-I-06 — iPhone foreground resume within 5 minutes: session continues

**Validates:** §14.6 — user switches back within 5 minutes; HTTP server wakes up; provider's next request resets TTL  
**Setup:** Surf Ace backgrounded with active session and frame displayed  
**Action:** Switch back to Surf Ace before 5-minute TTL expires  
**Expected:** HTTP server becomes reachable again; provider's next request (e.g. frame push) succeeds; session continues; frame reappears  
**Type:** Integration / E2E

---

### SESS-I-07 — iPhone foreground resume after 5 minutes: session expired, requires re-pair

**Validates:** §14.6 — if user doesn't switch back within 5 minutes, session expires  
**Setup:** Surf Ace backgrounded with active session  
**Action:** Do not switch back for 5+ minutes; then switch back  
**Expected:** Session is expired; screen shows Standby; new pairing required  
**Type:** Integration / E2E

---

### SESS-I-08 — Screen holds last frame if provider permanently unreachable

**Validates:** §6.6 — screen holds last displayed frame indefinitely if provider is permanently unreachable  
**Setup:** Active session; frame displayed; disconnect provider  
**Action:** Observe screen over time  
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
**Setup:** Active session; record token; let expire  
**Action:** `POST /frame` with old token  
**Expected:** `401` or `403`  
**Type:** Integration

---

### SESS-I-12 — Screen keeps content if TARS goes offline (no silent timeout)

**Validates:** §6.6 — "If the provider becomes permanently unreachable, the screen holds the last frame indefinitely. It only goes idle on explicit clear or app quit."  
**Setup:** Active session; frame displayed; shut down provider (simulate TARS offline)  
**Action:** Wait longer than 5 minutes without Surf Ace being backgrounded  
**Expected:** Frame is still displayed on screen; session does not expire due to provider absence alone (TTL runs on the screen side based on incoming requests)  
**Type:** Integration

---

## 8. Edge Cases

### EDGE-I-01 — POST /frame with unsupported content type returns 422 unsupported_type

**Validates:** §6.7 — `unsupported_type` error  
**Setup:** Active session; `cap` bitmask configured without a type (or test with an invented type)  
**Action:** Push frame with `contentType: "video"`  
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
**Expected:** `400 Bad Request` or `422`  
**Type:** Unit / Integration

---

### EDGE-I-09 — Missing contentType in POST /frame returns error

**Validates:** §8.1 — `contentType` required  
**Setup:** Active session  
**Action:** POST /frame JSON without `contentType`  
**Expected:** `400 Bad Request` or `422`  
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

**Validates:** §16.8 — concurrent requests; §16.7 — multiple simultaneous clients  
**Setup:** Active session  
**Action:** Send 5 concurrent `POST /frame` requests with distinct frameIds  
**Expected:** Server handles all without crash; one frame is active; no corrupted state  
**Type:** Integration

---

### EDGE-I-12 — GET /snapshot during active render returns current state without error

**Validates:** §16.8 — snapshot during render returns current visible state  
**Setup:** Active session; push a PDF frame (takes time to load)  
**Action:** `GET /snapshot` immediately after POST /frame  
**Expected:** `200 OK` (or `204` if still loading); no 500 errors; `frameId` in snapshot identifies the relevant frame  
**Type:** Integration

---

### EDGE-I-13 — POST /frame/append with unknown frameId returns 409

**Validates:** §8.4 — unknown frameId → `409 Conflict { "error": "stale_frame" }`  
**Setup:** Active session; terminal frame displayed  
**Action:** `POST /frame/append` with a `frameId` never pushed  
**Expected:** `409 Conflict`, `{ "error": "stale_frame" }`  
**Type:** Integration

---

### EDGE-I-14 — Watch mode callback security: events validated against active session

**Validates:** §15.6 — provider validates incoming events match active watch subscription (by source IP and session)  
**Setup:** Active watch mode session  
**Action:** Another device (not the screen) POSTs a spoofed event to the provider's callback URL  
**Expected:** Provider rejects the spoofed event (returns 403 or ignores it); not surfaced to CLU  
**Type:** Integration (provider-side validation)

---

### EDGE-I-15 — Screen factory reset: new keypair, old fingerprint invalid

**Validates:** §16.6 / §15.4 — factory reset regenerates keypair; provider must re-pair  
**Setup:** Trust established with a screen fingerprint  
**Action:** Simulate factory reset (delete Keychain entry + reinstall or clear Keychain); relaunch; observe `pk` TXT  
**Expected:** `pk` TXT has changed; provider cannot auto-connect with old trusted fingerprint; PIN pairing required  
**Type:** Integration

---

### EDGE-I-16 — Error during live update (patch/append) in watch mode reported as error event on callback

**Validates:** §6.7 — errors during live updates in watch mode reported as error events on callback URL  
**Setup:** Active session in watch mode; HTML frame displayed  
**Action:** `POST /frame/patch` with a selector that fails to match or with malformed HTML causing render error  
**Expected:** Callback URL receives an error event; endpoint also returns `422`  
**Type:** Integration

---

### EDGE-I-17 — Content is self-contained (no external network required)

**Validates:** §8.2 — "All content must be self-contained. Screens are local devices with no guaranteed internet access."  
**Setup:** Active session; device with no internet access (airplane mode, WiFi only to LAN)  
**Action:** Push HTML frame with inline styles and no external resources; push image frame with base64 data; push PDF frame with base64 data  
**Expected:** All frames render correctly without internet access  
**Type:** E2E

---

### EDGE-I-18 — POST /watch with no events array returns error

**Validates:** §9.2 — POST /watch requires `callbackUrl` and `events`  
**Setup:** Active session  
**Action:** `POST /watch { "callbackUrl": "https://tars.local:18789/surf-ace/events/sf_abc" }` (no `events` field)  
**Expected:** `400 Bad Request` or `422`  
**Type:** Unit / Integration

---

### EDGE-I-19 — Multiple providers: second sees busy=1 and cannot pair

**Validates:** §16.7 — first-come-first-served occupancy  
**Setup:** First provider has active session  
**Action:** Second provider sends `POST /pair`  
**Expected:** `409 Conflict { "error": "busy" }`  
**Type:** Integration

---

### EDGE-I-20 — Pencil strokes during frame push: strokes buffered and included in next debounce

**Validates:** §16.10 — strokes during frame push are buffered and not lost  
**Setup:** Active session; drawing in progress  
**Action:** Provider pushes a new frame mid-stroke; strokes continue after frame renders  
**Expected:** Next debounce payload contains all strokes (before, during, and after frame push); no strokes dropped  
**Type:** Integration

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

### STANDBY-I-03 — Pairing state shows PIN large and centered

**Validates:** §7.4 / §13.3 screen states — pairing state: PIN displayed large and centered  
**Setup:** Surf Ace in Standby  
**Action:** `POST /pair { "mode": "pin" }`; observe screen  
**Expected:** 4-digit PIN displayed large and centered; screen is in "Pairing" state  
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

## 10. Spawned Surf Ace (Annotation)

> These tests apply to the iOS Clawline app acting as the spawned surf ace origin (Phase 5 — may be tested as they are implemented).

### SPAWN-I-01 — surf ace_spawned message sent over existing WebSocket

**Validates:** §11.2 / §12.2 — `surf ace_spawned` message sent via existing Clawline WebSocket  
**Setup:** Clawline iOS app connected; user picks up Apple Pencil and starts annotating a chat bubble  
**Action:** Observe the WebSocket traffic from Clawline to provider  
**Expected:** A message `{ "type": "surf ace_spawned", "surf aceId": "sp_<8hex>", "streamKey": "...", "callbackUrl": "..." }` is sent  
**Type:** Integration

---

### SPAWN-I-02 — Spawned surf ace exposes GET /snapshot

**Validates:** §11.3 — spawned surf ace runs same HTTP server; GET /snapshot works  
**Setup:** Clawline spawns a surf ace during annotation  
**Action:** Provider calls `GET /snapshot` on the spawned surf ace's address  
**Expected:** `200 OK` with snapshot JSON including the original screenshot and any drawn annotations  
**Type:** Integration

---

### SPAWN-I-03 — surf ace_submitted message sent on pencil lift / send

**Validates:** §11.2 — `surf ace_submitted` sent when user lifts pencil or taps send  
**Setup:** Spawned surf ace active; user has drawn annotations  
**Action:** User lifts pencil / taps send; observe WebSocket traffic  
**Expected:** `{ "type": "surf ace_submitted", "surf aceId": "sp_<8hex>" }` sent over WebSocket  
**Type:** Integration

---

### SPAWN-I-04 — Spawned surf ace is ephemeral — HTTP server shuts down after submission

**Validates:** §11.3 — "ephemeral... After submission, it's gone."  
**Setup:** Surf ace submitted  
**Action:** Attempt to reach the spawned surf ace's HTTP server after submission  
**Expected:** Connection refused or timeout; HTTP server has shut down  
**Type:** Integration

---

### SPAWN-I-05 — Spawned surf ace surfaceId uses sp_ prefix format

**Validates:** §12.3 — `id: sp_<hex>` for spawned surf aces  
**Setup:** Clawline spawns a surf ace  
**Action:** Inspect the `surf aceId` in the `surf ace_spawned` message  
**Expected:** `surf aceId` starts with `sp_` followed by 8 hex characters  
**Type:** Unit / Integration

---
