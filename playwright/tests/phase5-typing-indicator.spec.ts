import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("assistant streaming renders and clears a typing indicator with settle delay", async ({
  page
}) => {
  const port = 25_701 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:clawline_web_test:main";
  const server = createServer();
  const wss = new WebSocketServer({ server, path: "/ws" });
  let activeSocket: import("ws").WebSocket | null = null;

  wss.on("connection", (socket) => {
    activeSocket = socket;
    socket.on("close", () => {
      if (activeSocket === socket) {
        activeSocket = null;
      }
    });
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "auth") {
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "clawline_web_test",
            replayCount: 0,
            sessionKeys: [sessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "clawline_web_test",
            isAdmin: false,
            sessionKeys: [sessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey,
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_500_000_000,
                updatedAt: 1_764_500_000_000,
                adopted: false
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_seed",
            role: "assistant",
            content: "Working through the next step.",
            timestamp: 1_764_500_000_010,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });

  try {
    await page.addInitScript((session) => {
      window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
      window.localStorage.setItem(
        "clawline-web:device-id",
        JSON.stringify(session.deviceId)
      );
    }, {
      claimedName: "Clawline Web Test Browser",
      deviceId: "phase5-typing-device",
      isAdmin: false,
      serverUrl: `ws://127.0.0.1:${port}/ws`,
      token: "jwt-phase5-typing-token",
      userId: "clawline_web_test"
    });

    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto(`/chat/${sessionKey}`);
    await expect(page.getByText("Working through the next step.")).toBeVisible();
    await expect(page.getByTestId("typing-indicator")).toHaveCount(0);

    activeSocket?.send(
      JSON.stringify({
        type: "message",
        id: "s_streaming",
        role: "assistant",
        content: "Thinking through the last step",
        timestamp: 1_764_500_000_020,
        streaming: true,
        sessionKey,
        attachments: []
      })
    );

    const typingIndicator = page.getByTestId("typing-indicator");
    await expect(typingIndicator).toBeVisible();
    await expect(typingIndicator.locator(".message-typing-indicator-dot")).toHaveCount(3);

    activeSocket?.send(
      JSON.stringify({
        type: "message",
        id: "s_streaming",
        role: "assistant",
        content: "Here is the finished answer.",
        timestamp: 1_764_500_000_030,
        streaming: false,
        sessionKey,
        attachments: []
      })
    );

    await expect(page.getByText("Here is the finished answer.")).toBeVisible();
    await expect(typingIndicator).toHaveCount(0);
  } finally {
    try {
      await page.goto("about:blank");
    } catch {
      // Ignore teardown navigation errors if the test already closed the page.
    }
    for (const client of wss.clients) {
      client.terminate();
    }
    server.closeAllConnections?.();
    await new Promise<void>((resolve, reject) => {
      wss.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        server.close((serverError) => {
          if (serverError) {
            reject(serverError);
            return;
          }
          resolve();
        });
      });
    });
  }
});

test("assistant in-flight session status renders cancellable typing indicator", async ({
  page
}) => {
  const port = 25_901 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:clawline_web_test:main";
  let cancelRequests = 0;
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
    response.setHeader("Content-Type", "application/json");
    response.setHeader("Access-Control-Allow-Origin", "*");
    response.setHeader("Access-Control-Allow-Headers", "authorization,content-type");
    response.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");

    if (request.method === "OPTIONS") {
      response.statusCode = 204;
      response.end();
      return;
    }

    if (url.pathname === "/api/session-status") {
      response.end(
        JSON.stringify({
          sessionKey,
          display: {
            model: "gpt-5.5",
            thinkingLevel: "medium",
            fastMode: true
          },
          run: {
            state: cancelRequests > 0 ? "idle" : "running"
          },
          capabilities: {
            cancelCurrentRun: { supported: true }
          }
        })
      );
      return;
    }

    if (url.pathname === "/api/session-control" && request.method === "POST") {
      cancelRequests += 1;
      response.end(
        JSON.stringify({
          ok: true,
          sessionKey,
          action: "cancel_current_run",
          status: {
            sessionKey,
            run: {
              state: "idle"
            }
          }
        })
      );
      return;
    }

    response.statusCode = 404;
    response.end(JSON.stringify({ error: { code: "not_found" } }));
  });
  const wss = new WebSocketServer({ server, path: "/ws" });

  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "auth") {
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "clawline_web_test",
            replayCount: 0,
            sessionKeys: [sessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams: [
              {
                sessionKey,
                displayName: "Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_500_000_000,
                updatedAt: 1_764_500_000_000,
                adopted: false
              }
            ]
          })
        );
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });

  try {
    await page.addInitScript((session) => {
      window.localStorage.setItem("clawline-web:auth-session", JSON.stringify(session));
      window.localStorage.setItem(
        "clawline-web:device-id",
        JSON.stringify(session.deviceId)
      );
    }, {
      claimedName: "Clawline Web Test Browser",
      deviceId: "phase5-typing-status-device",
      isAdmin: true,
      serverUrl: `ws://127.0.0.1:${port}/ws`,
      token: "jwt-phase5-typing-status-token",
      userId: "clawline_web_test"
    });

    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto(`/chat/${sessionKey}`);

    const typingIndicator = page.getByTestId("typing-indicator");
    await expect(typingIndicator).toBeVisible();
    await typingIndicator.click();
    const cancelPopover = page.getByTestId("typing-cancel-popover");
    await expect(cancelPopover).toBeVisible();
    await cancelPopover.getByRole("button", { name: "Cancel" }).click();
    await expect.poll(() => cancelRequests).toBe(1);
  } finally {
    try {
      await page.goto("about:blank");
    } catch {
      // Ignore teardown navigation errors if the test already closed the page.
    }
    for (const client of wss.clients) {
      client.terminate();
    }
    server.closeAllConnections?.();
    await new Promise<void>((resolve, reject) => {
      wss.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        server.close((serverError) => {
          if (serverError) {
            reject(serverError);
            return;
          }
          resolve();
        });
      });
    });
  }
});
