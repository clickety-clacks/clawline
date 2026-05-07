import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("scroll state restores on stream switch and reload, and unread stream selection anchors into history", async ({
  page
}) => {
  const port = 23_801 + Math.floor(Math.random() * 1_000);
  const mainSessionKey = "agent:main:clawline:flynn:main";
  const sideSessionKey = "agent:main:clawline:flynn:side";

  const mainTranscript = Array.from({ length: 90 }, (_, index) => ({
    type: "message",
    id: `s_main_${index + 1}`,
    role: index % 4 === 0 ? "user" : "assistant",
    content: `Main message ${index + 1}\n\n${"detail ".repeat(30)}`,
    timestamp: 1_764_320_000_000 + index,
    streaming: false,
    sessionKey: mainSessionKey,
    attachments: []
  }));

  const sideReplayTranscript = Array.from({ length: 45 }, (_, index) => ({
    type: "message",
    id: `s_side_${index + 1}`,
    role: "assistant",
    content: `Side replay ${index + 1}\n\n${"detail ".repeat(18)}`,
    timestamp: 1_764_320_100_000 + index,
    streaming: false,
    sessionKey: sideSessionKey,
    attachments: []
  }));

  const unreadSideMessage = {
    type: "message",
    id: "s_side_unread",
    role: "assistant",
    content: "Unread anchor target",
    timestamp: 1_764_320_200_000,
    streaming: false,
    sessionKey: sideSessionKey,
    attachments: []
  };
  const liveMainMessage = {
    type: "message",
    id: "s_main_live",
    role: "assistant",
    content: "Live region target",
    timestamp: 1_764_320_210_000,
    streaming: false,
    sessionKey: mainSessionKey,
    attachments: []
  };

  const server = createServer();
  const wss = new WebSocketServer({ server, path: "/ws" });
  const sockets = new Set<import("ws").WebSocket>();
  let activeSocket: import("ws").WebSocket | null = null;

  wss.on("connection", (socket) => {
    activeSocket = socket;
    sockets.add(socket);
    socket.on("close", () => {
      sockets.delete(socket);
      if (activeSocket === socket) {
        activeSocket = null;
      }
    });
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-phase5-scroll-token",
            userId: "user_flynn"
          })
        );
        return;
      }

      if (payload.type === "auth") {
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            replayCount: mainTranscript.length + sideReplayTranscript.length,
            sessionKeys: [mainSessionKey, sideSessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: false,
            sessionKeys: [mainSessionKey, sideSessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey: mainSessionKey,
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_320_000_000,
                updatedAt: 1_764_320_000_000
              },
              {
                sessionKey: sideSessionKey,
                displayName: "Side",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: 1_764_320_000_000,
                updatedAt: 1_764_320_000_000
              }
            ]
          })
        );

        for (const message of mainTranscript) {
          socket.send(JSON.stringify(message));
        }
        for (const message of sideReplayTranscript) {
          socket.send(JSON.stringify(message));
        }
      }
    });
  });

  try {
    await new Promise<void>((resolve) => {
      server.listen(port, "127.0.0.1", () => resolve());
    });

    await page.addInitScript(() => {
      const announcementLog: string[] = [];
      const seen = new Set<string>();

      function normalize(value: string | null | undefined) {
        return value?.replace(/\s+/g, " ").trim() ?? "";
      }

      function recordLiveRegions() {
        for (const element of document.querySelectorAll<HTMLElement>("[aria-live]")) {
          const text = normalize(element.textContent);
          if (!text || seen.has(text)) {
            continue;
          }

          seen.add(text);
          announcementLog.push(text);
        }
      }

      const observer = new MutationObserver(() => {
        recordLiveRegions();
      });

      const start = () => {
        observer.observe(document.documentElement, {
          subtree: true,
          childList: true,
          characterData: true
        });
        recordLiveRegions();
      };

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start, { once: true });
      } else {
        start();
      }

      (window as Window & { __clawlineAnnouncementLog?: string[] }).__clawlineAnnouncementLog =
        announcementLog;
    });

    await page.addInitScript((session) => {
      window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
      window.localStorage.setItem(
        "clawline-web:device-id",
        JSON.stringify(session.deviceId)
      );
    }, {
      claimedName: "Flynn Browser",
      deviceId: "phase5-scroll-device",
      isAdmin: false,
      serverUrl: `ws://127.0.0.1:${port}/ws`,
      token: "jwt-phase5-scroll-token",
      userId: "user_flynn"
    });

    await page.goto(`/chat/${mainSessionKey}`);

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await expect(page.getByText(/^Main message (1|90)$/).first()).toBeVisible();
    await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();
    await expect(page.locator('[data-testid="message-list"][aria-live="polite"]')).toBeVisible();
    await expect
      .poll(async () => {
        return await page.evaluate(() => {
          return (
            (window as Window & { __clawlineAnnouncementLog?: string[] })
              .__clawlineAnnouncementLog ?? []
          );
        });
      })
      .toContainEqual(expect.stringContaining("Main message"));

    const messageList = page.getByTestId("message-list");
    await messageList.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
      element.dispatchEvent(new Event("scroll"));
    });
    await expect(page.getByText("Main message 90")).toBeVisible();
    await expect(page.getByTestId("scroll-to-bottom-button")).toHaveCount(0);
    await messageList.evaluate((element) => {
      element.scrollTop = 0;
      element.dispatchEvent(new Event("scroll"));
    });
    await expect(page.getByTestId("scroll-to-bottom-button")).toHaveCount(1);
    await page.getByTestId("message-list").evaluate((element) => {
      element.scrollTop = element.scrollHeight;
      element.dispatchEvent(new Event("scroll"));
    });
    await expect(page.getByTestId("scroll-to-bottom-button")).toHaveCount(0);
    await expect(page.getByText("Main message 90")).toBeVisible();

    activeSocket?.send(JSON.stringify(liveMainMessage));
    await expect(page.getByText("Live region target")).toBeVisible();
    await expect
      .poll(async () => {
        return await page.evaluate(() => {
          return (
            (window as Window & { __clawlineAnnouncementLog?: string[] })
              .__clawlineAnnouncementLog ?? []
          );
        });
      })
      .toContainEqual(expect.stringContaining("Live region target"));

    activeSocket?.send(JSON.stringify(unreadSideMessage));
    await page.getByRole("button", { name: "Manage streams" }).click();
    await expect(page.getByLabel("1 unread messages")).toHaveCount(1);
    expect(
      await page
        .locator(".session-sheet-card-indicator--unread")
        .evaluate((element) => window.getComputedStyle(element).backgroundColor)
    ).toBe("rgb(224, 122, 95)");

    await page.getByRole("button", { name: "Side" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sideSessionKey)}$`));
    await expect(page.getByText("Unread anchor target")).toBeVisible();
    await page.getByRole("button", { name: "Manage streams" }).click();
    await expect(page.getByLabel("1 unread messages")).toHaveCount(0);

    await page.getByRole("button", { name: "Main" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await expect(page.getByText("Main message 90")).toBeVisible();
    await expect(page.getByTestId("scroll-to-bottom-button")).toHaveCount(0);
    await expect
      .poll(async () => readPersistedScrollState(page, mainSessionKey))
      .toMatchObject({ stickToBottom: true });

    await page.reload({ waitUntil: "domcontentloaded" });

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();
    await expect(page.getByText("Main message 90")).toBeVisible();
  } finally {
    await page.close();
    for (const client of sockets) {
      client.terminate();
    }
    server.closeAllConnections();
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
  }
});

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function readPersistedScrollState(
  page: import("@playwright/test").Page,
  sessionKey: string
) {
  return await page.evaluate(async (key) => {
    const scopeId = window.sessionStorage.getItem("clawline-web:tab-runtime-scope");
    if (!scopeId) {
      return null;
    }

    const database = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = window.indexedDB.open("clawline-web");
      request.onerror = () => reject(request.error);
      request.onsuccess = () => resolve(request.result);
    });

    try {
      const snapshot = await new Promise<{
        scrollStateBySessionKey?: Record<string, { stickToBottom: boolean }>;
      } | null>((resolve, reject) => {
        const transaction = database.transaction("chatSnapshots", "readonly");
        const request = transaction.objectStore("chatSnapshots").get(`chat-snapshot:${scopeId}`);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result ?? null);
      });

      return snapshot?.scrollStateBySessionKey?.[key] ?? null;
    } finally {
      database.close();
    }
  }, sessionKey);
}
