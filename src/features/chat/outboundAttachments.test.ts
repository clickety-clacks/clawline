import { describe, expect, it, vi } from "vitest";
import { prepareOutboundAttachments } from "./outboundAttachments";

describe("prepareOutboundAttachments", () => {
  it("keeps small supported images inline and uploads larger files", async () => {
    const fetchFn = vi.fn(async () =>
      new Response(
        JSON.stringify({
          assetId: "a_upload_1",
          mimeType: "application/pdf",
          size: 11
        }),
        {
          headers: { "Content-Type": "application/json" },
          status: 200
        }
      )
    );

    const result = await prepareOutboundAttachments({
      content: "Attachment send",
      fetchFn,
      files: [
        new File([new Uint8Array([137, 80, 78, 71])], "clip.png", {
          type: "image/png"
        }),
        new File(["hello world"], "report.pdf", {
          type: "application/pdf"
        })
      ],
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });

    expect(result.wireAttachments).toEqual([
      {
        type: "image",
        mimeType: "image/png",
        data: "iVBORw=="
      },
      {
        type: "asset",
        assetId: "a_upload_1"
      }
    ]);
    expect(result.optimisticAttachments).toEqual([
      {
        type: "image",
        mimeType: "image/png",
        data: "iVBORw==",
        metadata: {
          filename: "clip.png",
          mimeType: "image/png",
          size: 4
        }
      },
      {
        type: "asset",
        assetId: "a_upload_1",
        metadata: {
          filename: "report.pdf",
          mimeType: "application/pdf",
          size: 11
        }
      }
    ]);
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("falls back to upload when an image exceeds the inline ceiling", async () => {
    const fetchFn = vi.fn(async () =>
      new Response(
        JSON.stringify({
          assetId: "a_large_1",
          mimeType: "image/png",
          size: 262145
        }),
        {
          headers: { "Content-Type": "application/json" },
          status: 200
        }
      )
    );

    const result = await prepareOutboundAttachments({
      content: "Attachment send",
      fetchFn,
      files: [
        new File([new Uint8Array(262_145)], "large.png", {
          type: "image/png"
        })
      ],
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });

    expect(result.wireAttachments).toEqual([
      {
        type: "asset",
        assetId: "a_large_1"
      }
    ]);
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });
});
