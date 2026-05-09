import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { TerminalRuntimeState } from "./terminalSessionRuntime";
import { createTerminalSessionRuntime } from "./terminalSessionRuntime";
import { FakeTerminalWebSocketFactory } from "../../test/support/fakeWebSocket";

describe("terminalSessionRuntime", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("authenticates over /ws/terminal and gates resize and input until terminal readiness", async () => {
    const factory = new FakeTerminalWebSocketFactory();
    const runtimeStates: TerminalRuntimeState[] = [];
    const chunks: Array<string | Uint8Array> = [];
    const runtime = createTerminalSessionRuntime({
      descriptor: sampleDescriptor(),
      deviceId: "device-web-1",
      onData(chunk) {
        chunks.push(chunk);
      },
      onStateChange(state) {
        runtimeStates.push(state);
      },
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "chat-token",
      webSocketFactory: factory.create
    });

    runtime.connect({ cols: 100, rows: 28 });

    expect(factory.urlRequests).toEqual(["ws://127.0.0.1:18800/ws/terminal"]);
    expect(runtimeStates.at(-1)).toEqual({ phase: "connecting" });

    const socket = factory.sockets[0];
    socket.emitOpen();

    expect(JSON.parse(String(socket.sentPayloads[0]))).toMatchObject({
      type: "terminal_auth",
      authMode: "chat_token",
      authToken: "chat-token",
      deviceId: "device-web-1",
      terminalSessionId: "term_123",
      backfillLines: 2000,
      cols: 100,
      rows: 28
    });

    runtime.resize(132, 40);
    runtime.sendInput("pwd\n");
    expect(socket.sentPayloads).toHaveLength(1);

    socket.emitMessage(JSON.stringify({ type: "terminal_ready" }));
    socket.emitMessage(JSON.stringify({ type: "terminal_backfill_end" }));
    await vi.advanceTimersByTimeAsync(250);

    expect(runtimeStates.at(-1)).toEqual({ phase: "ready" });
    expect(JSON.parse(String(socket.sentPayloads[1]))).toEqual({
      type: "terminal_resize",
      cols: 132,
      rows: 40
    });

    runtime.sendInput("pwd\n");
    expect(ArrayBuffer.isView(socket.sentPayloads[2])).toBe(true);

    socket.emitMessage(JSON.stringify({ type: "terminal_data", data: btoa("hello\r\n") }));
    socket.emitMessage("plain text\r\n");
    socket.emitMessage(Uint8Array.from([0x41, 0x0a]).buffer);

    expect(chunks).toHaveLength(3);
    expect(chunks[0]).toBeInstanceOf(Uint8Array);
    expect(chunks[1]).toBe("plain text\r\n");
    expect(chunks[2]).toBeInstanceOf(Uint8Array);

    runtime.disconnect();

    expect(JSON.parse(String(socket.sentPayloads[3]))).toEqual({
      type: "terminal_detach"
    });
    expect(runtimeStates.at(-1)).toEqual({ phase: "disconnected" });
  });

  it("enables input after terminal_ready when the provider omits backfill end", async () => {
    const factory = new FakeTerminalWebSocketFactory();
    const runtime = createTerminalSessionRuntime({
      descriptor: sampleDescriptor(),
      deviceId: "device-web-1",
      onData() {},
      onStateChange() {},
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "chat-token",
      webSocketFactory: factory.create
    });

    runtime.connect({ cols: 100, rows: 28 });
    const socket = factory.sockets[0];
    socket.emitOpen();
    socket.emitMessage(JSON.stringify({ type: "terminal_ready" }));
    await vi.advanceTimersByTimeAsync(250);

    runtime.resize(132, 40);
    runtime.sendInput("pwd\n");

    expect(JSON.parse(String(socket.sentPayloads[1]))).toEqual({
      type: "terminal_resize",
      cols: 132,
      rows: 40
    });
    expect(ArrayBuffer.isView(socket.sentPayloads[2])).toBe(true);
  });

  it("surfaces terminal_closed reasons and reconnects cleanly", () => {
    const factory = new FakeTerminalWebSocketFactory();
    const runtimeStates: TerminalRuntimeState[] = [];
    const runtime = createTerminalSessionRuntime({
      descriptor: sampleDescriptor(),
      deviceId: "device-web-1",
      onData() {},
      onStateChange(state) {
        runtimeStates.push(state);
      },
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "chat-token",
      webSocketFactory: factory.create
    });

    runtime.connect({ cols: 80, rows: 24 });
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "terminal_closed",
        message: "Host unavailable"
      })
    );

    expect(runtimeStates.at(-1)).toEqual({
      phase: "failed",
      reason: "Host unavailable"
    });

    runtime.connect({ cols: 80, rows: 24 });
    expect(factory.sockets).toHaveLength(2);
  });

  it("preserves terminal exit state when the socket closes afterward", () => {
    const factory = new FakeTerminalWebSocketFactory();
    const runtimeStates: TerminalRuntimeState[] = [];
    const runtime = createTerminalSessionRuntime({
      descriptor: sampleDescriptor(),
      deviceId: "device-web-1",
      onData() {},
      onStateChange(state) {
        runtimeStates.push(state);
      },
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "chat-token",
      webSocketFactory: factory.create
    });

    runtime.connect({ cols: 80, rows: 24 });
    factory.sockets[0].emitOpen();
    factory.sockets[0].emitMessage(
      JSON.stringify({
        type: "terminal_exit",
        code: 0
      })
    );
    factory.sockets[0].emitClose();

    expect(runtimeStates.at(-1)).toEqual({
      phase: "exited",
      exitCode: 0
    });
  });
});

function sampleDescriptor() {
  return {
    version: 2,
    terminalSessionId: "term_123",
    title: "eezo",
    destination: {
      address: "mike@eezo"
    },
    capabilities: {
      interactive: true,
      supportsBinaryFrames: true,
      supportsResize: true,
      supportsDetach: true
    }
  } as const;
}
