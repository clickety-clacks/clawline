import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type MutableRefObject
} from "react";
import type { ServerAttachmentPayload, JsonValue } from "../../protocol/chat-wire";
import {
  decodeInteractiveHtmlDescriptor,
  interactiveHtmlTitle
} from "../../protocol/interactive-html-wire";
import { useSettingsStore } from "../../runtime/settings/settingsStore";
import { useTransportMachine } from "../../runtime/transport/transportMachine";

const DEFAULT_MAX_HEIGHT = 400;
const CALLBACKS_PER_SECOND = 10;
const MAX_CALLBACK_BYTES = 64 * 1024;
const MAX_HTML_BYTES = 256 * 1024;

type InteractiveHtmlState =
  | { kind: "loading" }
  | { kind: "ready" }
  | { kind: "closed"; summary: string }
  | { kind: "error"; message: string };

export function InteractiveHtmlAttachmentCard({
  attachment,
  expanded = false,
  messageId
}: {
  attachment: ServerAttachmentPayload;
  expanded?: boolean;
  messageId: string;
}) {
  const descriptor = useMemo(() => decodeInteractiveHtmlDescriptor(attachment), [attachment]);
  const iframeRef = useRef<HTMLIFrameElement | null>(null);
  const callbackWindowRef = useRef({ count: 0, startedAt: 0 });
  const resizeUsedRef = useRef(false);
  const lockedHeightRef = useRef(false);
  const { state: settingsState } = useSettingsStore();
  const { store: transportStore } = useTransportMachine();
  const [state, setState] = useState<InteractiveHtmlState>({ kind: "loading" });
  const [frameHeight, setFrameHeight] = useState<number>(() =>
    expanded ? 240 : 160
  );

  const supportError = interactiveHtmlSupportError();
  const htmlByteLength = descriptor
    ? new TextEncoder().encode(descriptor.html).length
    : 0;
  const isDark = settingsState.appearance !== "light";
  const title = descriptor ? interactiveHtmlTitle(descriptor) : "Interactive content";
  const maxHeight = descriptor?.metadata?.maxHeight ?? DEFAULT_MAX_HEIGHT;
  const bridgeToken = useMemo(makeBridgeToken, [descriptor, isDark]);
  const stageStyle = descriptor?.metadata?.backgroundColor
    ? { background: descriptor.metadata.backgroundColor }
    : undefined;
  const srcDoc = useMemo(() => {
    if (!descriptor || descriptor.version !== 1) {
      return "";
    }

    return injectInteractiveHtml({
      isDark,
      rawHtml: descriptor.html,
      token: bridgeToken
    });
  }, [bridgeToken, descriptor, isDark]);

  useEffect(() => {
    resizeUsedRef.current = false;
    lockedHeightRef.current = false;

    if (!descriptor) {
      setState({
        kind: "error",
        message: "Interactive content payload is invalid."
      });
      return;
    }

    if (descriptor.version !== 1) {
      setState({
        kind: "error",
        message: "Update Clawline to view this content."
      });
      return;
    }

    if (supportError) {
      setState({ kind: "error", message: supportError });
      return;
    }

    if (htmlByteLength > MAX_HTML_BYTES) {
      setState({
        kind: "error",
        message: "Interactive content too large to render."
      });
      return;
    }

    const configuredHeight = descriptor.metadata?.height;
    if (configuredHeight?.kind === "fixed") {
      const fixedHeight = clampHeight(configuredHeight.value, maxHeight);
      setFrameHeight(fixedHeight);
      lockedHeightRef.current = true;
    } else {
      setFrameHeight(expanded ? 240 : 160);
    }
    setState({ kind: "loading" });
  }, [descriptor, expanded, htmlByteLength, maxHeight, supportError]);

  useEffect(() => {
    if (!descriptor || supportError || descriptor.version !== 1 || htmlByteLength > MAX_HTML_BYTES) {
      return;
    }

    const fixedHeight = descriptor.metadata?.height?.kind === "fixed";
    const loadTimeout = window.setTimeout(() => {
      if (state.kind === "loading" && !fixedHeight) {
        setState({
          kind: "error",
          message: "Content failed to render."
        });
      }
    }, 2000);

    function handleMessage(event: MessageEvent) {
      if (event.source !== iframeRef.current?.contentWindow) {
        return;
      }

      const payload = event.data;
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return;
      }

      const record = payload as Record<string, unknown>;
      if (record.__clawlineInteractiveHtml !== true || record.token !== bridgeToken) {
        return;
      }

      if (record.kind === "measure" && !lockedHeightRef.current) {
        const measured = typeof record.height === "number" ? record.height : NaN;
        if (Number.isFinite(measured)) {
          lockedHeightRef.current = true;
          setFrameHeight(clampHeight(measured, maxHeight));
          setState({ kind: "ready" });
        }
        return;
      }

      if (record.kind !== "bridge") {
        return;
      }

      if (!acceptCallback(callbackWindowRef)) {
        return;
      }

      const action = typeof record.action === "string" ? record.action : "";
      if (!action || action.length > 128) {
        return;
      }

      if (action === "_close") {
        const summary =
          typeof record.summary === "string" && record.summary.trim().length > 0
            ? record.summary.trim().slice(0, 500)
            : "Done.";
        setState({ kind: "closed", summary });
        return;
      }

      if (action === "_resize") {
        if (resizeUsedRef.current) {
          return;
        }
        resizeUsedRef.current = true;
        const nextHeight =
          typeof record.height === "number"
            ? record.height
            : asHeight(record.data);
        if (nextHeight != null) {
          lockedHeightRef.current = true;
          setFrameHeight(clampHeight(nextHeight, maxHeight));
          setState({ kind: "ready" });
        }
        return;
      }

      const data = sanitizeJsonValue(record.data);
      if (data != null) {
        const encoded = JSON.stringify(data);
        if (encoded && new TextEncoder().encode(encoded).length > MAX_CALLBACK_BYTES) {
          return;
        }
      }

      void transportStore
        .sendInteractiveCallback({
          action,
          data: data ?? undefined,
          messageId
        })
        .catch(() => {});
    }

    window.addEventListener("message", handleMessage);
    return () => {
      window.clearTimeout(loadTimeout);
      window.removeEventListener("message", handleMessage);
    };
  }, [
    bridgeToken,
    descriptor,
    htmlByteLength,
    maxHeight,
    messageId,
    state.kind,
    supportError,
    transportStore
  ]);

  if (state.kind === "error") {
    return (
      <div className="message-attachment-card interactive-html-attachment-card">
        <div className="message-attachment-copy">
          <strong>{title}</strong>
          <span>Interactive content</span>
        </div>
        <p className="field-error">{state.message}</p>
      </div>
    );
  }

  if (state.kind === "closed") {
    return (
      <div className="message-attachment-card interactive-html-attachment-card">
        <div className="message-attachment-copy">
          <strong>{title}</strong>
          <span>Interactive content</span>
        </div>
        <p className="interactive-html-summary">{state.summary}</p>
      </div>
    );
  }

  return (
    <section className="message-attachment-card interactive-html-attachment-card">
      <header className="interactive-html-attachment-header">
        <div className="interactive-html-attachment-copy">
          <strong>{title}</strong>
          <span>Sandboxed interactive content</span>
        </div>
      </header>
      <div
        className="interactive-html-attachment-stage"
        data-testid={`interactive-html-stage-${messageId}`}
        style={stageStyle}
      >
        <iframe
          aria-label={title}
          className="interactive-html-attachment-frame"
          data-testid={`interactive-html-frame-${messageId}`}
          onLoad={() => {
            if (descriptor?.metadata?.height?.kind === "fixed") {
              setState({ kind: "ready" });
            }
          }}
          ref={iframeRef}
          sandbox="allow-scripts"
          srcDoc={srcDoc}
          style={{ height: `${frameHeight}px` }}
          title={title}
        />
        {state.kind === "loading" ? (
          <div className="interactive-html-attachment-overlay">Loading interactive content…</div>
        ) : null}
      </div>
    </section>
  );
}

function clampHeight(height: number, maxHeight: number) {
  return Math.max(44, Math.min(height, maxHeight));
}

function interactiveHtmlSupportError() {
  if (typeof document === "undefined") {
    return "Interactive content is unavailable.";
  }

  const iframe = document.createElement("iframe");
  return "srcdoc" in iframe ? null : "Interactive content is unavailable in this browser.";
}

function asHeight(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const height = (value as Record<string, unknown>).height;
  return typeof height === "number" ? height : null;
}

function acceptCallback(callbackWindowRef: MutableRefObject<{ count: number; startedAt: number }>) {
  const now = Date.now();
  if (callbackWindowRef.current.startedAt === 0 || now - callbackWindowRef.current.startedAt >= 1000) {
    callbackWindowRef.current.startedAt = now;
    callbackWindowRef.current.count = 0;
  }
  if (callbackWindowRef.current.count >= CALLBACKS_PER_SECOND) {
    return false;
  }
  callbackWindowRef.current.count += 1;
  return true;
}

function makeBridgeToken() {
  return `bridge-${Math.random().toString(36).slice(2, 12)}`;
}

function sanitizeJsonValue(value: unknown): JsonValue | null {
  if (typeof value === "undefined") {
    return null;
  }

  try {
    return JSON.parse(JSON.stringify(value)) as JsonValue;
  } catch {
    return null;
  }
}

function injectInteractiveHtml(input: {
  isDark: boolean;
  rawHtml: string;
  token: string;
}) {
  const csp =
    `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none';">`;
  const viewport =
    `<meta name="viewport" content="width=device-width, initial-scale=1">`;
  const themeStyle = interactiveHtmlThemeStyle(input.isDark);
  const bridgeScript = interactiveHtmlBridgeScript(input.token);

  let html = input.rawHtml;
  const insertion = `\n${viewport}\n${csp}\n${themeStyle}\n${bridgeScript}\n`;

  if (/<head>/i.test(html)) {
    return html.replace(/<head>/i, `<head>${insertion}`);
  }

  if (/<html[^>]*>/i.test(html)) {
    return html.replace(/<html[^>]*>/i, (match) => `${match}\n<head>${insertion}</head>`);
  }

  return `<head>${insertion}</head>${html}`;
}

function interactiveHtmlThemeStyle(isDark: boolean) {
  const background = isDark ? "#1a1a1a" : "#ffffff";
  const foreground = isDark ? "#ffffff" : "#111111";
  const bubbleBackground = isDark ? "#2a2a2a" : "#f2f2f2";
  const accent = "#007AFF";

  return `<style>
  :root {
    --clawline-bg: ${background};
    --clawline-fg: ${foreground};
    --clawline-accent: ${accent};
    --clawline-bubble-bg: ${bubbleBackground};
    --clawline-font-family: -apple-system, system-ui, sans-serif;
    --clawline-font-size: 16px;
  }
  html, body {
    margin: 0;
    padding: 0;
    background: transparent;
    color: var(--clawline-fg);
    font-family: var(--clawline-font-family);
    font-size: var(--clawline-font-size);
    -webkit-text-size-adjust: 100%;
    text-size-adjust: 100%;
    overflow: auto;
  }
  </style>`;
}

function interactiveHtmlBridgeScript(token: string) {
  const safeToken = JSON.stringify(token);
  return `<script>
  (() => {
    const token = ${safeToken};
    const post = (payload) => {
      window.parent.postMessage({ __clawlineInteractiveHtml: true, token, ...payload }, "*");
    };
    const bridge = {
      postMessage(message) {
        if (!message || typeof message !== "object") {
          return;
        }
        const action = typeof message.action === "string" ? message.action : "";
        if (!action) {
          return;
        }
        post({
          kind: "bridge",
          action,
          data: Object.prototype.hasOwnProperty.call(message, "data") ? message.data : undefined,
          height: typeof message.height === "number" ? message.height : undefined,
          summary: typeof message.summary === "string" ? message.summary : undefined
        });
      }
    };
    window.webkit = window.webkit || {};
    window.webkit.messageHandlers = window.webkit.messageHandlers || {};
    window.webkit.messageHandlers.clawline = bridge;
    window.Clawline = bridge;
    const sendMeasure = () => {
      const body = document.body;
      const height = body ? Math.ceil(body.scrollHeight) : 44;
      post({ kind: "measure", height });
    };
    window.addEventListener("load", () => {
      window.requestAnimationFrame(sendMeasure);
    }, { once: true });
  })();
  </script>`;
}
