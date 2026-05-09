import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test.describe("Phase 5 responsive and keyboard flow", () => {
  test("chat shell stays usable on iPad and mobile breakpoints", async ({ page }) => {
    const { close, port } = await startPhase5Server();

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      for (const appearance of ["dark", "light"] as const) {
        await page.setViewportSize({ height: 1180, width: 820 });
        await page.goto(`/chat/${MAIN_SESSION_KEY}`);
        await applyAppearance(page, appearance);
        await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();
        const dots = page.getByRole("button", { name: "Manage streams" });
        expect(
          await dots
            .locator(".stream-page-dot--active")
            .evaluate((element) => window.getComputedStyle(element).backgroundColor)
        ).toBe("rgb(107, 156, 107)");
        await expect(page.getByTestId("composer-input-bar")).toBeVisible();

        await expect(page.getByTestId("chat-layout")).toHaveScreenshot(
          `phase5-chat-shell-${appearance}.png`,
          { animations: "disabled" }
        );

        await dots.click();
        const popover = page.getByTestId("session-popover");
        await expect(popover).toBeVisible();
        await expect(popover.getByRole("button", { name: "Add stream" })).toBeVisible();
        await expect(popover.getByRole("button", { name: "Settings" })).toHaveCount(0);
        await expect(popover.getByRole("button", { name: "Retry" })).toHaveCount(0);
        const popoverBox = await popover.boundingBox();
        expect(popoverBox).not.toBeNull();
        expect(popoverBox!.width).toBeLessThan(820 * 0.52);
        expect(
          await popover.locator(".session-sheet-card-title").first().evaluate((element) => {
            return window.getComputedStyle(element).textAlign;
          })
        ).toBe("left");
        expect(
          await popover
            .locator(".session-sheet-card.active .session-sheet-card-indicator")
            .evaluate((element) => window.getComputedStyle(element).backgroundColor)
        ).toBe("rgb(107, 156, 107)");
        await expect(popover).toHaveScreenshot(`phase5-session-popover-${appearance}.png`, {
          animations: "disabled"
        });
        await page.mouse.click(12, 12);
        await expect(popover).toHaveCount(0);

        if (appearance === "dark") {
          await swipeChatPanel(page, { endX: 120, startX: 300, y: 360 });
          await expect(page.getByText("Responsive shell check")).toBeVisible();
          await expect(page).toHaveURL(new RegExp(`${SIDE_SESSION_KEY.replaceAll(":", "\\:")}$`));

          await swipeChatPanel(page, { endX: 300, startX: 120, y: 360 });
          await expect(page.getByText("Keyboard flow check")).toBeVisible();
          await expect(page).toHaveURL(new RegExp(`${MAIN_SESSION_KEY.replaceAll(":", "\\:")}$`));
        }
      }

      for (const viewport of [{ height: 1180, width: 820 }, { height: 844, width: 390 }]) {
        await page.setViewportSize(viewport);
        await page.goto(`/chat/${MAIN_SESSION_KEY}`);
        await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();
        expect(await page.getByTestId("session-popover").count()).toBe(0);

        const dots = page.getByRole("button", { name: "Manage streams" });
        await expect(page.getByTestId("composer-input-bar")).toBeVisible();

        await dots.click();
        const popover = page.getByTestId("session-popover");
        await expect(popover).toBeVisible();
        const popoverBox = await popover.boundingBox();
        expect(popoverBox).not.toBeNull();

        if (viewport.width > 500) {
          expect(popoverBox!.width).toBeLessThan(viewport.width * 0.52);
        } else {
          expect(popoverBox!.width).toBeGreaterThan(viewport.width * 0.78);
        }

        await expect(page.getByTestId("session-popover-list")).toBeVisible();
        await page.mouse.click(12, 12);
        await expect(popover).toHaveCount(0);

        if (viewport.width <= 390) {
          expect(
            await page.locator(".chat-floating-stack").evaluate((element) => {
              return window.getComputedStyle(element).justifyItems;
            })
          ).toBe("center");
          expect(
            await page.locator(".composer-input-bar").evaluate((element) => {
              return window.getComputedStyle(element).display;
            })
          ).toBe("grid");
          expect(
            await page.locator(".composer-input-bar").evaluate((element) => {
              return window.getComputedStyle(element).backgroundColor;
            })
          ).toBe("rgba(0, 0, 0, 0)");
          expect(
            await page.locator(".composer-input-field").evaluate((element) => {
              return window.getComputedStyle(element).backgroundColor;
            })
          ).not.toBe("rgba(0, 0, 0, 0)");
          const attachBox = await page.getByRole("button", { name: "Add attachment" }).boundingBox();
          const inputBox = await page.locator(".composer-input-field").boundingBox();
          const sendBox = await page.getByRole("button", { name: "Send" }).boundingBox();
          expect(attachBox).not.toBeNull();
          expect(inputBox).not.toBeNull();
          expect(sendBox).not.toBeNull();
          expect(inputBox!.x - (attachBox!.x + attachBox!.width)).toBeGreaterThan(8);
          expect(sendBox!.x - (inputBox!.x + inputBox!.width)).toBeGreaterThan(8);
        }
      }
    } finally {
      await close();
    }
  });

  test("composer supports keyboard send, newline, and dismiss flow", async ({ page }) => {
    const { close, port, receivedClientMessages } = await startPhase5Server();

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.setViewportSize({ height: 1180, width: 820 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();

      const focusOrder = await captureFocusOrder(page, 3);
      expect(focusOrder).toEqual([
        "Manage streams",
        "Add attachment",
        "Message"
      ]);

      await focusComposerWithKeyboard(page);

      await page.keyboard.type("Line one");
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type("Line two");
      await expect(page.getByLabel("Message")).toHaveValue("Line one\nLine two");

      await page.keyboard.press("Enter");

      await expect
        .poll(() => receivedClientMessages.at(-1)?.content ?? null)
        .toBe("Line one\nLine two");
      await expect(page.getByText("Line one")).toBeVisible();
      await expect(page.getByText("Line two")).toBeVisible();
      await expect(page.getByLabel("Message")).toHaveValue("");
      await expect(page.getByLabel("Message")).toBeFocused();

      await page.keyboard.type("Draft to dismiss");
      await page.keyboard.press("Escape");
      await expect(page.getByLabel("Message")).not.toBeFocused();
    } finally {
      await close();
    }
  });

  test("send button tap still sends while the composer is focused", async ({ browser }) => {
    const { close, port, receivedClientMessages } = await startPhase5Server();
    const context = await browser.newContext({
      hasTouch: true,
      isMobile: true,
      viewport: { height: 844, width: 390 }
    });
    const page = await context.newPage();

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      const composer = page.getByRole("textbox", { name: "Message" });
      await composer.click();
      await composer.fill("Tap send");

      const sendButton = page.getByRole("button", { name: "Send" });
      await expect(sendButton).toBeEnabled();
      await sendButton.tap();

      await expect
        .poll(() => receivedClientMessages.at(-1)?.content ?? null)
        .toBe("Tap send");
      await expect(page.getByText("Tap send")).toBeVisible();
    } finally {
      await context.close();
      await close();
    }
  });

  test("send button tap still sends after the keyboard is dismissed", async ({ browser }) => {
    const { close, port, receivedClientMessages } = await startPhase5Server();
    const context = await browser.newContext({
      hasTouch: true,
      isMobile: true,
      viewport: { height: 844, width: 390 }
    });
    const page = await context.newPage();

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      const composer = page.getByRole("textbox", { name: "Message" });
      await composer.click();
      await composer.fill("Tap send after blur");
      await page.keyboard.press("Escape");
      await expect(composer).not.toBeFocused();

      const sendButton = page.getByRole("button", { name: "Send" });
      await expect(sendButton).toBeEnabled();
      await sendButton.tap();

      await expect
        .poll(() => receivedClientMessages.at(-1)?.content ?? null)
        .toBe("Tap send after blur");
      await expect(page.getByText("Tap send after blur")).toBeVisible();
    } finally {
      await context.close();
      await close();
    }
  });

  test("message bubbles stay within the mobile viewport width", async ({ page }) => {
    const transcript = Array.from({ length: 6 }, (_, index) => ({
      type: "message" as const,
      id: `s_width_${index + 1}`,
      role: index % 2 === 0 ? "assistant" as const : "user" as const,
      content:
        index === 0
          ? "Medium messages should balance instead of stretching wide across the screen."
          : `Bubble width check ${index + 1}`,
      timestamp: 1_764_401_000_000 + index,
      streaming: false,
      sessionKey: MAIN_SESSION_KEY,
      attachments: []
    }));
    const { close, port } = await startPhase5Server({ mainTranscript: transcript });

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.setViewportSize({ height: 844, width: 390 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);

      const messageList = page.getByTestId("message-list");
      await expect(messageList).toBeVisible();
      await expect
        .poll(() =>
          messageList.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)
        )
        .toBe(true);
    } finally {
      await close();
    }
  });

  test("sending after switching chats from the popup targets the selected session", async ({
    page
  }) => {
    const { close, port, receivedClientMessages } = await startPhase5Server();

    try {
      await page.addInitScript((session) => {
        window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
        window.localStorage.setItem(
          "clawline-web:device-id",
          JSON.stringify(session.deviceId)
        );
      }, makeSession(port));

      await page.setViewportSize({ height: 844, width: 390 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);

      await page.getByRole("button", { name: "Manage streams" }).click();
      await page.getByRole("button", { name: /Side/ }).click();
      await expect(page).toHaveURL(new RegExp(`${SIDE_SESSION_KEY.replaceAll(":", "\\:")}$`));

      const composer = page.getByRole("textbox", { name: "Message" });
      await composer.fill("Send to side");
      await page.getByRole("button", { name: "Send" }).click();

      await expect
        .poll(() => receivedClientMessages.at(-1)?.sessionKey ?? null)
        .toBe(SIDE_SESSION_KEY);
      await expect(page.getByText("Send to side")).toBeVisible();
    } finally {
      await close();
    }
  });

  test("manage streams tap opens the popup without dismissing the keyboard", async ({ page }) => {
    const { close, port } = await startPhase5Server();

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

      await page.setViewportSize({ height: 844, width: 390 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      const composer = page.getByRole("textbox", { name: "Message" });
      await composer.click();
      await composer.fill("Keep keyboard open");
      await setVisualViewportInset(page, 280);
      await expect(composer).toBeFocused();

      await page.getByRole("button", { name: "Manage streams" }).click();

      const popover = page.getByTestId("session-popover");
      await expect(popover).toBeVisible();
      await expect(composer).toBeFocused();
      await expect
        .poll(async () => {
          const popoverBox = await popover.boundingBox();
          if (!popoverBox) {
            return null;
          }
          return Math.round(popoverBox.y + popoverBox.height);
        })
        .toBeLessThanOrEqual(844 - 280 - 12);
    } finally {
      await close();
    }
  });

  test("switching chats from the popup keeps the keyboard focused", async ({ page }) => {
    const { close, port } = await startPhase5Server();

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

      await page.setViewportSize({ height: 844, width: 390 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      const composer = page.getByRole("textbox", { name: "Message" });
      await composer.click();
      await composer.fill("Keep keyboard during chat switch");
      await setVisualViewportInset(page, 280);
      await expect(composer).toBeFocused();

      await page.getByRole("button", { name: "Manage streams" }).click();
      await expect(page.getByTestId("session-popover")).toBeVisible();
      await expect(composer).toBeFocused();

      await page.getByRole("button", { name: "Side" }).click();

      await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(SIDE_SESSION_KEY)}$`));
      await expect(page.getByTestId("session-popover")).toHaveCount(0);
      await expect(composer).toBeFocused();
    } finally {
      await close();
    }
  });

  test("sending with a mobile keyboard inset keeps the newest bubbles above the keyboard", async ({ page }) => {
    const { close, receivedClientMessages, port } = await startPhase5Server();

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

      await page.setViewportSize({ height: 844, width: 390 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      const composer = page.getByLabel("Message");
      await composer.click();
      await setVisualViewportInset(page, 280);

      await expect
        .poll(() => readKeyboardInset(page))
        .toBe("280px");

      await composer.fill("Latest bubble stays visible");
      await page.keyboard.press("Enter");

      await expect
        .poll(() => receivedClientMessages.at(-1)?.content ?? null)
        .toBe("Latest bubble stays visible");

      await setVisualViewportInset(page, 0);
      await setVisualViewportInset(page, 280);

      await expect(composer).toBeFocused();
      await expect(composer).toHaveValue("");
      await expect
        .poll(() => readKeyboardInset(page))
        .toBe("280px");
      await expect(page.getByText("Latest bubble stays visible")).toBeVisible();

      await expect
        .poll(async () => {
          const messageBox = await page.locator(".message-bubble--user").last().boundingBox();
          const composerBox = await page.getByTestId("composer-input-bar").boundingBox();

          if (!messageBox || !composerBox) {
            return null;
          }

          return Math.round(composerBox.y - (messageBox.y + messageBox.height));
        })
        .toBeGreaterThanOrEqual(8);
    } finally {
      await close();
    }
  });

  test("keyboard-up viewport changes do not block manual transcript scrolling", async ({ page }) => {
    const transcript = Array.from({ length: 18 }, (_, index) => ({
      type: "message" as const,
      id: `s_scroll_${index + 1}`,
      role: index % 4 === 0 ? "user" as const : "assistant" as const,
      content: `Scrollable message ${index + 1}\n\n${"detail ".repeat(28)}`,
      timestamp: 1_764_400_100_000 + index,
      streaming: false,
      sessionKey: MAIN_SESSION_KEY,
      attachments: []
    }));
    const { close, port } = await startPhase5Server({ mainTranscript: transcript });

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

      await page.setViewportSize({ height: 844, width: 390 });
      await page.goto(`/chat/${MAIN_SESSION_KEY}`);
      await expect(page.getByTestId("message-list")).toBeVisible();
      await expect(page.getByTestId("message-list")).toContainText("Scrollable message");

      const composer = page.getByLabel("Message");
      await composer.click();
      await setVisualViewportInset(page, 280);
      await expect.poll(() => readKeyboardInset(page)).toBe("280px");

      await page.getByTestId("message-list").dispatchEvent("touchstart", {
        touches: [{ clientX: 180, clientY: 320, identifier: 1 }]
      });

      const scrollTopBefore = await page.getByTestId("message-list").evaluate((element) => {
        element.scrollTop = Math.max(0, element.scrollHeight - element.clientHeight - 320);
        element.dispatchEvent(new Event("scroll", { bubbles: true }));
        return Math.round(element.scrollTop);
      });

      await setVisualViewportInset(page, 280);
      await page.getByTestId("message-list").dispatchEvent("touchend", {
        changedTouches: [{ clientX: 180, clientY: 200, identifier: 1 }]
      });

      await expect
        .poll(() =>
          page.getByTestId("message-list").evaluate((element) => Math.round(element.scrollTop))
        )
        .toBeGreaterThanOrEqual(scrollTopBefore);
    } finally {
      await close();
    }
  });
});

const MAIN_SESSION_KEY = "agent:main:clawline:flynn:main";
const SIDE_SESSION_KEY = "agent:main:clawline:flynn:side";

async function startPhase5Server(options?: {
  mainTranscript?: Array<{
    attachments: [];
    content: string;
    id: string;
    role: "assistant" | "user";
    sessionKey: string;
    streaming: boolean;
    timestamp: number;
    type: "message";
  }>;
}) {
  const port = 24_501 + Math.floor(Math.random() * 1_000);
  const server = createServer();
  const wss = new WebSocketServer({ server, path: "/ws" });
  const sockets = new Set<import("ws").WebSocket>();
  const receivedClientMessages: Array<{ content: string; id: string; sessionKey?: string }> = [];
  const mainTranscript = options?.mainTranscript ?? [
    {
      type: "message" as const,
      id: "s_phase5_1",
      role: "assistant" as const,
      content: "Keyboard flow check",
      timestamp: 1_764_400_000_200,
      streaming: false,
      sessionKey: MAIN_SESSION_KEY,
      attachments: []
    }
  ];

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
            replayCount: mainTranscript.length,
            sessionKeys: [MAIN_SESSION_KEY, SIDE_SESSION_KEY]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: false,
            sessionKeys: [MAIN_SESSION_KEY, SIDE_SESSION_KEY]
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
                createdAt: 1_764_400_000_000,
                updatedAt: 1_764_400_000_000,
                adopted: false
              },
              {
                sessionKey: SIDE_SESSION_KEY,
                displayName: "Side",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: 1_764_400_000_100,
                updatedAt: 1_764_400_000_100,
                adopted: false
              }
            ]
          })
        );
        for (const message of mainTranscript) {
          socket.send(JSON.stringify(message));
        }
        setTimeout(() => {
          if (socket.readyState !== socket.OPEN) {
            return;
          }
          socket.send(
            JSON.stringify({
              type: "message",
              id: "s_phase5_2",
              role: "assistant",
              content: "Responsive shell check",
              timestamp: 1_764_400_000_300,
              streaming: false,
              sessionKey: SIDE_SESSION_KEY,
              attachments: []
            })
          );
        }, 20);
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
      await Promise.resolve();
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
    token: "jwt-phase5-token",
    userId: "user_flynn"
  };
}

async function applyAppearance(
  page: import("@playwright/test").Page,
  appearance: "dark" | "light"
) {
  await page.waitForLoadState("domcontentloaded");
  await page.evaluate((mode) => {
    window.localStorage.setItem(
      "clawline-web:settings",
      JSON.stringify({
        appearance: mode,
        diagnostics: false,
        fontScale: "default"
      })
    );
    document.documentElement.dataset.appearance = mode;
  }, appearance);
  await page.reload();
}

async function focusComposerWithKeyboard(page: import("@playwright/test").Page) {
  for (let attempt = 0; attempt < 16; attempt += 1) {
    await page.keyboard.press("Tab");
    const activeId = await page.evaluate(() => {
      return (document.activeElement as HTMLElement | null)?.id ?? null;
    });
    if (activeId === "composer-input") {
      return;
    }
  }

  throw new Error("Failed to focus composer input with keyboard navigation");
}

async function swipeChatPanel(
  page: import("@playwright/test").Page,
  input: { endX: number; startX: number; y: number }
) {
  await page.getByTestId("chat-panel").evaluate((element, gesture) => {
    const start = new Event("touchstart", { bubbles: true, cancelable: true });
    Object.defineProperty(start, "touches", {
      value: [{ clientX: gesture.startX, clientY: gesture.y }]
    });
    Object.defineProperty(start, "changedTouches", {
      value: [{ clientX: gesture.startX, clientY: gesture.y }]
    });
    element.dispatchEvent(start);

    const end = new Event("touchend", { bubbles: true, cancelable: true });
    Object.defineProperty(end, "touches", { value: [] });
    Object.defineProperty(end, "changedTouches", {
      value: [{ clientX: gesture.endX, clientY: gesture.y }]
    });
    element.dispatchEvent(end);
  }, input);
}

async function readKeyboardInset(page: import("@playwright/test").Page) {
  return page.getByTestId("chat-layout").evaluate((element) => {
    return window.getComputedStyle(element).getPropertyValue("--chat-keyboard-inset").trim();
  });
}

async function setVisualViewportInset(
  page: import("@playwright/test").Page,
  inset: number
) {
  await page.evaluate((nextInset) => {
    (
      window as typeof window & {
        __setVisualViewportInsetForTest?: (value: number) => void;
      }
    ).__setVisualViewportInsetForTest?.(nextInset);
  }, inset);
}

async function captureFocusOrder(
  page: import("@playwright/test").Page,
  steps: number
) {
  const labels: string[] = [];

  for (let index = 0; index < steps; index += 1) {
    await page.keyboard.press("Tab");
    labels.push(
      await page.evaluate(() => {
        const element = document.activeElement as HTMLElement | null;
        if (!element) {
          return "<none>";
        }

        if (element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement) {
          return element.labels?.[0]?.textContent?.trim() ?? element.id ?? element.tagName;
        }

        return (
          element.getAttribute("aria-label") ??
          element.getAttribute("aria-labelledby") ??
          element.textContent?.replace(/\s+/g, " ").trim() ??
          element.tagName
        );
      })
    );
  }

  return labels.map((label) => label.replace(/(?<=\w)(ready)(?=\w)/g, " ready "));
}

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
