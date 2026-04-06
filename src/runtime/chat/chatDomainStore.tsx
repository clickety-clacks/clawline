import type { ReactNode } from "react";
import { createContext, useContext } from "react";
import type {
  ClientAttachmentPayload,
  ServerAttachmentPayload,
  ServerMessagePayload,
  SessionInfoPayload,
  StreamSessionPayload
} from "../../protocol/chat-wire";
import {
  createIndexedDbChatPersistence,
  type ChatPersistence
} from "../persistence/indexedDbChatPersistence";
import { createStore } from "../shared/store";
import { useStoreValue } from "../shared/useStoreValue";
import {
  applyServerMessage,
  applySessionDescriptors,
  applyStreamSnapshot as applyStreamSnapshotToState,
  applyStreamUpdate as applyStreamUpdateToState
} from "./applyServerEvent";

export type DeliveryState = "pending" | "acked" | "failed" | "server";

export interface StreamRecord extends StreamSessionPayload {}

export interface ChatMessageRecord {
  id: string;
  role: "user" | "assistant";
  content: string;
  timestamp: number;
  streaming: boolean;
  deviceId?: string;
  sessionKey: string;
  sender?: string;
  attachments: ServerAttachmentPayload[];
  delivery: DeliveryState;
}

export interface PendingMessageRecord {
  attachments: ServerAttachmentPayload[];
  content: string;
  createdAt: number;
  sessionKey: string;
  wireAttachments: ClientAttachmentPayload[];
}

export interface ReplayCursorRecord {
  lastServerEventId?: string | null;
  lastReadMessageId: string | null;
}

export interface SessionScrollState {
  offsetTop: number;
  stickToBottom: boolean;
}

export type IncomingMessageSource = "live" | "replay";

export interface ChatDomainState {
  firstUnreadMessageIdBySessionKey: Record<string, string>;
  hydrated: boolean;
  lastServerEventId: string | null;
  messagesBySessionKey: Record<string, ChatMessageRecord[]>;
  pendingMessages: Record<string, PendingMessageRecord>;
  provisionedSessionKeys: string[];
  replayCursorsBySessionKey: Record<string, ReplayCursorRecord>;
  scrollStateBySessionKey: Record<string, SessionScrollState>;
  streams: StreamRecord[];
  unreadBySessionKey: Record<string, number>;
}

export interface ChatDomainSnapshot extends ChatDomainState {}

export interface EnqueueOptimisticMessageInput {
  attachments: ServerAttachmentPayload[];
  content: string;
  deviceId: string;
  id: string;
  sessionKey: string;
  timestamp: number;
  wireAttachments: ClientAttachmentPayload[];
}

export interface ChatDomainStore {
  getState(): ChatDomainState;
  subscribe(listener: () => void): () => void;
  enqueueOptimisticMessage(input: EnqueueOptimisticMessageInput): void;
  markMessageAcked(messageId: string): void;
  markMessageFailed(messageId: string): void;
  markMessagePending(messageId: string): void;
  resetForAuthoritativeReplay(): void;
  upsertStream(stream: StreamSessionPayload): void;
  removeStream(sessionKey: string): void;
  applyIncomingMessage(input: {
    localDeviceId: string;
    message: ServerMessagePayload;
    selectedSessionKey?: string;
    source: IncomingMessageSource;
  }): void;
  applySessionInfo(info: SessionInfoPayload): void;
  applyStreamSnapshot(streams: StreamSessionPayload[]): void;
  rememberSessionScrollState(input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }): void;
  markSessionRead(sessionKey?: string): void;
  reset(): void;
}

const ChatDomainStoreContext = createContext<ChatDomainStore | null>(null);

const EMPTY_STATE: ChatDomainState = {
  firstUnreadMessageIdBySessionKey: {},
  hydrated: false,
  lastServerEventId: null,
  messagesBySessionKey: {},
  pendingMessages: {},
  provisionedSessionKeys: [],
  replayCursorsBySessionKey: {},
  scrollStateBySessionKey: {},
  streams: [],
  unreadBySessionKey: {}
};

export function createChatDomainStore(options?: {
  persistence?: ChatPersistence;
}): ChatDomainStore {
  const persistence = options?.persistence ?? createIndexedDbChatPersistence();
  const baseStore = createStore<ChatDomainState>(EMPTY_STATE);

  void hydrate();

  function persist(nextState: ChatDomainState) {
    const snapshot: ChatDomainSnapshot = {
      ...nextState
    };
    void persistence.save(snapshot);
  }

  async function hydrate() {
    const persisted = await persistence.load();

    baseStore.setState((current) => {
      const hydratedState = persisted ? mergeHydratedState(current, persisted) : current;

      return {
        ...hydratedState,
        hydrated: true
      };
    });
  }

  return {
    getState: baseStore.getState,
    subscribe: baseStore.subscribe,
    enqueueOptimisticMessage(input) {
      baseStore.setState((current) => {
        const nextMessage: ChatMessageRecord = {
          id: input.id,
          role: "user",
          content: input.content,
          timestamp: input.timestamp,
          streaming: false,
          deviceId: input.deviceId,
          sessionKey: input.sessionKey,
          attachments: input.attachments,
          delivery: "pending"
        };
        const nextState = {
          ...current,
          messagesBySessionKey: {
            ...current.messagesBySessionKey,
            [input.sessionKey]: [
              ...(current.messagesBySessionKey[input.sessionKey] ?? []),
              nextMessage
            ]
          },
          pendingMessages: {
            ...current.pendingMessages,
            [input.id]: {
              attachments: input.attachments,
              content: input.content,
              createdAt: input.timestamp,
              sessionKey: input.sessionKey,
              wireAttachments: input.wireAttachments
            }
          }
        };

        persist(nextState);
        return nextState;
      });
    },
    markMessageAcked(messageId) {
      baseStore.setState((current) => {
        const pendingRecord = current.pendingMessages[messageId];
        if (!pendingRecord) {
          return current;
        }

        const sessionMessages = current.messagesBySessionKey[pendingRecord.sessionKey] ?? [];
        const nextMessages = sessionMessages.map((message) =>
          message.id === messageId ? { ...message, delivery: "acked" as const } : message
        );
        const nextState = {
          ...current,
          messagesBySessionKey: {
            ...current.messagesBySessionKey,
            [pendingRecord.sessionKey]: nextMessages
          }
        };

        persist(nextState);
        return nextState;
      });
    },
    markMessageFailed(messageId) {
      baseStore.setState((current) => {
        const pendingRecord = current.pendingMessages[messageId];
        if (!pendingRecord) {
          return current;
        }

        const sessionMessages = current.messagesBySessionKey[pendingRecord.sessionKey] ?? [];
        const nextMessages = sessionMessages.map((message) =>
          message.id === messageId ? { ...message, delivery: "failed" as const } : message
        );
        const nextState = {
          ...current,
          messagesBySessionKey: {
            ...current.messagesBySessionKey,
            [pendingRecord.sessionKey]: nextMessages
          }
        };

        persist(nextState);
        return nextState;
      });
    },
    markMessagePending(messageId) {
      baseStore.setState((current) => {
        const pendingRecord = current.pendingMessages[messageId];
        if (!pendingRecord) {
          return current;
        }

        const sessionMessages = current.messagesBySessionKey[pendingRecord.sessionKey] ?? [];
        const nextMessages = sessionMessages.map((message) =>
          message.id === messageId ? { ...message, delivery: "pending" as const } : message
        );
        const nextState = {
          ...current,
          messagesBySessionKey: {
            ...current.messagesBySessionKey,
            [pendingRecord.sessionKey]: nextMessages
          }
        };

        persist(nextState);
        return nextState;
      });
    },
    resetForAuthoritativeReplay() {
      baseStore.setState((current) => {
        const nextState = {
          ...EMPTY_STATE,
          hydrated: current.hydrated
        };

        persist(nextState);
        return nextState;
      });
    },
    upsertStream(stream) {
      baseStore.setState((current) => {
        const nextState = applyStreamUpdateToState(current, stream);
        persist(nextState);
        return nextState;
      });
    },
    removeStream(sessionKey) {
      baseStore.setState((current) => {
        const nextState = {
          ...current,
          provisionedSessionKeys: current.provisionedSessionKeys.filter(
            (entry) => entry !== sessionKey
          ),
          streams: current.streams.filter((stream) => stream.sessionKey !== sessionKey)
        };
        persist(nextState);
        return nextState;
      });
    },
    applyIncomingMessage(input) {
      baseStore.setState((current) => {
        const nextState = applyServerMessage(current, input);
        persist(nextState);
        return nextState;
      });
    },
    applySessionInfo(info) {
      baseStore.setState((current) => {
        const nextState = applySessionDescriptors(
          current,
          info.sessions,
          info.sessionKeys
        );
        persist(nextState);
        return nextState;
      });
    },
    applyStreamSnapshot(streams) {
      baseStore.setState((current) => {
        const nextState = applyStreamSnapshotToState(current, streams);
        persist(nextState);
        return nextState;
      });
    },
    rememberSessionScrollState(input) {
      baseStore.setState((current) => {
        const currentScrollState = current.scrollStateBySessionKey[input.sessionKey];
        const nextScrollState = {
          offsetTop: Math.max(0, Math.round(input.offsetTop)),
          stickToBottom: input.stickToBottom
        };

        if (
          currentScrollState?.offsetTop === nextScrollState.offsetTop &&
          currentScrollState?.stickToBottom === nextScrollState.stickToBottom
        ) {
          return current;
        }

        const nextState = {
          ...current,
          scrollStateBySessionKey: {
            ...current.scrollStateBySessionKey,
            [input.sessionKey]: nextScrollState
          }
        };

        persist(nextState);
        return nextState;
      });
    },
    markSessionRead(sessionKey) {
      if (!sessionKey) {
        return;
      }

      baseStore.setState((current) => {
        const unreadCount = current.unreadBySessionKey[sessionKey] ?? 0;
        const firstUnread = current.firstUnreadMessageIdBySessionKey[sessionKey];

        const latestMessageId =
          current.messagesBySessionKey[sessionKey]?.at(-1)?.id ?? null;

        if (unreadCount === 0 && firstUnread == null) {
          const currentCursor = current.replayCursorsBySessionKey[sessionKey];

          if ((currentCursor?.lastReadMessageId ?? null) === latestMessageId) {
            return current;
          }

          const nextState = {
            ...current,
            replayCursorsBySessionKey: {
              ...current.replayCursorsBySessionKey,
              [sessionKey]: {
                lastServerEventId:
                  current.replayCursorsBySessionKey[sessionKey]?.lastServerEventId ?? null,
                lastReadMessageId: latestMessageId
              }
            }
          };

          persist(nextState);
          return nextState;
        }

        const nextUnreadBySessionKey = { ...current.unreadBySessionKey };
        delete nextUnreadBySessionKey[sessionKey];

        const nextFirstUnreadBySessionKey = {
          ...current.firstUnreadMessageIdBySessionKey
        };
        delete nextFirstUnreadBySessionKey[sessionKey];

        const nextState = {
          ...current,
          firstUnreadMessageIdBySessionKey: nextFirstUnreadBySessionKey,
          replayCursorsBySessionKey: {
            ...current.replayCursorsBySessionKey,
            [sessionKey]: {
              lastServerEventId:
                current.replayCursorsBySessionKey[sessionKey]?.lastServerEventId ?? null,
              lastReadMessageId: latestMessageId
            }
          },
          unreadBySessionKey: nextUnreadBySessionKey
        };

        persist(nextState);
        return nextState;
      });
    },
    reset() {
      void persistence.clear();
      baseStore.setState({
        ...EMPTY_STATE,
        hydrated: true
      });
    }
  };
}

export function ChatDomainStoreProvider({
  children,
  value
}: {
  children: ReactNode;
  value: ChatDomainStore;
}) {
  return (
    <ChatDomainStoreContext.Provider value={value}>
      {children}
    </ChatDomainStoreContext.Provider>
  );
}

export function useChatDomainStore() {
  const store = useContext(ChatDomainStoreContext);
  if (!store) {
    throw new Error("ChatDomainStoreProvider is missing");
  }

  const state = useStoreValue(store, (snapshot) => snapshot);
  return { store, state };
}

function mergeHydratedState(
  liveState: ChatDomainState,
  persistedState: ChatDomainSnapshot
) {
  if (
    Object.keys(liveState.messagesBySessionKey).length === 0 &&
    liveState.streams.length === 0
  ) {
    return persistedState;
  }

  const streamsByKey = new Map(
    persistedState.streams.map((stream) => [stream.sessionKey, stream])
  );
  for (const stream of liveState.streams) {
    streamsByKey.set(stream.sessionKey, stream);
  }

  return {
    ...persistedState,
    ...liveState,
    streams: [...streamsByKey.values()].sort((left, right) => {
      if (left.orderIndex !== right.orderIndex) {
        return left.orderIndex - right.orderIndex;
      }
      return left.displayName.localeCompare(right.displayName);
    }),
    messagesBySessionKey: {
      ...persistedState.messagesBySessionKey,
      ...liveState.messagesBySessionKey
    },
    pendingMessages: {
      ...persistedState.pendingMessages,
      ...liveState.pendingMessages
    },
    replayCursorsBySessionKey: {
      ...persistedState.replayCursorsBySessionKey,
      ...liveState.replayCursorsBySessionKey
    },
    scrollStateBySessionKey: {
      ...persistedState.scrollStateBySessionKey,
      ...liveState.scrollStateBySessionKey
    },
    provisionedSessionKeys:
      liveState.provisionedSessionKeys.length > 0
        ? [...liveState.provisionedSessionKeys]
        : [...persistedState.provisionedSessionKeys],
    firstUnreadMessageIdBySessionKey: {
      ...persistedState.firstUnreadMessageIdBySessionKey,
      ...liveState.firstUnreadMessageIdBySessionKey
    },
    unreadBySessionKey: {
      ...persistedState.unreadBySessionKey,
      ...liveState.unreadBySessionKey
    }
  };
}
