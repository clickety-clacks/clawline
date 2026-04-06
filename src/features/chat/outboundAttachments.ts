import type {
  ClientAttachmentPayload,
  ServerAttachmentPayload
} from "../../protocol/chat-wire";
import { uploadAttachmentFile } from "../../protocol/upload-api";

const INLINE_IMAGE_MIME_TYPES = new Set([
  "image/gif",
  "image/heic",
  "image/jpeg",
  "image/png",
  "image/webp"
]);
const MAX_INLINE_BYTES = 262_144;
const MAX_MESSAGE_BYTES = 65_536;
const MAX_UPLOAD_BYTES = 104_857_600;

export interface PreparedOutboundAttachments {
  optimisticAttachments: ServerAttachmentPayload[];
  wireAttachments: ClientAttachmentPayload[];
}

export async function prepareOutboundAttachments(input: {
  content: string;
  fetchFn?: typeof fetch;
  files: readonly File[];
  serverUrl: string;
  token: string;
}): Promise<PreparedOutboundAttachments> {
  const optimisticAttachments: ServerAttachmentPayload[] = [];
  const wireAttachments: ClientAttachmentPayload[] = [];
  const contentBytes = new TextEncoder().encode(input.content).length;
  let inlineBytes = 0;

  for (const file of input.files) {
    if (file.size > MAX_UPLOAD_BYTES) {
      throw new Error(`${file.name || "Attachment"} exceeds the upload size limit.`);
    }

    const mimeType = normalizeAttachmentMimeType(file.type);
    if (
      INLINE_IMAGE_MIME_TYPES.has(mimeType) &&
      file.size <= MAX_INLINE_BYTES &&
      inlineBytes + file.size <= MAX_INLINE_BYTES &&
      contentBytes + inlineBytes + file.size <= MAX_MESSAGE_BYTES + MAX_INLINE_BYTES
    ) {
      const data = await fileToBase64(file);
      inlineBytes += file.size;
      wireAttachments.push({
        type: "image",
        mimeType,
        data
      });
      optimisticAttachments.push({
        type: "image",
        mimeType,
        data,
        metadata: {
          filename: file.name || undefined,
          mimeType,
          size: file.size
        }
      });
      continue;
    }

    const uploaded = await uploadAttachmentFile({
      fetchFn: input.fetchFn,
      file,
      serverUrl: input.serverUrl,
      token: input.token
    });
    wireAttachments.push({
      type: "asset",
      assetId: uploaded.assetId
    });
    optimisticAttachments.push({
      type: "asset",
      assetId: uploaded.assetId,
      metadata: {
        filename: file.name || undefined,
        mimeType: uploaded.mimeType,
        size: uploaded.size
      }
    });
  }

  return {
    optimisticAttachments,
    wireAttachments
  };
}

function normalizeAttachmentMimeType(mimeType: string) {
  const normalized = mimeType.trim().toLowerCase();
  return normalized.length > 0 ? normalized : "application/octet-stream";
}

async function fileToBase64(file: File) {
  const bytes = new Uint8Array(await readFileBytes(file));
  let binary = "";

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary);
}

async function readFileBytes(file: File) {
  if (typeof file.arrayBuffer === "function") {
    return await file.arrayBuffer();
  }

  return await new Promise<ArrayBuffer>((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error ?? new Error("File read failed"));
    reader.onload = () => resolve(reader.result as ArrayBuffer);
    reader.readAsArrayBuffer(file);
  });
}
