import { useCallback, useEffect, useMemo, useState } from "react";
import { Navigate, useNavigate, useParams } from "react-router-dom";
import { StreamManagerDrawer } from "../streams/StreamManagerDrawer";
import { getSessionProvisioningState } from "../streams/provisioning";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import {
  resolveStreamDotStateMap,
  type StreamDotState,
  useChatDomainStore
} from "../../runtime/chat/chatDomainStore";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import { createStreamApiClient } from "../../protocol/stream-api";
import { ChatShell } from "./ChatShell";
import {
  type ChatSessionSwitchSource,
  useChatSessionCoordinator,
  useChatSessionInteractionCoordinator
} from "./useChatSessionCoordinator";
import { useChatKeyboardShortcuts } from "./useChatKeyboardShortcuts";

export function ChatRoute() {
  const navigate = useNavigate();
  const params = useParams();
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [networkRunStateBySessionKey, setNetworkRunStateBySessionKey] = useState<
    Record<string, string>
  >({});
  const [selectedUnreadAnchor, setSelectedUnreadAnchor] = useState<{
    messageId: string;
    sessionKey: string;
  } | null>(null);
  const coordinator = useChatSessionCoordinator({
    provisionedSessionKeys: chatState.provisionedSessionKeys,
    routeSessionKey: params.sessionKey,
    streams: chatState.streams,
    transportPhase: transportState.phase
  });
  const activeSessionKey = coordinator.activeSessionKey;
  const activeStream = chatState.streams.find(
    (stream) => stream.sessionKey === activeSessionKey
  );
  const provisioningState = getSessionProvisioningState({
    hasStream: Boolean(activeStream),
    provisionedSessionKeys: chatState.provisionedSessionKeys,
    sessionKey: activeSessionKey,
    transportPhase: transportState.phase
  });

  const selectedMessages = useMemo(
    () =>
      activeSessionKey
        ? chatState.messagesBySessionKey[activeSessionKey] ?? []
        : [],
    [chatState.messagesBySessionKey, activeSessionKey]
  );
  const streamSessionKeySignature = useMemo(
    () => chatState.streams.map((stream) => stream.sessionKey).join("\u0000"),
    [chatState.streams]
  );
  const streamDotStateBySessionKey = useMemo(
    () => {
      const dotStates = resolveStreamDotStateMap(
        chatState.streamReadStateBySessionKey,
        chatState.streamTailStateBySessionKey
      );

      return applyNetworkStatusDotStates(
        dotStates,
        networkRunStateBySessionKey,
        chatState.streams.map((stream) => stream.sessionKey)
      );
    },
    [
      chatState.streamReadStateBySessionKey,
      chatState.streamTailStateBySessionKey,
      chatState.streams,
      networkRunStateBySessionKey
    ]
  );

  useEffect(() => {
    const token = authState.session?.token;
    const serverUrl = authState.session?.serverUrl;
    if (!token || !serverUrl || transportState.phase !== "live") {
      return;
    }
    const statusServerUrl = serverUrl;
    const statusToken = token;

    const sessionKeys = streamSessionKeySignature.split("\u0000").filter(Boolean);
    if (sessionKeys.length === 0) {
      return;
    }

    let cancelled = false;
    const timers: number[] = [];
    const abortControllers = new Set<AbortController>();
    const streamApiClient = createStreamApiClient();
    const liveSessionKeys = new Set(sessionKeys);

    setNetworkRunStateBySessionKey((current) =>
      Object.fromEntries(
        Object.entries(current).filter(([sessionKey]) => liveSessionKeys.has(sessionKey))
      )
    );

    async function refreshSessionStatus(sessionKey: string) {
      const abortController = new AbortController();
      abortControllers.add(abortController);
      const timeoutId = window.setTimeout(() => abortController.abort(), 2_000);
      try {
        const status = await streamApiClient.fetchSessionStatus({
          serverUrl: statusServerUrl,
          sessionKey,
          signal: abortController.signal,
          token: statusToken
        });
        if (cancelled) {
          return;
        }

        const runState = status.run?.state ?? "unknown";
        setNetworkRunStateBySessionKey((current) =>
          current[sessionKey] === runState
            ? current
            : {
                ...current,
                [sessionKey]: runState
              }
        );

        if (runState === "running" || runState === "queued") {
          timers.push(window.setTimeout(() => void refreshSessionStatus(sessionKey), 5_000));
        }
      } catch {
        if (cancelled) {
          return;
        }

        setNetworkRunStateBySessionKey((current) => {
          if (!(sessionKey in current)) {
            return current;
          }
          const next = { ...current };
          delete next[sessionKey];
          return next;
        });
      } finally {
        window.clearTimeout(timeoutId);
        abortControllers.delete(abortController);
      }
    }

    for (const sessionKey of sessionKeys) {
      void refreshSessionStatus(sessionKey);
    }

    return () => {
      cancelled = true;
      for (const timer of timers) {
        window.clearTimeout(timer);
      }
      for (const abortController of abortControllers) {
        abortController.abort();
      }
    };
  }, [
    authState.session?.serverUrl,
    authState.session?.token,
    streamSessionKeySignature,
    transportState.phase
  ]);

  const handleSelectSession = (sessionKey: string, source: ChatSessionSwitchSource) => {
    coordinator.requestSessionSwitch(sessionKey, source);
    navigate(`/chat/${sessionKey}`);
  };
  const focusPromptInput = useCallback(() => {
    document.getElementById("composer-input")?.focus({ preventScroll: true });
  }, []);
  const openSessionListFromShortcut = useCallback(() => {
    coordinator.openSessionList();
  }, [coordinator]);

  const interactionCoordinator = useChatSessionInteractionCoordinator({
    activeSessionKey,
    onSelectSession: handleSelectSession,
    orderedSessionKeys: chatState.streams.map((stream) => stream.sessionKey)
  });
  useChatKeyboardShortcuts({
    canOpenSessionList: chatState.streams.length > 0,
    isShortcutSurfaceBlocked: coordinator.isSessionListOpen || coordinator.isStreamManagerOpen,
    onFocusPromptInput: focusPromptInput,
    onOpenSessionList: openSessionListFromShortcut
  });

  useEffect(() => {
    if (!activeSessionKey) {
      return;
    }

    const unreadAnchor =
      chatState.firstUnreadMessageIdBySessionKey[activeSessionKey] ?? null;

    setSelectedUnreadAnchor((current) => {
      if (unreadAnchor) {
        return current?.sessionKey === activeSessionKey &&
          current.messageId === unreadAnchor
          ? current
          : {
              messageId: unreadAnchor,
              sessionKey: activeSessionKey
            };
      }

      return current?.sessionKey === activeSessionKey ? current : null;
    });

    const lastReadMessageId = chatStore.markSessionRead(activeSessionKey);
    if (
      lastReadMessageId &&
      chatState.provisionedSessionKeys.includes(activeSessionKey)
    ) {
      void transportStore.publishReadState(activeSessionKey, lastReadMessageId);
    }
  }, [
    activeSessionKey,
    chatState.firstUnreadMessageIdBySessionKey,
    chatState.provisionedSessionKeys,
    chatStore,
    transportStore
  ]);

  if (!authState.session?.token) {
    return <Navigate to="/pair" replace />;
  }

  if (!params.sessionKey && coordinator.firstProviderValidSessionKey) {
    return <Navigate replace to={`/chat/${coordinator.firstProviderValidSessionKey}`} />;
  }

  if (params.sessionKey && chatState.streams.length > 0 && !coordinator.routeSessionExists) {
    return coordinator.firstProviderValidSessionKey ? (
      <Navigate replace to={`/chat/${coordinator.firstProviderValidSessionKey}`} />
    ) : (
      <Navigate replace to="/chat" />
    );
  }

  return (
    <>
      <ChatShell
        chatLayoutStyle={interactionCoordinator.layoutStyle}
        keyboardInset={interactionCoordinator.keyboardInset}
        isSessionListOpen={coordinator.isSessionListOpen}
        onCloseSessionList={coordinator.closeSessionList}
        onChatPanelTouchCancel={interactionCoordinator.handleChatPanelTouchCancel}
        onChatPanelTouchEnd={interactionCoordinator.handleChatPanelTouchEnd}
        onChatPanelTouchStart={interactionCoordinator.handleChatPanelTouchStart}
        onOpenSessionList={coordinator.openSessionList}
        onOpenStreamManager={coordinator.openStreamManager}
        onPopupSessionSelect={interactionCoordinator.handlePopupSessionSelect}
        onRememberScrollState={(input) => chatStore.rememberSessionScrollState(input)}
        provisioningState={provisioningState}
        onUnreadAnchorConsumed={(messageId) => {
          if (
            !activeSessionKey ||
            selectedUnreadAnchor?.sessionKey !== activeSessionKey ||
            selectedUnreadAnchor.messageId !== messageId
          ) {
            return;
          }

          setSelectedUnreadAnchor(null);
        }}
        rememberedScrollState={
          activeSessionKey
            ? chatState.scrollStateBySessionKey[activeSessionKey]
            : undefined
        }
        selectedMessages={selectedMessages}
        selectedSessionKey={activeSessionKey}
        selectedUnreadAnchorMessageId={
          selectedUnreadAnchor?.sessionKey === activeSessionKey
            ? selectedUnreadAnchor?.messageId ?? null
            : null
        }
        provisionedSessionKeys={chatState.provisionedSessionKeys}
        streamDotStateBySessionKey={streamDotStateBySessionKey}
        unreadBySessionKey={chatState.unreadBySessionKey}
        streams={chatState.streams}
        transportPhase={transportState.phase}
      />
      <StreamManagerDrawer
        activeSessionKey={activeSessionKey}
        isOpen={coordinator.isStreamManagerOpen}
        onClose={coordinator.closeStreamManager}
        onSelectSession={(sessionKey) => {
          if (sessionKey) {
            handleSelectSession(sessionKey, "stream-manager");
          } else {
            coordinator.closeStreamManager();
            navigate("/chat");
          }
        }}
      />
    </>
  );
}

function applyNetworkStatusDotStates(
  dotStates: Record<string, StreamDotState>,
  networkRunStateBySessionKey: Record<string, string>,
  sessionKeys: string[]
) {
  const next = { ...dotStates };
  for (const sessionKey of sessionKeys) {
    const runState = networkRunStateBySessionKey[sessionKey];
    if (runState !== "running" && runState !== "queued") {
      continue;
    }

    if (next[sessionKey] !== "unread") {
      next[sessionKey] = "userTail";
    }
  }

  return next;
}
