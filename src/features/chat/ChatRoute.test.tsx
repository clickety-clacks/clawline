import { readFileSync } from "node:fs";
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ChatRoute } from "./ChatRoute";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore
} from "../../runtime/auth/authSessionStore";
import {
  ChatDomainStoreProvider,
  createChatDomainStore
} from "../../runtime/chat/chatDomainStore";
import {
  CrossChatNotificationStoreProvider,
  createCrossChatNotificationStore
} from "../../runtime/chat/crossChatNotificationStore";
import { createMemoryChatPersistence } from "../../runtime/persistence/indexedDbChatPersistence";
import {
  SettingsStoreProvider,
  createSettingsStore
} from "../../runtime/settings/settingsStore";
import {
  TransportMachineProvider,
  createTransportMachine,
  type TransportMachine
} from "../../runtime/transport/transportMachine";
import { FakeWebSocketFactory } from "../../test/support/fakeWebSocket";

const TEST_STREAMS = [
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
    sessionKey: "agent:main:main",
    displayName: "Heimdal",
    kind: "global_dm",
    orderIndex: 1,
    isBuiltIn: true,
    createdAt: 10,
    updatedAt: 10,
    adopted: true
  },
  {
    sessionKey: "agent:main:clawline:user_1:side",
    displayName: "Side Thread",
    kind: "custom",
    orderIndex: 2,
    isBuiltIn: false,
    createdAt: 11,
    updatedAt: 11,
    adopted: false
  }
] as const;

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location">{location.pathname}</div>;
}

function renderChatRoute(
  initialPath: string,
  {
    initialMessages = [
      {
        content: "Main thread",
        id: "s_main",
        selectedSessionKey: "agent:main:clawline:user_1:main",
        sessionKey: "agent:main:clawline:user_1:main",
        timestamp: 10
      },
      {
        content: "Side thread",
        id: "s_side",
        selectedSessionKey: "agent:main:clawline:user_1:main",
        sessionKey: "agent:main:clawline:user_1:side",
        timestamp: 11
      }
    ],
    sessionKeys = ["agent:main:clawline:user_1:main", "agent:main:main"],
    streamReadStates,
    streamTailStates,
    configureTransportMachine
  }: {
    initialMessages?: Array<{
      content: string;
      id: string;
      selectedSessionKey: string;
      sessionKey: string;
      timestamp: number;
    }>;
    sessionKeys?: string[];
    streamReadStates?: Record<string, string>;
    streamTailStates?: Record<
      string,
      {
        lastMessageId: string;
        lastMessageRole: "user" | "assistant";
      }
    >;
    configureTransportMachine?: (input: {
      chatStore: ReturnType<typeof createChatDomainStore>;
      notificationStore: ReturnType<typeof createCrossChatNotificationStore>;
      transportMachine: TransportMachine;
    }) => void;
  } = {}
) {
  const authStore = createAuthSessionStore();
  const chatStore = createChatDomainStore({
    persistence: createMemoryChatPersistence()
  });
  const notificationStore = createCrossChatNotificationStore();
  const settingsStore = createSettingsStore();
  const webSocketFactory = new FakeWebSocketFactory();

  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });

  chatStore.applyStreamSnapshot(TEST_STREAMS.map((stream) => ({ ...stream })));
  chatStore.applySessionInfo({
    type: "session_info",
    sessionKeys
  });
  for (const message of initialMessages) {
    chatStore.applyIncomingMessage({
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: message.id,
        role: "assistant",
        content: message.content,
        timestamp: message.timestamp,
        streaming: false,
        sessionKey: message.sessionKey,
        attachments: []
      },
      selectedSessionKey: message.selectedSessionKey,
      source: "live"
    });
  }

  const transportMachine = createTransportMachine({
    authSessionStore: authStore,
    chatDomainStore: chatStore,
    crossChatNotificationStore: notificationStore,
    webSocketFactory: webSocketFactory.create
  });
  webSocketFactory.sockets[0]?.emitOpen();
  webSocketFactory.sockets[0]?.emitMessage(
    JSON.stringify({
      type: "auth_result",
      success: true,
      sessionKeys,
      streamReadStates,
      streamTailStates
    })
  );
  configureTransportMachine?.({
    chatStore,
    notificationStore,
    transportMachine
  });

  const view = render(
    <SettingsStoreProvider value={settingsStore}>
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <CrossChatNotificationStoreProvider value={notificationStore}>
            <TransportMachineProvider value={transportMachine}>
              <MemoryRouter initialEntries={[initialPath]}>
                <Routes>
                  <Route
                    element={
                      <>
                        <ChatRoute />
                        <LocationProbe />
                      </>
                    }
                    path="/chat/:sessionKey?"
                  />
                </Routes>
              </MemoryRouter>
            </TransportMachineProvider>
          </CrossChatNotificationStoreProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    </SettingsStoreProvider>
  );

  return {
    ...view,
    chatStore,
    notificationStore,
    transportMachine,
    webSocketFactory
  };
}

function applyAssistantNotification(
  input: ReturnType<typeof renderChatRoute>,
  {
    content = "Side notification",
    id = "s_side_notify",
    selectedSessionKey = "agent:main:clawline:user_1:main",
    sessionKey = "agent:main:clawline:user_1:side",
    timestamp = 21,
    streams = TEST_STREAMS.map((stream) => ({ ...stream }))
  }: {
    content?: string;
    id?: string;
    selectedSessionKey?: string;
    sessionKey?: string;
    timestamp?: number;
    streams?: Array<{
      sessionKey: string;
      displayName: string;
      kind: string;
      orderIndex: number;
      isBuiltIn: boolean;
      createdAt: number;
      updatedAt: number;
      adopted: boolean;
    }>;
  } = {}
) {
  const message = {
    type: "message" as const,
    id,
    role: "assistant" as const,
    content,
    timestamp,
    streaming: false,
    sessionKey,
    attachments: []
  };
  input.chatStore.applyIncomingMessage({
    localDeviceId: "browser-device-1",
    message,
    selectedSessionKey,
    source: "live"
  });
  input.notificationStore.applyIncomingMessage({
    message,
    selectedSessionKey,
    source: "live",
    streams
  });
}

describe("ChatRoute", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = input instanceof URL ? input : new URL(String(input));

        if (url.pathname === "/api/streams") {
          return new Response(JSON.stringify({ streams: TEST_STREAMS }), {
            headers: { "Content-Type": "application/json" },
            status: 200
          });
        }

        if (url.pathname === "/api/trackable-sessions") {
          return new Response(JSON.stringify({ sessions: [] }), {
            headers: { "Content-Type": "application/json" },
            status: 200
          });
        }

        if (url.pathname.startsWith("/api/streams/")) {
          return new Response(
            JSON.stringify({ deletedSessionKey: decodeURIComponent(url.pathname.slice("/api/streams/".length)) }),
            {
              headers: { "Content-Type": "application/json" },
              status: 200
            }
          );
        }

        return new Response(JSON.stringify({ error: { code: "unexpected_path" } }), {
          headers: { "Content-Type": "application/json" },
          status: 404
        });
      })
    );
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("keeps the URL-selected session active when provider inventory still exposes it", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side", {
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });

    expect(screen.getByText("Side thread")).toBeInTheDocument();
    expect(screen.queryByText("Main thread")).not.toBeInTheDocument();
  });

  it("reconciles a boot-selected stream back to provider-visible inventory when the stream is missing", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:missing");

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
    expect(screen.getByText("Main thread")).toBeInTheDocument();
  });

  it("renders an unprovisioned URL-selected stream without provider read publish", () => {
    const publishedReadSessionKeys: string[] = [];

    renderChatRoute("/chat/agent:main:clawline:user_1:side", {
      sessionKeys: [],
      configureTransportMachine({ transportMachine }) {
        const publishReadState = transportMachine.publishReadState.bind(transportMachine);
        vi.spyOn(transportMachine, "publishReadState").mockImplementation(
          async (sessionKey, lastReadMessageId) => {
            publishedReadSessionKeys.push(sessionKey);
            await publishReadState(sessionKey, lastReadMessageId);
          }
        );
      }
    });

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:side"
    );
    expect(screen.getByText("Side thread")).toBeInTheDocument();
    expect(
      screen.getByText("This session is unavailable for sending. Switch streams and try again.")
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
    expect(publishedReadSessionKeys).toEqual([]);
  });

  it("does not expose web-only footer controls in the session popup", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    expect(screen.queryByRole("button", { name: "Settings" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });

  it("opens session selection as an overlay without changing the route", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    expect(screen.getByRole("dialog", { name: "Sessions" })).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });

  it("supports browser-safe no-text chat shortcuts", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.keyDown(document.body, { key: "/" });

    expect(screen.getByRole("dialog", { name: "Sessions" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Personal/i }));
    fireEvent.keyDown(document.body, { key: " " });

    expect(screen.getByRole("textbox", { name: "Message" })).toHaveFocus();
  });

  it("routes command semicolon to the stream popup without taking browser-reserved command chords", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    const composer = screen.getByRole("textbox", { name: "Message" });
    composer.focus();
    fireEvent.keyDown(composer, { key: ";", metaKey: true });

    expect(screen.getByRole("dialog", { name: "Sessions" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Personal/i }));
    composer.blur();
    fireEvent.keyDown(document.body, { key: "l", metaKey: true });

    expect(composer).not.toHaveFocus();
    expect(screen.queryByRole("dialog", { name: "Sessions" })).not.toBeInTheDocument();
  });

  it("opens stream management from the session sheet without changing the route", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));
    fireEvent.click(screen.getByRole("button", { name: "Add stream" }));

    expect(screen.getByRole("heading", { name: "Manage sessions" })).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });

  it("disables untrack for built-in adopted sessions", async () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));
    fireEvent.click(screen.getByRole("button", { name: "Add stream" }));

    const streamManager = await screen.findByRole("heading", {
      name: "Manage sessions"
    });
    const streamManagerPanel = streamManager.closest("aside");
    expect(streamManagerPanel).not.toBeNull();
    const globalCard = within(streamManagerPanel as HTMLElement)
      .getByText("agent:main:main")
      .closest(".stream-manager-card");
    expect(globalCard).not.toBeNull();
    expect(
      within(globalCard as HTMLElement).queryByRole("button", { name: "Untrack" })
    ).toBeNull();
    expect(
      within(globalCard as HTMLElement).getByRole("button", { name: "Delete" })
    ).toBeDisabled();
  });

  it("dismisses source notifications after local stream deletion succeeds", async () => {
    const sideSessionKey = "agent:main:clawline:user_1:side";
    const { notificationStore } = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        sideSessionKey
      ],
      configureTransportMachine: ({ notificationStore }) => {
        notificationStore.applyIncomingMessage({
          message: {
            type: "message",
            id: "s_side_notification",
            role: "assistant",
            content: "Delete me after stream removal",
            timestamp: 30,
            streaming: false,
            sessionKey: sideSessionKey,
            attachments: []
          },
          selectedSessionKey: "agent:main:clawline:user_1:main",
          source: "live",
          streams: TEST_STREAMS.map((stream) => ({ ...stream }))
        });
      }
    });

    expect(
      notificationStore.getState().bubblesBySourceChatId
    ).toHaveProperty(sideSessionKey);
    expect(screen.getByText("Delete me after stream removal")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));
    fireEvent.click(screen.getByRole("button", { name: "Add stream" }));

    const streamManager = await screen.findByRole("heading", {
      name: "Manage sessions"
    });
    const streamManagerPanel = streamManager.closest("aside");
    expect(streamManagerPanel).not.toBeNull();
    const sideCard = within(streamManagerPanel as HTMLElement)
      .getByText(sideSessionKey)
      .closest(".stream-manager-card");
    expect(sideCard).not.toBeNull();

    fireEvent.click(within(sideCard as HTMLElement).getByRole("button", { name: "Delete" }));

    await waitFor(() => {
      expect(
        notificationStore.getState().bubblesBySourceChatId
      ).not.toHaveProperty(sideSessionKey);
    });
    await waitFor(() => {
      expect(screen.queryByText("Delete me after stream removal")).toBeNull();
    });
  });

  it("clears unread state when the URL-selected session becomes active", async () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side", {
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });

    expect(screen.getByText("Side thread")).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.queryByLabelText("1 unread messages")).not.toBeInTheDocument();
    });
  });

  it("shows assistant-only cross-chat notifications and dismisses them with shortcuts", async () => {
    const publishedReadStates: Array<{ sessionKey: string; lastReadMessageId: string }> = [];
    const { chatStore, notificationStore, transportMachine } = renderChatRoute(
      "/chat/agent:main:clawline:user_1:main",
      {
        initialMessages: [],
        sessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:main",
          "agent:main:clawline:user_1:side"
        ],
        streamReadStates: {
          "agent:main:clawline:user_1:side": "s_old_read"
        },
        configureTransportMachine({ transportMachine }) {
          const publishReadState = transportMachine.publishReadState.bind(transportMachine);
          vi.spyOn(transportMachine, "publishReadState").mockImplementation(
            async (sessionKey, lastReadMessageId) => {
              publishedReadStates.push({ sessionKey, lastReadMessageId });
              await publishReadState(sessionKey, lastReadMessageId);
            }
          );
        }
      }
    );

    const userMessageInput: Parameters<typeof chatStore.applyIncomingMessage>[0] = {
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_user_ignored",
        role: "user",
        content: "Do not notify",
        timestamp: 20,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    };
    chatStore.applyIncomingMessage(userMessageInput);
    notificationStore.applyIncomingMessage({
      message: userMessageInput.message,
      selectedSessionKey: userMessageInput.selectedSessionKey,
      source: userMessageInput.source,
      streams: TEST_STREAMS.map((stream) => ({ ...stream }))
    });

    expect(screen.queryByLabelText("Side Thread notification")).toBeNull();

    const assistantMessageInput: Parameters<typeof chatStore.applyIncomingMessage>[0] = {
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_notify",
        role: "assistant",
        content: "Side notification",
        timestamp: 21,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    };
    chatStore.applyIncomingMessage(assistantMessageInput);
    notificationStore.applyIncomingMessage({
      message: assistantMessageInput.message,
      selectedSessionKey: assistantMessageInput.selectedSessionKey,
      source: assistantMessageInput.source,
      streams: TEST_STREAMS.map((stream) => ({ ...stream }))
    });

    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();
    expect(screen.getByText("Side notification")).toBeInTheDocument();
    expect(screen.getByText("⌘0")).toBeInTheDocument();
    expect(transportMachine.publishReadState).not.toHaveBeenCalledWith(
      "agent:main:clawline:user_1:side",
      "s_side_notify"
    );

    fireEvent.keyDown(document.body, { key: "0", metaKey: true, shiftKey: true, altKey: true });

    await waitFor(() => {
      expect(screen.queryByLabelText("Side Thread notification")).toBeNull();
    });
    await waitFor(() => {
      expect(publishedReadStates).toContainEqual({
        sessionKey: "agent:main:clawline:user_1:side",
        lastReadMessageId: "s_side_notify"
      });
    });
    expect(
      chatStore.getState().streamReadStateBySessionKey[
        "agent:main:clawline:user_1:side"
      ]
    ).toBe("s_side_notify");
  });

  it("renders assistant markdown inside cross-chat notification content", async () => {
    const { chatStore, notificationStore } = renderChatRoute(
      "/chat/agent:main:clawline:user_1:main",
      {
        initialMessages: [],
        sessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:main",
          "agent:main:clawline:user_1:side"
        ]
      }
    );

    const assistantMessageInput: Parameters<typeof chatStore.applyIncomingMessage>[0] = {
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_markdown_notify",
        role: "assistant",
        content: "Side **notification** with [details](https://example.com)",
        timestamp: 21,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    };
    chatStore.applyIncomingMessage(assistantMessageInput);
    notificationStore.applyIncomingMessage({
      message: assistantMessageInput.message,
      selectedSessionKey: assistantMessageInput.selectedSessionKey,
      source: assistantMessageInput.source,
      streams: TEST_STREAMS.map((stream) => ({ ...stream }))
    });

    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();
    expect(screen.getByText("notification").tagName).toBe("STRONG");
    expect(screen.getByRole("link", { name: "details" })).toHaveAttribute(
      "href",
      "https://example.com"
    );
  });

  it("replies from a notification to its source chat without changing the current transcript", async () => {
    const { chatStore, notificationStore, transportMachine } = renderChatRoute(
      "/chat/agent:main:clawline:user_1:main",
      {
        initialMessages: [],
        sessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:main",
          "agent:main:clawline:user_1:side"
        ]
      }
    );
    const sendMessage = vi
      .spyOn(transportMachine, "sendMessage")
      .mockResolvedValue(undefined);

    const assistantMessageInput: Parameters<typeof chatStore.applyIncomingMessage>[0] = {
      localDeviceId: "browser-device-1",
      message: {
        type: "message",
        id: "s_side_notify",
        role: "assistant",
        content: "Side notification",
        timestamp: 21,
        streaming: false,
        sessionKey: "agent:main:clawline:user_1:side",
        attachments: []
      },
      selectedSessionKey: "agent:main:clawline:user_1:main",
      source: "live"
    };
    chatStore.applyIncomingMessage(assistantMessageInput);
    notificationStore.applyIncomingMessage({
      message: assistantMessageInput.message,
      selectedSessionKey: assistantMessageInput.selectedSessionKey,
      source: assistantMessageInput.source,
      streams: TEST_STREAMS.map((stream) => ({ ...stream }))
    });

    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();

    fireEvent.keyDown(document.body, { key: "0", metaKey: true, shiftKey: true });
    const replyField = await screen.findByRole("textbox", {
      name: "Reply to Side Thread"
    });
    expect(
      screen.getByLabelText("Side Thread notification").querySelector(".cross-chat-notification-entries")
    ).toBeNull();
    fireEvent.change(replyField, { target: { value: "Reply from here" } });
    fireEvent.keyDown(replyField, { key: "Enter" });

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledWith({
        attachments: [],
        content: "Reply from here",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:side"
      });
    });

    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toBeUndefined();
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:side"]
    ).toEqual([
      expect.objectContaining({
        content: "Side notification",
        role: "assistant"
      }),
      expect.objectContaining({
        content: "Reply from here",
        role: "user"
      })
    ]);
    expect(screen.getByLabelText("Side Thread notification")).toBeInTheDocument();

    const sentMessage = sendMessage.mock.calls[0]?.[0];
    expect(sentMessage?.id).toEqual(expect.stringMatching(/^c_/));
    await act(async () => {
      chatStore.markMessageAcked(sentMessage.id);
    });

    await waitFor(() => {
      expect(screen.queryByLabelText("Side Thread notification")).toBeNull();
    });
  });

  it("navigates to a notification source when the web notification body is clicked", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view);

    fireEvent.click(await screen.findByText("Side notification"));

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:side"
    );
    await waitFor(() => {
      expect(screen.queryByLabelText("Side Thread notification")).toBeNull();
    });
  });

  it("uses viewport-fit notification capacity with ten only as the upper bound", async () => {
    const originalInnerHeight = window.innerHeight;
    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: 230
    });

    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: ["agent:main:clawline:user_1:main", "agent:main:main"]
    });
    const notificationStreams = [
      ...TEST_STREAMS.map((stream) => ({ ...stream })),
      ...Array.from({ length: 3 }, (_, index) => ({
        sessionKey: `agent:main:clawline:user_1:extra_${index}`,
        displayName: `Extra ${index}`,
        kind: "custom",
        orderIndex: index + 3,
        isBuiltIn: false,
        createdAt: 20 + index,
        updatedAt: 20 + index,
        adopted: false
      }))
    ];

    for (let index = 0; index < 3; index += 1) {
      applyAssistantNotification(view, {
        content: `Extra notification ${index}`,
        id: `s_extra_notification_${index}`,
        sessionKey: `agent:main:clawline:user_1:extra_${index}`,
        timestamp: 30 + index,
        streams: notificationStreams
      });
    }

    expect(await screen.findByLabelText("Extra 2 notification")).toBeInTheDocument();
    expect(screen.getByLabelText("Extra 1 notification")).toBeInTheDocument();
    expect(screen.queryByLabelText("Extra 0 notification")).toBeNull();
    expect(
      view.notificationStore.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:extra_0"
      ]
    ).toBeDefined();

    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: originalInnerHeight
    });
  });

  it("keeps long web notification content in a scrollable entries region", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view, {
      content: "Long notification ".repeat(40)
    });

    const bubble = await screen.findByLabelText("Side Thread notification");
    const entries = bubble.querySelector(".cross-chat-notification-entries");
    const paragraph = bubble.querySelector(".cross-chat-notification-entries p");
    const styleText = readFileSync("src/app/styles.css", "utf8");
    expect(entries).not.toBeNull();
    expect(paragraph).not.toBeNull();
    expect(styleText).toContain(".cross-chat-notification-entries");
    expect(styleText).toContain("overflow: auto;");
    expect(styleText).toContain("interpolate-size: allow-keywords;");
    expect(styleText).toContain("align-self: start;");
    expect(styleText).toContain("justify-self: end;");
    expect(styleText).toContain("--notification-motion-duration: 300ms;");
    expect(styleText).toContain("--notification-motion-reveal: cubic-bezier(0, 0, 0.2, 1);");
    expect(styleText).toContain("--notification-motion-hide: cubic-bezier(0.4, 0, 1, 1);");
    expect(styleText).toContain("--notification-motion-resize: cubic-bezier(0.4, 0, 0.2, 1);");
    expect(styleText).toContain(
      "height var(--notification-motion-duration) var(--notification-motion-resize)"
    );
    expect(styleText).toContain("grid-template-rows: auto auto auto;");
    expect(styleText).toContain("max-height: calc(min(20rem, 45vh) - 4.7rem);");
    expect(styleText).not.toContain(".cross-chat-notification-entries {\n  min-height:");
    expect(styleText).not.toContain("-webkit-line-clamp: 3;");
  });

  it("collapses web notifications to right-edge peeks and restores them", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view);

    const overlay = await screen.findByLabelText("Cross-chat notifications");
    const bubble = await screen.findByLabelText("Side Thread notification");
    await act(async () => {
      fireEvent.pointerDown(bubble, { clientX: 200, clientY: 40 });
      fireEvent.pointerUp(bubble, { clientX: 260, clientY: 42 });
    });

    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(screen.getByLabelText("Side Thread notification")).toBeInTheDocument();
    expect(
      view.notificationStore.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]
    ).toBeDefined();

    fireEvent.click(screen.getByRole("button", { name: "Show notifications" }));
    expect(overlay).not.toHaveClass("cross-chat-notification-overlay--collapsed");

    await act(async () => {
      fireEvent.pointerDown(bubble, { clientX: 200, clientY: 40 });
      fireEvent.pointerUp(bubble, { clientX: 260, clientY: 42 });
    });
    const peek = screen.getByRole("button", { name: "Show notifications" });
    fireEvent.pointerDown(peek, { clientX: 260, clientY: 40 });
    fireEvent.pointerUp(peek, { clientX: 200, clientY: 42 });

    expect(overlay).not.toHaveClass("cross-chat-notification-overlay--collapsed");

    fireEvent.keyDown(document.body, { key: "\\", code: "Backslash", metaKey: true });
    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(fireEvent.keyDown(document.body, { key: "j", metaKey: true })).toBe(false);
    fireEvent.keyDown(document.body, { key: "\\", code: "Backslash", metaKey: true });
    expect(overlay).not.toHaveClass("cross-chat-notification-overlay--collapsed");
  });

  it("temporarily reveals collapsed web notifications when new content arrives", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view);

    const overlay = await screen.findByLabelText("Cross-chat notifications");
    const bubble = await screen.findByLabelText("Side Thread notification");
    fireEvent.pointerDown(bubble, { clientX: 200, clientY: 40 });
    fireEvent.pointerUp(bubble, { clientX: 260, clientY: 42 });
    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(bubble).toHaveClass("cross-chat-notification-bubble--collapsed");

    vi.useFakeTimers();
    await act(async () => {
      applyAssistantNotification(view, {
        content: "Fresh collapsed notification",
        id: "s_side_notify_2",
        timestamp: 22
      });
    });

    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(bubble).not.toHaveClass("cross-chat-notification-bubble--collapsed");
    expect(screen.getByText("Fresh collapsed notification")).toBeInTheDocument();

    await act(async () => {
      vi.advanceTimersByTime(3000);
      applyAssistantNotification(view, {
        content: "Another collapsed notification",
        id: "s_side_notify_3",
        timestamp: 23
      });
    });
    await act(async () => {
      vi.advanceTimersByTime(3000);
    });
    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(bubble).not.toHaveClass("cross-chat-notification-bubble--collapsed");

    await act(async () => {
      vi.advanceTimersByTime(2000);
    });
    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(bubble).toHaveClass("cross-chat-notification-bubble--collapsed");
    expect(
      view.notificationStore.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]
    ).toBeDefined();
  });

  it("uses notification-owned swipes for docked previews and dismissal", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view);

    const overlay = await screen.findByLabelText("Cross-chat notifications");
    const bubble = await screen.findByLabelText("Side Thread notification");
    fireEvent.pointerDown(bubble, { clientX: 200, clientY: 40 });
    fireEvent.pointerUp(bubble, { clientX: 260, clientY: 42 });
    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(bubble).toHaveClass("cross-chat-notification-bubble--collapsed");

    vi.useFakeTimers();
    await act(async () => {
      applyAssistantNotification(view, {
        content: "Preview me",
        id: "s_side_notify_preview",
        timestamp: 24
      });
    });
    expect(bubble).not.toHaveClass("cross-chat-notification-bubble--collapsed");

    fireEvent.pointerDown(bubble, { clientX: 200, clientY: 40 });
    fireEvent.pointerUp(bubble, { clientX: 260, clientY: 42 });
    expect(overlay).toHaveClass("cross-chat-notification-overlay--collapsed");
    expect(bubble).toHaveClass("cross-chat-notification-bubble--collapsed");
    expect(
      view.notificationStore.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]
    ).toBeDefined();

    await act(async () => {
      fireEvent.pointerDown(bubble, { clientX: 260, clientY: 40 });
      fireEvent.pointerUp(bubble, { clientX: 200, clientY: 42 });
    });
    expect(
      view.notificationStore.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:side"
      ]
    ).toBeUndefined();
    expect(bubble).toHaveClass("cross-chat-notification-bubble--exiting");
  });

  it("reveals only the updated collapsed web notification bubble", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    const notificationStreams = [
      ...TEST_STREAMS.map((stream) => ({ ...stream })),
      {
        sessionKey: "agent:main:clawline:user_1:other",
        displayName: "Other Thread",
        kind: "custom",
        orderIndex: 3,
        isBuiltIn: false,
        createdAt: 12,
        updatedAt: 12,
        adopted: false
      }
    ];
    applyAssistantNotification(view, { streams: notificationStreams });
    applyAssistantNotification(view, {
      content: "Other notification",
      id: "s_other_notify",
      sessionKey: "agent:main:clawline:user_1:other",
      timestamp: 22,
      streams: notificationStreams
    });

    const overlay = await screen.findByLabelText("Cross-chat notifications");
    const sideBubble = await screen.findByLabelText("Side Thread notification");
    const otherBubble = await screen.findByLabelText("Other Thread notification");
    fireEvent.pointerDown(sideBubble, { clientX: 200, clientY: 40 });
    fireEvent.pointerUp(sideBubble, { clientX: 260, clientY: 42 });
    expect(sideBubble).toHaveClass("cross-chat-notification-bubble--collapsed");
    expect(otherBubble).toHaveClass("cross-chat-notification-bubble--collapsed");

    vi.useFakeTimers();
    await act(async () => {
      applyAssistantNotification(view, {
        content: "Fresh side notification",
        id: "s_side_notify_2",
        timestamp: 23,
        streams: notificationStreams
      });
    });

    expect(sideBubble).not.toHaveClass("cross-chat-notification-bubble--collapsed");
    expect(otherBubble).toHaveClass("cross-chat-notification-bubble--collapsed");
  });

  it("keeps an active notification reply visible when newer notifications arrive", async () => {
    const originalInnerHeight = window.innerHeight;
    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: 220
    });
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: ["agent:main:clawline:user_1:main", "agent:main:main"]
    });
    const notificationStreams = [
      ...TEST_STREAMS.map((stream) => ({ ...stream })),
      ...Array.from({ length: 2 }, (_, index) => ({
        sessionKey: `agent:main:clawline:user_1:extra_${index}`,
        displayName: `Extra ${index}`,
        kind: "custom",
        orderIndex: index + 3,
        isBuiltIn: false,
        createdAt: 20 + index,
        updatedAt: 20 + index,
        adopted: false
      }))
    ];

    applyAssistantNotification(view, {
      content: "Reply target",
      id: "s_side_reply_pin",
      sessionKey: "agent:main:clawline:user_1:side",
      timestamp: 30,
      streams: notificationStreams
    });

    const sideBubble = await screen.findByLabelText("Side Thread notification");
    fireEvent.click(within(sideBubble).getByRole("button", { name: "Reply" }));
    expect(await screen.findByLabelText("Reply to Side Thread")).toBeInTheDocument();

    applyAssistantNotification(view, {
      content: "Newer visible",
      id: "s_extra_notification_0",
      sessionKey: "agent:main:clawline:user_1:extra_0",
      timestamp: 31,
      streams: notificationStreams
    });
    applyAssistantNotification(view, {
      content: "Newest would normally overflow the reply",
      id: "s_extra_notification_1",
      sessionKey: "agent:main:clawline:user_1:extra_1",
      timestamp: 32,
      streams: notificationStreams
    });

    expect(screen.getByLabelText("Side Thread notification")).toBeInTheDocument();
    expect(screen.getByLabelText("Reply to Side Thread")).toBeInTheDocument();
    expect(
      view.notificationStore.getState().bubblesBySourceChatId[
        "agent:main:clawline:user_1:extra_1"
      ]
    ).toBeDefined();

    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: originalInnerHeight
    });
  });

  it("offers clear-all confirmation after holding a web notification dismiss control", async () => {
    const confirm = vi.fn(() => true);
    vi.stubGlobal("confirm", confirm);
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view, {
      content: "First notification",
      id: "s_side_notify_1",
      sessionKey: "agent:main:clawline:user_1:side",
      timestamp: 21
    });
    applyAssistantNotification(view, {
      content: "Second notification",
      id: "s_main_notify_2",
      sessionKey: "agent:main:main",
      timestamp: 22
    });

    expect(await screen.findByText("Second notification")).toBeInTheDocument();
    vi.useFakeTimers();
    const dismissButton = screen.getAllByRole("button", { name: "Dismiss" })[0];
    fireEvent.pointerDown(dismissButton);
    await vi.advanceTimersByTimeAsync(650);

    expect(confirm).toHaveBeenCalledWith("Clear all notifications?");
    expect(view.notificationStore.getState().bubblesBySourceChatId).toEqual({});
  });

  it("uses notification digit shortcuts for action menus, reply, and dismiss", async () => {
    const navigateView = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(navigateView);

    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();

    const composer = screen.getByRole("textbox", { name: "Message" });
    composer.focus();
    fireEvent.keyDown(composer, {
      code: "Digit0",
      key: "0",
      metaKey: true
    });

    const actionMenu = await screen.findByRole("menu", {
      name: "Actions for Side Thread notification"
    });
    expect(within(actionMenu).getByRole("menuitem", { name: /Go to Chat/ }))
      .toHaveAttribute("aria-selected", "true");
    expect(within(actionMenu).getByText("⇧⌘0")).toBeInTheDocument();
    expect(within(actionMenu).getByText("⌥⇧⌘0")).toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );

    fireEvent.keyDown(actionMenu, { key: "Enter" });

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:side"
    );
    navigateView.unmount();

    const actionView = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(actionView);
    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();

    fireEvent.keyDown(document.body, {
      code: "Digit0",
      key: ")",
      metaKey: true,
      shiftKey: true
    });

    expect(
      await screen.findByRole("textbox", { name: "Reply to Side Thread" })
    ).toBeInTheDocument();

    const replyField = screen.getByRole("textbox", { name: "Reply to Side Thread" });
    replyField.focus();
    fireEvent.keyDown(replyField, {
      code: "Digit0",
      key: ")",
      metaKey: true,
      shiftKey: true,
      altKey: true
    });
    await waitFor(() => {
      expect(screen.queryByLabelText("Side Thread notification")).toBeNull();
    });
  });

  it("moves through the notification action menu with arrow keys", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view);

    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();

    fireEvent.keyDown(document.body, {
      code: "Digit0",
      key: "0",
      metaKey: true
    });

    const actionMenu = await screen.findByRole("menu", {
      name: "Actions for Side Thread notification"
    });
    fireEvent.keyDown(actionMenu, { key: "ArrowDown" });
    expect(within(actionMenu).getByRole("menuitem", { name: /Reply/ }))
      .toHaveAttribute("aria-selected", "true");

    fireEvent.keyDown(actionMenu, { key: "Escape" });
    expect(
      screen.queryByRole("menu", { name: "Actions for Side Thread notification" })
    ).toBeNull();

    fireEvent.keyDown(document.body, {
      code: "Digit0",
      key: "0",
      metaKey: true
    });
    const reopenedActionMenu = await screen.findByRole("menu", {
      name: "Actions for Side Thread notification"
    });
    fireEvent.keyDown(reopenedActionMenu, { key: "ArrowDown" });
    expect(within(reopenedActionMenu).getByRole("menuitem", { name: /Reply/ }))
      .toHaveAttribute("aria-selected", "true");

    fireEvent.keyDown(reopenedActionMenu, { key: "Enter" });

    expect(
      await screen.findByRole("textbox", { name: "Reply to Side Thread" })
    ).toBeInTheDocument();
  });

  it("ignores unspecced Ctrl notification digit variants", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view);

    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();

    fireEvent.keyDown(document.body, {
      code: "Digit0",
      ctrlKey: true,
      key: "0",
      metaKey: true
    });
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
    expect(screen.getByLabelText("Side Thread notification")).toBeInTheDocument();
  });

  it("scrolls the active or top visible notification with Cmd-J and Cmd-K", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view, {
      content: "Older notification ".repeat(20),
      id: "s_side_notify",
      sessionKey: "agent:main:clawline:user_1:side",
      timestamp: 21
    });
    applyAssistantNotification(view, {
      content: "Top notification ".repeat(20),
      id: "s_heimdal_notify",
      sessionKey: "agent:main:main",
      timestamp: 22
    });

    const topBubble = await screen.findByLabelText("Heimdal notification");
    const sideBubble = screen.getByLabelText("Side Thread notification");
    const topEntries = topBubble.querySelector(".cross-chat-notification-entries");
    const sideEntries = sideBubble.querySelector(".cross-chat-notification-entries");
    expect(topEntries).toBeInstanceOf(HTMLElement);
    expect(sideEntries).toBeInstanceOf(HTMLElement);
    const topElement = topEntries as HTMLElement;
    const sideElement = sideEntries as HTMLElement;
    Object.defineProperty(topElement, "clientHeight", { configurable: true, value: 80 });
    Object.defineProperty(topElement, "scrollHeight", { configurable: true, value: 240 });
    Object.defineProperty(sideElement, "clientHeight", { configurable: true, value: 80 });
    Object.defineProperty(sideElement, "scrollHeight", { configurable: true, value: 240 });
    topElement.scrollTo = vi.fn((options?: ScrollToOptions | number) => {
      topElement.scrollTop =
        typeof options === "number" ? options : Number(options?.top ?? 0);
    });
    sideElement.scrollTo = vi.fn((options?: ScrollToOptions | number) => {
      sideElement.scrollTop =
        typeof options === "number" ? options : Number(options?.top ?? 0);
    });

    fireEvent.keyDown(document.body, { key: "j", metaKey: true });
    expect(topElement.scrollTop).toBe(56);
    expect(sideElement.scrollTop).toBe(0);

    fireEvent.pointerEnter(sideBubble);
    fireEvent.keyDown(document.body, { key: "j", metaKey: true });
    expect(sideElement.scrollTop).toBe(56);

    fireEvent.keyDown(document.body, { key: "k", metaKey: true });
    expect(sideElement.scrollTop).toBe(0);
  });

  it("scrolls notifications with Cmd-J and Cmd-Shift-J while reply text is focused", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view, {
      content: "Side notification ".repeat(20),
      timestamp: 21
    });
    expect(await screen.findByLabelText("Side Thread notification"))
      .toBeInTheDocument();
    fireEvent.keyDown(document.body, {
      code: "Digit0",
      key: ")",
      metaKey: true,
      shiftKey: true
    });
    const replyField = await screen.findByRole("textbox", {
      name: "Reply to Side Thread"
    });
    expect(
      screen.getByLabelText("Side Thread notification").querySelector(".cross-chat-notification-entries")
    ).toBeNull();
    applyAssistantNotification(view, {
      content: "Heimdal notification ".repeat(20),
      id: "s_heimdal_notify",
      sessionKey: "agent:main:main",
      timestamp: 22
    });
    const bubble = await screen.findByLabelText("Heimdal notification");
    fireEvent.pointerEnter(bubble);
    const entries = bubble.querySelector(".cross-chat-notification-entries");
    expect(entries).toBeInstanceOf(HTMLElement);
    const element = entries as HTMLElement;
    Object.defineProperty(element, "clientHeight", { configurable: true, value: 80 });
    Object.defineProperty(element, "scrollHeight", { configurable: true, value: 240 });
    element.scrollTo = vi.fn((options?: ScrollToOptions | number) => {
      element.scrollTop =
        typeof options === "number" ? options : Number(options?.top ?? 0);
    });

    fireEvent.keyDown(replyField, { key: "j", metaKey: true });
    expect(element.scrollTo).toHaveBeenCalledTimes(1);
    expect(element.scrollTop).toBe(56);

    fireEvent.keyDown(replyField, { key: "j", metaKey: true, shiftKey: true });
    expect(element.scrollTo).toHaveBeenCalledTimes(2);
    expect(element.scrollTop).toBe(112);
  });

  it("scrolls notifications with Cmd-J while composer text is focused", async () => {
    const view = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      initialMessages: [],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });
    applyAssistantNotification(view, {
      content: "Side notification ".repeat(20)
    });

    const composer = screen.getByLabelText("Message");
    composer.focus();
    const bubble = await screen.findByLabelText("Side Thread notification");
    const entries = bubble.querySelector(".cross-chat-notification-entries");
    expect(entries).toBeInstanceOf(HTMLElement);
    const element = entries as HTMLElement;
    Object.defineProperty(element, "clientHeight", { configurable: true, value: 80 });
    Object.defineProperty(element, "scrollHeight", { configurable: true, value: 240 });
    element.scrollTo = vi.fn((options?: ScrollToOptions | number) => {
      element.scrollTop =
        typeof options === "number" ? options : Number(options?.top ?? 0);
    });

    fireEvent.keyDown(composer, { key: "j", metaKey: true });

    expect(element.scrollTo).toHaveBeenCalledTimes(1);
    expect(element.scrollTop).toBe(56);
  });

  it("clears built-in stream unread dots after each stream is visited", async () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side", {
      initialMessages: [
        {
          content: "Side thread",
          id: "s_side",
          selectedSessionKey: "agent:main:clawline:user_1:side",
          sessionKey: "agent:main:clawline:user_1:side",
          timestamp: 10
        },
        {
          content: "Personal ping",
          id: "s_personal_unread",
          selectedSessionKey: "agent:main:clawline:user_1:side",
          sessionKey: "agent:main:clawline:user_1:main",
          timestamp: 11
        },
        {
          content: "Heimdal ping",
          id: "s_heimdal_unread",
          selectedSessionKey: "agent:main:clawline:user_1:side",
          sessionKey: "agent:main:main",
          timestamp: 12
        }
      ],
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ],
      streamReadStates: {
        "agent:main:clawline:user_1:side": "s_side"
      },
      streamTailStates: {
        "agent:main:clawline:user_1:main": {
          lastMessageId: "s_personal_unread",
          lastMessageRole: "assistant"
        },
        "agent:main:main": {
          lastMessageId: "s_heimdal_unread",
          lastMessageRole: "assistant"
        },
        "agent:main:clawline:user_1:side": {
          lastMessageId: "s_side",
          lastMessageRole: "assistant"
        }
      }
    });

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    const personalUnreadCard = screen.getByRole("button", { name: /Personal/i });
    const heimdalUnreadCard = screen.getByRole("button", { name: /Heimdal/i });

    expect(
      personalUnreadCard.querySelector(".session-sheet-card-indicator--unread")
    ).not.toBeNull();
    expect(
      heimdalUnreadCard.querySelector(".session-sheet-card-indicator--unread")
    ).not.toBeNull();

    fireEvent.click(personalUnreadCard);

    await waitFor(() => {
      expect(screen.getByText("Personal ping")).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    const personalReadCard = screen.getByRole("button", { name: /Personal/i });
    const heimdalStillUnreadCard = screen.getByRole("button", { name: /Heimdal/i });

    expect(
      personalReadCard.querySelector(".session-sheet-card-indicator--unread")
    ).toBeNull();
    expect(
      heimdalStillUnreadCard.querySelector(".session-sheet-card-indicator--unread")
    ).not.toBeNull();

    fireEvent.click(heimdalStillUnreadCard);

    await waitFor(() => {
      expect(screen.getByText("Heimdal ping")).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    const heimdalReadCard = screen.getByRole("button", { name: /Heimdal/i });

    expect(
      heimdalReadCard.querySelector(".session-sheet-card-indicator--unread")
    ).toBeNull();
  });

  it("shows unavailable provisioning state when the user explicitly switches to a non-provisioned session", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main");

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));
    fireEvent.click(screen.getByRole("button", { name: /Side Thread/i }));

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:side"
    );
    expect(
      screen.getByText("This session is unavailable for sending. Switch streams and try again.")
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
  });

  it("sends through the committed URL-selected session after a popup switch", async () => {
    const { webSocketFactory } = renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));
    fireEvent.click(screen.getByRole("button", { name: /Side Thread/i }));

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent(
        "/chat/agent:main:clawline:user_1:side"
      );
    });

    fireEvent.change(screen.getByPlaceholderText(/Side Thread/), {
      target: { value: "Route-selected side send" }
    });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      const sentMessages = webSocketFactory.sockets[0].sentTexts
        .map((text) => JSON.parse(text))
        .filter((message) => message.type === "message");
      expect(sentMessages.at(-1)).toMatchObject({
        content: "Route-selected side send",
        sessionKey: "agent:main:clawline:user_1:side",
        type: "message"
      });
    });
  });

  it("swipes horizontally between adjacent streams on the chat panel", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:main", {
      sessionKeys: [
        "agent:main:clawline:user_1:main",
        "agent:main:main",
        "agent:main:clawline:user_1:side"
      ]
    });

    const chatPanel = screen.getByTestId("chat-panel");

    fireEvent.touchStart(chatPanel, {
      touches: [{ clientX: 280, clientY: 260 }]
    });
    fireEvent.touchEnd(chatPanel, {
      changedTouches: [{ clientX: 120, clientY: 250 }]
    });

    expect(screen.getByTestId("location")).toHaveTextContent("/chat/agent:main:main");

    fireEvent.touchStart(chatPanel, {
      touches: [{ clientX: 120, clientY: 260 }]
    });
    fireEvent.touchEnd(chatPanel, {
      changedTouches: [{ clientX: 280, clientY: 248 }]
    });

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
  });
});
