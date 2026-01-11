import http from "node:http";
import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";
import { watchFile, unwatchFile } from "node:fs";
import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";

import WebSocket, { WebSocketServer } from "ws";
import Database from "better-sqlite3";
import jwt from "jsonwebtoken";

export const PROTOCOL_VERSION = 1;

export interface Adapter {
  capabilities?: { streaming?: boolean };
  execute: (
    prompt: string
  ) => Promise<{ exitCode: number; output: string } | { exitCode?: number; output?: string } | string>;
  executeWithTUI?: (
    prompt: string,
    tui: { writeOutput: (chunk: string | Buffer) => void | Promise<void> }
  ) => Promise<{ exitCode: number; output: string } | { exitCode?: number; output?: string } | string>;
}

export interface ProviderConfig {
  port: number;
  statePath: string;
  network: {
    bindAddress: string;
    allowInsecurePublic: boolean;
    allowedOrigins?: string[];
  };
  adapter?: string | null;
  auth: {
    jwtSigningKey?: string | null;
    tokenTtlSeconds: number | null;
    maxAttemptsPerMinute: number;
    reissueGraceSeconds: number;
  };
  pairing: {
    maxPendingRequests: number;
    maxRequestsPerMinute: number;
    pendingTtlSeconds: number;
  };
  media: {
    storagePath: string;
    maxInlineBytes: number;
    maxUploadBytes: number;
    unreferencedUploadTtlSeconds: number;
  };
  sessions: {
    maxMessageBytes: number;
    maxReplayMessages: number;
    maxPromptMessages: number;
    maxMessagesPerSecond: number;
    maxTypingPerSecond: number;
    typingAutoExpireSeconds: number;
    maxQueuedMessages: number;
    maxWriteQueueDepth: number;
    adapterExecuteTimeoutSeconds: number;
    streamInactivitySeconds: number;
  };
  streams: {
    chunkPersistIntervalMs: number;
    chunkBufferBytes: number;
  };
}

export interface ProviderOptions {
  config?: Partial<ProviderConfig>;
  adapter: Adapter;
  logger?: Logger;
}

export interface ProviderServer {
  start(): Promise<void>;
  stop(): Promise<void>;
  getPort(): number;
}

export type Logger = {
  info: (...args: any[]) => void;
  warn: (...args: any[]) => void;
  error: (...args: any[]) => void;
};

type AllowlistEntry = {
  deviceId: string;
  claimedName?: string;
  deviceInfo: DeviceInfo;
  userId: string;
  isAdmin: boolean;
  tokenDelivered: boolean;
  createdAt: number;
  lastSeenAt: number | null;
};

type AllowlistFile = { version: 1; entries: AllowlistEntry[] };

type DeviceInfo = {
  platform: string;
  model: string;
  osVersion?: string;
  appVersion?: string;
};

const CONTROL_CHARS_REGEX = /[\u0000-\u001F\u007F]/g;
const UUID_V4_REGEX = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;
const SERVER_EVENT_ID_REGEX = /^s_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

class SlidingWindowRateLimiter {
  private readonly history = new Map<string, number[]>();
  private cleanupCounter = 0;

  constructor(private readonly limit: number, private readonly windowMs: number) {}

  attempt(key: string): boolean {
    if (this.limit <= 0) {
      return true;
    }
    const now = Date.now();
    if (++this.cleanupCounter % 1000 === 0) {
      this.cleanup(now);
    }
    const timestamps = this.history.get(key) ?? [];
    while (timestamps.length > 0 && now - timestamps[0] >= this.windowMs) {
      timestamps.shift();
    }
    if (timestamps.length >= this.limit) {
      this.history.set(key, timestamps);
      return false;
    }
    timestamps.push(now);
    this.history.set(key, timestamps);
    return true;
  }

  private cleanup(now: number) {
    for (const [key, timestamps] of this.history) {
      if (timestamps.length === 0) {
        this.history.delete(key);
        continue;
      }
      const last = timestamps[timestamps.length - 1];
      if (now - last >= this.windowMs) {
        this.history.delete(key);
      }
    }
  }
}

function truncateUtf8(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value, "utf8") <= maxBytes) {
    return value;
  }
  let bytes = 0;
  let result = "";
  for (const char of value) {
    const charBytes = Buffer.byteLength(char, "utf8");
    if (bytes + charBytes > maxBytes) {
      break;
    }
    result += char;
    bytes += charBytes;
  }
  return result;
}

function sanitizeLabel(label?: string): string | undefined {
  if (typeof label !== "string") {
    return undefined;
  }
  const stripped = label.replace(CONTROL_CHARS_REGEX, "").trim();
  if (!stripped) {
    return undefined;
  }
  return truncateUtf8(stripped, 64);
}

function sanitizeDeviceInfo(info: DeviceInfo): DeviceInfo {
  const sanitizeField = (value: string | undefined) => {
    if (typeof value !== "string") {
      return undefined;
    }
    const stripped = value.replace(CONTROL_CHARS_REGEX, "").trim();
    if (!stripped) {
      return undefined;
    }
    return truncateUtf8(stripped, 64);
  };
  return {
    platform: sanitizeField(info.platform) ?? "",
    model: sanitizeField(info.model) ?? "",
    osVersion: sanitizeField(info.osVersion),
    appVersion: sanitizeField(info.appVersion)
  };
}

function timingSafeStringEqual(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) {
    return false;
  }
  return timingSafeEqual(bufA, bufB);
}

function validateDeviceInfo(value: any): value is DeviceInfo {
  if (!value || typeof value !== "object") {
    return false;
  }
  const requiredString = (input: unknown) =>
    typeof input === "string" && input.length > 0 && Buffer.byteLength(input, "utf8") <= 64;
  if (!requiredString(value.platform) || !requiredString(value.model)) {
    return false;
  }
  if (value.osVersion !== undefined && (!requiredString(value.osVersion) && value.osVersion !== "")) {
    return false;
  }
  if (value.appVersion !== undefined && (!requiredString(value.appVersion) && value.appVersion !== "")) {
    return false;
  }
  return true;
}

type PendingPairRequest = {
  deviceId: string;
  socket: WebSocket;
  claimedName?: string;
  deviceInfo: DeviceInfo;
  createdAt: number;
};

type Session = {
  socket: WebSocket;
  deviceId: string;
  userId: string;
  isAdmin: boolean;
  sessionId: string;
};

type ConnectionState = {
  authenticated: boolean;
  deviceId?: string;
  userId?: string;
  isAdmin?: boolean;
  sessionId?: string;
};

type ServerMessage = {
  type: "message";
  id: string;
  role: "user" | "assistant";
  content: string;
  timestamp: number;
  streaming: boolean;
  attachments?: unknown[];
  deviceId?: string;
};

enum MessageStreamingState {
  Finalized = 0,
  Active = 1,
  Failed = 2
}

const DEFAULT_CONFIG: ProviderConfig = {
  port: 18792,
  statePath: path.join(os.homedir(), ".clawd", "clawline"),
  network: {
    bindAddress: "127.0.0.1",
    allowInsecurePublic: false,
    allowedOrigins: []
  },
  adapter: null,
  auth: {
    jwtSigningKey: null,
    tokenTtlSeconds: 31_536_000,
    maxAttemptsPerMinute: 5,
    reissueGraceSeconds: 600
  },
  pairing: {
    maxPendingRequests: 100,
    maxRequestsPerMinute: 5,
    pendingTtlSeconds: 300
  },
  media: {
    storagePath: path.join(os.homedir(), ".clawd", "clawline-media"),
    maxInlineBytes: 262_144,
    maxUploadBytes: 104_857_600,
    unreferencedUploadTtlSeconds: 3600
  },
  sessions: {
    maxMessageBytes: 65_536,
    maxReplayMessages: 500,
    maxPromptMessages: 200,
    maxMessagesPerSecond: 5,
    maxTypingPerSecond: 2,
    typingAutoExpireSeconds: 10,
    maxQueuedMessages: 20,
    maxWriteQueueDepth: 1000,
    adapterExecuteTimeoutSeconds: 300,
    streamInactivitySeconds: 300
  },
  streams: {
    chunkPersistIntervalMs: 100,
    chunkBufferBytes: 1_048_576
  }
};

const ALLOWLIST_FILENAME = "allowlist.json";
const DENYLIST_FILENAME = "denylist.json";
const JWT_KEY_FILENAME = "jwt.key";
const DB_FILENAME = "clawline.sqlite";
const SESSION_REPLACED_CODE = 1000;

function mergeConfig(partial?: Partial<ProviderConfig>): ProviderConfig {
  const merged = JSON.parse(JSON.stringify(DEFAULT_CONFIG)) as ProviderConfig;
  if (!partial) {
    return merged;
  }
  return deepMerge(merged, partial);
}

function deepMerge<T>(target: T, source: Partial<T>): T {
  for (const [key, value] of Object.entries(source) as [keyof T, any][]) {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      (target as any)[key] = deepMerge((target as any)[key] ?? {}, value);
    } else if (value !== undefined) {
      (target as any)[key] = value;
    }
  }
  return target;
}

function isLocalhost(address: string): boolean {
  return ["127.0.0.1", "::1", "localhost"].includes(address);
}

async function ensureDir(dir: string) {
  await fs.mkdir(dir, { recursive: true });
}

async function loadJsonFile<T>(filePath: string, fallback: T): Promise<T> {
  try {
    const data = await fs.readFile(filePath, "utf8");
    return JSON.parse(data) as T;
  } catch (err: any) {
    if (err && (err.code === "ENOENT" || err.code === "ENOTDIR")) {
      await fs.writeFile(filePath, JSON.stringify(fallback, null, 2));
      return fallback;
    }
    throw err;
  }
}

async function loadAllowlist(filePath: string): Promise<AllowlistFile> {
  return loadJsonFile<AllowlistFile>(filePath, { version: 1, entries: [] });
}

async function loadDenylist(filePath: string): Promise<{ deviceId: string }[]> {
  return loadJsonFile(filePath, [] as { deviceId: string }[]);
}

async function ensureJwtKey(filePath: string, provided?: string | null): Promise<string> {
  const validateKey = (value: string) => {
    const trimmed = value.trim();
    if (Buffer.byteLength(trimmed, "utf8") < 64) {
      throw new Error("JWT signing key must be at least 32 bytes (64 hex characters)");
    }
    return trimmed;
  };
  if (provided) {
    return validateKey(provided);
  }
  try {
    const data = await fs.readFile(filePath, "utf8");
    return validateKey(data);
  } catch (err: any) {
    if (err && err.code !== "ENOENT") {
      throw err;
    }
    const key = randomBytes(32).toString("hex");
    await fs.writeFile(filePath, key, { mode: 0o600 });
    return key;
  }
}

const userSequenceStmt = (
  db: Database.Database
) =>
  db.prepare(
    `INSERT INTO user_sequences (userId, nextSequence)
     VALUES (?, 1)
     ON CONFLICT(userId)
     DO UPDATE SET nextSequence = user_sequences.nextSequence + 1
     RETURNING nextSequence as sequence`
  );

function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

function normalizeAttachmentsHash(): string {
  return sha256("[]");
}

type AdapterExecutionResult = { exitCode?: number; output?: string } | string;

function normalizeAdapterResult(result: AdapterExecutionResult): { exitCode: number; output: string } {
  if (typeof result === "string") {
    return { exitCode: 0, output: result };
  }
  return {
    exitCode: result?.exitCode ?? 0,
    output: result?.output ?? ""
  };
}

function nowMs(): number {
  return Date.now();
}

function generateServerMessageId(): string {
  return `s_${randomUUID()}`;
}

function generateUserId(): string {
  return `user_${randomUUID()}`;
}

function buildPromptFromEvents(
  events: ServerMessage[],
  maxPromptMessages: number,
  appendedUserContent: string
): string {
  const trimmed = events
    .filter((event) => event.role === "user" || event.role === "assistant")
    .slice(-maxPromptMessages + 1);
  const lines = trimmed.map((event) => `${event.role === "user" ? "User" : "Assistant"}: ${event.content}`);
  lines.push(`User: ${appendedUserContent}`);
  return lines.join("\n");
}

function parseServerMessage(json: string): ServerMessage {
  return JSON.parse(json) as ServerMessage;
}

export async function createProviderServer(options: ProviderOptions): Promise<ProviderServer> {
  const config = mergeConfig(options.config);
  const logger: Logger = options.logger ?? console;

  if (!config.network.allowInsecurePublic && !isLocalhost(config.network.bindAddress)) {
    throw new Error("allowInsecurePublic must be true to bind non-localhost");
  }
  if (
    config.network.allowInsecurePublic &&
    !isLocalhost(config.network.bindAddress) &&
    (!config.network.allowedOrigins || config.network.allowedOrigins.length === 0)
  ) {
    throw new Error("allowedOrigins must be configured when binding to a public interface");
  }

  await ensureDir(config.statePath);
  await ensureDir(config.media.storagePath);

  const allowlistPath = path.join(config.statePath, ALLOWLIST_FILENAME);
  const denylistPath = path.join(config.statePath, DENYLIST_FILENAME);
  const jwtKeyPath = path.join(config.statePath, JWT_KEY_FILENAME);
  const dbPath = path.join(config.statePath, DB_FILENAME);

  let allowlist = await loadAllowlist(allowlistPath);
  let denylist = await loadDenylist(denylistPath);
  const jwtKey = await ensureJwtKey(jwtKeyPath, config.auth.jwtSigningKey);

  const db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.exec(`
    CREATE TABLE IF NOT EXISTS user_sequences (
      userId TEXT PRIMARY KEY,
      nextSequence INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS events (
      id TEXT PRIMARY KEY,
      userId TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      originatingDeviceId TEXT,
      payloadJson TEXT NOT NULL,
      payloadBytes INTEGER NOT NULL,
      timestamp INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_events_userId_sequence ON events(userId, sequence);
    CREATE INDEX IF NOT EXISTS idx_events_userId ON events(userId);
    CREATE TABLE IF NOT EXISTS messages (
      deviceId TEXT NOT NULL,
      userId TEXT NOT NULL,
      clientId TEXT NOT NULL,
      serverEventId TEXT NOT NULL,
      serverSequence INTEGER NOT NULL,
      content TEXT NOT NULL,
      contentHash TEXT NOT NULL,
      attachmentsHash TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      streaming INTEGER NOT NULL,
      ackSent INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (deviceId, clientId)
    );
    CREATE INDEX IF NOT EXISTS idx_messages_userId ON messages(userId);
    CREATE INDEX IF NOT EXISTS idx_messages_serverEventId ON messages(serverEventId);
  `);

  const sequenceStatement = userSequenceStmt(db);
  const insertEventStmt = db.prepare(
    `INSERT INTO events (id, userId, sequence, originatingDeviceId, payloadJson, payloadBytes, timestamp)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  );
  const updateMessageAckStmt = db.prepare(`UPDATE messages SET ackSent = 1 WHERE deviceId = ? AND clientId = ?`);
  const insertMessageStmt = db.prepare(
    `INSERT INTO messages (deviceId, userId, clientId, serverEventId, serverSequence, content, contentHash, attachmentsHash, timestamp, streaming, ackSent)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ${MessageStreamingState.Active}, 0)`
  );
  const selectMessageStmt = db.prepare(
    `SELECT deviceId, userId, clientId, serverEventId, serverSequence, content, contentHash, attachmentsHash, timestamp, streaming, ackSent
     FROM messages WHERE deviceId = ? AND clientId = ?`
  );
  const updateMessageStreamingStmt = db.prepare(`UPDATE messages SET streaming = ? WHERE deviceId = ? AND clientId = ?`);
  const insertUserMessageTx = db.transaction(
    (session: Session, messageId: string, content: string, timestamp: number) => {
      const serverMessageId = generateServerMessageId();
      const event: ServerMessage = {
        type: "message",
        id: serverMessageId,
        role: "user",
        content,
        timestamp,
        streaming: false,
        deviceId: session.deviceId
      };
      const payloadJson = JSON.stringify(event);
      const payloadBytes = Buffer.byteLength(payloadJson, "utf8");
      const sequenceRow = sequenceStatement.get(session.userId) as { sequence: number };
      insertEventStmt.run(
        serverMessageId,
        session.userId,
        sequenceRow.sequence,
        session.deviceId,
        payloadJson,
        payloadBytes,
        timestamp
      );
      insertMessageStmt.run(
        session.deviceId,
        session.userId,
        messageId,
        serverMessageId,
        sequenceRow.sequence,
        content,
        sha256(content),
        normalizeAttachmentsHash(),
        timestamp
      );
      return { event, sequence: sequenceRow.sequence };
    }
  );

  const selectEventsAfterStmt = db.prepare(
    `SELECT id, payloadJson FROM events WHERE userId = ? AND sequence > ? ORDER BY sequence ASC`
  );
  const selectEventsTailStmt = db.prepare(
    `SELECT id, payloadJson FROM events WHERE userId = ? ORDER BY sequence DESC LIMIT ?`
  );
  const selectAnchorStmt = db.prepare(`SELECT sequence FROM events WHERE id = ? AND userId = ?`);
  const insertEventTx = db.transaction((event: ServerMessage, userId: string, originatingDeviceId?: string) => {
    const payloadJson = JSON.stringify(event);
    const payloadBytes = Buffer.byteLength(payloadJson, "utf8");
    const sequenceRow = sequenceStatement.get(userId) as { sequence: number };
    insertEventStmt.run(event.id, userId, sequenceRow.sequence, originatingDeviceId ?? null, payloadJson, payloadBytes, event.timestamp);
    return sequenceRow.sequence;
  });

  const httpServer = http.createServer(async (req, res) => {
    if (!req.url) {
      res.writeHead(404).end();
      return;
    }
    if (req.method === "GET" && req.url === "/version") {
      res.setHeader("Content-Type", "application/json");
      res.writeHead(200);
      res.end(JSON.stringify({ protocolVersion: PROTOCOL_VERSION }));
      return;
    }
    res.writeHead(404).end();
  });

  const wss = new WebSocketServer({ noServer: true });

  httpServer.on("upgrade", (request, socket, head) => {
    if (request.url !== "/ws") {
      socket.destroy();
      return;
    }
    if (config.network.allowedOrigins && config.network.allowedOrigins.length > 0) {
      const origin = request.headers.origin ?? "null";
      if (!config.network.allowedOrigins.includes(origin)) {
        socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
        socket.destroy();
        return;
      }
    }
    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit("connection", ws, request);
    });
  });

  const connectionState = new WeakMap<WebSocket, ConnectionState>();
  const pendingPairs = new Map<string, PendingPairRequest>();
  const sessionsByDevice = new Map<string, Session>();
  const userSessions = new Map<string, Set<Session>>();
  const perUserQueue = new Map<string, Promise<unknown>>();
  const pairRateLimiter = new SlidingWindowRateLimiter(config.pairing.maxRequestsPerMinute, 60_000);
  const authRateLimiter = new SlidingWindowRateLimiter(config.auth.maxAttemptsPerMinute, 60_000);
  const messageRateLimiter = new SlidingWindowRateLimiter(config.sessions.maxMessagesPerSecond, 1_000);
  const pendingCleanupInterval = setInterval(() => expirePendingPairs(), 1_000);
  if (typeof pendingCleanupInterval.unref === "function") {
    pendingCleanupInterval.unref();
  }
  const denylistWatcher = () => {
    refreshDenylist();
  };
  watchFile(denylistPath, { interval: 5_000 }, denylistWatcher);

  function runPerUserTask<T>(userId: string, task: () => Promise<T>): Promise<T> {
    const previous = perUserQueue.get(userId) ?? Promise.resolve();
    const next = previous.then(task, task).finally(() => {
      if (perUserQueue.get(userId) === next) {
        perUserQueue.delete(userId);
      }
    });
    perUserQueue.set(userId, next);
    return next;
  }

  async function persistAllowlist() {
    await fs.writeFile(allowlistPath, JSON.stringify(allowlist, null, 2));
  }

  async function refreshDenylist() {
    try {
      const next = await loadDenylist(denylistPath);
      const newlyRevoked = next.filter(
        (entry) => !denylist.some((existing) => existing.deviceId === entry.deviceId)
      );
      denylist = next;
      for (const revoked of newlyRevoked) {
        const session = sessionsByDevice.get(revoked.deviceId);
        if (session) {
          sendJson(session.socket, { type: "error", code: "token_revoked", message: "Device revoked" })
            .catch(() => {})
            .finally(() => session.socket.close(1008));
        }
      }
    } catch (err) {
      logger.warn("denylist_reload_failed", err);
    }
  }

  function findAllowlistEntry(deviceId: string) {
    return allowlist.entries.find((entry) => entry.deviceId === deviceId);
  }

  async function upsertAllowlistEntry(entry: AllowlistEntry) {
    const idx = allowlist.entries.findIndex((existing) => existing.deviceId === entry.deviceId);
    if (idx >= 0) {
      allowlist.entries[idx] = entry;
    } else {
      allowlist.entries.push(entry);
    }
    await persistAllowlist();
  }

  function isDenylisted(deviceId: string) {
    return denylist.some((entry) => entry.deviceId === deviceId);
  }

  function issueToken(entry: AllowlistEntry): string {
    const payload: jwt.JwtPayload = {
      sub: entry.userId,
      deviceId: entry.deviceId,
      isAdmin: entry.isAdmin,
      iat: Math.floor(Date.now() / 1000)
    };
    if (config.auth.tokenTtlSeconds) {
      payload.exp = payload.iat! + config.auth.tokenTtlSeconds;
    }
    const token = jwt.sign(payload, jwtKey, { algorithm: "HS256" });
    return token;
  }

  async function setTokenDelivered(deviceId: string, delivered: boolean) {
    const entry = findAllowlistEntry(deviceId);
    if (!entry) return;
    entry.tokenDelivered = delivered;
    await persistAllowlist();
  }

  async function updateLastSeen(deviceId: string, timestamp: number) {
    const entry = findAllowlistEntry(deviceId);
    if (!entry) return;
    entry.lastSeenAt = timestamp;
    await persistAllowlist();
  }

  function sendJson(ws: WebSocket, payload: unknown): Promise<void> {
    return new Promise((resolve, reject) => {
      if (ws.readyState !== WebSocket.OPEN) {
        reject(new Error("socket not open"));
        return;
      }
      ws.send(JSON.stringify(payload), (err) => {
        if (err) {
          reject(err);
        } else {
          resolve();
        }
      });
    });
  }

  function markAckSent(deviceId: string, clientId: string) {
    updateMessageAckStmt.run(deviceId, clientId);
  }

  function selectEventsAfter(userId: string, lastMessageId: string | null) {
    if (!lastMessageId) {
      const rows = selectEventsTailStmt.all(userId, config.sessions.maxReplayMessages);
      return rows.map((row) => parseServerMessage(row.payloadJson)).reverse();
    }
    const anchor = selectAnchorStmt.get(lastMessageId, userId) as
      | { sequence: number }
      | undefined;
    if (!anchor) {
      const tail = selectEventsTailStmt.all(userId, config.sessions.maxReplayMessages);
      return tail.map((row) => parseServerMessage(row.payloadJson)).reverse();
    }
    const rows = selectEventsAfterStmt.all(userId, anchor.sequence);
    return rows.map((row) => parseServerMessage(row.payloadJson));
  }

  async function sendReplay(session: Session, lastMessageId: string | null) {
    const events = selectEventsAfter(session.userId, lastMessageId);
    const payload = {
      type: "auth_result",
      success: true,
      userId: session.userId,
      sessionId: session.sessionId,
      replayCount: events.length,
      replayTruncated: false,
      historyReset: lastMessageId ? false : true
    };
    await sendJson(session.socket, payload);
    for (const event of events) {
      await sendJson(session.socket, event);
    }
  }

  function broadcastToUser(userId: string, payload: ServerMessage) {
    const sessions = userSessions.get(userId);
    if (!sessions) return;
    for (const session of sessions) {
      if (session.socket.readyState !== WebSocket.OPEN) continue;
      session.socket.send(JSON.stringify(payload), (err) => {
        if (err) {
          session.socket.close();
        }
      });
    }
  }

  async function appendEvent(event: ServerMessage, userId: string, originatingDeviceId?: string) {
    return insertEventTx(event, userId, originatingDeviceId);
  }

  function persistUserMessage(
    session: Session,
    messageId: string,
    content: string
  ): { event: ServerMessage; sequence: number } {
    const timestamp = nowMs();
    return insertUserMessageTx(session, messageId, content, timestamp);
  }

  async function persistAssistantMessage(
    session: Session,
    content: string
  ): Promise<ServerMessage> {
    const timestamp = nowMs();
    const event: ServerMessage = {
      type: "message",
      id: generateServerMessageId(),
      role: "assistant",
      content,
      timestamp,
      streaming: false
    };
    await appendEvent(event, session.userId);
    return event;
  }

  function getConversationEvents(userId: string) {
    const rows = db
      .prepare(`SELECT payloadJson FROM events WHERE userId = ? ORDER BY sequence ASC LIMIT ?`)
      .all(userId, config.sessions.maxPromptMessages - 1);
    return rows.map((row) => parseServerMessage(row.payloadJson));
  }

  function removeSession(session: Session) {
    sessionsByDevice.delete(session.deviceId);
    const sessions = userSessions.get(session.userId);
    if (sessions) {
      sessions.delete(session);
      if (sessions.size === 0) {
        userSessions.delete(session.userId);
      }
    }
  }

  function registerSession(session: Session) {
    const existing = sessionsByDevice.get(session.deviceId);
    if (existing && existing.socket !== session.socket) {
      sendJson(existing.socket, { type: "error", code: "session_replaced", message: "Session replaced" })
        .catch(() => {})
        .finally(() => existing.socket.close(SESSION_REPLACED_CODE));
      removeSession(existing);
    }
    sessionsByDevice.set(session.deviceId, session);
    const set = userSessions.get(session.userId) ?? new Set();
    set.add(session);
    userSessions.set(session.userId, set);
  }

  async function processClientMessage(session: Session, payload: any) {
    if (payload.type !== "message") {
      await sendJson(session.socket, { type: "error", code: "invalid_message", message: "Unsupported type" });
      return;
    }
    if (typeof payload.id !== "string" || !payload.id.startsWith("c_")) {
      await sendJson(session.socket, { type: "error", code: "invalid_message", message: "Invalid id" });
      return;
    }
    if (typeof payload.content !== "string" || payload.content.length === 0) {
      await sendJson(session.socket, { type: "error", code: "invalid_message", message: "Missing content" });
      return;
    }
    const contentBytes = Buffer.byteLength(payload.content, "utf8");
    if (contentBytes > config.sessions.maxMessageBytes) {
      await sendJson(session.socket, { type: "error", code: "payload_too_large", message: "Message too large" });
      return;
    }

    await runPerUserTask(session.userId, async () => {
      const existing = selectMessageStmt.get(session.deviceId, payload.id) as
        | {
            deviceId: string;
            contentHash: string;
            attachmentsHash: string;
            streaming: number;
            ackSent: number;
          }
        | undefined;
      const incomingHash = sha256(payload.content);
      if (existing) {
        if (existing.contentHash !== incomingHash || existing.attachmentsHash !== normalizeAttachmentsHash()) {
          await sendJson(session.socket, { type: "error", code: "invalid_message", message: "Duplicate mismatch" });
          return;
        }
        if (existing.streaming === MessageStreamingState.Failed) {
          await sendJson(session.socket, { type: "error", code: "invalid_message", message: "Message failed" });
          return;
        }
        if (existing.ackSent === 0) {
          session.socket.send(JSON.stringify({ type: "ack", id: payload.id }), (err) => {
            if (!err) {
              markAckSent(session.deviceId, payload.id);
            }
          });
        } else {
          session.socket.send(JSON.stringify({ type: "ack", id: payload.id }), () => {});
        }
        return;
      }

      if (!messageRateLimiter.attempt(session.deviceId)) {
        await sendJson(session.socket, { type: "error", code: "rate_limited", message: "Too many messages" });
        return;
      }

      const { event } = persistUserMessage(session, payload.id, payload.content);
      await new Promise<void>((resolve) => {
        session.socket.send(JSON.stringify({ type: "ack", id: payload.id }), (err) => {
          if (!err) {
            markAckSent(session.deviceId, payload.id);
          }
          resolve();
        });
      });
      broadcastToUser(session.userId, event);

      const priorEvents = getConversationEvents(session.userId);
      const prompt = buildPromptFromEvents(priorEvents, config.sessions.maxPromptMessages, payload.content);
      try {
        const adapterResult = await Promise.race<AdapterExecutionResult>([
          options.adapter.execute(prompt),
          new Promise((_, reject) =>
            setTimeout(() => reject(new Error("adapter_timeout")), config.sessions.adapterExecuteTimeoutSeconds * 1000)
          )
        ]);
        const normalizedResult = normalizeAdapterResult(adapterResult);
        if ((normalizedResult.exitCode ?? 0) !== 0) {
          updateMessageStreamingStmt.run(MessageStreamingState.Failed, session.deviceId, payload.id);
          await sendJson(session.socket, {
            type: "error",
            code: "server_error",
            message: "Adapter error",
            messageId: payload.id
          });
          return;
        }
        const assistantEvent = await persistAssistantMessage(session, normalizedResult.output ?? "");
        broadcastToUser(session.userId, assistantEvent);
        updateMessageStreamingStmt.run(MessageStreamingState.Finalized, session.deviceId, payload.id);
      } catch (err) {
        updateMessageStreamingStmt.run(MessageStreamingState.Failed, session.deviceId, payload.id);
        await sendJson(session.socket, {
          type: "error",
          code: "server_error",
          message: "Adapter failure",
          messageId: payload.id
        });
      }
    });
  }

  async function notifyAdminsOfPending() {
    for (const session of sessionsByDevice.values()) {
      if (!session.isAdmin) continue;
      for (const pending of pendingPairs.values()) {
        await sendJson(session.socket, {
          type: "pair_approval_request",
          deviceId: pending.deviceId,
          claimedName: pending.claimedName,
          deviceInfo: pending.deviceInfo
        }).catch(() => {});
      }
    }
  }

  function expirePendingPairs() {
    if (config.pairing.pendingTtlSeconds <= 0) {
      return;
    }
    const now = nowMs();
    for (const [deviceId, pending] of pendingPairs) {
      if (now - pending.createdAt >= config.pairing.pendingTtlSeconds * 1000) {
        pendingPairs.delete(deviceId);
        sendJson(pending.socket, { type: "pair_result", success: false, reason: "pair_timeout" }).finally(() => {
          pending.socket.close(1000);
        });
      }
    }
  }

  function handleSocketClose(socket: WebSocket) {
    const state = connectionState.get(socket);
    if (!state) return;
    if (state.deviceId && state.userId && state.sessionId) {
      const session = sessionsByDevice.get(state.deviceId);
      if (session && session.socket === socket) {
        removeSession(session);
      }
    }

    for (const [deviceId, pending] of pendingPairs.entries()) {
      if (pending.socket === socket) {
        pendingPairs.delete(deviceId);
      }
    }
    connectionState.delete(socket);
  }

  function hasAdmin(): boolean {
    return allowlist.entries.some((entry) => entry.isAdmin);
  }

  function validateDeviceId(value: unknown): value is string {
    return typeof value === "string" && UUID_V4_REGEX.test(value);
  }

  wss.on("connection", (ws) => {
    connectionState.set(ws, { authenticated: false });

    ws.on("message", async (raw) => {
      let payload: any;
      try {
        payload = JSON.parse(raw.toString());
      } catch {
        await sendJson(ws, { type: "error", code: "invalid_message", message: "Malformed JSON" });
        ws.close();
        return;
      }
      if (!payload || typeof payload.type !== "string") {
        await sendJson(ws, { type: "error", code: "invalid_message", message: "Missing type" });
        return;
      }
      switch (payload.type) {
        case "pair_request":
          await handlePairRequest(ws, payload);
          break;
        case "pair_decision":
          await handlePairDecision(ws, payload);
          break;
        case "auth":
          await handleAuth(ws, payload);
          break;
        case "message":
          await handleAuthedMessage(ws, payload);
          break;
        default:
          await sendJson(ws, { type: "error", code: "invalid_message", message: "Unknown type" });
      }
    });

    ws.on("close", () => handleSocketClose(ws));
    ws.on("error", () => handleSocketClose(ws));
  });

  async function handlePairRequest(ws: WebSocket, payload: any) {
    if (payload.protocolVersion !== PROTOCOL_VERSION) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Unsupported protocol" });
      ws.close();
      return;
    }
    if (!validateDeviceId(payload.deviceId)) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Invalid deviceId" });
      return;
    }
    if (!pairRateLimiter.attempt(payload.deviceId)) {
      await sendJson(ws, { type: "error", code: "rate_limited", message: "Pairing rate limited" });
      ws.close(1008);
      return;
    }
    if (isDenylisted(payload.deviceId)) {
      await sendJson(ws, { type: "pair_result", success: false, reason: "pair_rejected" });
      ws.close();
      return;
    }
    if (!validateDeviceInfo(payload.deviceInfo)) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Invalid device info" });
      return;
    }
    const sanitizedInfo = sanitizeDeviceInfo(payload.deviceInfo);
    if (!sanitizedInfo.platform || !sanitizedInfo.model) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Invalid device info" });
      return;
    }
    const sanitizedClaimedName = sanitizeLabel(payload.claimedName);

    const entry = findAllowlistEntry(payload.deviceId);
    if (!hasAdmin()) {
      const userId = generateUserId();
      const newEntry: AllowlistEntry = {
        deviceId: payload.deviceId,
        claimedName: sanitizedClaimedName,
        deviceInfo: sanitizedInfo,
        userId,
        isAdmin: true,
        tokenDelivered: false,
        createdAt: nowMs(),
        lastSeenAt: null
      };
      allowlist.entries.push(newEntry);
      await persistAllowlist();
      const token = issueToken(newEntry);
      await sendJson(ws, { type: "pair_result", success: true, token, userId });
      await setTokenDelivered(payload.deviceId, true);
      ws.close();
      return;
    }

    if (entry && entry.tokenDelivered) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Device already paired" });
      ws.close();
      return;
    }

    if (pendingPairs.size >= config.pairing.maxPendingRequests) {
      await sendJson(ws, { type: "error", code: "rate_limited", message: "Too many pending requests" });
      ws.close(1008);
      return;
    }

    pendingPairs.set(payload.deviceId, {
      deviceId: payload.deviceId,
      socket: ws,
      claimedName: sanitizedClaimedName,
      deviceInfo: sanitizedInfo,
      createdAt: nowMs()
    });
    await notifyAdminsOfPending();
  }

  async function handlePairDecision(ws: WebSocket, payload: any) {
    const state = connectionState.get(ws);
    if (!state || !state.authenticated || !state.deviceId || !state.userId) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Not authenticated" });
      return;
    }
    const session = sessionsByDevice.get(state.deviceId);
    if (!session || !session.isAdmin) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Not admin" });
      return;
    }
    const pending = pendingPairs.get(payload.deviceId);
    if (!pending) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Unknown device" });
      return;
    }
    if (payload.approve !== true) {
      await sendJson(pending.socket, { type: "pair_result", success: false, reason: "pair_denied" });
      pendingPairs.delete(payload.deviceId);
      return;
    }
    const userId = typeof payload.userId === "string" && payload.userId.length > 0 ? payload.userId : generateUserId();
    const newEntry: AllowlistEntry = {
      deviceId: pending.deviceId,
      claimedName: pending.claimedName,
      deviceInfo: pending.deviceInfo,
      userId,
      isAdmin: false,
      tokenDelivered: false,
      createdAt: nowMs(),
      lastSeenAt: null
    };
    await upsertAllowlistEntry(newEntry);
    const token = issueToken(newEntry);
    await sendJson(pending.socket, { type: "pair_result", success: true, token, userId });
    await setTokenDelivered(pending.deviceId, true);
    pendingPairs.delete(pending.deviceId);
  }

  async function handleAuth(ws: WebSocket, payload: any) {
    if (payload.protocolVersion !== PROTOCOL_VERSION) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Unsupported protocol" });
      ws.close();
      return;
    }
    if (typeof payload.token !== "string" || !validateDeviceId(payload.deviceId)) {
      await sendJson(ws, { type: "auth_result", success: false, reason: "auth_failed" });
      ws.close();
      return;
    }
    if (!authRateLimiter.attempt(payload.deviceId)) {
      await sendJson(ws, { type: "auth_result", success: false, reason: "rate_limited" });
      ws.close(1008);
      return;
    }
    let decoded: jwt.JwtPayload;
    try {
      decoded = jwt.verify(payload.token, jwtKey, { algorithms: ["HS256"] }) as jwt.JwtPayload;
    } catch {
      await sendJson(ws, { type: "auth_result", success: false, reason: "auth_failed" });
      ws.close();
      return;
    }
    if (typeof decoded.deviceId !== "string" || !timingSafeStringEqual(decoded.deviceId, payload.deviceId)) {
      await sendJson(ws, { type: "auth_result", success: false, reason: "auth_failed" });
      ws.close();
      return;
    }
    const entry = findAllowlistEntry(payload.deviceId);
    if (!entry) {
      await sendJson(ws, { type: "auth_result", success: false, reason: "auth_failed" });
      ws.close();
      return;
    }
    if (typeof decoded.sub !== "string" || !timingSafeStringEqual(decoded.sub, entry.userId)) {
      await sendJson(ws, { type: "auth_result", success: false, reason: "auth_failed" });
      ws.close();
      return;
    }
    const session: Session = {
      socket: ws,
      deviceId: entry.deviceId,
      userId: entry.userId,
      isAdmin: entry.isAdmin,
      sessionId: `session_${randomUUID()}`
    };
    registerSession(session);
    connectionState.set(ws, {
      authenticated: true,
      deviceId: session.deviceId,
      userId: session.userId,
      isAdmin: session.isAdmin,
      sessionId: session.sessionId
    });
    try {
      await updateLastSeen(session.deviceId, nowMs());
      const lastMessageId =
        typeof payload.lastMessageId === "string" ? payload.lastMessageId : null;
      if (typeof payload.lastMessageId === "string" && !SERVER_EVENT_ID_REGEX.test(payload.lastMessageId)) {
        await sendJson(ws, { type: "error", code: "invalid_message", message: "Invalid lastMessageId" });
        ws.close();
        return;
      }
      await sendReplay(session, lastMessageId);
      if (session.isAdmin) {
        await notifyAdminsOfPending();
      }
    } catch (err) {
      removeSession(session);
      connectionState.delete(ws);
      await sendJson(ws, { type: "error", code: "server_error", message: "Replay failed" }).catch(() => {});
      ws.close(1011);
      return;
    }
  }

  async function handleAuthedMessage(ws: WebSocket, payload: any) {
    const state = connectionState.get(ws);
    if (!state || !state.authenticated || !state.deviceId || !state.userId) {
      await sendJson(ws, { type: "error", code: "auth_failed", message: "Not authenticated" });
      ws.close();
      return;
    }
    const session = sessionsByDevice.get(state.deviceId);
    if (!session) {
      await sendJson(ws, { type: "error", code: "auth_failed", message: "Session missing" });
      return;
    }
    await processClientMessage(session, payload);
  }

  let started = false;

  return {
    async start() {
      if (started) return;
      await new Promise<void>((resolve) => {
        httpServer.listen(config.port, config.network.bindAddress, () => resolve());
      });
      started = true;
      logger.info(`Provider listening on ${config.network.bindAddress}:${this.getPort()}`);
    },
    async stop() {
      if (!started) return;
      unwatchFile(denylistPath, denylistWatcher);
      clearInterval(pendingCleanupInterval);
      await new Promise<void>((resolve) => wss.close(() => resolve()));
      await new Promise<void>((resolve) => httpServer.close(() => resolve()));
      db.close();
      started = false;
    },
    getPort() {
      const addr = httpServer.address();
      if (!addr || typeof addr === "string") {
        return config.port;
      }
      return addr.port;
    }
  };
}
