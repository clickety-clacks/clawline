import type { ReactNode } from "react";
import { createContext, useContext } from "react";
import type {
  ClientAttachmentPayload,
  MessageRole,
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

export interface StreamTailStateRecord {
  lastMessageId: string;
  lastMessageRole: MessageRole;
}

export type StreamDotState = "inactive" | "unread" | "userTail";

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
  streamReadStateBySessionKey: Record<string, string>;
  streamTailStateBySessionKey: Record<string, StreamTailStateRecord>;
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
  applyStreamReadStateSnapshot(snapshot: Record<string, string>): void;
  applyStreamReadStateUpdate(input: {
    lastReadMessageId: string;
    sessionKey: string;
  }): void;
  applyStreamSnapshot(streams: StreamSessionPayload[]): void;
  applyStreamTailStateSnapshot(
    snapshot: Record<string, StreamTailStateRecord>
  ): void;
  applyStreamTailStateUpdate(input: {
    sessionKey: string;
    tailState: StreamTailStateRecord;
  }): void;
  rememberSessionScrollState(input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }): void;
  markSessionRead(sessionKey?: string): string | null;
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
  streamReadStateBySessionKey: {},
  streamTailStateBySessionKey: {},
  streams: [],
  unreadBySessionKey: {}
};

export function createChatDomainStore(options?: {
  persistence?: ChatPersistence;
}): ChatDomainStore {
  const persistence = options?.persistence ?? createIndexedDbChatPersistence();
  const baseStore = createStore<ChatDomainState>(EMPTY_STATE);
  let hydrationEpoch = 0;

  void hydrate();

  function persist(nextState: ChatDomainState) {
    const snapshot: ChatDomainSnapshot = {
      ...nextState
    };
    void persistence.save(snapshot);
  }

  async function hydrate() {
    const epoch = hydrationEpoch;
    const persisted = await persistence.load();

    baseStore.setState((current) => {
      if (epoch !== hydrationEpoch) {
        return {
          ...current,
          hydrated: true
        };
      }

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
        hydrationEpoch += 1;
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
    applyStreamReadStateSnapshot(snapshot) {
      baseStore.setState((current) => {
        const nextState = applyStreamReadStateSnapshot(current, snapshot);
        persist(nextState);
        return nextState;
      });
    },
    applyStreamReadStateUpdate(input) {
      baseStore.setState((current) => {
        const nextState = applyStreamReadStateUpdate(current, input);
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
    applyStreamTailStateSnapshot(snapshot) {
      baseStore.setState((current) => {
        const nextState = applyStreamTailStateSnapshot(current, snapshot);
        persist(nextState);
        return nextState;
      });
    },
    applyStreamTailStateUpdate(input) {
      baseStore.setState((current) => {
        const nextState = applyStreamTailStateUpdate(current, input);
        persist(nextState);
        return nextState;
      });
    },
    rememberSessionScrollState(input) {
      baseStore.setState((current) => {
        const currentScrollState = current.scrollStateBySessionKey[input.sessionKey];
        const nextScrollState = {
          offsetTop: input.stickToBottom
            ? Number.MAX_SAFE_INTEGER
            : Math.max(0, Math.round(input.offsetTop)),
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
        return null;
      }

      const current = baseStore.getState();
      const result = markSessionReadState(current, sessionKey);
      if (result.nextState !== current) {
        baseStore.setState(result.nextState);
        persist(result.nextState);
      }
      return result.lastReadMessageId;
    },
    reset() {
      hydrationEpoch += 1;
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
    streamReadStateBySessionKey: {
      ...persistedState.streamReadStateBySessionKey,
      ...liveState.streamReadStateBySessionKey
    },
    streamTailStateBySessionKey: {
      ...persistedState.streamTailStateBySessionKey,
      ...liveState.streamTailStateBySessionKey
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

export function resolveStreamDotStateMap(
  streamReadStateBySessionKey: Record<string, string>,
  streamTailStateBySessionKey: Record<string, StreamTailStateRecord>
) {
  return Object.fromEntries(
    Object.keys(streamTailStateBySessionKey).map((sessionKey) => [
      sessionKey,
      resolveStreamDotState(
        streamReadStateBySessionKey[sessionKey],
        streamTailStateBySessionKey[sessionKey]
      )
    ])
  ) as Record<string, StreamDotState>;
}

export function resolveStreamDotState(
  lastReadMessageId: string | undefined,
  tailState: StreamTailStateRecord | undefined
): StreamDotState {
  if (!tailState) {
    return "inactive";
  }

  if (tailState.lastMessageRole === "user") {
    return "userTail";
  }

  return lastReadMessageId !== tailState.lastMessageId ? "unread" : "inactive";
}

function applyStreamReadStateSnapshot(
  state: ChatDomainState,
  snapshot: Record<string, string>
) {
  const normalizedSnapshot = Object.fromEntries(
    Object.entries(snapshot).filter(
      ([sessionKey, lastReadMessageId]) =>
        sessionKey.length > 0 && lastReadMessageId.length > 0
    )
  );

  let nextState: ChatDomainState = state;
  const staleSessionKeys = Object.keys(state.streamReadStateBySessionKey).filter(
    (sessionKey) => !(sessionKey in normalizedSnapshot)
  );
  for (const sessionKey of staleSessionKeys) {
    nextState = clearStreamReadState(nextState, sessionKey);
  }

  for (const [sessionKey, lastReadMessageId] of Object.entries(normalizedSnapshot)) {
    nextState = applyStreamReadStateUpdate(nextState, {
      lastReadMessageId,
      sessionKey
    });
  }

  return nextState;
}

function applyStreamReadStateUpdate(
  state: ChatDomainState,
  input: {
    lastReadMessageId: string;
    sessionKey: string;
  }
) {
  if (input.sessionKey.length === 0 || input.lastReadMessageId.length === 0) {
    return state;
  }

  const currentLastRead = state.streamReadStateBySessionKey[input.sessionKey];
  const currentCursor = state.replayCursorsBySessionKey[input.sessionKey];
  if (
    currentLastRead === input.lastReadMessageId &&
    (currentCursor?.lastReadMessageId ?? null) === input.lastReadMessageId
  ) {
    return state;
  }

  return reconcileLocalUnreadWithRemoteRead({
    ...state,
    replayCursorsBySessionKey: {
      ...state.replayCursorsBySessionKey,
      [input.sessionKey]: {
        lastServerEventId: currentCursor?.lastServerEventId ?? null,
        lastReadMessageId: input.lastReadMessageId
      }
    },
    streamReadStateBySessionKey: {
      ...state.streamReadStateBySessionKey,
      [input.sessionKey]: input.lastReadMessageId
    }
  }, input.sessionKey, input.lastReadMessageId);
}

function applyStreamTailStateSnapshot(
  state: ChatDomainState,
  snapshot: Record<string, StreamTailStateRecord>
) {
  const normalizedSnapshot = Object.fromEntries(
    Object.entries(snapshot).filter(
      ([sessionKey, tailState]) =>
        sessionKey.length > 0 &&
        tailState.lastMessageId.length > 0 &&
        (tailState.lastMessageRole === "user" || tailState.lastMessageRole === "assistant")
    )
  );

  const nextTailStateBySessionKey = { ...normalizedSnapshot };
  if (
    shallowEqualStreamTailStateMaps(
      state.streamTailStateBySessionKey,
      nextTailStateBySessionKey
    )
  ) {
    return state;
  }

  const nextState = {
    ...state,
    streamTailStateBySessionKey: nextTailStateBySessionKey
  };

  return Object.entries(nextTailStateBySessionKey).reduce(
    (currentState, [sessionKey, tailState]) => {
      const lastReadMessageId = currentState.streamReadStateBySessionKey[sessionKey];
      return lastReadMessageId === tailState.lastMessageId
        ? clearLocalUnread(currentState, sessionKey)
        : currentState;
    },
    nextState
  );
}

function applyStreamTailStateUpdate(
  state: ChatDomainState,
  input: {
    sessionKey: string;
    tailState: StreamTailStateRecord;
  }
) {
  const { sessionKey, tailState } = input;
  if (
    sessionKey.length === 0 ||
    tailState.lastMessageId.length === 0 ||
    (tailState.lastMessageRole !== "user" && tailState.lastMessageRole !== "assistant")
  ) {
    return state;
  }

  const currentTailState = state.streamTailStateBySessionKey[sessionKey];
  if (
    currentTailState?.lastMessageId === tailState.lastMessageId &&
    currentTailState.lastMessageRole === tailState.lastMessageRole
  ) {
    return state;
  }

  const nextState = {
    ...state,
    streamTailStateBySessionKey: {
      ...state.streamTailStateBySessionKey,
      [sessionKey]: tailState
    }
  };

  return state.streamReadStateBySessionKey[sessionKey] === tailState.lastMessageId
    ? clearLocalUnread(nextState, sessionKey)
    : nextState;
}

function clearStreamReadState(state: ChatDomainState, sessionKey: string) {
  if (!(sessionKey in state.streamReadStateBySessionKey)) {
    return state;
  }

  const nextStreamReadStateBySessionKey = { ...state.streamReadStateBySessionKey };
  delete nextStreamReadStateBySessionKey[sessionKey];

  const currentCursor = state.replayCursorsBySessionKey[sessionKey];
  const nextReplayCursorsBySessionKey = { ...state.replayCursorsBySessionKey };
  if (currentCursor) {
    nextReplayCursorsBySessionKey[sessionKey] = {
      lastServerEventId: currentCursor.lastServerEventId ?? null,
      lastReadMessageId: null
    };
  }

  return {
    ...state,
    replayCursorsBySessionKey: nextReplayCursorsBySessionKey,
    streamReadStateBySessionKey: nextStreamReadStateBySessionKey
  };
}

function reconcileLocalUnreadWithRemoteRead(
  state: ChatDomainState,
  sessionKey: string,
  lastReadMessageId: string
) {
  const firstUnreadMessageId = state.firstUnreadMessageIdBySessionKey[sessionKey];
  if (!firstUnreadMessageId) {
    return state;
  }

  const tailMessageId = state.streamTailStateBySessionKey[sessionKey]?.lastMessageId;
  if (tailMessageId != null && tailMessageId === lastReadMessageId) {
    return clearLocalUnread(state, sessionKey);
  }

  const messages = state.messagesBySessionKey[sessionKey] ?? [];
  const firstUnreadIndex = messages.findIndex((message) => message.id === firstUnreadMessageId);
  const lastReadIndex = messages.findIndex((message) => message.id === lastReadMessageId);
  if (firstUnreadIndex < 0 || lastReadIndex < 0) {
    return state;
  }
  if (firstUnreadIndex >= 0 && lastReadIndex >= firstUnreadIndex) {
    return clearLocalUnread(state, sessionKey);
  }

  return state;
}

function clearLocalUnread(state: ChatDomainState, sessionKey: string) {
  if (
    !(sessionKey in state.firstUnreadMessageIdBySessionKey) &&
    !(sessionKey in state.unreadBySessionKey)
  ) {
    return state;
  }

  const nextFirstUnreadBySessionKey = { ...state.firstUnreadMessageIdBySessionKey };
  delete nextFirstUnreadBySessionKey[sessionKey];

  const nextUnreadBySessionKey = { ...state.unreadBySessionKey };
  delete nextUnreadBySessionKey[sessionKey];

  return {
    ...state,
    firstUnreadMessageIdBySessionKey: nextFirstUnreadBySessionKey,
    unreadBySessionKey: nextUnreadBySessionKey
  };
}

function markSessionReadState(state: ChatDomainState, sessionKey: string) {
  const unreadCount = state.unreadBySessionKey[sessionKey] ?? 0;
  const firstUnread = state.firstUnreadMessageIdBySessionKey[sessionKey];
  const lastReadMessageId =
    findLastServerMessageId(state.messagesBySessionKey[sessionKey] ?? []) ??
    state.streamTailStateBySessionKey[sessionKey]?.lastMessageId ??
    null;

  if (lastReadMessageId == null) {
    return {
      lastReadMessageId: null,
      nextState: state
    };
  }

  const currentCursor = state.replayCursorsBySessionKey[sessionKey];
  const currentReadState = state.streamReadStateBySessionKey[sessionKey] ?? null;
  if (
    unreadCount === 0 &&
    firstUnread == null &&
    (currentCursor?.lastReadMessageId ?? null) === lastReadMessageId &&
    currentReadState === lastReadMessageId
  ) {
    return {
      lastReadMessageId,
      nextState: state
    };
  }

  const nextState = clearLocalUnread({
    ...state,
    replayCursorsBySessionKey: {
      ...state.replayCursorsBySessionKey,
      [sessionKey]: {
        lastServerEventId: currentCursor?.lastServerEventId ?? null,
        lastReadMessageId
      }
    },
    streamReadStateBySessionKey: {
      ...state.streamReadStateBySessionKey,
      [sessionKey]: lastReadMessageId
    }
  }, sessionKey);

  return {
    lastReadMessageId,
    nextState
  };
}

function findLastServerMessageId(messages: ChatMessageRecord[]) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const messageId = messages[index]?.id;
    if (typeof messageId === "string" && messageId.startsWith("s_")) {
      return messageId;
    }
  }

  return null;
}

function shallowEqualStreamTailStateMaps(
  left: Record<string, StreamTailStateRecord>,
  right: Record<string, StreamTailStateRecord>
) {
  const leftEntries = Object.entries(left);
  const rightEntries = Object.entries(right);
  if (leftEntries.length !== rightEntries.length) {
    return false;
  }

  return leftEntries.every(([sessionKey, tailState]) => {
    const rightTailState = right[sessionKey];
    return (
      rightTailState?.lastMessageId === tailState.lastMessageId &&
      rightTailState.lastMessageRole === tailState.lastMessageRole
    );
  });
}
