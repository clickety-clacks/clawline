import { describe, expect, it } from "vitest";
import { computeKeyboardInset } from "./visualViewportInset";

describe("computeKeyboardInset", () => {
  it("returns zero when the composer is not focused", () => {
    expect(
      computeKeyboardInset({
        isComposerFocused: false,
        layoutViewportHeight: 844,
        viewportHeight: 564,
        viewportOffsetTop: 0
      })
    ).toBe(0);
  });

  it("returns the visual viewport delta when the composer is focused", () => {
    expect(
      computeKeyboardInset({
        isComposerFocused: true,
        layoutViewportHeight: 844,
        viewportHeight: 564,
        viewportOffsetTop: 0
      })
    ).toBe(280);
  });

  it("accounts for offset visual viewports", () => {
    expect(
      computeKeyboardInset({
        isComposerFocused: true,
        layoutViewportHeight: 844,
        viewportHeight: 600,
        viewportOffsetTop: 44
      })
    ).toBe(200);
  });

  it("returns zero when the layout viewport has already shrunk with the keyboard", () => {
    expect(
      computeKeyboardInset({
        isComposerFocused: true,
        layoutViewportHeight: 564,
        viewportHeight: 564,
        viewportOffsetTop: 0
      })
    ).toBe(0);
  });
});
