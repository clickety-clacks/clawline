# xterm.js Recon for Clawline Web Terminal Feasibility

Date: 2026-03-30

## Bottom Line

xterm.js is the obvious browser-terminal choice for Clawline. It is the default path, not because it is trivial, but because it already solves the hard terminal-emulation/rendering problem that the web platform does not solve natively.

It is not a drop-in solution for Clawline terminal bubbles. The expensive part is not "render ANSI text in React"; the expensive part is embedding a live terminal runtime inside a chat bubble with Clawline's separate terminal protocol, resize semantics, reconnect/backfill behavior, and iPad/mobile ergonomics.

Blunt recommendation:

- Do not skip terminal forever.
- Do not put terminal on the Phase 1 launch-critical path.
- Treat terminal as a later rich-surfaces phase with a deliberately scoped v1.
- Use xterm.js when that phase starts.

If the question is "is there an easier credible browser terminal path than xterm.js for Clawline?", the answer is no.

## Sources Used

Authoritative product / architecture docs:

- `docs/implementation_details/terminal-bubbles.md`
- `docs/provider-architecture.md`
- `docs/ios-provider-connection.md`
- `docs/implementation_details/connection-state-ui.md`

iOS implementation / behavior reference:

- `ios/Clawline/Clawline/Services/TerminalSessionService.swift`
- `ios/Clawline/Clawline/Models/TerminalSessionDescriptor.swift`
- `ios/Clawline/Clawline/Views/Chat/TerminalBubbleUIKitView.swift`
- `ios/Clawline/ClawlineTests/TerminalSessionConnectionPoolTests.swift`
- `ios/Clawline/ClawlineTests/TerminalBubbleUIKitViewTests.swift`

Current xterm.js primary sources:

- https://xtermjs.org/
- https://xtermjs.org/docs/
- https://xtermjs.org/docs/guides/security/
- https://xtermjs.org/docs/guides/using-addons/
- https://xtermjs.org/docs/guides/flowcontrol/
- https://github.com/xtermjs/xterm.js
- https://github.com/xtermjs/xterm.js/issues/1101
- https://github.com/xtermjs/xterm.js/issues

## What Clawline Terminal Actually Is

Clawline terminal is not "a terminal tab in a devtool shell." It is a rich attachment surface embedded inside chat.

Architecturally, terminal is its own runtime because:

- it uses a separate WebSocket endpoint, `/ws/terminal`, not the main chat `/ws`
- it has its own auth handshake and control messages
- it can receive raw data frames, text frames, or JSON control envelopes
- it has independent connection health, pinging, and reconnect behavior
- it has resize semantics tied to rendered bubble dimensions
- it has offscreen reuse/detach behavior that is intentionally separate from chat connection state

Per docs and iOS:

- terminal attachments are discovered by MIME type `application/vnd.clawline.terminal-session+json`
- the provider owns tmux/PTY and, in remote mode, the provider performs the SSH hop; the client never SSHes directly
- the client must send PTY dimensions derived from the rendered terminal bounds
- the client authenticates over `/ws/terminal` using the paired chat token or an attachment-specific terminal access token
- terminal connection state does not drive chat send eligibility

This matters for the web because xterm.js only solves terminal rendering/input. It does not solve Clawline's terminal protocol or bubble lifecycle.

## Clawline Terminal Contract the Browser Must Honor

### Attachment detection

The browser must route any attachment with MIME `application/vnd.clawline.terminal-session+json` into a terminal surface instead of a generic file/document renderer.

### Descriptor shape

The iOS client decodes a `TerminalSessionDescriptor` with:

- `version`
- `terminalSessionId`
- optional `title`
- optional `provider.baseUrl`
- optional `provider.wsPath`
- optional capabilities:
  - `interactive`
  - `supportsBinaryFrames`
  - `supportsResize`
  - `supportsDetach`
- optional auth:
  - `mode`
  - `terminalAccessToken`
- optional `expiresAtMs`

### Terminal auth / control events

The iOS client sends:

- `terminal_auth`
- `terminal_resize`
- `terminal_detach`
- `terminal_close`

The iOS client handles:

- `terminal_ready`
- `terminal_backfill_end`
- `terminal_exit`
- `terminal_data`
- `terminal_error`
- `terminal_closed`

The auth payload sent by iOS includes:

- `type: "terminal_auth"`
- `protocolVersion: 1`
- `authMode: "chat_token" | "terminal_access_token"`
- `authToken`
- `deviceId`
- `terminalSessionId`
- `backfillLines`
- `cols`
- `rows`

### Non-obvious runtime rules from iOS

- The provider may emit output either as raw `.data`, raw `.string`, or JSON `terminal_data`; the client must accept all three.
- The client defers non-auth frames until after provider readiness/backfill, with an extra 250 ms delay in iOS, because early resize/input can be rejected as "Expected terminal_auth".
- Terminal reuse exists. The iOS pool reuses a live session across bubble detach/reattach and only the latest attached consumer owns resize/input.
- Buffered output is bounded.
- Offscreen/reuse does not preserve a permanent embedded terminal instance; the view is recreated and rebound.
- The terminal bubble deliberately has no extra chrome like default bubble padding, close button, or expand button.
- Input sanitization exists around bracketed paste behavior.
- The terminal surface sets explicit accessibility label/hint and theme colors.

## What xterm.js Maps Cleanly To

xterm.js maps cleanly to the part of the problem that is genuinely "terminal emulation in a browser."

### Clean mapping: terminal rendering

xterm.js is built for ANSI/VT terminal rendering, curses/tmux/vim-style applications, mouse events, Unicode/IME, theming, and normal terminal scrollback. That is exactly the rendering class Clawline terminal needs.

Clean Clawline mapping:

- tmux output rendering
- ANSI color/state handling
- alternate screen apps like `vim`, `less`, `htop`
- keyboard input capture
- copy/selection
- theme application
- link detection
- browser-side sizing into terminal cols/rows

### Clean mapping: resize

The `@xterm/addon-fit` addon plus `ResizeObserver` is the obvious implementation path for translating DOM bounds into terminal columns/rows and then sending `terminal_resize` to the provider.

This maps directly to the iOS behavior where bubble bounds drive PTY size.

### Clean mapping: theming

Clawline's terminal theme is straightforward to port:

- background color
- foreground color
- selection color
- font family
- font weight/style variants

xterm.js has a native theme model, and the existing iOS theme is already explicit enough to replicate.

### Clean mapping: search / links / clipboard

Likely clean addon mapping:

- `@xterm/addon-search` for in-terminal find
- `@xterm/addon-web-links` for URL detection
- `@xterm/addon-clipboard` only if its browser behavior is worth the extra dependency over native clipboard APIs

These are ordinary enhancements, not core integration risks.

## What Does Not Map Cleanly

### 1. Clawline should not use the stock attach addon as its transport layer

This is the most important implementation conclusion.

xterm.js offers `@xterm/addon-attach`, but official xterm.js security guidance explicitly warns not to use the demo app and attach addon directly as your production websocket solution. That warning lines up with Clawline's needs anyway.

Why it is a mismatch for Clawline:

- Clawline terminal transport is not "blindly attach terminal to websocket bytes"
- terminal auth is an explicit JSON handshake
- control messages are mixed with data messages
- output can arrive as raw data, raw text, or JSON terminal envelopes
- reconnect/backfill policy is application-defined
- provider readiness has a real gating rule before resize/input

Conclusion:

- xterm.js is the renderer/input surface
- Clawline needs a custom `TerminalConnectionRuntime` adapter
- that adapter owns `/ws/terminal`, auth, control envelopes, gating, reconnect, and writing output into xterm

### 2. Bubble embedding is harder than standalone full-page terminal

A full-page xterm is easy. A chat-embedded xterm bubble is not.

Clawline-specific stressors:

- bubble height is fixed by message layout, not by terminal preference
- parent chat scroll container competes with terminal scrollback gestures
- resize events happen because of message layout changes, window size changes, split panes, sheet expansion, mobile keyboard, and responsive reflow
- embedded terminal focus has to coexist with the rest of chat input focus rules
- offscreen behavior matters because chat lists virtualize/reuse

iOS already had to explicitly make terminal scroll pan beat ancestor scroll views. Web will have analogous wheel/touch/pointer conflicts.

### 3. iPad/mobile is a real risk area

Current xterm.js sources still show mobile/touch pain points:

- historic iPad keyboard issues are documented in the official mobile support issue
- current issue listings still include limited touch support on mobile devices impacting usability
- current issue listings include duplicated keyboard input on Android with physical keyboards

For Clawline this matters because terminal is not a desktop-only surface; the product is explicitly iOS/iPad-rooted, and the web port will almost certainly be used on iPad browsers.

Implication:

- xterm.js desktop viability is high
- xterm.js iPad/mobile viability is acceptable for a scoped phase, but not "free"
- expect testing and UX concessions on touch devices

### 4. Accessibility is acceptable but not low-risk

xterm.js advertises screen-reader mode and contrast support, which is materially better than building a terminal surface from scratch.

But official issue listings still show live accessibility defects, including a recent "Screen readers read content twice" issue. For Clawline, terminal is already a visually dense secondary surface; accessibility parity with the rest of chat will be weaker unless we deliberately scope and test it.

Conclusion:

- accessibility is not a blocker to using xterm.js
- accessibility is a blocker to calling terminal "easy"
- terminal should ship with explicit accessibility acceptance criteria instead of piggybacking on normal chat accessibility assumptions

### 5. Reconnect/backfill is application work, not xterm work

Clawline already has provider-side terminal session identity, tmux persistence, and optional backfill lines. That is good news: the browser does not need to emulate or persist a terminal session itself.

But the browser still must decide:

- when to detach vs hard close
- whether an offscreen bubble keeps the session alive
- whether expanded view and inline bubble share one live runtime
- how much scrollback/backfill to request on reconnect
- whether to preserve a pooled connection across React unmount/remount

xterm.js does not answer any of that.

### 6. WebGL/canvas optimization is not free

xterm.js can use a GPU renderer, but current official issue/discussion traffic still shows renderer-specific edge cases like flicker in moving/responsive layouts and selection/background quirks. For a chat-embedded terminal whose bounds may animate or reflow, that matters.

Recommendation:

- default to the stable non-WebGL renderer first
- treat WebGL as an opt-in later optimization only if profiling proves the need

## Browser Responsibilities vs Provider Responsibilities

### Provider already does the hard backend work

Per docs/source, the provider already owns:

- terminal session creation/ownership
- `/ws/terminal`
- auth validation
- tmux/PTY bridging
- remote SSH hop when terminal host is remote
- backfill production
- close / exit / error signaling

That means the browser does not need:

- SSH libraries
- PTY/node-pty equivalents
- tmux emulation
- server-side shell spawning logic

### Browser still needs a meaningful runtime

The web client must own:

- MIME detection and descriptor decoding
- xterm surface lifecycle
- terminal websocket connection and auth handshake
- readiness gating before resize/input
- raw vs JSON frame decoding
- size observation and `terminal_resize`
- user input forwarding
- dead-state / reconnect UI
- focus/blur handling
- copy/paste policy
- detachment rules when the bubble unmounts or goes offscreen

This is not huge backend work, but it is real product/runtime work.

## Recommended xterm.js Stack for Clawline

### Core

- `@xterm/xterm`
- `@xterm/addon-fit`

### Very likely

- `@xterm/addon-search`
- `@xterm/addon-web-links`

### Conditional

- `@xterm/addon-unicode11` or `@xterm/addon-unicode-graphemes` if glyph-width issues show up with Clawline output
- `@xterm/addon-web-fonts` if bundled terminal fonts need more reliable loading behavior
- `@xterm/addon-clipboard` if native browser clipboard handling proves too weak

### Probably not in v1

- `@xterm/addon-attach`
- `@xterm/addon-webgl`
- `@xterm/addon-serialize`
- `@xterm/addon-image`

Notes:

- `attach` is the wrong abstraction for Clawline's mixed protocol/runtime needs.
- `serialize` is only useful if we later want client-side restore/snapshot behavior beyond provider backfill.
- `webgl` should be a later performance optimization, not a baseline dependency.

## Minimal Viable Terminal Implementation

This is the smallest version worth building.

### User-visible behavior

- Terminal attachments render as live terminal surfaces inside messages.
- The terminal auto-connects when visible, like iOS.
- The user can type, copy, select, and scroll terminal output on desktop browsers.
- Resize follows bubble/container size.
- On disconnect/error/exit, the bubble shows a dead-state overlay with reconnect.

### Required browser implementation pieces

#### 1. Terminal attachment routing

- Detect terminal MIME in attachment parsing.
- Decode `TerminalSessionDescriptor`.
- Route to `TerminalAttachmentView`.

#### 2. Terminal connection runtime

Owns:

- websocket connect to `/ws/terminal`
- `terminal_auth`
- readiness gating
- control frame parsing
- raw frame parsing
- ping/health if needed on web
- reconnect and detach behavior

This should be a custom adapter, not xterm logic embedded directly in React components.

#### 3. React terminal view wrapper

Owns:

- xterm instance creation/disposal
- DOM mount
- addon loading
- resize observation
- theme setup
- `onData` bridge from xterm to runtime
- runtime output bridge into `term.write(...)`

#### 4. Dead-state / reconnect UX

Match current product behavior closely:

- visible dead overlay
- reconnect affordance
- do not pretend terminal is healthy when transport is not

#### 5. Desktop-only initial quality bar

Ship first on:

- Chrome
- Safari desktop
- iPad Safari with hardware keyboard as best-effort, but not parity-critical for the first terminal milestone

### Things the MVP can intentionally omit

- terminal search UI if needed to cut scope
- persistent pooled runtime across multiple mounts
- expanded-sheet/shared-runtime sophistication
- WebGL renderer
- mobile touch polish beyond basic usability
- deep screen-reader optimization beyond baseline labels and tested focus order

## What Maps Cleanly From iOS to Web

These parts are mostly straightforward ports of behavior:

- MIME-based terminal attachment detection
- separate terminal runtime boundary
- `/ws/terminal` auth handshake
- terminal access token fallback to chat token
- provider-owned tmux/PTY model
- resize driven by rendered surface bounds
- no extra message-bubble chrome for terminal
- dead-state / reconnect overlay
- theme token translation

## What Is Awkward, Risky, or Expensive

### Medium risk

- React mount/unmount lifecycle versus pooled terminal reuse
- exact resize timing and debounce rules
- wheel/touch/scroll conflict inside the chat surface
- paste sanitization parity with iOS
- iPad hardware keyboard behavior

### High risk

- polished mobile/touch usability
- accessibility quality strong enough to claim parity with normal chat
- getting embed/reconnect/offscreen lifecycle right without leaking sockets or breaking session ownership

### Not actually a risk because provider already solves it

- SSH to remote hosts
- PTY spawning
- tmux persistence
- shell protocol

## Suggested Web Module Split

This split keeps terminal logic out of normal chat code.

### `terminal-protocol`

Owns:

- descriptor types
- auth/control event types
- frame decode helpers

### `terminal-runtime`

Owns:

- websocket lifecycle
- auth handshake
- ready gating
- reconnect
- resize sending
- detach/close

### `terminal-view`

Owns:

- xterm instance
- addons
- DOM mount/dispose
- theme and font application
- runtime I/O binding

### `terminal-message-surface`

Owns:

- integrating the terminal view into chat message layout
- visible/dead/loading states
- reconnect button
- optional expand/open-larger behavior later

## What Should Be Deferred

### Definitely defer out of core Phase 1 launch

- terminal surfaces at all

Phase 1 for the web client should prove chat, pairing, sessions, message rendering, and attachments without the extra runtime complexity of embedded terminals.

### Defer out of terminal v1

- pooled live session sharing across inline bubble and expanded panel
- perfect iPad touch ergonomics
- advanced accessibility beyond tested baseline
- WebGL optimization
- search UI chrome
- client-side serialized terminal restoration
- terminal-specific keyboard shortcut layer beyond basic passthrough

## Feasibility Judgment

### Is xterm.js the obvious choice?

Yes.

It is the obvious and recommended choice because:

- it is the standard, actively maintained browser terminal renderer
- it already handles the terminal-emulation class Clawline needs
- alternatives would mostly mean re-solving a much harder problem

It is not obvious in the sense of "easy enough for Phase 1 launch scope." That is a separate question, and the answer there is no.

### What pieces of Clawline terminal map cleanly?

- rendering tmux/PTY output
- keyboard input
- ANSI/curses apps
- terminal theming
- resize based on DOM size
- link detection
- copy/selection
- dead/live state presentation around the terminal surface

### What pieces are awkward, risky, or expensive?

- mixed auth/control/data protocol integration
- bubble embedding lifecycle
- reconnect/backfill semantics
- focus and scroll conflict inside chat
- iPad/mobile behavior
- accessibility polish

### What libraries/addons are likely required?

- `@xterm/xterm`
- `@xterm/addon-fit`
- likely `@xterm/addon-search`
- likely `@xterm/addon-web-links`
- possibly Unicode/font helpers depending output/font testing

### What does a minimal viable implementation include?

- terminal MIME routing
- xterm terminal surface
- custom `/ws/terminal` runtime
- `terminal_auth`
- raw and control frame handling
- resize support
- basic copy/paste/input
- dead-state and reconnect UI

### What belongs in Phase 1 vs later?

Phase 1:

- no terminal

Later advanced-rich-surfaces phase:

- terminal attachments using xterm.js
- start with desktop-focused v1
- add iPad/mobile/accessibility polish incrementally

### Blunt recommendation

Terminal should be in later scope, not launch scope.

Reason:

- xterm.js makes terminal feasible
- Clawline terminal is real product/runtime work, not a low-cost embellishment
- terminal adds an entire secondary live runtime inside chat
- the provider side is already favorable, so this is worth doing later
- it is still not the right thing to put on the critical path for the first runnable web client

## Implementation Recommendation

When terminal work starts, the team should:

1. Build a custom `TerminalConnectionRuntime` around Clawline's `/ws/terminal` contract.
2. Wrap xterm.js in a small React adapter component with `fit` and explicit teardown.
3. Ship a desktop-first terminal v1.
4. Defer pooling, WebGL, and deeper mobile/accessibility polish until after the first terminal milestone is working end-to-end.

That is the lowest-risk path that still respects Clawline's actual terminal behavior.
