import type { StreamSessionPayload } from "./chat-wire";

export interface ProviderVersionResponse {
  protocolVersion: number;
}

export interface StreamApiError {
  code: string;
  message?: string;
  statusCode: number;
}

export interface TrackableSessionPayload {
  sessionKey: string;
  displayName: string;
  updatedAt: number;
  channel?: string;
  lastChannel?: string;
  lastTo?: string;
}

export interface FetchStreamsResponse {
  streams: StreamSessionPayload[];
}

export interface FetchTrackableSessionsResponse {
  sessions: TrackableSessionPayload[];
}

export interface SessionStatusPayload {
  sessionKey: string;
  display?: {
    model?: string | null;
    fallbackModels?: string[] | null;
    provider?: string | null;
    harness?: string | null;
    reasoningLevel?: string | null;
    thinkingLevel?: string | null;
    fastMode?: boolean | null;
    mode?: string | null;
    verbosity?: string | null;
  };
  run?: {
    state?: string | null;
    runId?: string | null;
    messageId?: string | null;
    startedAt?: number | null;
    queueDepth?: number | null;
  };
  context?: unknown;
  approval?: unknown;
  capabilities?: SessionStatusCapabilities | null;
  modelCatalog?: ModelCatalogPayload | null;
}

export interface SessionStatusCapability {
  supported: boolean;
  reason?: string | null;
}

export interface SessionStatusCapabilities {
  cancelCurrentRun?: SessionStatusCapability | null;
  setModel?: SessionStatusCapability | null;
  setThinking?: SessionStatusCapability | null;
  setReasoning?: SessionStatusCapability | null;
  setFastMode?: SessionStatusCapability | null;
  setMode?: SessionStatusCapability | null;
  setVerbosity?: SessionStatusCapability | null;
  canCancelCurrentRun?: boolean | null;
  canChangeModel?: boolean | null;
  canChangeReasoning?: boolean | null;
  canChangeFastMode?: boolean | null;
  canChangeVerbosity?: boolean | null;
  readOnlyStatus?: boolean | null;
}

export interface ModelCatalogPayload {
  available?: boolean | null;
  reason?: string | null;
  models?: ModelCatalogEntryPayload[] | null;
}

export interface ModelCatalogEntryPayload {
  id?: string | null;
  provider?: string | null;
  ref: string;
  name?: string | null;
  alias?: string | null;
}

export type SessionControlAction =
  | "cancel_current_run"
  | "set_model"
  | "set_thinking"
  | "set_reasoning"
  | "set_fast_mode"
  | "set_mode"
  | "set_verbosity";

export interface ApplySessionControlRequest {
  sessionKey: string;
  action: SessionControlAction;
  fastMode?: boolean | null;
  mode?: string | null;
  model?: string | null;
  reasoningLevel?: string | null;
  thinkingLevel?: string | null;
  verbosity?: string | null;
}

export interface ApplySessionControlResponse {
  ok: boolean;
  sessionKey: string;
  action: SessionControlAction | string;
  code?: string | null;
  message?: string | null;
  status?: SessionStatusPayload | null;
  capabilities?: SessionStatusCapabilities | null;
}

export interface CreateStreamRequest {
  idempotencyKey: string;
  displayName: string;
}

export interface AdoptStreamRequest {
  sessionKey: string;
}

export interface RenameStreamRequest {
  displayName: string;
}

export interface DeleteStreamRequest {
  idempotencyKey?: string | null;
}

export interface MutateStreamResponse {
  stream: StreamSessionPayload;
}

export interface DeleteStreamResponse {
  deletedSessionKey: string;
}

interface StreamApiErrorEnvelope {
  error: {
    code: string;
    message?: string;
  };
}

interface StreamApiClientOptions {
  fetchFn?: typeof fetch;
}

const URL_PATH_COMPONENT_ALLOWED =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

export function createStreamApiClient(options?: StreamApiClientOptions) {
  const fetchFn =
    options?.fetchFn ?? ((input: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(input, init));

  return {
    fetchStreams(input: { serverUrl: string; token: string }) {
      return sendRequest<void, FetchStreamsResponse>({
        fetchFn,
        method: "GET",
        path: "/api/streams",
        serverUrl: input.serverUrl,
        token: input.token
      });
    },
    fetchTrackableSessions(input: { serverUrl: string; token: string }) {
      return sendRequest<void, FetchTrackableSessionsResponse>({
        fetchFn,
        method: "GET",
        path: "/api/trackable-sessions",
        serverUrl: input.serverUrl,
        token: input.token
      });
    },
    fetchSessionStatus(input: {
      serverUrl: string;
      sessionKey: string;
      signal?: AbortSignal;
      token: string;
    }) {
      return sendRequest<void, SessionStatusPayload>({
        fetchFn,
        method: "GET",
        path: "/api/session-status",
        query: {
          sessionKey: input.sessionKey
        },
        signal: input.signal,
        serverUrl: input.serverUrl,
        token: input.token
      });
    },
    applySessionControl(input: {
      action: SessionControlAction;
      enabled?: boolean | null;
      serverUrl: string;
      sessionKey: string;
      token: string;
      value?: string | null;
    }) {
      return sendRequest<ApplySessionControlRequest, ApplySessionControlResponse>({
        fetchFn,
        method: "POST",
        path: "/api/session-control",
        serverUrl: input.serverUrl,
        token: input.token,
        body: buildSessionControlRequestBody(input)
      });
    },
    createStream(input: {
      displayName: string;
      idempotencyKey: string;
      serverUrl: string;
      token: string;
    }) {
      return sendRequest<CreateStreamRequest, MutateStreamResponse>({
        fetchFn,
        method: "POST",
        path: "/api/streams",
        serverUrl: input.serverUrl,
        token: input.token,
        body: {
          idempotencyKey: input.idempotencyKey,
          displayName: input.displayName
        }
      });
    },
    adoptStream(input: { sessionKey: string; serverUrl: string; token: string }) {
      return sendRequest<AdoptStreamRequest, MutateStreamResponse>({
        fetchFn,
        method: "POST",
        path: "/api/streams/adopt",
        serverUrl: input.serverUrl,
        token: input.token,
        body: {
          sessionKey: input.sessionKey
        }
      });
    },
    renameStream(input: {
      displayName: string;
      serverUrl: string;
      sessionKey: string;
      token: string;
    }) {
      return sendRequest<RenameStreamRequest, MutateStreamResponse>({
        fetchFn,
        method: "PATCH",
        path: `/api/streams/${encodePathComponent(input.sessionKey)}`,
        serverUrl: input.serverUrl,
        token: input.token,
        body: {
          displayName: input.displayName
        }
      });
    },
    deleteStream(input: {
      idempotencyKey?: string | null;
      serverUrl: string;
      sessionKey: string;
      token: string;
    }) {
      return sendRequest<DeleteStreamRequest, DeleteStreamResponse>({
        fetchFn,
        method: "DELETE",
        path: `/api/streams/${encodePathComponent(input.sessionKey)}`,
        serverUrl: input.serverUrl,
        token: input.token,
        body: {
          idempotencyKey: input.idempotencyKey ?? null
        }
      });
    }
  };
}

function buildSessionControlRequestBody(input: {
  action: SessionControlAction;
  enabled?: boolean | null;
  sessionKey: string;
  value?: string | null;
}): ApplySessionControlRequest {
  const base = {
    sessionKey: input.sessionKey,
    action: input.action
  };

  switch (input.action) {
    case "set_model":
      return {
        ...base,
        model: input.value ?? null
      };
    case "set_thinking":
      return {
        ...base,
        thinkingLevel: input.value ?? null
      };
    case "set_reasoning":
      return {
        ...base,
        reasoningLevel: input.value ?? null
      };
    case "set_fast_mode":
      return {
        ...base,
        fastMode: input.enabled ?? null
      };
    case "set_mode":
      return {
        ...base,
        mode: input.value ?? null
      };
    case "set_verbosity":
      return {
        ...base,
        verbosity: input.value ?? null
      };
    case "cancel_current_run":
      return base;
  }
}

export function providerHttpBaseUrlFromServerUrl(serverUrl: string) {
  const baseUrl = new URL(serverUrl);
  if (baseUrl.protocol === "ws:") {
    baseUrl.protocol = "http:";
  } else if (baseUrl.protocol === "wss:") {
    baseUrl.protocol = "https:";
  }

  if (baseUrl.pathname.endsWith("/ws")) {
    baseUrl.pathname = baseUrl.pathname.slice(0, -3) || "/";
  }

  return baseUrl;
}

function encodePathComponent(value: string) {
  return [...value]
    .map((character) =>
      URL_PATH_COMPONENT_ALLOWED.includes(character)
        ? character
        : encodeURIComponent(character)
    )
    .join("");
}

async function sendRequest<Body, Response>(input: {
  body?: Body;
  fetchFn: typeof fetch;
  method: string;
  path: string;
  query?: Record<string, string>;
  signal?: AbortSignal;
  serverUrl: string;
  token: string;
}) {
  const endpoint = new URL(input.path, providerHttpBaseUrlFromServerUrl(input.serverUrl));
  for (const [name, value] of Object.entries(input.query ?? {})) {
    endpoint.searchParams.set(name, value);
  }

  const headers = new Headers({
    Accept: "application/json",
    Authorization: `Bearer ${input.token}`
  });

  let body: string | undefined;
  if (typeof input.body !== "undefined") {
    headers.set("Content-Type", "application/json");
    body = JSON.stringify(input.body);
  }

  const response = await input.fetchFn(endpoint, {
    method: input.method,
    headers,
    body,
    signal: input.signal
  });

  if (!response.ok) {
    const errorPayload = (await safeJsonParse(response)) as
      | StreamApiErrorEnvelope
      | undefined;
    throw {
      code:
        errorPayload?.error?.code ??
        `http_${response.status}`,
      message: errorPayload?.error?.message,
      statusCode: response.status
    } satisfies StreamApiError;
  }

  return (await response.json()) as Response;
}

async function safeJsonParse(response: Response) {
  try {
    return (await response.json()) as unknown;
  } catch {
    return undefined;
  }
}
