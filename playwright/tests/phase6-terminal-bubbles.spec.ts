import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer, type WebSocket } from "ws";

test("terminal bubbles render through the dedicated runtime and reconnect honestly", async ({
  page
}) => {
  const port = 23_501 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  let terminalAuthCount = 0;
  let latestTerminalSocket: WebSocket | null = null;

  const server = createServer((request, response) => {
    response.setHeader("Access-Control-Allow-Origin", "*");
    response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");

    if (request.method === "OPTIONS") {
      response.writeHead(204);
      response.end();
      return;
    }

    response.writeHead(404);
    response.end();
  });

  const chatSocketServer = new WebSocketServer({ noServer: true });
  chatSocketServer.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-phase6-token",
            userId: "user_flynn"
          })
        );
        return;
      }

      if (payload.type !== "auth") {
        return;
      }

      socket.send(
        JSON.stringify({
          type: "auth_result",
          success: true,
          userId: "user_flynn",
          replayCount: 0,
          sessionKeys: [sessionKey]
        })
      );
      socket.send(
        JSON.stringify({
          type: "session_info",
          userId: "user_flynn",
          isAdmin: true,
          sessionKeys: [sessionKey]
        })
      );
      socket.send(
        JSON.stringify({
          type: "stream_snapshot",
          streams: [
            {
              sessionKey,
              displayName: "Personal",
              kind: "main",
              orderIndex: 0,
              isBuiltIn: true,
              createdAt: 1_765_006_000_000,
              updatedAt: 1_765_006_000_000,
              adopted: false
            }
          ]
        })
      );
      socket.send(
        JSON.stringify({
          type: "message",
          id: "s_terminal_1",
          role: "assistant",
          content: "Terminal surface",
          timestamp: 1_765_006_000_100,
          streaming: false,
          sessionKey,
          attachments: [
            {
              type: "document",
              mimeType: "application/vnd.clawline.terminal-session+json",
              data: Buffer.from(
                JSON.stringify({
                  version: 2,
                  terminalSessionId: "term_eezo_1",
                  title: "eezo",
                  destination: {
                    address: "mike@eezo"
                  },
                  capabilities: {
                    interactive: true,
                    supportsBinaryFrames: true,
                    supportsResize: true,
                    supportsDetach: true
                  }
                })
              ).toString("base64")
            }
          ]
        })
      );
    });
  });

  const terminalSocketServer = new WebSocketServer({ noServer: true });
  terminalSocketServer.on("connection", (socket) => {
    latestTerminalSocket = socket;

    socket.on("message", (payload, isBinary) => {
      const raw = payload.toString();
      let message: { type?: string } | null = null;
      try {
        message = JSON.parse(raw) as { type?: string };
      } catch {
        socket.send(raw);
        return;
      }

      if (message.type === "terminal_auth") {
        terminalAuthCount += 1;
        socket.send(JSON.stringify({ type: "terminal_ready" }));
        socket.send(JSON.stringify({ type: "terminal_backfill_end" }));
        socket.send("connected to eezo\r\n$ ");
        return;
      }

      if (message.type === "terminal_detach") {
        return;
      }

      if (message.type === "terminal_resize") {
        return;
      }
    });
  });

  server.on("upgrade", (request, socket, head) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);

    if (url.pathname === "/ws") {
      chatSocketServer.handleUpgrade(request, socket, head, (client) => {
        chatSocketServer.emit("connection", client, request);
      });
      return;
    }

    if (url.pathname === "/ws/terminal") {
      terminalSocketServer.handleUpgrade(request, socket, head, (client) => {
        terminalSocketServer.emit("connection", client, request);
      });
      return;
    }

    socket.destroy();
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });

  try {
    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

    const terminalCard = page.getByTestId("terminal-attachment-term_eezo_1");
    await expect(terminalCard).toBeVisible();
    await expect(page.getByText("mike@eezo")).toBeVisible();
    await expect.poll(() => terminalAuthCount).toBe(1);
    await expect(terminalCard.locator(".xterm")).toBeVisible();
    await expect
      .poll(() => terminalCard.locator(".xterm-rows").textContent())
      .toContain("connected to eezo");

    latestTerminalSocket?.close();
    await expect(page.getByText("Terminal disconnected.")).toBeVisible();
    await page.getByRole("button", { name: "Reconnect" }).click();
    await expect.poll(() => terminalAuthCount).toBe(2);
  } finally {
    try {
      await page.goto("about:blank");
    } catch {
      // Ignore teardown navigation errors if the page is already gone.
    }
    for (const client of chatSocketServer.clients) {
      client.terminate();
    }
    for (const client of terminalSocketServer.clients) {
      client.terminate();
    }
    server.closeAllConnections?.();
    await new Promise<void>((resolve, reject) => {
      terminalSocketServer.close((terminalError) => {
        if (terminalError) {
          reject(terminalError);
          return;
        }
        chatSocketServer.close((chatError) => {
          if (chatError) {
            reject(chatError);
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
    });
  }
});

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
