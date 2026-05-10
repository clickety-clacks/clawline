import ackFixture from "../test/fixtures/protocol/ack.json";
import authFixture from "../test/fixtures/protocol/auth.json";
import authResultFixture from "../test/fixtures/protocol/auth_result.json";
import errorFixture from "../test/fixtures/protocol/error.json";
import messageFixture from "../test/fixtures/protocol/message.json";
import pairRequestFixture from "../test/fixtures/protocol/pair_request.json";
import pairResultFixture from "../test/fixtures/protocol/pair_result.json";
import sessionInfoFixture from "../test/fixtures/protocol/session_info.json";
import streamSnapshotFixture from "../test/fixtures/protocol/stream_snapshot.json";
import type { AuthPayload, PairRequestPayload } from "./chat-wire";
import {
  parseAuthResultPayload,
  parsePairResultPayload,
  parseServerPayload,
  serializeAuthPayload,
  serializeClientMessage,
  serializeClientStreamRead,
  serializePairRequest
} from "./chat-wire";

describe("chat-wire protocol fixtures", () => {
  it("serializes pair_request fixtures", () => {
    expect(
      JSON.parse(serializePairRequest(pairRequestFixture as PairRequestPayload))
    ).toEqual(
      pairRequestFixture
    );
  });

  it("parses pair_result fixtures", () => {
    expect(parsePairResultPayload(JSON.stringify(pairResultFixture))).toEqual(
      pairResultFixture
    );
  });

  it("serializes auth fixtures", () => {
    expect(JSON.parse(serializeAuthPayload(authFixture as AuthPayload))).toEqual(
      authFixture
    );
  });

  it("serializes auth payloads with native client parity fields", () => {
    expect(
      JSON.parse(
        serializeAuthPayload({
          ...(authFixture as AuthPayload),
          clientFeatures: ["terminal_bubbles_v1"],
          client: {
            id: "clawline-web",
            features: ["terminal_bubbles_v1"]
          }
        })
      )
    ).toEqual({
      ...authFixture,
      clientFeatures: ["terminal_bubbles_v1"],
      client: {
        id: "clawline-web",
        features: ["terminal_bubbles_v1"]
      }
    });
  });

  it("parses auth_result fixtures", () => {
    expect(parseAuthResultPayload(JSON.stringify(authResultFixture))).toEqual(
      authResultFixture
    );
  });

  it("parses auth_result read and tail snapshots", () => {
    expect(
      parseAuthResultPayload(
        JSON.stringify({
          type: "auth_result",
          success: true,
          streamReadStates: {
            "agent:main:clawline:user_1:main": "s_101"
          },
          streamTailStates: {
            "agent:main:clawline:user_1:main": {
              lastMessageId: "s_102",
              lastMessageRole: "assistant"
            }
          }
        })
      )
    ).toEqual({
      type: "auth_result",
      success: true,
      streamReadStates: {
        "agent:main:clawline:user_1:main": "s_101"
      },
      streamTailStates: {
        "agent:main:clawline:user_1:main": {
          lastMessageId: "s_102",
          lastMessageRole: "assistant"
        }
      }
    });
  });

  it("serializes client message payloads", () => {
    const payload = {
      type: "message" as const,
      id: "c_101",
      content: "hello",
      attachments: [
        {
          type: "image" as const,
          mimeType: "image/png",
          data: "aW1hZ2U="
        },
        {
          type: "asset" as const,
          assetId: "a_upload_1"
        }
      ],
      sessionKey: "agent:main:clawline:user_1:main"
    };

    expect(JSON.parse(serializeClientMessage(payload))).toEqual(payload);
  });

  it("serializes client stream_read payloads", () => {
    const payload = {
      type: "stream_read" as const,
      sessionKey: "agent:main:clawline:user_1:main",
      lastReadMessageId: "s_101"
    };

    expect(JSON.parse(serializeClientStreamRead(payload))).toEqual(payload);
  });

  it("parses message fixtures", () => {
    expect(parseServerPayload(JSON.stringify(messageFixture))).toEqual(messageFixture);
  });

  it("parses assistant typing payloads", () => {
    expect(
      parseServerPayload(
        JSON.stringify({
          type: "typing",
          active: true,
          role: "assistant",
          sessionKey: "agent:main:clawline:user_1:main"
        })
      )
    ).toEqual({
      type: "typing",
      active: true,
      role: "assistant",
      sessionKey: "agent:main:clawline:user_1:main"
    });
  });

  it("treats missing server message attachments as an empty array", () => {
    expect(
      parseServerPayload(
        JSON.stringify({
          type: "message",
          id: "s_live_1",
          role: "assistant",
          content: "hello from provider",
          timestamp: 1774910000000,
          streaming: false,
          sessionKey: "agent:main:clawline:flynn:main"
        })
      )
    ).toEqual({
      type: "message",
      id: "s_live_1",
      role: "assistant",
      content: "hello from provider",
      timestamp: 1774910000000,
      streaming: false,
      sessionKey: "agent:main:clawline:flynn:main",
      attachments: []
    });
  });

  it("accepts server messages with empty content", () => {
    expect(
      parseServerPayload(
        JSON.stringify({
          type: "message",
          id: "s_live_empty",
          role: "assistant",
          content: "",
          timestamp: 1774910000001,
          streaming: true,
          sessionKey: "agent:main:clawline:flynn:main"
        })
      )
    ).toEqual({
      type: "message",
      id: "s_live_empty",
      role: "assistant",
      content: "",
      timestamp: 1774910000001,
      streaming: true,
      sessionKey: "agent:main:clawline:flynn:main",
      attachments: []
    });
  });

  it("parses typed server attachment payloads", () => {
    expect(
      parseServerPayload(
        JSON.stringify({
          type: "message",
          id: "s_live_attachment",
          role: "assistant",
          content: "attachment message",
          timestamp: 1774910000002,
          streaming: false,
          sessionKey: "agent:main:clawline:flynn:main",
          attachments: [
            {
              type: "image",
              mimeType: "image/png",
              data: "aW1hZ2U="
            },
            {
              type: "document",
              assetId: "asset_1",
              metadata: {
                filename: "clip.mp4",
                mimeType: "video/mp4",
                size: 1200
              }
            }
          ]
        })
      )
    ).toEqual({
      type: "message",
      id: "s_live_attachment",
      role: "assistant",
      content: "attachment message",
      timestamp: 1774910000002,
      streaming: false,
      sessionKey: "agent:main:clawline:flynn:main",
      attachments: [
        {
          type: "image",
          mimeType: "image/png",
          data: "aW1hZ2U="
        },
        {
          type: "document",
          assetId: "asset_1",
          metadata: {
            filename: "clip.mp4",
            mimeType: "video/mp4",
            size: 1200
          }
        }
      ]
    });
  });

  it("parses ack fixtures", () => {
    expect(parseServerPayload(JSON.stringify(ackFixture))).toEqual(ackFixture);
  });

  it("parses stream_snapshot fixtures", () => {
    expect(parseServerPayload(JSON.stringify(streamSnapshotFixture))).toEqual(
      streamSnapshotFixture
    );
  });

  it("parses incremental stream mutation payloads", () => {
    expect(
      parseServerPayload(
        JSON.stringify({
          type: "stream_created",
          stream: streamSnapshotFixture.streams[0]
        })
      )
    ).toEqual({
      type: "stream_created",
      stream: streamSnapshotFixture.streams[0]
    });
    expect(
      parseServerPayload(
        JSON.stringify({
          type: "stream_deleted",
          sessionKey: streamSnapshotFixture.streams[0].sessionKey
        })
      )
    ).toEqual({
      type: "stream_deleted",
      sessionKey: streamSnapshotFixture.streams[0].sessionKey
    });
  });

  it("parses session_info fixtures", () => {
    expect(parseServerPayload(JSON.stringify(sessionInfoFixture))).toEqual(
      sessionInfoFixture
    );
  });

  it("parses stream read-state, tail-state, and event payloads", () => {
    expect(
      parseServerPayload(
        JSON.stringify({
          type: "stream_read_state",
          sessionKey: "agent:main:clawline:flynn:main",
          lastReadMessageId: "s_101"
        })
      )
    ).toEqual({
      type: "stream_read_state",
      sessionKey: "agent:main:clawline:flynn:main",
      lastReadMessageId: "s_101"
    });

    expect(
      parseServerPayload(
        JSON.stringify({
          type: "stream_tail_state",
          sessionKey: "agent:main:clawline:flynn:main",
          lastMessageId: "s_102",
          lastMessageRole: "assistant"
        })
      )
    ).toEqual({
      type: "stream_tail_state",
      sessionKey: "agent:main:clawline:flynn:main",
      lastMessageId: "s_102",
      lastMessageRole: "assistant"
    });

    expect(
      parseServerPayload(
        JSON.stringify({
          type: "event",
          event: "activity",
          payload: {
            sessionKey: "agent:main:clawline:flynn:main"
          }
        })
      )
    ).toEqual({
      type: "event",
      event: "activity",
      payload: {
        sessionKey: "agent:main:clawline:flynn:main"
      }
    });

    expect(parseServerPayload(JSON.stringify({ type: "sync_complete" }))).toEqual({
      type: "sync_complete"
    });
  });

  it("parses error fixtures", () => {
    expect(parseServerPayload(JSON.stringify(errorFixture))).toEqual(errorFixture);
  });
});
