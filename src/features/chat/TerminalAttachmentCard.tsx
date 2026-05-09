import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { ServerAttachmentPayload } from "../../protocol/chat-wire";
import {
  decodeTerminalSessionDescriptor,
  terminalDestinationLabel,
  type TerminalSessionDescriptor
} from "../../protocol/terminal-wire";
import {
  createTerminalSessionRuntime,
  type TerminalRuntimeState
} from "../../runtime/terminal/terminalSessionRuntime";
import { supportsTerminalBubbles } from "../../runtime/terminal/terminalCapabilities";

const TERMINAL_THEME = {
  background: "#1e1e2e",
  foreground: "#cdd6f4",
  selectionBackground: "#45475a",
  cursor: "#f5e0dc",
  black: "#45475a",
  red: "#f38ba8",
  green: "#a6e3a1",
  yellow: "#f9e2af",
  blue: "#89b4fa",
  magenta: "#f5c2e7",
  cyan: "#94e2d5",
  white: "#bac2de",
  brightBlack: "#585b70",
  brightWhite: "#a6adc8"
} as const;

export function TerminalAttachmentCard({
  attachment,
  deviceId,
  serverUrl,
  token
}: {
  attachment: ServerAttachmentPayload;
  deviceId?: string;
  serverUrl?: string;
  token?: string;
}) {
  const descriptor = useMemo(
    () => decodeTerminalSessionDescriptor(attachment),
    [attachment]
  );
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [runtimeState, setRuntimeState] = useState<TerminalRuntimeState>({
    phase: "connecting"
  });
  const isSupported = supportsTerminalBubbles();

  useEffect(() => {
    if (!isSupported) {
      setRuntimeState({
        phase: "failed",
        reason: "Terminal bubbles are unavailable in this browser."
      });
      return;
    }

    if (!descriptor) {
      setRuntimeState({
        phase: "failed",
        reason: "Terminal attachment payload is invalid."
      });
      return;
    }

    if (!serverUrl || !token || !deviceId || !containerRef.current) {
      setRuntimeState({
        phase: "failed",
        reason: "Terminal session is unavailable."
      });
      return;
    }

    setRuntimeState({ phase: "connecting" });

    const terminal = new Terminal({
      allowProposedApi: false,
      convertEol: false,
      cursorBlink: descriptor.capabilities?.interactive !== false,
      cursorStyle: "block",
      disableStdin: descriptor.capabilities?.interactive === false,
      fontFamily:
        '"BlexMonoNerdFontMono-Regular", "SFMono-Regular", "SF Mono", ui-monospace, monospace',
      fontSize: 13,
      lineHeight: 1.12,
      rows: 24,
      theme: TERMINAL_THEME
    });
    const fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.open(containerRef.current);

    const runtime = createTerminalSessionRuntime({
      descriptor,
      deviceId,
      onData(chunk) {
        terminal.write(chunk);
      },
      onStateChange(nextState) {
        setRuntimeState(nextState);
      },
      serverUrl,
      token
    });

    const connect = () => {
      fitSafely(fitAddon);
      runtime.connect({
        cols: clampTerminalCols(terminal.cols),
        rows: clampTerminalRows(terminal.rows)
      });
    };

    const frame = window.requestAnimationFrame(connect);
    const resizeObserver =
      typeof window.ResizeObserver === "function"
        ? new window.ResizeObserver(() => {
            fitSafely(fitAddon);
            runtime.resize(
              clampTerminalCols(terminal.cols),
              clampTerminalRows(terminal.rows)
            );
          })
        : null;
    resizeObserver?.observe(containerRef.current);

    const inputDisposable =
      descriptor.capabilities?.interactive === false
        ? null
        : terminal.onData((input) => {
            runtime.sendInput(input);
          });

    return () => {
      window.cancelAnimationFrame(frame);
      inputDisposable?.dispose();
      resizeObserver?.disconnect();
      runtime.disconnect();
      terminal.dispose();
    };
  }, [attempt, descriptor, deviceId, isSupported, serverUrl, token]);

  if (!descriptor) {
    return (
      <TerminalShell
        descriptor={null}
        runtimeState={runtimeState}
        onReconnect={null}
      >
        <div className="terminal-attachment-error">Terminal attachment payload is invalid.</div>
      </TerminalShell>
    );
  }

  return (
    <TerminalShell
      descriptor={descriptor}
      runtimeState={runtimeState}
      onReconnect={
        runtimeState.phase === "failed" || runtimeState.phase === "exited"
          ? () => setAttempt((current) => current + 1)
          : null
      }
    >
      <div
        aria-label={terminalAriaLabel(descriptor)}
        className="terminal-attachment-surface"
        data-testid={`terminal-attachment-${descriptor.terminalSessionId}`}
        ref={containerRef}
      />
    </TerminalShell>
  );
}

function TerminalShell({
  children,
  descriptor,
  onReconnect,
  runtimeState
}: {
  children: ReactNode;
  descriptor: TerminalSessionDescriptor | null;
  onReconnect: (() => void) | null;
  runtimeState: TerminalRuntimeState;
}) {
  const isReadOnly = descriptor?.capabilities?.interactive === false;
  const overlayCopy = terminalOverlayCopy(runtimeState);
  const shouldShowOverlay = runtimeState.phase !== "ready";

  return (
    <section className="message-attachment-card terminal-attachment-card">
      <header className="terminal-attachment-header">
        <div className="terminal-attachment-copy">
          <strong>{descriptor?.title?.trim() || "Terminal"}</strong>
          <span>{descriptor ? terminalDestinationLabel(descriptor) : "Destination unknown"}</span>
        </div>
        {isReadOnly ? <span className="terminal-attachment-badge">Read only</span> : null}
      </header>
      <div className="terminal-attachment-stage">
        {children}
        {shouldShowOverlay ? (
          <div className="terminal-attachment-overlay">
            <p>{overlayCopy}</p>
            {onReconnect ? (
              <button className="button-secondary" onClick={onReconnect} type="button">
                Reconnect
              </button>
            ) : null}
          </div>
        ) : null}
      </div>
    </section>
  );
}

function terminalOverlayCopy(state: TerminalRuntimeState) {
  switch (state.phase) {
    case "connecting":
      return "Connecting terminal…";
    case "exited":
      return typeof state.exitCode === "number"
        ? `Terminal exited (code ${state.exitCode}).`
        : "Terminal exited.";
    case "failed":
      return state.reason ?? "Terminal unavailable.";
    case "disconnected":
      return "Terminal disconnected.";
    case "ready":
      return "";
  }
}

function clampTerminalCols(cols: number) {
  return Number.isFinite(cols) && cols > 1 ? cols : 80;
}

function clampTerminalRows(rows: number) {
  return Number.isFinite(rows) && rows > 0 ? rows : 24;
}

function fitSafely(fitAddon: FitAddon) {
  try {
    fitAddon.fit();
  } catch {
    // Ignore fit timing errors during initial layout.
  }
}

function terminalAriaLabel(descriptor: TerminalSessionDescriptor) {
  const destination = terminalDestinationLabel(descriptor);
  const title = descriptor.title?.trim() || "Terminal";
  return `${title}, ${destination}`;
}
