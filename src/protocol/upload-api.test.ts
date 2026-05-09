import { describe, expect, it, vi } from "vitest";
import {
  isUploadAuthFailure,
  uploadAttachmentFile
} from "./upload-api";

describe("upload-api", () => {
  it("uploads multipart attachments through the provider surface", async () => {
    const fetchFn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const requestUrl = input instanceof URL ? input.toString() : String(input);
      expect(init?.method).toBe("POST");
      expect(requestUrl).toBe("http://127.0.0.1:18800/upload");
      expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer jwt-token");

      const form = init?.body;
      expect(form).toBeInstanceOf(FormData);
      const multipartBody = form as FormData;
      const file = multipartBody.get("file");
      expect(file).toBeInstanceOf(File);
      expect((file as File).name).toBe("report.pdf");

      return new Response(
        JSON.stringify({
          assetId: "a_upload_1",
          mimeType: "application/pdf",
          size: 7
        }),
        {
          headers: { "Content-Type": "application/json" },
          status: 200
        }
      );
    });

    await expect(
      uploadAttachmentFile({
        fetchFn,
        file: new File(["report"], "report.pdf", {
          type: "application/pdf"
        }),
        serverUrl: "ws://127.0.0.1:18800/ws",
        token: "jwt-token"
      })
    ).resolves.toEqual({
      assetId: "a_upload_1",
      mimeType: "application/pdf",
      size: 7
    });
  });

  it("surfaces provider auth failures for shared handling", async () => {
    const fetchFn = vi.fn(async () =>
      new Response(
        JSON.stringify({
          error: {
            code: "auth_failed",
            message: "Invalid token"
          }
        }),
        {
          headers: { "Content-Type": "application/json" },
          status: 401
        }
      )
    );

    await expect(
      uploadAttachmentFile({
        fetchFn,
        file: new File(["report"], "report.pdf", {
          type: "application/pdf"
        }),
        serverUrl: "ws://127.0.0.1:18800/ws",
        token: "jwt-token"
      })
    ).rejects.toMatchObject({
      code: "auth_failed",
      statusCode: 401
    });

    expect(
      isUploadAuthFailure({
        code: "auth_failed",
        statusCode: 401
      })
    ).toBe(true);
    expect(
      isUploadAuthFailure({
        code: "upload_failed_retryable",
        statusCode: 503
      })
    ).toBe(false);
  });
});
