import type { ChatDomainSnapshot } from "../../../runtime/chat/chatDomainStore";

export const phase1TranscriptFixture: ChatDomainSnapshot = {
  firstUnreadMessageIdBySessionKey: {},
  hydrated: true,
  lastServerEventId: "s_101",
  messagesBySessionKey: {
    "agent:main:clawline:user_1:main": [
      {
        id: "s_100",
        role: "user",
        content: "Hello",
        timestamp: 1704671000000,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: [],
        delivery: "server"
      },
      {
        id: "s_101",
        role: "assistant",
        content: "Hi there",
        timestamp: 1704672000000,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: [],
        delivery: "server"
      }
    ]
  },
  pendingMessages: {},
  provisionedSessionKeys: ["agent:main:clawline:user_1:main"],
  replayCursorsBySessionKey: {},
  scrollStateBySessionKey: {},
  streamReadStateBySessionKey: {},
  streamTailStateBySessionKey: {},
  streams: [
    {
      sessionKey: "agent:main:clawline:user_1:main",
      displayName: "Personal",
      kind: "main",
      orderIndex: 0,
      isBuiltIn: true,
      createdAt: 1704671000000,
      updatedAt: 1704672000000,
      adopted: false
    }
  ],
  unreadBySessionKey: {}
};
