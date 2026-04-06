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
});
