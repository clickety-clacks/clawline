import { useEffect, useMemo, useState, type ReactNode } from "react";
import type { ServerAttachmentPayload } from "../../protocol/chat-wire";
import {
  attachmentFilename,
  attachmentMimeType,
  fetchAuthenticatedAttachmentBlob
} from "../../protocol/attachment-api";
import { isInteractiveHtmlAttachment } from "../../protocol/interactive-html-wire";
import { isTerminalAttachment } from "../../protocol/terminal-wire";
import { InteractiveHtmlAttachmentCard } from "./InteractiveHtmlAttachmentCard";
import { TerminalAttachmentCard } from "./TerminalAttachmentCard";

export function MessageAttachments({
  attachments,
  deviceId,
  expanded = false,
  messageId,
  serverUrl,
  token
}: {
  attachments: ServerAttachmentPayload[];
  deviceId?: string;
  expanded?: boolean;
  messageId: string;
  serverUrl?: string;
  token?: string;
}) {
  if (attachments.length === 0) {
    return null;
  }

  return (
    <div className="message-attachments">
      {attachments.map((attachment, index) => (
        <AttachmentCard
          attachment={attachment}
          deviceId={deviceId}
          expanded={expanded}
          key={attachment.id ?? attachment.assetId ?? `${attachment.type}:${index}`}
          messageId={messageId}
          serverUrl={serverUrl}
          token={token}
        />
      ))}
    </div>
  );
}

function AttachmentCard({
  attachment,
  deviceId,
  expanded,
  messageId,
  serverUrl,
  token
}: {
  attachment: ServerAttachmentPayload;
  deviceId?: string;
  expanded?: boolean;
  messageId: string;
  serverUrl?: string;
  token?: string;
}) {
  const kind = classifyAttachment(attachment);

  if (kind === "interactive-html") {
    return (
      <InteractiveHtmlAttachmentCard
        attachment={attachment}
        expanded={expanded}
        messageId={messageId}
      />
    );
  }

  if (kind === "terminal") {
    if (expanded) {
      return <TerminalAttachmentPlaceholder attachment={attachment} />;
    }

    return (
      <TerminalAttachmentCard
        attachment={attachment}
        deviceId={deviceId}
        serverUrl={serverUrl}
        token={token}
      />
    );
  }

  if (kind === "image") {
    return (
      <RemoteAttachmentMedia
        attachment={attachment}
        render={(sourceUrl) => (
          <img
            alt={attachmentFilename(attachment)}
            className="message-attachment-image"
            data-testid={`attachment-image-${attachment.assetId ?? attachment.id ?? "inline"}`}
            src={sourceUrl}
          />
        )}
        serverUrl={serverUrl}
        token={token}
      />
    );
  }

  if (kind === "audio") {
    return (
      <RemoteAttachmentMedia
        attachment={attachment}
        render={(sourceUrl) => (
          <audio
            aria-label={attachmentFilename(attachment)}
            className="message-attachment-audio"
            controls
            src={sourceUrl}
          />
        )}
        serverUrl={serverUrl}
        token={token}
      />
    );
  }

  if (kind === "video") {
    return (
      <RemoteAttachmentMedia
        attachment={attachment}
        render={(sourceUrl) => (
          <video
            aria-label={attachmentFilename(attachment)}
            className="message-attachment-video"
            controls
            src={sourceUrl}
          />
        )}
        serverUrl={serverUrl}
        token={token}
      />
    );
  }

  return (
    <FileAttachmentCard
      attachment={attachment}
      serverUrl={serverUrl}
      token={token}
    />
  );
}

function RemoteAttachmentMedia({
  attachment,
  render,
  serverUrl,
  token
}: {
  attachment: ServerAttachmentPayload;
  render: (sourceUrl: string) => ReactNode;
  serverUrl?: string;
  token?: string;
}) {
  const { errorMessage, sourceUrl } = useAttachmentObjectUrl({
    attachment,
    serverUrl,
    token
  });

  if (errorMessage) {
    return <AttachmentErrorCard attachment={attachment} errorMessage={errorMessage} />;
  }

  if (!sourceUrl) {
    return <AttachmentPendingCard attachment={attachment} />;
  }

  return (
    <figure className="message-attachment-card">
      {render(sourceUrl)}
      <figcaption>{attachmentFilename(attachment)}</figcaption>
    </figure>
  );
}

function FileAttachmentCard({
  attachment,
  serverUrl,
  token
}: {
  attachment: ServerAttachmentPayload;
  serverUrl?: string;
  token?: string;
}) {
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isDownloading, setDownloading] = useState(false);

  async function download() {
    if (!serverUrl || !token) {
      setErrorMessage("Attachment download is unavailable.");
      return;
    }

    setDownloading(true);
    setErrorMessage(null);

    try {
      const blob = await fetchAuthenticatedAttachmentBlob({
        attachment,
        serverUrl,
        token
      });
      const objectUrl = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = objectUrl;
      anchor.download = attachmentFilename(attachment);
      anchor.rel = "noreferrer";
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(objectUrl);
    } catch {
      setErrorMessage("Attachment download failed.");
    } finally {
      setDownloading(false);
    }
  }

  return (
    <div className="message-attachment-card message-attachment-card--file">
      <div className="message-attachment-copy">
        <strong>{attachmentFilename(attachment)}</strong>
        <span>{attachmentMimeType(attachment) ?? "File attachment"}</span>
      </div>
      <button className="button-secondary" onClick={() => void download()} type="button">
        {isDownloading ? "Downloading…" : `Download ${attachmentFilename(attachment)}`}
      </button>
      {errorMessage ? <p className="field-error">{errorMessage}</p> : null}
    </div>
  );
}

function TerminalAttachmentPlaceholder({
  attachment
}: {
  attachment: ServerAttachmentPayload;
}) {
  return (
    <div className="message-attachment-card message-attachment-card--file">
      <div className="message-attachment-copy">
        <strong>{attachmentFilename(attachment)}</strong>
        <span>Terminal session remains active in the message bubble.</span>
      </div>
    </div>
  );
}

function AttachmentPendingCard({
  attachment
}: {
  attachment: ServerAttachmentPayload;
}) {
  return (
    <div className="message-attachment-card message-attachment-card--file">
      <div className="message-attachment-copy">
        <strong>{attachmentFilename(attachment)}</strong>
        <span>{attachmentMimeType(attachment) ?? "Attachment"}</span>
      </div>
      <span className="connection-status">Loading attachment…</span>
    </div>
  );
}

function AttachmentErrorCard({
  attachment,
  errorMessage
}: {
  attachment: ServerAttachmentPayload;
  errorMessage: string;
}) {
  return (
    <div className="message-attachment-card message-attachment-card--file">
      <div className="message-attachment-copy">
        <strong>{attachmentFilename(attachment)}</strong>
        <span>{attachmentMimeType(attachment) ?? "Attachment"}</span>
      </div>
      <p className="field-error">{errorMessage}</p>
    </div>
  );
}

function useAttachmentObjectUrl(input: {
  attachment: ServerAttachmentPayload;
  serverUrl?: string;
  token?: string;
}) {
  const [sourceUrl, setSourceUrl] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const shouldLoad = useMemo(() => {
    if (input.attachment.data) {
      return true;
    }

    return Boolean(input.attachment.assetId && input.serverUrl && input.token);
  }, [input.attachment, input.serverUrl, input.token]);

  useEffect(() => {
    if (!shouldLoad) {
      setSourceUrl(null);
      setErrorMessage("Attachment preview is unavailable.");
      return;
    }

    if (!input.attachment.data && (!input.serverUrl || !input.token)) {
      setSourceUrl(null);
      setErrorMessage("Attachment preview is unavailable.");
      return;
    }

    let isCancelled = false;
    let objectUrl: string | null = null;
    setSourceUrl(null);
    setErrorMessage(null);

    void (async () => {
      try {
        const blob = await fetchAuthenticatedAttachmentBlob({
          attachment: input.attachment,
          serverUrl: input.serverUrl ?? "ws://invalid/ws",
          token: input.token ?? ""
        });
        objectUrl = URL.createObjectURL(blob);
        if (!isCancelled) {
          setSourceUrl(objectUrl);
        }
      } catch {
        if (!isCancelled) {
          setErrorMessage("Attachment preview failed.");
        }
      }
    })();

    return () => {
      isCancelled = true;
      if (objectUrl) {
        URL.revokeObjectURL(objectUrl);
      }
    };
  }, [
    input.attachment.assetId,
    input.attachment.data,
    input.attachment.id,
    input.attachment.metadata?.mimeType,
    input.attachment.mimeType,
    input.serverUrl,
    input.token,
    shouldLoad
  ]);

  return { errorMessage, sourceUrl };
}

function classifyAttachment(attachment: ServerAttachmentPayload) {
  if (isInteractiveHtmlAttachment(attachment)) {
    return "interactive-html";
  }

  if (isTerminalAttachment(attachment)) {
    return "terminal";
  }

  const mimeType = attachmentMimeType(attachment) ?? "";
  if (attachment.type === "image" || mimeType.startsWith("image/")) {
    return "image";
  }
  if (mimeType.startsWith("audio/")) {
    return "audio";
  }
  if (mimeType.startsWith("video/")) {
    return "video";
  }
  return "file";
}
