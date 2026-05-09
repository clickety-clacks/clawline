import type { MessageEventLike, SocketLike, WebSocketFactory } from "../../runtime/transport/wsClient";
import type {
  TerminalSocketLike,
  TerminalWebSocketFactory
} from "../../runtime/terminal/terminalSessionRuntime";

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

export class FakeTerminalSocket implements TerminalSocketLike {
  binaryType: BinaryType = "blob";
  onclose: ((event: CloseEvent | Event) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent<string | ArrayBuffer | Blob>) => void) | null = null;
  onopen: ((event: Event) => void) | null = null;
  sentPayloads: Array<string | ArrayBufferLike | Blob | ArrayBufferView> = [];

  close() {
    this.onclose?.(new Event("close"));
  }

  emitClose() {
    this.onclose?.(new Event("close"));
  }

  emitError() {
    this.onerror?.(new Event("error"));
  }

  emitMessage(data: string | ArrayBuffer | Blob) {
    this.onmessage?.(
      new MessageEvent("message", {
        data
      })
    );
  }

  emitOpen() {
    this.onopen?.(new Event("open"));
  }

  send(data: string | ArrayBufferLike | Blob | ArrayBufferView) {
    this.sentPayloads.push(data);
  }
}

export class FakeTerminalWebSocketFactory {
  sockets: FakeTerminalSocket[] = [];
  urlRequests: string[] = [];

  readonly create: TerminalWebSocketFactory = (url) => {
    this.urlRequests.push(url);
    const socket = new FakeTerminalSocket();
    this.sockets.push(socket);
    return socket;
  };
}
