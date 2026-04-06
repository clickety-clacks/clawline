import { X } from "lucide-react";
import type { ChatMessageRecord } from "../../runtime/chat/chatDomainStore";
import { RichMessageBody } from "./RichMessageBody";

export function ExpandedMessageOverlay({
  message,
  onClose
}: {
  message: ChatMessageRecord;
  onClose: () => void;
}) {
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
        <RichMessageBody content={message.content} expanded />
      </aside>
    </div>
  );
}
