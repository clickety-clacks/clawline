import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
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
import { createMemoryChatPersistence } from "../../runtime/persistence/indexedDbChatPersistence";
import {
  SettingsStoreProvider,
  createSettingsStore
} from "../../runtime/settings/settingsStore";
import {
  TransportMachineProvider,
  createTransportMachine
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
    sessionKeys = ["agent:main:clawline:user_1:main", "agent:main:main"]
  }: {
    initialMessages?: Array<{
      content: string;
      id: string;
      selectedSessionKey: string;
      sessionKey: string;
      timestamp: number;
    }>;
    sessionKeys?: string[];
  } = {}
) {
  const authStore = createAuthSessionStore();
  const chatStore = createChatDomainStore({
    persistence: createMemoryChatPersistence()
  });
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
    webSocketFactory: webSocketFactory.create
  });
  webSocketFactory.sockets[0]?.emitOpen();
  webSocketFactory.sockets[0]?.emitMessage(
    JSON.stringify({
      type: "auth_result",
      success: true,
      sessionKeys
    })
  );

  return render(
    <SettingsStoreProvider value={settingsStore}>
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
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
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    </SettingsStoreProvider>
  );
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

        return new Response(JSON.stringify({ error: { code: "unexpected_path" } }), {
          headers: { "Content-Type": "application/json" },
          status: 404
        });
      })
    );
  });

  afterEach(() => {
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

  it("reconciles a boot-selected stream back to provider-visible inventory when it is no longer available", () => {
    renderChatRoute("/chat/agent:main:clawline:user_1:side");

    expect(screen.getByTestId("location")).toHaveTextContent(
      "/chat/agent:main:clawline:user_1:main"
    );
    expect(screen.getByText("Main thread")).toBeInTheDocument();
    expect(screen.queryByText("Side thread")).not.toBeInTheDocument();
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
      ]
    });

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    const personalUnreadCard = screen.getByRole("button", { name: /Personal/i });
    const heimdalUnreadCard = screen.getByRole("button", { name: /Heimdal/i });

    expect(within(personalUnreadCard).getByLabelText("1 unread messages")).toBeInTheDocument();
    expect(within(heimdalUnreadCard).getByLabelText("1 unread messages")).toBeInTheDocument();

    fireEvent.click(personalUnreadCard);

    await waitFor(() => {
      expect(screen.getByText("Personal ping")).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    const personalReadCard = screen.getByRole("button", { name: /Personal/i });
    const heimdalStillUnreadCard = screen.getByRole("button", { name: /Heimdal/i });

    expect(within(personalReadCard).queryByLabelText("1 unread messages")).toBeNull();
    expect(
      personalReadCard.querySelector(".session-sheet-card-indicator--unread")
    ).toBeNull();
    expect(
      within(heimdalStillUnreadCard).getByLabelText("1 unread messages")
    ).toBeInTheDocument();

    fireEvent.click(heimdalStillUnreadCard);

    await waitFor(() => {
      expect(screen.getByText("Heimdal ping")).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole("button", { name: "Manage streams" }));

    const heimdalReadCard = screen.getByRole("button", { name: /Heimdal/i });

    expect(within(heimdalReadCard).queryByLabelText("1 unread messages")).toBeNull();
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
