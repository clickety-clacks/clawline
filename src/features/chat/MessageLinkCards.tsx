import { useEffect, useState, type RefObject } from "react";
import {
  fallbackLinkCardMetadata,
  fetchLinkCardMetadata,
  type LinkCardMetadata
} from "./linkCardMetadata";

export function MessageLinkCards({
  content,
  contentRef
}: {
  content: string;
  contentRef: RefObject<HTMLDivElement | null>;
}) {
  const [urls, setUrls] = useState<string[]>([]);

  useEffect(() => {
    const anchors = Array.from(
      contentRef.current?.querySelectorAll<HTMLAnchorElement>("a[href]") ?? []
    );
    const nextUrls = uniqueHttpUrls(anchors.map((anchor) => anchor.href));
    setUrls((current) =>
      current.length === nextUrls.length &&
      current.every((value, index) => value === nextUrls[index])
        ? current
        : nextUrls
    );
  }, [content, contentRef]);

  if (urls.length === 0) {
    return null;
  }

  return (
    <div className="message-link-cards">
      {urls.map((url) => (
        <MessageLinkCard href={url} key={url} />
      ))}
    </div>
  );
}

function MessageLinkCard({ href }: { href: string }) {
  const [metadata, setMetadata] = useState<LinkCardMetadata>(() => fallbackLinkCardMetadata(href));

  useEffect(() => {
    let cancelled = false;
    setMetadata(fallbackLinkCardMetadata(href));

    void fetchLinkCardMetadata(href).then((nextMetadata) => {
      if (cancelled || !nextMetadata) {
        return;
      }

      setMetadata(nextMetadata);
    });

    return () => {
      cancelled = true;
    };
  }, [href]);

  return (
    <a
      className="message-link-card"
      href={href}
      rel="noreferrer"
      target="_blank"
    >
      {metadata.imageUrl ? (
        <img
          alt=""
          aria-hidden="true"
          className="message-link-card-thumbnail"
          src={metadata.imageUrl}
        />
      ) : null}
      <div className="message-link-card-copy">
        <span className="message-link-card-domain">{metadata.domain}</span>
        <strong>{metadata.title}</strong>
        {metadata.description ? <span>{metadata.description}</span> : null}
      </div>
      <span aria-hidden="true" className="message-link-card-arrow">
        ↗
      </span>
    </a>
  );
}

function uniqueHttpUrls(urls: string[]) {
  const seen = new Set<string>();
  const unique: string[] = [];

  for (const candidate of urls) {
    try {
      const url = new URL(candidate);
      if (url.protocol !== "http:" && url.protocol !== "https:") {
        continue;
      }

      const normalized = url.toString();
      if (!seen.has(normalized)) {
        seen.add(normalized);
        unique.push(normalized);
      }
    } catch {
      continue;
    }
  }

  return unique;
}
