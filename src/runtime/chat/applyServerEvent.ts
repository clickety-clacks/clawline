import type {
  ServerMessagePayload,
  SessionDescriptor,
  StreamSessionPayload
} from "../../protocol/chat-wire";
import type {
  ChatDomainState,
  ChatMessageRecord,
  IncomingMessageSource,
  StreamRecord
} from "./chatDomainStore";

export function applyServerMessage(
  state: ChatDomainState,
  input: {
    localDeviceId: string;
    message: ServerMessagePayload;
    selectedSessionKey?: string;
    source: IncomingMessageSource;
  }
) {
  const { localDeviceId, message, selectedSessionKey, source } = input;
  const sessionKey = message.sessionKey ?? state.streams[0]?.sessionKey ?? "unassigned";
  const currentMessages = state.messagesBySessionKey[sessionKey] ?? [];

  const existingIndex = currentMessages.findIndex(
    (entry) => entry.id === message.id
  );

  if (existingIndex >= 0) {
    const updated = {
      ...currentMessages[existingIndex],
      content: message.content,
      streaming: message.streaming,
      timestamp: message.timestamp,
      sender: message.sender,
      attachments: mergeServerAttachments(
        message.attachments,
        currentMessages[existingIndex].attachments
      ),
      deviceId: message.deviceId,
      delivery: "server" as const
    };
    return {
      ...state,
      lastServerEventId: message.id,
      replayCursorsBySessionKey: {
        ...state.replayCursorsBySessionKey,
        [sessionKey]: {
          ...state.replayCursorsBySessionKey[sessionKey],
          lastReadMessageId:
            state.replayCursorsBySessionKey[sessionKey]?.lastReadMessageId ?? null,
          lastServerEventId: message.id
        }
      },
      messagesBySessionKey: {
        ...state.messagesBySessionKey,
        [sessionKey]: replaceAtIndex(currentMessages, existingIndex, updated)
      }
    };
  }

  if (message.role === "user" && message.deviceId === localDeviceId) {
    const optimisticIndex = currentMessages.findIndex(
      (entry) =>
        entry.delivery !== "server" &&
        entry.role === "user" &&
        entry.content === message.content &&
        attachmentsMatch(entry.attachments, message.attachments)
    );

    if (optimisticIndex >= 0) {
      const optimistic = currentMessages[optimisticIndex];
      const replacement: ChatMessageRecord = {
        ...optimistic,
        id: message.id,
        timestamp: message.timestamp,
        streaming: message.streaming,
        sender: message.sender,
        attachments: mergeServerAttachments(message.attachments, optimistic.attachments),
        deviceId: message.deviceId,
        delivery: "server"
      };

      const nextPending = { ...state.pendingMessages };
      delete nextPending[optimistic.id];

      return {
        ...state,
        lastServerEventId: message.id,
        pendingMessages: nextPending,
        replayCursorsBySessionKey: {
          ...state.replayCursorsBySessionKey,
          [sessionKey]: {
            ...state.replayCursorsBySessionKey[sessionKey],
            lastReadMessageId:
              state.replayCursorsBySessionKey[sessionKey]?.lastReadMessageId ?? null,
            lastServerEventId: message.id
          }
        },
        messagesBySessionKey: {
          ...state.messagesBySessionKey,
          [sessionKey]: replaceAtIndex(currentMessages, optimisticIndex, replacement)
        }
      };
    }
  }

  const nextMessage: ChatMessageRecord = {
    id: message.id,
    role: message.role,
    content: message.content,
    timestamp: message.timestamp,
    streaming: message.streaming,
    deviceId: message.deviceId,
    sessionKey,
    sender: message.sender,
    attachments: message.attachments,
    delivery: "server"
  };

  return {
    ...state,
    lastServerEventId: message.id,
    replayCursorsBySessionKey: {
      ...state.replayCursorsBySessionKey,
      [sessionKey]: {
        ...state.replayCursorsBySessionKey[sessionKey],
        lastReadMessageId:
          state.replayCursorsBySessionKey[sessionKey]?.lastReadMessageId ?? null,
        lastServerEventId: message.id
      }
    },
    firstUnreadMessageIdBySessionKey:
      shouldMarkUnread(message, sessionKey, selectedSessionKey, source)
        ? {
            ...state.firstUnreadMessageIdBySessionKey,
            [sessionKey]:
              state.firstUnreadMessageIdBySessionKey[sessionKey] ?? message.id
          }
        : state.firstUnreadMessageIdBySessionKey,
    messagesBySessionKey: {
      ...state.messagesBySessionKey,
      [sessionKey]: [...currentMessages, nextMessage].sort(sortMessages)
    },
    unreadBySessionKey:
      shouldMarkUnread(message, sessionKey, selectedSessionKey, source)
        ? {
            ...state.unreadBySessionKey,
            [sessionKey]: (state.unreadBySessionKey[sessionKey] ?? 0) + 1
          }
        : state.unreadBySessionKey
  };
}

function shouldMarkUnread(
  message: ServerMessagePayload,
  sessionKey: string,
  selectedSessionKey: string | undefined,
  source: IncomingMessageSource
) {
  return (
    source === "live" &&
    message.role === "assistant" &&
    sessionKey !== selectedSessionKey
  );
}

function attachmentsMatch(
  current: ChatMessageRecord["attachments"],
  incoming: ServerMessagePayload["attachments"]
) {
  if (current.length !== incoming.length) {
    return false;
  }

  return current.every((attachment, index) => {
    const next = incoming[index];
    return (
      attachment.type === next.type &&
      attachment.assetId === next.assetId &&
      attachment.data === next.data &&
      attachment.mimeType === next.mimeType
    );
  });
}

function mergeServerAttachments(
  incoming: ServerMessagePayload["attachments"],
  existing: ChatMessageRecord["attachments"]
) {
  return incoming.map((attachment, index) => {
    const prior = existing[index];
    if (!prior) {
      return attachment;
    }

    return {
      ...attachment,
      metadata: attachment.metadata ?? prior.metadata,
      mimeType: attachment.mimeType ?? prior.mimeType
    };
  });
}

export function applyStreamSnapshot(
  state: ChatDomainState,
  streams: StreamSessionPayload[]
) {
  if (typeof process === "undefined" || process.env.NODE_ENV !== "production") {
    console.warn(
      "clawline applyStreamSnapshot displayNames",
      streams.map((stream) => ({
        displayName: stream.displayName,
        sessionKey: stream.sessionKey
      }))
    );
  }

  const mergedStreams = mergeStreams(
    [],
    streams.map((stream) => ({
      ...toStreamRecord(stream),
      displayName: stream.displayName
    }))
  );
  return {
    ...state,
    streams: mergedStreams
  };
}

export function applyStreamUpdate(
  state: ChatDomainState,
  stream: StreamSessionPayload
) {
  const mergedStreams = mergeStreams(state.streams, [toStreamRecord(stream)]);
  return {
    ...state,
    streams: mergedStreams
  };
}

export function applySessionDescriptors(
  state: ChatDomainState,
  descriptors: SessionDescriptor[] | undefined,
  sessionKeys: string[] | undefined
) {
  const nextProvisionedSessionKeys = normalizeProvisionedSessionKeys(
    descriptors,
    sessionKeys
  );
  const existingKeys = new Set(state.streams.map((stream) => stream.sessionKey));
  const provisionalStreams = [
    ...(descriptors ?? []).flatMap((descriptor, index) => {
      if (existingKeys.has(descriptor.sessionKey)) {
        return [];
      }

      return [{
        sessionKey: descriptor.sessionKey,
        displayName: provisionalDisplayName(descriptor.sessionKey, descriptor.stream),
        kind: descriptor.stream ?? "session",
        orderIndex: index,
        isBuiltIn: index === 0,
        createdAt: 0,
        updatedAt: 0,
        adopted: false
      }];
    }),
    ...(sessionKeys ?? []).flatMap((sessionKey, index) => {
      if (existingKeys.has(sessionKey)) {
        return [];
      }

      return [{
        sessionKey,
        displayName: provisionalDisplayName(sessionKey),
        kind: "session",
        orderIndex: index,
        isBuiltIn: index === 0,
        createdAt: 0,
        updatedAt: 0,
        adopted: false
      }];
    })
  ];

  if (provisionalStreams.length === 0) {
    if (!nextProvisionedSessionKeys) {
      return state;
    }

    return {
      ...state,
      provisionedSessionKeys: nextProvisionedSessionKeys
    };
  }

  return {
    ...state,
    provisionedSessionKeys:
      nextProvisionedSessionKeys ?? state.provisionedSessionKeys,
    streams: mergeStreams(state.streams, provisionalStreams)
  };
}

function normalizeProvisionedSessionKeys(
  descriptors: SessionDescriptor[] | undefined,
  sessionKeys: string[] | undefined
) {
  if (!descriptors && !sessionKeys) {
    return undefined;
  }

  const orderedKeys = [
    ...(descriptors ?? []).map((descriptor) => descriptor.sessionKey),
    ...(sessionKeys ?? [])
  ];
  const seen = new Set<string>();
  const normalized: string[] = [];

  for (const sessionKey of orderedKeys) {
    const trimmed = sessionKey.trim();
    if (trimmed.length === 0 || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    normalized.push(trimmed);
  }

  return normalized;
}

function mergeStreams(
  existingStreams: StreamRecord[],
  incomingStreams: StreamRecord[]
) {
  const byKey = new Map(existingStreams.map((stream) => [stream.sessionKey, stream]));

  for (const incoming of incomingStreams) {
    byKey.set(incoming.sessionKey, {
      ...(byKey.get(incoming.sessionKey) ?? incoming),
      ...incoming
    });
  }

  return [...byKey.values()].sort((left, right) => {
    if (left.orderIndex !== right.orderIndex) {
      return left.orderIndex - right.orderIndex;
    }
    return left.displayName.localeCompare(right.displayName);
  });
}

function provisionalDisplayName(sessionKey: string, stream?: string) {
  if (stream === "personal" || sessionKey.endsWith(":main")) {
    return "Personal";
  }

  if (stream === "admin") {
    return "DM";
  }

  const pieces = sessionKey.split(":");
  return pieces.at(-1) ?? sessionKey;
}

function toStreamRecord(stream: StreamSessionPayload): StreamRecord {
  return {
    ...stream
  };
}

function replaceAtIndex<Value>(values: Value[], index: number, value: Value) {
  return values.map((entry, entryIndex) => (entryIndex === index ? value : entry));
}

function sortMessages(left: ChatMessageRecord, right: ChatMessageRecord) {
  if (left.timestamp !== right.timestamp) {
    return left.timestamp - right.timestamp;
  }

  return left.id.localeCompare(right.id);
}
