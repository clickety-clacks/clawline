import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent
} from "react";
import { RefreshCw, Reply, SendHorizontal, X } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import {
  type CrossChatNotificationBubble,
  useCrossChatNotificationStore
} from "../../runtime/chat/crossChatNotificationStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { generateUuidV4 } from "../../runtime/shared/uuid";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import { getSessionProvisioningState } from "../streams/provisioning";
import { projectComposerSendState } from "./chatSendState";
import { RichMessageBody } from "./RichMessageBody";

const VISIBLE_NOTIFICATION_LIMIT = 10;
const OVERLAY_VERTICAL_MARGIN_PX = 14;
const NOTIFICATION_MAX_BUBBLE_HEIGHT_PX = 320;
const NOTIFICATION_MAX_BUBBLE_VIEWPORT_RATIO = 0.45;
const NOTIFICATION_BUBBLE_GAP_PX = 9;
const COLLAPSE_SWIPE_THRESHOLD_PX = 44;
const CLEAR_ALL_HOLD_DELAY_MS = 650;
const NOTIFICATION_EXIT_ANIMATION_MS = 300;
const COLLAPSED_NOTIFICATION_REVEAL_MS = 5000;
const NOTIFICATION_ACTION_MENU_ITEMS = [
  { key: "go-to-chat", label: "Go to Chat…" },
  { key: "reply", label: "Reply…" },
  { key: "dismiss", label: "Dismiss" }
] as const;
const DEFAULT_NOTIFICATION_ACTION_MENU_INDEX = 0;

interface RenderedNotificationBubble {
  bubble: CrossChatNotificationBubble;
  isExiting: boolean;
}

export function CrossChatNotificationOverlay() {
  const navigate = useNavigate();
  const { state: authState } = useAuthSessionStore();
  const { state: chatState, store: chatStore } = useChatDomainStore();
  const { state: notificationState, store: notificationStore } =
    useCrossChatNotificationStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [replyErrorsBySourceChatId, setReplyErrorsBySourceChatId] = useState<
    Record<string, string>
  >({});
  const [sendingReplySourceChatIds, setSendingReplySourceChatIds] = useState<
    ReadonlySet<string>
  >(() => new Set());
  const [replySourceChatIdByClientMessageId, setReplySourceChatIdByClientMessageId] =
    useState<Record<string, string>>({});
  const [viewportHeight, setViewportHeight] = useState(getViewportHeight);
  const [measuredBubbleHeightsBySourceChatId, setMeasuredBubbleHeightsBySourceChatId] =
    useState<Record<string, number>>({});
  const [isCollapsed, setIsCollapsed] = useState(false);
  const [previewingCollapsedSourceChatIds, setPreviewingCollapsedSourceChatIds] =
    useState<Set<string>>(() => new Set());
  const [renderedBubbles, setRenderedBubbles] = useState<RenderedNotificationBubble[]>(
    []
  );
  const [activeSourceChatId, setActiveSourceChatId] = useState<string | null>(null);
  const [actionMenuSourceChatId, setActionMenuSourceChatId] = useState<string | null>(
    null
  );
  const [actionMenuSelectedIndex, setActionMenuSelectedIndex] = useState(
    DEFAULT_NOTIFICATION_ACTION_MENU_INDEX
  );
  const [replyPinSlotsBySourceChatId, setReplyPinSlotsBySourceChatId] = useState<
    Record<string, number>
  >({});
  const dragStartXRef = useRef<number | null>(null);
  const dragStartYRef = useRef<number | null>(null);
  const suppressNavigationClickRef = useRef(false);
  const clearAllHoldTimerRef = useRef<number | null>(null);
  const collapsedRevealTimersBySourceChatIdRef = useRef<Record<string, number>>({});
  const previousNotificationActivitySignaturesBySourceChatIdRef =
    useRef<Record<string, string> | null>(null);
  const entriesRefsBySourceChatId = useRef<Record<string, HTMLDivElement | null>>({});
  const bubbleRefsBySourceChatId = useRef<Record<string, HTMLElement | null>>({});
  const actionMenuRef = useRef<HTMLDivElement | null>(null);
  const sendingReplySourceChatIdsRef = useRef<Set<string>>(new Set());
  const baseOrderedBubbles = useMemo(
    () =>
      Object.values(notificationState.bubblesBySourceChatId).sort(
        sortBubblesByRecentActivity
      ),
    [notificationState.bubblesBySourceChatId]
  );
  const visibleCapacity = useMemo(
    () =>
      visibleCapacityForViewportHeight(
        viewportHeight,
        baseOrderedBubbles,
        measuredBubbleHeightsBySourceChatId
      ),
    [baseOrderedBubbles, measuredBubbleHeightsBySourceChatId, viewportHeight]
  );
  const orderedBubbles = useMemo(
    () =>
      applyReplyPinsToBubbleOrder(
        baseOrderedBubbles,
        replyPinSlotsBySourceChatId,
        visibleCapacity
      ),
    [baseOrderedBubbles, replyPinSlotsBySourceChatId, visibleCapacity]
  );
  const visibleBubbles = selectVisibleBubblesWithPinnedReplies(
    orderedBubbles,
    visibleCapacity
  );
  const overflowBubbles = orderedBubbles.slice(visibleCapacity);
  const visibleSourceChatIds = visibleBubbles.map((bubble) => bubble.sourceChatId);
  const hasActiveReply = orderedBubbles.some((bubble) => bubble.replyMode);
  const hasCollapsedPreview = previewingCollapsedSourceChatIds.size > 0;
  const notificationActivitySignaturesBySourceChatId = useMemo(
    () =>
      Object.fromEntries(
        orderedBubbles.map((bubble) => [
          bubble.sourceChatId,
          notificationBubbleActivitySignature(bubble)
        ])
      ),
    [orderedBubbles]
  );
  const visibleBubbleSignature = visibleBubbles
    .map((bubble) =>
      [
        notificationBubbleActivitySignature(bubble),
        bubble.replyMode,
        bubble.replyDraft
      ].join(":")
    )
    .join("|");

  useEffect(() => {
    const trackedEntries = Object.entries(replySourceChatIdByClientMessageId);
    if (trackedEntries.length === 0) {
      return;
    }

    for (const [messageId, sourceChatId] of trackedEntries) {
      const messages = chatState.messagesBySessionKey[sourceChatId] ?? [];
      const message = messages.find((candidate) => candidate.id === messageId);
      const isPending = Boolean(chatState.pendingMessages[messageId]);
      if (message?.delivery === "failed") {
        setReplySubmitting(sourceChatId, false);
        setReplySourceChatIdByClientMessageId((current) => {
          const next = { ...current };
          delete next[messageId];
          return next;
        });
        setReplyErrorsBySourceChatId((current) => ({
          ...current,
          [sourceChatId]: "Reply send failed."
        }));
        continue;
      }

      if (message?.delivery === "acked" || (!isPending && !message)) {
        setReplySubmitting(sourceChatId, false);
        dismissNotificationAndMarkSourceRead(sourceChatId);
        setReplySourceChatIdByClientMessageId((current) => {
          const next = { ...current };
          delete next[messageId];
          return next;
        });
      }
    }
  }, [
    chatState.messagesBySessionKey,
    chatState.pendingMessages,
    chatState.provisionedSessionKeys,
    chatStore,
    notificationStore,
    replySourceChatIdByClientMessageId,
    transportStore
  ]);

  useEffect(() => {
    function updateVisibleCapacity() {
      setViewportHeight(getViewportHeight());
    }

    updateVisibleCapacity();
    window.addEventListener("resize", updateVisibleCapacity);
    return () => window.removeEventListener("resize", updateVisibleCapacity);
  }, []);

  useEffect(() => {
    const activeSourceChatIds = new Set(baseOrderedBubbles.map((bubble) => bubble.sourceChatId));
    setMeasuredBubbleHeightsBySourceChatId((current) => {
      const next = Object.fromEntries(
        Object.entries(current).filter(([sourceChatId]) =>
          activeSourceChatIds.has(sourceChatId)
        )
      );
      return shallowNumberRecordEqual(current, next) ? current : next;
    });
  }, [baseOrderedBubbles]);

  useEffect(() => {
    if (typeof ResizeObserver === "undefined") {
      return;
    }

    const observer = new ResizeObserver((entries) => {
      setMeasuredBubbleHeightsBySourceChatId((current) => {
        let changed = false;
        const next = { ...current };
        for (const entry of entries) {
          const sourceChatId = entry.target.getAttribute("data-source-chat-id");
          if (!sourceChatId) {
            continue;
          }
          const height = entry.borderBoxSize[0]?.blockSize ?? entry.contentRect.height;
          if (Math.abs((next[sourceChatId] ?? 0) - height) > 0.5) {
            next[sourceChatId] = height;
            changed = true;
          }
        }
        return changed ? next : current;
      });
    });

    for (const bubble of renderedBubbles) {
      const element = bubbleRefsBySourceChatId.current[bubble.bubble.sourceChatId];
      if (element) {
        observer.observe(element);
      }
    }

    return () => observer.disconnect();
  }, [renderedBubbles]);

  useEffect(() => {
    const visibleSourceChatIdSet = new Set(
      visibleBubbles.map((bubble) => bubble.sourceChatId)
    );
    setRenderedBubbles((current) => {
      const exitingBubbles = current
        .filter((item) => !visibleSourceChatIdSet.has(item.bubble.sourceChatId))
        .map((item) => ({ ...item, isExiting: true }));
      return [
        ...visibleBubbles.map((bubble) => ({
          bubble,
          isExiting: false
        })),
        ...exitingBubbles
      ];
    });
  }, [visibleBubbleSignature]);

  useEffect(() => {
    if (!renderedBubbles.some((item) => item.isExiting)) {
      return;
    }

    const timeoutId = window.setTimeout(() => {
      setRenderedBubbles((current) => current.filter((item) => !item.isExiting));
    }, NOTIFICATION_EXIT_ANIMATION_MS);
    return () => window.clearTimeout(timeoutId);
  }, [renderedBubbles]);

  useEffect(() => {
    return () => {
      clearClearAllHoldTimer();
      clearAllCollapsedRevealPreviews();
    };
  }, []);

  useEffect(() => {
    const previousSignatures =
      previousNotificationActivitySignaturesBySourceChatIdRef.current;
    previousNotificationActivitySignaturesBySourceChatIdRef.current =
      notificationActivitySignaturesBySourceChatId;
    if (previousSignatures !== null && isCollapsed) {
      const changedSourceChatIds = Object.entries(
        notificationActivitySignaturesBySourceChatId
      )
        .filter(
          ([sourceChatId, signature]) => previousSignatures[sourceChatId] !== signature
        )
        .map(([sourceChatId]) => sourceChatId);
      startCollapsedRevealPreview(changedSourceChatIds);
    }
  }, [isCollapsed, notificationActivitySignaturesBySourceChatId]);

  useEffect(() => {
    for (const bubble of overflowBubbles) {
      if (bubble.replyMode || bubble.replyDraft.length > 0) {
        if (bubble.replyMode) {
          continue;
        }
        notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
      }
    }
  }, [notificationStore, overflowBubbles]);

  useEffect(() => {
    setReplyPinSlotsBySourceChatId((current) => {
      const next: Record<string, number> = {};
      let changed = false;
      const maxSlot = Math.max(0, visibleCapacity - 1);
      for (const bubble of baseOrderedBubbles) {
        if (!bubble.replyMode) {
          if (current[bubble.sourceChatId] !== undefined) {
            changed = true;
          }
          continue;
        }
        const existingSlot = current[bubble.sourceChatId];
        const fallbackSlot = Math.min(
          maxSlot,
          Math.max(
            0,
            orderedBubbles.findIndex(
              (orderedBubble) => orderedBubble.sourceChatId === bubble.sourceChatId
            )
          )
        );
        const nextSlot = Math.min(maxSlot, existingSlot ?? fallbackSlot);
        next[bubble.sourceChatId] = nextSlot;
        if (existingSlot !== nextSlot) {
          changed = true;
        }
      }

      for (const sourceChatId of Object.keys(current)) {
        if (next[sourceChatId] === undefined) {
          changed = true;
        }
      }

      return changed ? next : current;
    });
  }, [baseOrderedBubbles, orderedBubbles, visibleCapacity]);

  useEffect(() => {
    if (
      actionMenuSourceChatId &&
      !visibleSourceChatIds.includes(actionMenuSourceChatId)
    ) {
      setActionMenuSourceChatId(null);
    }
  }, [actionMenuSourceChatId, visibleSourceChatIds]);

  useEffect(() => {
    if (actionMenuSourceChatId) {
      actionMenuRef.current?.focus({ preventScroll: true });
    }
  }, [actionMenuSourceChatId]);

  // T307 keyboard ownership: notification command shortcuts are captured at the
  // document boundary before focused text fields; plain composer/reply editing
  // remains owned by those focused controls.
  useEffect(() => {
    function handleKeyDown(event: globalThis.KeyboardEvent) {
      if (event.ctrlKey || !event.metaKey) {
        return;
      }

      const key = shortcutKeyFromEvent(event);
      if (key === "\\" && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        toggleNotificationDock();
        return;
      }

      if ((key === "j" || key === "k") && !event.altKey) {
        const targetSourceChatId =
          activeSourceChatId && visibleSourceChatIds.includes(activeSourceChatId)
            ? activeSourceChatId
            : visibleSourceChatIds[0];
        if (!targetSourceChatId) {
          return;
        }
        event.preventDefault();
        if (hasCollapsedPreview) {
          restoreNotifications();
        }
        scrollNotificationEntries(targetSourceChatId, key === "j" ? "down" : "up");
        return;
      }

      if (key === "-" && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        clearNotificationsAndMarkSourcesRead();
        return;
      }

      const hotkeyIndex = hotkeyIndexFromKey(key);
      if (hotkeyIndex === null) {
        return;
      }

      const sourceChatId = visibleSourceChatIds[hotkeyIndex];
      if (!sourceChatId) {
        return;
      }

      if (event.shiftKey && event.altKey) {
        event.preventDefault();
        setActionMenuSourceChatId(null);
        unpinReplySourceChatId(sourceChatId);
        dismissNotificationAndMarkSourceRead(sourceChatId);
      } else if (event.shiftKey) {
        event.preventDefault();
        setActionMenuSourceChatId(null);
        pinReplySourceChatId(sourceChatId);
        notificationStore.openCrossChatNotificationReply(sourceChatId);
      } else if (!event.altKey) {
        event.preventDefault();
        if (isCollapsed || hasCollapsedPreview) {
          restoreNotifications();
        }
        setActionMenuSelectedIndex(DEFAULT_NOTIFICATION_ACTION_MENU_INDEX);
        setActionMenuSourceChatId(sourceChatId);
      }
    }

    document.addEventListener("keydown", handleKeyDown, { capture: true });
    return () => document.removeEventListener("keydown", handleKeyDown, { capture: true });
  }, [
    activeSourceChatId,
    hasCollapsedPreview,
    hasActiveReply,
    isCollapsed,
    chatState.provisionedSessionKeys,
    chatStore,
    notificationStore,
    orderedBubbles,
    transportStore,
    visibleCapacity,
    visibleSourceChatIds
  ]);

  if (visibleBubbles.length === 0 && renderedBubbles.length === 0) {
    return null;
  }

  function setReplySubmitting(sourceChatId: string, isSubmitting: boolean) {
    const next = new Set(sendingReplySourceChatIdsRef.current);
    if (isSubmitting) {
      next.add(sourceChatId);
    } else {
      next.delete(sourceChatId);
    }
    sendingReplySourceChatIdsRef.current = next;
    setSendingReplySourceChatIds(new Set(next));
  }

  async function sendReply(bubble: CrossChatNotificationBubble) {
    const submitSession = authState.session;
    const content = bubble.replyDraft.trim();
    if (!submitSession || content.length === 0) {
      return;
    }
    const sendState = replySendStateFor(bubble);
    if (
      sendState.sendAction !== "send" ||
      sendingReplySourceChatIdsRef.current.has(bubble.sourceChatId)
    ) {
      return;
    }

    setReplySubmitting(bubble.sourceChatId, true);
    setReplyErrorsBySourceChatId((current) => {
      const next = { ...current };
      delete next[bubble.sourceChatId];
      return next;
    });

    const id = `c_${generateUuidV4()}`;
    setReplySourceChatIdByClientMessageId((current) => ({
      ...current,
      [id]: bubble.sourceChatId
    }));
    chatStore.enqueueOptimisticMessage({
      attachments: [],
      content,
      deviceId: submitSession.deviceId,
      id,
      sessionKey: bubble.sourceChatId,
      timestamp: Date.now(),
      wireAttachments: []
    });

    try {
      await transportStore.sendMessage({
        attachments: [],
        content,
        id,
        sessionKey: bubble.sourceChatId
      });
    } catch {
      chatStore.markMessageFailed(id);
      setReplyErrorsBySourceChatId((current) => ({
        ...current,
        [bubble.sourceChatId]: "Reply send failed."
      }));
      setReplySubmitting(bubble.sourceChatId, false);
      setReplySourceChatIdByClientMessageId((current) => {
        const next = { ...current };
        delete next[id];
        return next;
      });
    }
  }

  function replySendStateFor(bubble: CrossChatNotificationBubble) {
    return projectComposerSendState({
      activeStreamDisplayName: bubble.sourceTitle,
      draft: bubble.replyDraft,
      isSubmitting: sendingReplySourceChatIds.has(bubble.sourceChatId),
      provisioningState: getSessionProvisioningState({
        hasStream: chatState.streams.some(
          (stream) => stream.sessionKey === bubble.sourceChatId
        ),
        provisionedSessionKeys: chatState.provisionedSessionKeys,
        sessionKey: bubble.sourceChatId,
        transportPhase: transportState.phase
      }),
      sessionKey: bubble.sourceChatId,
      stagedAttachmentCount: 0,
      transportPhase: transportState.phase
    });
  }

  function activateReplySendButton(
    bubble: CrossChatNotificationBubble,
    sendAction: "none" | "reconnect" | "send"
  ) {
    if (sendAction === "reconnect") {
      transportStore.retryNow();
      return;
    }
    if (sendAction === "send") {
      void sendReply(bubble);
    }
  }

  function markNotificationSourceRead(sourceChatId: string) {
    const lastReadMessageId = chatStore.markSessionRead(sourceChatId);
    if (
      lastReadMessageId &&
      chatState.provisionedSessionKeys.includes(sourceChatId)
    ) {
      void transportStore.publishReadState(sourceChatId, lastReadMessageId);
    }
  }

  function dismissNotificationAndMarkSourceRead(sourceChatId: string) {
    markNotificationSourceRead(sourceChatId);
    notificationStore.dismissCrossChatNotification(sourceChatId);
  }

  function clearNotificationsAndMarkSourcesRead() {
    for (const bubble of orderedBubbles) {
      markNotificationSourceRead(bubble.sourceChatId);
    }
    notificationStore.clearCrossChatNotifications();
  }

  function clearClearAllHoldTimer() {
    if (clearAllHoldTimerRef.current !== null) {
      window.clearTimeout(clearAllHoldTimerRef.current);
      clearAllHoldTimerRef.current = null;
    }
  }

  function clearCollapsedRevealPreview(sourceChatId: string) {
    const timerId = collapsedRevealTimersBySourceChatIdRef.current[sourceChatId];
    if (timerId !== undefined) {
      window.clearTimeout(timerId);
      delete collapsedRevealTimersBySourceChatIdRef.current[sourceChatId];
    }
    setPreviewingCollapsedSourceChatIds((current) => {
      if (!current.has(sourceChatId)) {
        return current;
      }
      const next = new Set(current);
      next.delete(sourceChatId);
      return next;
    });
  }

  function clearAllCollapsedRevealPreviews() {
    for (const timerId of Object.values(collapsedRevealTimersBySourceChatIdRef.current)) {
      window.clearTimeout(timerId);
    }
    collapsedRevealTimersBySourceChatIdRef.current = {};
    setPreviewingCollapsedSourceChatIds(new Set());
  }

  function startCollapsedRevealPreview(sourceChatIds: readonly string[]) {
    if (!isCollapsed || sourceChatIds.length === 0) {
      return;
    }
    const visibleSourceChatIdSet = new Set(visibleSourceChatIds);
    const previewSourceChatIds = sourceChatIds.filter((sourceChatId) =>
      visibleSourceChatIdSet.has(sourceChatId)
    );
    if (previewSourceChatIds.length === 0) {
      return;
    }
    setPreviewingCollapsedSourceChatIds((current) => {
      const next = new Set(current);
      for (const sourceChatId of previewSourceChatIds) {
        next.add(sourceChatId);
      }
      return next;
    });
    for (const sourceChatId of previewSourceChatIds) {
      const currentTimer = collapsedRevealTimersBySourceChatIdRef.current[sourceChatId];
      if (currentTimer !== undefined) {
        window.clearTimeout(currentTimer);
      }
      collapsedRevealTimersBySourceChatIdRef.current[sourceChatId] =
        window.setTimeout(() => {
          delete collapsedRevealTimersBySourceChatIdRef.current[sourceChatId];
          setPreviewingCollapsedSourceChatIds((current) => {
            if (!current.has(sourceChatId)) {
              return current;
            }
            const next = new Set(current);
            next.delete(sourceChatId);
            return next;
          });
        }, COLLAPSED_NOTIFICATION_REVEAL_MS);
    }
  }

  function confirmClearAllNotifications() {
    clearClearAllHoldTimer();
    if (window.confirm("Clear all notifications?")) {
      clearNotificationsAndMarkSourcesRead();
    }
  }

  function startClearAllHold() {
    clearClearAllHoldTimer();
    clearAllHoldTimerRef.current = window.setTimeout(() => {
      clearAllHoldTimerRef.current = null;
      confirmClearAllNotifications();
    }, CLEAR_ALL_HOLD_DELAY_MS);
  }

  function navigateToSourceChat(sourceChatId: string) {
    if (suppressNavigationClickRef.current) {
      suppressNavigationClickRef.current = false;
      return;
    }
    setActionMenuSourceChatId(null);
    unpinReplySourceChatId(sourceChatId);
    dismissNotificationAndMarkSourceRead(sourceChatId);
    navigate(`/chat/${sourceChatId}`);
  }

  function handleReplyButtonClick(bubble: CrossChatNotificationBubble) {
    setActionMenuSourceChatId(null);
    if (bubble.replyMode) {
      unpinReplySourceChatId(bubble.sourceChatId);
      notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
    } else {
      pinReplySourceChatId(bubble.sourceChatId);
      notificationStore.openCrossChatNotificationReply(bubble.sourceChatId);
    }
  }

  function selectActionMenuItem(sourceChatId: string, index: number) {
    if (index === 0) {
      navigateToSourceChat(sourceChatId);
      return;
    }

    setActionMenuSourceChatId(null);
    if (index === 1) {
      pinReplySourceChatId(sourceChatId);
      notificationStore.openCrossChatNotificationReply(sourceChatId);
    } else {
      unpinReplySourceChatId(sourceChatId);
      dismissNotificationAndMarkSourceRead(sourceChatId);
    }
  }

  function handleActionMenuKeyDown(
    event: KeyboardEvent<HTMLDivElement>,
    sourceChatId: string
  ) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActionMenuSelectedIndex((current) =>
        Math.min(current + 1, NOTIFICATION_ACTION_MENU_ITEMS.length - 1)
      );
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      setActionMenuSelectedIndex((current) => Math.max(current - 1, 0));
      return;
    }

    if (event.key === "Enter") {
      event.preventDefault();
      selectActionMenuItem(sourceChatId, actionMenuSelectedIndex);
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      setActionMenuSourceChatId(null);
    }
  }

  function dockNotifications() {
    if (hasActiveReply) {
      return;
    }
    clearAllCollapsedRevealPreviews();
    setIsCollapsed(true);
  }

  function restoreNotifications() {
    clearAllCollapsedRevealPreviews();
    setIsCollapsed(false);
  }

  function toggleNotificationDock() {
    if (hasActiveReply) {
      if (isCollapsed) {
        restoreNotifications();
      }
      return;
    }
    clearAllCollapsedRevealPreviews();
    setIsCollapsed((current) => !current);
  }

  function pinReplySourceChatId(sourceChatId: string) {
    if (isCollapsed || hasCollapsedPreview) {
      restoreNotifications();
    }
    const currentSlot = visibleSourceChatIds.indexOf(sourceChatId);
    setReplyPinSlotsBySourceChatId((current) => ({
      ...current,
      [sourceChatId]: Math.min(
        Math.max(0, visibleCapacity - 1),
        Math.max(0, currentSlot)
      )
    }));
  }

  function unpinReplySourceChatId(sourceChatId: string) {
    setReplyPinSlotsBySourceChatId((current) => {
      if (current[sourceChatId] === undefined) {
        return current;
      }
      const next = { ...current };
      delete next[sourceChatId];
      return next;
    });
  }

  function scrollNotificationEntries(sourceChatId: string, direction: "down" | "up") {
    const element = entriesRefsBySourceChatId.current[sourceChatId];
    if (!element || element.scrollHeight <= element.clientHeight) {
      return;
    }
    const lineIncrement = 56;
    const targetScrollTop =
      direction === "down"
        ? element.scrollTop + lineIncrement
        : element.scrollTop - lineIncrement;
    element.scrollTo({
      behavior: "smooth",
      top: Math.max(0, Math.min(targetScrollTop, element.scrollHeight - element.clientHeight))
    });
  }

  function handlePointerDown(event: PointerEvent<HTMLElement>) {
    event.currentTarget.setPointerCapture?.(event.pointerId);
    dragStartXRef.current = event.clientX;
    dragStartYRef.current = event.clientY;
  }

  function clearPointerDragState() {
    dragStartXRef.current = null;
    dragStartYRef.current = null;
  }

  function releasePointerCapture(event: PointerEvent<HTMLElement>) {
    if (event.currentTarget.hasPointerCapture?.(event.pointerId)) {
      event.currentTarget.releasePointerCapture?.(event.pointerId);
    }
  }

  function handleBubblePointerUp(
    event: PointerEvent<HTMLElement>,
    sourceChatId: string
  ) {
    releasePointerCapture(event);
    const startX = dragStartXRef.current;
    const startY = dragStartYRef.current;
    clearPointerDragState();
    if (startX === null || startY === null) {
      return;
    }

    const horizontal = event.clientX - startX;
    const vertical = event.clientY - startY;
    if (
      Math.abs(horizontal) <= Math.abs(vertical) ||
      Math.abs(horizontal) < COLLAPSE_SWIPE_THRESHOLD_PX
    ) {
      return;
    }

    suppressNavigationClickRef.current = true;
    window.setTimeout(() => {
      suppressNavigationClickRef.current = false;
    }, 0);
    if (horizontal > 0) {
      if (isCollapsed) {
        clearCollapsedRevealPreview(sourceChatId);
      } else {
        dockNotifications();
      }
    } else {
      setActionMenuSourceChatId(null);
      unpinReplySourceChatId(sourceChatId);
      dismissNotificationAndMarkSourceRead(sourceChatId);
    }
  }

  function handlePeekPointerUp(event: PointerEvent<HTMLElement>) {
    releasePointerCapture(event);
    const startX = dragStartXRef.current;
    const startY = dragStartYRef.current;
    clearPointerDragState();
    if (startX === null || startY === null) {
      return;
    }

    const horizontal = event.clientX - startX;
    const vertical = event.clientY - startY;
    if (
      Math.abs(horizontal) <= Math.abs(vertical) ||
      Math.abs(horizontal) < COLLAPSE_SWIPE_THRESHOLD_PX
    ) {
      return;
    }

    suppressNavigationClickRef.current = true;
    window.setTimeout(() => {
      suppressNavigationClickRef.current = false;
    }, 0);
    if (horizontal < 0) {
      restoreNotifications();
    }
  }

  const actionMenuBubble =
    actionMenuSourceChatId === null
      ? null
      : visibleBubbles.find((bubble) => bubble.sourceChatId === actionMenuSourceChatId) ?? null;
  const actionMenuAssignedNumber = actionMenuBubble
    ? Math.max(0, visibleSourceChatIds.indexOf(actionMenuBubble.sourceChatId))
    : -1;
  return (
    <aside
      aria-label="Cross-chat notifications"
      className={
        isCollapsed
          ? "cross-chat-notification-overlay cross-chat-notification-overlay--collapsed"
          : "cross-chat-notification-overlay"
      }
    >
      {isCollapsed ? (
        <button
          aria-label="Show notifications"
          className="cross-chat-notification-peek"
          onClick={restoreNotifications}
          onPointerCancel={clearPointerDragState}
          onPointerDown={handlePointerDown}
          onPointerUp={handlePeekPointerUp}
          type="button"
        />
      ) : null}
      {renderedBubbles.map(({ bubble, isExiting }) => {
        const isBubbleCollapsed =
          isCollapsed && !previewingCollapsedSourceChatIds.has(bubble.sourceChatId);
        const replySendState = replySendStateFor(bubble);
        const isReplySubmitting = sendingReplySourceChatIds.has(bubble.sourceChatId);
        return (
          <section
            aria-label={`${bubble.sourceTitle} notification`}
            className={[
              "cross-chat-notification-bubble",
              isExiting ? "cross-chat-notification-bubble--exiting" : null,
              isBubbleCollapsed ? "cross-chat-notification-bubble--collapsed" : null,
              bubble.replyMode ? "cross-chat-notification-bubble--replying" : null
            ]
              .filter(Boolean)
              .join(" ")}
            data-testid="cross-chat-notification-bubble"
            data-source-chat-id={bubble.sourceChatId}
            key={bubble.sourceChatId}
            onPointerCancel={clearPointerDragState}
            onPointerDown={handlePointerDown}
            onPointerUp={(event) => handleBubblePointerUp(event, bubble.sourceChatId)}
            onBlur={(event) => {
              const nextFocused = event.relatedTarget;
              if (!(nextFocused instanceof Node) || !event.currentTarget.contains(nextFocused)) {
                setActiveSourceChatId((current) =>
                  current === bubble.sourceChatId ? null : current
                );
              }
            }}
            onFocus={() => setActiveSourceChatId(bubble.sourceChatId)}
            onPointerEnter={() => setActiveSourceChatId(bubble.sourceChatId)}
            onPointerLeave={() =>
              setActiveSourceChatId((current) =>
                current === bubble.sourceChatId ? null : current
              )
            }
            ref={(element) => {
              bubbleRefsBySourceChatId.current[bubble.sourceChatId] = element;
            }}
            tabIndex={0}
          >
          <header
            className="cross-chat-notification-header"
            onClick={() => navigateToSourceChat(bubble.sourceChatId)}
          >
            <div className="cross-chat-notification-title">
              <kbd>⌘{Math.max(0, visibleSourceChatIds.indexOf(bubble.sourceChatId))}</kbd>
              <strong>{bubble.sourceTitle}</strong>
            </div>
            <div className="cross-chat-notification-actions">
              <button
                aria-label={bubble.replyMode ? "Close reply" : "Reply"}
                aria-pressed={bubble.replyMode}
                className={
                  bubble.replyMode
                    ? "cross-chat-notification-icon-button cross-chat-notification-icon-button--active"
                    : "cross-chat-notification-icon-button"
                }
                onClick={(event) => {
                  event.stopPropagation();
                  handleReplyButtonClick(bubble);
                }}
                type="button"
              >
                <Reply aria-hidden="true" size={15} strokeWidth={2.2} />
              </button>
              <button
                aria-label="Dismiss"
                className="cross-chat-notification-icon-button"
                onClick={(event) => {
                  event.stopPropagation();
                  setActionMenuSourceChatId(null);
                  dismissNotificationAndMarkSourceRead(bubble.sourceChatId);
                }}
                onPointerCancel={clearClearAllHoldTimer}
                onPointerDown={(event) => {
                  event.stopPropagation();
                  startClearAllHold();
                }}
                onPointerLeave={clearClearAllHoldTimer}
                onPointerUp={clearClearAllHoldTimer}
                type="button"
              >
                <X aria-hidden="true" size={16} strokeWidth={2.3} />
              </button>
            </div>
          </header>
          {!bubble.replyMode ? (
            <div
              className="cross-chat-notification-entries"
              onClick={() => navigateToSourceChat(bubble.sourceChatId)}
              ref={(element) => {
                entriesRefsBySourceChatId.current[bubble.sourceChatId] = element;
              }}
            >
              {bubble.entriesNewestFirst.map((entry) => (
                <RichMessageBody
                  className="cross-chat-notification-markdown"
                  content={entry.contentPreview.length > 0 ? entry.contentPreview : "Assistant reply"}
                  key={entry.assistantMessageId}
                />
              ))}
            </div>
          ) : null}
          {bubble.replyMode ? (
            <div className="cross-chat-notification-reply">
              <textarea
                aria-label={`Reply to ${bubble.sourceTitle}`}
                onChange={(event) =>
                  notificationStore.setCrossChatNotificationReplyDraft(
                    bubble.sourceChatId,
                    event.target.value
                  )
                }
                onKeyDown={(event: KeyboardEvent<HTMLTextAreaElement>) => {
                  if (event.key === "Escape") {
                    event.preventDefault();
                    notificationStore.closeCrossChatNotificationReply(bubble.sourceChatId);
                    return;
                  }
                  if (event.key === "Enter" && !event.shiftKey) {
                    event.preventDefault();
                    activateReplySendButton(bubble, replySendState.sendAction);
                  }
                }}
                rows={1}
                value={bubble.replyDraft}
              />
              <button
                aria-label={
                  replySendState.sendAction === "send"
                    ? `Send reply to ${bubble.sourceTitle}`
                    : replySendState.sendAriaLabel
                }
                className={[
                  "composer-circle-button",
                  "composer-circle-button--send",
                  `composer-circle-button--${replySendState.connectionState}`,
                  "cross-chat-notification-send"
                ].join(" ")}
                data-connection-state={replySendState.connectionState}
                disabled={!replySendState.isSendButtonEnabled}
                onClick={() => activateReplySendButton(bubble, replySendState.sendAction)}
                type="button"
              >
                {isReplySubmitting ? (
                  <span aria-hidden="true">…</span>
                ) : replySendState.sendAction === "reconnect" ? (
                  <RefreshCw aria-hidden="true" size={15} strokeWidth={2.1} />
                ) : (
                  <SendHorizontal aria-hidden="true" size={15} strokeWidth={2.1} />
                )}
              </button>
              {replyErrorsBySourceChatId[bubble.sourceChatId] ? (
                <p className="field-error">
                  {replyErrorsBySourceChatId[bubble.sourceChatId]}
                </p>
              ) : null}
            </div>
          ) : null}
        </section>
        );
      })}
      {actionMenuBubble ? (
        <div
          className="cross-chat-notification-action-menu-layer"
          style={{ top: `${actionMenuAssignedNumber * 3.25}rem` }}
        >
          <div
            aria-label={`Actions for ${actionMenuBubble.sourceTitle} notification`}
            className="cross-chat-notification-action-menu"
            onClick={(event) => event.stopPropagation()}
            onKeyDown={(event) => handleActionMenuKeyDown(event, actionMenuBubble.sourceChatId)}
            ref={actionMenuRef}
            role="menu"
            tabIndex={-1}
          >
            {NOTIFICATION_ACTION_MENU_ITEMS.map((label, index) => (
              <button
                aria-selected={actionMenuSelectedIndex === index}
                className={
                  actionMenuSelectedIndex === index
                    ? "cross-chat-notification-action-menu-item cross-chat-notification-action-menu-item--active"
                    : "cross-chat-notification-action-menu-item"
                }
                key={label.key}
                onClick={() => selectActionMenuItem(actionMenuBubble.sourceChatId, index)}
                onPointerEnter={() => setActionMenuSelectedIndex(index)}
                role="menuitem"
                type="button"
              >
                <span>{label.label}</span>
                {index > 0 ? (
                  <kbd>
                    {index === 1
                      ? `⇧⌘${actionMenuAssignedNumber}`
                      : `⌥⇧⌘${actionMenuAssignedNumber}`}
                  </kbd>
                ) : null}
              </button>
            ))}
          </div>
        </div>
      ) : null}
    </aside>
  );
}

function getViewportHeight() {
  return typeof window === "undefined" ? 0 : window.innerHeight;
}

function visibleCapacityForViewportHeight(
  viewportHeight: number,
  bubbles: CrossChatNotificationBubble[] = [],
  measuredHeightsBySourceChatId: Record<string, number> = {}
) {
  const availableHeight = Math.max(0, viewportHeight - OVERLAY_VERTICAL_MARGIN_PX * 2);
  if (bubbles.length === 0) {
    return 1;
  }

  let usedHeight = 0;
  let capacity = 0;
  for (const bubble of bubbles.slice(0, VISIBLE_NOTIFICATION_LIMIT)) {
    const measuredHeight = measuredHeightsBySourceChatId[bubble.sourceChatId];
    const nextHeight =
      measuredHeight && measuredHeight > 0
        ? measuredHeight
        : estimatedResolvedBubbleHeight(bubble, viewportHeight);
    const nextUsedHeight =
      usedHeight + nextHeight + (capacity === 0 ? 0 : NOTIFICATION_BUBBLE_GAP_PX);
    if (capacity > 0 && nextUsedHeight > availableHeight) {
      break;
    }
    usedHeight = nextUsedHeight;
    capacity += 1;
  }
  return Math.max(1, Math.min(VISIBLE_NOTIFICATION_LIMIT, capacity));
}

function estimatedResolvedBubbleHeight(
  bubble: CrossChatNotificationBubble,
  viewportHeight: number
) {
  const maxHeight = Math.min(
    NOTIFICATION_MAX_BUBBLE_HEIGHT_PX,
    viewportHeight * NOTIFICATION_MAX_BUBBLE_VIEWPORT_RATIO
  );
  if (bubble.replyMode) {
    return Math.min(maxHeight, 92);
  }
  const text = bubble.entriesNewestFirst
    .map((entry) => entry.contentPreview)
    .join("\n")
    .trim();
  if (text.length === 0) {
    return Math.min(maxHeight, 86);
  }

  const lineCount = text.split(/\n/).reduce((count, line) => {
    return count + Math.max(1, Math.ceil(Math.max(1, line.length) / 48));
  }, 0);
  return Math.min(maxHeight, Math.max(86, 60 + lineCount * 21));
}

function shallowNumberRecordEqual(
  left: Record<string, number>,
  right: Record<string, number>
) {
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);
  if (leftKeys.length !== rightKeys.length) {
    return false;
  }
  return leftKeys.every((key) => left[key] === right[key]);
}

function sortBubblesByRecentActivity(
  left: CrossChatNotificationBubble,
  right: CrossChatNotificationBubble
) {
  if (left.lastAssistantActivityAt !== right.lastAssistantActivityAt) {
    return right.lastAssistantActivityAt - left.lastAssistantActivityAt;
  }
  return left.sourceChatId.localeCompare(right.sourceChatId);
}

function notificationBubbleActivitySignature(bubble: CrossChatNotificationBubble) {
  return [
    bubble.sourceChatId,
    bubble.lastAssistantActivityAt,
    bubble.entriesNewestFirst
      .map((entry) =>
        [
          entry.assistantMessageId,
          entry.updatedAt,
          entry.final,
          entry.contentPreview
        ].join(":")
      )
      .join(",")
  ].join(":");
}

function applyReplyPinsToBubbleOrder(
  bubbles: CrossChatNotificationBubble[],
  replyPinSlotsBySourceChatId: Record<string, number>,
  visibleCapacity: number
) {
  const pinnedBubbles = bubbles
    .filter(
      (bubble) =>
        bubble.replyMode && replyPinSlotsBySourceChatId[bubble.sourceChatId] !== undefined
    )
    .sort((left, right) => {
      const leftSlot = replyPinSlotsBySourceChatId[left.sourceChatId] ?? 0;
      const rightSlot = replyPinSlotsBySourceChatId[right.sourceChatId] ?? 0;
      if (leftSlot !== rightSlot) {
        return leftSlot - rightSlot;
      }
      return sortBubblesByRecentActivity(left, right);
    });
  if (pinnedBubbles.length === 0) {
    return bubbles;
  }

  const pinnedSourceChatIds = new Set(
    pinnedBubbles.map((bubble) => bubble.sourceChatId)
  );
  const unpinnedBubbles = bubbles.filter(
    (bubble) => !pinnedSourceChatIds.has(bubble.sourceChatId)
  );
  const nextOrder: CrossChatNotificationBubble[] = [];
  let unpinnedIndex = 0;

  for (let slot = 0; nextOrder.length < bubbles.length; slot += 1) {
    const pinnedAtSlot = pinnedBubbles.filter(
      (bubble) =>
        Math.min(
          Math.max(0, visibleCapacity - 1),
          replyPinSlotsBySourceChatId[bubble.sourceChatId] ?? 0
        ) === slot
    );
    for (const bubble of pinnedAtSlot) {
      nextOrder.push(bubble);
    }

    if (nextOrder.length >= bubbles.length) {
      break;
    }

    while (
      unpinnedIndex < unpinnedBubbles.length &&
      pinnedAtSlot.length === 0
    ) {
      nextOrder.push(unpinnedBubbles[unpinnedIndex]);
      unpinnedIndex += 1;
      break;
    }

    if (slot >= bubbles.length + pinnedBubbles.length) {
      break;
    }
  }

  while (unpinnedIndex < unpinnedBubbles.length) {
    nextOrder.push(unpinnedBubbles[unpinnedIndex]);
    unpinnedIndex += 1;
  }

  return nextOrder;
}

function selectVisibleBubblesWithPinnedReplies(
  orderedBubbles: CrossChatNotificationBubble[],
  visibleCapacity: number
) {
  const visibleBubbles = orderedBubbles.slice(0, visibleCapacity);
  const visibleSourceChatIds = new Set(
    visibleBubbles.map((bubble) => bubble.sourceChatId)
  );
  const hiddenReplyBubbles = orderedBubbles.filter(
    (bubble) => bubble.replyMode && !visibleSourceChatIds.has(bubble.sourceChatId)
  );
  if (hiddenReplyBubbles.length === 0) {
    return visibleBubbles;
  }

  const nextVisible = [...visibleBubbles];
  for (const replyBubble of hiddenReplyBubbles) {
    while (
      nextVisible.length >= visibleCapacity &&
      nextVisible.some((bubble) => !bubble.replyMode)
    ) {
      let removableIndex = nextVisible.length - 1;
      while (removableIndex >= 0 && nextVisible[removableIndex]?.replyMode) {
        removableIndex -= 1;
      }
      nextVisible.splice(removableIndex, 1);
    }
    nextVisible.push(replyBubble);
  }

  const orderIndexBySourceChatId = new Map(
    orderedBubbles.map((bubble, index) => [bubble.sourceChatId, index])
  );
  return nextVisible.sort(
    (left, right) =>
      (orderIndexBySourceChatId.get(left.sourceChatId) ?? 0) -
      (orderIndexBySourceChatId.get(right.sourceChatId) ?? 0)
  );
}

function hotkeyIndexFromKey(key: string) {
  if (!/^[0-9]$/.test(key)) {
    return null;
  }
  return Number(key);
}

function shortcutKeyFromEvent(event: globalThis.KeyboardEvent) {
  if (/^Digit[0-9]$/.test(event.code)) {
    return event.code.slice("Digit".length);
  }

  if (/^Numpad[0-9]$/.test(event.code)) {
    return event.code.slice("Numpad".length);
  }

  if (event.code === "Minus" || event.code === "NumpadSubtract") {
    return "-";
  }

  return event.key.toLowerCase();
}
