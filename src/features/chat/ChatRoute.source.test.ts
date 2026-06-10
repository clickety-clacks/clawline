import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("ChatRoute source contracts", () => {
  it("passes a stable scroll-state callback into MessageList", () => {
    const sourceText = readFileSync("src/features/chat/ChatRoute.tsx", "utf8");

    expect(sourceText).toContain("const rememberSessionScrollState = useCallback(");
    expect(sourceText).toContain("onRememberScrollState={rememberSessionScrollState}");
    expect(sourceText).not.toContain(
      "onRememberScrollState={(input) => chatStore.rememberSessionScrollState(input)}"
    );
  });
});
