import type { ReactNode } from "react";
import { createContext, useContext } from "react";
import type { ServerMessagePayload } from "../../protocol/chat-wire";
import { createStore } from "../shared/store";
import { useStoreValue } from "../shared/useStoreValue";
import type { IncomingMessageSource, StreamRecord } from "./chatDomainStore";

export interface AssistantNotificationEntry {
  assistantMessageId: string;
  contentPreview: string;
  final: boolean;
  updatedAt: number;
}

export interface CrossChatNotificationBubble {
  entriesNewestFirst: AssistantNotificationEntry[];
  lastAssistantActivityAt: number;
  replyDraft: string;
  replyMode: boolean;
  sourceChatId: string;
  sourceTitle: string;
}

export interface CrossChatNotificationState {
  bubblesBySourceChatId: Record<string, CrossChatNotificationBubble>;
}

export interface CrossChatNotificationStore {
  getState(): CrossChatNotificationState;
  subscribe(listener: () => void): () => void;
  applyIncomingMessage(input: {
    message: ServerMessagePayload;
    selectedSessionKey?: string;
    source: IncomingMessageSource;
    streams: StreamRecord[];
  }): void;
  clearCrossChatNotifications(): void;
  dismissCrossChatNotification(sourceChatId: string): void;
  dismissUnavailableNotifications(availableSourceChatIds: readonly string[]): void;
  openCrossChatNotificationReply(sourceChatId: string): void;
  closeCrossChatNotificationReply(sourceChatId: string): void;
  setCrossChatNotificationReplyDraft(sourceChatId: string, draft: string): void;
  reset(): void;
}

const EMPTY_STATE: CrossChatNotificationState = {
  bubblesBySourceChatId: {}
};

const CrossChatNotificationStoreContext =
  createContext<CrossChatNotificationStore | null>(null);

export function createCrossChatNotificationStore(): CrossChatNotificationStore {
  const baseStore = createStore<CrossChatNotificationState>(EMPTY_STATE);

  return {
    getState: baseStore.getState,
    subscribe: baseStore.subscribe,
    applyIncomingMessage(input) {
      baseStore.setState((current) =>
        applyCrossChatNotificationForIncomingMessage(current, input)
      );
    },
    clearCrossChatNotifications() {
      baseStore.setState((current) => {
        if (Object.keys(current.bubblesBySourceChatId).length === 0) {
          return current;
        }
        return EMPTY_STATE;
      });
    },
    dismissCrossChatNotification(sourceChatId) {
      baseStore.setState((current) => {
        const nextBubbles = omitNotificationBubble(
          current.bubblesBySourceChatId,
          sourceChatId
        );
        if (nextBubbles === current.bubblesBySourceChatId) {
          return current;
        }
        return {
          bubblesBySourceChatId: nextBubbles
        };
      });
    },
    dismissUnavailableNotifications(availableSourceChatIds) {
      baseStore.setState((current) => {
        const available = new Set(availableSourceChatIds);
        const nextBubbles = Object.fromEntries(
          Object.entries(current.bubblesBySourceChatId).filter(([sourceChatId]) =>
            available.has(sourceChatId)
          )
        );
        if (
          Object.keys(nextBubbles).length ===
          Object.keys(current.bubblesBySourceChatId).length
        ) {
          return current;
        }
        return {
          bubblesBySourceChatId: nextBubbles
        };
      });
    },
    openCrossChatNotificationReply(sourceChatId) {
      baseStore.setState((current) =>
        updateNotificationBubble(current, sourceChatId, (bubble) => ({
          ...bubble,
          replyMode: true
        }))
      );
    },
    closeCrossChatNotificationReply(sourceChatId) {
      baseStore.setState((current) =>
        updateNotificationBubble(current, sourceChatId, (bubble) => ({
          ...bubble,
          replyDraft: "",
          replyMode: false
        }))
      );
    },
    setCrossChatNotificationReplyDraft(sourceChatId, draft) {
      baseStore.setState((current) =>
        updateNotificationBubble(current, sourceChatId, (bubble) => ({
          ...bubble,
          replyDraft: draft
        }))
      );
    },
    reset() {
      baseStore.setState(EMPTY_STATE);
    }
  };
}

export function CrossChatNotificationStoreProvider({
  children,
  value
}: {
  children: ReactNode;
  value: CrossChatNotificationStore;
}) {
  return (
    <CrossChatNotificationStoreContext.Provider value={value}>
      {children}
    </CrossChatNotificationStoreContext.Provider>
  );
}

export function useCrossChatNotificationStore() {
  const store = useContext(CrossChatNotificationStoreContext);
  if (!store) {
    throw new Error("CrossChatNotificationStoreProvider is missing");
  }

  const state = useStoreValue(store, (snapshot) => snapshot);
  return { store, state };
}

function applyCrossChatNotificationForIncomingMessage(
  state: CrossChatNotificationState,
  input: Parameters<CrossChatNotificationStore["applyIncomingMessage"]>[0]
) {
  const { message, selectedSessionKey, source, streams } = input;
  const sourceChatId = message.sessionKey ?? streams[0]?.sessionKey ?? "unassigned";

  if (
    source !== "live" ||
    message.role !== "assistant" ||
    sourceChatId === selectedSessionKey
  ) {
    return state;
  }

  const currentBubble = state.bubblesBySourceChatId[sourceChatId];
  const sourceTitle =
    streams.find((stream) => stream.sessionKey === sourceChatId)?.displayName ??
    sourceChatId;
  const nextEntry: AssistantNotificationEntry = {
    assistantMessageId: message.id,
    contentPreview: message.content,
    final: !message.streaming,
    updatedAt: message.timestamp
  };
  const priorEntries = currentBubble?.entriesNewestFirst ?? [];
  const existingIndex = priorEntries.findIndex(
    (entry) => entry.assistantMessageId === message.id
  );
  const entriesNewestFirst =
    existingIndex >= 0
      ? [
          nextEntry,
          ...priorEntries.filter((_, entryIndex) => entryIndex !== existingIndex)
        ]
      : [nextEntry, ...priorEntries];

  return {
    bubblesBySourceChatId: {
      ...state.bubblesBySourceChatId,
      [sourceChatId]: {
        sourceChatId,
        sourceTitle,
        entriesNewestFirst,
        lastAssistantActivityAt: message.timestamp,
        replyDraft: currentBubble?.replyDraft ?? "",
        replyMode: currentBubble?.replyMode ?? false
      }
    }
  };
}

function omitNotificationBubble(
  bubbles: Record<string, CrossChatNotificationBubble>,
  sourceChatId: string
) {
  if (!(sourceChatId in bubbles)) {
    return bubbles;
  }

  const nextBubbles = { ...bubbles };
  delete nextBubbles[sourceChatId];
  return nextBubbles;
}

function updateNotificationBubble(
  state: CrossChatNotificationState,
  sourceChatId: string,
  update: (bubble: CrossChatNotificationBubble) => CrossChatNotificationBubble
) {
  const bubble = state.bubblesBySourceChatId[sourceChatId];
  if (!bubble) {
    return state;
  }

  return {
    bubblesBySourceChatId: {
      ...state.bubblesBySourceChatId,
      [sourceChatId]: update(bubble)
    }
  };
}
