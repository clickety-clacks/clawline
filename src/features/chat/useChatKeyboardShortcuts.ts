import { useEffect } from "react";

export function useChatKeyboardShortcuts({
  canOpenSessionList,
  isShortcutSurfaceBlocked,
  onFocusPromptInput,
  onOpenSessionList
}: {
  canOpenSessionList: boolean;
  isShortcutSurfaceBlocked: boolean;
  onFocusPromptInput: () => void;
  onOpenSessionList: () => void;
}) {
  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.defaultPrevented || event.altKey) {
        return;
      }
      if (isShortcutSurfaceBlocked) {
        return;
      }

      const key = normalizeShortcutKey(event.key);
      const hasCommandModifier = event.metaKey || event.ctrlKey;
      const hasOnlyCommandModifier =
        hasCommandModifier && !event.shiftKey && !event.altKey;

      if (hasOnlyCommandModifier && key === ";") {
        if (!canOpenSessionList) {
          return;
        }
        event.preventDefault();
        onOpenSessionList();
        return;
      }

      if (hasCommandModifier || event.shiftKey || event.altKey) {
        return;
      }

      if (isEditableShortcutTarget(event.target) || isInteractiveShortcutTarget(event.target)) {
        return;
      }

      if ((key === "/" || key === ";") && canOpenSessionList) {
        event.preventDefault();
        onOpenSessionList();
        return;
      }

      if (key === " " || key === "enter") {
        event.preventDefault();
        onFocusPromptInput();
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [canOpenSessionList, isShortcutSurfaceBlocked, onFocusPromptInput, onOpenSessionList]);
}

function normalizeShortcutKey(key: string) {
  return key.toLowerCase();
}

function isEditableShortcutTarget(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) {
    return false;
  }

  if (target.isContentEditable) {
    return true;
  }

  return Boolean(
    target.closest("input, textarea, select, [contenteditable='true'], [role='textbox']")
  );
}

function isInteractiveShortcutTarget(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) {
    return false;
  }

  return Boolean(target.closest("button, a, label, audio, video, iframe"));
}
