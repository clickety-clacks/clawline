import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parseStreamName, resolveStreamDisplayName } from "./SessionListSheet";

describe("SessionListSheet", () => {
  it("falls back to a readable name derived from the session key", () => {
    expect(
      resolveStreamDisplayName({
        displayName: "",
        sessionKey: "agent:main:clawline:flynn:research_notes"
      })
    ).toBe("Research Notes");
  });

  it("prefers the provider display name when one is present", () => {
    expect(
      resolveStreamDisplayName({
        displayName: "Personal",
        sessionKey: "agent:main:clawline:flynn:main"
      })
    ).toBe("Personal");
  });

  it("parses the trailing session segment into title case", () => {
    expect(parseStreamName("agent:main:clawline:flynn:side_thread")).toBe("Side Thread");
  });

  it("keeps the stream picker on a measured-width scrolling list", () => {
    const styleText = readFileSync("src/app/styles.css", "utf8");

    expect(styleText).toContain("--session-popover-content-width");
    expect(styleText).toContain(
      "max(18rem, calc(var(--session-popover-content-width, 0px) + 7.75rem))"
    );
    expect(styleText).toContain("width: 100%;");
    expect(styleText).toContain("overflow: auto;");
    expect(styleText).toContain("border-radius: 8px;");
  });
});
