import { test, expect } from "@playwright/test";
import { WebSocketServer } from "ws";

test("large transcripts keep a bounded DOM window in the browser", async ({
  page
}) => {
  const port = 23_401 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  const transcript = Array.from({ length: 60 }, (_, index) => ({
    type: "message",
    id: `s_bulk_${index + 1}`,
    role: index % 5 === 0 ? "user" : "assistant",
    content: `Virtualized message ${index + 1}\n\n${"detail ".repeat(40)}`,
    timestamp: 1_764_300_000_000 + index,
    streaming: false,
    sessionKey,
    attachments: []
  }));

  const wss = new WebSocketServer({ port });

  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-phase5-token",
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
            replayCount: transcript.length,
            sessionKeys: [sessionKey]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
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
                createdAt: 1_764_300_000_000,
                updatedAt: 1_764_300_000_000
              }
            ]
          })
        );

        for (const message of transcript) {
          socket.send(JSON.stringify(message));
        }
      }
    });
  });

  try {
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));
    await expect(page.getByText("Virtualized message 60")).toBeVisible();

    const renderedCountNearBottom = await page
      .locator('[data-testid^="message-s_bulk_"]')
      .count();
    expect(renderedCountNearBottom).toBeLessThan(40);
    await expect(page.getByText("Virtualized message 1")).toHaveCount(0);
  } finally {
    for (const client of wss.clients) {
      client.terminate();
    }
    await new Promise<void>((resolve, reject) => {
      wss.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }
});

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
