import type { ServerAttachmentPayload } from "./chat-wire";
import { providerHttpBaseUrlFromServerUrl } from "./stream-api";

export function providerDownloadUrl(serverUrl: string, assetId: string) {
  return new URL(
    `/download/${encodeURIComponent(assetId)}`,
    providerHttpBaseUrlFromServerUrl(serverUrl)
  );
}

export async function fetchAuthenticatedAttachmentBlob(input: {
  attachment: ServerAttachmentPayload;
  fetchFn?: typeof fetch;
  serverUrl: string;
  token: string;
}) {
  const fetchFn =
    input.fetchFn ??
    ((request: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(request, init));

  const inlineData = attachmentDataBytes(input.attachment);
  if (inlineData) {
    return new Blob([inlineData.bytes], {
      type: inlineData.mimeType
    });
  }

  if (!input.attachment.assetId) {
    throw new Error("Attachment is missing assetId");
  }

  const response = await fetchFn(
    providerDownloadUrl(input.serverUrl, input.attachment.assetId),
    {
      headers: {
        Authorization: `Bearer ${input.token}`
      }
    }
  );

  if (!response.ok) {
    throw new Error(`Attachment download failed with status ${response.status}`);
  }

  return await response.blob();
}

function attachmentDataBytes(attachment: ServerAttachmentPayload) {
  const mimeType = attachmentMimeType(attachment);
  if (!attachment.data || !mimeType) {
    return null;
  }

  const binary = atob(attachment.data);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }

  return { bytes, mimeType };
}

export function attachmentMimeType(attachment: ServerAttachmentPayload) {
  return attachment.mimeType ?? attachment.metadata?.mimeType;
}

export function attachmentFilename(attachment: ServerAttachmentPayload) {
  return attachment.metadata?.filename ?? attachment.assetId ?? attachment.id ?? "attachment";
}
