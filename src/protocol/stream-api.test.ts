import {
  createStreamApiClient,
  providerHttpBaseUrlFromServerUrl
} from "./stream-api";

describe("stream-api", () => {
  function jsonResponse(body: unknown, status = 200) {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" }
    });
  }

  it("converts websocket provider URLs into HTTP control-plane base URLs", () => {
    expect(
      providerHttpBaseUrlFromServerUrl("ws://127.0.0.1:18800/ws").toString()
    ).toBe("http://127.0.0.1:18800/");
    expect(
      providerHttpBaseUrlFromServerUrl("wss://clawline.app/ws").toString()
    ).toBe("https://clawline.app/");
  });

  it("sends authorized stream create requests to the documented route", async () => {
    const requests: Request[] = [];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return new Response(
          JSON.stringify({
            stream: {
              sessionKey: "agent:main:clawline:user_1:s_created",
              displayName: "Research",
              kind: "custom",
              orderIndex: 3,
              isBuiltIn: false,
              createdAt: 10,
              updatedAt: 10,
              adopted: false
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        );
      }
    });

    const response = await client.createStream({
      displayName: "Research",
      idempotencyKey: "uuid-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });

    expect(response.stream.displayName).toBe("Research");
    expect(requests).toHaveLength(1);
    expect(requests[0].url).toBe("http://127.0.0.1:18800/api/streams");
    expect(requests[0].method).toBe("POST");
    expect(requests[0].headers.get("Authorization")).toBe("Bearer jwt-token");
    expect(await requests[0].json()).toEqual({
      idempotencyKey: "uuid-1",
      displayName: "Research"
    });
  });

  it("loads the documented stream and trackable-session routes", async () => {
    const requests: Request[] = [];
    const responses = [
      jsonResponse({
        streams: [
          {
            sessionKey: "agent:main:clawline:user_1:main",
            displayName: "Personal",
            kind: "main",
            orderIndex: 0,
            isBuiltIn: true,
            createdAt: 10,
            updatedAt: 10,
            adopted: false
          }
        ]
      }),
      jsonResponse({
        sessions: [
          {
            sessionKey: "agent:main:openclaw:user:s_trackable",
            displayName: "External Session",
            updatedAt: 12,
            channel: "slack",
            lastChannel: "alerts",
            lastTo: "ops"
          }
        ]
      })
    ];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return responses.shift() ?? jsonResponse({ error: { code: "unexpected" } }, 500);
      }
    });

    const streamResponse = await client.fetchStreams({
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });
    const trackableResponse = await client.fetchTrackableSessions({
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });

    expect(streamResponse.streams).toHaveLength(1);
    expect(trackableResponse.sessions).toEqual([
      {
        sessionKey: "agent:main:openclaw:user:s_trackable",
        displayName: "External Session",
        updatedAt: 12,
        channel: "slack",
        lastChannel: "alerts",
        lastTo: "ops"
      }
    ]);
    expect(requests[0].url).toBe("http://127.0.0.1:18800/api/streams");
    expect(requests[0].method).toBe("GET");
    expect(requests[1].url).toBe("http://127.0.0.1:18800/api/trackable-sessions");
    expect(requests[1].method).toBe("GET");
  });

  it("fetches session status through the provider control-plane route", async () => {
    const requests: Request[] = [];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return jsonResponse({
          sessionKey: "agent:main:clawline:user_1:side",
          display: {
            model: "gpt-5.5",
            provider: "openai",
            thinkingLevel: "medium",
            fastMode: true
          },
          run: {
            state: "running",
            queueDepth: 1
          },
          capabilities: {
            cancelCurrentRun: { supported: true }
          }
        });
      }
    });

    const status = await client.fetchSessionStatus({
      serverUrl: "ws://127.0.0.1:18800/ws",
      sessionKey: "agent:main:clawline:user_1:side",
      token: "jwt-token"
    });

    expect(status.run?.state).toBe("running");
    expect(status.display?.model).toBe("gpt-5.5");
    expect(requests).toHaveLength(1);
    expect(requests[0].url).toBe(
      "http://127.0.0.1:18800/api/session-status?sessionKey=agent%3Amain%3Aclawline%3Auser_1%3Aside"
    );
    expect(requests[0].method).toBe("GET");
    expect(requests[0].headers.get("Authorization")).toBe("Bearer jwt-token");
  });

  it("posts typed session-control actions through the provider control-plane route", async () => {
    const requests: Request[] = [];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return jsonResponse({
          ok: true,
          sessionKey: "agent:main:clawline:user_1:main",
          action: "cancel_current_run",
          status: {
            sessionKey: "agent:main:clawline:user_1:main",
            run: {
              state: "idle"
            }
          }
        });
      }
    });

    const response = await client.applySessionControl({
      action: "cancel_current_run",
      serverUrl: "ws://127.0.0.1:18800/ws",
      sessionKey: "agent:main:clawline:user_1:main",
      token: "jwt-token"
    });

    expect(response.ok).toBe(true);
    expect(requests).toHaveLength(1);
    expect(requests[0].url).toBe("http://127.0.0.1:18800/api/session-control");
    expect(requests[0].method).toBe("POST");
    expect(requests[0].headers.get("Authorization")).toBe("Bearer jwt-token");
    expect(await requests[0].json()).toEqual({
      sessionKey: "agent:main:clawline:user_1:main",
      action: "cancel_current_run"
    });
  });

  it("posts action-specific typed session-control payload fields", async () => {
    const requests: Request[] = [];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return jsonResponse({
          ok: true,
          sessionKey: "agent:main:clawline:user_1:main",
          action: "set_fast_mode"
        });
      }
    });

    await client.applySessionControl({
      action: "set_model",
      serverUrl: "ws://127.0.0.1:18800/ws",
      sessionKey: "agent:main:clawline:user_1:main",
      token: "jwt-token",
      value: "gpt-5.5"
    });
    await client.applySessionControl({
      action: "set_fast_mode",
      enabled: true,
      serverUrl: "ws://127.0.0.1:18800/ws",
      sessionKey: "agent:main:clawline:user_1:main",
      token: "jwt-token"
    });

    expect(await requests[0].json()).toEqual({
      sessionKey: "agent:main:clawline:user_1:main",
      action: "set_model",
      model: "gpt-5.5"
    });
    expect(await requests[1].json()).toEqual({
      sessionKey: "agent:main:clawline:user_1:main",
      action: "set_fast_mode",
      fastMode: true
    });
  });

  it("sends documented adopt and delete payloads", async () => {
    const requests: Request[] = [];
    const responses = [
      jsonResponse({
        stream: {
          sessionKey: "agent:main:openclaw:user:s_trackable",
          displayName: "External Session",
          kind: "custom",
          orderIndex: 2,
          isBuiltIn: false,
          createdAt: 10,
          updatedAt: 10,
          adopted: true
        }
      }),
      jsonResponse({
        deletedSessionKey: "agent:main:openclaw:user:s_trackable"
      })
    ];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return responses.shift() ?? jsonResponse({ error: { code: "unexpected" } }, 500);
      }
    });

    const adopted = await client.adoptStream({
      sessionKey: "agent:main:openclaw:user:s_trackable",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });
    const deleted = await client.deleteStream({
      sessionKey: "agent:main:openclaw:user:s_trackable",
      idempotencyKey: null,
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });

    expect(adopted.stream.adopted).toBe(true);
    expect(deleted.deletedSessionKey).toBe("agent:main:openclaw:user:s_trackable");
    expect(requests[0].url).toBe("http://127.0.0.1:18800/api/streams/adopt");
    expect(requests[0].method).toBe("POST");
    expect(await requests[0].json()).toEqual({
      sessionKey: "agent:main:openclaw:user:s_trackable"
    });
    expect(requests[1].method).toBe("DELETE");
    expect(await requests[1].json()).toEqual({
      idempotencyKey: null
    });
  });

  it("percent-encodes session keys for rename and delete routes", async () => {
    const requests: Request[] = [];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return jsonResponse({
          stream: {
            sessionKey: "agent:main:openclaw:user:s_trackable",
            displayName: "Renamed",
            kind: "custom",
            orderIndex: 2,
            isBuiltIn: false,
            createdAt: 10,
            updatedAt: 11,
            adopted: true
          }
        });
      }
    });

    await client.renameStream({
      displayName: "Renamed",
      serverUrl: "ws://127.0.0.1:18800/ws",
      sessionKey: "agent:main:openclaw:user:s_trackable",
      token: "jwt-token"
    });

    expect(requests[0].url).toBe(
      "http://127.0.0.1:18800/api/streams/agent%3Amain%3Aopenclaw%3Auser%3As_trackable"
    );

    await client.deleteStream({
      idempotencyKey: "uuid-2",
      serverUrl: "ws://127.0.0.1:18800/ws",
      sessionKey: "agent:main:openclaw:user:s_trackable",
      token: "jwt-token"
    });

    expect(requests[1].url).toBe(
      "http://127.0.0.1:18800/api/streams/agent%3Amain%3Aopenclaw%3Auser%3As_trackable"
    );
  });

  it("surfaces provider error envelopes with code and message", async () => {
    const client = createStreamApiClient({
      fetchFn: async () =>
        jsonResponse(
          {
            error: {
              code: "stream_not_found",
              message: "Missing stream"
            }
          },
          404
        )
    });

    await expect(
      client.deleteStream({
        idempotencyKey: "uuid-2",
        serverUrl: "ws://127.0.0.1:18800/ws",
        sessionKey: "agent:main:openclaw:user:s_missing",
        token: "jwt-token"
      })
    ).rejects.toMatchObject({
      code: "stream_not_found",
      message: "Missing stream",
      statusCode: 404
    });
  });
});
