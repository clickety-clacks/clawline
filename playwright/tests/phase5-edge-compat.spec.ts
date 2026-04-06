import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

const MAIN_SESSION_KEY = "agent:main:clawline:flynn:main";

test.describe("Phase 5 Edge-on-Android compatibility", () => {
  test("send, viewport width, and keyboard-up scrolling stay usable on Edge Android", async ({
    browser
  }) => {
    const context = await browser.newContext({
      baseURL: "http://127.0.0.1:4173",
      hasTouch: true,
      userAgent:
        "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36 EdgA/125.0.2535.72",
      viewport: {
        width: 412,
        height: 915
      }
    });
    const page = await context.newPage();

    const transcript = Array.from({ length: 18 }, (_, index) => ({
      type: "message" as const,
      id: `s_edge_${index + 1}`,
      role: index % 4 === 0 ? ("user" as const) : ("assistant" as const),
      content:
        index === 0
          ? "Medium messages should stay inside the viewport on Edge Android."
          : `Scrollable message ${index + 1}\n\n${"detail ".repeat(26)}`,
      timestamp: 1_764_402_000_000 + index,
      streaming: false,
      sessionKey: MAIN_SESSION_KEY,
      attachments: []
    }));
    const { close, port, receivedClientMessages } = await startEdgeCompatServer(transcript);

    try {
      await page.addInitScript(() => {
        const listeners = new Map<string, Set<EventListener>>();
        let height = window.innerHeight;
        let offsetTop = 0;

        const visualViewport = {
          get width() {
            return window.innerWidth;
          },
          get height() {
            return height;
          },
          get offsetTop() {
            return offsetTop;
          },
          addEventListener(type: string, listener: EventListener) {
            const bucket = listeners.get(type) ?? new Set<EventListener>();
            bucket.add(listener);
            listeners.set(type, bucket);
          },
          removeEventListener(type: string, listener: EventListener) {
            listeners.get(type)?.delete(listener);
          }
        };

        const dispatch = (type: string) => {
          const event = new Event(type);
          for (const listener of listeners.get(type) ?? []) {
            listener.call(visualViewport, event);
          }
        };

        Object.defineProperty(window, "visualViewport", {
          configurable: true,
          get() {
            return visualViewport;
          }
        });

        Object.assign(window, {
          __setVisualViewportInsetForTest(nextInset: number) {
            height = Math.max(0, window.innerHeight - nextInset);
            offsetTop = 0;
            dispatch("resize");
            dispatch("scroll");
          }
        });
      });

      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.goto(`/chat/${MAIN_SESSION_KEY}`);

      const composer = page.getByLabel("Message");
      await composer.click();
      await composer.fill("Edge tap send");

      const sendButton = page.getByRole("button", { name: "Send" });
      await expect(sendButton).toBeEnabled();
      await sendButton.tap();

      await expect
        .poll(() => receivedClientMessages.at(-1)?.content ?? null)
        .toBe("Edge tap send");
      await expect(composer).toHaveValue("");

      await expect
        .poll(() =>
          page.getByTestId("message-list").evaluate((element) => {
            return element.scrollWidth <= element.clientWidth + 1;
          })
        )
        .toBe(true);

      await setVisualViewportInset(page, 280);
      await expect.poll(() => readKeyboardInset(page)).toBe("280px");

      await page.getByTestId("message-list").dispatchEvent("touchstart", {
        touches: [{ clientX: 260, clientY: 320, identifier: 1 }]
      });

      const scrollTopBefore = await page.getByTestId("message-list").evaluate((element) => {
        element.scrollTop = Math.max(0, element.scrollHeight - element.clientHeight - 320);
        element.dispatchEvent(new Event("scroll", { bubbles: true }));
        return Math.round(element.scrollTop);
      });

      await setVisualViewportInset(page, 280);
      await page.getByTestId("message-list").dispatchEvent("touchend", {
        changedTouches: [{ clientX: 260, clientY: 200, identifier: 1 }]
      });

      await expect
        .poll(() =>
          page.getByTestId("message-list").evaluate((element) => Math.round(element.scrollTop))
        )
        .toBe(scrollTopBefore);
    } finally {
      await context.close();
      await close();
    }
  });
});

async function startEdgeCompatServer(
  transcript: Array<{
    attachments: [];
    content: string;
    id: string;
    role: "assistant" | "user";
    sessionKey: string;
    streaming: boolean;
    timestamp: number;
    type: "message";
  }>
) {
  const port = 25_600 + Math.floor(Math.random() * 1_000);
  const server = createServer();
  const wss = new WebSocketServer({ server, path: "/ws" });
  const sockets = new Set<import("ws").WebSocket>();
  const receivedClientMessages: Array<{ content: string; id: string; sessionKey?: string }> = [];

  wss.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "auth") {
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            replayCount: transcript.length,
            sessionKeys: [MAIN_SESSION_KEY]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: false,
            sessionKeys: [MAIN_SESSION_KEY]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey: MAIN_SESSION_KEY,
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_402_000_000,
                updatedAt: 1_764_402_000_000,
                adopted: false
              }
            ]
          })
        );
        for (const message of transcript) {
          socket.send(JSON.stringify(message));
        }
        return;
      }

      if (payload.type === "message") {
        receivedClientMessages.push(payload as { content: string; id: string; sessionKey?: string });
        socket.send(JSON.stringify({ type: "ack", id: payload.id }));
        socket.send(
          JSON.stringify({
            type: "message",
            id: `server_${payload.id}`,
            role: "user",
            content: (payload as { content: string }).content,
            timestamp: Date.now(),
            streaming: false,
            deviceId: "browser-device-1",
            sessionKey: (payload as { sessionKey?: string }).sessionKey ?? MAIN_SESSION_KEY,
            attachments: []
          })
        );
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });

  return {
    close: async () => {
      await Promise.all(
        Array.from(sockets, (socket) => {
          socket.terminate();
          return Promise.resolve();
        })
      );
      server.closeAllConnections?.();
      await new Promise<void>((resolve, reject) => {
        wss.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          server.close((closeError) => {
            if (closeError) {
              reject(closeError);
              return;
            }
            resolve();
          });
        });
      });
    },
    port,
    receivedClientMessages
  };
}

function makeSession(port: number) {
  return {
    claimedName: "Flynn Browser",
    deviceId: "browser-device-1",
    isAdmin: false,
    serverUrl: `ws://127.0.0.1:${port}/ws`,
    token: "jwt-edge-token",
    userId: "user_flynn"
  };
}

async function setVisualViewportInset(page: import("@playwright/test").Page, inset: number) {
  await page.evaluate((nextInset) => {
    (
      window as typeof window & {
        __setVisualViewportInsetForTest?: (value: number) => void;
      }
    ).__setVisualViewportInsetForTest?.(nextInset);
  }, inset);
}

async function readKeyboardInset(page: import("@playwright/test").Page) {
  return page.evaluate(() => {
    return getComputedStyle(document.querySelector(".chat-layout")!).getPropertyValue(
      "--chat-keyboard-inset"
    ).trim();
  });
}
