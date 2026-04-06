import { createServer } from "node:http";
import { expect, test } from "@playwright/test";
import { WebSocket, WebSocketServer } from "ws";

test.setTimeout(90_000);

test("stream manager handles create, rename, delete, track, untrack, provisioning gating, and reload persistence", async ({
  page
}) => {
  const port = 20_901 + Math.floor(Math.random() * 1_000);
  const mainSessionKey = "agent:main:clawline:flynn:main";
  const sideSessionKey = "agent:main:clawline:flynn:side";
  const createdSessionKey = "agent:main:clawline:flynn:s_created";
  const trackableSessionKey = "agent:main:openclaw:flynn:s_trackable";

  const streams = [
    {
      sessionKey: mainSessionKey,
      displayName: "Personal",
      kind: "main",
      orderIndex: 0,
      isBuiltIn: true,
      createdAt: 1_764_133_400_000,
      updatedAt: 1_764_133_400_000,
      adopted: false
    },
    {
      sessionKey: sideSessionKey,
      displayName: "Side Thread",
      kind: "custom",
      orderIndex: 1,
      isBuiltIn: false,
      createdAt: 1_764_133_400_100,
      updatedAt: 1_764_133_400_100,
      adopted: false
    }
  ];
  const provisionedSessionKeys = new Set<string>([mainSessionKey, sideSessionKey]);
  let trackableSessions = [
    {
      sessionKey: trackableSessionKey,
      displayName: "External Session",
      updatedAt: 1_764_133_400_200
    }
  ];
  const sockets = new Set<WebSocket>();
  let delayNextAuthResult = false;
  let releaseDelayedAuth: (() => void) | null = null;
  let delayedAuthRequested: Promise<void> | null = null;
  let resolveDelayedAuthRequested: (() => void) | null = null;

  const server = createServer(async (request, response) => {
    response.setHeader("Access-Control-Allow-Origin", "*");
    response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    response.setHeader(
      "Access-Control-Allow-Methods",
      "GET,POST,PATCH,DELETE,OPTIONS"
    );
    response.setHeader("Content-Type", "application/json");

    if (request.method === "OPTIONS") {
      response.writeHead(204);
      response.end();
      return;
    }

    if (request.headers.authorization !== "Bearer jwt-test-token") {
      response.writeHead(401);
      response.end(JSON.stringify({ error: { code: "auth_failed" } }));
      return;
    }

    const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);

    if (request.method === "GET" && url.pathname === "/api/streams") {
      response.writeHead(200);
      response.end(JSON.stringify({ streams }));
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/trackable-sessions") {
      response.writeHead(200);
      response.end(JSON.stringify({ sessions: trackableSessions }));
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/streams") {
      const body = (await readJson(request)) as { displayName: string };
      const nextStream = {
        sessionKey: createdSessionKey,
        displayName: body.displayName,
        kind: "custom",
        orderIndex: 3,
        isBuiltIn: false,
        createdAt: 1_764_133_401_000,
        updatedAt: 1_764_133_401_000,
        adopted: false
      };
      streams.push(nextStream);
      response.writeHead(200);
      response.end(JSON.stringify({ stream: nextStream }));
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/streams/adopt") {
      const body = (await readJson(request)) as { sessionKey: string };
      const candidate = trackableSessions.find(
        (session) => session.sessionKey === body.sessionKey
      );
      const nextStream = {
        sessionKey: body.sessionKey,
        displayName: candidate?.displayName ?? body.sessionKey,
        kind: "custom",
        orderIndex: 4,
        isBuiltIn: false,
        createdAt: 1_764_133_402_000,
        updatedAt: 1_764_133_402_000,
        adopted: true
      };
      streams.push(nextStream);
      trackableSessions = trackableSessions.filter(
        (session) => session.sessionKey !== body.sessionKey
      );
      response.writeHead(200);
      response.end(JSON.stringify({ stream: nextStream }));
      return;
    }

    if (request.method === "PATCH" && url.pathname.startsWith("/api/streams/")) {
      const sessionKey = decodeURIComponent(url.pathname.slice("/api/streams/".length));
      const body = (await readJson(request)) as { displayName: string };
      const target = streams.find((stream) => stream.sessionKey === sessionKey);
      if (!target) {
        response.writeHead(404);
        response.end(JSON.stringify({ error: { code: "stream_not_found" } }));
        return;
      }
      target.displayName = body.displayName;
      target.updatedAt += 1;
      response.writeHead(200);
      response.end(JSON.stringify({ stream: target }));
      return;
    }

    if (request.method === "DELETE" && url.pathname.startsWith("/api/streams/")) {
      const sessionKey = decodeURIComponent(url.pathname.slice("/api/streams/".length));
      const streamIndex = streams.findIndex((stream) => stream.sessionKey === sessionKey);
      if (streamIndex === -1) {
        response.writeHead(404);
        response.end(JSON.stringify({ error: { code: "stream_not_found" } }));
        return;
      }
      const [deletedStream] = streams.splice(streamIndex, 1);
      provisionedSessionKeys.delete(sessionKey);
      if (deletedStream.adopted) {
        trackableSessions = [
          ...trackableSessions,
          {
            sessionKey,
            displayName: deletedStream.displayName,
            updatedAt: deletedStream.updatedAt
          }
        ];
      }
      response.writeHead(200);
      response.end(JSON.stringify({ deletedSessionKey: sessionKey }));
      return;
    }

    response.writeHead(404);
    response.end(JSON.stringify({ error: { code: "not_found" } }));
  });

  const wss = new WebSocketServer({ server, path: "/ws" });
  function broadcast(payload: unknown) {
    const serialized = JSON.stringify(payload);
    for (const socket of sockets) {
      socket.send(serialized);
    }
  }

  wss.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => {
      sockets.delete(socket);
    });
    socket.on("message", async (buffer) => {
      const payload = JSON.parse(buffer.toString()) as {
        type: string;
      };

      if (payload.type === "pair_request") {
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-test-token",
            userId: "user_flynn"
          })
        );
        return;
      }

      if (payload.type === "auth") {
        if (delayNextAuthResult) {
          delayNextAuthResult = false;
          resolveDelayedAuthRequested?.();
          await new Promise<void>((resolve) => {
            releaseDelayedAuth = resolve;
          });
          releaseDelayedAuth = null;
        }

        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            isAdmin: true,
            replayCount: 0,
            sessionKeys: [...provisionedSessionKeys]
          })
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: true,
            sessionKeys: [...provisionedSessionKeys]
          })
        );
        socket.send(
          JSON.stringify({
            type: "stream_snapshot",
            streams
          })
        );
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

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));

    await page.getByRole("button", { name: "Manage streams" }).click();
    await page.getByTestId("session-popover").getByRole("button", { name: "Add stream" }).click();
    await page.getByLabel("New stream name").fill("Research");
    await page.getByRole("button", { name: "Create" }).click();

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(createdSessionKey)}$`));
    await expect(
      page.getByText("This session is unavailable for sending. Switch streams and try again.")
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Send" })).toBeDisabled();

    await page.getByRole("button", { name: "Manage streams" }).click();
    await page.getByTestId("session-popover").getByRole("button", { name: "Add stream" }).click();
    const createdCard = page.locator(".stream-manager-card").filter({
      hasText: createdSessionKey
    });
    await expect(createdCard.getByText("unavailable")).toBeVisible();
    await createdCard.getByRole("button", { name: "Rename" }).click();
    await createdCard.getByLabel("Rename Research").fill("Research v2");
    await createdCard.getByRole("button", { name: "Save" }).click();
    await expect(createdCard.getByText("Research v2")).toBeVisible();

    delayNextAuthResult = true;
    delayedAuthRequested = new Promise<void>((resolve) => {
      resolveDelayedAuthRequested = resolve;
    });
    for (const socket of sockets) {
      socket.close();
    }

    await expect(
      page.getByText("This session is waiting for provisioning before send becomes available.")
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Send" })).toBeDisabled();

    await delayedAuthRequested;
    provisionedSessionKeys.add(createdSessionKey);
    releaseDelayedAuth?.();
    resolveDelayedAuthRequested = null;
    delayedAuthRequested = null;

    await expect(page.locator("#composer-input")).toHaveAttribute(
      "placeholder",
      `Research v2 — ${createdSessionKey}`
    );
    await expect(page.getByRole("button", { name: "Send" })).toBeDisabled();

    await createdCard.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await expect(createdCard).toHaveCount(0);

    await page.getByRole("button", { name: "Manage streams" }).click();
    await page.getByTestId("session-popover").getByRole("button", { name: "Add stream" }).click();
    const trackCard = page.locator(".stream-manager-card").filter({
      hasText: trackableSessionKey
    });
    await trackCard.getByRole("button", { name: "Track" }).click();
    await expect(page).toHaveURL(
      new RegExp(`/chat/${escapeForRegExp(trackableSessionKey)}$`)
    );
    await expect(
      page.getByText("This session is unavailable for sending. Switch streams and try again.")
    ).toBeVisible();

    await page.getByRole("button", { name: "Manage streams" }).click();
    await page.getByTestId("session-popover").getByRole("button", { name: "Add stream" }).click();
    const adoptedCard = page.locator(".stream-manager-card").filter({
      hasText: trackableSessionKey
    });
    await adoptedCard.getByRole("button", { name: "Untrack" }).click();
    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await page.getByRole("button", { name: "Manage streams" }).click();
    await page.getByTestId("session-popover").getByRole("button", { name: "Add stream" }).click();
    await expect(trackCard.getByRole("button", { name: "Track" })).toBeVisible();

    const sideCard = page.locator(".stream-manager-card").filter({
      hasText: sideSessionKey
    });
    await sideCard.getByRole("button", { name: "Rename" }).click();
    await sideCard.getByLabel("Rename Side Thread").fill("Side Thread v2");
    await sideCard.getByRole("button", { name: "Save" }).click();
    await expect(sideCard.getByText("Side Thread v2")).toBeVisible();

    await page.getByRole("button", { name: "Close" }).click();
    await page.reload();

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await page.getByRole("button", { name: "Manage streams" }).click();
    await expect(page.locator(".session-sheet-card").filter({ hasText: "Personal" })).toHaveCount(
      1
    );
    await expect(page.locator(".session-sheet-card").nth(0)).toContainText("Personal");
    await expect(page.locator(".session-sheet-card").nth(1)).toContainText("Side Thread v2");
    await expect(page.locator(".session-sheet-card").filter({ hasText: "Research v2" })).toHaveCount(
      0
    );
    await expect(
      page.locator(".session-sheet-card").filter({ hasText: "External Session" })
    ).toHaveCount(0);

    await page.getByTestId("session-popover").getByRole("button", { name: "Add stream" }).click();
    await expect(
      page.locator(".stream-manager-card").filter({ hasText: sideSessionKey })
    ).toContainText("Side Thread v2");
    await expect(
      page.locator(".stream-manager-card").filter({ hasText: createdSessionKey })
    ).toHaveCount(0);
    await expect(
      page.locator(".stream-manager-card").filter({ hasText: trackableSessionKey })
    ).toHaveCount(1);

    await trackCard.getByRole("button", { name: "Track" }).click();
    await expect(page).toHaveURL(
      new RegExp(`/chat/${escapeForRegExp(trackableSessionKey)}$`)
    );
    await page.getByRole("button", { name: "Manage streams" }).click();
    await page.getByTestId("session-popover").getByRole("button", { name: "Add stream" }).click();
    await expect(
      page.locator(".stream-manager-card").filter({ hasText: trackableSessionKey })
    ).toContainText("Tracked session");

    const adoptedStreamIndex = streams.findIndex(
      (stream) => stream.sessionKey === trackableSessionKey
    );
    expect(adoptedStreamIndex).toBeGreaterThanOrEqual(0);
    streams.splice(adoptedStreamIndex, 1);
    provisionedSessionKeys.delete(trackableSessionKey);
    trackableSessions = [
      {
        sessionKey: trackableSessionKey,
        displayName: "External Session",
        updatedAt: 1_764_133_400_200
      }
    ];

    broadcast({
      type: "stream_deleted",
      sessionKey: trackableSessionKey
    });
    broadcast({
      type: "session_info",
      userId: "user_flynn",
      isAdmin: true,
      sessionKeys: [...provisionedSessionKeys]
    });

    await expect(page).toHaveURL(new RegExp(`/chat/${escapeForRegExp(mainSessionKey)}$`));
    await expect(
      page.locator(".stream-manager-card").filter({ hasText: trackableSessionKey })
    ).toHaveCount(1);
    await expect(
      page
        .locator(".stream-manager-card")
        .filter({ hasText: trackableSessionKey })
        .getByRole("button", { name: "Track" })
    ).toBeVisible();
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

async function readJson(request: import("node:http").IncomingMessage) {
  const chunks: Buffer[] = [];

  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
}
