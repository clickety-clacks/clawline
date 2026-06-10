import { EventEmitter } from "node:events";
import { createHash, randomUUID } from "node:crypto";
import { lstat, readFile, realpath, stat } from "node:fs/promises";
import { watch, type FSWatcher } from "node:fs";
import path from "node:path";

export type DocumentSourceDescriptor = {
  path: string;
  label?: string;
  allowedRoots?: string[];
  allowedFiles?: string[];
  contentType?: "markdown" | "html" | "text";
  watchMode?: "auto" | "watch" | "poll";
  pollIntervalMs?: number;
};

export type DocumentSnapshot = {
  id: string;
  label: string;
  revision: number;
  hash: string;
  byteSize: number;
  mtimeMs: number;
  contentType: "markdown" | "html" | "text";
  text: string;
  watcherMode: "watch" | "poll";
  updatedAt: string;
};

export type DocumentRevisionEvent = {
  type: "document.changed";
  documentId: string;
  revision: number;
  hash: string;
  updatedAt: string;
  watcherMode: "watch" | "poll";
};

type RegisteredDocument = {
  id: string;
  label: string;
  sourcePath: string;
  contentType: "markdown" | "html" | "text";
  watcherMode: "watch" | "poll";
  revision: number;
  hash: string;
  mtimeMs: number;
  byteSize: number;
  text: string;
  updatedAt: string;
  watcher?: FSWatcher;
  pollTimer?: NodeJS.Timeout;
  refreshInFlight: Promise<DocumentSnapshot | null> | null;
};

export class DocumentAccessError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DocumentAccessError";
  }
}

export class DocumentReader extends EventEmitter {
  private readonly documents = new Map<string, RegisteredDocument>();

  async registerSource(descriptor: DocumentSourceDescriptor): Promise<DocumentSnapshot> {
    const sourcePath = await resolveAuthorizedFile(descriptor);
    const sourceStat = await stat(sourcePath);
    if (!sourceStat.isFile()) throw new DocumentAccessError("document source is not a file");

    const id = randomUUID();
    const contentType = descriptor.contentType ?? contentTypeForPath(sourcePath);
    const initial = await readSnapshotFile(id, descriptor.label ?? path.basename(sourcePath), sourcePath, contentType, 1, "poll");
    const record: RegisteredDocument = {
      ...initial,
      sourcePath,
      refreshInFlight: null,
    };
    this.documents.set(id, record);

    this.startChangeDetection(record, descriptor);
    return toSnapshot(record);
  }

  snapshot(documentId: string): DocumentSnapshot {
    const record = this.documents.get(documentId);
    if (!record) throw new DocumentAccessError("document not registered");
    return toSnapshot(record);
  }

  close(documentId: string): void {
    const record = this.documents.get(documentId);
    if (!record) return;
    record.watcher?.close();
    if (record.pollTimer) clearInterval(record.pollTimer);
    this.documents.delete(documentId);
  }

  closeAll(): void {
    for (const id of this.documents.keys()) this.close(id);
  }

  private startChangeDetection(record: RegisteredDocument, descriptor: DocumentSourceDescriptor): void {
    if (descriptor.watchMode !== "poll") {
      try {
        record.watcher = watch(record.sourcePath, { persistent: false }, () => {
          void this.refreshFromSource(record.id);
        });
        record.watcherMode = "watch";
        return;
      } catch {
        if (descriptor.watchMode === "watch") throw new DocumentAccessError("native file watching unavailable");
      }
    }

    record.watcherMode = "poll";
    const interval = Math.max(250, descriptor.pollIntervalMs ?? 2000);
    record.pollTimer = setInterval(() => {
      void this.refreshFromSource(record.id);
    }, interval);
    record.pollTimer.unref?.();
  }

  private async refreshFromSource(documentId: string): Promise<DocumentSnapshot | null> {
    const record = this.documents.get(documentId);
    if (!record) return null;
    if (record.refreshInFlight) return record.refreshInFlight;

    record.refreshInFlight = (async () => {
      const next = await readSnapshotFile(
        record.id,
        record.label,
        record.sourcePath,
        record.contentType,
        record.revision + 1,
        record.watcherMode,
      );
      if (next.hash === record.hash && next.mtimeMs === record.mtimeMs && next.byteSize === record.byteSize) return null;

      Object.assign(record, next);
      const event: DocumentRevisionEvent = {
        type: "document.changed",
        documentId: record.id,
        revision: record.revision,
        hash: record.hash,
        updatedAt: record.updatedAt,
        watcherMode: record.watcherMode,
      };
      this.emit("document.changed", event);
      this.emit(`document.changed:${record.id}`, event);
      return toSnapshot(record);
    })();

    try {
      return await record.refreshInFlight;
    } finally {
      record.refreshInFlight = null;
    }
  }
}

export function formatSseEvent(event: DocumentRevisionEvent): string {
  return `event: document.changed\ndata: ${JSON.stringify(event)}\n\n`;
}

async function resolveAuthorizedFile(descriptor: DocumentSourceDescriptor): Promise<string> {
  const requested = await realpath(path.resolve(descriptor.path));
  const allowedFiles = await Promise.all((descriptor.allowedFiles ?? []).map(file => realpath(path.resolve(file))));
  if (allowedFiles.includes(requested)) return requested;

  const allowedRoots = await Promise.all(
    (descriptor.allowedRoots ?? []).map(async root => {
      try {
        return await realpath(path.resolve(root));
      } catch {
        return "";
      }
    }),
  );
  for (const root of allowedRoots) {
    if (!root) continue;
    const rootStat = await lstat(root);
    if (!rootStat.isDirectory()) continue;
    const relative = path.relative(root, requested);
    if (relative && !relative.startsWith("..") && !path.isAbsolute(relative)) return requested;
  }

  throw new DocumentAccessError("document source is not authorized");
}

async function readSnapshotFile(
  id: string,
  label: string,
  sourcePath: string,
  contentType: "markdown" | "html" | "text",
  revision: number,
  watcherMode: "watch" | "poll",
): Promise<DocumentSnapshot> {
  const [sourceStat, body] = await Promise.all([stat(sourcePath), readFile(sourcePath, "utf8")]);
  const hash = createHash("sha256").update(body).digest("hex");
  return {
    id,
    label,
    revision,
    hash,
    byteSize: sourceStat.size,
    mtimeMs: sourceStat.mtimeMs,
    contentType,
    text: body,
    watcherMode,
    updatedAt: new Date().toISOString(),
  };
}

function contentTypeForPath(sourcePath: string): "markdown" | "html" | "text" {
  const ext = path.extname(sourcePath).toLowerCase();
  if (ext === ".md" || ext === ".markdown") return "markdown";
  if (ext === ".html" || ext === ".htm") return "html";
  return "text";
}

function toSnapshot(record: RegisteredDocument): DocumentSnapshot {
  const { watcher, pollTimer, refreshInFlight, sourcePath, ...snapshot } = record;
  void watcher;
  void pollTimer;
  void refreshInFlight;
  void sourcePath;
  return { ...snapshot };
}
