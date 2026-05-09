import type { ServerAttachmentPayload } from "./chat-wire";
import { normalizedAttachmentMimeType } from "./attachment-api";

export const TERMINAL_ATTACHMENT_MIME = "application/vnd.clawline.terminal-session+json";

export interface TerminalDestinationDescriptor {
  address: string;
}

export interface TerminalSessionDescriptor {
  version: number;
  terminalSessionId: string;
  title?: string;
  destination?: TerminalDestinationDescriptor;
  provider?: {
    baseUrl?: string;
    wsPath?: string;
  };
  capabilities?: {
    interactive: boolean;
    supportsBinaryFrames: boolean;
    supportsResize: boolean;
    supportsDetach: boolean;
  };
  auth?: {
    mode?: "chat_token" | "terminal_access_token";
    terminalAccessToken?: string;
  };
  expiresAtMs?: number;
}

export function isTerminalAttachment(attachment: ServerAttachmentPayload) {
  return normalizedAttachmentMimeType(attachment) === TERMINAL_ATTACHMENT_MIME;
}

export function decodeTerminalSessionDescriptor(
  attachment: ServerAttachmentPayload
): TerminalSessionDescriptor | null {
  if (!isTerminalAttachment(attachment) || !attachment.data) {
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
    const terminalSessionId =
      typeof value.terminalSessionId === "string" ? value.terminalSessionId.trim() : "";

    if (version == null || terminalSessionId.length === 0) {
      return null;
    }

    return {
      version,
      terminalSessionId,
      title: optionalString(value.title),
      destination: parseDestination(value.destination),
      provider: parseProvider(value.provider),
      capabilities: parseCapabilities(value.capabilities),
      auth: parseAuth(value.auth),
      expiresAtMs: typeof value.expiresAtMs === "number" ? value.expiresAtMs : undefined
    };
  } catch {
    return null;
  }
}

export function terminalDestinationLabel(descriptor: TerminalSessionDescriptor) {
  const address = descriptor.destination?.address?.trim();
  return address && address.length > 0 ? address : "Destination unknown";
}

function optionalString(value: unknown) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function parseDestination(value: unknown) {
  if (!value || typeof value !== "object") {
    return undefined;
  }

  const record = value as Record<string, unknown>;
  const address = typeof record.address === "string" ? record.address.trim() : "";

  return address.length > 0 ? { address } : undefined;
}

function parseProvider(value: unknown) {
  if (!value || typeof value !== "object") {
    return undefined;
  }

  const baseUrl = optionalString((value as Record<string, unknown>).baseUrl);
  const wsPath = optionalString((value as Record<string, unknown>).wsPath);
  if (!baseUrl && !wsPath) {
    return undefined;
  }

  return { baseUrl, wsPath };
}

function parseCapabilities(value: unknown) {
  if (!value || typeof value !== "object") {
    return undefined;
  }

  const capabilities = value as Record<string, unknown>;
  return {
    interactive: capabilities.interactive !== false,
    supportsBinaryFrames: capabilities.supportsBinaryFrames !== false,
    supportsResize: capabilities.supportsResize !== false,
    supportsDetach: capabilities.supportsDetach !== false
  };
}

function parseAuth(value: unknown) {
  if (!value || typeof value !== "object") {
    return undefined;
  }

  const mode = (value as Record<string, unknown>).mode;
  const normalizedMode =
    mode === "chat_token" || mode === "terminal_access_token"
      ? (mode as "chat_token" | "terminal_access_token")
      : undefined;
  const terminalAccessToken = optionalString(
    (value as Record<string, unknown>).terminalAccessToken
  );

  if (!normalizedMode && !terminalAccessToken) {
    return undefined;
  }

  return {
    mode: normalizedMode,
    terminalAccessToken
  };
}

function decodeBase64Utf8(value: string) {
  const decoded = atob(value);
  const bytes = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index);
  }
  return new TextDecoder().decode(bytes);
}
