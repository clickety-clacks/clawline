import { createAuthSessionStore } from "../auth/authSessionStore";
import { createChatDomainStore } from "../chat/chatDomainStore";
import { createMemoryChatPersistence } from "../persistence/indexedDbChatPersistence";
import { createTransportMachine } from "./transportMachine";
import { FakeWebSocketFactory } from "../../test/support/fakeWebSocket";
import { phase1TranscriptFixture } from "../../test/fixtures/transcripts/phase1-transcript";

class FakeBrowserRuntime {
  isCurrentlyOnline = true;
  listeners = {
    offline: new Set<() => void>(),
    online: new Set<() => void>()
  };
  nextTimeoutId = 1;
  pendingTimeouts = new Map<number, () => void>();

  addEventListener(type: "offline" | "online", listener: () => void) {
    this.listeners[type].add(listener);
    return () => {
      this.listeners[type].delete(listener);
    };
  }

  clearTimeout(timeoutId: number) {
    this.pendingTimeouts.delete(timeoutId);
  }

  emit(type: "offline" | "online") {
    if (type === "offline") {
      this.isCurrentlyOnline = false;
    } else {
      this.isCurrentlyOnline = true;
    }

    for (const listener of this.listeners[type]) {
      listener();
    }
  }

  isOnline() {
    return this.isCurrentlyOnline;
  }

  setTimeout(listener: () => void) {
    const timeoutId = this.nextTimeoutId;
    this.nextTimeoutId += 1;
    this.pendingTimeouts.set(timeoutId, listener);
    return timeoutId;
  }

  runNextTimeout() {
    const next = this.pendingTimeouts.entries().next();
    if (next.done) {
      return false;
    }

    const [timeoutId, listener] = next.value;
    this.pendingTimeouts.delete(timeoutId);
    listener();
    return true;
  }

  runAllTimeouts() {
    while (this.runNextTimeout()) {
      continue;
    }
  }
}

function seedSession() {
  const authStore = createAuthSessionStore();
  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });
  return authStore;
}

async function waitForSocket(factory: FakeWebSocketFactory, count = 1) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (factory.sockets.length >= count) {
      return;
    }
    await Promise.resolve();
  }

  throw new Error(`Expected ${count} socket(s), found ${factory.sockets.length}`);
}

async function waitForHydration(store: ReturnType<typeof createChatDomainStore>) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (store.getState().hydrated) {
      return;
    }
    await Promise.resolve();
  }

  throw new Error("Store did not hydrate");
}

describe("transportMachine", () => {
  afterEach(() => {
    window.history.replaceState({}, "", "/");
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("transitions idle -> connecting -> authenticating -> live on auth success", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      clientFeatures: ["terminal_bubbles_v1"],
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);

    expect(transport.getState().phase).toBe("connecting");
    expect(factory.sockets).toHaveLength(1);

    factory.sockets[0].emitOpen();
    expect(transport.getState().phase).toBe("authenticating");
    expect(JSON.parse(factory.sockets[0].sentTexts[0]).type).toBe("auth");

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transport.getState().phase).toBe("live");
    expect(chatStore.getState().streams[0]?.sessionKey).toBe(
      "agent:main:clawline:user_1:main"
    );
    expect(chatStore.getState().provisionedSessionKeys).toEqual([
      "agent:main:clawline:user_1:main"
    ]);
    expect(JSON.parse(factory.sockets[0].sentTexts[0])).toMatchObject({
      type: "auth",
      clientFeatures: ["terminal_bubbles_v1"],
      client: {
        id: "clawline-web",
        features: ["terminal_bubbles_v1"]
      }
    });
  });

  it("does not advertise terminal bubble support when WebSocket is unavailable", async () => {
    vi.stubGlobal("WebSocket", undefined);

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();

    expect(JSON.parse(factory.sockets[0].sentTexts[0])).toMatchObject({
      type: "auth",
      clientFeatures: [],
      client: {
        id: "clawline-web",
        features: []
      }
    });
  });

  it("uses the URL-selected session when classifying incoming unread state", async () => {
    window.history.replaceState({}, "", "/chat/agent:main:clawline:user_1:side");

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        sessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:clawline:user_1:side"
        ]
      })
    );

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_side_101",
        role: "assistant",
        content: "Side message",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      })
    );

    expect(
      chatStore.getState().unreadBySessionKey["agent:main:clawline:user_1:side"]
    ).toBeUndefined();
  });

  it("re-reads URL-selected session for each incoming message", async () => {
    window.history.replaceState({}, "", "/chat/agent:main:clawline:user_1:side");

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        sessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:clawline:user_1:side"
        ]
      })
    );

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_side_102",
        role: "assistant",
        content: "Side message",
        timestamp: 102,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      })
    );

    expect(
      chatStore.getState().unreadBySessionKey["agent:main:clawline:user_1:side"]
    ).toBeUndefined();

    window.history.replaceState({}, "", "/chat/agent:main:clawline:user_1:main");
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_side_103",
        role: "assistant",
        content: "Side message after switch",
        timestamp: 103,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      })
    );

    expect(chatStore.getState().unreadBySessionKey["agent:main:clawline:user_1:side"]).toBe(1);
  });

  it("does not treat a missing URL stream as the selected session", async () => {
    window.history.replaceState({}, "", "/chat/agent:main:clawline:user_1:missing");

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        sessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:clawline:user_1:side"
        ]
      })
    );

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_side_104",
        role: "assistant",
        content: "Side message for missing URL",
        timestamp: 104,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      })
    );

    expect(chatStore.getState().unreadBySessionKey["agent:main:clawline:user_1:side"]).toBe(1);
  });

  it("ignores stale hash-router fragments when the browser router owns the path", async () => {
    window.history.replaceState(
      {},
      "",
      "/chat/agent:main:clawline:user_1:main#/chat/agent:main:clawline:user_1:side"
    );

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        sessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:clawline:user_1:side"
        ]
      })
    );

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_side_hash_ignored",
        role: "assistant",
        content: "Side message while main path is active",
        timestamp: 105,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      })
    );

    expect(chatStore.getState().unreadBySessionKey["agent:main:clawline:user_1:side"]).toBe(1);
  });

  it("stays replaying until replay messages complete even after auth succeeds", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 1,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transport.getState().phase).toBe("replaying");

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_101",
        role: "assistant",
        content: "Replay complete",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      })
    );

    expect(transport.getState().phase).toBe("live");
  });

  it("chunks large replay bursts through browser timeouts before entering live", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const browserRuntime = new FakeBrowserRuntime();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      browserRuntime,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 30,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    for (let index = 0; index < 30; index += 1) {
      factory.sockets[0].emitMessage(
        JSON.stringify({
          type: "message",
          id: `s_${index}`,
          role: "assistant",
          content: `Replay ${index}`,
          timestamp: index,
          streaming: false,
          sessionKey: "agent:main:clawline:user_1:main",
          attachments: []
        })
      );
    }

    expect(chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"])
      .toBeUndefined();
    expect(transport.getState().phase).toBe("replaying");

    browserRuntime.runNextTimeout();

    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toHaveLength(24);
    expect(transport.getState().phase).toBe("replaying");

    browserRuntime.runAllTimeouts();

    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toHaveLength(30);
    expect(transport.getState().phase).toBe("live");
  });

  it("enters live on auth success even when session inventory arrives later", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 0
      })
    );

    expect(transport.getState().phase).toBe("live");

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "session_info",
        userId: "user_1",
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transport.getState().phase).toBe("live");
  });

  it("accepts native read-state and event frames without regressing the live connection", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 0
      })
    );

    expect(() =>
      factory.sockets[0].emitMessage(
        JSON.stringify({
          type: "stream_read_state",
          sessionKey: "agent:main:clawline:user_1:main",
          lastReadMessageId: "s_101"
        })
      )
    ).not.toThrow();
    expect(() =>
      factory.sockets[0].emitMessage(
        JSON.stringify({
          type: "stream_tail_state",
          sessionKey: "agent:main:clawline:user_1:main",
          lastMessageId: "s_102",
          lastMessageRole: "assistant"
        })
      )
    ).not.toThrow();
    expect(() =>
      factory.sockets[0].emitMessage(
        JSON.stringify({
          type: "event",
          event: "activity",
          payload: {
            sessionKey: "agent:main:clawline:user_1:main",
            isActive: true
          }
        })
      )
    ).not.toThrow();

    expect(transport.getState().phase).toBe("live");
    expect(chatStore.getState().streamReadStateBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": "s_101"
    });
    expect(chatStore.getState().streamTailStateBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": {
        lastMessageId: "s_102",
        lastMessageRole: "assistant"
      }
    });
  });

  it("hydrates authoritative read and tail snapshots from auth bootstrap", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        replayCount: 0,
        streamReadStates: {
          "agent:main:clawline:user_1:main": "s_101"
        },
        streamTailStates: {
          "agent:main:clawline:user_1:main": {
            lastMessageId: "s_102",
            lastMessageRole: "assistant"
          }
        }
      })
    );

    expect(chatStore.getState().streamReadStateBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": "s_101"
    });
    expect(chatStore.getState().streamTailStateBySessionKey).toEqual({
      "agent:main:clawline:user_1:main": {
        lastMessageId: "s_102",
        lastMessageRole: "assistant"
      }
    });
  });

  it("publishes stream_read frames for visited sessions with server tails", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        replayCount: 0
      })
    );

    await transport.publishReadState("agent:main:clawline:user_1:main", "s_101");

    expect(
      factory.sockets[0].sentTexts.map((entry) => JSON.parse(entry))
    ).toContainEqual({
      type: "stream_read",
      sessionKey: "agent:main:clawline:user_1:main",
      lastReadMessageId: "s_101"
    });
  });

  it("drops stale local transcript state when auth reports history reset", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence({
        ...phase1TranscriptFixture,
        pendingMessages: {
          c_stale: {
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
        }
      })
    });
    await waitForHydration(chatStore);
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 1,
        historyReset: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(chatStore.getState()).toMatchObject({
      messagesBySessionKey: {},
      pendingMessages: {},
      replayCursorsBySessionKey: {},
      streams: [
        expect.objectContaining({
          sessionKey: "agent:main:clawline:user_1:main"
        })
      ]
    });
    expect(transport.getState().phase).toBe("replaying");

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "message",
        id: "s_fresh",
        role: "assistant",
        content: "fresh replay",
        timestamp: 200,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      })
    );

    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toEqual([
      expect.objectContaining({
        id: "s_fresh",
        content: "fresh replay"
      })
    ]);
    expect(transport.getState().phase).toBe("live");
  });

  it("drops stale local transcript state when auth reports replay truncation", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });
    await waitForHydration(chatStore);
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        userId: "user_1",
        replayCount: 0,
        replayTruncated: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(chatStore.getState()).toMatchObject({
      lastServerEventId: null,
      messagesBySessionKey: {},
      replayCursorsBySessionKey: {},
      streams: [
        expect.objectContaining({
          sessionKey: "agent:main:clawline:user_1:main"
        })
      ]
    });
  });

  it("sends persisted per-stream replay cursors on auth bootstrap", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    chatStore.applyIncomingMessage({
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
    chatStore.applyIncomingMessage({
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
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      selectedSessionKeySource: () => "agent:main:clawline:user_1:main",
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();

    expect(JSON.parse(factory.sockets[0].sentTexts[0])).toMatchObject({
      type: "auth",
      lastMessageId: "s_main_1",
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:main": "s_main_1",
        "agent:main:clawline:user_1:side": "s_side_1"
      }
    });
  });

  it("does not send a global legacy replay cursor for streams without their own cursor", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    chatStore.applyIncomingMessage({
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
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      selectedSessionKeySource: () => "agent:main:clawline:user_1:side",
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();

    const payload = JSON.parse(factory.sockets[0].sentTexts[0]);
    expect(payload).toMatchObject({
      type: "auth",
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:main": "s_main_1"
      }
    });
    expect(payload.lastMessageId).toBeNull();
  });

  it("starts re-pair auth from an empty replay context after in-session logout", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    chatStore.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_before_logout",
        role: "assistant",
        content: "Before logout",
        timestamp: 100,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    expect(JSON.parse(factory.sockets[0].sentTexts[0])).toMatchObject({
      lastMessageId: null,
      replayCursorsBySessionKey: {
        "agent:main:clawline:user_1:main": "s_before_logout"
      }
    });

    authStore.logout();
    chatStore.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_late_stale_cursor",
        role: "assistant",
        content: "Late stale cursor",
        timestamp: 101,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:main",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    });

    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token-2",
      userId: "user_1"
    });

    await waitForSocket(factory, 2);
    factory.sockets[1].emitOpen();
    const reauthPayload = JSON.parse(factory.sockets[1].sentTexts[0]);
    expect(reauthPayload).toMatchObject({
      type: "auth",
      token: "jwt-token-2"
    });
    expect(reauthPayload.lastMessageId).toBeNull();
    expect(reauthPayload.replayCursorsBySessionKey).toBeUndefined();
  });

  it("does not let delayed hydrate restore stale replay cursors after logout re-pair", async () => {
    const authStore = seedSession();
    let resolveLoad: ((snapshot: typeof phase1TranscriptFixture | null) => void) | null =
      null;
    const chatStore = createChatDomainStore({
      persistence: {
        clear: async () => undefined,
        load: () =>
          new Promise((resolve) => {
            resolveLoad = resolve;
          }),
        save: async () => undefined
      }
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    expect(factory.sockets).toHaveLength(0);
    expect(chatStore.getState().hydrated).toBe(false);

    authStore.logout();
    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token-2",
      userId: "user_1"
    });

    await waitForSocket(factory);
    const hydrateResolver = resolveLoad;
    if (!hydrateResolver) {
      throw new Error("Expected hydrate resolver to be captured");
    }
    (
      hydrateResolver as (snapshot: typeof phase1TranscriptFixture | null) => void
    )(phase1TranscriptFixture);
    await Promise.resolve();
    await Promise.resolve();

    factory.sockets[0].emitOpen();
    const reauthPayload = JSON.parse(factory.sockets[0].sentTexts[0]);
    expect(reauthPayload.lastMessageId).toBeNull();
    expect(reauthPayload.replayCursorsBySessionKey).toBeUndefined();
  });

  it("starts cold fresh pairing from an empty replay context when stale chat persists", async () => {
    const authStore = createAuthSessionStore();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence(phase1TranscriptFixture)
    });
    await waitForHydration(chatStore);
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    expect(factory.sockets).toHaveLength(0);
    expect(chatStore.getState().lastServerEventId).toBe("s_101");

    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token",
      userId: "user_1"
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    const authPayload = JSON.parse(factory.sockets[0].sentTexts[0]);
    expect(authPayload.lastMessageId).toBeNull();
    expect(authPayload.replayCursorsBySessionKey).toBeUndefined();
  });

  it("applies incremental stream mutation events through the transport owner", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "stream_created",
        stream: {
          sessionKey: "agent:main:clawline:user_1:custom",
          displayName: "Custom",
          kind: "custom",
          orderIndex: 2,
          isBuiltIn: false,
          createdAt: 10,
          updatedAt: 10,
          adopted: false
        }
      })
    );

    expect(chatStore.getState().streams.map((stream) => stream.sessionKey)).toEqual([
      "agent:main:clawline:user_1:main",
      "agent:main:clawline:user_1:custom"
    ]);

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "stream_deleted",
        sessionKey: "agent:main:clawline:user_1:custom"
      })
    );

    expect(chatStore.getState().streams.map((stream) => stream.sessionKey)).toEqual([
      "agent:main:clawline:user_1:main"
    ]);
  });

  it("treats stream snapshots as authoritative across restored sessions", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
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
            createdAt: 10,
            updatedAt: 10,
            adopted: true
          }
        ]
      })
    });
    await waitForHydration(chatStore);
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "stream_snapshot",
        streams: [
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
        ]
      })
    );

    expect(chatStore.getState().streams).toEqual([
      expect.objectContaining({
        sessionKey: "agent:main:clawline:user_1:main"
      })
    ]);
  });

  it("suppresses duplicate reconnect intents while already live", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    transport.retryNow();
    transport.retryNow();

    expect(factory.sockets).toHaveLength(1);
    expect(transport.getState().phase).toBe("live");
  });

  it("warns with the raw stream snapshot payload outside production", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    const streams = [
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
    ];

    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "stream_snapshot",
        streams
      })
    );

    expect(warnSpy).toHaveBeenCalledWith("clawline stream_snapshot", streams);
  });

  it("serializes attachment payloads through the live socket send path", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    await transport.sendMessage({
      attachments: [
        {
          type: "image",
          mimeType: "image/png",
          data: "aW1hZ2U="
        },
        {
          type: "asset",
          assetId: "a_upload_1"
        }
      ],
      content: "hello",
      id: "c_101",
      sessionKey: "agent:main:clawline:user_1:main"
    });

    expect(JSON.parse(factory.sockets[0].sentTexts.at(-1) ?? "{}")).toEqual({
      type: "message",
      id: "c_101",
      content: "hello",
      attachments: [
        {
          type: "image",
          mimeType: "image/png",
          data: "aW1hZ2U="
        },
        {
          type: "asset",
          assetId: "a_upload_1"
        }
      ],
      sessionKey: "agent:main:clawline:user_1:main"
    });
  });

  it("serializes interactive callbacks through the live socket send path", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    await transport.sendInteractiveCallback({
      messageId: "s_html_101",
      action: "ping",
      data: {
        count: 7
      }
    });

    expect(JSON.parse(factory.sockets[0].sentTexts.at(-1) ?? "{}")).toEqual({
      type: "interactive-callback",
      messageId: "s_html_101",
      payload: {
        action: "ping",
        data: {
          count: 7
        }
      }
    });
  });

  it("transitions to failed and clears auth on auth failure", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: false,
        reason: "auth_failed"
      })
    );

    expect(transport.getState().phase).toBe("failed");
    expect(authStore.getState().session).toBeNull();
  });

  it("allows manual retry out of recovery", async () => {
    vi.useFakeTimers();

    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );
    factory.sockets[0].emitClose();

    expect(transport.getState().phase).toBe("recovering");

    transport.retryNow();
    expect(factory.sockets).toHaveLength(2);
  });

  it("keeps tab transport independent across two runtimes", async () => {
    const authStoreA = seedSession();
    const authStoreB = seedSession();
    const chatStoreA = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const chatStoreB = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factoryA = new FakeWebSocketFactory();
    const factoryB = new FakeWebSocketFactory();

    const transportA = createTransportMachine({
      authSessionStore: authStoreA,
      chatDomainStore: chatStoreA,
      webSocketFactory: factoryA.create
    });
    const transportB = createTransportMachine({
      authSessionStore: authStoreB,
      chatDomainStore: chatStoreB,
      webSocketFactory: factoryB.create
    });

    await waitForSocket(factoryA);
    await waitForSocket(factoryB);
    factoryA.sockets[0].emitOpen();
    factoryB.sockets[0].emitOpen();
    factoryA.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );
    factoryB.sockets[0].emitMessage(
      JSON.stringify({
        type: "auth_result",
        success: true,
        sessionKeys: ["agent:main:clawline:user_1:main"]
      })
    );

    expect(transportA.getState().phase).toBe("live");
    expect(transportB.getState().phase).toBe("live");
    expect(factoryA.sockets).toHaveLength(1);
    expect(factoryB.sockets).toHaveLength(1);
  });

  it("waits for the browser to come back online before reconnecting", async () => {
    const authStore = seedSession();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const factory = new FakeWebSocketFactory();
    const browserRuntime = new FakeBrowserRuntime();
    const transport = createTransportMachine({
      authSessionStore: authStore,
      browserRuntime,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    await waitForSocket(factory);
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({ type: "auth_result", success: true })
    );

    browserRuntime.emit("offline");

    expect(transport.getState()).toMatchObject({
      failureReason: "Browser offline",
      isBrowserOnline: false,
      phase: "recovering"
    });
    expect(factory.sockets).toHaveLength(1);

    browserRuntime.emit("online");

    expect(transport.getState().isBrowserOnline).toBe(true);
    expect(factory.sockets).toHaveLength(2);
  });

  it("waits for persisted hydration before auth bootstrap on restored sessions", async () => {
    const authStore = seedSession();
    let resolveLoad: ((snapshot: typeof phase1TranscriptFixture | null) => void) | null =
      null;
    const chatStore = createChatDomainStore({
      persistence: {
        clear: async () => undefined,
        load: () =>
          new Promise((resolve) => {
            resolveLoad = resolve;
          }),
        save: async () => undefined
      }
    });
    const factory = new FakeWebSocketFactory();
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: factory.create
    });

    expect(factory.sockets).toHaveLength(0);
    expect(chatStore.getState().hydrated).toBe(false);

    const hydrateResolver = resolveLoad;
    if (!hydrateResolver) {
      throw new Error("Expected hydrate resolver to be captured");
    }

    (
      hydrateResolver as (snapshot: typeof phase1TranscriptFixture | null) => void
    )(phase1TranscriptFixture);
    await Promise.resolve();
    await Promise.resolve();

    expect(chatStore.getState().hydrated).toBe(true);
    expect(factory.sockets).toHaveLength(1);

    factory.sockets[0].emitOpen();
    expect(JSON.parse(factory.sockets[0].sentTexts[0])).toMatchObject({
      lastMessageId: null
    });
  });
});
