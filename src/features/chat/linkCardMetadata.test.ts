import { afterEach, describe, expect, it } from "vitest";
import {
  fallbackLinkCardMetadata,
  parseLinkCardMetadata,
  resetLinkCardMetadataCache
} from "./linkCardMetadata";

afterEach(() => {
  resetLinkCardMetadataCache();
});

describe("linkCardMetadata", () => {
  it("parses opengraph metadata and resolves relative images", () => {
    const metadata = parseLinkCardMetadata(
      [
        "<html><head>",
        '<meta property="og:title" content="Market Update" />',
        '<meta property="og:description" content="Fresh herbs and flowers." />',
        '<meta property="og:image" content="/images/preview.jpg" />',
        "<title>Fallback title</title>",
        "</head><body></body></html>"
      ].join(""),
      "https://example.com/posts/spring"
    );

    expect(metadata).toEqual({
      description: "Fresh herbs and flowers.",
      domain: "EXAMPLE.COM",
      imageUrl: "https://example.com/images/preview.jpg",
      title: "Market Update",
      url: "https://example.com/posts/spring"
    });
  });

  it("falls back to URL-derived metadata when preview data is absent", () => {
    expect(fallbackLinkCardMetadata("https://example.com/docs?tab=web#intro")).toEqual({
      description: "https://example.com/docs?tab=web#intro",
      domain: "EXAMPLE.COM",
      imageUrl: null,
      title: "example.com/docs?tab=web#intro",
      url: "https://example.com/docs?tab=web#intro"
    });
  });
});
