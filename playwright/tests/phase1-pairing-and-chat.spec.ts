import { test, expect } from "@playwright/test";
import { WebSocketServer } from "ws";

test("pair -> auth -> send -> receive -> reload -> transcript still usable", async ({
  page,
}) => {
  const port = 18_801 + Math.floor(Math.random() * 1_000);
  const sessionKey = "agent:main:clawline:flynn:main";
  const transcript = [
    {
      type: "message",
      id: "s_user_echo_1",
      role: "user",
      content: "hello from phase 1",
      timestamp: 1_764_133_200_100,
      streaming: false,
      deviceId: "DEVICE_TEST",
      sessionKey,
      attachments: [],
    },
    {
      type: "message",
      id: "s_assistant_1",
      role: "assistant",
      content: "Phase 1 is alive.",
      timestamp: 1_764_133_200_200,
      streaming: false,
      sessionKey,
      attachments: [],
    },
  ];
  let currentDeviceId = "DEVICE_TEST";

  const wss = new WebSocketServer({ port });

  wss.on("connection", (socket) => {
    socket.on("message", (buffer) => {
      const payload = JSON.parse(buffer.toString()) as {
        type: string;
        id?: string;
        content?: string;
        deviceId?: string;
        sessionKey?: string;
      };

      if (payload.type === "pair_request") {
        currentDeviceId = payload.deviceId ?? currentDeviceId;
        socket.send(
          JSON.stringify({
            type: "pair_result",
            success: true,
            token: "jwt-test-token",
            userId: "user_flynn",
          }),
        );
        return;
      }

      if (payload.type === "auth") {
        currentDeviceId = payload.deviceId ?? currentDeviceId;
        socket.send(
          JSON.stringify({
            type: "auth_result",
            success: true,
            userId: "user_flynn",
            sessionId: "sess_1",
            isAdmin: false,
            replayCount: transcript.length,
            replayTruncated: false,
            historyReset: false,
            sessions: [{ stream: "main", sessionKey }],
          }),
        );
        socket.send(
          JSON.stringify({
            type: "session_info",
            userId: "user_flynn",
            isAdmin: false,
            sessionKeys: [sessionKey],
          }),
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
                createdAt: 1_764_133_200_000,
                updatedAt: 1_764_133_200_000,
              },
            ],
          }),
        );
        for (const message of transcript) {
          socket.send(JSON.stringify(message));
        }
        return;
      }

      if (payload.type === "message" && payload.id && payload.content) {
        socket.send(JSON.stringify({ type: "ack", id: payload.id }));
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_user_echo_live",
            role: "user",
            content: payload.content,
            timestamp: 1_764_133_201_000,
            streaming: false,
            deviceId: currentDeviceId,
            sessionKey: payload.sessionKey,
            attachments: [],
          }),
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_assistant_live",
            role: "assistant",
            content: "stream",
            timestamp: 1_764_133_201_200,
            streaming: true,
            sessionKey: payload.sessionKey,
            attachments: [],
          }),
        );
        socket.send(
          JSON.stringify({
            type: "message",
            id: "s_assistant_live",
            role: "assistant",
            content: "stream complete",
            timestamp: 1_764_133_201_400,
            streaming: false,
            sessionKey: payload.sessionKey,
            attachments: [],
          }),
        );
      }
    });
  });

  try {
    await page.goto("/pair");
    await page.getByLabel("Name").fill("Flynn Browser");
    await page.getByLabel("Provider address").fill(`ws://127.0.0.1:${port}/ws`);
    await page.getByRole("button", { name: "Pair browser" }).click();

    await expect(page).toHaveURL(
      new RegExp(`/chat/${escapeForRegExp(sessionKey)}$`),
    );
    await expect(page.getByText("Phase 1 is alive.")).toBeVisible();

    await page.getByLabel("Message").fill("hello from phase 1");
    await page.getByRole("button", { name: "Send" }).click();

    await expect(page.getByText("stream complete")).toBeVisible();
    await expect(page.getByText("Sending...")).toHaveCount(0);
    await expect(page.getByText("stream complete")).toBeVisible();

    await page.reload();

    await expect(page.getByText("Phase 1 is alive.")).toBeVisible();
    await expect(page.getByText("stream complete")).toBeVisible();
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
