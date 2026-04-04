import { useEffect, useRef, useState, type PointerEvent, type ReactNode } from "react";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import type {
  ChatMessageRecord,
  PendingMessageRecord,
  SessionScrollState
} from "../../runtime/chat/chatDomainStore";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import { ExpandedMessageOverlay } from "./ExpandedMessageOverlay";
import { MessageAttachments } from "./MessageAttachments";
import { MessageLinkCards } from "./MessageLinkCards";
import {
  analyzeMessagePresentation,
  getMessageSenderInitial,
  getMessageSenderLabel,
  hasStreamingAssistantMessage
} from "./messagePresentation";
import { projectFailedMessageRetryState } from "./chatSendState";
import { RichMessageBody, shouldOfferExpandedMessage } from "./RichMessageBody";
import { useVirtualMessageWindow } from "./useVirtualMessageWindow";

const TYPING_INDICATOR_HEIGHT = 90;
const TYPING_INDICATOR_GAP = 14;
const TYPING_ACTIVITY_SETTLE_MS = 180;

export function MessageList({
  messages,
  onRememberScrollState,
  onUnreadAnchorConsumed,
  rememberedScrollState,
  sessionKey,
  unreadAnchorMessageId,
  viewportInsetBottom = 0
}: {
  messages: ChatMessageRecord[];
  onRememberScrollState?: (input: {
    offsetTop: number;
    sessionKey: string;
    stickToBottom: boolean;
  }) => void;
  onUnreadAnchorConsumed?: (messageId: string) => void;
  rememberedScrollState?: SessionScrollState;
  sessionKey?: string;
  unreadAnchorMessageId?: string | null;
  viewportInsetBottom?: number;
}) {
  const { state: authState } = useAuthSessionStore();
  const { store: chatStore } = useChatDomainStore();
  const { store: transportStore } = useTransportMachine();
  const [expandedMessageId, setExpandedMessageId] = useState<string | null>(null);
  const {
    containerRef,
    handleScroll,
    isAtBottom,
    isAtBottomRef,
    registerMessageSize,
    renderedMessages,
    scrollTop,
    scrollToBottom,
    scrollToMessage,
    scrollToOffset,
    totalHeight
  } = useVirtualMessageWindow(messages);
  const shouldShowTypingIndicator = hasStreamingAssistantMessage(messages);
  const [isTypingIndicatorVisible, setIsTypingIndicatorVisible] = useState(
    shouldShowTypingIndicator
  );
  const restoredSessionKeyRef = useRef<string | null>(null);
  const consumedUnreadAnchorRef = useRef<string | null>(null);
  const touchScrollActiveRef = useRef(false);
  const touchScrollReleaseTimeoutRef = useRef<number | null>(null);
  const expandedMessage = messages.find((message) => message.id === expandedMessageId) ?? null;
  const typingIndicatorOffsetTop = totalHeight + (messages.length > 0 ? TYPING_INDICATOR_GAP : 0);
  const virtualSurfaceHeight =
    totalHeight
    + (isTypingIndicatorVisible ? TYPING_INDICATOR_HEIGHT + (messages.length > 0 ? TYPING_INDICATOR_GAP : 0) : 0);

  useEffect(() => {
    return () => {
      if (touchScrollReleaseTimeoutRef.current !== null) {
        window.clearTimeout(touchScrollReleaseTimeoutRef.current);
      }
    };
  }, []);

  useEffect(() => {
    if (shouldShowTypingIndicator) {
      setIsTypingIndicatorVisible(true);
      return;
    }

    const timeoutId = window.setTimeout(() => {
      setIsTypingIndicatorVisible(false);
    }, TYPING_ACTIVITY_SETTLE_MS);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [shouldShowTypingIndicator]);

  useEffect(() => {
    if (!sessionKey || !onRememberScrollState) {
      return;
    }

    if (restoredSessionKeyRef.current !== sessionKey) {
      return;
    }

    onRememberScrollState({
      offsetTop: scrollTop,
      sessionKey,
      stickToBottom: isAtBottom
    });
  }, [isAtBottom, onRememberScrollState, scrollTop, sessionKey]);

  useEffect(() => {
    if (!sessionKey) {
      return;
    }

    if (restoredSessionKeyRef.current === sessionKey) {
      return;
    }

    restoredSessionKeyRef.current = sessionKey;

    if (rememberedScrollState?.stickToBottom) {
      scrollToBottom();
      return;
    }

    if (rememberedScrollState) {
      scrollToOffset(rememberedScrollState.offsetTop);
      return;
    }

    scrollToOffset(0);
  }, [
    rememberedScrollState,
    scrollToBottom,
    scrollToOffset,
    sessionKey,
  ]);

  useEffect(() => {
    if (!sessionKey || !unreadAnchorMessageId) {
      return;
    }

    const unreadAnchorKey = `${sessionKey}:${unreadAnchorMessageId}`;

    if (consumedUnreadAnchorRef.current === unreadAnchorKey) {
      return;
    }

    if (!scrollToMessage(unreadAnchorMessageId, "center")) {
      return;
    }

    consumedUnreadAnchorRef.current = unreadAnchorKey;
    onUnreadAnchorConsumed?.(unreadAnchorMessageId);
  }, [onUnreadAnchorConsumed, scrollToMessage, sessionKey, unreadAnchorMessageId]);

  useEffect(() => {
    if (viewportInsetBottom <= 0) {
      return;
    }

    const activeElement = document.activeElement;
    const isComposerFocused =
      activeElement instanceof HTMLTextAreaElement &&
      activeElement.id === "composer-input";

    if (!isComposerFocused || !isAtBottomRef.current || touchScrollActiveRef.current) {
      return;
    }

    const frame = window.requestAnimationFrame(() => {
      scrollToBottom();
    });

    return () => {
      window.cancelAnimationFrame(frame);
    };
  }, [isAtBottomRef, scrollToBottom, viewportInsetBottom]);

  useEffect(() => {
    if (!isTypingIndicatorVisible || !isAtBottom) {
      return;
    }

    const frame = window.requestAnimationFrame(() => {
      scrollToBottom();
    });

    return () => {
      window.cancelAnimationFrame(frame);
    };
  }, [isAtBottom, isTypingIndicatorVisible, scrollToBottom]);

  async function handleRetryMessage(messageId: string) {
    const pendingMessage = chatStore.getState().pendingMessages[messageId];
    const message = messages.find((entry) => entry.id === messageId);
    const retryState = projectFailedMessageRetryState({
      delivery: message?.delivery ?? "server",
      pendingMessage,
      transportPhase: transportStore.getState().phase
    });

    if (!retryState.canRetry || !pendingMessage) {
      return;
    }

    if (retryState.action === "reconnect") {
      transportStore.retryNow();
      return;
    }

    chatStore.markMessagePending(messageId);

    try {
      await transportStore.sendMessage({
        attachments: pendingMessage.wireAttachments,
        content: pendingMessage.content,
        id: messageId,
        sessionKey: pendingMessage.sessionKey
      });
    } catch {
      chatStore.markMessageFailed(messageId);
    }
  }

  if (messages.length === 0) {
    return (
      <section className="message-list empty-state">
        <p className="eyebrow">No Messages Yet</p>
        <h2>This stream is ready for text chat.</h2>
        <p>Send the first message once the connection is live.</p>
      </section>
    );
  }

  return (
    <>
      <section
        aria-live="polite"
        className="message-list"
        data-testid="message-list"
        onScroll={handleScroll}
        onTouchCancel={() => {
          if (touchScrollReleaseTimeoutRef.current !== null) {
            window.clearTimeout(touchScrollReleaseTimeoutRef.current);
          }
          touchScrollActiveRef.current = false;
        }}
        onTouchEnd={() => {
          if (touchScrollReleaseTimeoutRef.current !== null) {
            window.clearTimeout(touchScrollReleaseTimeoutRef.current);
          }
          touchScrollReleaseTimeoutRef.current = window.setTimeout(() => {
            touchScrollActiveRef.current = false;
            touchScrollReleaseTimeoutRef.current = null;
          }, 180);
        }}
        onTouchStart={() => {
          if (touchScrollReleaseTimeoutRef.current !== null) {
            window.clearTimeout(touchScrollReleaseTimeoutRef.current);
            touchScrollReleaseTimeoutRef.current = null;
          }
          touchScrollActiveRef.current = true;
        }}
        ref={containerRef}
      >
        <div
          className="message-list-virtual-surface"
          style={{ height: `${Math.max(virtualSurfaceHeight, 0)}px` }}
        >
          {renderedMessages.map(({ message, offsetLeft, offsetTop, width }) => (
            <MeasuredMessageRow
              key={message.id}
              messageId={message.id}
              offsetLeft={offsetLeft}
              offsetTop={offsetTop}
              onSizeChange={registerMessageSize}
              width={width}
            >
              <MessageBubble
                message={message}
                onExpand={() => setExpandedMessageId(message.id)}
                onRetry={() => void handleRetryMessage(message.id)}
                pendingMessage={chatStore.getState().pendingMessages[message.id]}
                transportPhase={transportStore.getState().phase}
                serverUrl={authState.session?.serverUrl}
                token={authState.session?.token}
              />
            </MeasuredMessageRow>
          ))}
          {isTypingIndicatorVisible ? (
            <div
              className="message-list-row message-list-row--typing"
              style={{ left: "0px", top: `${typingIndicatorOffsetTop}px` }}
            >
              <TypingIndicator />
            </div>
          ) : null}
        </div>
      </section>
      {!isAtBottom ? (
        <div className="message-list-affordance-bar">
          <button
            className="button-secondary message-list-jump-button"
            data-testid="scroll-to-bottom-button"
            onClick={() => scrollToBottom()}
            type="button"
          >
            Jump to latest
          </button>
        </div>
      ) : null}
      {expandedMessage ? (
        <ExpandedMessageOverlay
          message={expandedMessage}
          onClose={() => setExpandedMessageId(null)}
        />
      ) : null}
    </>
  );
}

function TypingIndicator() {
  return (
    <div className="message-typing-indicator" data-testid="typing-indicator">
      <span className="sr-only">Assistant is typing</span>
      <span aria-hidden="true" className="message-typing-indicator-dots">
        <span className="message-typing-indicator-dot" />
        <span className="message-typing-indicator-dot" />
        <span className="message-typing-indicator-dot" />
      </span>
    </div>
  );
}

function MeasuredMessageRow({
  children,
  messageId,
  offsetLeft,
  offsetTop,
  onSizeChange,
  width
}: {
  children: ReactNode;
  messageId: string;
  offsetLeft: number;
  offsetTop: number;
  onSizeChange: (messageId: string, size: { height: number; width: number }) => void;
  width: number;
}) {
  const rowRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const row = rowRef.current;
    if (!row) {
      return;
    }

    function measure() {
      if (!rowRef.current) {
        return;
      }

      const measuredTarget =
        rowRef.current.firstElementChild instanceof HTMLElement
          ? rowRef.current.firstElementChild
          : rowRef.current;
      const rect = measuredTarget.getBoundingClientRect();
      onSizeChange(messageId, {
        height: rect.height,
        width: rect.width
      });
    }

    measure();

    const resizeObserver =
      typeof window.ResizeObserver === "function"
        ? new window.ResizeObserver(() => {
            measure();
          })
        : null;

    resizeObserver?.observe(row);

    return () => {
      resizeObserver?.disconnect();
    };
  }, [messageId, onSizeChange]);

  return (
    <div
      className="message-list-row"
      ref={rowRef}
      style={{
        left: `${offsetLeft}px`,
        top: `${offsetTop}px`,
        width: `${width}px`
      }}
    >
      {children}
    </div>
  );
}

function MessageBubble({
  message,
  onExpand,
  onRetry,
  pendingMessage,
  serverUrl,
  transportPhase,
  token
}: {
  message: ChatMessageRecord;
  onExpand: () => void;
  onRetry: () => void;
  pendingMessage?: PendingMessageRecord;
  serverUrl?: string;
  transportPhase: Parameters<typeof projectFailedMessageRetryState>[0]["transportPhase"];
  token?: string;
}) {
  const contentRef = useRef<HTMLDivElement | null>(null);
  const [isTimestampVisible, setTimestampVisible] = useState(false);
  const senderLabel = getMessageSenderLabel(message);
  const senderInitial = getMessageSenderInitial(message);
  const isUser = message.role === "user";
  const presentation = analyzeMessagePresentation(message, shouldOfferExpandedMessage);
  const retryState = projectFailedMessageRetryState({
    delivery: message.delivery,
    pendingMessage,
    transportPhase
  });
  const timestampLabel = formatMessageTimestamp(message.timestamp);

  function handlePointerUp(event: PointerEvent<HTMLElement>) {
    if (presentation.isTruncated) {
      return;
    }

    if (event.pointerType === "touch" || event.pointerType === "pen") {
      setTimestampVisible((current) => !current);
    }
  }

  return (
    <article
      className={
        [
          "message-bubble",
          isUser ? "message-bubble--user" : "message-bubble--assistant",
          `message-bubble--${presentation.sizeClass}`,
          isTimestampVisible ? "message-bubble--timestamp-visible" : null,
          presentation.chromeKind !== "default"
            ? `message-bubble--${presentation.chromeKind}`
            : null,
          presentation.isWide ? "message-bubble--wide" : null,
          presentation.isTruncated ? "message-bubble--truncated" : null
        ]
          .filter(Boolean)
          .join(" ")
      }
      data-message-chrome={presentation.chromeKind}
      data-message-size={presentation.sizeClass}
      data-testid={`message-${message.id}`}
      onClick={presentation.isTruncated ? onExpand : undefined}
      onPointerUp={handlePointerUp}
      role={presentation.isTruncated ? "button" : undefined}
      style={presentation.isTruncated ? { cursor: "pointer" } : undefined}
    >
      <header className="message-header">
        <div
          aria-hidden="true"
          className={isUser ? "message-avatar message-avatar--user" : "message-avatar message-avatar--assistant"}
          data-testid={`message-avatar-${message.id}`}
        >
          {senderInitial}
        </div>
        <div className="message-header-text">
          <span className="message-sender-name">{senderLabel}</span>
          <span className="message-timestamp">{timestampLabel}</span>
        </div>
      </header>
      <RichMessageBody
        className={[
          `message-markdown--${presentation.sizeClass}`,
          presentation.chromeKind === "chromeless-emoji" ? "message-markdown--emoji" : null,
          presentation.isWide ? "message-markdown--wide" : null
        ]
          .filter(Boolean)
          .join(" ")}
        content={message.content}
        contentRef={contentRef}
      />
      <MessageLinkCards content={message.content} contentRef={contentRef} />
      <MessageAttachments
        attachments={message.attachments}
        serverUrl={serverUrl}
        token={token}
      />
      {/* Tap bubble to expand — no visible button, matches iOS behavior */}
      <footer className="message-status">
        {message.delivery === "pending" ? "Sending..." : null}
        {message.delivery === "acked" ? "Accepted by provider" : null}
        {retryState.shouldShowRetry ? (
          <>
            <span>Send failed</span>
            <button
              className="message-status-action"
              onClick={(event) => {
                event.stopPropagation();
                onRetry();
              }}
              type="button"
            >
              Retry
            </button>
          </>
        ) : null}
      </footer>
    </article>
  );
}

function formatMessageTimestamp(timestamp: number, now = Date.now()) {
  const messageDate = new Date(timestamp);
  const nowDate = new Date(now);
  const diffMs = Math.max(0, now - timestamp);
  const diffMinutes = Math.floor(diffMs / 60_000);

  if (diffMs < 60_000) {
    return "just now";
  }

  if (diffMinutes < 60) {
    return `${diffMinutes}m ago`;
  }

  if (isSameDay(messageDate, nowDate)) {
    return messageDate.toLocaleTimeString([], {
      hour: "numeric",
      minute: "2-digit"
    });
  }

  const yesterday = new Date(nowDate);
  yesterday.setDate(nowDate.getDate() - 1);

  if (isSameDay(messageDate, yesterday)) {
    return `Yesterday, ${messageDate.toLocaleTimeString([], {
      hour: "numeric",
      minute: "2-digit"
    })}`;
  }

  const diffDays = Math.floor(diffMs / 86_400_000);
  if (diffDays < 7) {
    return messageDate.toLocaleDateString([], {
      weekday: "long",
      hour: "numeric",
      minute: "2-digit"
    });
  }

  if (messageDate.getFullYear() === nowDate.getFullYear()) {
    return messageDate.toLocaleDateString([], {
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit"
    });
  }

  return messageDate.toLocaleDateString([], {
    month: "short",
    day: "numeric",
    year: "numeric"
  });
}

function isSameDay(left: Date, right: Date) {
  return (
    left.getFullYear() === right.getFullYear() &&
    left.getMonth() === right.getMonth() &&
    left.getDate() === right.getDate()
  );
}
