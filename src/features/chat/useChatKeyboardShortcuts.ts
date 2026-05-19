import { useEffect } from "react";
import {
  keyboardIntentFromEvent,
  routeKeyboardCommand,
  useKeyboardOwnershipStore
} from "./keyboardCommandRouter";

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
  const keyboardOwnershipStore = useKeyboardOwnershipStore();

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.defaultPrevented || event.altKey) {
        return;
      }
      if (isShortcutSurfaceBlocked) {
        return;
      }

      const routed = keyboardIntentFromEvent(event);

      if (
        routed?.intent === "openStreamPopup" &&
        routeKeyboardCommand(routed.intent, keyboardOwnershipStore).ownerSurfaceId ===
          "transcript"
      ) {
        if (!canOpenSessionList) {
          return;
        }
        event.preventDefault();
        onOpenSessionList();
        return;
      }

      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
        return;
      }

      if (isEditableShortcutTarget(event.target) || isInteractiveShortcutTarget(event.target)) {
        return;
      }

      const key = normalizeShortcutKey(event.key);
      if (
        (key === "/" || key === ";") &&
        canOpenSessionList &&
        routeKeyboardCommand("openStreamPopup", keyboardOwnershipStore).ownerSurfaceId ===
          "transcript"
      ) {
        event.preventDefault();
        onOpenSessionList();
        return;
      }

      if (
        (key === " " || key === "enter") &&
        routeKeyboardCommand("focusPromptInput", keyboardOwnershipStore).ownerSurfaceId ===
          "transcript"
      ) {
        event.preventDefault();
        onFocusPromptInput();
      }
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [
    canOpenSessionList,
    isShortcutSurfaceBlocked,
    keyboardOwnershipStore,
    onFocusPromptInput,
    onOpenSessionList
  ]);
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
