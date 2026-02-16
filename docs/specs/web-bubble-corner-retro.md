# T028 Web Bubble Corner Radius Retro

## 1) Original fix and why it regressed
- The original fix was commit `7b6b5b879` (`fix(#12294): round embedded web preview + darken surface`), which introduced a squircle mask path for embedded `WKWebView` content and a darker preview surface chrome.
- It regressed because the radius token used by that fix was a local hard-coded media value (`12`) instead of the design-system link-preview radius token; subsequent refactors preserved the same local token across render paths, so behavior stayed functional but visually drifted from design spec.

## 2) Where web-view bubble radius is set, and how many paths control it
- Primary source token: `LinkPreviewView.Constants.mediaCornerRadius` in `ios/Clawline/Clawline/Views/Chat/LinkPreviewView.swift`.
- Radius fan-out paths (3 runtime paths):
  1. `MaskedWebContainerView` superellipse mask (`maskLayer.path`) via `cornerRadius`.
  2. `webView.layer.cornerRadius` for `WKWebView` surface clipping.
  3. `webView.scrollView.layer.cornerRadius` for internal scroll/tile clipping consistency.
- Separate outer-message-bubble corners are controlled in `MessageBubbleUIKitView.bubbleCornerRadii(...)`; that is a different boundary from embedded web preview radius.

## 3) Design-system value and source
- Design-system value for link preview border radius is **16px**.
- Source: `/Users/mike/shared-workspace/clawline/design-system/design-system.html` under the **Link Preview** spec table (`Border radius: 16px`), referenced from `/Users/mike/shared-workspace/clawline/design-system/README.md`.

## 4) Right fix to match design
- Keep one radius source of truth for embedded web previews (`LinkPreviewView.Constants.mediaCornerRadius`) and set it to the design-system value (`16`).
- Continue fanning that token to all three clipping paths (container mask, `WKWebView` layer, and `WKWebView.scrollView` layer) so visual shape and clipping remain consistent.
- Do not change outer message bubble corner logic in this fix; it is a separate concern and would broaden scope.
