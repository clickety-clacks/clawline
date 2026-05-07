import { providerHttpBaseUrlFromServerUrl } from "../../protocol/stream-api";
import type { TerminalSessionDescriptor } from "../../protocol/terminal-wire";

export type TerminalRuntimePhase =
  | "disconnected"
  | "connecting"
  | "ready"
  | "exited"
  | "failed";

export interface TerminalRuntimeState {
  phase: TerminalRuntimePhase;
  exitCode?: number;
  reason?: string;
}

export interface TerminalSocketLike {
  binaryType: BinaryType;
  close(code?: number, reason?: string): void;
  onclose: ((event: CloseEvent | Event) => void) | null;
  onerror: ((event: Event) => void) | null;
  onmessage: ((event: MessageEvent<string | ArrayBuffer | Blob>) => void) | null;
  onopen: ((event: Event) => void) | null;
  send(data: string | ArrayBufferLike | Blob | ArrayBufferView): void;
}

export type TerminalWebSocketFactory = (url: string) => TerminalSocketLike;

interface CreateTerminalSessionRuntimeOptions {
  descriptor: TerminalSessionDescriptor;
  deviceId: string;
  onData: (chunk: string | Uint8Array) => void;
  onStateChange: (state: TerminalRuntimeState) => void;
  serverUrl: string;
  token: string;
  webSocketFactory?: TerminalWebSocketFactory;
}

type CloseIntent = "disconnect" | "failure" | "terminal-exit" | null;

const ENABLE_MESSAGES_DELAY_MS = 250;
const DEFAULT_BACKFILL_LINES = 2000;

export function createTerminalSessionRuntime({
  descriptor,
  deviceId,
  onData,
  onStateChange,
  serverUrl,
  token,
  webSocketFactory = createBrowserTerminalWebSocketFactory()
}: CreateTerminalSessionRuntimeOptions) {
  const textEncoder = new TextEncoder();

  let socket: TerminalSocketLike | null = null;
  let enableMessagesTimer: ReturnType<typeof setTimeout> | null = null;
  let isOpen = false;
  let isReadyForInput = false;
  let closeIntent: CloseIntent = null;
  let pendingResize: { cols: number; rows: number } | null = null;
  let sawBackfillEnd = false;
  let requestedBackfillLines = 0;

  return {
    connect(input: { cols: number; rows: number; backfillLines?: number }) {
      if (socket) {
        return;
      }

      const url = makeTerminalWebSocketUrl({
        descriptor,
        serverUrl
      });
      if (!url) {
        onStateChange({
          phase: "failed",
          reason: "Missing provider URL"
        });
        return;
      }

      closeIntent = null;
      isOpen = false;
      isReadyForInput = false;
      pendingResize = null;
      sawBackfillEnd = false;
      requestedBackfillLines = input.backfillLines ?? DEFAULT_BACKFILL_LINES;
      onStateChange({ phase: "connecting" });

      const nextSocket = webSocketFactory(url);
      nextSocket.binaryType = "arraybuffer";
      nextSocket.onopen = () => {
        isOpen = true;
        sendAuth({
          cols: input.cols,
          rows: input.rows
        });
      };
      nextSocket.onmessage = (event) => {
        void handleMessage(event.data);
      };
      nextSocket.onerror = () => {
        handleFailure("Terminal connection failed.");
      };
      nextSocket.onclose = () => {
        cleanupSocket();
        if (
          closeIntent === "disconnect" ||
          closeIntent === "failure" ||
          closeIntent === "terminal-exit"
        ) {
          return;
        }
        onStateChange({
          phase: "failed",
          reason: "Terminal disconnected."
        });
      };
      socket = nextSocket;
    },
    disconnect() {
      closeIntent = "disconnect";
      clearEnableMessagesTimer();

      if (socket && isOpen && supportsDetach(descriptor)) {
        try {
          socket.send(JSON.stringify({ type: "terminal_detach" }));
        } catch {
          // Ignore detach send failures while closing.
        }
      }

      socket?.close();
      cleanupSocket();
      onStateChange({ phase: "disconnected" });
    },
    resize(cols: number, rows: number) {
      pendingResize = { cols, rows };
      if (!socket || !isReadyForInput || !supportsResize(descriptor)) {
        return;
      }

      socket.send(JSON.stringify({ type: "terminal_resize", cols, rows }));
    },
    sendInput(input: string) {
      if (!socket || !isReadyForInput || !isInteractive(descriptor)) {
        return;
      }

      if (supportsBinaryFrames(descriptor)) {
        socket.send(textEncoder.encode(input));
        return;
      }

      socket.send(input);
    }
  };

  function cleanupSocket() {
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
    }
    socket = null;
    isOpen = false;
    isReadyForInput = false;
    pendingResize = null;
    sawBackfillEnd = false;
    requestedBackfillLines = 0;
    clearEnableMessagesTimer();
  }

  function clearEnableMessagesTimer() {
    if (enableMessagesTimer != null) {
      clearTimeout(enableMessagesTimer);
      enableMessagesTimer = null;
    }
  }

  function sendAuth(input: { cols: number; rows: number }) {
    const authToken = descriptor.auth?.terminalAccessToken ?? token;
    if (!socket || !authToken) {
      handleFailure("Missing auth token");
      return;
    }

    socket.send(
      JSON.stringify({
        type: "terminal_auth",
        protocolVersion: 1,
        authMode:
          descriptor.auth?.terminalAccessToken != null
            ? "terminal_access_token"
            : "chat_token",
        authToken,
        deviceId,
        terminalSessionId: descriptor.terminalSessionId,
        backfillLines: requestedBackfillLines,
        cols: input.cols,
        rows: input.rows
      })
    );
  }

  async function handleMessage(data: string | ArrayBuffer | Blob) {
    if (typeof data === "string") {
      if (handleControlMessage(data)) {
        return;
      }
      onData(data);
      return;
    }

    const bytes =
      data instanceof Blob
        ? new Uint8Array(await data.arrayBuffer())
        : new Uint8Array(data);
    onData(bytes);
  }

  function handleControlMessage(text: string) {
    let payload: Record<string, unknown> | null = null;
    try {
      payload = JSON.parse(text) as Record<string, unknown>;
    } catch {
      return false;
    }

    if (!payload || typeof payload.type !== "string") {
      return false;
    }

    switch (payload.type) {
      case "terminal_ready":
        onStateChange({ phase: "ready" });
        scheduleEnableMessages();
        return true;
      case "terminal_backfill_end":
        sawBackfillEnd = true;
        scheduleEnableMessages();
        return true;
      case "terminal_exit":
        closeIntent = "terminal-exit";
        clearEnableMessagesTimer();
        isReadyForInput = false;
        onStateChange({
          phase: "exited",
          exitCode: typeof payload.code === "number" ? payload.code : undefined
        });
        return true;
      case "terminal_data":
        if (typeof payload.data === "string") {
          const decoded = tryDecodeBase64(payload.data);
          onData(decoded ?? payload.data);
        }
        return true;
      case "terminal_error":
        handleFailure(
          typeof payload.message === "string" && payload.message.length > 0
            ? payload.message
            : "Terminal error"
        );
        return true;
      case "terminal_closed":
        handleFailure(resolveClosedReason(payload));
        return true;
      default:
        return true;
    }
  }

  function scheduleEnableMessages() {
    if (enableMessagesTimer != null) {
      return;
    }

    enableMessagesTimer = setTimeout(() => {
      enableMessagesTimer = null;
      if (!socket) {
        return;
      }
      isReadyForInput = true;
      if (pendingResize && supportsResize(descriptor)) {
        socket.send(
          JSON.stringify({
            type: "terminal_resize",
            cols: pendingResize.cols,
            rows: pendingResize.rows
          })
        );
      }
    }, ENABLE_MESSAGES_DELAY_MS);
  }

  function handleFailure(reason: string) {
    closeIntent = "failure";
    onStateChange({
      phase: "failed",
      reason
    });
    socket?.close();
    cleanupSocket();
  }
}

export function createBrowserTerminalWebSocketFactory(): TerminalWebSocketFactory {
  return (url) => new WebSocket(url) as TerminalSocketLike;
}

function makeTerminalWebSocketUrl(input: {
  descriptor: TerminalSessionDescriptor;
  serverUrl: string;
}) {
  const baseUrl = input.serverUrl
    ? providerHttpBaseUrlFromServerUrl(input.serverUrl)
    : input.descriptor.provider?.baseUrl
      ? new URL(input.descriptor.provider.baseUrl)
      : null;

  if (!baseUrl) {
    return null;
  }

  if (baseUrl.protocol === "http:") {
    baseUrl.protocol = "ws:";
  } else if (baseUrl.protocol === "https:") {
    baseUrl.protocol = "wss:";
  }

  const candidatePath = input.descriptor.provider?.wsPath?.trim();
  baseUrl.pathname = candidatePath === "/ws/terminal" ? candidatePath : "/ws/terminal";
  return baseUrl.toString();
}

function tryDecodeBase64(value: string) {
  try {
    const decoded = atob(value);
    const bytes = new Uint8Array(decoded.length);
    for (let index = 0; index < decoded.length; index += 1) {
      bytes[index] = decoded.charCodeAt(index);
    }
    return bytes;
  } catch {
    return null;
  }
}

function resolveClosedReason(payload: Record<string, unknown>) {
  const message =
    typeof payload.message === "string" && payload.message.trim().length > 0
      ? payload.message.trim()
      : typeof payload.reason === "string" && payload.reason.trim().length > 0
        ? payload.reason.trim()
        : null;
  if (message) {
    return message;
  }

  return typeof payload.code === "number"
    ? `Terminal closed (code ${payload.code})`
    : "Terminal closed";
}

function isInteractive(descriptor: TerminalSessionDescriptor) {
  return descriptor.capabilities?.interactive !== false;
}

function supportsBinaryFrames(descriptor: TerminalSessionDescriptor) {
  return descriptor.capabilities?.supportsBinaryFrames !== false;
}

function supportsResize(descriptor: TerminalSessionDescriptor) {
  return descriptor.capabilities?.supportsResize !== false;
}

function supportsDetach(descriptor: TerminalSessionDescriptor) {
  return descriptor.capabilities?.supportsDetach !== false;
}
