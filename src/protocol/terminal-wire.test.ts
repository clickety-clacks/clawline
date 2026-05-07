import { describe, expect, it } from "vitest";
import {
  decodeTerminalSessionDescriptor,
  isTerminalAttachment,
  terminalDestinationLabel,
  TERMINAL_ATTACHMENT_MIME
} from "./terminal-wire";

describe("terminal-wire", () => {
  it("decodes version 2 terminal descriptors and preserves destination truth", () => {
    const descriptor = decodeTerminalSessionDescriptor({
      type: "document",
      mimeType: TERMINAL_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 2,
          terminalSessionId: "term_123",
          title: "eezo",
          destination: {
            address: "mike@eezo"
          },
          capabilities: {
            interactive: true,
            supportsBinaryFrames: true,
            supportsResize: true,
            supportsDetach: true
          }
        })
      )
    });

    expect(descriptor).toMatchObject({
      version: 2,
      terminalSessionId: "term_123",
      title: "eezo",
      destination: {
        address: "mike@eezo"
      }
    });
    expect(descriptor && terminalDestinationLabel(descriptor)).toBe("mike@eezo");
  });

  it("treats version 1 descriptors as destination-unknown", () => {
    const descriptor = decodeTerminalSessionDescriptor({
      type: "document",
      mimeType: TERMINAL_ATTACHMENT_MIME,
      data: btoa(
        JSON.stringify({
          version: 1,
          terminalSessionId: "term_legacy",
          title: "Legacy"
        })
      )
    });

    expect(descriptor).not.toBeNull();
    expect(descriptor && terminalDestinationLabel(descriptor)).toBe("Destination unknown");
  });

  it("decodes UTF-8 descriptor JSON", () => {
    const descriptor = decodeTerminalSessionDescriptor({
      type: "document",
      mimeType: TERMINAL_ATTACHMENT_MIME,
      data: Buffer.from(
        JSON.stringify({
          version: 2,
          terminalSessionId: "term_utf8",
          title: "Résumé 🌊",
          destination: {
            address: "mike@東京"
          }
        }),
        "utf8"
      ).toString("base64")
    });

    expect(descriptor?.title).toBe("Résumé 🌊");
    expect(descriptor && terminalDestinationLabel(descriptor)).toBe("mike@東京");
  });

  it("accepts parameterized and case-varied terminal MIME types", () => {
    expect(
      isTerminalAttachment({
        type: "document",
        mimeType: "Application/Vnd.Clawline.Terminal-Session+Json; charset=utf-8"
      })
    ).toBe(true);
  });

  it("ignores invalid or non-terminal attachments", () => {
    expect(
      isTerminalAttachment({
        type: "document",
        mimeType: "application/json"
      })
    ).toBe(false);
    expect(
      decodeTerminalSessionDescriptor({
        type: "document",
        mimeType: TERMINAL_ATTACHMENT_MIME,
        data: btoa(JSON.stringify({ version: 2 }))
      })
    ).toBeNull();
  });
});
