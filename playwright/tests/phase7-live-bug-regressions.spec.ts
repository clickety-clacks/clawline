import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("live bug procedure: history replay, network status dots, and short-chat scroll are stable", async ({
  page
}) => {
  const port = 24_801 + Math.floor(Math.random() * 1_000);
  const mainSessionKey = "agent:main:clawline:flynn:main";
  const sideSessionKey = "agent:main:clawline:flynn:side";
  const authPayloads: Array<Record<string, unknown>> = [];
  let sideRunState = "running";

  const server = createServer((request, response) => {
    const corsHeaders = {
      "Access-Control-Allow-Headers": "authorization,content-type",
      "Access-Control-Allow-Methods": "GET,OPTIONS",
      "Access-Control-Allow-Origin": "*"
    };
    if (request.method === "OPTIONS") {
      response.writeHead(204, corsHeaders);
      response.end();
      return;
    }

    const url = new URL(request.url ?? "/", `http://${request.headers.host}`);
    if (url.pathname === "/api/session-status") {
      const sessionKey = url.searchParams.get("sessionKey") ?? "";
      const runState = sessionKey === sideSessionKey ? sideRunState : "idle";
      response.writeHead(200, {
        ...corsHeaders,
        "Content-Type": "application/json"
      });
      response.end(
        JSON.stringify({
          sessionKey,
          display: {
            model: "gpt-5.5",
            provider: "openai",
            thinkingLevel: "medium",
            fastMode: false
          },
          run: {
            state: runState,
            queueDepth: runState === "running" ? 1 : 0
          },
          capabilities: {
            cancelCurrentRun: { supported: runState === "running" }
          }
        })
      );
      return;
    }

    response.writeHead(404, {
      ...corsHeaders,
      "Content-Type": "application/json"
    });
    response.end(JSON.stringify({ error: { code: "unexpected_path" } }));
  });
  const wss = new WebSocketServer({ server, path: "/ws" });

  const streams = [
    {
      sessionKey: mainSessionKey,
      displayName: "Main",
      kind: "main",
      orderIndex: 0,
      isBuiltIn: true,
      createdAt: 1_764_500_000_000,
      updatedAt: 1_764_500_000_000
    },
    {
      sessionKey: sideSessionKey,
      displayName: "Side thread",
      kind: "custom",
      orderIndex: 1,
      isBuiltIn: false,
      createdAt: 1_764_500_000_100,
      updatedAt: 1_764_500_000_100
    }
  ];
  const mainBootstrap = {
    type: "message",
    id: "s_main_1",
    role: "assistant",
    content: "Main bootstrap cursor",
    timestamp: 1_764_500_000_200,
    streaming: false,
    sessionKey: mainSessionKey,
    attachments: []
  };
  const sideHistory = [
    {
      type: "message",
      id: "s_side_1",
      role: "assistant",
      content: "Side history first message",
      timestamp: 1_764_500_000_300,
      streaming: false,
      sessionKey: sideSessionKey,
      attachments: []
    },
    {
      type: "message",
      id: "s_side_2",
      role: "assistant",
      content: "Side history second message",
      timestamp: 1_764_500_000_400,
      streaming: false,
      sessionKey: sideSessionKey,
      attachments: []
    }
  ];

  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as {
        type: string;
        lastMessageId?: string | null;
      };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-live-bug-token",
            userId: "user_flynn"
          })
        );
        return;
      }

      if (payload.type === "auth") {
        authPayloads.push(payload as Record<string, unknown>);
        const shouldReplaySideHistory =
          authPayloads.length > 1 && payload.lastMessageId !== mainBootstrap.id;
        const replayMessages =
          authPayloads.length === 1
            ? [mainBootstrap]
            : shouldReplaySideHistory
              ? sideHistory
              : [];

        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            sessionId: `sess_${authPayloads.length}`,
            isAdmin: false,
            replayCount: replayMessages.length,
            replayTruncated: false,
            historyReset: false,
            sessionKeys: [mainSessionKey, sideSessionKey],
            streamTailStates: {
              [mainSessionKey]: {
                lastMessageId: mainBootstrap.id,
                lastMessageRole: "assistant"
              }
            }
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
            streams
          })
        );
        for (const message of replayMessages) {
          socket.send(JSON.stringify(message));
        }
      }
    });
  });

  try {
    await new Promise<void>((resolve) => {
      server.listen(port, "127.0.0.1", () => resolve());
    });

    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await expect(page.getByText("Main bootstrap cursor")).toBeVisible();

    await page.getByRole("button", { name: "Manage streams" }).click();
    const sideCard = page.getByRole("button", { name: /Side thread/ });
    await expect(sideCard.locator(".session-sheet-card-indicator--user-tail")).toHaveCount(1);
    await sideCard.click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sideSessionKey)}$`));
    await expect(page.getByText("This stream is ready for text chat.")).toBeVisible();

    await page.reload();

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sideSessionKey)}$`));
    await expect(page.getByText("Side history first message")).toBeVisible();
    await expect(page.getByText("Side history second message")).toBeVisible();
    await expect(page.getByText("This stream is ready for text chat.")).toHaveCount(0);
    await expect.poll(() => authPayloads.length).toBeGreaterThanOrEqual(2);
    expect(authPayloads.at(-1)?.lastMessageId).toBeNull();

    const messageList = page.getByTestId("message-list");
    const beforeScroll = await messageList.evaluate((element) => ({
      buttonCount: document.querySelectorAll('[data-testid="scroll-to-bottom-button"]').length,
      firstTop: document
        .querySelector('[data-testid="message-s_side_1"]')
        ?.getBoundingClientRect().top,
      scrollTop: element.scrollTop
    }));
    expect(beforeScroll.buttonCount).toBe(0);
    expect(beforeScroll.scrollTop).toBe(0);

    await messageList.hover();
    await page.mouse.wheel(0, -700);
    await page.mouse.wheel(0, 700);
    await messageList.evaluate((element) => {
      element.scrollTop = -80;
      element.dispatchEvent(new Event("scroll"));
    });

    const afterScroll = await messageList.evaluate((element) => ({
      buttonCount: document.querySelectorAll('[data-testid="scroll-to-bottom-button"]').length,
      firstTop: document
        .querySelector('[data-testid="message-s_side_1"]')
        ?.getBoundingClientRect().top,
      scrollTop: element.scrollTop
    }));
    expect(afterScroll.buttonCount).toBe(0);
    expect(afterScroll.scrollTop).toBe(0);
    expect(Math.abs(Number(afterScroll.firstTop) - Number(beforeScroll.firstTop))).toBeLessThan(2);

    sideRunState = "idle";
  } finally {
    await page.goto("about:blank");
    for (const client of wss.clients) {
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
