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
import { TransportMachineProvider } from "../../runtime/transport/transportMachine";
import { Composer } from "./Composer";

function renderComposer({
  phase = "live" as const,
  retryNow = vi.fn(),
  sendMessage = vi.fn().mockResolvedValue(undefined)
}: {
  phase?: TransportPhase;
  retryNow?: TransportMachine["retryNow"];
  sendMessage?: TransportMachine["sendMessage"];
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
    retryNow,
    setSelectedSessionKey() {},
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

  const renderResult = render(
    <AuthSessionStoreProvider value={authStore}>
      <ChatDomainStoreProvider value={chatStore}>
        <TransportMachineProvider value={transportStore}>
          <Composer
            provisioningState="ready"
            sessionKey="agent:main:clawline:user_1:main"
          />
        </TransportMachineProvider>
      </ChatDomainStoreProvider>
    </AuthSessionStoreProvider>
  );

  return {
    chatStore,
    renderResult,
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
