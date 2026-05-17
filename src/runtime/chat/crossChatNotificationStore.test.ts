import { describe, expect, it } from "vitest";
import { createCrossChatNotificationStore } from "./crossChatNotificationStore";
import type { StreamRecord } from "./chatDomainStore";

const STREAMS: StreamRecord[] = [
  {
    sessionKey: "agent:main:clawline:user_1:main",
    displayName: "Personal",
    kind: "main",
    orderIndex: 0,
    isBuiltIn: true,
    createdAt: 10,
    updatedAt: 10,
    adopted: false
  },
  {
    sessionKey: "agent:main:clawline:user_1:side",
    displayName: "Side Thread",
    kind: "custom",
    orderIndex: 1,
    isBuiltIn: false,
    createdAt: 11,
    updatedAt: 11,
    adopted: false
  }
];

describe("crossChatNotificationStore", () => {
  it("keeps assistant notifications volatile, assistant-only, and updated in place", () => {
    const store = createCrossChatNotificationStore();

    store.applyIncomingMessage({
      message: {
        type: "message",
        id: "s_user",
        role: "user",
        content: "Ignored",
        timestamp: 100,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live",
      streams: STREAMS
    });
    store.applyIncomingMessage({
      message: {
        type: "message",
        id: "s_stream",
        role: "assistant",
        content: "Hel",
        timestamp: 101,
        streaming: true,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live",
      streams: STREAMS
    });
    store.applyIncomingMessage({
      message: {
        type: "message",
        id: "s_stream",
        role: "assistant",
        content: "Hello",
        timestamp: 102,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live",
      streams: STREAMS
    });

    expect(store.getState().bubblesBySourceChatId).toEqual({
      "agent:main:clawline:user_1:side": {
        entriesNewestFirst: [
          {
            assistantMessageId: "s_stream",
            contentPreview: "Hello",
            final: true,
            updatedAt: 102
          }
        ],
        lastAssistantActivityAt: 102,
        replyDraft: "",
        replyMode: false,
        sourceChatId: "agent:main:clawline:user_1:side",
        sourceTitle: "Side Thread"
      }
    });

    const freshStore = createCrossChatNotificationStore();
    expect(freshStore.getState().bubblesBySourceChatId).toEqual({});
  });

  it("dismisses unavailable source chats from visible and overflow state", () => {
    const store = createCrossChatNotificationStore();

    for (let index = 0; index < 12; index += 1) {
      const sourceChatId = `agent:main:clawline:user_1:side_${index}`;
      store.applyIncomingMessage({
        message: {
          type: "message",
          id: `s_${index}`,
          role: "assistant",
          content: `Reply ${index}`,
          timestamp: index,
          streaming: false,
          sessionKey: sourceChatId,
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "live",
        streams: [
          ...STREAMS,
          {
            ...STREAMS[1],
            displayName: `Side ${index}`,
            sessionKey: sourceChatId
          }
        ]
      });
    }

    store.dismissUnavailableNotifications([
      "agent:main:clawline:user_1:main",
      "agent:main:clawline:user_1:side_11"
    ]);

    expect(Object.keys(store.getState().bubblesBySourceChatId)).toEqual([
      "agent:main:clawline:user_1:side_11"
    ]);
  });
});
