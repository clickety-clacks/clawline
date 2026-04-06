import { describe, expect, it } from "vitest";
import { computeKeyboardInset } from "./visualViewportInset";

describe("computeKeyboardInset", () => {
  it("returns zero when the composer is not focused", () => {
    expect(
      computeKeyboardInset({
        baseViewportHeight: 844,
        isComposerFocused: false,
        viewportHeight: 564,
        viewportOffsetTop: 0
      })
    ).toBe(0);
  });

  it("returns the visual viewport delta when the composer is focused", () => {
    expect(
      computeKeyboardInset({
        baseViewportHeight: 844,
        isComposerFocused: true,
        viewportHeight: 564,
        viewportOffsetTop: 0
      })
    ).toBe(280);
  });

  it("accounts for offset visual viewports", () => {
    expect(
      computeKeyboardInset({
        baseViewportHeight: 844,
        isComposerFocused: true,
        viewportHeight: 600,
        viewportOffsetTop: 44
      })
    ).toBe(200);
  });
});
