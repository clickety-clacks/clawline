import {
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type KeyboardEvent,
  type PointerEvent
} from "react";
import { Plus, RefreshCw, SendHorizontal, X } from "lucide-react";
import type { SessionProvisioningState } from "../streams/provisioning";
import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { useChatDomainStore } from "../../runtime/chat/chatDomainStore";
import { generateUuidV4 } from "../../runtime/shared/uuid";
import { useTransportMachine } from "../../runtime/transport/transportMachine";
import {
  isUploadAuthFailure
} from "../../protocol/upload-api";
import { prepareOutboundAttachments } from "./outboundAttachments";
import { projectComposerSendState } from "./chatSendState";

interface ComposerAttachmentDraft {
  file: File;
  id: string;
}

export function Composer({
  activeStreamDisplayName,
  provisioningState,
  sessionKey,
  streams = []
}: {
  activeStreamDisplayName?: string;
  provisioningState: SessionProvisioningState;
  sessionKey?: string;
  streams?: StreamRecord[];
}) {
  const { state: authState, store: authStore } = useAuthSessionStore();
  const { store: chatStore } = useChatDomainStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [draft, setDraft] = useState("");
  const [isDragActive, setDragActive] = useState(false);
  const [isSubmitting, setSubmitting] = useState(false);
  const [stagedAttachments, setStagedAttachments] = useState<ComposerAttachmentDraft[]>([]);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [sentToastMessage, setSentToastMessage] = useState<string | null>(null);
  const [resolvedMention, setResolvedMention] = useState<{
    destinationChatId: string;
    displayTitle: string;
  } | null>(null);
  const [highlightedMentionIndex, setHighlightedMentionIndex] = useState(0);
  const fileInputId = useId();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const sentToastTimeoutRef = useRef<number | null>(null);
  const sendClickSuppressionTimeoutRef = useRef<number | null>(null);
  const suppressNextSendClickRef = useRef(false);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const leadingMentionQuery =
    !resolvedMention && draft.startsWith("@") ? draft.slice(1) : null;
  const mentionPickerVisible = leadingMentionQuery !== null;
  const eligibleMentionStreams = useMemo(
    () => streams.filter((stream) => stream.sessionKey !== sessionKey),
    [sessionKey, streams]
  );
  const filteredMentionStreams = useMemo(() => {
    if (leadingMentionQuery === null) {
      return [];
    }

    const normalizedQuery = leadingMentionQuery.trim().toLowerCase();
    if (normalizedQuery.length === 0) {
      return eligibleMentionStreams;
    }

    return eligibleMentionStreams.filter((stream) => {
      return (
        stream.displayName.toLowerCase().includes(normalizedQuery) ||
        stream.sessionKey.toLowerCase().includes(normalizedQuery)
      );
    });
  }, [eligibleMentionStreams, leadingMentionQuery]);
  const highlightedMentionStream =
    filteredMentionStreams[
      Math.min(highlightedMentionIndex, filteredMentionStreams.length - 1)
    ];

  const sendState = projectComposerSendState({
    activeStreamDisplayName,
    draft,
    isSubmitting,
    provisioningState,
    sessionKey,
    stagedAttachmentCount: stagedAttachments.length,
    transportPhase: transportState.phase
  });
  const latestSubmitStateRef = useRef({
    authToken: authState.session?.token,
    provisioningState,
    sessionKey,
    transportPhase: transportState.phase
  });
  latestSubmitStateRef.current = {
    authToken: authState.session?.token,
    provisioningState,
    sessionKey,
    transportPhase: transportState.phase
  };

  useEffect(() => {
    return () => {
      if (sendClickSuppressionTimeoutRef.current != null) {
        window.clearTimeout(sendClickSuppressionTimeoutRef.current);
      }
    };
  }, []);

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) {
      return;
    }

    textarea.style.height = "0px";
    const nextHeight = Math.min(Math.max(textarea.scrollHeight, 28), 140);
    textarea.style.height = `${nextHeight}px`;
  }, [draft]);

  useEffect(() => {
    setHighlightedMentionIndex(0);
  }, [leadingMentionQuery]);

  useEffect(() => {
    if (highlightedMentionIndex < filteredMentionStreams.length) {
      return;
    }
    setHighlightedMentionIndex(Math.max(0, filteredMentionStreams.length - 1));
  }, [filteredMentionStreams.length, highlightedMentionIndex]);

  useEffect(() => {
    return () => {
      if (sentToastTimeoutRef.current != null) {
        window.clearTimeout(sentToastTimeoutRef.current);
      }
    };
  }, []);

  function showSentToast(displayTitle: string) {
    setSentToastMessage(`Sent to ${displayTitle}`);
    if (sentToastTimeoutRef.current != null) {
      window.clearTimeout(sentToastTimeoutRef.current);
    }
    sentToastTimeoutRef.current = window.setTimeout(() => {
      setSentToastMessage(null);
      sentToastTimeoutRef.current = null;
    }, 2500);
  }

  async function submit() {
    const submitSession = authState.session;
    if (!sessionKey || !submitSession) {
      return;
    }

    if (sendState.sendAction !== "send") {
      return;
    }

    const isCrossChatSend = resolvedMention !== null;
    const destinationSessionKey = resolvedMention?.destinationChatId ?? sessionKey;
    const crossChatSentToastTitle = resolvedMention?.displayTitle;
    if (!destinationSessionKey) {
      return;
    }

    if (
      resolvedMention &&
      !streams.some((stream) => stream.sessionKey === resolvedMention.destinationChatId)
    ) {
      setSubmitError("Message send failed.");
      return;
    }

    const content = draft.trim();
    if (content.length === 0 && stagedAttachments.length === 0) {
      return;
    }

    setSubmitting(true);
    setSubmitError(null);

    let preparedAttachments;
    try {
      preparedAttachments = await prepareOutboundAttachments({
        content,
        files: stagedAttachments.map((attachment) => attachment.file),
        serverUrl: submitSession.serverUrl,
        token: submitSession.token
      });
    } catch (error) {
      if (isUploadAuthFailure(error)) {
        setSubmitting(false);
        authStore.logout();
        return;
      }
      setSubmitError(
        error instanceof Error ? error.message : "Attachment upload failed."
      );
      setSubmitting(false);
      return;
    }

    const latestSubmitState = latestSubmitStateRef.current;
    if (
      latestSubmitState.sessionKey !== sessionKey ||
      latestSubmitState.provisioningState !== "ready" ||
      latestSubmitState.transportPhase !== "live" ||
      latestSubmitState.authToken !== submitSession.token
    ) {
      setSubmitting(false);
      return;
    }

    const id = `c_${generateUuidV4()}`;
    const timestamp = Date.now();

    chatStore.enqueueOptimisticMessage({
      attachments: preparedAttachments.optimisticAttachments,
      content,
      deviceId: submitSession.deviceId,
      id,
      sessionKey: destinationSessionKey,
      timestamp,
      wireAttachments: preparedAttachments.wireAttachments
    });

    setDraft("");
    setResolvedMention(null);
    setStagedAttachments([]);
    if (fileInputRef.current) {
      fileInputRef.current.value = "";
    }
    window.requestAnimationFrame(() => {
      textareaRef.current?.focus({ preventScroll: true });
    });

    try {
      await transportStore.sendMessage({
        attachments: preparedAttachments.wireAttachments,
        content,
        id,
        sessionKey: destinationSessionKey
      });
      if (isCrossChatSend && crossChatSentToastTitle) {
        showSentToast(crossChatSentToastTitle);
      }
    } catch {
      chatStore.markMessageFailed(id);
      if (isCrossChatSend) {
        setSubmitError("Message send failed.");
      }
    } finally {
      setSubmitting(false);
    }
  }

  function appendFiles(files: readonly File[]) {
    if (files.length === 0) {
      return;
    }

    setSubmitError(null);
    setStagedAttachments((current) => [
      ...current,
      ...files.map((file) => ({
        file,
        id: generateUuidV4()
      }))
    ]);
  }

  function removeAttachment(attachmentId: string) {
    setStagedAttachments((current) =>
      current.filter((attachment) => attachment.id !== attachmentId)
    );
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void submit();
  }

  function resolveHighlightedMention() {
    if (!highlightedMentionStream) {
      return;
    }

    setResolvedMention({
      destinationChatId: highlightedMentionStream.sessionKey,
      displayTitle: highlightedMentionStream.displayName
    });
    setDraft("");
    window.requestAnimationFrame(() => {
      textareaRef.current?.focus({ preventScroll: true });
    });
  }

  function handleComposerKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (mentionPickerVisible) {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        if (filteredMentionStreams.length > 0) {
          setHighlightedMentionIndex((current) =>
            Math.min(current + 1, filteredMentionStreams.length - 1)
          );
        }
        return;
      }

      if (event.key === "ArrowUp") {
        event.preventDefault();
        if (filteredMentionStreams.length > 0) {
          setHighlightedMentionIndex((current) => Math.max(current - 1, 0));
        }
        return;
      }

      if (event.key === "Tab") {
        event.preventDefault();
        resolveHighlightedMention();
        return;
      }

      if (event.key === "Enter" && highlightedMentionStream) {
        event.preventDefault();
        resolveHighlightedMention();
        return;
      }
    }

    if (
      resolvedMention &&
      event.key === "Backspace" &&
      draft.length === 0 &&
      event.currentTarget.selectionStart === 0 &&
      event.currentTarget.selectionEnd === 0
    ) {
      event.preventDefault();
      setResolvedMention(null);
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      event.currentTarget.blur();
      return;
    }

    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void submit();
    }
  }

  function activateSendButton() {
    if (sendState.sendAction === "reconnect") {
      transportStore.retryNow();
      return;
    }

    if (sendState.sendAction === "send") {
      void submit();
    }
  }

  function handleSendButtonPointerDown(event: PointerEvent<HTMLButtonElement>) {
    if (event.button !== 0 || !sendState.isSendButtonEnabled) {
      return;
    }

    event.preventDefault();
    suppressNextSendClickRef.current = true;
    if (sendClickSuppressionTimeoutRef.current != null) {
      window.clearTimeout(sendClickSuppressionTimeoutRef.current);
    }
    sendClickSuppressionTimeoutRef.current = window.setTimeout(() => {
      suppressNextSendClickRef.current = false;
      sendClickSuppressionTimeoutRef.current = null;
    }, 0);
    activateSendButton();
  }

  function handleSendButtonClick() {
    if (suppressNextSendClickRef.current) {
      suppressNextSendClickRef.current = false;
      if (sendClickSuppressionTimeoutRef.current != null) {
        window.clearTimeout(sendClickSuppressionTimeoutRef.current);
        sendClickSuppressionTimeoutRef.current = null;
      }
      return;
    }

    activateSendButton();
  }

  return (
    <section
      className={
        isDragActive ? "composer-shell composer-shell--drag-active" : "composer-shell"
      }
      data-testid="composer-shell"
      onDragEnter={(event) => {
        if (event.dataTransfer?.files.length) {
          event.preventDefault();
          setDragActive(true);
        }
      }}
      onDragLeave={(event) => {
        if (event.currentTarget === event.target) {
          setDragActive(false);
        }
      }}
      onDragOver={(event) => {
        if (event.dataTransfer?.files.length) {
          event.preventDefault();
        }
      }}
      onDrop={(event) => {
        event.preventDefault();
        setDragActive(false);
        appendFiles(Array.from(event.dataTransfer?.files ?? []));
      }}
      >
      <input
        aria-hidden="true"
        className="sr-only"
        id={fileInputId}
        multiple
        onChange={(event) => appendFiles(Array.from(event.target.files ?? []))}
        ref={fileInputRef}
        tabIndex={-1}
        type="file"
      />
      <label className="sr-only" htmlFor="composer-input">
        Message
      </label>
      {stagedAttachments.length > 0 ? (
        <div className="composer-attachments" data-testid="composer-attachments">
          {stagedAttachments.map((attachment) => (
            <div className="composer-attachment-chip" key={attachment.id}>
              <div className="composer-attachment-copy">
                <strong>{attachment.file.name || "attachment"}</strong>
                <span>{formatAttachmentSize(attachment.file.size)}</span>
              </div>
              <button
                className="button-secondary"
                onClick={() => removeAttachment(attachment.id)}
                type="button"
              >
                Remove
              </button>
            </div>
          ))}
        </div>
      ) : null}
      {submitError ? <p className="field-error">{submitError}</p> : null}
      {sentToastMessage ? (
        <div className="composer-sent-toast" role="status">
          {sentToastMessage}
        </div>
      ) : null}
      <form
        className="composer-input-bar"
        data-testid="composer-input-bar"
        onSubmit={handleSubmit}
      >
        <button
          aria-label="Add attachment"
          className="composer-circle-button composer-circle-button--attach"
          disabled={!sendState.canAttach}
          onClick={() => fileInputRef.current?.click()}
          type="button"
        >
          <Plus aria-hidden="true" size={18} strokeWidth={2.3} />
        </button>
        <div className="composer-input-field">
          {resolvedMention ? (
            <span className="composer-mention-chip" data-testid="composer-mention-chip">
              <span>@{resolvedMention.displayTitle}</span>
              <button
                aria-label={`Remove ${resolvedMention.displayTitle} mention`}
                className="composer-mention-remove"
                onClick={() => setResolvedMention(null)}
                type="button"
              >
                <X aria-hidden="true" size={14} strokeWidth={2.3} />
              </button>
            </span>
          ) : null}
          <textarea
            aria-keyshortcuts="Enter,Shift+Enter,Escape"
            enterKeyHint="send"
            id="composer-input"
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={handleComposerKeyDown}
            onPaste={(event) => {
              const files = Array.from(event.clipboardData?.files ?? []);
              if (files.length > 0) {
                event.preventDefault();
                appendFiles(files);
              }
            }}
            placeholder={sendState.placeholder}
            ref={textareaRef}
            rows={1}
            value={draft}
          />
          {mentionPickerVisible ? (
            <div
              aria-label="Mention destination"
              className="composer-mention-picker"
              role="listbox"
            >
              {filteredMentionStreams.length > 0 ? (
                filteredMentionStreams.map((stream, index) => (
                  <button
                    aria-selected={index === highlightedMentionIndex}
                    className={
                      index === highlightedMentionIndex
                        ? "composer-mention-option composer-mention-option--active"
                        : "composer-mention-option"
                    }
                    key={stream.sessionKey}
                    onClick={() => {
                      setResolvedMention({
                        destinationChatId: stream.sessionKey,
                        displayTitle: stream.displayName
                      });
                      setDraft("");
                      textareaRef.current?.focus({ preventScroll: true });
                    }}
                    role="option"
                    type="button"
                  >
                    <span>{stream.displayName}</span>
                    <small>{stream.sessionKey}</small>
                  </button>
                ))
              ) : (
                <div className="composer-mention-empty" role="option">
                  No matching sessions
                </div>
              )}
            </div>
          ) : null}
        </div>
        <button
          aria-label={sendState.sendAriaLabel}
          className={[
            "composer-circle-button",
            "composer-circle-button--send",
            `composer-circle-button--${sendState.connectionState}`
          ].join(" ")}
          data-connection-state={sendState.connectionState}
          disabled={!sendState.isSendButtonEnabled}
          onClick={handleSendButtonClick}
          onPointerDown={handleSendButtonPointerDown}
          type="button"
        >
          {isSubmitting ? (
            <span aria-hidden="true">…</span>
          ) : sendState.sendAction === "reconnect" ? (
            <RefreshCw aria-hidden="true" size={18} strokeWidth={2.1} />
          ) : (
            <SendHorizontal aria-hidden="true" size={18} strokeWidth={2.1} />
          )}
        </button>
      </form>
    </section>
  );
}

function formatAttachmentSize(size: number) {
  if (size >= 1_000_000) {
    return `${(size / 1_000_000).toFixed(1)} MB`;
  }
  if (size >= 1_000) {
    return `${(size / 1_000).toFixed(1)} KB`;
  }
  return `${size} B`;
}
