export function normalizePairingWebSocketUrl(raw: string) {
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    return null;
  }

  const initialUrl = trimmed.includes("://") ? trimmed : `ws://${trimmed}`;
  let url: URL;

  try {
    url = new URL(initialUrl);
  } catch {
    return null;
  }

  if (url.protocol === "http:") {
    url.protocol = "ws:";
  } else if (url.protocol === "https:") {
    url.protocol = "wss:";
  } else if (url.protocol !== "ws:" && url.protocol !== "wss:") {
    url.protocol = "ws:";
  }

  if (!url.port) {
    url.port = "18800";
  }

  if (!url.pathname || url.pathname === "/") {
    url.pathname = "/ws";
  } else if (!url.pathname.endsWith("/ws")) {
    url.pathname = `${url.pathname.replace(/\/$/, "")}/ws`;
  }

  url.search = "";
  url.hash = "";
  return url.toString();
}
