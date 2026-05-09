import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocketServer } from "ws";

test("file input, paste, and drag-drop stage attachments and send them through upload + websocket paths", async ({
  page
}) => {
  test.setTimeout(45_000);
  const port = 22_931 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  const uploadRequests: Array<{ filename: string; mimeType: string }> = [];
  const socketMessages: Array<{
    attachments: unknown[];
    content: string;
    id: string;
    sessionKey?: string;
    type: string;
  }> = [];
  const uploadsByAssetId = new Map<string, { body: Buffer; mimeType: string }>();
  let nextAssetNumber = 1;
  let nextServerMessageNumber = 1;
  let pairedDeviceId = "";

  const server = createServer(async (request, response) => {
    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);

    response.setHeader("Access-Control-Allow-Origin", "*");
    response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");

    if (request.method === "OPTIONS") {
      response.writeHead(204);
      response.end();
      return;
    }

    if (url.pathname === "/upload" && request.method === "POST") {
      if (request.headers.authorization !== "Bearer jwt-phase4-token") {
        response.writeHead(401, { "Content-Type": "application/json" });
        response.end(
          JSON.stringify({
            error: {
              code: "auth_failed",
              message: "Invalid token"
            }
          })
        );
        return;
      }

      const body = await readBody(request);
      const parsed = parseMultipartUpload(body);
      uploadRequests.push({
        filename: parsed.filename,
        mimeType: parsed.mimeType
      });

      const assetId = `a_upload_${nextAssetNumber}`;
      nextAssetNumber += 1;
      uploadsByAssetId.set(assetId, {
        body: parsed.fileBytes,
        mimeType: parsed.mimeType
      });

      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(
        JSON.stringify({
          assetId,
          mimeType: parsed.mimeType,
          size: parsed.fileBytes.length
        })
      );
      return;
    }

    if (url.pathname.startsWith("/download/")) {
      if (request.headers.authorization !== "Bearer jwt-phase4-token") {
        response.writeHead(401);
        response.end();
        return;
      }

      const assetId = url.pathname.split("/").pop() ?? "";
      const uploaded = uploadsByAssetId.get(assetId);
      if (!uploaded) {
        response.writeHead(404);
        response.end();
        return;
      }

      response.writeHead(200, {
        "Content-Type": uploaded.mimeType
      });
      response.end(uploaded.body);
      return;
    }

    response.writeHead(404);
    response.end();
  });

  const wss = new WebSocketServer({ server, path: "/ws" });
  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as {
        attachments?: unknown[];
        content?: string;
        id?: string;
        sessionKey?: string;
        type: string;
      };

      if (payload.type === "pair_request") {
        pairedDeviceId =
          "deviceId" in payload && typeof payload.deviceId === "string"
            ? payload.deviceId
            : "";
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-phase4-token",
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
            replayCount: 0,
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
                displayName: "Personal",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: 1_764_202_600_000,
                updatedAt: 1_764_202_600_000,
                adopted: false
              }
            ]
          })
        );
        return;
      }

      if (payload.type === "message") {
        socketMessages.push({
          attachments: payload.attachments ?? [],
          content: payload.content ?? "",
          id: payload.id ?? "",
          sessionKey: payload.sessionKey,
          type: payload.type
        });

        socket.send(
          JSON.stringify({
            type: "ack",
            id: payload.id
          })
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: `s_upload_${nextServerMessageNumber}`,
            role: "user",
            content: payload.content ?? "",
            timestamp: 1_764_202_600_100 + nextServerMessageNumber,
            streaming: false,
            deviceId: pairedDeviceId,
            sessionKey,
            attachments: (payload.attachments ?? []).map((attachment) => {
              if (
                attachment &&
                typeof attachment === "object" &&
                "type" in attachment &&
                attachment.type === "asset"
              ) {
                return {
                  type: "asset",
                  assetId:
                    "assetId" in attachment && typeof attachment.assetId === "string"
                      ? attachment.assetId
                      : ""
                };
              }

              return attachment;
            })
          })
        );
        nextServerMessageNumber += 1;
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, "127.0.0.1", () => resolve());
  });

  try {
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`));

    await page.locator('input[type="file"]').setInputFiles({
      name: "outline.pdf",
      mimeType: "application/pdf",
      buffer: Buffer.from("outline")
    });

    await page.locator("#composer-input").evaluate((element) => {
      const dataTransfer = new DataTransfer();
      dataTransfer.items.add(
        new File([new Uint8Array([137, 80, 78, 71])], "clip.png", {
          type: "image/png"
        })
      );
      const event = new Event("paste", { bubbles: true, cancelable: true });
      Object.defineProperty(event, "clipboardData", {
        value: dataTransfer
      });
      element.dispatchEvent(event);
    });

    await page.locator(".composer-shell").evaluate((element) => {
      const dataTransfer = new DataTransfer();
      dataTransfer.items.add(new File(["audio"], "note.mp3", { type: "audio/mpeg" }));
      for (const type of ["dragenter", "dragover", "drop"]) {
        const event = new Event(type, { bubbles: true, cancelable: true });
        Object.defineProperty(event, "dataTransfer", {
          value: dataTransfer
        });
        element.dispatchEvent(event);
      }
    });

    await page.getByLabel("Message").fill("Attachment send");

    await expect(page.getByTestId("composer-attachments")).toContainText("outline.pdf");
    await expect(page.getByTestId("composer-attachments")).toContainText("clip.png");
    await expect(page.getByTestId("composer-attachments")).toContainText("note.mp3");

    await page.getByRole("button", { name: "Send" }).click();

    await expect.poll(() => uploadRequests).toHaveLength(2);
    await expect
      .poll(() => uploadRequests.map((request) => request.filename))
      .toEqual(["outline.pdf", "note.mp3"]);
    await expect.poll(() => socketMessages).toHaveLength(1);
    await expect.poll(() => socketMessages[0]?.attachments).toEqual([
      {
        type: "asset",
        assetId: "a_upload_1"
      },
      {
        type: "image",
        mimeType: "image/png",
        data: "iVBORw=="
      },
      {
        type: "asset",
        assetId: "a_upload_2"
      }
    ]);

    const sentBubble = page.getByTestId("message-s_upload_1");
    await expect(sentBubble.getByRole("button", { name: "Download outline.pdf" })).toBeVisible();
    await expect(sentBubble.getByAltText("clip.png")).toBeVisible();
    await expect(sentBubble.getByLabel("note.mp3")).toBeVisible();
    await expect(page.getByTestId("composer-attachments")).toHaveCount(0);
  } finally {
    await page.goto("about:blank");
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

function escapeForRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseMultipartUpload(body: Buffer) {
  const text = body.toString("latin1");
  const filenameMatch = text.match(/filename=\"([^\"]+)\"/);
  const mimeTypeMatch = text.match(/Content-Type: ([^\r\n]+)/);
  const headerTerminator = text.indexOf("\r\n\r\n");
  if (!filenameMatch || !mimeTypeMatch || headerTerminator < 0) {
    throw new Error("Failed to parse multipart upload");
  }

  const contentStart = headerTerminator + 4;
  const closingBoundaryIndex = text.lastIndexOf("\r\n--");
  const fileBytes = body.subarray(contentStart, closingBoundaryIndex);

  return {
    filename: filenameMatch[1],
    fileBytes,
    mimeType: mimeTypeMatch[1]
  };
}

async function readBody(request: Parameters<typeof createServer>[0]) {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}
