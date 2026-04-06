export interface SocketLike {
  close(code?: number, reason?: string): void;
  onclose: ((event: unknown) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onmessage: ((event: MessageEventLike) => void) | null;
  onopen: ((event: unknown) => void) | null;
  send(data: string): void;
}

export interface EventLike {
  type?: string;
}

export interface MessageEventLike extends EventLike {
  data: string;
}

export type WebSocketFactory = (url: string) => SocketLike;

export function createBrowserWebSocketFactory(): WebSocketFactory {
  return (url) => new WebSocket(url) as unknown as SocketLike;
}
