import type { MessageEventLike, SocketLike, WebSocketFactory } from "../../runtime/transport/wsClient";

export class FakeSocket implements SocketLike {
  onclose: ((event: unknown) => void) | null = null;
  onerror: ((event: unknown) => void) | null = null;
  onmessage: ((event: MessageEventLike) => void) | null = null;
  onopen: ((event: unknown) => void) | null = null;
  sentTexts: string[] = [];

  close() {
    this.onclose?.({ type: "close" });
  }

  emitOpen() {
    this.onopen?.({ type: "open" });
  }

  emitMessage(data: string) {
    this.onmessage?.({ data, type: "message" });
  }

  emitClose() {
    this.onclose?.({ type: "close" });
  }

  emitError() {
    this.onerror?.({ type: "error" });
  }

  send(data: string) {
    this.sentTexts.push(data);
  }
}

export class FakeWebSocketFactory {
  sockets: FakeSocket[] = [];
  urlRequests: string[] = [];

  readonly create: WebSocketFactory = (url) => {
    this.urlRequests.push(url);
    const socket = new FakeSocket();
    this.sockets.push(socket);
    return socket;
  };
}
