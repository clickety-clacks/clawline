export function computeKeyboardInset(input: {
  baseViewportHeight: number;
  isComposerFocused: boolean;
  viewportHeight: number;
  viewportOffsetTop: number;
}) {
  if (!input.isComposerFocused) {
    return 0;
  }

  return Math.max(
    0,
    Math.round(input.baseViewportHeight - (input.viewportHeight + input.viewportOffsetTop))
  );
}

