import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("message links render as lightweight cards without turning code-block URLs into previews", async ({
  page
}) => {
  const port = 21_941 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:clawline_web_test:main";
  const docsUrl = "https://clawline.test/docs";
  const researchUrl = "https://clawline.test/research";
  const linkContent = [
    `Visit ${docsUrl} for docs.`,
    "",
    `Here is a markdown link to [Research](${researchUrl}).`,
    "",
    "```",
    `${docsUrl}/in-code`,
    "```"
  ].join("\n");

  const server = createServer((request, response) => {
    if (request.url === "/docs") {
      response.writeHead(200, {
        "access-control-allow-origin": "*",
        "content-type": "text/html"
      });
      response.end(
        [
          "<html><head>",
          "<title>Garden Guide</title>",
          '<meta property="og:title" content="Garden Guide" />',
          '<meta property="og:description" content="Fresh herbs, flowers, and paths." />',
          '<meta property="og:image" content="/card.png" />',
          "</head><body>Guide</body></html>"
        ].join("")
      );
      return;
    }

    if (request.url === "/research") {
      response.writeHead(200, {
        "access-control-allow-origin": "*",
        "content-type": "text/html"
      });
      response.end(
        [
          "<html><head>",
          "<title>Research Brief</title>",
          '<meta name="description" content="Open field notes." />',
          "</head><body>Brief</body></html>"
        ].join("")
      );
      return;
    }

    if (request.url === "/card.png") {
      response.writeHead(200, {
        "access-control-allow-origin": "*",
        "content-type": "image/png"
      });
      response.end(
        Buffer.from(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9sX6ix0AAAAASUVORK5CYII=",
          "base64"
        )
      );
      return;
    }

    response.writeHead(404);
    response.end("not found");
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
            token: "jwt-phase4-link-token",
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
                createdAt: 1_764_202_900_000,
                updatedAt: 1_764_202_900_000,
                adopted: false
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_links_1",
            role: "assistant",
            content: linkContent,
            timestamp: 1_764_202_900_100,
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
    await page.route("https://clawline.test/**", async (route) => {
      const url = new URL(route.request().url());
      if (url.pathname === "/docs") {
        await route.fulfill({
          contentType: "text/html",
          body: [
            "<html><head>",
            "<title>Garden Guide</title>",
            '<meta property="og:title" content="Garden Guide" />',
            '<meta property="og:description" content="Fresh herbs, flowers, and paths." />',
            '<meta property="og:image" content="/card.png" />',
            "</head><body>Guide</body></html>"
          ].join("")
        });
        return;
      }

      if (url.pathname === "/research") {
        await route.fulfill({
          contentType: "text/html",
          body: [
            "<html><head>",
            "<title>Research Brief</title>",
            '<meta name="description" content="Open field notes." />',
            "</head><body>Brief</body></html>"
          ].join("")
        });
        return;
      }

      if (url.pathname === "/card.png") {
        await route.fulfill({
          contentType: "image/png",
          body: Buffer.from(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9sX6ix0AAAAASUVORK5CYII=",
            "base64"
          )
        });
        return;
      }

      await route.abort();
    });
    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Clawline Web Test Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

    for (const appearance of ["dark", "light"] as const) {
      await applyAppearance(page, appearance);

      await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

      const docsCard = page.locator(`.message-link-card[href="${docsUrl}"]`);
      await expect(docsCard).toBeVisible();
      await expect(docsCard).toHaveAttribute("href", docsUrl);
      await expect(docsCard).toContainText("Garden Guide");
      await expect(docsCard).toContainText("Fresh herbs, flowers, and paths.");
      await expect(docsCard.locator(".message-link-card-thumbnail")).toBeVisible();
      expect(await docsCard.evaluate((element) => window.getComputedStyle(element).borderRadius)).toBe(
        "18px 18px 16px 16px / 20px 20px 14px 14px"
      );
      expect(
        await docsCard
          .locator(".message-link-card-thumbnail")
          .evaluate((element) => window.getComputedStyle(element).borderRadius)
      ).toBe("14px 14px 12px 12px / 15px 15px 11px 11px");

      const researchCard = page.locator(`.message-link-card[href="${researchUrl}"]`);
      await expect(researchCard).toBeVisible();
      await expect(researchCard).toHaveAttribute("href", researchUrl);
      await expect(researchCard).toContainText("Research Brief");
      await expect(researchCard).toContainText("Open field notes.");
      await expect(page.getByTestId("message-s_links_1")).toHaveScreenshot(
        `phase4-link-cards-surface-${appearance}.png`,
        {
          animations: "disabled",
          caret: "hide",
          maxDiffPixelRatio: 0.02
        }
      );

      await expect(page.getByText(`${docsUrl}/in-code`)).toBeVisible();
      await expect(page.locator('.message-link-card[href*="in-code"]')).toHaveCount(0);
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
        resolve();
      });
    });
    await new Promise<void>((resolve, reject) => {
      server.close((serverError) => {
        if (serverError) {
          reject(serverError);
          return;
        }
        resolve();
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
