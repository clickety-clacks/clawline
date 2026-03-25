# Interactive HTML Bubbles — Non-Obvious Details

## Must not affect existing web view behavior — complete isolation required
The most critical invariant: existing `LinkPreviewView` and any other WKWebView-based bubbles must continue to function exactly as today. Interactive HTML bubbles must use their own `WKWebViewConfiguration`, their own `WKProcessPool`, and their own `WKContentRuleList`. **Do not refactor, consolidate, or "improve" existing web view code as part of this work.** This isolation is explicit and intentional.

## Sizing protocol: measure once, lock, never resize from content changes
After `webView(_:didFinish:)`, measure `document.body.scrollHeight`, set bubble height to `min(measured, maxHeight)`, lock it. If JS content changes size after load (animations etc.), it scrolls within the locked height — no re-measurement. The one-measurement protocol exists specifically to avoid the layout feedback loops seen in T020/T026/T028. ResizeObserver must not be used.

## `_resize` escape hatch: at most ONE per bubble lifetime
The `_resize` reserved action allows a one-time JS-initiated height change. The client must honor at most one `_resize` per bubble; subsequent `_resize` requests are ignored. This prevents the same feedback loop the lock-height protocol prevents.

## Callbacks are at-most-once, fire-and-forget — ordering not guaranteed under rate limiting
Callbacks are best-effort. The client does not wait for acknowledgement. Under rate limiting, dropped callbacks break sequence. **Interactive HTML must be designed assuming callbacks may be lost or re-ordered.** Agents that depend on callback delivery for state machine transitions need retry logic at the application level.

## 256KB hard cap enforced at BOTH provider and client
Provider rejects oversized payloads before delivery. Client also rejects if they somehow arrive. Both enforcement points are required — don't rely solely on provider-side rejection.

## Security model: the agent already has full session access — HTML sandbox is defense-in-depth
The content is authored by a trusted agent delivered over an authenticated WebSocket. The WKWebView isolation (non-persistent data store, separate process pool, CSP, WKContentRuleList blocking all network requests) is defense against accidental external resource loading, not protection against a malicious content author. The agent cannot do more damage via HTML than via text messages.

## Base URL must be `nil` — no file access, no credential leakage
Setting `nil` as base URL means no origin, no file system access, no credential access. This is different from a `file://` or `data:` base URL which would grant unintended capabilities.

## `webViewWebContentProcessDidTerminate:` — auto-reload once, then permanent error
On first process termination: auto-reload. On second crash: show permanent "Content crashed" error state. Do not auto-reload indefinitely — a crashing content process can lock up the app.

## Cell reuse: WKWebView created on bind, torn down on `prepareForReuse`
No WKWebView pooling in v1. On `didReceiveMemoryWarning`, tear down offscreen interactive bubble web views; they recreate on next scroll-into-view.
