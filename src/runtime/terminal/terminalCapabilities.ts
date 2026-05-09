export const TERMINAL_BUBBLES_FEATURE = "terminal_bubbles_v1";

export function supportsTerminalBubbles(input?: { hasWebSocket?: boolean }) {
  const hasWebSocket =
    input?.hasWebSocket ?? typeof globalThis.WebSocket === "function";
  return hasWebSocket;
}

export function getWebClientFeatures(input?: { hasWebSocket?: boolean }) {
  return supportsTerminalBubbles(input) ? [TERMINAL_BUBBLES_FEATURE] : [];
}
