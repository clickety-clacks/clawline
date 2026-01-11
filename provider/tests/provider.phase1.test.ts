import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";

import { createProviderServer, type Adapter, type ProviderConfig } from "../src/index";

const TEST_PROTOCOL_VERSION = 1;

const log = (...args: unknown[]) => {
  if (process.env.VITEST_DEBUG === "1") {
    console.log("[phase1-test]", ...args);
  }
};

class RecordingAdapter implements Adapter {
  public capabilities = { streaming: false };
  public calls: Array<{ prompt: string }> = [];

  async execute(prompt: string) {
    this.calls.push({ prompt });
    return { exitCode: 0, output: `assistant:${prompt}` };
  }

  async executeWithTUI(prompt: string) {
    return this.execute(prompt);
  }
}

type SocketQueue = {
  buffered: any[];
  pending: Array<{ resolve: (value: any) => void; reject: (err: Error) => void; timer: NodeJS.Timeout }>;
};

const socketQueues = new WeakMap<WebSocket, SocketQueue>();

function ensureSocketQueue(ws: WebSocket) {
  if (socketQueues.has(ws)) {
    return;
  }
  const entry: SocketQueue = { buffered: [], pending: [] };
  socketQueues.set(ws, entry);
  const flushError = (err: Error) => {
    while (entry.pending.length > 0) {
      const wait = entry.pending.shift()!;
      clearTimeout(wait.timer);
      wait.reject(err);
    }
  };
  ws.on("message", (data) => {
    const json = JSON.parse(data.toString());
    if (entry.pending.length > 0) {
      const wait = entry.pending.shift()!;
      clearTimeout(wait.timer);
      wait.resolve(json);
    } else {
      entry.buffered.push(json);
    }
  });
  ws.on("error", (err) => flushError(err instanceof Error ? err : new Error(String(err))));
  ws.on("close", () => flushError(new Error("Socket closed")));
}

function waitForMessage<T>(ws: WebSocket, timeoutMs = 5000): Promise<T> {
  ensureSocketQueue(ws);
  const entry = socketQueues.get(ws)!;
  if (entry.buffered.length > 0) {
    return Promise.resolve(entry.buffered.shift() as T);
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      entry.pending = entry.pending.filter((pending) => pending.timer !== timer);
      reject(new Error("Timed out waiting for message"));
    }, timeoutMs);
    entry.pending.push({ resolve, reject, timer });
  });
}

function waitForNoMessage(ws: WebSocket, timeoutMs = 300): Promise<void> {
  ensureSocketQueue(ws);
  const entry = socketQueues.get(ws)!;
  if (entry.buffered.length > 0) {
    return Promise.reject(new Error("Expected no message but buffered queue was not empty"));
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      resolve();
    }, timeoutMs);
    const onMessage = () => {
      cleanup();
      reject(new Error("Expected no message but received one"));
    };
    const onError = (err: Error) => {
      cleanup();
      reject(err);
    };
    const onClose = () => {
      cleanup();
      reject(new Error("Socket closed before silence window elapsed"));
    };
    const cleanup = () => {
      clearTimeout(timer);
      ws.off("message", onMessage);
      ws.off("error", onError);
      ws.off("close", onClose);
    };
    ws.once("message", onMessage);
    ws.once("error", onError);
    ws.once("close", onClose);
  });
}

async function createTmpDir() {
  return mkdtemp(path.join(os.tmpdir(), "clawline-provider-"));
}

async function openSocket(port: number): Promise<WebSocket> {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  await new Promise((resolve) => socket.once("open", resolve));
  if (process.env.VITEST_DEBUG === "1") {
    socket.on("message", (data) => log("socket recv", data.toString()));
  }
  return socket;
}

type TestContext = {
  statePath: string;
  mediaPath: string;
  server: Awaited<ReturnType<typeof createProviderServer>>;
  adapter: RecordingAdapter;
};

async function bootServer(overrides?: Partial<ProviderConfig>): Promise<TestContext> {
  const statePath = await createTmpDir();
  const mediaPath = path.join(statePath, "media");
  const adapter = new RecordingAdapter();
  const server = await createProviderServer({
    config: {
      port: 0,
      statePath,
      media: {
        storagePath: mediaPath,
        maxInlineBytes: 262144,
        maxUploadBytes: 104857600,
        unreferencedUploadTtlSeconds: 3600
      },
      ...overrides
    },
    adapter,
    logger: {
      info: () => {},
      warn: () => {},
      error: () => {}
    }
  });
  await server.start();
  return { statePath, mediaPath, server, adapter };
}

describe.sequential("Clawline provider phase 1", () => {
  let ctx: TestContext | undefined;

  async function resetServer(overrides?: Partial<ProviderConfig>) {
    if (ctx) {
      await ctx.server.stop();
      await rm(ctx.statePath, { recursive: true, force: true });
      ctx = undefined;
    }
    ctx = await bootServer(overrides);
  }

  beforeEach(async () => {
    await resetServer();
  });

  afterEach(async () => {
    if (ctx) {
      await ctx.server.stop();
      await rm(ctx.statePath, { recursive: true, force: true });
      ctx = undefined;
    }
  });

  it("boots, handles pairing/auth, routes messages, and replays history", async () => {
    if (!ctx) throw new Error("missing ctx");
    const { server, statePath, adapter } = ctx;
    const port = server.getPort();

    log("fetch /version", port);
    const versionResp = await fetch(`http://127.0.0.1:${port}/version`);
    expect(versionResp.status).toBe(200);
    const versionJson = await versionResp.json();
    expect(versionJson).toEqual({ protocolVersion: TEST_PROTOCOL_VERSION });

    const adminDeviceId = randomUUID();
    const adminSocket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    await new Promise((resolve) => adminSocket.once("open", resolve));
    if (process.env.VITEST_DEBUG === "1") {
      adminSocket.on("message", (data) => {
        log("admin socket recv", data.toString());
      });
    }
    adminSocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: adminDeviceId,
        claimedName: "Admin",
        deviceInfo: {
          platform: "iOS",
          model: "iPhone",
          osVersion: "17.2",
          appVersion: "1.0"
        }
      })
    );
    log("waiting for admin pair_result");
    const pairResultAdmin = await waitForMessage<any>(adminSocket);
    expect(pairResultAdmin.type).toBe("pair_result");
    expect(pairResultAdmin.success).toBe(true);
    expect(typeof pairResultAdmin.token).toBe("string");
    expect(pairResultAdmin.userId).toMatch(/^user_/);
    log("admin paired, closing socket");
    adminSocket.close();

    const allowlistPath = path.join(statePath, "allowlist.json");
    const allowlistContent = JSON.parse(await readFile(allowlistPath, "utf8"));
    expect(allowlistContent.entries).toHaveLength(1);
    expect(allowlistContent.entries[0].isAdmin).toBe(true);

    const adminAuthSocket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    await new Promise((resolve) => adminAuthSocket.once("open", resolve));
    if (process.env.VITEST_DEBUG === "1") {
      adminAuthSocket.on("message", (data) => log("admin auth socket recv", data.toString()));
    }
    adminAuthSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: pairResultAdmin.token,
        deviceId: adminDeviceId,
        lastMessageId: null
      })
    );
    log("waiting for admin auth_result");
    const adminAuthResult = await waitForMessage<any>(adminAuthSocket);
    expect(adminAuthResult.type).toBe("auth_result");
    expect(adminAuthResult.success).toBe(true);

    const userDeviceId = randomUUID();
    const userPairSocket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    await new Promise((resolve) => userPairSocket.once("open", resolve));
    if (process.env.VITEST_DEBUG === "1") {
      userPairSocket.on("message", (data) => log("user pair socket recv", data.toString()));
    }
    userPairSocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: userDeviceId,
        claimedName: "User",
        deviceInfo: {
          platform: "iOS",
          model: "iPhone",
          osVersion: "17.2",
          appVersion: "1.0"
        }
      })
    );

    log("waiting for approval request");
    const approvalRequest = await waitForMessage<any>(adminAuthSocket);
    expect(approvalRequest.type).toBe("pair_approval_request");
    expect(approvalRequest.deviceId).toBe(userDeviceId);

    const newUserId = `user_${randomUUID()}`;
    adminAuthSocket.send(
      JSON.stringify({
        type: "pair_decision",
        deviceId: userDeviceId,
        userId: newUserId,
        approve: true
      })
    );

    log("waiting for user pair_result");
    const userPairResult = await waitForMessage<any>(userPairSocket);
    expect(userPairResult.type).toBe("pair_result");
    expect(userPairResult.success).toBe(true);
    expect(userPairResult.userId).toBe(newUserId);
    const userToken = userPairResult.token;
    userPairSocket.close();

    const userSocket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    await new Promise((resolve) => userSocket.once("open", resolve));
    if (process.env.VITEST_DEBUG === "1") {
      userSocket.on("message", (data) => log("user socket recv", data.toString()));
    }
    userSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: userToken,
        deviceId: userDeviceId,
        lastMessageId: null
      })
    );

    log("waiting for user auth_result");
    const authResult = await waitForMessage<any>(userSocket);
    expect(authResult.success).toBe(true);
    expect(authResult.userId).toBe(newUserId);
    expect(authResult.replayCount).toBe(0);

    const messageId = `c_${randomUUID()}`;
    const messageContent = "Hello";
    userSocket.send(
      JSON.stringify({
        type: "message",
        id: messageId,
        content: messageContent
      })
    );

    log("waiting for ack");
    const ack = await waitForMessage<any>(userSocket);
    expect(ack.type).toBe("ack");
    expect(ack.id).toBe(messageId);

    log("waiting for user echo");
    const userEcho = await waitForMessage<any>(userSocket);
    expect(userEcho.type).toBe("message");
    expect(userEcho.role).toBe("user");
    expect(userEcho.content).toBe(messageContent);
    expect(userEcho.deviceId).toBe(userDeviceId);

    log("waiting for assistant message");
    const assistantMessage = await waitForMessage<any>(userSocket);
    expect(assistantMessage.type).toBe("message");
    expect(assistantMessage.role).toBe("assistant");
    expect(assistantMessage.streaming).toBe(false);
    expect(assistantMessage.content).toContain(messageContent);

    expect(adapter.calls).toHaveLength(1);

    userSocket.send(
      JSON.stringify({
        type: "message",
        id: messageId,
        content: messageContent
      })
    );
    log("waiting for retry ack");
    const retryAck = await waitForMessage<any>(userSocket);
    expect(retryAck.type).toBe("ack");
    expect(adapter.calls).toHaveLength(1);
    await waitForNoMessage(userSocket);

    const takeoverSocket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    await new Promise((resolve) => takeoverSocket.once("open", resolve));
    if (process.env.VITEST_DEBUG === "1") {
      takeoverSocket.on("message", (data) => log("takeover socket recv", data.toString()));
    }
    takeoverSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: userToken,
        deviceId: userDeviceId,
        lastMessageId: assistantMessage.id
      })
    );
    log("waiting for takeover auth_result");
    const takeoverAuthResult = await waitForMessage<any>(takeoverSocket);
    expect(takeoverAuthResult.success).toBe(true);

    log("waiting for session_replaced message");
    const sessionReplaced = await waitForMessage<any>(userSocket);
    expect(sessionReplaced.type).toBe("error");
    expect(sessionReplaced.code).toBe("session_replaced");

    const replayingSocket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    await new Promise((resolve) => replayingSocket.once("open", resolve));
    if (process.env.VITEST_DEBUG === "1") {
      replayingSocket.on("message", (data) => log("replay socket recv", data.toString()));
    }
    replayingSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: userToken,
        deviceId: userDeviceId,
        lastMessageId: null
      })
    );

    log("waiting for replay auth_result");
    const replayAuth = await waitForMessage<any>(replayingSocket);
    expect(replayAuth.replayCount).toBeGreaterThanOrEqual(2);
    let received = 0;
    while (received < replayAuth.replayCount) {
      await waitForMessage<any>(replayingSocket);
      received += 1;
    }

    replayingSocket.close();
    takeoverSocket.close();
    adminAuthSocket.close();
  });

  it("enforces rate limits and pending TTL", async () => {
    await resetServer({
      pairing: {
        maxPendingRequests: 5,
        maxRequestsPerMinute: 1,
        pendingTtlSeconds: 1
      },
      auth: { maxAttemptsPerMinute: 2 },
      sessions: { maxMessagesPerSecond: 1 }
    });
    if (!ctx) throw new Error("missing ctx");
    const port = ctx.server.getPort();

    const adminDeviceId = randomUUID();
    const adminPairSocket = await openSocket(port);
    adminPairSocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: adminDeviceId,
        claimedName: "Admin",
        deviceInfo: {
          platform: "iOS",
          model: "iPhone",
          osVersion: "17.2",
          appVersion: "1.0"
        }
      })
    );
    const adminPairResult = await waitForMessage<any>(adminPairSocket);
    adminPairSocket.close();
    const adminAuthSocket = await openSocket(port);
    adminAuthSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: adminPairResult.token,
        deviceId: adminDeviceId,
        lastMessageId: null
      })
    );
    const adminAuthResult = await waitForMessage<any>(adminAuthSocket);
    expect(adminAuthResult.success).toBe(true);

    const ttlDeviceId = randomUUID();
    const ttlSocket = await openSocket(port);
    ttlSocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: ttlDeviceId,
        claimedName: "TTL",
        deviceInfo: {
          platform: "iOS",
          model: "iPhone",
          osVersion: "17.2",
          appVersion: "1.0"
        }
      })
    );
    const ttlApproval = await waitForMessage<any>(adminAuthSocket);
    expect(ttlApproval.type).toBe("pair_approval_request");
    expect(ttlApproval.deviceId).toBe(ttlDeviceId);
    const ttlResult = await waitForMessage<any>(ttlSocket, 5000);
    expect(ttlResult.type).toBe("pair_result");
    expect(ttlResult.success).toBe(false);
    expect(ttlResult.reason).toBe("pair_timeout");
    ttlSocket.close();

    const rateSocket = await openSocket(port);
    rateSocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: ttlDeviceId,
        claimedName: "TTL",
        deviceInfo: {
          platform: "iOS",
          model: "iPhone",
          osVersion: "17.2",
          appVersion: "1.0"
        }
      })
    );
    const rateLimited = await waitForMessage<any>(rateSocket);
    expect(rateLimited.type).toBe("error");
    expect(rateLimited.code).toBe("rate_limited");
    rateSocket.close();

    const authDeviceId = randomUUID();
    for (let i = 0; i < 2; i += 1) {
      const socket = await openSocket(port);
      socket.send(
        JSON.stringify({
          type: "auth",
          protocolVersion: TEST_PROTOCOL_VERSION,
          token: "bad",
          deviceId: authDeviceId,
          lastMessageId: null
        })
      );
      const resp = await waitForMessage<any>(socket);
      expect(resp.type).toBe("auth_result");
      expect(resp.success).toBe(false);
      expect(resp.reason).toBe("auth_failed");
      socket.close();
    }
    const limitedAuthSocket = await openSocket(port);
    limitedAuthSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: "bad",
        deviceId: authDeviceId,
        lastMessageId: null
      })
    );
    const limitedAuthResult = await waitForMessage<any>(limitedAuthSocket);
    expect(limitedAuthResult.type).toBe("auth_result");
    expect(limitedAuthResult.success).toBe(false);
    expect(limitedAuthResult.reason).toBe("rate_limited");
    limitedAuthSocket.close();

    const messageLimitedDeviceId = randomUUID();
    const messagePairSocket = await openSocket(port);
    messagePairSocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: messageLimitedDeviceId,
        claimedName: "Limiter",
        deviceInfo: {
          platform: "iOS",
          model: "iPhone",
          osVersion: "17.2",
          appVersion: "1.0"
        }
      })
    );
    const approval = await waitForMessage<any>(adminAuthSocket);
    expect(approval.deviceId).toBe(messageLimitedDeviceId);
    const newUserId = `user_${randomUUID()}`;
    adminAuthSocket.send(
      JSON.stringify({
        type: "pair_decision",
        deviceId: messageLimitedDeviceId,
        userId: newUserId,
        approve: true
      })
    );
    const messagePairResult = await waitForMessage<any>(messagePairSocket);
    expect(messagePairResult.success).toBe(true);
    const limitedToken = messagePairResult.token;
    messagePairSocket.close();

    const userSocket = await openSocket(port);
    userSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: limitedToken,
        deviceId: messageLimitedDeviceId,
        lastMessageId: null
      })
    );
    const limitedAuth = await waitForMessage<any>(userSocket);
    expect(limitedAuth.success).toBe(true);

    const firstMessageId = `c_${randomUUID()}`;
    userSocket.send(JSON.stringify({ type: "message", id: firstMessageId, content: "one" }));
    await waitForMessage<any>(userSocket); // ack
    await waitForMessage<any>(userSocket); // user echo
    await waitForMessage<any>(userSocket); // assistant message

    const secondMessageId = `c_${randomUUID()}`;
    userSocket.send(JSON.stringify({ type: "message", id: secondMessageId, content: "two" }));
    const rateMessage = await waitForMessage<any>(userSocket);
    expect(rateMessage.type).toBe("error");
    expect(rateMessage.code).toBe("rate_limited");
    userSocket.close();
    adminAuthSocket.close();
  });

  it("sanitizes claimed names and device info before persisting", async () => {
    if (!ctx) throw new Error("missing ctx");
    const { server, statePath } = ctx;
    const port = server.getPort();

    const adminDeviceId = randomUUID();
    const adminPairSocket = await openSocket(port);
    adminPairSocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: adminDeviceId,
        claimedName: "Admin",
        deviceInfo: {
          platform: "iOS",
          model: "iPhone",
          osVersion: "17.2",
          appVersion: "1.0"
        }
      })
    );
    const adminPairResult = await waitForMessage<any>(adminPairSocket);
    adminPairSocket.close();

    const adminAuthSocket = await openSocket(port);
    adminAuthSocket.send(
      JSON.stringify({
        type: "auth",
        protocolVersion: TEST_PROTOCOL_VERSION,
        token: adminPairResult.token,
        deviceId: adminDeviceId,
        lastMessageId: null
      })
    );
    await waitForMessage<any>(adminAuthSocket);

    const messyDeviceId = randomUUID();
    const messySocket = await openSocket(port);
    messySocket.send(
      JSON.stringify({
        type: "pair_request",
        protocolVersion: TEST_PROTOCOL_VERSION,
        deviceId: messyDeviceId,
        claimedName: "  Bad\u0007Name\n ",
        deviceInfo: {
          platform: "iOS\u0000\x1fPro",
          model: "iPhone 16 Pro Max\n",
          osVersion: "17.2.0-beta\nbuild",
          appVersion: "1.0.0\nbeta"
        }
      })
    );
    const messyApproval = await waitForMessage<any>(adminAuthSocket);
    expect(messyApproval.deviceId).toBe(messyDeviceId);
    const messyUserId = `user_${randomUUID()}`;
    adminAuthSocket.send(
      JSON.stringify({
        type: "pair_decision",
        deviceId: messyDeviceId,
        userId: messyUserId,
        approve: true
      })
    );
    const messyResult = await waitForMessage<any>(messySocket);
    expect(messyResult.success).toBe(true);
    messySocket.close();
    adminAuthSocket.close();

    const allowlistPath = path.join(statePath, "allowlist.json");
    const allowlist = JSON.parse(await readFile(allowlistPath, "utf8"));
    const entry = allowlist.entries.find((row: any) => row.deviceId === messyDeviceId);
    expect(entry).toBeDefined();
    expect(entry.claimedName).toBe("BadName");
    expect(entry.deviceInfo.platform).toBe("iOSPro");
    expect(entry.deviceInfo.model.length).toBeLessThanOrEqual(64);
    expect(entry.deviceInfo.osVersion.includes("\n")).toBe(false);
    expect(entry.deviceInfo.appVersion.includes("\n")).toBe(false);
  });
});
