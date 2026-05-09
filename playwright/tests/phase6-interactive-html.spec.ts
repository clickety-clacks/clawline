import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("interactive HTML bubbles stay sandboxed, block network access, and use the approved bridge", async ({
  page
}) => {
  const port = 24_601 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  const interactiveCallbacks: unknown[] = [];
  let blockedFetchCount = 0;

  const server = createServer((request, response) => {
    response.setHeader("Access-Control-Allow-Origin", "*");
    response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");

    if (request.method === "OPTIONS") {
      response.writeHead(204);
      response.end();
      return;
    }

    if (request.url === "/should-block") {
      blockedFetchCount += 1;
      response.writeHead(200, { "content-type": "text/plain" });
      response.end("network should not be reachable");
      return;
    }

    response.writeHead(404);
    response.end();
  });

  const html = [
    "<!doctype html>",
    "<html>",
    "<body style=\"margin:0;padding:16px;font-family:-apple-system,system-ui,sans-serif;\">",
    "<div style=\"height:180px;display:flex;flex-direction:column;gap:12px;\">",
    "<p id=\"status\">loading</p>",
    "<button type=\"button\" onclick=\"window.webkit.messageHandlers.clawline.postMessage({ action: 'ping', data: { value: 7 } })\">Ping</button>",
    "<button type=\"button\" onclick=\"window.webkit.messageHandlers.clawline.postMessage({ action: '_resize', height: 320 })\">Resize Tall</button>",
    "<button type=\"button\" onclick=\"window.webkit.messageHandlers.clawline.postMessage({ action: '_resize', height: 120 })\">Resize Short</button>",
    "<script>",
    "const statusNode = document.getElementById('status');",
    `fetch('http://127.0.0.1:${port}/should-block')`,
    "  .then(() => { statusNode.textContent = 'fetch-allowed'; })",
    "  .catch(() => { statusNode.textContent = 'fetch-blocked'; });",
    "</script>",
    "</div>",
    "</body>",
    "</html>"
  ].join("");

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

      if (payload.type === "interactive-callback") {
        interactiveCallbacks.push(payload);
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
          id: "s_html_1",
          role: "assistant",
          content: "Interactive HTML surface",
          timestamp: 1_765_006_000_100,
          streaming: false,
          sessionKey,
          attachments: [
            {
              type: "document",
              mimeType: "application/vnd.clawline.interactive-html+json",
              data: Buffer.from(
                JSON.stringify({
                  version: 1,
                  html,
                  metadata: {
                    title: "Interactive Demo",
                    height: "auto",
                    maxHeight: 360
                  }
                })
              ).toString("base64")
            }
          ]
        })
      );
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

    const iframe = page.getByTestId("interactive-html-frame-s_html_1");
    await expect(iframe).toBeVisible();
    await expect(iframe).toHaveAttribute("sandbox", "allow-scripts");
    await expect(iframe).not.toHaveAttribute("sandbox", /allow-same-origin/);

    const frame = page.frameLocator('[data-testid="interactive-html-frame-s_html_1"]');
    await expect(frame.getByText("fetch-blocked")).toBeVisible();
    await expect.poll(() => blockedFetchCount).toBe(0);

    await frame.getByRole("button", { name: "Ping" }).click();
    await expect.poll(() => interactiveCallbacks.length).toBe(1);
    expect(interactiveCallbacks[0]).toEqual({
      type: "interactive-callback",
      messageId: "s_html_1",
      payload: {
        action: "ping",
        data: {
          value: 7
        }
      }
    });

    await frame.getByRole("button", { name: "Resize Tall" }).click();
    await expect.poll(() => iframe.evaluate((node) => (node as HTMLIFrameElement).style.height)).toBe(
      "320px"
    );

    await frame.getByRole("button", { name: "Resize Short" }).click();
    await expect.poll(() => iframe.evaluate((node) => (node as HTMLIFrameElement).style.height)).toBe(
      "320px"
    );
  } finally {
    try {
      await page.goto("about:blank");
    } catch {
      // Ignore teardown navigation errors if the page is already gone.
    }
    for (const client of chatSocketServer.clients) {
      client.terminate();
    }
    server.closeAllConnections?.();
    await new Promise<void>((resolve, reject) => {
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
  }
});

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
