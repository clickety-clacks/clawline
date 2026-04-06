import {
  createMemoryChatPersistence
} from "../persistence/indexedDbChatPersistence";
import { createChatDomainStore } from "./chatDomainStore";
import { phase1TranscriptFixture } from "../../test/fixtures/transcripts/phase1-transcript";

async function waitForHydration(store: ReturnType<typeof createChatDomainStore>) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (store.getState().hydrated) {
      return;
    }
    await new Promise((resolve) => window.setTimeout(resolve, 0));
  }
  throw new Error("Store did not hydrate");
}

describe("chatDomainStore", () => {
  it("reconciles optimistic send -> ack -> echoed user replacement", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.enqueueOptimisticMessage({
      attachments: [
        {
          type: "asset",
          assetId: "a_upload_1",
          metadata: {
            filename: "report.pdf",
            mimeType: "application/pdf",
            size: 7
          }
        }
      ],
      content: "Hello",
      deviceId: "browser-device-1",
      id: "c_1",
      sessionKey: "agent:main:clawline:user_1:main",
      timestamp: 100,
      wireAttachments: [
        {
          type: "asset",
          assetId: "a_upload_1"
        }
      ]
    });
    store.markMessageAcked("c_1");
    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_1",
          role: "user",
          content: "Hello",
          timestamp: 101,
          streaming: false,
          deviceId: "browser-device-1",
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: [
            {
              type: "asset",
              assetId: "a_upload_1"
            }
          ]
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "live"
      },
    );

    const messages =
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"];

    expect(messages).toHaveLength(1);
    expect(messages[0].id).toBe("s_1");
    expect(messages[0].delivery).toBe("server");
    expect(messages[0].attachments).toEqual([
      {
        type: "asset",
        assetId: "a_upload_1",
        metadata: {
          filename: "report.pdf",
          mimeType: "application/pdf",
          size: 7
        }
      }
    ]);
  });

  it("updates streaming assistant replies in place", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_stream",
          role: "assistant",
          content: "Hel",
          timestamp: 100,
          streaming: true,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "live"
      },
    );
    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_stream",
          role: "assistant",
          content: "Hello",
          timestamp: 101,
          streaming: false,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "live"
      },
    );

    const messages =
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"];

    expect(messages).toHaveLength(1);
    expect(messages[0].content).toBe("Hello");
    expect(messages[0].streaming).toBe(false);
  });

  it("applies stream and provisioning snapshots through the domain owner", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applySessionInfo({
      type: "session_info",
      sessionKeys: ["agent:main:clawline:user_1:main"]
    });
    store.applyStreamSnapshot([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);

    expect(store.getState().streams).toEqual([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);
    expect(store.getState().provisionedSessionKeys).toEqual([
      "agent:main:clawline:user_1:main"
    ]);
  });

  it("treats stream snapshots as authoritative and drops stale persisted rows", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence({
        ...phase1TranscriptFixture,
        streams: [
          ...phase1TranscriptFixture.streams,
          {
            sessionKey: "agent:main:clawline:user_1:old",
            displayName: "Old Thread",
            kind: "custom",
            orderIndex: 9,
            isBuiltIn: false,
            createdAt: 1704673000100,
            updatedAt: 1704673000100,
            adopted: true
          }
        ]
      })
    });
    await waitForHydration(store);

    store.applyStreamSnapshot([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);

    expect(store.getState().streams).toEqual([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);
  });

  it("treats snapshot display names as authoritative over persisted names for the same session", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence({
        ...phase1TranscriptFixture,
        streams: [
          {
            sessionKey: "agent:main:clawline:user_1:main",
            displayName: "Main",
            kind: "main",
            orderIndex: 0,
            isBuiltIn: true,
            createdAt: 10,
            updatedAt: 10,
            adopted: false
          }
        ]
      })
    });
    await waitForHydration(store);

    store.applyStreamSnapshot([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);

    expect(store.getState().streams).toEqual([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);
  });

  it("warns with snapshot display names while applying authoritative stream snapshots", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

    store.applyStreamSnapshot([
      {
        sessionKey: "agent:main:clawline:user_1:main",
        displayName: "Personal",
        kind: "main",
        orderIndex: 0,
        isBuiltIn: true,
        createdAt: 10,
        updatedAt: 11,
        adopted: false
      }
    ]);

    expect(warnSpy).toHaveBeenCalledWith("clawline applyStreamSnapshot displayNames", [
      {
        displayName: "Personal",
        sessionKey: "agent:main:clawline:user_1:main"
      }
    ]);
  });

  it("keeps transcript history when a stream is untracked or deleted locally", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });
    await waitForHydration(store);

    store.removeStream("agent:main:clawline:user_1:main");

    expect(store.getState().streams).toEqual([]);
    expect(
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toEqual(phase1TranscriptFixture.messagesBySessionKey["agent:main:clawline:user_1:main"]);
    expect(store.getState().provisionedSessionKeys).toEqual([]);
  });

  it("does not renumber surviving streams after a delete or untrack", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence({
        ...phase1TranscriptFixture,
        streams: [
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
            orderIndex: 3,
            isBuiltIn: false,
            createdAt: 11,
            updatedAt: 11,
            adopted: false
          }
        ]
      })
    });
    await waitForHydration(store);

    store.removeStream("agent:main:clawline:user_1:main");

    expect(store.getState().streams).toEqual([
      expect.objectContaining({
        sessionKey: "agent:main:clawline:user_1:side",
        orderIndex: 3
      })
    ]);
  });

  it("merges stream upserts without renumbering surviving rows", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });
    await waitForHydration(store);

    store.upsertStream({
      sessionKey: "agent:main:clawline:user_1:side",
      displayName: "Side Thread",
      kind: "custom",
      orderIndex: 3,
      isBuiltIn: false,
      createdAt: 1704673000000,
      updatedAt: 1704673000000,
      adopted: true
    });

    expect(store.getState().streams.map((stream) => stream.sessionKey)).toEqual([
      "agent:main:clawline:user_1:main",
      "agent:main:clawline:user_1:side"
    ]);
    expect(store.getState().streams[1]).toMatchObject({
      displayName: "Side Thread",
      adopted: true,
      orderIndex: 3
    });
  });

  it("hydrates snapshots without generating unread state or replay duplicates", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });
    await waitForHydration(store);

    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_101",
          role: "assistant",
          content: "Hi there",
          timestamp: 1704672000000,
          streaming: false,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "replay"
      },
    );

    expect(
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toHaveLength(2);
    expect(store.getState().unreadBySessionKey).toEqual({});
  });

  it("treats hydrate as gap fill and does not overwrite live replayed state", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });

    store.applyIncomingMessage(
      {
        localDeviceId: "browser-device-1",
        message: {
          type: "message",
          id: "s_live",
          role: "assistant",
          content: "fresh replayed copy",
          timestamp: 1704673000000,
          streaming: false,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        },
        selectedSessionKey: "agent:main:clawline:user_1:main",
        source: "replay"
      },
    );

    await waitForHydration(store);

    expect(
      store.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toEqual([
      expect.objectContaining({
        id: "s_live",
        content: "fresh replayed copy"
      })
    ]);
  });

  it("marks non-active live assistant messages unread and clears them on selection", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_1",
        role: "assistant",
        content: "Side reply",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    });
    store.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_2",
        role: "assistant",
        content: "Another side reply",
        timestamp: 102,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    });

    expect(store.getState().unreadBySessionKey).toEqual({
      "agent:main:clawline:user_1:side": 2
    });
    expect(store.getState().firstUnreadMessageIdBySessionKey).toEqual({
      "agent:main:clawline:user_1:side": "s_side_1"
    });

    store.markSessionRead("agent:main:clawline:user_1:side");

    expect(store.getState().unreadBySessionKey).toEqual({});
    expect(store.getState().firstUnreadMessageIdBySessionKey).toEqual({});
    expect(
      store.getState().replayCursorsBySessionKey["agent:main:clawline:user_1:side"]
    ).toEqual({
      lastServerEventId: "s_side_2",
      lastReadMessageId: "s_side_2"
    });
  });

  it("does not rewrite replay cursors when a session is already read at the tail", () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_main_1",
        role: "assistant",
        content: "Main",
        timestamp: 100,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    });
    store.markSessionRead("agent:main:clawline:user_1:main");

    const firstCursor =
      store.getState().replayCursorsBySessionKey["agent:main:clawline:user_1:main"];

    store.markSessionRead("agent:main:clawline:user_1:main");

    expect(
      store.getState().replayCursorsBySessionKey["agent:main:clawline:user_1:main"]
    ).toBe(firstCursor);
  });

  it("tracks per-stream replay cursors independently and preserves them across hydrate", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_main_1",
        role: "assistant",
        content: "Main",
        timestamp: 100,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "replay"
    });
    store.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_1",
        role: "assistant",
        content: "Side",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "replay"
    });

    expect(store.getState().replayCursorsBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": {
        lastReadMessageId: null,
        lastServerEventId: "s_main_1"
      },
      "agent:main:clawline:user_1:side": {
        lastReadMessageId: null,
        lastServerEventId: "s_side_1"
      }
    });

    const rehydratedStore = createChatDomainStore({
      persistence: createMemoryChatPersistence(store.getState())
    });
    await waitForHydration(rehydratedStore);

    expect(rehydratedStore.getState().replayCursorsBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": {
        lastReadMessageId: null,
        lastServerEventId: "s_main_1"
      },
      "agent:main:clawline:user_1:side": {
        lastReadMessageId: null,
        lastServerEventId: "s_side_1"
      }
    });
  });

  it("persists per-session scroll state across hydrate", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });

    store.rememberSessionScrollState({
      offsetTop: 640.4,
      sessionKey: "agent:main:clawline:user_1:main",
      stickToBottom: false
    });
    store.rememberSessionScrollState({
      offsetTop: 0,
      sessionKey: "agent:main:clawline:user_1:side",
      stickToBottom: true
    });

    expect(store.getState().scrollStateBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": {
        offsetTop: 640,
        stickToBottom: false
      },
      "agent:main:clawline:user_1:side": {
        offsetTop: 0,
        stickToBottom: true
      }
    });

    const rehydratedStore = createChatDomainStore({
      persistence: createMemoryChatPersistence(store.getState())
    });
    await waitForHydration(rehydratedStore);

    expect(rehydratedStore.getState().scrollStateBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": {
        offsetTop: 640,
        stickToBottom: false
      },
      "agent:main:clawline:user_1:side": {
        offsetTop: 0,
        stickToBottom: true
      }
    });
  });

  it("drops persisted/local transcript state on authoritative replay reset", async () => {
    const store = createChatDomainStore({
      persistence: createMemoryChatPersistence({
        ...phase1TranscriptFixture,
        pendingMessages: {
          c_pending: {
            attachments: [],
            content: "stale pending",
            createdAt: 1704672000100,
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
        unreadBySessionKey: {
          "agent:main:clawline:user_1:side": 1
        }
      })
    });
    await waitForHydration(store);

    store.resetForAuthoritativeReplay();

    expect(store.getState()).toMatchObject({
      hydrated: true,
      lastServerEventId: null,
      messagesBySessionKey: {},
      pendingMessages: {},
      provisionedSessionKeys: [],
      replayCursorsBySessionKey: {},
      streams: [],
      unreadBySessionKey: {}
    });
  });
});
