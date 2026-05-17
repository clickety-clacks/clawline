import type { CSSProperties, TouchEvent } from "react";
import type {
  ChatMessageRecord,
  SessionScrollState,
  StreamDotState,
  StreamRecord
} from "../../runtime/chat/chatDomainStore";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import type {
  SessionControlAction,
  SessionStatusPayload
} from "../../protocol/stream-api";
import { Composer } from "./Composer";
import { CrossChatNotificationOverlay } from "./CrossChatNotificationOverlay";
import { MessageList } from "./MessageList";
import { SessionListSheet } from "./SessionListSheet";
import { StreamPageDots } from "./StreamPageDots";
import type { SessionProvisioningState } from "../streams/provisioning";

export function ChatShell({
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
  onCancelCurrentPrompt,
  onRememberScrollState,
  onSessionControlSelected,
  onUnreadAnchorConsumed,
  provisionedSessionKeys,
  provisioningState,
  rememberedScrollState,
  selectedMessages,
  selectedSessionKey,
  selectedSessionStatus,
  selectedUnreadAnchorMessageId,
  streamDotStateBySessionKey,
  unreadBySessionKey,
  streams,
  transportPhase
}: {
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
  onCancelCurrentPrompt?: (sessionKey: string) => Promise<void> | void;
  onRememberScrollState: (input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }) => void;
  onSessionControlSelected?: (
    sessionKey: string,
    action: SessionControlAction,
    value?: string | null,
    enabled?: boolean | null
  ) => Promise<void> | void;
  onUnreadAnchorConsumed: (messageId: string) => void;
  provisionedSessionKeys: string[];
  provisioningState: SessionProvisioningState;
  rememberedScrollState?: SessionScrollState;
  selectedMessages: ChatMessageRecord[];
  selectedSessionKey?: string;
  selectedSessionStatus?: SessionStatusPayload | null;
  selectedUnreadAnchorMessageId?: string | null;
  streamDotStateBySessionKey: Record<string, StreamDotState>;
  unreadBySessionKey: Record<string, number>;
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
        <CrossChatNotificationOverlay />
        <MessageList
          messages={selectedMessages}
          onCancelCurrentPrompt={onCancelCurrentPrompt}
          onRememberScrollState={onRememberScrollState}
          onSessionControlSelected={onSessionControlSelected}
          onUnreadAnchorConsumed={onUnreadAnchorConsumed}
          viewportInsetBottom={keyboardInset}
          rememberedScrollState={rememberedScrollState}
          sessionKey={selectedSessionKey}
          sessionStatus={selectedSessionStatus}
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
                activeSessionKey={selectedSessionKey}
                onClick={onOpenSessionList}
                sessionKeys={streams.map((stream) => stream.sessionKey)}
                streamDotStateBySessionKey={streamDotStateBySessionKey}
              />
            </div>
          ) : null}
          <Composer
            activeStreamDisplayName={streams.find((s) => s.sessionKey === selectedSessionKey)?.displayName}
            provisioningState={provisioningState}
            sessionKey={selectedSessionKey}
            streams={streams}
          />
        </div>
      </main>
      <SessionListSheet
        activeSessionKey={selectedSessionKey}
        isOpen={isSessionListOpen}
        onClose={onCloseSessionList}
        onOpenStreamManager={onOpenStreamManager}
        onSelectSession={onPopupSessionSelect}
        provisionedSessionKeys={provisionedSessionKeys}
        streamDotStateBySessionKey={streamDotStateBySessionKey}
        unreadBySessionKey={unreadBySessionKey}
        streams={streams}
        transportPhase={transportPhase}
      />
    </section>
  );
}
