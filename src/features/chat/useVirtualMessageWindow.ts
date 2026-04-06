import { useEffect, useMemo, useRef, useState, type RefObject } from "react";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
import { analyzeMessagePresentation, getMessageSenderLabel } from "./messagePresentation";
import { shouldOfferExpandedMessage } from "./RichMessageBody";

const BOTTOM_THRESHOLD_PX = 32;
const DEFAULT_CONTAINER_WIDTH = 820;
const DEFAULT_MESSAGE_HEIGHT = 96;
const DEFAULT_VIEWPORT_HEIGHT = 720;
const OVERSCAN_PX = 1_000;
const BUBBLE_MIN_WIDTH = 120;
const BUBBLE_PADDING_HORIZONTAL = 40;
const BUBBLE_HEADER_AVATAR_WIDTH = 32;
const BUBBLE_HEADER_GAP = 10;
const BUBBLE_HEADER_TIMESTAMP_GAP = 12;
const MAX_LINE_WIDTH_PX = 560;
const MEDIUM_WIDTH_SAFETY_MARGIN_PX = 24;
const PHONE_MEDIUM_WIDTH_SAFETY_MARGIN_PX = 8;
const TIMESTAMP_WIDTH_SAMPLE = "Yesterday, 12:00 PM";
let textMeasureCanvas: HTMLCanvasElement | null = null;
const textMeasureCache = new Map<string, number>();
const bubbleWidthCache = new Map<string, number>();

export interface VirtualMessageWindow {
  containerRef: RefObject<HTMLElement | null>;
  isAtBottom: boolean;
  isAtBottomRef: RefObject<boolean>;
  handleScroll: () => void;
  registerMessageSize: (messageId: string, size: { height: number; width: number }) => void;
  renderedMessages: Array<{
    message: ChatMessageRecord;
    offsetLeft: number;
    offsetTop: number;
    width: number;
  }>;
  scrollTop: number;
  scrollToBottom: () => void;
  scrollToMessage: (messageId: string, alignment?: "center" | "start") => boolean;
  scrollToOffset: (offsetTop: number) => void;
  totalHeight: number;
}

export function useVirtualMessageWindow(messages: ChatMessageRecord[]): VirtualMessageWindow {
  const containerRef = useRef<HTMLElement | null>(null);
  const shouldStickToBottomRef = useRef(false);
  const isAtBottomRef = useRef(true);
  const [scrollTop, setScrollTop] = useState(0);
  const [containerWidth, setContainerWidth] = useState(DEFAULT_CONTAINER_WIDTH);
  const [viewportHeight, setViewportHeight] = useState(DEFAULT_VIEWPORT_HEIGHT);
  const [measuredSizes, setMeasuredSizes] = useState<Record<string, { height: number; width: number }>>({});

  useEffect(() => {
    const container = containerRef.current;
    if (!container) {
      return;
    }
    const target = container;

    function syncContainerMetrics(target: HTMLElement) {
      const computedStyle = window.getComputedStyle(target);
      const paddingInline =
        Number.parseFloat(computedStyle.paddingLeft || "0")
        + Number.parseFloat(computedStyle.paddingRight || "0");
      const contentWidth = Math.max(0, target.clientWidth - paddingInline);

      setContainerWidth(contentWidth || DEFAULT_CONTAINER_WIDTH);
      setViewportHeight(target.clientHeight || DEFAULT_VIEWPORT_HEIGHT);
    }

    syncContainerMetrics(target);

    const resizeObserver =
      typeof window.ResizeObserver === "function"
        ? new window.ResizeObserver(() => {
            syncContainerMetrics(target);
          })
        : null;

    resizeObserver?.observe(target);
    function handleWindowResize() {
      syncContainerMetrics(target);
    }

    window.addEventListener("resize", handleWindowResize);

    return () => {
      resizeObserver?.disconnect();
      window.removeEventListener("resize", handleWindowResize);
    };
  }, []);

  const gapPx = containerWidth <= 500 ? 12 : 16;
  const layout = useMemo(
    () =>
      buildVirtualLayout(messages, measuredSizes, scrollTop, viewportHeight, containerWidth, gapPx),
    [containerWidth, gapPx, measuredSizes, messages, scrollTop, viewportHeight]
  );

  function handleScroll() {
    if (!containerRef.current) {
      return;
    }

    const nextScrollTop = containerRef.current.scrollTop;
    const maxScrollTop = Math.max(
      0,
      containerRef.current.scrollHeight - containerRef.current.clientHeight
    );
    isAtBottomRef.current = maxScrollTop - nextScrollTop <= BOTTOM_THRESHOLD_PX;
    shouldStickToBottomRef.current = isAtBottomRef.current;
    setScrollTop(nextScrollTop);
  }

  useEffect(() => {
    const container = containerRef.current;
    if (!container || !shouldStickToBottomRef.current) {
      return;
    }

    container.scrollTop = container.scrollHeight;
    setScrollTop(container.scrollTop);
  }, [layout.totalHeight]);

  return {
    containerRef,
    handleScroll,
    isAtBottom:
      Math.max(0, layout.totalHeight - viewportHeight - scrollTop) <= BOTTOM_THRESHOLD_PX,
    isAtBottomRef,
    registerMessageSize(messageId, size) {
      if (size.height <= 0 || size.width <= 0) {
        return;
      }

      setMeasuredSizes((current) =>
        current[messageId]?.height === size.height && current[messageId]?.width === size.width
          ? current
          : {
              ...current,
              [messageId]: size
            }
      );
    },
    renderedMessages: layout.renderedMessages,
    scrollTop,
    scrollToBottom() {
      const container = containerRef.current;
      if (!container) {
        return;
      }

      shouldStickToBottomRef.current = true;
      container.scrollTop = container.scrollHeight;
      isAtBottomRef.current = true;
      setScrollTop(container.scrollTop);
    },
    scrollToMessage(messageId, alignment = "start") {
      const container = containerRef.current;
      const messageLayout = layout.messageLayouts.find(
        (entry) => entry.message.id === messageId
      );

      if (!container || !messageLayout) {
        return false;
      }

      const nextOffset =
        alignment === "center"
          ? Math.max(
              0,
              messageLayout.offsetTop - (container.clientHeight - messageLayout.height) / 2
            )
          : messageLayout.offsetTop;

      shouldStickToBottomRef.current = false;
      container.scrollTop = nextOffset;
      isAtBottomRef.current = false;
      setScrollTop(container.scrollTop);
      return true;
    },
    scrollToOffset(offsetTop) {
      const container = containerRef.current;
      if (!container) {
        return;
      }

      shouldStickToBottomRef.current = false;
      container.scrollTop = Math.max(0, offsetTop);
      isAtBottomRef.current = false;
      setScrollTop(container.scrollTop);
    },
    totalHeight: layout.totalHeight
  };
}

function buildVirtualLayout(
  messages: ChatMessageRecord[],
  measuredSizes: Record<string, { height: number; width: number }>,
  scrollTop: number,
  viewportHeight: number,
  containerWidth: number,
  gapPx: number
) {
  const availableWidth = Math.max(BUBBLE_MIN_WIDTH, containerWidth);
  let offsetTop = 0;
  let offsetLeft = 0;
  let currentRowHeight = 0;
  const messageLayouts = messages.map((message, index) => {
    const measuredSize = measuredSizes[message.id];
    const presentation = analyzeMessagePresentation(message, shouldOfferExpandedMessage);
    const width =
      measuredSize?.width ??
      estimateBubbleWidth(message, presentation, availableWidth);
    const height = measuredSize?.height ?? DEFAULT_MESSAGE_HEIGHT;
    const shouldForceOwnRow =
      presentation.isWide
      || presentation.isTruncated
      || presentation.sizeClass === "long";

    if (shouldForceOwnRow && offsetLeft > 0) {
      offsetTop += currentRowHeight + gapPx;
      offsetLeft = 0;
      currentRowHeight = 0;
    }

    const clampedWidth = Math.max(BUBBLE_MIN_WIDTH, Math.min(width, availableWidth));
    if (!shouldForceOwnRow && offsetLeft > 0 && offsetLeft + clampedWidth > availableWidth) {
      offsetTop += currentRowHeight + gapPx;
      offsetLeft = 0;
      currentRowHeight = 0;
    }

    const messageOffsetLeft =
      message.role === "user" && shouldForceOwnRow
        ? Math.max(0, availableWidth - clampedWidth)
        : offsetLeft;

    const layout = {
      height,
      message,
      offsetLeft: messageOffsetLeft,
      offsetTop,
      width: clampedWidth
    };

    if (shouldForceOwnRow) {
      offsetTop += height + (index < messages.length - 1 ? gapPx : 0);
      offsetLeft = 0;
      currentRowHeight = 0;
      return layout;
    }

    offsetLeft = messageOffsetLeft + clampedWidth + gapPx;
    currentRowHeight = Math.max(currentRowHeight, height);
    return layout;
  });

  const totalHeight =
    currentRowHeight > 0
      ? offsetTop + currentRowHeight
      : offsetTop;
  const clampedScrollTop = Math.min(scrollTop, Math.max(0, totalHeight - viewportHeight));
  const visibleTop = Math.max(0, clampedScrollTop - OVERSCAN_PX);
  const visibleBottom = clampedScrollTop + viewportHeight + OVERSCAN_PX;
  const renderedMessages: Array<{
    message: ChatMessageRecord;
    offsetLeft: number;
    offsetTop: number;
    width: number;
  }> = [];

  for (const layout of messageLayouts) {
    const messageBottom = layout.offsetTop + layout.height;

    if (messageBottom >= visibleTop && layout.offsetTop <= visibleBottom) {
      renderedMessages.push({
        message: layout.message,
        offsetLeft: layout.offsetLeft,
        offsetTop: layout.offsetTop,
        width: layout.width
      });
    }
  }

  return {
    messageLayouts,
    renderedMessages,
    totalHeight
  };
}

function estimateBubbleWidth(
  message: ChatMessageRecord,
  presentation: ReturnType<typeof analyzeMessagePresentation>,
  containerWidth: number
) {
  const cacheKey = [
    message.id,
    message.content,
    presentation.sizeClass,
    presentation.isWide ? "wide" : "plain",
    presentation.isTruncated ? "truncated" : "full",
    containerWidth
  ].join(":");
  const cachedWidth = bubbleWidthCache.get(cacheKey);
  if (cachedWidth !== undefined) {
    return cachedWidth;
  }

  const maxAllowedWidth = Math.min(containerWidth, MAX_LINE_WIDTH_PX + BUBBLE_PADDING_HORIZONTAL);
  const minimumChromeWidth = Math.min(
    maxAllowedWidth,
    Math.max(BUBBLE_MIN_WIDTH, estimateBubbleChromeWidth(message))
  );
  let width: number;

  if (presentation.isWide || presentation.isTruncated) {
    width = containerWidth;
  } else if (presentation.sizeClass === "long") {
    width = maxAllowedWidth;
  } else if (presentation.sizeClass === "short") {
    width = clamp(
      minimumChromeWidth,
      measureSingleLineWidth(message.content, 22, 600) + BUBBLE_PADDING_HORIZONTAL,
      maxAllowedWidth
    );
  } else {
    width = estimateMediumWidth(message.content, containerWidth, maxAllowedWidth, minimumChromeWidth);
  }

  bubbleWidthCache.set(cacheKey, width);
  return width;
}

function estimateMediumWidth(
  content: string,
  containerWidth: number,
  maxAllowedWidth: number,
  minimumChromeWidth: number
) {
  const minWidth = Math.min(
    maxAllowedWidth,
    Math.max(Math.floor(containerWidth / 4), minimumChromeWidth)
  );

  if (containerWidth <= 500) {
    const phoneMaxWidth = clamp(minWidth, Math.floor(containerWidth * 0.67), maxAllowedWidth);

    for (const targetLines of [3, 2, 1]) {
      const bestWidth = findMinimumWidthForLines(content, targetLines, minWidth, phoneMaxWidth);
      if (bestWidth !== null && bestWidth >= minWidth) {
        return clamp(
          minWidth,
          bestWidth + PHONE_MEDIUM_WIDTH_SAFETY_MARGIN_PX,
          phoneMaxWidth
        );
      }
    }

    return maxAllowedWidth;
  }

  for (const targetLines of [3, 2, 1]) {
    const bestWidth = findMinimumWidthForLines(content, targetLines, minWidth, maxAllowedWidth);
    if (bestWidth !== null && bestWidth >= minWidth) {
      return clamp(
        minWidth,
        bestWidth + MEDIUM_WIDTH_SAFETY_MARGIN_PX,
        maxAllowedWidth
      );
    }
  }

  return maxAllowedWidth;
}

function findMinimumWidthForLines(
  content: string,
  targetLines: number,
  minWidth: number,
  maxWidth: number
) {
  if (estimateLineCount(content, 17, 500, maxWidth) > targetLines) {
    return null;
  }

  let low = minWidth;
  let high = maxWidth;
  let bestWidth = maxWidth;

  while (high - low > 4) {
    const mid = Math.floor((low + high) / 2);
    if (estimateLineCount(content, 17, 500, mid) <= targetLines) {
      bestWidth = mid;
      high = mid;
    } else {
      low = mid;
    }
  }

  return bestWidth;
}

function estimateLineCount(
  content: string,
  fontSizePx: number,
  fontWeight: number,
  bubbleWidth: number
) {
  const availableTextWidth = Math.max(1, bubbleWidth - BUBBLE_PADDING_HORIZONTAL);
  const words = normalizeForMeasurement(content).split(/\s+/).filter(Boolean);

  if (words.length === 0) {
    return 1;
  }

  const spaceWidth = measureSingleLineWidth(" ", fontSizePx, fontWeight);
  let lines = 1;
  let lineWidth = 0;

  for (const word of words) {
    const wordWidth = measureSingleLineWidth(word, fontSizePx, fontWeight);

    if (lineWidth === 0) {
      lineWidth = wordWidth;
      continue;
    }

    if (lineWidth + spaceWidth + wordWidth <= availableTextWidth) {
      lineWidth += spaceWidth + wordWidth;
      continue;
    }

    lines += 1;
    lineWidth = wordWidth;
  }

  return lines;
}

function measureSingleLineWidth(content: string, fontSizePx: number, fontWeight: number) {
  const measurementKey = `${fontWeight}:${fontSizePx}:${content}`;
  const cachedWidth = textMeasureCache.get(measurementKey);
  if (cachedWidth !== undefined) {
    return cachedWidth;
  }

  const isJsdom =
    typeof navigator !== "undefined" && /jsdom/i.test(navigator.userAgent);

  if (typeof document === "undefined" || isJsdom) {
    const width = fallbackTextWidth(content, fontSizePx);
    textMeasureCache.set(measurementKey, width);
    return width;
  }

  textMeasureCanvas ??= document.createElement("canvas");
  const context = textMeasureCanvas.getContext("2d");
  if (!context) {
    const width = fallbackTextWidth(content, fontSizePx);
    textMeasureCache.set(measurementKey, width);
    return width;
  }

  context.font = `${fontWeight} ${fontSizePx}px "DM Sans", system-ui, sans-serif`;
  const width = Math.ceil(context.measureText(normalizeForMeasurement(content)).width);
  textMeasureCache.set(measurementKey, width);
  return width;
}

function fallbackTextWidth(content: string, fontSizePx: number) {
  return normalizeForMeasurement(content).length * fontSizePx * 0.58;
}

function normalizeForMeasurement(content: string) {
  return content
    .replace(/```[\s\S]*?```/g, " code ")
    .replace(/\[[^\]]+\]\((https?:\/\/[^)]+)\)/g, " link ")
    .replace(/\s+/g, " ")
    .trim();
}

function estimateBubbleChromeWidth(message: ChatMessageRecord) {
  const senderWidth = measureSingleLineWidth(getMessageSenderLabel(message), 12, 600);
  const timestampWidth = measureSingleLineWidth(TIMESTAMP_WIDTH_SAMPLE, 11, 400);

  return Math.ceil(
    BUBBLE_PADDING_HORIZONTAL
    + BUBBLE_HEADER_AVATAR_WIDTH
    + BUBBLE_HEADER_GAP
    + senderWidth
    + BUBBLE_HEADER_TIMESTAMP_GAP
    + timestampWidth
  );
}

function clamp(min: number, value: number, max: number) {
  return Math.max(min, Math.min(max, value));
}
