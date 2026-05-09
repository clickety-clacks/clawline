import { X } from "lucide-react";
import { useRef } from "react";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import { MessageAttachments } from "./MessageAttachments";
import { MessageLinkCards } from "./MessageLinkCards";
import { RichMessageBody } from "./RichMessageBody";

export function ExpandedMessageOverlay({
  message,
  onClose
}: {
  message: ChatMessageRecord;
  onClose: () => void;
}) {
  const { state: authState } = useAuthSessionStore();
  const contentRef = useRef<HTMLDivElement | null>(null);

  return (
    <div className="message-overlay-backdrop" onClick={onClose} role="presentation">
      <aside
        aria-label="Expanded message"
        className="message-overlay"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="settings-header">
          <div>
            <p className="eyebrow">Message</p>
            <h2>Expanded view</h2>
          </div>
          <button
            aria-label="Close expanded message"
            className="button-secondary button-icon"
            onClick={onClose}
            type="button"
          >
            <X size={18} strokeWidth={2.1} />
          </button>
        </div>
        <header className="message-meta">
          <span>{message.role === "user" ? "You" : message.sender ?? "Assistant"}</span>
          <span>{new Date(message.timestamp).toLocaleTimeString()}</span>
        </header>
        <RichMessageBody content={message.content} contentRef={contentRef} expanded />
        <MessageLinkCards content={message.content} contentRef={contentRef} />
        <MessageAttachments
          attachments={message.attachments}
          deviceId={authState.session?.deviceId}
          expanded
          messageId={message.id}
          serverUrl={authState.session?.serverUrl}
          token={authState.session?.token}
        />
      </aside>
    </div>
  );
}
