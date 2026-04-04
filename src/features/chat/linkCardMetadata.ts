export interface LinkCardMetadata {
  description: string | null;
  domain: string;
  imageUrl: string | null;
  title: string;
  url: string;
}

const metadataCache = new Map<string, LinkCardMetadata | null>();
const metadataRequests = new Map<string, Promise<LinkCardMetadata | null>>();

export async function fetchLinkCardMetadata(url: string): Promise<LinkCardMetadata | null> {
  if (metadataCache.has(url)) {
    return metadataCache.get(url) ?? null;
  }

  const inFlight = metadataRequests.get(url);
  if (inFlight) {
    return inFlight;
  }

  const request = loadLinkCardMetadata(url);
  metadataRequests.set(url, request);

  try {
    const value = await request;
    metadataCache.set(url, value);
    return value;
  } finally {
    metadataRequests.delete(url);
  }
}

async function loadLinkCardMetadata(url: string): Promise<LinkCardMetadata | null> {
  try {
    const response = await fetch(url, {
      headers: {
        Accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
        Range: "bytes=0-262143"
      }
    });

    if (!response.ok) {
      return null;
    }

    const mimeType = response.headers.get("content-type")?.toLowerCase() ?? "";
    if (mimeType && !mimeType.startsWith("text/html") && !mimeType.startsWith("application/xhtml")) {
      return null;
    }

    const html = (await response.text()).slice(0, 200_000);
    const resolvedUrl = response.url || url;
    return parseLinkCardMetadata(html, resolvedUrl);
  } catch {
    return null;
  }
}

export function parseLinkCardMetadata(html: string, url: string): LinkCardMetadata | null {
  const resolvedUrl = new URL(url);
  const document = new DOMParser().parseFromString(html, "text/html");
  const query = (selector: string) => document.head.querySelector(selector)?.getAttribute("content");

  const title =
    query('meta[property="og:title"]') ??
    query('meta[name="twitter:title"]') ??
    document.title ??
    resolvedUrl.toString();
  const description =
    query('meta[property="og:description"]') ??
    query('meta[name="twitter:description"]') ??
    query('meta[name="description"]');
  const imageSource =
    query('meta[property="og:image"]') ??
    query('meta[name="twitter:image"]');

  const normalizedTitle = title.trim();
  if (!normalizedTitle) {
    return null;
  }

  return {
    description: description?.trim() || null,
    domain: resolvedUrl.hostname.toUpperCase(),
    imageUrl: imageSource ? new URL(imageSource, resolvedUrl).toString() : null,
    title: normalizedTitle,
    url: resolvedUrl.toString()
  };
}

export function fallbackLinkCardMetadata(value: string): LinkCardMetadata {
  const url = new URL(value);
  const pathname = decodeURIComponent(url.pathname).replace(/\/+$/, "");
  const title =
    pathname.length > 1
      ? `${url.hostname}${pathname}${url.search}${url.hash}`
      : url.hostname;

  return {
    description: value,
    domain: url.hostname.toUpperCase(),
    imageUrl: null,
    title,
    url: url.toString()
  };
}

export function resetLinkCardMetadataCache() {
  metadataCache.clear();
  metadataRequests.clear();
}
