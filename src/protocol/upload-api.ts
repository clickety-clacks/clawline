import { providerHttpBaseUrlFromServerUrl } from "./stream-api";

export interface UploadAssetResponse {
  assetId: string;
  mimeType: string;
  size: number;
}

export interface UploadApiError {
  code: string;
  message?: string;
  statusCode: number;
}

interface UploadApiErrorEnvelope {
  error: {
    code: string;
    message?: string;
  };
}

export async function uploadAttachmentFile(input: {
  fetchFn?: typeof fetch;
  file: File;
  serverUrl: string;
  token: string;
}) {
  const fetchFn =
    input.fetchFn ??
    ((request: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(request, init));

  const endpoint = new URL("/upload", providerHttpBaseUrlFromServerUrl(input.serverUrl));
  const form = new FormData();
  form.set("file", input.file, input.file.name || "upload.bin");

  const response = await fetchFn(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${input.token}`
    },
    body: form
  });

  if (!response.ok) {
    const errorPayload = (await safeJsonParse(response)) as
      | UploadApiErrorEnvelope
      | undefined;
    throw {
      code: errorPayload?.error?.code ?? `http_${response.status}`,
      message: errorPayload?.error?.message,
      statusCode: response.status
    } satisfies UploadApiError;
  }

  return (await response.json()) as UploadAssetResponse;
}

export function isUploadAuthFailure(error: unknown): error is UploadApiError {
  if (!error || typeof error !== "object") {
    return false;
  }

  const candidate = error as Partial<UploadApiError>;
  return (
    candidate.statusCode === 401 ||
    candidate.code === "auth_failed" ||
    candidate.code === "token_revoked"
  );
}

async function safeJsonParse(response: Response) {
  try {
    return (await response.json()) as unknown;
  } catch {
    return undefined;
  }
}
