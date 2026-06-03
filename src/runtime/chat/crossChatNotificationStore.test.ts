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

  it("marks newly appended notification entries with one separator timestamp", () => {
    const store = createCrossChatNotificationStore();

    store.applyIncomingMessage({
      message: {
        type: "message",
        id: "s_first",
        role: "assistant",
        content: "First",
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
        id: "s_second",
        role: "assistant",
        content: "Second",
        timestamp: 200,
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
        id: "s_second",
        role: "assistant",
        content: "Second final",
        timestamp: 250,
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
        id: "s_third",
        role: "assistant",
        content: "Third",
        timestamp: 300,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live",
      streams: STREAMS
    });

    expect(
      store.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]?.entriesNewestFirst
    ).toEqual([
      expect.objectContaining({
        appendSeparatorTimestamp: 300,
        assistantMessageId: "s_third"
      }),
      expect.objectContaining({
        appendSeparatorTimestamp: 200,
        assistantMessageId: "s_second",
        contentPreview: "Second final"
      }),
      expect.objectContaining({
        appendSeparatorTimestamp: undefined,
        assistantMessageId: "s_first"
      })
    ]);
  });

  it("does not recreate a dismissed notification from a later live update for the same assistant message", () => {
    const store = createCrossChatNotificationStore();

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

    store.dismissCrossChatNotification("agent:main:clawline:user_1:side");
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

    expect(store.getState().bubblesBySourceChatId).toEqual({});

    store.applyIncomingMessage({
      message: {
        type: "message",
        id: "s_next",
        role: "assistant",
        content: "Next reply",
        timestamp: 103,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live",
      streams: STREAMS
    });

    expect(
      store.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]?.entriesNewestFirst
    ).toEqual([
      expect.objectContaining({
        assistantMessageId: "s_next",
        contentPreview: "Next reply"
      })
    ]);
  });

  it("does not recreate cleared notifications from later live updates for the same assistant messages", () => {
    const store = createCrossChatNotificationStore();

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
    store.clearCrossChatNotifications();
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

    expect(store.getState().bubblesBySourceChatId).toEqual({});
  });

  it("does not append a late update for a dismissed assistant message into a newer source bubble", () => {
    const store = createCrossChatNotificationStore();

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
    store.dismissCrossChatNotification("agent:main:clawline:user_1:side");
    store.applyIncomingMessage({
      message: {
        type: "message",
        id: "s_next",
        role: "assistant",
        content: "Next reply",
        timestamp: 102,
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
        content: "Late final",
        timestamp: 103,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live",
      streams: STREAMS
    });

    expect(
      store.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]?.entriesNewestFirst
    ).toEqual([
      expect.objectContaining({
        assistantMessageId: "s_next",
        contentPreview: "Next reply"
      })
    ]);
  });

  it("clears dismissed notification memory on reset", () => {
    const store = createCrossChatNotificationStore();

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
    store.dismissCrossChatNotification("agent:main:clawline:user_1:side");
    store.reset();
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

    expect(
      store.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]?.entriesNewestFirst
    ).toEqual([
      expect.objectContaining({
        assistantMessageId: "s_stream",
        contentPreview: "Hello"
      })
    ]);
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
