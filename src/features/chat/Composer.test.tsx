import { readFileSync } from "node:fs";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore
} from "../../runtime/auth/authSessionStore";
import {
  ChatDomainStoreProvider,
  createChatDomainStore
} from "../../runtime/chat/chatDomainStore";
import { createMemoryChatPersistence } from "../../runtime/persistence/indexedDbChatPersistence";
import type {
  TransportMachine,
  TransportPhase
} from "../../runtime/transport/transportMachine";
import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import { TransportMachineProvider } from "../../runtime/transport/transportMachine";
import type { SessionProvisioningState } from "../streams/provisioning";
import { Composer } from "./Composer";

function renderComposer({
  phase = "live" as const,
  provisioningState = "ready" as const,
  retryNow = vi.fn(),
  sendMessage = vi.fn().mockResolvedValue(undefined),
  sessionKey = "agent:main:clawline:user_1:main",
  streams = []
}: {
  phase?: TransportPhase;
  provisioningState?: SessionProvisioningState;
  retryNow?: TransportMachine["retryNow"];
  sendMessage?: TransportMachine["sendMessage"];
  sessionKey?: string;
  streams?: StreamRecord[];
} = {}) {
  const authStore = createAuthSessionStore();
  const chatStore = createChatDomainStore({
    persistence: createMemoryChatPersistence()
  });
  const transportState = {
    failureReason: null,
    isBrowserOnline: true,
    phase,
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
  let currentStreams = streams;

  function renderTree(input: {
    provisioningState: SessionProvisioningState;
    sessionKey?: string;
  }) {
    return (
      <AuthSessionStoreProvider value={authStore}>
        <ChatDomainStoreProvider value={chatStore}>
          <TransportMachineProvider value={transportStore}>
            <Composer
              provisioningState={input.provisioningState}
              sessionKey={input.sessionKey}
              streams={currentStreams}
            />
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    );
  }

  const renderResult = render(
    renderTree({
      provisioningState,
      sessionKey
    })
  );

  return {
    chatStore,
    renderResult,
    rerenderComposer(input: {
      provisioningState?: SessionProvisioningState;
      sessionKey?: string;
      streams?: StreamRecord[];
    }) {
      currentStreams = input.streams ?? currentStreams;
      renderResult.rerender(
        renderTree({
          provisioningState: input.provisioningState ?? provisioningState,
          sessionKey: input.sessionKey ?? sessionKey
        })
      );
    },
    retryNow,
    sendMessage
  };
}

describe("Composer", () => {
  beforeEach(() => {
    vi.stubGlobal("requestAnimationFrame", ((callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    }) as typeof requestAnimationFrame);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("auto-resizes the textarea and allows Escape to dismiss focus", async () => {
    renderComposer();

    const textarea = screen.getByLabelText("Message");
    Object.defineProperty(textarea, "scrollHeight", {
      configurable: true,
      get: () => 180
    });

    fireEvent.change(textarea, { target: { value: "Expanded draft" } });

    await waitFor(() => {
      expect(textarea).toHaveStyle({ height: "140px" });
    });

    textarea.focus();
    expect(textarea).toHaveFocus();

    fireEvent.keyDown(textarea, { key: "Escape" });

    expect(textarea).not.toHaveFocus();
  });

  it("submits with Enter and keeps the composer focused for continued typing", async () => {
    const { chatStore, sendMessage } = renderComposer();
    const textarea = screen.getByLabelText("Message");

    textarea.focus();
    fireEvent.change(textarea, { target: { value: "Hello from the keyboard" } });
    fireEvent.keyDown(textarea, { key: "Enter" });

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledWith({
        attachments: [],
        content: "Hello from the keyboard",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:main"
      });
    });

    expect(textarea).toHaveFocus();
    expect(textarea).toHaveValue("");
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toHaveLength(1);
  });

  it("submits when the send button is tapped", async () => {
    const { sendMessage } = renderComposer();
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "Hello from the send button" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledWith({
        attachments: [],
        content: "Hello from the send button",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:main"
      });
    });
  });

  it("resolves a leading mention with Tab and sends only to the destination chat", async () => {
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      },
      {
        adopted: false,
        createdAt: 11,
        displayName: "Side Thread",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 1,
        sessionKey: "agent:main:clawline:user_1:side",
        updatedAt: 11
      }
    ];
    const { chatStore, sendMessage } = renderComposer({ streams });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@side" } });

    expect(screen.getByRole("listbox", { name: "Mention destination" }))
      .toBeInTheDocument();
    expect(screen.getByRole("option", { name: /Side Thread/i })).toBeInTheDocument();
    expect(screen.queryByRole("option", { name: /Personal/i })).not.toBeInTheDocument();

    fireEvent.keyDown(textarea, { key: "Tab" });
    expect(screen.getByTestId("composer-mention-chip")).toHaveTextContent(
      "Side Thread"
    );

    fireEvent.change(textarea, { target: { value: "Please check this" } });
    fireEvent.keyDown(textarea, { key: "Enter" });

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledWith({
        attachments: [],
        content: "Please check this",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:side"
      });
    });
    expect(await screen.findByRole("status")).toHaveTextContent("Sent to Side Thread");

    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toBeUndefined();
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:side"]
    ).toHaveLength(1);
  });

  it("lists every eligible chat for bare at-sign and keeps the popup scroll-contained", () => {
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      },
      ...Array.from({ length: 8 }, (_, index) => ({
        adopted: false,
        createdAt: 11 + index,
        displayName: `Project Room ${index + 1}`,
        isBuiltIn: false,
        kind: "custom",
        orderIndex: index + 1,
        sessionKey: `agent:main:clawline:user_1:room_${index + 1}`,
        updatedAt: 11 + index
      }))
    ];
    renderComposer({ streams });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@" } });

    const options = screen.getAllByRole("option");
    expect(options).toHaveLength(8);
    expect(screen.queryByRole("option", { name: /Personal/i })).not.toBeInTheDocument();
    expect(screen.getByRole("option", { name: /Project Room 1/i })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: /Project Room 8/i })).toBeInTheDocument();

    const styleText = readFileSync("src/app/styles.css", "utf8");
    expect(styleText).toContain(".composer-mention-picker");
    expect(styleText).toContain("bottom: calc(100% + 0.28rem);");
    expect(styleText).toContain("overflow: auto;");
    expect(styleText).toContain("overscroll-behavior: contain;");
  });

  it("moves the leading mention picker highlight with ArrowUp and ArrowDown", async () => {
    const scrollIntoView = vi.fn();
    const originalScrollIntoView = HTMLElement.prototype.scrollIntoView;
    HTMLElement.prototype.scrollIntoView = scrollIntoView;
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      },
      {
        adopted: false,
        createdAt: 11,
        displayName: "Side Thread",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 1,
        sessionKey: "agent:main:clawline:user_1:side",
        updatedAt: 11
      },
      {
        adopted: false,
        createdAt: 12,
        displayName: "Dictation",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 2,
        sessionKey: "agent:main:clawline:user_1:dictation",
        updatedAt: 12
      }
    ];
    renderComposer({ streams });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@" } });
    const sideOption = screen.getByRole("option", { name: /Side Thread/i });
    const dictationOption = screen.getByRole("option", { name: /Dictation/i });
    expect(sideOption).toHaveAttribute("aria-selected", "true");
    expect(dictationOption).toHaveAttribute("aria-selected", "false");

    fireEvent.keyDown(textarea, { key: "ArrowDown" });
    expect(sideOption).toHaveAttribute("aria-selected", "false");
    expect(dictationOption).toHaveAttribute("aria-selected", "true");
    expect(scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });

    fireEvent.keyDown(textarea, { key: "Tab" });
    expect(screen.getByTestId("composer-mention-chip")).toHaveTextContent(
      "Dictation"
    );

    fireEvent.click(screen.getByRole("button", { name: "Remove Dictation mention" }));
    fireEvent.change(textarea, { target: { value: "@" } });
    fireEvent.keyDown(textarea, { key: "ArrowDown" });
    fireEvent.keyDown(textarea, { key: "ArrowUp" });
    expect(screen.getByRole("option", { name: /Side Thread/i })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    expect(screen.getByRole("option", { name: /Dictation/i })).toHaveAttribute(
      "aria-selected",
      "false"
    );
    HTMLElement.prototype.scrollIntoView = originalScrollIntoView;
  });

  it("resolves the highlighted leading mention with Enter before submitting", async () => {
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      },
      {
        adopted: false,
        createdAt: 11,
        displayName: "Side Thread",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 1,
        sessionKey: "agent:main:clawline:user_1:side",
        updatedAt: 11
      },
      {
        adopted: false,
        createdAt: 12,
        displayName: "Dictation",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 2,
        sessionKey: "agent:main:clawline:user_1:dictation",
        updatedAt: 12
      }
    ];
    const { sendMessage } = renderComposer({ streams });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@" } });
    fireEvent.keyDown(textarea, { key: "ArrowDown" });
    fireEvent.keyDown(textarea, { key: "Enter" });

    expect(sendMessage).not.toHaveBeenCalled();
    expect(screen.getByTestId("composer-mention-chip")).toHaveTextContent(
      "Dictation"
    );
    expect(screen.queryByRole("listbox", { name: "Mention destination" }))
      .not.toBeInTheDocument();

    fireEvent.change(textarea, { target: { value: "Please check this" } });
    fireEvent.keyDown(textarea, { key: "Enter" });

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledWith({
        attachments: [],
        content: "Please check this",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:dictation"
      });
    });
  });

  it("keeps ArrowUp and ArrowDown inside an empty leading mention picker", async () => {
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      }
    ];
    renderComposer({ streams });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@" } });
    expect(fireEvent.keyDown(textarea, { key: "ArrowDown" })).toBe(false);
    expect(fireEvent.keyDown(textarea, { key: "ArrowUp" })).toBe(false);
    expect(screen.getByText("No matching sessions")).toBeInTheDocument();
  });

  it("submits unresolved leading mention text normally to the current chat", async () => {
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      },
      {
        adopted: false,
        createdAt: 11,
        displayName: "Side Thread",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 1,
        sessionKey: "agent:main:clawline:user_1:side",
        updatedAt: 11
      }
    ];
    const { sendMessage } = renderComposer({ streams });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@side normal text" } });
    fireEvent.keyDown(textarea, { key: "Enter" });

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledWith({
        attachments: [],
        content: "@side normal text",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:main"
      });
    });
  });

  it("reports cross-chat send failure in the initiating composer without echoing into the current chat", async () => {
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      },
      {
        adopted: false,
        createdAt: 11,
        displayName: "Side Thread",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 1,
        sessionKey: "agent:main:clawline:user_1:side",
        updatedAt: 11
      }
    ];
    const { chatStore, sendMessage } = renderComposer({
      sendMessage: vi.fn().mockRejectedValue(new Error("offline")),
      streams
    });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@side" } });
    fireEvent.keyDown(textarea, { key: "Tab" });
    fireEvent.change(textarea, { target: { value: "Please check this" } });
    fireEvent.keyDown(textarea, { key: "Enter" });

    await waitFor(() => {
      expect(screen.getByText("Message send failed.")).toBeInTheDocument();
    });
    expect(sendMessage).toHaveBeenCalledWith({
      attachments: [],
      content: "Please check this",
      id: expect.stringMatching(/^c_/),
      sessionKey: "agent:main:clawline:user_1:side"
    });
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:main"]
    ).toBeUndefined();
    expect(
      chatStore.getState().messagesBySessionKey["agent:main:clawline:user_1:side"]?.[0]
        ?.delivery
    ).toBe("failed");
  });

  it("fails a disappeared resolved destination through the composer send-error path", async () => {
    const streams: StreamRecord[] = [
      {
        adopted: false,
        createdAt: 10,
        displayName: "Personal",
        isBuiltIn: true,
        kind: "main",
        orderIndex: 0,
        sessionKey: "agent:main:clawline:user_1:main",
        updatedAt: 10
      },
      {
        adopted: false,
        createdAt: 11,
        displayName: "Side Thread",
        isBuiltIn: false,
        kind: "custom",
        orderIndex: 1,
        sessionKey: "agent:main:clawline:user_1:side",
        updatedAt: 11
      }
    ];
    const { chatStore, rerenderComposer, sendMessage } = renderComposer({ streams });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "@side" } });
    fireEvent.keyDown(textarea, { key: "Tab" });
    rerenderComposer({ streams: [streams[0]] });
    fireEvent.change(textarea, { target: { value: "Please check this" } });
    fireEvent.keyDown(textarea, { key: "Enter" });

    await waitFor(() => {
      expect(screen.getByText("Message send failed.")).toBeInTheDocument();
    });
    expect(sendMessage).not.toHaveBeenCalled();
    expect(chatStore.getState().messagesBySessionKey).toEqual({});
  });

  it("submits on primary pointer-down while focused without waiting for click", async () => {
    const { sendMessage } = renderComposer();
    const textarea = screen.getByLabelText("Message");
    const sendButton = screen.getByRole("button", { name: "Send" });

    textarea.focus();
    fireEvent.change(textarea, { target: { value: "Hello from round send" } });
    fireEvent.pointerDown(sendButton, { button: 0, pointerType: "touch" });
    fireEvent.click(sendButton);

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledTimes(1);
      expect(sendMessage).toHaveBeenCalledWith({
        attachments: [],
        content: "Hello from round send",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:main"
      });
    });
    expect(textarea).toHaveFocus();
  });

  it("does not swallow a later click when the pointer-down activation has no trailing click", async () => {
    const { sendMessage } = renderComposer();
    const textarea = screen.getByLabelText("Message");
    const sendButton = screen.getByRole("button", { name: "Send" });

    fireEvent.change(textarea, { target: { value: "Pointer send" } });
    fireEvent.pointerDown(sendButton, { button: 0, pointerType: "touch" });

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledTimes(1);
    });
    await new Promise((resolve) => window.setTimeout(resolve, 0));

    fireEvent.change(textarea, { target: { value: "Later click send" } });
    fireEvent.click(sendButton);

    await waitFor(() => {
      expect(sendMessage).toHaveBeenCalledTimes(2);
      expect(sendMessage).toHaveBeenLastCalledWith({
        attachments: [],
        content: "Later click send",
        id: expect.stringMatching(/^c_/),
        sessionKey: "agent:main:clawline:user_1:main"
      });
    });
  });

  it("does not submit from the keyboard before provisioning is ready", () => {
    const { chatStore, sendMessage } = renderComposer({
      provisioningState: "unavailable"
    });
    const textarea = screen.getByLabelText("Message");

    fireEvent.change(textarea, { target: { value: "Blocked keyboard send" } });
    fireEvent.keyDown(textarea, { key: "Enter" });

    expect(sendMessage).not.toHaveBeenCalled();
    expect(chatStore.getState().messagesBySessionKey).toEqual({});
  });

  it("does not finish a submit after provisioning changes during attachment preparation", async () => {
    let resolveUpload: ((response: Response) => void) | undefined;
    vi.stubGlobal(
      "fetch",
      vi.fn(
        () =>
          new Promise<Response>((resolve) => {
            resolveUpload = resolve;
          })
      )
    );
    const { chatStore, rerenderComposer, sendMessage } = renderComposer();
    const fileInput = document.querySelector<HTMLInputElement>("input[type='file']");
    expect(fileInput).not.toBeNull();

    fireEvent.change(fileInput as HTMLInputElement, {
      target: {
        files: [new File(["upload"], "notes.txt", { type: "text/plain" })]
      }
    });
    fireEvent.change(screen.getByLabelText("Message"), {
      target: { value: "Attachment send" }
    });
    fireEvent.keyDown(screen.getByLabelText("Message"), { key: "Enter" });

    await waitFor(() => {
      expect(resolveUpload).toBeDefined();
    });
    rerenderComposer({ provisioningState: "unavailable" });
    resolveUpload?.(
      new Response(
        JSON.stringify({
          assetId: "asset_1",
          mimeType: "text/plain",
          size: 6
        }),
        {
          headers: { "Content-Type": "application/json" },
          status: 200
        }
      )
    );

    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(chatStore.getState().messagesBySessionKey).toEqual({});
    expect(sendMessage).not.toHaveBeenCalled();
  });

  it("shows reconnecting and disconnected send button states", () => {
    const reconnecting = renderComposer({ phase: "recovering" });
    expect(screen.getByRole("button", { name: "Reconnecting" }))
      .toHaveAttribute("data-connection-state", "reconnecting");
    expect(screen.getByRole("button", { name: "Reconnecting" })).toBeDisabled();
    reconnecting.renderResult.unmount();

    renderComposer({ phase: "failed" });
    expect(screen.getByRole("button", { name: "Disconnected. Tap to reconnect." }))
      .toHaveAttribute("data-connection-state", "disconnected");
    expect(screen.getByRole("button", { name: "Disconnected. Tap to reconnect." })).toBeEnabled();
  });

  it("taps reconnect from the send button when disconnected", () => {
    const { retryNow, sendMessage } = renderComposer({ phase: "failed" });

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Hello" } });
    fireEvent.click(screen.getByRole("button", { name: "Disconnected. Tap to reconnect." }));

    expect(retryNow).toHaveBeenCalledTimes(1);
    expect(sendMessage).not.toHaveBeenCalled();
  });
});
