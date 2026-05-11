import type { ReactNode } from "react";
import { createContext, useContext } from "react";
import {
  parseAuthResultPayload,
  parseServerPayload,
  serializeAuthPayload,
  serializeClientMessage,
  serializeClientStreamRead,
  serializeInteractiveCallback,
  type JsonValue
} from "../../protocol/chat-wire";
import type { ClientAttachmentPayload } from "../../protocol/chat-wire";
import type { AuthSessionStore } from "../auth/authSessionStore";
import type { ChatDomainStore } from "../chat/chatDomainStore";
import type { IncomingMessageSource } from "../chat/chatDomainStore";
import { createStore } from "../shared/store";
import { useStoreValue } from "../shared/useStoreValue";
import {
  createBrowserWebSocketFactory,
  type SocketLike,
  type WebSocketFactory
} from "./wsClient";
import { getWebClientFeatures } from "../terminal/terminalCapabilities";

export type TransportPhase =
  | "idle"
  | "connecting"
  | "authenticating"
  | "replaying"
  | "live"
  | "recovering"
  | "failed";

export interface TransportState {
  failureReason: string | null;
  isBrowserOnline: boolean;
  phase: TransportPhase;
  retryAttempt: number;
}

export interface SendMessageInput {
  attachments: ClientAttachmentPayload[];
  content: string;
  id: string;
  sessionKey?: string;
}

export interface TransportMachine {
  getState(): TransportState;
  sendInteractiveCallback(input: {
    action: string;
    data?: JsonValue;
    messageId: string;
  }): Promise<void>;
  subscribe(listener: () => void): () => void;
  publishReadState(sessionKey: string, lastReadMessageId: string): Promise<void>;
  retryNow(): void;
  sendMessage(input: SendMessageInput): Promise<void>;
}

interface CreateTransportMachineOptions {
  authSessionStore: AuthSessionStore;
  chatDomainStore: ChatDomainStore;
  browserRuntime?: BrowserRuntime;
  clientFeatures?: string[];
  selectedSessionKeySource?: (
    chatState: ReturnType<ChatDomainStore["getState"]>
  ) => string | undefined;
  webSocketFactory?: WebSocketFactory;
}

interface BrowserRuntime {
  addEventListener(type: "offline" | "online", listener: () => void): () => void;
  clearTimeout(timeoutId: number): void;
  isOnline(): boolean;
  setTimeout(listener: () => void, delayMs: number): number;
}

const TransportMachineContext = createContext<TransportMachine | null>(null);

const INITIAL_STATE: TransportState = {
  failureReason: null,
  isBrowserOnline: true,
  phase: "idle",
  retryAttempt: 0
};

const MAX_SYNC_REPLAY_MESSAGES = 24;
const REPLAY_MESSAGE_BATCH_SIZE = 24;
const SHOULD_WARN_ON_STREAM_SNAPSHOT =
  typeof process === "undefined" || process.env.NODE_ENV !== "production";
const WEB_CLIENT_ID = "clawline-web";

function readSelectedSessionKeyFromCurrentUrl(
  chatState: ReturnType<ChatDomainStore["getState"]>
) {
  if (typeof window === "undefined") {
    return undefined;
  }

  const path = window.location.protocol === "file:" && window.location.hash.startsWith("#/")
    ? window.location.hash.slice(1)
    : window.location.pathname;
  const match = /^\/chat\/([^/?#]+)/.exec(path);
  if (!match) {
    return undefined;
  }

  let routeSessionKey = match[1];
  try {
    routeSessionKey = decodeURIComponent(routeSessionKey);
  } catch {
    // Keep the raw route segment if the browser exposes a malformed escape.
  }

  const routeSessionExists = chatState.streams.some(
    (stream) => stream.sessionKey === routeSessionKey
  );
  if (chatState.streams.length > 0 && !routeSessionExists) {
    return undefined;
  }

  return routeSessionKey;
}

export function createTransportMachine({
  authSessionStore,
  chatDomainStore,
  browserRuntime = createBrowserRuntime(),
  clientFeatures,
  selectedSessionKeySource = readSelectedSessionKeyFromCurrentUrl,
  webSocketFactory = createBrowserWebSocketFactory()
}: CreateTransportMachineOptions): TransportMachine {
  const resolvedClientFeatures = clientFeatures ?? getWebClientFeatures();
  const baseStore = createStore<TransportState>({
    ...INITIAL_STATE,
    isBrowserOnline: browserRuntime.isOnline()
  });
  let socket: SocketLike | null = null;
  let reconnectTimer: number | null = null;
  let replayFlushTimer: number | null = null;
  let connectionGeneration = 0;
  let replayMessagesRemaining = 0;
  let shouldResetChatBeforeNextAuth = !authSessionStore.getState().session;
  let queuedReplayMessages: Array<{
    generation: number;
    payload: Parameters<ChatDomainStore["applyIncomingMessage"]>[0];
  }> = [];

  chatDomainStore.subscribe(() => {
    if (!authSessionStore.getState().session) {
      return;
    }

    if (baseStore.getState().phase !== "idle") {
      return;
    }

    if (!isChatReadyForAuth(chatDomainStore.getState())) {
      return;
    }

    void connect("auth-bootstrap");
  });

  browserRuntime.addEventListener("online", () => {
    baseStore.setState((current) => ({
      ...current,
      failureReason: current.phase === "recovering" ? null : current.failureReason,
      isBrowserOnline: true
    }));

    if (authSessionStore.getState().session && baseStore.getState().phase !== "live") {
      if (isChatReadyForAuth(chatDomainStore.getState())) {
        void connect("retry");
      }
    }
  });
  browserRuntime.addEventListener("offline", () => {
    teardown(false);
    baseStore.setState((current) => ({
      ...current,
      failureReason: "Browser offline",
      isBrowserOnline: false,
      phase: authSessionStore.getState().session ? "recovering" : "idle"
    }));
  });

  authSessionStore.subscribe(() => {
    const session = authSessionStore.getState().session;
    if (!session) {
      teardown(false);
      if (baseStore.getState().phase !== "failed") {
        baseStore.setState({
          ...INITIAL_STATE,
          isBrowserOnline: browserRuntime.isOnline()
        });
      }
      chatDomainStore.reset();
      shouldResetChatBeforeNextAuth = true;
      return;
    }

    if (shouldResetChatBeforeNextAuth) {
      chatDomainStore.reset();
      shouldResetChatBeforeNextAuth = false;
    }

    if (baseStore.getState().phase === "idle") {
      if (isChatReadyForAuth(chatDomainStore.getState())) {
        void connect("auth-bootstrap");
      }
    }
  });

  if (
    authSessionStore.getState().session &&
    isChatReadyForAuth(chatDomainStore.getState())
  ) {
    void connect("auth-bootstrap");
  }

  async function connect(trigger: "auth-bootstrap" | "retry") {
    const state = baseStore.getState();
    if (
      state.phase === "connecting" ||
      state.phase === "authenticating" ||
      state.phase === "replaying" ||
      state.phase === "live"
    ) {
      return;
    }

    const session = authSessionStore.getState().session;
    if (!session) {
      return;
    }

    if (!browserRuntime.isOnline()) {
      baseStore.setState((current) => ({
        ...current,
        failureReason: "Browser offline",
        isBrowserOnline: false,
        phase: "recovering"
      }));
      return;
    }

    if (reconnectTimer != null) {
      browserRuntime.clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    teardown(false);

    connectionGeneration += 1;
    replayMessagesRemaining = 0;
    const generation = connectionGeneration;
    baseStore.setState((current) => ({
      ...current,
      failureReason: null,
      isBrowserOnline: true,
      phase: "connecting"
    }));

    const nextSocket = webSocketFactory(session.serverUrl);
    socket = nextSocket;

    nextSocket.onopen = () => {
      if (generation !== connectionGeneration) {
        return;
      }

      baseStore.setState((current) => ({
        ...current,
        phase: "authenticating"
      }));

      const chatState = chatDomainStore.getState();
      const selectedReplaySessionKey = selectedSessionKeySource(chatState);

      nextSocket.send(
        serializeAuthPayload({
          type: "auth",
          protocolVersion: 1,
          token: session.token,
          deviceId: session.deviceId,
          lastMessageId: legacyReplayCursorForSession(
            chatState.replayCursorsBySessionKey,
            selectedReplaySessionKey
          ),
          clientFeatures: resolvedClientFeatures,
          client: {
            id: WEB_CLIENT_ID,
            features: resolvedClientFeatures
          },
          replayCursorsBySessionKey: toReplayCursorPayload(chatState.replayCursorsBySessionKey)
        })
      );
    };

    nextSocket.onmessage = (event) => {
      if (generation !== connectionGeneration) {
        return;
      }

      try {
        const type = JSON.parse(event.data).type as string | undefined;
        if (type === "auth_result") {
          const payload = parseAuthResultPayload(event.data);
          if (payload.success) {
            if (payload.historyReset || payload.replayTruncated) {
              chatDomainStore.resetForAuthoritativeReplay();
            }

            replayMessagesRemaining = payload.replayCount ?? 0;
            if (typeof payload.isAdmin === "boolean") {
              authSessionStore.updateAdminStatus(payload.isAdmin);
            }

            chatDomainStore.applySessionInfo({
              type: "session_info",
              userId: payload.userId,
              isAdmin: payload.isAdmin,
              sessionKeys: payload.sessionKeys,
              sessions: payload.sessions
            });
            if (payload.streamReadStates) {
              chatDomainStore.applyStreamReadStateSnapshot(payload.streamReadStates);
            }
            if (payload.streamTailStates) {
              chatDomainStore.applyStreamTailStateSnapshot(payload.streamTailStates);
            }

            syncReplayProgress(trigger);
            return;
          }

          baseStore.setState({
            failureReason: payload.reason ?? "Authentication failed",
            isBrowserOnline: browserRuntime.isOnline(),
            phase: "failed",
            retryAttempt: baseStore.getState().retryAttempt
          });
          teardown(false);
          authSessionStore.logout();
          return;
        }

        const payload = parseServerPayload(event.data);
        switch (payload.type) {
          case "message":
            const source: IncomingMessageSource =
              replayMessagesRemaining > 0 ? "replay" : "live";
            const messageInput = {
              localDeviceId: authSessionStore.getState().session?.deviceId ?? "",
              message: payload,
              selectedSessionKey: selectedSessionKeySource(chatDomainStore.getState()),
              source
            };
            if (
              source === "replay" &&
              (queuedReplayMessages.length > 0 ||
                replayMessagesRemaining > MAX_SYNC_REPLAY_MESSAGES)
            ) {
              queuedReplayMessages.push({
                generation,
                payload: messageInput
              });
              scheduleReplayFlush(trigger);
              return;
            }

            chatDomainStore.applyIncomingMessage(messageInput);
            if (source === "replay") {
              replayMessagesRemaining -= 1;
              syncReplayProgress(trigger);
            }
            return;
          case "ack":
            chatDomainStore.markMessageAcked(payload.id);
            return;
          case "stream_snapshot":
            if (SHOULD_WARN_ON_STREAM_SNAPSHOT) {
              console.warn("clawline stream_snapshot", payload.streams);
            }
            chatDomainStore.applyStreamSnapshot(payload.streams);
            syncReplayProgress(trigger);
            return;
          case "stream_created":
          case "stream_updated":
            chatDomainStore.upsertStream(payload.stream);
            return;
          case "stream_deleted":
            chatDomainStore.removeStream(payload.sessionKey);
            return;
          case "session_info":
            chatDomainStore.applySessionInfo(payload);
            syncReplayProgress(trigger);
            return;
          case "stream_read_state":
            chatDomainStore.applyStreamReadStateUpdate({
              lastReadMessageId: payload.lastReadMessageId,
              sessionKey: payload.sessionKey
            });
            return;
          case "stream_tail_state":
            chatDomainStore.applyStreamTailStateUpdate({
              sessionKey: payload.sessionKey,
              tailState: {
                lastMessageId: payload.lastMessageId,
                lastMessageRole: payload.lastMessageRole
              }
            });
            return;
          case "typing":
            if ((payload.role == null || payload.role === "assistant") && payload.sessionKey) {
              chatDomainStore.applyAssistantTypingState({
                active: payload.active,
                sessionKey: payload.sessionKey
              });
            }
            return;
          case "event":
            applyAssistantActivityEvent(payload);
            return;
          case "sync_complete":
            replayMessagesRemaining = 0;
            syncReplayProgress(trigger);
            return;
          case "error":
            if (payload.messageId) {
              chatDomainStore.markMessageFailed(payload.messageId);
            }
            baseStore.setState((current) => ({
              ...current,
              failureReason: payload.message ?? payload.code
            }));
            return;
          default:
            return;
        }
      } catch (error) {
        console.warn("clawline transport dropped payload", error, event.data);
      }
    };

    nextSocket.onerror = () => {
      if (generation !== connectionGeneration) {
        return;
      }
      enterRecovery("Connection error");
    };

    nextSocket.onclose = () => {
      if (generation !== connectionGeneration) {
        return;
      }

      const currentPhase = baseStore.getState().phase;
      if (currentPhase === "idle" || currentPhase === "failed") {
        return;
      }

      enterRecovery("Connection closed");
    };
  }

  function applyAssistantActivityEvent(payload: {
    event: string;
    payload?: Record<string, unknown> | null;
  }) {
    if (payload.event !== "activity") {
      return;
    }

    const eventPayload = payload.payload;
    const sessionKey =
      typeof eventPayload?.sessionKey === "string" ? eventPayload.sessionKey : "";
    if (!sessionKey) {
      return;
    }

    const active =
      typeof eventPayload?.isActive === "boolean"
        ? eventPayload.isActive
        : typeof eventPayload?.active === "boolean"
          ? eventPayload.active
          : null;
    if (active == null) {
      return;
    }

    chatDomainStore.applyAssistantTypingState({
      active,
      sessionKey
    });
  }

  function enterRecovery(reason: string) {
    teardown(false);

    baseStore.setState((current) => {
      const retryAttempt = current.retryAttempt + 1;
      if (browserRuntime.isOnline()) {
        scheduleReconnect(retryAttempt);
      }
      return {
        failureReason: reason,
        isBrowserOnline: browserRuntime.isOnline(),
        phase: "recovering",
        retryAttempt
      };
    });
  }

  function syncReplayProgress(trigger: "auth-bootstrap" | "retry") {
    baseStore.setState((current) => ({
      failureReason: null,
      isBrowserOnline: true,
      phase: replayMessagesRemaining === 0 ? "live" : "replaying",
      retryAttempt: trigger === "retry" ? current.retryAttempt : 0
    }));
  }

  function scheduleReplayFlush(trigger: "auth-bootstrap" | "retry") {
    if (replayFlushTimer != null) {
      return;
    }

    replayFlushTimer = browserRuntime.setTimeout(() => {
      replayFlushTimer = null;
      flushQueuedReplayMessages(trigger);
    }, 0);
  }

  function flushQueuedReplayMessages(trigger: "auth-bootstrap" | "retry") {
    const batch = queuedReplayMessages.splice(0, REPLAY_MESSAGE_BATCH_SIZE);

    for (const entry of batch) {
      if (entry.generation !== connectionGeneration) {
        continue;
      }

      chatDomainStore.applyIncomingMessage(entry.payload);
      if (entry.payload.source === "replay" && replayMessagesRemaining > 0) {
        replayMessagesRemaining -= 1;
      }
    }

    syncReplayProgress(trigger);

    if (queuedReplayMessages.length > 0) {
      scheduleReplayFlush(trigger);
    }
  }

  function scheduleReconnect(retryAttempt: number) {
    const delayMs = Math.min(1000 * 2 ** Math.max(retryAttempt - 1, 0), 8000);
    reconnectTimer = browserRuntime.setTimeout(() => {
      reconnectTimer = null;
      void connect("retry");
    }, delayMs);
  }

  function teardown(incrementGeneration: boolean) {
    if (incrementGeneration) {
      connectionGeneration += 1;
    }

    queuedReplayMessages = [];
    if (replayFlushTimer != null) {
      browserRuntime.clearTimeout(replayFlushTimer);
      replayFlushTimer = null;
    }

    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close();
      socket = null;
    }
  }

  return {
    getState: baseStore.getState,
    subscribe: baseStore.subscribe,
    async publishReadState(sessionKey, lastReadMessageId) {
      if (
        baseStore.getState().phase !== "live" ||
        !socket ||
        !sessionKey ||
        !lastReadMessageId.startsWith("s_")
      ) {
        return;
      }

      socket.send(
        serializeClientStreamRead({
          type: "stream_read",
          sessionKey,
          lastReadMessageId
        })
      );
    },
    retryNow() {
      void connect("retry");
    },
    async sendMessage(input) {
      if (baseStore.getState().phase !== "live" || !socket) {
        throw new Error("Transport is not live");
      }

      socket.send(
        serializeClientMessage({
          type: "message",
          id: input.id,
          content: input.content,
          attachments: input.attachments,
          sessionKey: input.sessionKey
        })
      );
    },
    async sendInteractiveCallback(input) {
      if (baseStore.getState().phase !== "live" || !socket) {
        throw new Error("Transport is not live");
      }

      socket.send(
        serializeInteractiveCallback({
          type: "interactive-callback",
          messageId: input.messageId,
          payload: {
            action: input.action,
            data: input.data
          }
        })
      );
    }
  };
}

function createBrowserRuntime(): BrowserRuntime {
  return {
    addEventListener(type, listener) {
      window.addEventListener(type, listener);
      return () => window.removeEventListener(type, listener);
    },
    clearTimeout(timeoutId) {
      window.clearTimeout(timeoutId);
    },
    isOnline() {
      return navigator.onLine;
    },
    setTimeout(listener, delayMs) {
      return window.setTimeout(listener, delayMs);
    }
  };
}

function isChatReadyForAuth(
  chatState: ChatDomainStore["getState"] extends () => infer State ? State : never
) {
  return (
    chatState.hydrated ||
    chatState.lastServerEventId != null ||
    chatState.streams.length > 0 ||
    Object.keys(chatState.messagesBySessionKey).length > 0 ||
    Object.keys(chatState.replayCursorsBySessionKey).length > 0
  );
}

function toReplayCursorPayload(
  replayCursorsBySessionKey: ChatDomainStore["getState"] extends () => infer State
    ? State extends { replayCursorsBySessionKey: infer ReplayCursors }
      ? ReplayCursors
      : never
    : never
) {
  const entries = Object.entries(replayCursorsBySessionKey).flatMap(
    ([sessionKey, cursor]) =>
      typeof cursor?.lastServerEventId === "string" &&
      cursor.lastServerEventId.length > 0
        ? [[sessionKey, cursor.lastServerEventId] as const]
        : []
  );

  return entries.length > 0 ? Object.fromEntries(entries) : undefined;
}

function legacyReplayCursorForSession(
  replayCursorsBySessionKey: ChatDomainStore["getState"] extends () => infer State
    ? State extends { replayCursorsBySessionKey: infer ReplayCursors }
      ? ReplayCursors
      : never
    : never,
  sessionKey: string | undefined
) {
  if (!sessionKey) {
    return null;
  }

  const cursor = replayCursorsBySessionKey[sessionKey]?.lastServerEventId;
  return typeof cursor === "string" && cursor.length > 0 ? cursor : null;
}

export function TransportMachineProvider({
  children,
  value
}: {
  children: ReactNode;
  value: TransportMachine;
}) {
  return (
    <TransportMachineContext.Provider value={value}>
      {children}
    </TransportMachineContext.Provider>
  );
}

export function useTransportMachine() {
  const store = useContext(TransportMachineContext);
  if (!store) {
    throw new Error("TransportMachineProvider is missing");
  }

  const state = useStoreValue(store, (snapshot) => snapshot);
  return { store, state };
}
