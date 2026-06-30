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
import { useCrossChatNotificationStore } from "../../runtime/chat/crossChatNotificationStore";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import {
  createStreamApiClient,
  type SessionControlAction,
  type SessionStatusPayload
} from "../../protocol/stream-api";
import { ChatShell } from "./ChatShell";
import {
  type ChatSessionSwitchSource,
  useChatSessionCoordinator,
  useChatSessionInteractionCoordinator
} from "./useChatSessionCoordinator";

const SESSION_STATUS_REQUEST_TIMEOUT_MS = 2_000;
const SESSION_STATUS_RUNNING_REFRESH_MS = 5_000;
const SESSION_STATUS_RETRY_MS = 10_000;

export function ChatRoute() {
  const navigate = useNavigate();
  const params = useParams();
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { store: notificationStore } = useCrossChatNotificationStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [sessionStatusBySessionKey, setSessionStatusBySessionKey] = useState<
    Record<string, SessionStatusPayload>
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
  const rememberSessionScrollState = useCallback(
    (input: {
      offsetTop: number;
      sessionKey: string;
      stickToBottom: boolean;
    }) => chatStore.rememberSessionScrollState(input),
    [chatStore]
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
        sessionStatusBySessionKey,
        chatState.streams.map((stream) => stream.sessionKey)
      );
    },
    [
      chatState.streamReadStateBySessionKey,
      chatState.streamTailStateBySessionKey,
      chatState.streams,
      sessionStatusBySessionKey
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

    setSessionStatusBySessionKey((current) =>
      Object.fromEntries(
        Object.entries(current).filter(([sessionKey]) => liveSessionKeys.has(sessionKey))
      )
    );

    async function refreshSessionStatus(sessionKey: string) {
      const abortController = new AbortController();
      abortControllers.add(abortController);
      const timeoutId = window.setTimeout(
        () => abortController.abort(),
        SESSION_STATUS_REQUEST_TIMEOUT_MS
      );
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
        setSessionStatusBySessionKey((current) =>
          current[sessionKey] === status
            ? current
            : {
                ...current,
                [sessionKey]: status
              }
        );

        if (runState === "running" || runState === "queued") {
          timers.push(
            window.setTimeout(
              () => void refreshSessionStatus(sessionKey),
              SESSION_STATUS_RUNNING_REFRESH_MS
            )
          );
        }
      } catch (error) {
        if (cancelled) {
          return;
        }

        if (shouldRetrySessionStatus(error)) {
          timers.push(
            window.setTimeout(
              () => void refreshSessionStatus(sessionKey),
              SESSION_STATUS_RETRY_MS
            )
          );
          return;
        }

        setSessionStatusBySessionKey((current) => {
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

  const handleSelectSession = useCallback(
    (
      sessionKey: string,
      source: ChatSessionSwitchSource,
      options?: { keepSessionListOpen?: boolean }
    ) => {
      coordinator.requestSessionSwitch(sessionKey, source, options);
      navigate(`/chat/${sessionKey}`);
    },
    [coordinator, navigate]
  );
  const interactionCoordinator = useChatSessionInteractionCoordinator({
    activeSessionKey,
    onSelectSession: handleSelectSession,
    orderedSessionKeys: chatState.streams.map((stream) => stream.sessionKey)
  });
  const applySessionControl = useCallback(
    async (
      sessionKey: string,
      action: SessionControlAction,
      value?: string | null,
      enabled?: boolean | null
    ) => {
      const token = authState.session?.token;
      const serverUrl = authState.session?.serverUrl;
      if (!token || !serverUrl) {
        return;
      }

      const streamApiClient = createStreamApiClient();
      try {
        const response = await streamApiClient.applySessionControl({
          action,
          enabled,
          serverUrl,
          sessionKey,
          token,
          value
        });
        if (response.status) {
          const nextStatus = response.status;
          setSessionStatusBySessionKey((current) => ({
            ...current,
            [nextStatus.sessionKey]: nextStatus
          }));
          return;
        }

        const abortController = new AbortController();
        const timeoutId = window.setTimeout(
          () => abortController.abort(),
          SESSION_STATUS_REQUEST_TIMEOUT_MS
        );
        try {
          const nextStatus = await streamApiClient.fetchSessionStatus({
            serverUrl,
            sessionKey,
            signal: abortController.signal,
            token
          });
          setSessionStatusBySessionKey((current) => ({
            ...current,
            [nextStatus.sessionKey]: nextStatus
          }));
        } finally {
          window.clearTimeout(timeoutId);
        }
      } catch (error) {
        console.warn("Session control request failed", error);
      }
    },
    [authState.session?.serverUrl, authState.session?.token]
  );
  const createSessionFromPopup = useCallback(async () => {
    const token = authState.session?.token;
    const serverUrl = authState.session?.serverUrl;
    if (!token || !serverUrl) {
      return null;
    }

    const streamApiClient = createStreamApiClient();
    const response = await streamApiClient.createStream({
      displayName: "New Chat",
      idempotencyKey: crypto.randomUUID(),
      serverUrl,
      token
    });
    chatStore.upsertStream(response.stream);
    handleSelectSession(response.stream.sessionKey, "popup", {
      keepSessionListOpen: true
    });
    return response.stream;
  }, [
    authState.session?.serverUrl,
    authState.session?.token,
    chatStore,
    handleSelectSession
  ]);
  const renameSessionFromPopup = useCallback(
    async (sessionKey: string, displayName: string) => {
      const token = authState.session?.token;
      const serverUrl = authState.session?.serverUrl;
      if (!token || !serverUrl) {
        return;
      }

      const streamApiClient = createStreamApiClient();
      const response = await streamApiClient.renameStream({
        displayName,
        serverUrl,
        sessionKey,
        token
      });
      chatStore.upsertStream(response.stream);
    },
    [authState.session?.serverUrl, authState.session?.token, chatStore]
  );
  const deleteSessionFromPopup = useCallback(
    async (sessionKey: string) => {
      const token = authState.session?.token;
      const serverUrl = authState.session?.serverUrl;
      if (!token || !serverUrl) {
        return;
      }

      const streamApiClient = createStreamApiClient();
      await streamApiClient.deleteStream({
        idempotencyKey: crypto.randomUUID(),
        serverUrl,
        sessionKey,
        token
      });
      chatStore.removeStream(sessionKey);
    },
    [authState.session?.serverUrl, authState.session?.token, chatStore]
  );

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
    notificationStore.dismissCrossChatNotification(activeSessionKey);
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
    notificationStore,
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
        isStreamManagerOpen={coordinator.isStreamManagerOpen}
        onCloseSessionList={coordinator.closeSessionList}
        onCreateSession={createSessionFromPopup}
        onDeleteSession={deleteSessionFromPopup}
        onChatPanelTouchCancel={interactionCoordinator.handleChatPanelTouchCancel}
        onChatPanelTouchEnd={interactionCoordinator.handleChatPanelTouchEnd}
        onChatPanelTouchStart={interactionCoordinator.handleChatPanelTouchStart}
        onOpenSessionList={coordinator.openSessionList}
        onOpenStreamManager={coordinator.openStreamManager}
        onPopupSessionSelect={interactionCoordinator.handlePopupSessionSelect}
        onRenameSession={renameSessionFromPopup}
        onCancelCurrentPrompt={(sessionKey) =>
          applySessionControl(sessionKey, "cancel_current_run")
        }
        onRememberScrollState={rememberSessionScrollState}
        onSessionControlSelected={applySessionControl}
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
        selectedSessionStatus={
          activeSessionKey ? sessionStatusBySessionKey[activeSessionKey] ?? null : null
        }
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
  sessionStatusBySessionKey: Record<string, SessionStatusPayload>,
  sessionKeys: string[]
) {
  const next = { ...dotStates };
  for (const sessionKey of sessionKeys) {
    const runState = sessionStatusBySessionKey[sessionKey]?.run?.state;
    if (runState !== "running" && runState !== "queued") {
      continue;
    }

    if (next[sessionKey] !== "unread") {
      next[sessionKey] = "userTail";
    }
  }

  return next;
}

function shouldRetrySessionStatus(error: unknown) {
  if (error instanceof DOMException && error.name === "AbortError") {
    return true;
  }
  if (error instanceof TypeError) {
    return true;
  }
  if (isHttpStreamApiError(error)) {
    return (
      error.statusCode === 408 ||
      error.statusCode === 429 ||
      error.statusCode >= 500
    );
  }

  return false;
}

function isHttpStreamApiError(error: unknown): error is { statusCode: number } {
  return (
    typeof error === "object" &&
    error !== null &&
    "statusCode" in error &&
    typeof error.statusCode === "number"
  );
}
