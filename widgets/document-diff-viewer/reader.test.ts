import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { DocumentAccessError, DocumentReader, formatSseEvent } from "./reader";

describe("document diff viewer reader", () => {
  it("authorizes explicit source files and emits document-id change events from the reader", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "doc-reader-"));
    const file = path.join(dir, "note.md");
    await writeFile(file, "# One\n\nBody", "utf8");
    const reader = new DocumentReader();
    try {
      const snapshot = await reader.registerSource({ path: file, allowedFiles: [file], watchMode: "watch" });
      const eventPromise = new Promise(resolve => reader.once(`document.changed:${snapshot.id}`, resolve));

      await writeFile(file, "# One\n\nChanged body", "utf8");
      const event = await eventPromise as { documentId: string; revision: number; watcherMode: string };

      expect(event.documentId).toBe(snapshot.id);
      expect(event.revision).toBe(2);
      expect(event.watcherMode).toBe("watch");
      expect(reader.snapshot(snapshot.id).text).toContain("Changed body");
    } finally {
      reader.closeAll();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("keeps bounded polling inside the service when native events are not selected", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "doc-reader-poll-"));
    const file = path.join(dir, "note.md");
    await writeFile(file, "before", "utf8");
    const reader = new DocumentReader();
    try {
      const snapshot = await reader.registerSource({ path: file, allowedRoots: [dir], watchMode: "poll", pollIntervalMs: 250 });
      expect(snapshot.watcherMode).toBe("poll");
      await writeFile(file, "after", "utf8");
      await new Promise(resolve => reader.once(`document.changed:${snapshot.id}`, resolve));
      expect(reader.snapshot(snapshot.id).text).toBe("after");
    } finally {
      reader.closeAll();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("rejects unauthorized paths without returning source content", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "doc-reader-deny-"));
    const allowed = path.join(dir, "allowed");
    const denied = path.join(dir, "secret.md");
    await writeFile(denied, "secret", "utf8");
    const reader = new DocumentReader();
    try {
      await expect(reader.registerSource({ path: denied, allowedRoots: [allowed] })).rejects.toBeInstanceOf(DocumentAccessError);
    } finally {
      reader.closeAll();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("formats the supported event-stream payload", () => {
    const body = formatSseEvent({
      type: "document.changed",
      documentId: "doc_1",
      revision: 3,
      hash: "abc",
      updatedAt: "2026-06-09T00:00:00.000Z",
      watcherMode: "watch",
    });
    expect(body).toContain("event: document.changed");
    expect(body).toContain('"documentId":"doc_1"');
  });

  it("keeps the browser widget off primary client-side polling", async () => {
    const html = await readFile(path.join(process.cwd(), "widgets/document-diff-viewer/document-diff-viewer.html"), "utf8");
    expect(html).toContain("new EventSource(eventsUrl)");
    expect(html).toContain('addEventListener("document.changed"');
    expect(html).not.toContain("setInterval");
    expect(html).not.toContain("/documents/\" + encodeURIComponent(documentId) + \"/snapshot\", 15000");
  });
});

