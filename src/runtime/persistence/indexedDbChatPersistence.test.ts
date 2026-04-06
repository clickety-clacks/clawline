import { createIndexedDbChatPersistence } from "./indexedDbChatPersistence";
import { phase1TranscriptFixture } from "../../test/fixtures/transcripts/phase1-transcript";

describe("indexedDbChatPersistence", () => {
  it("isolates snapshots by tab runtime scope", async () => {
    const persistenceA = createIndexedDbChatPersistence("tab-a");
    const persistenceB = createIndexedDbChatPersistence("tab-b");

    await persistenceA.save({
      ...phase1TranscriptFixture,
      pendingMessages: {
        c_a: {
          attachments: [],
          content: "hello from tab a",
          createdAt: 111,
          sessionKey: "agent:main:clawline:user_1:main",
          wireAttachments: []
        }
      },
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:main": {
          lastReadMessageId: "s_101",
          lastServerEventId: "s_101"
        }
      },
      scrollStateBySessionKey: {
        "agent:main:clawline:user_1:main": {
          offsetTop: 420,
          stickToBottom: false
        }
      },
      unreadBySessionKey: {
        "agent:main:clawline:user_1:side": 2
      }
    });
    await persistenceB.save({
      ...phase1TranscriptFixture,
      pendingMessages: {
        c_b: {
          attachments: [],
          content: "hello from tab b",
          createdAt: 222,
          sessionKey: "agent:main:clawline:user_1:side",
          wireAttachments: []
        }
      },
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:side": {
          lastReadMessageId: "s_side_1",
          lastServerEventId: "s_side_1"
        }
      },
      scrollStateBySessionKey: {
        "agent:main:clawline:user_1:side": {
          offsetTop: 640,
          stickToBottom: true
        }
      },
      unreadBySessionKey: {}
    });

    expect(await persistenceA.load()).toMatchObject({
      pendingMessages: {
        c_a: {
          content: "hello from tab a"
        }
      },
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:main": {
          lastServerEventId: "s_101"
        }
      },
      scrollStateBySessionKey: {
        "agent:main:clawline:user_1:main": {
          offsetTop: 420,
          stickToBottom: false
        }
      },
      unreadBySessionKey: {
        "agent:main:clawline:user_1:side": 2
      }
    });
    expect(await persistenceB.load()).toMatchObject({
      pendingMessages: {
        c_b: {
          content: "hello from tab b"
        }
      },
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:side": {
          lastServerEventId: "s_side_1"
        }
      },
      scrollStateBySessionKey: {
        "agent:main:clawline:user_1:side": {
          offsetTop: 640,
          stickToBottom: true
        }
      },
      unreadBySessionKey: {}
    });
  });
});
