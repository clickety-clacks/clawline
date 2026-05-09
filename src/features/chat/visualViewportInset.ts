export function computeKeyboardInset(input: {
  isComposerFocused: boolean;
  layoutViewportHeight: number;
  viewportHeight: number;
  viewportOffsetTop: number;
}) {
  if (!input.isComposerFocused) {
    return 0;
  }

  return Math.max(
    0,
    Math.round(
      input.layoutViewportHeight - (input.viewportHeight + input.viewportOffsetTop)
    )
  );
}
