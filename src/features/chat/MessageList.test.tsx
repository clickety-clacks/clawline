import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MessageList } from "./MessageList";
import { resetLinkCardMetadataCache } from "./linkCardMetadata";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
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
import type { TransportMachine } from "../../runtime/transport/transportMachine";
import { TransportMachineProvider } from "../../runtime/transport/transportMachine";
import { INTERACTIVE_HTML_ATTACHMENT_MIME } from "../../protocol/interactive-html-wire";
import type {
  SessionControlAction,
  SessionStatusPayload
} from "../../protocol/stream-api";

const RICH_MESSAGE: ChatMessageRecord = {
  id: "s_rich",
  role: "assistant",
  content: [
    "Intro paragraph.",
    "",
    "```ts",
    "console.log('hi');",
    "```",
    "",
    "After code.",
    "",
    "| Name | Value |",
    "| --- | --- |",
    "| alpha | beta |"
  ].join("\n"),
  timestamp: 1_764_201_200_000,
  streaming: false,
  sessionKey: "agent:main:clawline:flynn:main",
  attachments: [],
  delivery: "server",
  sender: "Assistant"
};

const ATTACHMENT_MESSAGE: ChatMessageRecord = {
  id: "s_attachments",
  role: "assistant",
  content: "Attachment surface",
  timestamp: 1_764_201_200_100,
  streaming: false,
  sessionKey: "agent:main:clawline:flynn:main",
  attachments: [
    {
      type: "image",
      mimeType: "image/png",
      data: "aW1hZ2U="
    },
    {
      type: "asset",
      assetId: "audio_1",
      metadata: {
        filename: "note.mp3",
        mimeType: "audio/mpeg"
      }
    },
    {
      type: "document",
      assetId: "video_1",
      metadata: {
        filename: "demo.mp4",
        mimeType: "video/mp4"
      }
    },
    {
      type: "document",
      assetId: "file_1",
      metadata: {
        filename: "report.pdf",
        mimeType: "application/pdf"
      }
    }
  ],
  delivery: "server",
  sender: "Assistant"
};

const LINK_MESSAGE: ChatMessageRecord = {
  id: "s_links",
  role: "assistant",
  content: [
    "Visit https://example.com/docs for docs.",
    "",
    "Here is a markdown link to [OpenAI](https://openai.com/research).",
    "",
    "```",
    "https://example.com/in-code",
    "```"
  ].join("\n"),
  timestamp: 1_764_201_200_200,
  streaming: false,
  sessionKey: "agent:main:clawline:flynn:main",
  attachments: [],
  delivery: "server",
  sender: "Assistant"
};

function makeMessage(index: number): ChatMessageRecord {
  return {
    id: `s_bulk_${index}`,
    role: index % 3 === 0 ? "user" : "assistant",
    content: `Message ${index} ${"detail ".repeat(24)}`,
    timestamp: 1_764_201_300_000 + index,
    streaming: false,
    sessionKey: "agent:main:clawline:flynn:main",
    attachments: [],
    delivery: "server",
    sender: index % 3 === 0 ? undefined : "Assistant"
  };
}

function renderMessageList(messages: ChatMessageRecord[]) {
  const authStore = createAuthSessionStore();
  const chatStore = createChatDomainStore({
    persistence: createMemoryChatPersistence()
  });
  const transportState = {
    failureReason: null,
    isBrowserOnline: true,
    phase: "live" as const,
    retryAttempt: 0
  };
  const transportStore: TransportMachine = {
    getState() {
      return transportState;
    },
    async publishReadState() {},
    retryNow() {},
    async sendInteractiveCallback() {},
    async sendMessage() {},
    subscribe() {
      return () => {};
    }
  };
  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });
  const settingsStore = createSettingsStore();

  const renderResult = render(
    <SettingsStoreProvider value={settingsStore}>
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportStore}>
            <MessageList messages={messages} />
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    </SettingsStoreProvider>
  );

  return {
    chatStore,
    renderResult,
    transportStore
  };
}

function renderMessageListWithProps(input: {
  messages: ChatMessageRecord[];
  onCancelCurrentPrompt?: (sessionKey: string) => Promise<void> | void;
  onSessionControlSelected?: (
    sessionKey: string,
    action: SessionControlAction,
    value?: string | null,
    enabled?: boolean | null
  ) => Promise<void> | void;
  rememberedScrollState?: {
    offsetTop: number;
    stickToBottom: boolean;
  };
  sessionKey?: string;
  sessionStatus?: SessionStatusPayload | null;
  unreadAnchorMessageId?: string | null;
}) {
  const authStore = createAuthSessionStore();
  const chatStore = createChatDomainStore({
    persistence: createMemoryChatPersistence()
  });
  const transportState = {
    failureReason: null,
    isBrowserOnline: true,
    phase: "live" as const,
    retryAttempt: 0
  };
  const transportStore: TransportMachine = {
    getState() {
      return transportState;
    },
    async publishReadState() {},
    retryNow() {},
    async sendInteractiveCallback() {},
    async sendMessage() {},
    subscribe() {
      return () => {};
    }
  };
  authStore.storePairingSession({
    claimedName: "Desk Browser",
    deviceId: "browser-device-1",
    serverUrl: "ws://127.0.0.1:18800/ws",
    token: "jwt-token",
    userId: "user_1"
  });
  const settingsStore = createSettingsStore();

  const renderResult = render(
    <SettingsStoreProvider value={settingsStore}>
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportStore}>
            <MessageList
              messages={input.messages}
              onCancelCurrentPrompt={input.onCancelCurrentPrompt}
              rememberedScrollState={input.rememberedScrollState}
              onSessionControlSelected={input.onSessionControlSelected}
              sessionKey={input.sessionKey}
              sessionStatus={input.sessionStatus}
              unreadAnchorMessageId={input.unreadAnchorMessageId}
            />
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    </SettingsStoreProvider>
  );

  return {
    chatStore,
    renderResult,
    transportStore
  };
}

const originalCreateObjectUrl = URL.createObjectURL;
const originalRevokeObjectUrl = URL.revokeObjectURL;

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof URL ? input : new URL(String(input));
      if (url.pathname.endsWith("/audio_1")) {
        return new Response(new Blob(["audio"], { type: "audio/mpeg" }), { status: 200 });
      }
      if (url.pathname.endsWith("/video_1")) {
        return new Response(new Blob(["video"], { type: "video/mp4" }), { status: 200 });
      }
      if (url.pathname.endsWith("/file_1")) {
        return new Response(new Blob(["file"], { type: "application/pdf" }), { status: 200 });
      }
      return new Response(null, { status: 404 });
    })
  );

  Object.defineProperty(URL, "createObjectURL", {
    configurable: true,
    value: vi.fn((value: Blob) => `blob:${value.type || "application/octet-stream"}`)
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    configurable: true,
    value: vi.fn()
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  resetLinkCardMetadataCache();
  Object.defineProperty(URL, "createObjectURL", {
    configurable: true,
    value: originalCreateObjectUrl
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    configurable: true,
    value: originalRevokeObjectUrl
  });
});

describe("MessageList rich rendering", () => {
  it("formats timestamps per the bubble timestamp rules and reveals them on tap", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-04-02T18:00:00.000Z"));

    renderMessageList([
      {
        id: "s_recent",
        role: "assistant",
        content: "Fresh reply",
        timestamp: new Date("2026-04-02T17:58:00.000Z").getTime(),
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_yesterday",
        role: "assistant",
        content: "From yesterday",
        timestamp: new Date("2026-04-01T17:12:00.000Z").getTime(),
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      }
    ]);

    const recentBubble = screen.getByTestId("message-s_recent");
    const yesterdayBubble = screen.getByTestId("message-s_yesterday");

    expect(within(recentBubble).getByText("2m ago")).toBeInTheDocument();
    expect(within(yesterdayBubble).getByText(/Yesterday,/)).toBeInTheDocument();

    fireEvent.pointerUp(recentBubble, { pointerType: "touch" });
    expect(recentBubble).toHaveClass("message-bubble--timestamp-visible");

    vi.useRealTimers();
  });

  it("classifies message sizing and wide content from the design-system rules", () => {
    renderMessageList([
      {
        id: "s_short",
        role: "assistant",
        content: "Absolutely yes",
        timestamp: 1_764_201_200_025,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_medium",
        role: "assistant",
        content: "Found a better route through the market if you still want plants later.",
        timestamp: 1_764_201_200_030,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_long",
        role: "assistant",
        content:
          "This should settle into the long-form body treatment because it crosses the medium threshold and reads more like a full thought than a quick exchange.",
        timestamp: 1_764_201_200_035,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_wide",
        role: "assistant",
        content: [
          "Intro text.",
          "",
          "| Name | Value |",
          "| --- | --- |",
          "| alpha | beta |"
        ].join("\n"),
        timestamp: 1_764_201_200_040,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      }
    ]);

    expect(screen.getByTestId("message-s_short")).toHaveClass("message-bubble--short");
    expect(screen.getByTestId("message-s_medium")).toHaveClass("message-bubble--medium");
    expect(screen.getByTestId("message-s_long")).toHaveClass("message-bubble--long");
    expect(screen.getByTestId("message-s_wide")).toHaveClass("message-bubble--wide");
  });

  it("renders sender avatar waypoints with paired initials and alignment", () => {
    renderMessageList([
      RICH_MESSAGE,
      {
        id: "s_user",
        role: "user",
        content: "On it.",
        timestamp: 1_764_201_200_050,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server"
      }
    ]);

    const assistantAvatar = screen.getByTestId("message-avatar-s_rich");
    const assistantBubble = screen.getByTestId("message-s_rich");
    expect(assistantAvatar).toHaveTextContent("A");
    expect(assistantBubble).toContainElement(assistantAvatar);
    expect(assistantBubble.querySelector(".message-header")?.firstElementChild).toBe(assistantAvatar);
    expect(assistantBubble).toHaveClass("message-bubble--assistant");

    const userAvatar = screen.getByTestId("message-avatar-s_user");
    const userBubble = screen.getByTestId("message-s_user");
    expect(userAvatar).toHaveTextContent("Y");
    expect(userBubble).toContainElement(userAvatar);
    expect(userBubble.querySelector(".message-header")?.firstElementChild).toBe(userAvatar);
    expect(userBubble).toHaveClass("message-bubble--user");
  });

  it("applies chromeless bubble treatment only for the eligible content types", () => {
    renderMessageList([
      {
        id: "s_image_only",
        role: "assistant",
        content: "",
        timestamp: 1_764_201_200_051,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [
          {
            type: "image",
            mimeType: "image/png",
            data: "aW1hZ2U="
          }
        ],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_code_only",
        role: "assistant",
        content: ["```ts", "console.log('hi');", "```"].join("\n"),
        timestamp: 1_764_201_200_052,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_emoji_only",
        role: "user",
        content: "🌿✨",
        timestamp: 1_764_201_200_053,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server"
      },
      {
        id: "s_regular_code",
        role: "assistant",
        content: ["Before", "", "```ts", "console.log('hi');", "```"].join("\n"),
        timestamp: 1_764_201_200_054,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      }
    ]);

    expect(screen.getByTestId("message-s_image_only")).toHaveAttribute(
      "data-message-chrome",
      "chromeless-image"
    );
    expect(screen.getByTestId("message-s_code_only")).toHaveAttribute(
      "data-message-chrome",
      "chromeless-code"
    );
    expect(screen.getByTestId("message-s_emoji_only")).toHaveAttribute(
      "data-message-chrome",
      "chromeless-emoji"
    );
    expect(screen.getByTestId("message-s_regular_code")).toHaveAttribute(
      "data-message-chrome",
      "default"
    );
    expect(screen.getByTestId("message-s_emoji_only").querySelector(".message-markdown")).toHaveClass(
      "message-markdown--emoji"
    );
  });

  it("shows a typing indicator when the latest assistant reply is still streaming", () => {
    renderMessageList([
      {
        id: "s_typing_seed",
        role: "assistant",
        content: "Let me think through that.",
        timestamp: 1_764_201_200_055,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_typing_live",
        role: "assistant",
        content: "Working on it",
        timestamp: 1_764_201_200_056,
        streaming: true,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      }
    ]);

    expect(screen.getByTestId("typing-indicator")).toBeInTheDocument();
    expect(screen.getByTestId("typing-indicator")).toHaveTextContent("Assistant is typing");
    expect(screen.queryByText("Streaming...")).not.toBeInTheDocument();
  });

  it("offers retry for failed optimistic sends and resubmits through the transport", async () => {
    const authStore = createAuthSessionStore();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const sendMessage = vi.fn().mockResolvedValue(undefined);
    const retryNow = vi.fn();
    const transportState = {
      failureReason: null,
      isBrowserOnline: true,
      phase: "live" as const,
      retryAttempt: 0
    };
    const transportStore: TransportMachine = {
      getState() {
        return transportState;
      },
      async publishReadState() {},
      retryNow,
      async sendInteractiveCallback() {},
      sendMessage,
      subscribe() {
        return () => {};
      }
    };

    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token",
      userId: "user_1"
    });
    chatStore.applySessionInfo({
      type: "session_info",
      sessionKeys: ["agent:main:clawline:flynn:main"]
    });

    chatStore.enqueueOptimisticMessage({
      attachments: [],
      content: "Retry me",
      deviceId: "browser-device-1",
      id: "c_failed",
      sessionKey: "agent:main:clawline:flynn:main",
      timestamp: 1_764_201_200_070,
      wireAttachments: []
    });
    chatStore.markMessageFailed("c_failed");

    render(
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportStore}>
            <MessageList
              messages={chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:main"]}
            />
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Retry" }));

    expect(retryNow).not.toHaveBeenCalled();
    expect(sendMessage).toHaveBeenCalledWith({
      attachments: [],
      content: "Retry me",
      id: "c_failed",
      sessionKey: "agent:main:clawline:flynn:main"
    });
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:main"][0].delivery
    ).toBe("pending");
  });

  it("does not resend a failed optimistic send for an unprovisioned session", async () => {
    const authStore = createAuthSessionStore();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const sendMessage = vi.fn().mockResolvedValue(undefined);
    const retryNow = vi.fn();
    const transportState = {
      failureReason: null,
      isBrowserOnline: true,
      phase: "live" as const,
      retryAttempt: 0
    };
    const transportStore: TransportMachine = {
      getState() {
        return transportState;
      },
      async publishReadState() {},
      retryNow,
      async sendInteractiveCallback() {},
      sendMessage,
      subscribe() {
        return () => {};
      }
    };

    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token",
      userId: "user_1"
    });
    chatStore.applySessionInfo({
      type: "session_info",
      sessionKeys: ["agent:main:clawline:flynn:main"]
    });

    chatStore.enqueueOptimisticMessage({
      attachments: [],
      content: "Do not retry me",
      deviceId: "browser-device-1",
      id: "c_failed_unprovisioned",
      sessionKey: "agent:main:clawline:flynn:side",
      timestamp: 1_764_201_200_075,
      wireAttachments: []
    });
    chatStore.markMessageFailed("c_failed_unprovisioned");

    render(
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportStore}>
            <MessageList
              messages={chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:side"]}
            />
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Retry" }));

    expect(retryNow).not.toHaveBeenCalled();
    expect(sendMessage).not.toHaveBeenCalled();
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:side"][0].delivery
    ).toBe("failed");
  });

  it("routes failed-send retry through reconnect when transport is not live", async () => {
    const authStore = createAuthSessionStore();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const sendMessage = vi.fn().mockResolvedValue(undefined);
    const retryNow = vi.fn();
    const transportState = {
      failureReason: null,
      isBrowserOnline: true,
      phase: "recovering" as const,
      retryAttempt: 0
    };
    const transportStore: TransportMachine = {
      getState() {
        return transportState;
      },
      async publishReadState() {},
      retryNow,
      async sendInteractiveCallback() {},
      sendMessage,
      subscribe() {
        return () => {};
      }
    };

    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token",
      userId: "user_1"
    });
    chatStore.applySessionInfo({
      type: "session_info",
      sessionKeys: ["agent:main:clawline:flynn:main"]
    });

    chatStore.enqueueOptimisticMessage({
      attachments: [],
      content: "Retry me later",
      deviceId: "browser-device-1",
      id: "c_failed_recovering",
      sessionKey: "agent:main:clawline:flynn:main",
      timestamp: 1_764_201_200_080,
      wireAttachments: []
    });
    chatStore.markMessageFailed("c_failed_recovering");

    render(
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportStore}>
            <MessageList
              messages={chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:main"]}
            />
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Retry" }));

    expect(retryNow).toHaveBeenCalledTimes(1);
    expect(sendMessage).not.toHaveBeenCalled();
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:main"][0].delivery
    ).toBe("failed");
  });

  it("does not reconnect for a failed optimistic send in an unprovisioned session", async () => {
    const authStore = createAuthSessionStore();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const sendMessage = vi.fn().mockResolvedValue(undefined);
    const retryNow = vi.fn();
    const transportState = {
      failureReason: null,
      isBrowserOnline: true,
      phase: "recovering" as const,
      retryAttempt: 0
    };
    const transportStore: TransportMachine = {
      getState() {
        return transportState;
      },
      async publishReadState() {},
      retryNow,
      async sendInteractiveCallback() {},
      sendMessage,
      subscribe() {
        return () => {};
      }
    };

    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token",
      userId: "user_1"
    });

    chatStore.enqueueOptimisticMessage({
      attachments: [],
      content: "Do not reconnect me",
      deviceId: "browser-device-1",
      id: "c_failed_unprovisioned_recovering",
      sessionKey: "agent:main:clawline:flynn:side",
      timestamp: 1_764_201_200_085,
      wireAttachments: []
    });
    chatStore.markMessageFailed("c_failed_unprovisioned_recovering");

    render(
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportStore}>
            <MessageList
              messages={chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:side"]}
            />
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Retry" }));

    expect(retryNow).not.toHaveBeenCalled();
    expect(sendMessage).not.toHaveBeenCalled();
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:flynn:side"][0].delivery
    ).toBe("failed");
  });

  it("flows short messages side-by-side and wraps long content to a new row", () => {
    renderMessageList([
      {
        id: "s_flow_short_assistant",
        role: "assistant",
        content: "Want tea?",
        timestamp: 1_764_201_200_060,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      },
      {
        id: "s_flow_short_user",
        role: "user",
        content: "Yes please!",
        timestamp: 1_764_201_200_061,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server"
      },
      {
        id: "s_flow_long",
        role: "assistant",
        content:
          "This longer bubble should break onto its own row so the flow layout keeps the reading rhythm clear instead of trying to squeeze everything into one horizontal strip.",
        timestamp: 1_764_201_200_062,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      }
    ]);

    const shortAssistantRow = screen
      .getByTestId("message-s_flow_short_assistant")
      .closest<HTMLElement>(".message-list-row");
    const shortUserRow = screen
      .getByTestId("message-s_flow_short_user")
      .closest<HTMLElement>(".message-list-row");
    const longRow = screen
      .getByTestId("message-s_flow_long")
      .closest<HTMLElement>(".message-list-row");

    expect(shortAssistantRow).not.toBeNull();
    expect(shortUserRow).not.toBeNull();
    expect(longRow).not.toBeNull();
    expect(shortAssistantRow!.style.top).toBe(shortUserRow!.style.top);
    expect(Number.parseFloat(shortUserRow!.style.left)).toBeGreaterThan(
      Number.parseFloat(shortAssistantRow!.style.left)
    );
    expect(Number.parseFloat(longRow!.style.top)).toBeGreaterThan(
      Number.parseFloat(shortAssistantRow!.style.top)
    );
    expect(longRow!.style.left).toBe("0px");
  });

  it("flows medium messages side-by-side when they fit on the row", () => {
    renderMessageList([
      {
        id: "s_flow_medium_1",
        role: "user",
        content: "Pulled the latest notes this morning.",
        timestamp: 1_764_201_200_063,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server"
      },
      {
        id: "s_flow_medium_2",
        role: "user",
        content: "Sent the draft reply to Chris.",
        timestamp: 1_764_201_200_064,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server"
      },
      {
        id: "s_flow_medium_3",
        role: "assistant",
        content: "Queued the follow-up for this afternoon.",
        timestamp: 1_764_201_200_065,
        streaming: false,
        sessionKey: "agent:main:clawline:flynn:main",
        attachments: [],
        delivery: "server",
        sender: "Assistant"
      }
    ]);

    const firstRow = screen
      .getByTestId("message-s_flow_medium_1")
      .closest<HTMLElement>(".message-list-row");
    const secondRow = screen
      .getByTestId("message-s_flow_medium_2")
      .closest<HTMLElement>(".message-list-row");
    const thirdRow = screen
      .getByTestId("message-s_flow_medium_3")
      .closest<HTMLElement>(".message-list-row");

    expect(firstRow).not.toBeNull();
    expect(secondRow).not.toBeNull();
    expect(thirdRow).not.toBeNull();
    expect(firstRow!.style.top).toBe(secondRow!.style.top);
    expect(Number.parseFloat(secondRow!.style.left)).toBeGreaterThan(
      Number.parseFloat(firstRow!.style.left)
    );
    expect(Number.parseFloat(thirdRow!.style.top) - Number.parseFloat(firstRow!.style.top))
      .toBeLessThanOrEqual(120);
  });

  it("renders markdown blocks in source order", () => {
    renderMessageList([RICH_MESSAGE]);

    const bubble = screen.getByTestId("message-s_rich");
    const markdown = bubble.querySelector(".message-markdown");
    expect(markdown).not.toBeNull();

    const children = Array.from(markdown?.children ?? []).map((child) => child.tagName);
    expect(children).toEqual(["P", "PRE", "P", "TABLE"]);
    expect(within(bubble).getByText("Intro paragraph.")).toBeInTheDocument();
    expect(within(bubble).getByText("console.log('hi');")).toBeInTheDocument();
    expect(within(bubble).getByText("After code.")).toBeInTheDocument();
    expect(within(bubble).getByRole("table")).toBeInTheDocument();
  });

  it("opens detailed messages in an expanded overlay", () => {
    renderMessageList([
      {
        ...RICH_MESSAGE,
        id: "s_rich_truncated",
        content: `${RICH_MESSAGE.content}\n\n${"More detail. ".repeat(90)}`
      }
    ]);

    fireEvent.click(screen.getByRole("button"));

    const dialog = screen.getByRole("dialog", { name: "Expanded message" });
    expect(within(dialog).getByText("Expanded view")).toBeInTheDocument();
    expect(within(dialog).getByText("console.log('hi');")).toBeInTheDocument();
    expect(within(dialog).getByRole("table")).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole("button", { name: "Close expanded message" }));
    expect(screen.queryByRole("dialog", { name: "Expanded message" })).not.toBeInTheDocument();
  });

  it("renders interactive HTML attachments in both the bubble and expanded overlay", () => {
    renderMessageList([
      {
        ...RICH_MESSAGE,
        id: "s_html_overlay",
        content: `${RICH_MESSAGE.content}\n\n${"More detail. ".repeat(90)}`,
        attachments: [
          {
            type: "document",
            mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
            data: btoa(
              JSON.stringify({
                version: 1,
                html: "<body><p>Interactive overlay</p></body>",
                metadata: {
                  title: "Interactive Demo",
                  height: "auto",
                  maxHeight: 360
                }
              })
            )
          }
        ]
      }
    ]);

    const inlineFrame = screen.getByTestId("interactive-html-frame-s_html_overlay");
    expect(inlineFrame).toHaveAttribute("sandbox", "allow-scripts");

    fireEvent.click(screen.getByTestId("message-s_html_overlay"));

    const dialog = screen.getByRole("dialog", { name: "Expanded message" });
    const expandedFrame = within(dialog).getByTestId("interactive-html-frame-s_html_overlay");
    expect(expandedFrame).toHaveAttribute("sandbox", "allow-scripts");
  });

  it("renders image, audio, video, and file attachments", async () => {
    renderMessageList([ATTACHMENT_MESSAGE]);

    expect(await screen.findByAltText("attachment")).toBeInTheDocument();
    expect(await screen.findByLabelText("note.mp3")).toBeInTheDocument();
    expect(await screen.findByLabelText("demo.mp4")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Download report.pdf" })).toBeInTheDocument();
  });

  it("renders link cards for visible message links but not code-block URLs", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const value = input instanceof URL ? input.toString() : String(input);
        if (value === "https://example.com/docs") {
          return new Response(
            [
              "<html><head>",
              '<meta property="og:title" content="Documentation" />',
              '<meta property="og:description" content="Setup guide" />',
              '<meta property="og:image" content="https://example.com/preview.png" />',
              "</head><body></body></html>"
            ].join(""),
            {
              headers: {
                "content-type": "text/html"
              },
              status: 200
            }
          );
        }
        if (value === "https://openai.com/research") {
          return new Response(
            [
              "<html><head>",
              "<title>OpenAI Research</title>",
              '<meta name="description" content="Research index" />',
              "</head><body></body></html>"
            ].join(""),
            {
              headers: {
                "content-type": "text/html"
              },
              status: 200
            }
          );
        }

        return new Response(null, { status: 404 });
      })
    );

    renderMessageList([LINK_MESSAGE]);

    const cards = await screen.findByText("EXAMPLE.COM");
    const cardSurface = cards.closest(".message-link-cards");
    expect(cardSurface).not.toBeNull();

    const linkCards = Array.from(
      (cardSurface as HTMLElement).querySelectorAll<HTMLAnchorElement>(".message-link-card")
    );
    expect(linkCards.map((card) => card.href)).toEqual([
      "https://example.com/docs",
      "https://openai.com/research"
    ]);
    expect(await within(linkCards[0]!).findByText("Documentation")).toBeInTheDocument();
    expect(await within(linkCards[0]!).findByText("Setup guide")).toBeInTheDocument();
    expect(await within(linkCards[1]!).findByText("OpenAI Research")).toBeInTheDocument();
    expect(linkCards.some((card) => card.href.includes("in-code"))).toBe(false);
  });

  it("virtualizes large transcripts while keeping deep messages reachable", async () => {
    renderMessageList(Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)));

    const list = screen.getByTestId("message-list");
    const initialRows = list.querySelectorAll<HTMLElement>('[data-testid^="message-s_bulk_"]');
    expect(initialRows.length).toBeGreaterThan(0);
    expect(initialRows.length).toBeLessThan(30);
    expect(screen.queryByTestId("message-s_bulk_240")).not.toBeInTheDocument();

    fireEvent.scroll(list, { target: { scrollTop: 100_000 } });

    expect(await screen.findByTestId("message-s_bulk_240")).toBeInTheDocument();
    expect(screen.queryByTestId("message-s_bulk_1")).not.toBeInTheDocument();
  });

  it("restores persisted scroll position for the selected session", async () => {
    renderMessageListWithProps({
      messages: Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)),
      rememberedScrollState: {
        offsetTop: 100_000,
        stickToBottom: false
      },
      sessionKey: "agent:main:clawline:flynn:main"
    });

    expect(await screen.findByTestId("message-s_bulk_240")).toBeInTheDocument();
    expect(screen.queryByTestId("message-s_bulk_1")).not.toBeInTheDocument();
  });

  it("does not force bottom restoration while a user wheel scroll is active", async () => {
    const animationFrames: FrameRequestCallback[] = [];
    vi.stubGlobal(
      "requestAnimationFrame",
      vi.fn((callback: FrameRequestCallback) => {
        animationFrames.push(callback);
        return animationFrames.length;
      })
    );
    vi.stubGlobal("cancelAnimationFrame", vi.fn());

    renderMessageListWithProps({
      messages: Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)),
      rememberedScrollState: {
        offsetTop: Number.MAX_SAFE_INTEGER,
        stickToBottom: true
      },
      sessionKey: "agent:main:clawline:flynn:main"
    });

    const list = screen.getByTestId("message-list");
    Object.defineProperty(list, "scrollHeight", { configurable: true, value: 24_000 });
    Object.defineProperty(list, "clientHeight", { configurable: true, value: 800 });
    list.scrollTop = 18_000;

    fireEvent.wheel(list, { deltaY: -700 });
    fireEvent.scroll(list, { target: { scrollTop: 17_300 } });

    await act(async () => {
      animationFrames.splice(0).forEach((callback) => callback(0));
    });

    expect(list.scrollTop).toBe(17_300);
  });

  it("anchors to the first unread message before unread clears", async () => {
    renderMessageListWithProps({
      messages: Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)),
      sessionKey: "agent:main:clawline:flynn:main",
      unreadAnchorMessageId: "s_bulk_200"
    });

    expect(await screen.findByTestId("message-s_bulk_200")).toBeInTheDocument();
    expect(screen.queryByTestId("message-s_bulk_1")).not.toBeInTheDocument();
  });

  it("anchors when unread state arrives after initial session restoration", async () => {
    const authStore = createAuthSessionStore();
    const chatStore = createChatDomainStore({
      persistence: createMemoryChatPersistence()
    });
    const transportState = {
      failureReason: null,
      isBrowserOnline: true,
      phase: "live" as const,
      retryAttempt: 0
    };
    const transportStore: TransportMachine = {
      getState() {
        return transportState;
      },
      async publishReadState() {},
      retryNow() {},
      async sendInteractiveCallback() {},
      async sendMessage() {},
      subscribe() {
        return () => {};
      }
    };
    authStore.storePairingSession({
      claimedName: "Desk Browser",
      deviceId: "browser-device-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token",
      userId: "user_1"
    });
    const onUnreadAnchorConsumed = vi.fn();
    const messages = Array.from({ length: 240 }, (_, index) => makeMessage(index + 1));

    const view = render(
      <SettingsStoreProvider value={createSettingsStore()}>
        <AuthSessionStoreProvider value={authStore}>
          <ChatDomainStoreProvider value={chatStore}>
            <TransportMachineProvider value={transportStore}>
              <MessageList
                messages={messages}
                onUnreadAnchorConsumed={onUnreadAnchorConsumed}
                sessionKey="agent:main:clawline:flynn:main"
                unreadAnchorMessageId={null}
              />
            </TransportMachineProvider>
          </ChatDomainStoreProvider>
        </AuthSessionStoreProvider>
      </SettingsStoreProvider>
    );

    view.rerender(
      <SettingsStoreProvider value={createSettingsStore()}>
        <AuthSessionStoreProvider value={authStore}>
          <ChatDomainStoreProvider value={chatStore}>
            <TransportMachineProvider value={transportStore}>
              <MessageList
                messages={messages}
                onUnreadAnchorConsumed={onUnreadAnchorConsumed}
                sessionKey="agent:main:clawline:flynn:main"
                unreadAnchorMessageId="s_bulk_200"
              />
            </TransportMachineProvider>
          </ChatDomainStoreProvider>
        </AuthSessionStoreProvider>
      </SettingsStoreProvider>
    );

    expect(await screen.findByTestId("message-s_bulk_200")).toBeInTheDocument();
    expect(onUnreadAnchorConsumed).toHaveBeenCalledWith("s_bulk_200");
  });

  it("shows a jump-to-latest affordance when scrolled away from bottom", async () => {
    renderMessageListWithProps({
      messages: Array.from({ length: 240 }, (_, index) => makeMessage(index + 1)),
      sessionKey: "agent:main:clawline:flynn:main"
    });

    const list = screen.getByTestId("message-list");
    Object.defineProperty(list, "scrollHeight", { configurable: true, value: 24_000 });
    Object.defineProperty(list, "clientHeight", { configurable: true, value: 800 });
    fireEvent.scroll(list, { target: { scrollTop: 20_000 } });

    expect(await screen.findByTestId("scroll-to-bottom-button")).toBeInTheDocument();
  });

  it("keeps short transcripts at bottom during overscroll attempts", async () => {
    renderMessageListWithProps({
      messages: [makeMessage(1), makeMessage(2)],
      sessionKey: "agent:main:clawline:flynn:main"
    });

    const list = screen.getByTestId("message-list");
    Object.defineProperty(list, "scrollHeight", { configurable: true, value: 420 });
    Object.defineProperty(list, "clientHeight", { configurable: true, value: 800 });

    fireEvent.scroll(list, { target: { scrollTop: -80 } });

    expect(list.scrollTop).toBe(0);
    expect(screen.queryByTestId("scroll-to-bottom-button")).not.toBeInTheDocument();
  });

  it("shows the typing indicator from in-flight session status", async () => {
    renderMessageListWithProps({
      messages: [],
      sessionKey: "agent:main:clawline:flynn:main",
      sessionStatus: {
        sessionKey: "agent:main:clawline:flynn:main",
        run: {
          state: "running"
        },
        capabilities: {
          cancelCurrentRun: { supported: true }
        }
      }
    });

    expect(await screen.findByTestId("typing-indicator")).toBeInTheDocument();
  });

  it("anchors cancel confirmation to the typing indicator before typed cancellation", async () => {
    const onCancelCurrentPrompt = vi.fn();
    renderMessageListWithProps({
      messages: [makeMessage(1)],
      onCancelCurrentPrompt,
      sessionKey: "agent:main:clawline:flynn:main",
      sessionStatus: {
        sessionKey: "agent:main:clawline:flynn:main",
        run: {
          state: "running"
        },
        capabilities: {
          cancelCurrentRun: { supported: true }
        }
      }
    });

    fireEvent.click(await screen.findByTestId("typing-indicator"));
    expect(await screen.findByTestId("typing-cancel-popover")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));

    expect(onCancelCurrentPrompt).toHaveBeenCalledWith("agent:main:clawline:flynn:main");
  });

  it("opens typing cancellation with Cmd-period and dismisses with Escape", async () => {
    const onCancelCurrentPrompt = vi.fn();
    renderMessageListWithProps({
      messages: [makeMessage(1)],
      onCancelCurrentPrompt,
      sessionKey: "agent:main:clawline:flynn:main",
      sessionStatus: {
        sessionKey: "agent:main:clawline:flynn:main",
        run: {
          state: "queued"
        },
        capabilities: {
          cancelCurrentRun: { supported: true }
        }
      }
    });

    fireEvent.keyDown(window, { key: ".", metaKey: true });
    expect(await screen.findByTestId("typing-cancel-popover")).toBeInTheDocument();

    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByTestId("typing-cancel-popover")).not.toBeInTheDocument();

    fireEvent.keyDown(window, { key: ".", metaKey: true });
    expect(await screen.findByTestId("typing-cancel-popover")).toBeInTheDocument();

    screen.getByRole("button", { name: "Assistant is typing. Cancel current prompt" }).focus();
    fireEvent.keyDown(window, { key: "Enter" });
    expect(onCancelCurrentPrompt).toHaveBeenCalledWith("agent:main:clawline:flynn:main");
  });

  it("renders interactive session footer controls from session status", async () => {
    const onSessionControlSelected = vi.fn();
    renderMessageListWithProps({
      messages: [makeMessage(1)],
      onSessionControlSelected,
      sessionKey: "agent:main:clawline:flynn:main",
      sessionStatus: {
        sessionKey: "agent:main:clawline:flynn:main",
        display: {
          model: "gpt-5.5",
          thinkingLevel: "medium",
          fastMode: true
        },
        capabilities: {
          setModel: { supported: true },
          setThinking: { supported: true },
          setFastMode: { supported: true }
        },
        modelCatalog: {
          available: true,
          models: [
            {
              ref: "openai/gpt-5.5",
              name: "gpt-5.5"
            },
            {
              ref: "openai/gpt-5.4",
              name: "gpt-5.4"
            }
          ]
        }
      }
    });

    expect(await screen.findByTestId("session-status-footer")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("gpt-5.5"), {
      target: { value: "1" }
    });

    expect(onSessionControlSelected).toHaveBeenCalledWith(
      "agent:main:clawline:flynn:main",
      "set_model",
      "openai/gpt-5.4",
      undefined
    );
  });

  it("renders read-only fast mode status when mutation is unsupported", async () => {
    renderMessageListWithProps({
      messages: [makeMessage(1)],
      sessionKey: "agent:main:clawline:flynn:main",
      sessionStatus: {
        sessionKey: "agent:main:clawline:flynn:main",
        display: {
          fastMode: false
        },
        capabilities: {
          setFastMode: {
            supported: false,
            reason: "read_only"
          }
        }
      }
    });

    const fastModeControl = await screen.findByLabelText("Fast off");
    expect(fastModeControl).toBeDisabled();
    expect(fastModeControl).toHaveTextContent("Off");
  });
});
