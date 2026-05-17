import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("markdown messages render rich blocks and expand into an overlay", async ({ page }) => {
  const port = 21_901 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:clawline_web_test:main";
  const richContent = [
    "Intro paragraph.",
    "",
    "```ts",
    "console.log('phase4');",
    "```",
    "",
    "| Name | Value |",
    "| --- | --- |",
    "| alpha | beta |"
  ].join("\n");
  const expandedRichContent = `${richContent}\n\n${"More detail. ".repeat(90)}`;
  const shortContent = "Hey there";
  const highlightContent = "Please ==watch the market signal== before heading out.";
  const mediumContent = "Found a better route through the market if you still want plants later.";
  const longContent =
    "This should settle into the long-form body treatment because it crosses the medium threshold and reads more like a full thought than a quick exchange.";
  const codeOnlyContent = ["```ts", "console.log('chromeless');", "```"].join("\n");

  const server = createServer();
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
                createdAt: 1_764_201_200_000,
                updatedAt: 1_764_201_200_000,
                adopted: false
              }
            ]
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_short_1",
            role: "assistant",
            content: shortContent,
            timestamp: Date.now() - 15_000,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_highlight_1",
            role: "assistant",
            content: highlightContent,
            timestamp: 1_764_201_200_080,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_medium_1",
            role: "assistant",
            content: mediumContent,
            timestamp: 1_764_201_200_090,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_long_1",
            role: "assistant",
            content: longContent,
            timestamp: Date.now() - 24 * 60 * 60 * 1000,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_code_only",
            role: "assistant",
            content: codeOnlyContent,
            timestamp: 1_764_201_200_095,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_rich_1",
            role: "assistant",
            content: richContent,
            timestamp: 1_764_201_200_100,
            streaming: false,
            sessionKey,
            attachments: []
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_rich_2",
            role: "assistant",
            content: expandedRichContent,
            timestamp: 1_764_201_200_110,
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
    await page.setViewportSize({ width: 820, height: 1180 });
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Clawline Web Test Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

    for (const appearance of ["dark", "light"] as const) {
      await applyAppearance(page, appearance);

      await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));
      await expect(page.getByTestId("message-s_rich_1").locator(".message-markdown pre")).toContainText(
        "console.log('phase4');"
      );
      const mark = page.getByTestId("message-s_highlight_1").locator(".message-markdown mark");
      await expect(mark).toContainText("watch the market signal");
      const highlightColors = await page.getByTestId("message-s_highlight_1").locator(".message-markdown").evaluate((element) => {
        const markElement = element.querySelector("mark");
        return {
          baseColor: window.getComputedStyle(element).color,
          markColor: markElement ? window.getComputedStyle(markElement).color : null
        };
      });
      expect(highlightColors.markColor).not.toBeNull();
      expect(highlightColors.markColor).not.toBe(highlightColors.baseColor);
      const shortTypography = await page.getByTestId("message-s_short_1").locator(".message-markdown").evaluate((element) => {
        const style = window.getComputedStyle(element);
        return {
          fontSize: style.fontSize,
          fontWeight: style.fontWeight,
          lineHeight: style.lineHeight
        };
      });
      expect(shortTypography).toEqual({
        fontSize: "22px",
        fontWeight: "600",
        lineHeight: "28.6px"
      });

      await expect(page.getByTestId("message-s_code_only")).toHaveAttribute(
        "data-message-chrome",
        "chromeless-code"
      );
      const mediumTypography = await page.getByTestId("message-s_medium_1").locator(".message-markdown").evaluate((element) => {
        const style = window.getComputedStyle(element);
        return {
          fontSize: style.fontSize,
          fontWeight: style.fontWeight,
          lineHeight: style.lineHeight
        };
      });
      expect(mediumTypography).toEqual({
        fontSize: "17px",
        fontWeight: "500",
        lineHeight: "25.5px"
      });
      const longTypography = await page.getByTestId("message-s_long_1").locator(".message-markdown").evaluate((element) => {
        const style = window.getComputedStyle(element);
        return {
          fontSize: style.fontSize,
          fontWeight: style.fontWeight,
          lineHeight: style.lineHeight
        };
      });
      expect(longTypography).toEqual({
        fontSize: "15px",
        fontWeight: "400",
        lineHeight: "22.5px"
      });
      const assistantBubbleRadius = await page
        .getByTestId("message-s_medium_1")
        .evaluate((element) => window.getComputedStyle(element).borderRadius);
      expect(assistantBubbleRadius).toBe("28px 28px 28px 6px / 30px 30px 20px 14px");
      await expect(page.getByTestId("message-s_rich_1").locator(".message-markdown table")).toContainText(
        "alpha"
      );
      const recentTimestamp = page.getByTestId("message-s_short_1").locator(".message-timestamp");
      await expect(recentTimestamp).toHaveText("just now");
      await expect(recentTimestamp).toHaveCSS("opacity", "0");
      await page.getByTestId("message-s_short_1").hover();
      await expect(recentTimestamp).toHaveCSS("opacity", "0.7");

      await waitForStableLayout(page, "message-s_rich_1");
      await expect(page.getByTestId("message-s_medium_1")).toHaveAttribute("data-message-size", "medium");
      const mediumMetrics = await page.getByTestId("message-s_medium_1").evaluate((element) => {
        const markdown = element.querySelector<HTMLElement>(".message-markdown");
        if (!markdown) {
          return null;
        }

        const markdownBox = markdown.getBoundingClientRect();
        const bubbleBox = element.getBoundingClientRect();
        const lineHeight = Number.parseFloat(window.getComputedStyle(markdown).lineHeight);
        return {
          bubbleWidth: Math.round(bubbleBox.width),
          lineCount: Math.round(markdownBox.height / lineHeight)
        };
      });
      expect(mediumMetrics).not.toBeNull();
      expect(mediumMetrics!.lineCount).toBeGreaterThanOrEqual(2);
      expect(mediumMetrics!.lineCount).toBeLessThanOrEqual(3);
      expect(mediumMetrics!.bubbleWidth).toBeLessThan(460);
      await expect(page.getByTestId("message-s_rich_1")).toHaveScreenshot(
        `phase4-rich-rendering-message-${appearance}.png`,
        {
          animations: "disabled",
          caret: "hide",
          maxDiffPixelRatio: 0.02
        }
      );

      await page.getByTestId("message-s_rich_2").click();
      const dialog = page.getByRole("dialog", { name: "Expanded message" });
      await expect(dialog).toContainText("Expanded view");
      await expect(dialog.locator("pre")).toContainText("console.log('phase4');");
      await expect(dialog.locator("table")).toContainText("beta");
      await expect(dialog).toHaveScreenshot(`phase4-rich-rendering-overlay-${appearance}.png`, {
        animations: "disabled",
        caret: "hide",
        maxDiffPixelRatio: 0.02
      });
      await dialog.getByRole("button", { name: "Close" }).click();
      await expect(dialog).toHaveCount(0);
    }

    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByTestId("message-s_long_1").dispatchEvent("pointerup", {
      bubbles: true,
      pointerType: "touch"
    });
    await expect(page.getByTestId("message-s_long_1")).toHaveClass(/message-bubble--timestamp-visible/);
    await expect(page.getByTestId("message-s_long_1").locator(".message-timestamp")).toContainText(
      /Yesterday,|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday/
    );
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

async function waitForStableLayout(
  page: import("@playwright/test").Page,
  testId: string
) {
  await page.getByTestId(testId).evaluate(async (element) => {
    function snapshot() {
      const rect = element.getBoundingClientRect();
      return [
        Math.round(rect.left),
        Math.round(rect.top),
        Math.round(rect.width),
        Math.round(rect.height)
      ].join(":");
    }

    const start = performance.now();
    let previous = snapshot();

    while (performance.now() - start < 3000) {
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      const current = snapshot();

      if (current === previous) {
        return;
      }

      previous = current;
    }

    throw new Error(`Layout for ${testId} did not stabilize`);
  });
}

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
