import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type PointerEvent,
  type ReactNode
} from "react";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import type {
  ChatMessageRecord,
  PendingMessageRecord,
  SessionScrollState
} from "../../runtime/chat/chatDomainStore";
import type {
  SessionControlAction,
  SessionStatusPayload
} from "../../protocol/stream-api";
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
import {
  SESSION_STATUS_FOOTER_HEIGHT,
  SessionStatusFooter
} from "./SessionStatusFooter";
import { useVirtualMessageWindow } from "./useVirtualMessageWindow";

const TYPING_INDICATOR_HEIGHT = 90;
const TYPING_INDICATOR_GAP = 14;
const TYPING_ACTIVITY_SETTLE_MS = 180;
const BOTTOM_RESTORE_SETTLE_FRAMES = 8;

export function MessageList({
  messages,
  onCancelCurrentPrompt,
  onRememberScrollState,
  onSessionControlSelected,
  onUnreadAnchorConsumed,
  rememberedScrollState,
  sessionKey,
  sessionStatus,
  unreadAnchorMessageId,
  viewportInsetBottom = 0
}: {
  messages: ChatMessageRecord[];
  onCancelCurrentPrompt?: (sessionKey: string) => Promise<void> | void;
  onRememberScrollState?: (input: {
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
  onUnreadAnchorConsumed?: (messageId: string) => void;
  rememberedScrollState?: SessionScrollState;
  sessionKey?: string;
  sessionStatus?: SessionStatusPayload | null;
  unreadAnchorMessageId?: string | null;
  viewportInsetBottom?: number;
}) {
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { store: transportStore } = useTransportMachine();
  const [expandedMessageId, setExpandedMessageId] = useState<string | null>(null);
  const [isCancelPromptOpen, setCancelPromptOpen] = useState(false);
  const [cancelPromptAnchor, setCancelPromptAnchor] = useState<{
    left: number;
    top: number;
  } | null>(null);
  const statusRunState = sessionStatus?.run?.state ?? "unknown";
  const hasInFlightRun = statusRunState === "running" || statusRunState === "queued";
  const hasAssistantTyping = Boolean(
    sessionKey && chatState.assistantTypingBySessionKey[sessionKey]
  );
  const canCancelCurrentPrompt = Boolean(
    sessionKey &&
    onCancelCurrentPrompt &&
    (sessionStatus?.capabilities?.cancelCurrentRun?.supported ??
      sessionStatus?.capabilities?.canCancelCurrentRun ??
      true) &&
    (hasAssistantTyping || hasInFlightRun)
  );
  const shouldShowTypingIndicator =
    hasAssistantTyping || hasInFlightRun || hasStreamingAssistantMessage(messages);
  const footerHeight = sessionStatus ? SESSION_STATUS_FOOTER_HEIGHT : 0;
  const typingTrailingHeight = shouldShowTypingIndicator
    ? TYPING_INDICATOR_HEIGHT + (messages.length > 0 ? TYPING_INDICATOR_GAP : 0)
    : 0;
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
    suspendBottomFollow,
    trailingRevealAlpha,
    totalHeight
  } = useVirtualMessageWindow(messages, {
    restingTrailingHeight: typingTrailingHeight,
    revealTrailingHeight: footerHeight
  });
  const [isTypingIndicatorVisible, setIsTypingIndicatorVisible] = useState(
    shouldShowTypingIndicator
  );
  const restoredScrollStateKeyRef = useRef<string | null>(null);
  const isRestoringScrollRef = useRef(false);
  const consumedUnreadAnchorRef = useRef<string | null>(null);
  const typingRowRef = useRef<HTMLDivElement | null>(null);
  const userScrollActiveRef = useRef(false);
  const userScrollReleaseTimeoutRef = useRef<number | null>(null);
  const expandedMessage = messages.find((message) => message.id === expandedMessageId) ?? null;
  const typingIndicatorOffsetTop = totalHeight + (messages.length > 0 ? TYPING_INDICATOR_GAP : 0);
  const visibleTypingTrailingHeight = isTypingIndicatorVisible
    ? TYPING_INDICATOR_HEIGHT + (messages.length > 0 ? TYPING_INDICATOR_GAP : 0)
    : 0;
  const footerOffsetTop = totalHeight + visibleTypingTrailingHeight;
  const virtualSurfaceHeight =
    totalHeight + visibleTypingTrailingHeight + footerHeight;

  useEffect(() => {
    return () => {
      if (userScrollReleaseTimeoutRef.current !== null) {
        window.clearTimeout(userScrollReleaseTimeoutRef.current);
      }
    };
  }, []);

  function markUserScrollActive() {
    if (userScrollReleaseTimeoutRef.current !== null) {
      window.clearTimeout(userScrollReleaseTimeoutRef.current);
      userScrollReleaseTimeoutRef.current = null;
    }
    userScrollActiveRef.current = true;
    suspendBottomFollow();
  }

  function releaseUserScrollAfterSettling() {
    if (userScrollReleaseTimeoutRef.current !== null) {
      window.clearTimeout(userScrollReleaseTimeoutRef.current);
    }
    userScrollReleaseTimeoutRef.current = window.setTimeout(() => {
      userScrollActiveRef.current = false;
      userScrollReleaseTimeoutRef.current = null;
    }, 180);
  }

  function openCancelCurrentPrompt() {
    const rect = typingRowRef.current?.getBoundingClientRect();
    setCancelPromptAnchor(
      rect
        ? {
            left: rect.left + 104,
            top: rect.top + 16
          }
        : null
    );
    setCancelPromptOpen(true);
  }

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
    if (!isCancelPromptOpen) {
      return;
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        setCancelPromptOpen(false);
        return;
      }

      if (event.key === "Enter") {
        event.preventDefault();
        event.stopPropagation();
        void confirmCancelCurrentPrompt();
      }
    }

    window.addEventListener("keydown", handleKeyDown, { capture: true });
    return () => window.removeEventListener("keydown", handleKeyDown, { capture: true });
  }, [isCancelPromptOpen]);

  useEffect(() => {
    if (!canCancelCurrentPrompt && isCancelPromptOpen) {
      setCancelPromptOpen(false);
    }
  }, [canCancelCurrentPrompt, isCancelPromptOpen]);

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (!canCancelCurrentPrompt || event.defaultPrevented) {
        return;
      }

      if (event.key !== "." || (!event.metaKey && !event.ctrlKey) || event.altKey) {
        return;
      }

      event.preventDefault();
      openCancelCurrentPrompt();
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [canCancelCurrentPrompt]);

  useLayoutEffect(() => {
    if (!sessionKey || !onRememberScrollState || isRestoringScrollRef.current) {
      return;
    }

    if (!restoredScrollStateKeyRef.current?.startsWith(`${sessionKey}:`)) {
      return;
    }

    onRememberScrollState({
      offsetTop: scrollTop,
      sessionKey,
      stickToBottom: isAtBottom || isAtBottomRef.current
    });
  }, [isAtBottom, isAtBottomRef, onRememberScrollState, scrollTop, sessionKey]);

  useEffect(() => {
    if (!sessionKey) {
      return;
    }

    const restoreKey = `${sessionKey}:${rememberedScrollState?.stickToBottom ? "bottom" : rememberedScrollState ? rememberedScrollState.offsetTop : "none"}`;

    if (restoredScrollStateKeyRef.current === restoreKey) {
      return;
    }

    restoredScrollStateKeyRef.current = restoreKey;
    const activeSessionKey = sessionKey;

    function rememberBottomIfSettled(offsetTop: number) {
      if (isAtBottomRef.current) {
        onRememberScrollState?.({
          offsetTop,
          sessionKey: activeSessionKey,
          stickToBottom: true
        });
      }
    }

    if (rememberedScrollState?.stickToBottom) {
      isRestoringScrollRef.current = true;
      scrollToBottom();
      let frame = 0;
      let remainingFrames = BOTTOM_RESTORE_SETTLE_FRAMES;
      const settleBottom = () => {
        if (userScrollActiveRef.current) {
          isRestoringScrollRef.current = false;
          return;
        }
        scrollToBottom();
        onRememberScrollState?.({
          offsetTop: Number.MAX_SAFE_INTEGER,
          sessionKey: activeSessionKey,
          stickToBottom: true
        });
        remainingFrames -= 1;
        if (remainingFrames > 0) {
          frame = window.requestAnimationFrame(settleBottom);
          return;
        }
        isRestoringScrollRef.current = false;
      };
      frame = window.requestAnimationFrame(settleBottom);
      return () => {
        isRestoringScrollRef.current = false;
        if (frame !== 0) {
          window.cancelAnimationFrame(frame);
        }
      };
    }

    if (rememberedScrollState) {
      scrollToOffset(rememberedScrollState.offsetTop);
      const frame = window.requestAnimationFrame(() => {
        rememberBottomIfSettled(rememberedScrollState.offsetTop);
      });
      return () => window.cancelAnimationFrame(frame);
    }

    scrollToOffset(0);
    const frame = window.requestAnimationFrame(() => {
      rememberBottomIfSettled(0);
    });
    return () => window.cancelAnimationFrame(frame);
  }, [
    isAtBottomRef,
    onRememberScrollState,
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

    const consumeTimer = window.setTimeout(() => {
      if (scrollToMessage(unreadAnchorMessageId, "center")) {
        consumedUnreadAnchorRef.current = unreadAnchorKey;
        onUnreadAnchorConsumed?.(unreadAnchorMessageId);
      }
    }, 0);

    return () => window.clearTimeout(consumeTimer);
  }, [onUnreadAnchorConsumed, scrollToMessage, sessionKey, unreadAnchorMessageId]);

  useEffect(() => {
    if (!sessionKey || !rememberedScrollState?.stickToBottom) {
      return;
    }

    let frame = 0;
    let remainingFrames = BOTTOM_RESTORE_SETTLE_FRAMES;
    const settleBottom = () => {
      if (userScrollActiveRef.current) {
        return;
      }
      scrollToBottom();
      remainingFrames -= 1;
      if (remainingFrames > 0) {
        frame = window.requestAnimationFrame(settleBottom);
      }
    };

    frame = window.requestAnimationFrame(settleBottom);

    return () => {
      if (frame !== 0) {
        window.cancelAnimationFrame(frame);
      }
    };
  }, [rememberedScrollState?.stickToBottom, scrollToBottom, sessionKey, totalHeight]);

  useEffect(() => {
    if (viewportInsetBottom <= 0) {
      return;
    }

    const activeElement = document.activeElement;
    const isComposerFocused =
      activeElement instanceof HTMLTextAreaElement &&
      activeElement.id === "composer-input";

    if (!isComposerFocused || !isAtBottomRef.current || userScrollActiveRef.current) {
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

    if (
      !chatStore.getState().provisionedSessionKeys.includes(pendingMessage.sessionKey)
    ) {
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

  async function confirmCancelCurrentPrompt() {
    if (!sessionKey || !canCancelCurrentPrompt) {
      return;
    }

    setCancelPromptOpen(false);
    await onCancelCurrentPrompt?.(sessionKey);
  }

  if (messages.length === 0 && !isTypingIndicatorVisible) {
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
        onWheel={() => {
          markUserScrollActive();
          releaseUserScrollAfterSettling();
        }}
        onScroll={handleScroll}
        onTouchCancel={() => {
          if (userScrollReleaseTimeoutRef.current !== null) {
            window.clearTimeout(userScrollReleaseTimeoutRef.current);
            userScrollReleaseTimeoutRef.current = null;
          }
          userScrollActiveRef.current = false;
        }}
        onTouchEnd={() => {
          releaseUserScrollAfterSettling();
        }}
        onTouchStart={() => {
          markUserScrollActive();
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
                deviceId={authState.session?.deviceId}
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
              ref={typingRowRef}
              style={{ left: "0px", top: `${typingIndicatorOffsetTop}px` }}
            >
              <TypingIndicator
                canCancel={canCancelCurrentPrompt}
                onClick={openCancelCurrentPrompt}
              />
              {isCancelPromptOpen ? (
                <TypingCancelPrompt
                  anchor={cancelPromptAnchor}
                  onCancelPrompt={() => void confirmCancelCurrentPrompt()}
                  onDismiss={() => setCancelPromptOpen(false)}
                />
              ) : null}
            </div>
          ) : null}
          {sessionStatus ? (
            <div
              className="message-list-row message-list-row--footer"
              style={{ left: "0px", top: `${footerOffsetTop}px`, width: "100%" }}
            >
              <SessionStatusFooter
                onSelect={(selectedSessionKey, action, value, enabled) => {
                  void onSessionControlSelected?.(
                    selectedSessionKey,
                    action,
                    value,
                    enabled
                  );
                }}
                opacity={trailingRevealAlpha}
                sessionStatus={sessionStatus}
              />
            </div>
          ) : null}
        </div>
      </section>
      {!isAtBottom && !isAtBottomRef.current ? (
        <div className="message-list-affordance-bar">
          <button
            className="button-secondary message-list-jump-button"
            data-testid="scroll-to-bottom-button"
            onClick={() => {
              scrollToBottom();
              if (sessionKey && onRememberScrollState) {
                onRememberScrollState({
                  offsetTop: Number.MAX_SAFE_INTEGER,
                  sessionKey,
                  stickToBottom: true
                });
              }
            }}
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

function TypingIndicator({
  canCancel,
  onClick
}: {
  canCancel: boolean;
  onClick: () => void;
}) {
  return (
    <button
      aria-label={
        canCancel
          ? "Assistant is typing. Cancel current prompt"
          : "Assistant is typing"
      }
      className="message-typing-indicator"
      data-testid="typing-indicator"
      disabled={!canCancel}
      onClick={onClick}
      type="button"
    >
      <span className="sr-only">Assistant is typing</span>
      <span aria-hidden="true" className="message-typing-indicator-dots">
        <span className="message-typing-indicator-dot" />
        <span className="message-typing-indicator-dot" />
        <span className="message-typing-indicator-dot" />
      </span>
    </button>
  );
}

function TypingCancelPrompt({
  anchor,
  onCancelPrompt,
  onDismiss
}: {
  anchor: { left: number; top: number } | null;
  onCancelPrompt: () => void;
  onDismiss: () => void;
}) {
  return (
    <>
      <button
        aria-label="Dismiss cancel prompt"
        className="message-typing-cancel-backdrop"
        onClick={onDismiss}
        type="button"
      />
      <div
        aria-label="Cancel current prompt"
        className="message-typing-cancel-popover"
        data-testid="typing-cancel-popover"
        role="dialog"
        style={
          anchor
            ? {
                left: `${anchor.left}px`,
                top: `${anchor.top}px`
              }
            : undefined
        }
      >
        <button
          className="message-typing-cancel-action"
          onClick={onCancelPrompt}
          type="button"
        >
          Cancel
        </button>
      </div>
    </>
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
  deviceId,
  message,
  onExpand,
  onRetry,
  pendingMessage,
  serverUrl,
  transportPhase,
  token
}: {
  deviceId?: string;
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
        deviceId={deviceId}
        messageId={message.id}
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
