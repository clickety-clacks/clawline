import type { ServerAttachmentPayload } from "./chat-wire";
import { normalizedAttachmentMimeType } from "./attachment-api";

export const INTERACTIVE_HTML_ATTACHMENT_MIME =
  "application/vnd.clawline.interactive-html+json";

export type InteractiveHtmlHeight = { kind: "auto" } | { kind: "fixed"; value: number };

export interface InteractiveHtmlDescriptor {
  version: number;
  html: string;
  metadata?: {
    backgroundColor?: string;
    height?: InteractiveHtmlHeight;
    maxHeight?: number;
    title?: string;
  };
}

export function isInteractiveHtmlAttachment(attachment: ServerAttachmentPayload) {
  return normalizedAttachmentMimeType(attachment) === INTERACTIVE_HTML_ATTACHMENT_MIME;
}

export function decodeInteractiveHtmlDescriptor(
  attachment: ServerAttachmentPayload
): InteractiveHtmlDescriptor | null {
  if (!isInteractiveHtmlAttachment(attachment) || !attachment.data) {
    return null;
  }

  try {
    const decoded = decodeBase64Utf8(attachment.data);
    const parsed = JSON.parse(decoded) as unknown;
    if (!parsed || typeof parsed !== "object") {
      return null;
    }

    const value = parsed as Record<string, unknown>;
    const version = typeof value.version === "number" ? value.version : null;
    const html = typeof value.html === "string" ? value.html : "";
    if (version == null || html.length === 0) {
      return null;
    }

    return {
      version,
      html,
      metadata: parseMetadata(value.metadata)
    };
  } catch {
    return null;
  }
}

export function interactiveHtmlTitle(descriptor: InteractiveHtmlDescriptor) {
  return descriptor.metadata?.title?.trim() || "Interactive content";
}

function parseMetadata(value: unknown) {
  if (!value || typeof value !== "object") {
    return undefined;
  }

  const record = value as Record<string, unknown>;
  const backgroundColor =
    typeof record.backgroundColor === "string" ? record.backgroundColor : undefined;
  const title = typeof record.title === "string" ? record.title : undefined;
  const maxHeight = typeof record.maxHeight === "number" ? record.maxHeight : undefined;
  const height = parseHeight(record.height);

  if (!backgroundColor && !title && maxHeight == null && !height) {
    return undefined;
  }

  return {
    backgroundColor,
    height,
    maxHeight,
    title
  };
}

function parseHeight(value: unknown): InteractiveHtmlHeight | undefined {
  if (value === "auto") {
    return { kind: "auto" };
  }

  if (typeof value === "number" && Number.isFinite(value)) {
    return { kind: "fixed", value };
  }

  return undefined;
}

function decodeBase64Utf8(value: string) {
  const decoded = atob(value);
  const bytes = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index);
  }
  return new TextDecoder().decode(bytes);
}
