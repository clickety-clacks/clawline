import { describe, expect, it } from "vitest";
import {
  decodeInteractiveHtmlDescriptor,
  interactiveHtmlTitle,
  INTERACTIVE_HTML_ATTACHMENT_MIME,
  isInteractiveHtmlAttachment
} from "./interactive-html-wire";

describe("interactive-html-wire", () => {
  it("decodes version 1 descriptors with fixed heights and metadata", () => {
    const descriptor = decodeInteractiveHtmlDescriptor({
      type: "document",
      mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 1,
          html: "<body><p>Hello</p></body>",
          metadata: {
            title: " Demo ",
            height: 320,
            maxHeight: 420,
            backgroundColor: "#123456"
          }
        })
      )
    });

    expect(descriptor).toEqual({
      version: 1,
      html: "<body><p>Hello</p></body>",
      metadata: {
        title: " Demo ",
        height: { kind: "fixed", value: 320 },
        maxHeight: 420,
        backgroundColor: "#123456"
      }
    });
    expect(descriptor && interactiveHtmlTitle(descriptor)).toBe("Demo");
  });

  it("decodes auto-height descriptors", () => {
    const descriptor = decodeInteractiveHtmlDescriptor({
      type: "document",
      mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 1,
          html: "<body><p>Hello</p></body>",
          metadata: {
            height: "auto"
          }
        })
      )
    });

    expect(descriptor?.metadata?.height).toEqual({ kind: "auto" });
  });

  it("decodes UTF-8 descriptor JSON", () => {
    const descriptor = decodeInteractiveHtmlDescriptor({
      type: "document",
      mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
      data: Buffer.from(
        JSON.stringify({
          version: 1,
          html: "<body><p>こんにちは 🌊</p></body>",
          metadata: {
            title: "Résumé 🌊"
          }
        }),
        "utf8"
      ).toString("base64")
    });

    expect(descriptor?.html).toBe("<body><p>こんにちは 🌊</p></body>");
    expect(descriptor && interactiveHtmlTitle(descriptor)).toBe("Résumé 🌊");
  });

  it("accepts parameterized and case-varied interactive HTML MIME types", () => {
    expect(
      isInteractiveHtmlAttachment({
        type: "document",
        mimeType: "Application/Vnd.Clawline.Interactive-Html+Json; charset=utf-8"
      })
    ).toBe(true);
  });

  it("rejects invalid or non-interactive payloads", () => {
    expect(
      isInteractiveHtmlAttachment({
        type: "document",
        mimeType: "application/json"
      })
    ).toBe(false);

    expect(
      decodeInteractiveHtmlDescriptor({
        type: "document",
        mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
        data: btoa(JSON.stringify({ version: 1 }))
      })
    ).toBeNull();

    expect(
      decodeInteractiveHtmlDescriptor({
        type: "document",
        mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
        data: "%%%not-base64%%%"
      })
    ).toBeNull();
  });
});
