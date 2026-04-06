import { useEffect, useMemo, useState } from "react";
import { Navigate, useNavigate, useParams } from "react-router-dom";
import { StreamManagerDrawer } from "../streams/StreamManagerDrawer";
import { getSessionProvisioningState } from "../streams/provisioning";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import { ChatShell } from "./ChatShell";
import {
  type ChatSessionSwitchSource,
  useChatSessionCoordinator,
  useChatSessionInteractionCoordinator
} from "./useChatSessionCoordinator";

export function ChatRoute() {
  const navigate = useNavigate();
  const params = useParams();
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
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
  const engineActiveSessionKey = coordinator.engineActiveSessionKey;
  const uiSelectedSessionKey =
    coordinator.uiSelectedSessionKey ?? coordinator.engineActiveSessionKey;
  const activeStream = chatState.streams.find(
    (stream) => stream.sessionKey === engineActiveSessionKey
  );
  const provisioningState = getSessionProvisioningState({
    hasStream: Boolean(activeStream),
    provisionedSessionKeys: chatState.provisionedSessionKeys,
    sessionKey: engineActiveSessionKey,
    transportPhase: transportState.phase
  });

  const selectedMessages = useMemo(
    () =>
      engineActiveSessionKey
        ? chatState.messagesBySessionKey[engineActiveSessionKey] ?? []
        : [],
    [chatState.messagesBySessionKey, engineActiveSessionKey]
  );

  useEffect(() => {
    transportStore.setSelectedSessionKey(engineActiveSessionKey);
  }, [engineActiveSessionKey, transportStore]);

  const handleSelectSession = (sessionKey: string, source: ChatSessionSwitchSource) => {
    coordinator.requestSessionSwitch(sessionKey, source);
    navigate(`/chat/${sessionKey}`);
  };

  const interactionCoordinator = useChatSessionInteractionCoordinator({
    activeSessionKey: engineActiveSessionKey,
    onSelectSession: handleSelectSession,
    orderedSessionKeys: chatState.streams.map((stream) => stream.sessionKey)
  });

  useEffect(() => {
    if (!engineActiveSessionKey) {
      return;
    }

    const unreadAnchor =
      chatState.firstUnreadMessageIdBySessionKey[engineActiveSessionKey] ?? null;

    setSelectedUnreadAnchor((current) => {
      if (unreadAnchor) {
        return current?.sessionKey === engineActiveSessionKey &&
          current.messageId === unreadAnchor
          ? current
          : {
              messageId: unreadAnchor,
              sessionKey: engineActiveSessionKey
            };
      }

      return current?.sessionKey === engineActiveSessionKey ? current : null;
    });

    chatStore.markSessionRead(engineActiveSessionKey);
  }, [
    chatState.firstUnreadMessageIdBySessionKey,
    chatStore,
    engineActiveSessionKey
  ]);

  if (!authState.session?.token) {
    return <Navigate to="/pair" replace />;
  }

  if (!params.sessionKey && coordinator.firstProviderValidSessionKey) {
    return <Navigate replace to={`/chat/${coordinator.firstProviderValidSessionKey}`} />;
  }

  if (
    coordinator.transition.bootRequestedSessionKey &&
    params.sessionKey === coordinator.transition.bootRequestedSessionKey &&
    transportState.phase === "live" &&
    chatState.provisionedSessionKeys.length > 0 &&
    !chatState.provisionedSessionKeys.includes(coordinator.transition.bootRequestedSessionKey)
  ) {
    return coordinator.firstProviderValidSessionKey ? (
      <Navigate replace to={`/chat/${coordinator.firstProviderValidSessionKey}`} />
    ) : (
      <Navigate replace to="/chat" />
    );
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
        activeSessionKey={engineActiveSessionKey}
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
            !engineActiveSessionKey ||
            selectedUnreadAnchor?.sessionKey !== engineActiveSessionKey ||
            selectedUnreadAnchor.messageId !== messageId
          ) {
            return;
          }

          setSelectedUnreadAnchor(null);
        }}
        rememberedScrollState={
          engineActiveSessionKey
            ? chatState.scrollStateBySessionKey[engineActiveSessionKey]
            : undefined
        }
        selectedMessages={selectedMessages}
        selectedSessionKey={engineActiveSessionKey}
        uiSelectedSessionKey={uiSelectedSessionKey}
        selectedUnreadAnchorMessageId={
          selectedUnreadAnchor?.sessionKey === engineActiveSessionKey
            ? selectedUnreadAnchor?.messageId ?? null
            : null
        }
        provisionedSessionKeys={chatState.provisionedSessionKeys}
        streams={chatState.streams}
        transportPhase={transportState.phase}
        unreadBySessionKey={chatState.unreadBySessionKey}
      />
      <StreamManagerDrawer
        activeSessionKey={uiSelectedSessionKey}
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
