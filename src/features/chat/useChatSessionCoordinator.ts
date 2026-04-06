import { useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { computeKeyboardInset } from "./visualViewportInset";

export type ChatSessionSwitchSource =
  | "boot"
  | "popup"
  | "route"
  | "stream-manager"
  | "swipe";

export interface ChatSessionTransition {
  bootRequestedSessionKey: string | null;
  pendingSessionKey: string | null;
  source: ChatSessionSwitchSource | null;
}

export interface ChatSessionCoordinator {
  closeSessionList: () => void;
  closeStreamManager: () => void;
  engineActiveSessionKey?: string;
  firstProviderValidSessionKey?: string;
  isSessionListOpen: boolean;
  isStreamManagerOpen: boolean;
  openSessionList: () => void;
  openStreamManager: () => void;
  routeSessionExists: boolean;
  requestSessionSwitch: (sessionKey: string, source: ChatSessionSwitchSource) => void;
  transition: ChatSessionTransition;
  uiSelectedSessionKey?: string;
}

export interface ChatSessionInteractionCoordinator {
  handleChatPanelTouchCancel: () => void;
  handleChatPanelTouchEnd: (input: {
    touch: { clientX: number; clientY: number } | null;
  }) => void;
  handleChatPanelTouchStart: (input: {
    target: EventTarget | null;
    touch: { clientX: number; clientY: number } | null;
  }) => void;
  handlePopupSessionSelect: (sessionKey: string) => void;
  keyboardInset: number;
  layoutStyle: CSSProperties;
  shouldEnableSwipeNavigation: boolean;
}

export function useChatSessionCoordinator({
  routeSessionKey,
  streams,
  provisionedSessionKeys,
  transportPhase
}: {
  provisionedSessionKeys: string[];
  routeSessionKey?: string;
  streams: StreamRecord[];
  transportPhase: TransportPhase;
}): ChatSessionCoordinator {
  const [isSessionListOpen, setSessionListOpen] = useState(false);
  const [isStreamManagerOpen, setStreamManagerOpen] = useState(false);
  const [uiSelectedSessionKey, setUiSelectedSessionKey] = useState<string | undefined>(
    routeSessionKey
  );
  const [transition, setTransition] = useState<ChatSessionTransition>({
    bootRequestedSessionKey: routeSessionKey ?? null,
    pendingSessionKey: null,
    source: routeSessionKey ? "boot" : null
  });

  const firstProviderValidSessionKey = useMemo(
    () =>
      streams.find((stream) => provisionedSessionKeys.includes(stream.sessionKey))
        ?.sessionKey ?? streams[0]?.sessionKey,
    [provisionedSessionKeys, streams]
  );

  const routeSessionExists = useMemo(
    () =>
      routeSessionKey
        ? streams.some((stream) => stream.sessionKey === routeSessionKey)
        : false,
    [routeSessionKey, streams]
  );

  const engineActiveSessionKey = routeSessionKey ?? firstProviderValidSessionKey;

  useEffect(() => {
    setUiSelectedSessionKey(routeSessionKey ?? firstProviderValidSessionKey);
  }, [firstProviderValidSessionKey, routeSessionKey]);

  useEffect(() => {
    if (!transition.pendingSessionKey) {
      return;
    }

    if (routeSessionKey !== transition.pendingSessionKey) {
      return;
    }

    setTransition((current) => ({
      ...current,
      pendingSessionKey: null
    }));
  }, [routeSessionKey, transition.pendingSessionKey]);

  useEffect(() => {
    const bootRequestedSessionKey = transition.bootRequestedSessionKey;

    if (!bootRequestedSessionKey) {
      return;
    }

    if (routeSessionKey !== bootRequestedSessionKey) {
      setTransition((current) => ({
        ...current,
        bootRequestedSessionKey: null
      }));
      return;
    }

    if (
      transportPhase === "live" &&
      provisionedSessionKeys.includes(bootRequestedSessionKey)
    ) {
      setTransition((current) => ({
        ...current,
        bootRequestedSessionKey: null
      }));
    }
  }, [provisionedSessionKeys, routeSessionKey, transition.bootRequestedSessionKey, transportPhase]);

  return {
    closeSessionList() {
      setSessionListOpen(false);
    },
    closeStreamManager() {
      setStreamManagerOpen(false);
    },
    engineActiveSessionKey,
    firstProviderValidSessionKey,
    isSessionListOpen,
    isStreamManagerOpen,
    openSessionList() {
      setSessionListOpen(true);
    },
    openStreamManager() {
      setSessionListOpen(false);
      setStreamManagerOpen(true);
    },
    requestSessionSwitch(sessionKey, source) {
      setUiSelectedSessionKey(sessionKey);
      setSessionListOpen(false);
      setStreamManagerOpen(false);
      setTransition((current) => ({
        ...current,
        pendingSessionKey: sessionKey,
        source
      }));
    },
    routeSessionExists,
    transition,
    uiSelectedSessionKey
  };
}

export function useChatSessionInteractionCoordinator({
  activeSessionKey,
  onSelectSession,
  orderedSessionKeys
}: {
  activeSessionKey?: string;
  onSelectSession: (sessionKey: string, source: ChatSessionSwitchSource) => void;
  orderedSessionKeys: string[];
}): ChatSessionInteractionCoordinator {
  const [keyboardInset, setKeyboardInset] = useState(0);
  const touchStartRef = useRef<{
    active: boolean;
    x: number;
    y: number;
  }>({
    active: false,
    x: 0,
    y: 0
  });
  const baseViewportHeightRef = useRef(0);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    function syncKeyboardInset() {
      const visualViewport = window.visualViewport;
      const viewportHeight = visualViewport?.height ?? window.innerHeight;
      const viewportOffsetTop = visualViewport?.offsetTop ?? 0;
      const baseViewportHeight = visualViewport
        ? viewportHeight + viewportOffsetTop
        : window.innerHeight;

      baseViewportHeightRef.current = Math.max(
        baseViewportHeightRef.current,
        baseViewportHeight
      );

      const activeElement = document.activeElement;
      const isComposerFocused =
        activeElement instanceof HTMLTextAreaElement &&
        activeElement.id === "composer-input";

      setKeyboardInset(
        computeKeyboardInset({
          baseViewportHeight: baseViewportHeightRef.current || baseViewportHeight,
          isComposerFocused,
          viewportHeight,
          viewportOffsetTop
        })
      );
    }

    syncKeyboardInset();

    const visualViewport = window.visualViewport;
    visualViewport?.addEventListener("resize", syncKeyboardInset);
    visualViewport?.addEventListener("scroll", syncKeyboardInset);
    window.addEventListener("focusin", syncKeyboardInset);
    window.addEventListener("focusout", syncKeyboardInset);
    window.addEventListener("resize", syncKeyboardInset);

    return () => {
      visualViewport?.removeEventListener("resize", syncKeyboardInset);
      visualViewport?.removeEventListener("scroll", syncKeyboardInset);
      window.removeEventListener("focusin", syncKeyboardInset);
      window.removeEventListener("focusout", syncKeyboardInset);
      window.removeEventListener("resize", syncKeyboardInset);
    };
  }, []);

  const layoutStyle = useMemo(
    () =>
      ({
        "--chat-keyboard-inset": `${keyboardInset}px`
      }) as CSSProperties,
    [keyboardInset]
  );
  const shouldEnableSwipeNavigation = keyboardInset <= 0;

  function handleChatPanelTouchCancel() {
    touchStartRef.current.active = false;
  }

  function handleChatPanelTouchEnd(input: {
    touch: { clientX: number; clientY: number } | null;
  }) {
    if (!touchStartRef.current.active || orderedSessionKeys.length < 2) {
      return;
    }

    touchStartRef.current.active = false;
    const touch = input.touch;

    if (!touch) {
      return;
    }

    const deltaX = touch.clientX - touchStartRef.current.x;
    const deltaY = touch.clientY - touchStartRef.current.y;

    if (Math.abs(deltaX) < 56 || Math.abs(deltaX) <= Math.abs(deltaY) * 1.25) {
      return;
    }

    const currentIndex = activeSessionKey
      ? orderedSessionKeys.indexOf(activeSessionKey)
      : -1;

    if (currentIndex < 0) {
      return;
    }

    const nextIndex = deltaX < 0 ? currentIndex + 1 : currentIndex - 1;
    const nextSessionKey = orderedSessionKeys[nextIndex];

    if (!nextSessionKey || nextSessionKey === activeSessionKey) {
      return;
    }

    onSelectSession(nextSessionKey, "swipe");
  }

  function handleChatPanelTouchStart(input: {
    target: EventTarget | null;
    touch: { clientX: number; clientY: number } | null;
  }) {
    const target = input.target;

    if (
      !(target instanceof Element) ||
      target.closest(
        "button, input, textarea, select, a, label, audio, video, .chat-floating-stack"
      )
    ) {
      touchStartRef.current.active = false;
      return;
    }

    const touch = input.touch;

    if (!touch) {
      touchStartRef.current.active = false;
      return;
    }

    touchStartRef.current = {
      active: true,
      x: touch.clientX,
      y: touch.clientY
    };
  }

  return {
    handleChatPanelTouchCancel,
    handleChatPanelTouchEnd,
    handleChatPanelTouchStart,
    handlePopupSessionSelect(sessionKey) {
      onSelectSession(sessionKey, "popup");
    },
    keyboardInset,
    layoutStyle,
    shouldEnableSwipeNavigation
  };
}
