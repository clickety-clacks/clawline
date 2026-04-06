import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import { Plus, RefreshCw, SendHorizontal } from "lucide-react";
import type { SessionProvisioningState } from "../streams/provisioning";
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
  sessionKey
}: {
  activeStreamDisplayName?: string;
  provisioningState: SessionProvisioningState;
  sessionKey?: string;
}) {
  const { state: authState, store: authStore } = useAuthSessionStore();
  const { store: chatStore } = useChatDomainStore();
  const { state: transportState, store: transportStore } = useTransportMachine();
  const [draft, setDraft] = useState("");
  const [isDragActive, setDragActive] = useState(false);
  const [isSubmitting, setSubmitting] = useState(false);
  const [stagedAttachments, setStagedAttachments] = useState<ComposerAttachmentDraft[]>([]);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const fileInputId = useId();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  const sendState = projectComposerSendState({
    activeStreamDisplayName,
    draft,
    isSubmitting,
    provisioningState,
    sessionKey,
    stagedAttachmentCount: stagedAttachments.length,
    transportPhase: transportState.phase
  });

  useEffect(() => {
    const textarea = textareaRef.current;
    if (!textarea) {
      return;
    }

    textarea.style.height = "0px";
    const nextHeight = Math.min(Math.max(textarea.scrollHeight, 28), 140);
    textarea.style.height = `${nextHeight}px`;
  }, [draft]);

  async function submit() {
    if (!sessionKey || !authState.session) {
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
        serverUrl: authState.session.serverUrl,
        token: authState.session.token
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

    const id = `c_${generateUuidV4()}`;
    const timestamp = Date.now();

    chatStore.enqueueOptimisticMessage({
      attachments: preparedAttachments.optimisticAttachments,
      content,
      deviceId: authState.session.deviceId,
      id,
      sessionKey,
      timestamp,
      wireAttachments: preparedAttachments.wireAttachments
    });

    setDraft("");
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
        sessionKey
      });
    } catch {
      chatStore.markMessageFailed(id);
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

  function handleSendButtonClick() {
    if (sendState.sendAction === "reconnect") {
      transportStore.retryNow();
      return;
    }

    if (sendState.sendAction === "send") {
      void submit();
    }
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
          <textarea
            aria-keyshortcuts="Enter,Shift+Enter,Escape"
            enterKeyHint="send"
            id="composer-input"
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") {
                event.preventDefault();
                event.currentTarget.blur();
                return;
              }

              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                void submit();
              }
            }}
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
