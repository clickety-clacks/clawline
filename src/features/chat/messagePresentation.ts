import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
import { attachmentMimeType } from "../../protocol/attachment-api";

export type MessageSizeClass = "short" | "medium" | "long";
export type MessageChromeKind = "default" | "chromeless-code" | "chromeless-emoji" | "chromeless-image";

export interface MessagePresentation {
  chromeKind: MessageChromeKind;
  isTruncated: boolean;
  isWide: boolean;
  sizeClass: MessageSizeClass;
}

export function getMessageSenderLabel(message: ChatMessageRecord) {
  return message.role === "user" ? "You" : message.sender ?? "Assistant";
}

export function getMessageSenderInitial(message: ChatMessageRecord) {
  const label = getMessageSenderLabel(message).trim();
  const initial = Array.from(label).find((character) => /\p{Letter}|\p{Number}/u.test(character));
  return (initial ?? "?").toUpperCase();
}

export function analyzeMessagePresentation(
  message: ChatMessageRecord,
  shouldOfferExpandedMessage: (content: string) => boolean
): MessagePresentation {
  const normalizedContent = message.content.trim();
  const isTruncated = shouldOfferExpandedMessage(message.content);
  const wordCount = countWords(normalizedContent);
  const hasMarkdownTable = /\n\|(?:\s*:?-+:?\s*\|)+\s*(?:\n|$)/m.test(normalizedContent);
  const hasBlockContent =
    message.attachments.length > 0 ||
    hasMarkdownTable ||
    normalizedContent.includes("```") ||
    normalizedContent.includes("\n\n");
  const hasLinkPreviewCandidate = /https?:\/\/\S+|\[[^\]]+\]\((https?:\/\/[^)]+)\)/.test(
    normalizedContent
  );
  const sizeClass: MessageSizeClass = hasBlockContent
    ? "long"
    : wordCount <= 3
      ? "short"
      : wordCount <= 20
        ? "medium"
        : "long";

  return {
    chromeKind: classifyChromeKind(message, normalizedContent, isTruncated),
    isTruncated,
    isWide: message.attachments.length > 0 || hasMarkdownTable || hasLinkPreviewCandidate,
    sizeClass
  };
}

export function hasStreamingAssistantMessage(messages: ChatMessageRecord[]) {
  const lastAssistantMessage = [...messages].reverse().find((message) => message.role === "assistant");
  return lastAssistantMessage?.streaming === true;
}

function countWords(content: string) {
  return content
    .replace(/```[\s\S]*?```/g, " code ")
    .replace(/\[[^\]]+\]\((https?:\/\/[^)]+)\)/g, " link ")
    .replace(/[|*_`>#-]/g, " ")
    .split(/\s+/)
    .filter(Boolean).length;
}

function classifyChromeKind(
  message: ChatMessageRecord,
  normalizedContent: string,
  isTruncated: boolean
): MessageChromeKind {
  if (isTruncated) {
    return "default";
  }

  if (isSingleImageMessage(message, normalizedContent)) {
    return "chromeless-image";
  }

  if (isSingleCodeBlock(normalizedContent)) {
    return "chromeless-code";
  }

  if (isEmojiOnlyMessage(normalizedContent)) {
    return "chromeless-emoji";
  }

  return "default";
}

function isSingleImageMessage(message: ChatMessageRecord, normalizedContent: string) {
  if (normalizedContent.length > 0 || message.attachments.length !== 1) {
    return false;
  }

  const mimeType = attachmentMimeType(message.attachments[0]) ?? "";
  return mimeType.startsWith("image/");
}

function isSingleCodeBlock(content: string) {
  if (content.length === 0) {
    return false;
  }

  return /^```[\w-]*\n[\s\S]*?\n```$/u.test(content);
}

function isEmojiOnlyMessage(content: string) {
  if (content.length === 0) {
    return false;
  }

  const normalized = content.replace(/\uFE0F/g, "");
  const clusters = segmentText(normalized);

  if (clusters.length === 0 || clusters.length > 2) {
    return false;
  }

  return clusters.every((cluster) => /^\p{Extended_Pictographic}(?:\u200D\p{Extended_Pictographic})*$/u.test(cluster));
}

function segmentText(content: string) {
  if (typeof Intl !== "undefined" && "Segmenter" in Intl) {
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    return Array.from(segmenter.segment(content), (entry) => entry.segment)
      .map((segment) => segment.trim())
      .filter(Boolean);
  }

  return Array.from(content.trim()).filter((segment) => segment.trim().length > 0);
}
