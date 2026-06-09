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

  it("keeps the stream picker on the wrapping flow layout", () => {
    const styleText = readFileSync("src/app/styles.css", "utf8");

    expect(styleText).toContain("width: min(48rem, calc(100vw - 1.5rem));");
    expect(styleText).toContain(
      "grid-template-columns: repeat(auto-fill, minmax(min(9.5rem, 100%), 1fr));"
    );
    expect(styleText).toContain("gap: 10px;");
    expect(styleText).toContain("min-height: 76px;");
    expect(styleText).toContain("border-radius: 8px;");
  });
});
