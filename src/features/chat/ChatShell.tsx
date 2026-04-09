import type { CSSProperties, TouchEvent } from "react";
import type {
  ChatMessageRecord,
  SessionScrollState,
  StreamDotState,
  StreamRecord
} from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { Composer } from "./Composer";
import { MessageList } from "./MessageList";
import { SessionListSheet } from "./SessionListSheet";
import { StreamPageDots } from "./StreamPageDots";
import type { SessionProvisioningState } from "../streams/provisioning";

export function ChatShell({
  activeSessionKey,
  chatLayoutStyle,
  keyboardInset,
  isSessionListOpen,
  onCloseSessionList,
  onChatPanelTouchCancel,
  onChatPanelTouchEnd,
  onChatPanelTouchStart,
  onOpenSessionList,
  onOpenStreamManager,
  onPopupSessionSelect,
  onRememberScrollState,
  onUnreadAnchorConsumed,
  provisionedSessionKeys,
  provisioningState,
  rememberedScrollState,
  selectedMessages,
  selectedSessionKey,
  uiSelectedSessionKey,
  selectedUnreadAnchorMessageId,
  streamDotStateBySessionKey,
  streams,
  transportPhase
}: {
  activeSessionKey?: string;
  chatLayoutStyle: CSSProperties;
  keyboardInset: number;
  isSessionListOpen: boolean;
  onCloseSessionList: () => void;
  onChatPanelTouchCancel: () => void;
  onChatPanelTouchEnd: (input: {
    touch: { clientX: number; clientY: number } | null;
  }) => void;
  onChatPanelTouchStart: (input: {
    target: EventTarget | null;
    touch: { clientX: number; clientY: number } | null;
  }) => void;
  onOpenSessionList: () => void;
  onOpenStreamManager: () => void;
  onPopupSessionSelect: (sessionKey: string) => void;
  onRememberScrollState: (input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }) => void;
  onUnreadAnchorConsumed: (messageId: string) => void;
  provisionedSessionKeys: string[];
  provisioningState: SessionProvisioningState;
  rememberedScrollState?: SessionScrollState;
  selectedMessages: ChatMessageRecord[];
  selectedSessionKey?: string;
  uiSelectedSessionKey?: string;
  selectedUnreadAnchorMessageId?: string | null;
  streamDotStateBySessionKey: Record<string, StreamDotState>;
  streams: StreamRecord[];
  transportPhase: TransportPhase;
}) {
  const shouldEnableSwipeNavigation = keyboardInset <= 0;

  return (
    <section
      className="chat-layout"
      data-testid="chat-layout"
      style={chatLayoutStyle}
    >
      <main
        className="chat-panel"
        data-testid="chat-panel"
        onTouchCancel={shouldEnableSwipeNavigation ? onChatPanelTouchCancel : undefined}
        onTouchEnd={shouldEnableSwipeNavigation ? (event: TouchEvent<HTMLElement>) =>
          onChatPanelTouchEnd({
            touch: event.changedTouches[0]
              ? {
                  clientX: event.changedTouches[0].clientX,
                  clientY: event.changedTouches[0].clientY
                }
              : null
          }) : undefined}
        onTouchStart={shouldEnableSwipeNavigation ? (event: TouchEvent<HTMLElement>) =>
          onChatPanelTouchStart({
            target: event.target,
            touch: event.touches[0]
              ? {
                  clientX: event.touches[0].clientX,
                  clientY: event.touches[0].clientY
                }
              : null
          }) : undefined}
      >
        <MessageList
          messages={selectedMessages}
          onRememberScrollState={onRememberScrollState}
          onUnreadAnchorConsumed={onUnreadAnchorConsumed}
          viewportInsetBottom={keyboardInset}
          rememberedScrollState={rememberedScrollState}
          sessionKey={selectedSessionKey}
          unreadAnchorMessageId={selectedUnreadAnchorMessageId}
        />
        <div className="chat-floating-stack">
          {provisioningState === "waiting" ? (
            <div className="provisioning-banner provisioning-banner--floating">
              This session is waiting for provisioning before send becomes available.
            </div>
          ) : null}
          {provisioningState === "unavailable" ? (
            <div className="provisioning-banner provisioning-banner--warning provisioning-banner--floating">
              This session is unavailable for sending. Switch streams and try again.
            </div>
          ) : null}
          {streams.length > 0 ? (
            <div className="chat-dots-dock">
              <StreamPageDots
                activeSessionKey={uiSelectedSessionKey}
                onClick={onOpenSessionList}
                sessionKeys={streams.map((stream) => stream.sessionKey)}
                streamDotStateBySessionKey={streamDotStateBySessionKey}
              />
            </div>
          ) : null}
          <Composer
            activeStreamDisplayName={streams.find((s) => s.sessionKey === activeSessionKey)?.displayName}
            provisioningState={provisioningState}
            sessionKey={activeSessionKey}
          />
        </div>
      </main>
      <SessionListSheet
        activeSessionKey={uiSelectedSessionKey}
        isOpen={isSessionListOpen}
        onClose={onCloseSessionList}
        onOpenStreamManager={onOpenStreamManager}
        onSelectSession={onPopupSessionSelect}
        provisionedSessionKeys={provisionedSessionKeys}
        streamDotStateBySessionKey={streamDotStateBySessionKey}
        streams={streams}
        transportPhase={transportPhase}
      />
    </section>
  );
}
