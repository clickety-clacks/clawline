import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("common attachment types render through the authenticated display path", async ({
  page
}) => {
  const port = 22_901 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:clawline_web_test:main";
  const downloadHits: string[] = [];

  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);

    response.setHeader("Access-Control-Allow-Origin", "*");
    response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");

    if (request.method === "OPTIONS") {
      response.writeHead(204);
      response.end();
      return;
    }

    if (url.pathname.startsWith("/download/")) {
      downloadHits.push(url.pathname.split("/").pop() ?? "unknown");

      if (request.headers.authorization !== "Bearer jwt-phase4-token") {
        response.writeHead(401);
        response.end();
        return;
      }

      if (url.pathname.endsWith("/audio_1")) {
        response.writeHead(200, { "Content-Type": "audio/mpeg" });
        response.end(Buffer.from("audio"));
        return;
      }

      if (url.pathname.endsWith("/video_1")) {
        response.writeHead(200, { "Content-Type": "video/mp4" });
        response.end(Buffer.from("video"));
        return;
      }

      if (url.pathname.endsWith("/file_1")) {
        response.writeHead(200, { "Content-Type": "application/pdf" });
        response.end(Buffer.from("file"));
        return;
      }

      response.writeHead(404);
      response.end();
      return;
    }

    response.writeHead(404);
    response.end();
  });

  const wss = new WebSocketServer({ server, path: "/ws" });
  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as { type: string };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-phase4-token",
            userId: "clawline_web_test"
          })
        );
        return;
      }

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
                createdAt: 1_764_202_100_000,
                updatedAt: 1_764_202_100_000,
                adopted: false
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_image_only",
            role: "assistant",
            content: "",
            timestamp: 1_764_202_100_090,
            streaming: false,
            sessionKey,
            attachments: [
              {
                type: "image",
                mimeType: "image/svg+xml",
                data: Buffer.from(
                  '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="10" fill="#c4785c"/></svg>'
                ).toString("base64")
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_attachment_1",
            role: "assistant",
            content: "Attachment surface",
            timestamp: 1_764_202_100_100,
            streaming: false,
            sessionKey,
            attachments: [
              {
                type: "image",
                mimeType: "image/svg+xml",
                data: Buffer.from(
                  '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><rect width="24" height="24" fill="#63d2c6"/></svg>'
                ).toString("base64")
              },
              {
                type: "asset",
                assetId: "audio_1",
                metadata: {
                  filename: "note.mp3",
                  mimeType: "audio/mpeg"
                }
              },
              {
                type: "document",
                assetId: "video_1",
                metadata: {
                  filename: "demo.mp4",
                  mimeType: "video/mp4"
                }
              },
              {
                type: "document",
                assetId: "file_1",
                metadata: {
                  filename: "report.pdf",
                  mimeType: "application/pdf"
                }
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
    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Clawline Web Test Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

    for (const appearance of ["dark", "light"] as const) {
      await applyAppearance(page, appearance);

      await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));
      await expect(
        page.getByTestId("message-s_attachment_1").getByAltText("attachment")
      ).toBeVisible();
      await expect(page.getByTestId("message-s_image_only")).toHaveAttribute(
        "data-message-chrome",
        "chromeless-image"
      );
      await expect(page.getByLabel("note.mp3")).toBeVisible();
      await expect(page.getByLabel("demo.mp4")).toBeVisible();
      await expect(page.getByRole("button", { name: "Download report.pdf" })).toBeVisible();

      await expect
        .poll(() => [...new Set(downloadHits)].sort())
        .toContain("audio_1");
      await expect
        .poll(() => [...new Set(downloadHits)].sort())
        .toContain("video_1");
      await expect(page.getByTestId("message-s_attachment_1")).toHaveScreenshot(
        `phase4-attachment-display-surface-${appearance}.png`,
        {
          animations: "disabled",
          caret: "hide",
          maxDiffPixelRatio: 0.02
        }
      );

      await page.getByRole("button", { name: "Download report.pdf" }).click();
      await expect
        .poll(() => [...new Set(downloadHits)].sort())
        .toEqual(["audio_1", "file_1", "video_1"]);
    }
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

async function applyAppearance(
  page: import("@playwright/test").Page,
  appearance: "dark" | "light"
) {
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

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
