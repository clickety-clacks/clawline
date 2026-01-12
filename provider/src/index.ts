import http from "node:http";
import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";
import { watchFile, unwatchFile, createWriteStream } from "node:fs";
import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";

import WebSocket, { WebSocketServer } from "ws";
import Database from "better-sqlite3";
import jwt from "jsonwebtoken";
import Busboy from "busboy";

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
const ASSET_ID_REGEX = /^a_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const USER_ID_PREFIX = "user_";
const INLINE_IMAGE_MIME_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic"]);
const MAX_ATTACHMENTS_COUNT = 4;
const MAX_TOTAL_PAYLOAD_BYTES = 320 * 1024;

type NormalizedAttachment =
  | { type: "image"; mimeType: string; data: string }
  | { type: "asset"; assetId: string };

class ClientMessageError extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

class HttpError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}

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

function normalizeAttachmentsInput(
  raw: unknown,
  mediaConfig: ProviderConfig["media"]
): { attachments: NormalizedAttachment[]; inlineBytes: number; assetIds: string[] } {
  if (raw === undefined) {
    return { attachments: [], inlineBytes: 0, assetIds: [] };
  }
  if (!Array.isArray(raw)) {
    throw new ClientMessageError("invalid_message", "attachments must be an array");
  }
  if (raw.length > MAX_ATTACHMENTS_COUNT) {
    throw new ClientMessageError("payload_too_large", "Too many attachments");
  }
  let inlineBytes = 0;
  const attachments: NormalizedAttachment[] = [];
  const assetIds: string[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") {
      throw new ClientMessageError("invalid_message", "Invalid attachment");
    }
    const typed = entry as any;
    if (typed.type === "image") {
      if (typeof typed.mimeType !== "string" || typeof typed.data !== "string") {
        throw new ClientMessageError("invalid_message", "Invalid inline attachment");
      }
      const mime = typed.mimeType.toLowerCase();
      if (!INLINE_IMAGE_MIME_TYPES.has(mime)) {
        throw new ClientMessageError("invalid_message", "Unsupported image type");
      }
      let decoded: Buffer;
      try {
        decoded = Buffer.from(typed.data, "base64");
      } catch {
        throw new ClientMessageError("invalid_message", "Invalid base64 data");
      }
      if (decoded.length === 0) {
        throw new ClientMessageError("invalid_message", "Empty attachment data");
      }
      if (decoded.length > mediaConfig.maxInlineBytes) {
        throw new ClientMessageError("payload_too_large", "Inline attachment too large");
      }
      inlineBytes += decoded.length;
      attachments.push({ type: "image", mimeType: mime, data: typed.data });
    } else if (typed.type === "asset") {
      if (typeof typed.assetId !== "string" || !ASSET_ID_REGEX.test(typed.assetId)) {
        throw new ClientMessageError("invalid_message", "Invalid assetId");
      }
      attachments.push({ type: "asset", assetId: typed.assetId });
      assetIds.push(typed.assetId);
    } else {
      throw new ClientMessageError("invalid_message", "Unknown attachment type");
    }
  }
  if (inlineBytes > mediaConfig.maxInlineBytes) {
    throw new ClientMessageError("payload_too_large", "Inline attachments exceed limit");
  }
  return { attachments, inlineBytes, assetIds };
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

function validateUserId(value: unknown): value is string {
  if (typeof value !== "string" || !value.startsWith(USER_ID_PREFIX)) {
    return false;
  }
  return UUID_V4_REGEX.test(value.slice(USER_ID_PREFIX.length));
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

function hashAttachments(attachments: NormalizedAttachment[]): string {
  const quote = (value: string) => JSON.stringify(value);
  if (attachments.length === 0) {
    return sha256("[]");
  }
  const parts = attachments.map((attachment) =>
    attachment.type === "image"
      ? `{"type":"image","mimeType":${quote(attachment.mimeType)},"data":${quote(attachment.data)}}`
      : `{"type":"asset","assetId":${quote(attachment.assetId)}}`
  );
  return sha256(`[${parts.join(",")}]`);
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
  const assetsDir = path.join(config.media.storagePath, "assets");
  const tmpDir = path.join(config.media.storagePath, "tmp");
  await ensureDir(assetsDir);
  await ensureDir(tmpDir);
  await cleanupTmpDirectory();

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
    CREATE TABLE IF NOT EXISTS assets (
      assetId TEXT PRIMARY KEY,
      userId TEXT NOT NULL,
      mimeType TEXT NOT NULL,
      size INTEGER NOT NULL,
      createdAt INTEGER NOT NULL,
      uploaderDeviceId TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_assets_userId ON assets(userId);
    CREATE INDEX IF NOT EXISTS idx_assets_createdAt ON assets(createdAt);
    CREATE TABLE IF NOT EXISTS message_assets (
      deviceId TEXT NOT NULL,
      clientId TEXT NOT NULL,
      assetId TEXT NOT NULL,
      PRIMARY KEY (deviceId, clientId, assetId),
      FOREIGN KEY (deviceId, clientId) REFERENCES messages(deviceId, clientId) ON DELETE CASCADE,
      FOREIGN KEY (assetId) REFERENCES assets(assetId) ON DELETE RESTRICT
    );
    CREATE INDEX IF NOT EXISTS idx_message_assets_assetId ON message_assets(assetId);
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
  const insertMessageAssetStmt = db.prepare(
    `INSERT INTO message_assets (deviceId, clientId, assetId) VALUES (?, ?, ?)`
  );
  const insertAssetStmt = db.prepare(
    `INSERT INTO assets (assetId, userId, mimeType, size, createdAt, uploaderDeviceId) VALUES (?, ?, ?, ?, ?, ?)`
  );
  const selectAssetStmt = db.prepare(
    `SELECT assetId, userId, mimeType, size, createdAt FROM assets WHERE assetId = ?`
  );
  const selectExpiredAssetsStmt = db.prepare(
    `SELECT assetId FROM assets
     WHERE createdAt <= ?
       AND NOT EXISTS (
         SELECT 1 FROM message_assets WHERE message_assets.assetId = assets.assetId
       )`
  );
  const deleteAssetStmt = db.prepare(
    `DELETE FROM assets
     WHERE assetId = ?
       AND NOT EXISTS (
         SELECT 1 FROM message_assets WHERE message_assets.assetId = assets.assetId
       )`
  );
  await cleanupOrphanedAssetFiles();
  const insertUserMessageTx = db.transaction(
    (
      session: Session,
      messageId: string,
      content: string,
      timestamp: number,
      attachments: NormalizedAttachment[],
      attachmentsHash: string,
      assetIds: string[]
    ) => {
      for (const assetId of assetIds) {
        const asset = selectAssetStmt.get(assetId) as { assetId: string; userId: string } | undefined;
        if (!asset || asset.userId !== session.userId) {
          throw new ClientMessageError("asset_not_found", "Asset not found");
        }
      }
      const serverMessageId = generateServerMessageId();
      const event: ServerMessage = {
        type: "message",
        id: serverMessageId,
        role: "user",
        content,
        timestamp,
        streaming: false,
        deviceId: session.deviceId,
        attachments: attachments.length > 0 ? attachments : undefined
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
        attachmentsHash,
        timestamp
      );
      for (const assetId of assetIds) {
        insertMessageAssetStmt.run(session.deviceId, messageId, assetId);
      }
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
    try {
      if (!req.url) {
        res.writeHead(404).end();
        return;
      }
      const parsedUrl = new URL(req.url, "http://localhost");
      if (req.method === "GET" && parsedUrl.pathname === "/version") {
        res.setHeader("Content-Type", "application/json");
        res.writeHead(200);
        res.end(JSON.stringify({ protocolVersion: PROTOCOL_VERSION }));
        return;
      }
      if (req.method === "POST" && parsedUrl.pathname === "/upload") {
        await handleUpload(req, res);
        return;
      }
      if (req.method === "GET" && parsedUrl.pathname.startsWith("/download/")) {
        const assetId = parsedUrl.pathname.slice("/download/".length);
        await handleDownload(req, res, assetId);
        return;
      }
      res.writeHead(404).end();
    } catch (err) {
      logger.error("http_request_failed", err);
      if (!res.headersSent) {
        sendHttpError(res, 500, "server_error", "Internal error");
      } else {
        res.end();
      }
    }
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
  const deniedDevices = new Map<string, number>();
  const sessionsByDevice = new Map<string, Session>();
  const userSessions = new Map<string, Set<Session>>();
  const perUserQueue = new Map<string, Promise<unknown>>();
  const pairRateLimiter = new SlidingWindowRateLimiter(config.pairing.maxRequestsPerMinute, 60_000);
  const authRateLimiter = new SlidingWindowRateLimiter(config.auth.maxAttemptsPerMinute, 60_000);
  const messageRateLimiter = new SlidingWindowRateLimiter(config.sessions.maxMessagesPerSecond, 1_000);
  let writeQueue: Promise<void> = Promise.resolve();
  const pendingCleanupInterval = setInterval(() => expirePendingPairs(), 1_000);
  if (typeof pendingCleanupInterval.unref === "function") {
    pendingCleanupInterval.unref();
  }
  const maintenanceIntervalMs = Math.min(60_000, Math.max(1_000, config.media.unreferencedUploadTtlSeconds * 250));
  const assetCleanupInterval =
    config.media.unreferencedUploadTtlSeconds > 0
      ? setInterval(() => {
          cleanupUnreferencedAssets().catch((err) => logger.warn("asset_cleanup_failed", err));
        }, maintenanceIntervalMs)
      : null;
  if (assetCleanupInterval && typeof assetCleanupInterval.unref === "function") {
    assetCleanupInterval.unref();
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

  function enqueueWriteTask<T>(task: () => T | Promise<T>): Promise<T> {
    const run = () => Promise.resolve().then(task);
    const result = writeQueue.then(run, run);
    writeQueue = result.then(
      () => undefined,
      () => undefined
    );
    return result;
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

  function sendHttpError(res: http.ServerResponse, status: number, code: string, message: string) {
    res.setHeader("Content-Type", "application/json");
    res.writeHead(status);
    res.end(JSON.stringify({ type: "error", code, message }));
  }

  function authenticateHttpRequest(req: http.IncomingMessage) {
    const header = req.headers.authorization;
    if (!header || !header.startsWith("Bearer ")) {
      throw new HttpError(401, "auth_failed", "Missing authorization");
    }
    const token = header.slice(7).trim();
    if (!token) {
      throw new HttpError(401, "auth_failed", "Missing token");
    }
    let decoded: jwt.JwtPayload;
    try {
      decoded = jwt.verify(token, jwtKey, { algorithms: ["HS256"] }) as jwt.JwtPayload;
    } catch {
      throw new HttpError(401, "auth_failed", "Invalid token");
    }
    const deviceId = decoded.deviceId;
    if (typeof deviceId !== "string" || !validateDeviceId(deviceId)) {
      throw new HttpError(401, "auth_failed", "Invalid token device");
    }
    if (isDenylisted(deviceId)) {
      throw new HttpError(403, "token_revoked", "Device revoked");
    }
    const entry = findAllowlistEntry(deviceId);
    if (!entry) {
      throw new HttpError(401, "auth_failed", "Unknown device");
    }
    if (typeof decoded.sub !== "string" || !timingSafeStringEqual(decoded.sub, entry.userId)) {
      throw new HttpError(401, "auth_failed", "Invalid token subject");
    }
    if (typeof decoded.exp === "number" && decoded.exp * 1000 < Date.now()) {
      throw new HttpError(401, "auth_failed", "Token expired");
    }
    return { deviceId, userId: entry.userId };
  }

  async function safeUnlink(filePath: string) {
    try {
      await fs.unlink(filePath);
    } catch (err: any) {
      if (!err || err.code === "ENOENT") {
        return;
      }
      logger.warn("file_unlink_failed", err);
    }
  }

  async function cleanupTmpDirectory() {
    try {
      const entries = await fs.readdir(tmpDir);
      await Promise.all(entries.map((entry) => safeUnlink(path.join(tmpDir, entry))));
    } catch (err) {
      logger.warn("tmp_cleanup_failed", err);
    }
  }

  async function cleanupOrphanedAssetFiles() {
    const startedAt = nowMs();
    try {
      const entries = await fs.readdir(assetsDir);
      const now = nowMs();
      const batchSize = 10_000;
      for (let i = 0; i < entries.length; i += batchSize) {
        const batch = entries.slice(i, i + batchSize);
        for (const entry of batch) {
          if (!ASSET_ID_REGEX.test(entry)) continue;
          const asset = selectAssetStmt.get(entry);
          if (asset) continue;
          const filePath = path.join(assetsDir, entry);
          if (config.media.unreferencedUploadTtlSeconds > 0) {
            try {
              const stats = await fs.stat(filePath);
              const ageMs = now - stats.mtimeMs;
              if (ageMs < config.media.unreferencedUploadTtlSeconds * 1000) {
                continue;
              }
            } catch {
              continue;
            }
          }
          await safeUnlink(filePath);
        }
      }
    } catch (err) {
      logger.warn("asset_orphan_scan_failed", err);
    } finally {
      const elapsedMs = nowMs() - startedAt;
      if (elapsedMs > 30_000) {
        logger.warn("asset_orphan_scan_slow", { elapsedMs });
      }
    }
  }

  async function cleanupUnreferencedAssets() {
    if (config.media.unreferencedUploadTtlSeconds <= 0) {
      return;
    }
    const cutoff = nowMs() - config.media.unreferencedUploadTtlSeconds * 1000;
    const deletedAssetIds = (await enqueueWriteTask(() => {
      const rows = selectExpiredAssetsStmt.all(cutoff) as { assetId: string }[];
      const deleted: string[] = [];
      for (const row of rows) {
        const result = deleteAssetStmt.run(row.assetId);
        if (result.changes > 0) {
          deleted.push(row.assetId);
        }
      }
      return deleted;
    })) as string[];
    for (const assetId of deletedAssetIds) {
      const assetPath = path.join(assetsDir, assetId);
      await safeUnlink(assetPath);
    }
  }

  async function handleUpload(req: http.IncomingMessage, res: http.ServerResponse) {
    let tmpPath: string | undefined;
    try {
      const auth = authenticateHttpRequest(req);
      const assetId = `a_${randomUUID()}`;
      tmpPath = path.join(tmpDir, `${assetId}.tmp`);
      let detectedMime = "application/octet-stream";
      let size = 0;
      await new Promise<void>((resolve, reject) => {
        const busboy = Busboy({
          headers: req.headers,
          limits: { files: 1, fileSize: config.media.maxUploadBytes }
        });
        let handled = false;
        busboy.on("file", (fieldname, file, info) => {
          if (handled || fieldname !== "file") {
            handled = true;
            file.resume();
            reject(new ClientMessageError("invalid_message", "Invalid upload field"));
            return;
          }
          handled = true;
          detectedMime = info.mimeType || "application/octet-stream";
          const writeStream = createWriteStream(tmpPath!);
          let aborted = false;
          file.on("data", (chunk) => {
            size += chunk.length;
            if (!aborted && size > config.media.maxUploadBytes) {
              aborted = true;
              file.unpipe(writeStream);
              writeStream.destroy();
              file.resume();
              reject(new ClientMessageError("payload_too_large", "Upload too large"));
            }
          });
          file.on("limit", () => reject(new ClientMessageError("payload_too_large", "Upload too large")));
          file.on("error", reject);
          writeStream.on("error", reject);
          file.pipe(writeStream);
          file.on("end", () => writeStream.end());
        });
        busboy.on("finish", () => {
          if (!handled) {
            reject(new ClientMessageError("invalid_message", "Missing file field"));
            return;
          }
          resolve();
        });
        busboy.on("error", reject);
        req.pipe(busboy);
      });
      if (size === 0) {
        throw new ClientMessageError("invalid_message", "Empty upload");
      }
      const finalPath = path.join(assetsDir, assetId);
      await fs.rename(tmpPath, finalPath);
      await enqueueWriteTask(() => insertAssetStmt.run(assetId, auth.userId, detectedMime, size, nowMs(), auth.deviceId));
      res.setHeader("Content-Type", "application/json");
      res.writeHead(200);
      res.end(JSON.stringify({ assetId, mimeType: detectedMime, size }));
    } catch (err) {
      if (tmpPath) {
        await safeUnlink(tmpPath);
      }
      if (err instanceof HttpError) {
        sendHttpError(res, err.status, err.code, err.message);
        return;
      }
      if (err instanceof ClientMessageError) {
        const status = err.code === "payload_too_large" ? 413 : 400;
        sendHttpError(res, status, err.code, err.message);
        return;
      }
      logger.error("upload_failed", err);
      sendHttpError(res, 503, "upload_failed_retryable", "Upload failed");
    }
  }

  async function handleDownload(req: http.IncomingMessage, res: http.ServerResponse, assetId: string) {
    try {
      const auth = authenticateHttpRequest(req);
      if (!ASSET_ID_REGEX.test(assetId)) {
        sendHttpError(res, 400, "invalid_message", "Invalid assetId");
        return;
      }
      const asset = selectAssetStmt.get(assetId) as
        | { assetId: string; userId: string; mimeType: string; size: number }
        | undefined;
      if (!asset) {
        sendHttpError(res, 404, "asset_not_found", "Asset not found");
        return;
      }
      if (asset.userId !== auth.userId) {
        sendHttpError(res, 404, "asset_not_found", "Asset not found");
        return;
      }
      const filePath = path.join(assetsDir, assetId);
      let fileHandle: fs.FileHandle;
      try {
        fileHandle = await fs.open(filePath, "r");
      } catch (err: any) {
        if (err && err.code === "ENOENT") {
          await enqueueWriteTask(() => deleteAssetStmt.run(assetId));
          sendHttpError(res, 404, "asset_not_found", "Asset not found");
          return;
        }
        throw err;
      }
      res.writeHead(200, {
        "Content-Type": asset.mimeType || "application/octet-stream",
        "Content-Length": asset.size
      });
      const stream = fileHandle.createReadStream();
      stream.on("error", (err) => {
        logger.error("download_stream_failed", err);
        if (!res.headersSent) {
          sendHttpError(res, 500, "server_error", "Download failed");
        } else {
          res.end();
        }
      });
      stream.on("close", () => {
        fileHandle
          .close()
          .catch(() => {});
      });
      stream.pipe(res);
    } catch (err) {
      if (err instanceof HttpError) {
        sendHttpError(res, err.status, err.code, err.message);
        return;
      }
      logger.error("download_failed", err);
      sendHttpError(res, 500, "server_error", "Download failed");
    }
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
    return enqueueWriteTask(() => insertEventTx(event, userId, originatingDeviceId));
  }

  async function persistUserMessage(
    session: Session,
    messageId: string,
    content: string,
    attachments: NormalizedAttachment[],
    attachmentsHash: string,
    assetIds: string[]
  ): Promise<{ event: ServerMessage; sequence: number }> {
    const timestamp = nowMs();
    try {
      return await enqueueWriteTask(() =>
        insertUserMessageTx(session, messageId, content, timestamp, attachments, attachmentsHash, assetIds)
      );
    } catch (err: any) {
      if (err && typeof err.message === "string" && err.message.includes("FOREIGN KEY")) {
        throw new ClientMessageError("asset_not_found", "Asset not found");
      }
      throw err;
    }
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
    try {
      if (payload.type !== "message") {
        throw new ClientMessageError("invalid_message", "Unsupported type");
      }
      if (typeof payload.id !== "string" || !payload.id.startsWith("c_")) {
        throw new ClientMessageError("invalid_message", "Invalid id");
      }
      if (typeof payload.content !== "string" || payload.content.length === 0) {
        throw new ClientMessageError("invalid_message", "Missing content");
      }
      const contentBytes = Buffer.byteLength(payload.content, "utf8");
      if (contentBytes > config.sessions.maxMessageBytes) {
        throw new ClientMessageError("payload_too_large", "Message too large");
      }
      const attachmentsInfo = normalizeAttachmentsInput(payload.attachments, config.media);
      if (contentBytes + attachmentsInfo.inlineBytes > MAX_TOTAL_PAYLOAD_BYTES) {
        throw new ClientMessageError("payload_too_large", "Message too large");
      }
      const attachmentsHash = hashAttachments(attachmentsInfo.attachments);

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
          if (existing.contentHash !== incomingHash || existing.attachmentsHash !== attachmentsHash) {
            throw new ClientMessageError("invalid_message", "Duplicate mismatch");
          }
          if (existing.streaming === MessageStreamingState.Failed) {
            throw new ClientMessageError("invalid_message", "Message failed");
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
          throw new ClientMessageError("rate_limited", "Too many messages");
        }

        const { event } = await persistUserMessage(
          session,
          payload.id,
          payload.content,
          attachmentsInfo.attachments,
          attachmentsHash,
          attachmentsInfo.assetIds
        );
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
    } catch (err) {
      if (err instanceof ClientMessageError) {
        await sendJson(session.socket, { type: "error", code: err.code, message: err.message });
        return;
      }
      throw err;
    }
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
    if (deniedDevices.has(payload.deviceId)) {
      deniedDevices.delete(payload.deviceId);
      await sendJson(ws, { type: "pair_result", success: false, reason: "pair_denied" });
      ws.close();
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
    if (entry && !entry.tokenDelivered) {
      const token = issueToken(entry);
      const delivered = await sendJson(ws, { type: "pair_result", success: true, token, userId: entry.userId })
        .then(() => true)
        .catch(() => false);
      if (delivered) {
        await setTokenDelivered(payload.deviceId, true);
      }
      ws.close();
      return;
    }
    if (entry && entry.tokenDelivered && entry.lastSeenAt === null) {
      const now = nowMs();
      const graceMs = config.auth.reissueGraceSeconds * 1000;
      if (now - entry.createdAt <= graceMs) {
        const token = issueToken(entry);
        const delivered = await sendJson(ws, { type: "pair_result", success: true, token, userId: entry.userId })
          .then(() => true)
          .catch(() => false);
        if (delivered) {
          await updateLastSeen(entry.deviceId, now);
        }
        ws.close();
        return;
      }
    }
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
      const delivered = await sendJson(ws, { type: "pair_result", success: true, token, userId })
        .then(() => true)
        .catch(() => false);
      if (delivered) {
        await setTokenDelivered(payload.deviceId, true);
      }
      ws.close();
      return;
    }

    if (entry && entry.tokenDelivered) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Device already paired" });
      ws.close();
      return;
    }

    const pending = pendingPairs.get(payload.deviceId);
    if (pending) {
      pending.socket = ws;
      await notifyAdminsOfPending();
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
      const delivered = await sendJson(pending.socket, { type: "pair_result", success: false, reason: "pair_denied" })
        .then(() => true)
        .catch(() => false);
      if (!delivered) {
        deniedDevices.set(payload.deviceId, nowMs());
      }
      pendingPairs.delete(payload.deviceId);
      return;
    }
    if (!validateUserId(payload.userId)) {
      await sendJson(ws, { type: "error", code: "invalid_message", message: "Invalid userId" });
      return;
    }
    const userId = payload.userId;
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
    const delivered = await sendJson(pending.socket, { type: "pair_result", success: true, token, userId })
      .then(() => true)
      .catch(() => false);
    if (delivered) {
      await setTokenDelivered(pending.deviceId, true);
    }
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
    if (pendingPairs.has(payload.deviceId)) {
      await sendJson(ws, { type: "auth_result", success: false, reason: "device_not_approved" });
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
      if (assetCleanupInterval) {
        clearInterval(assetCleanupInterval);
      }
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
