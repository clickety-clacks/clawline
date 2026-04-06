import { act, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { PairingScreen } from "./PairingScreen";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore
} from "../../runtime/auth/authSessionStore";

class MockPairingWebSocket {
  static attempts: Array<"pending" | "success"> = [];

  static reset(attempts: Array<"pending" | "success">) {
    MockPairingWebSocket.attempts = [...attempts];
  }

  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent<string>) => void) | null = null;
  onopen: ((event: Event) => void) | null = null;

  constructor(_url: string | URL) {
    queueMicrotask(() => {
      this.onopen?.(new Event("open"));
    });
  }

  close() {
    this.onclose?.(new CloseEvent("close"));
  }

  send(_data: string) {
    const nextAttempt = MockPairingWebSocket.attempts.shift() ?? "success";

    queueMicrotask(() => {
      if (nextAttempt === "pending") {
        this.onmessage?.(
          new MessageEvent("message", {
            data: JSON.stringify({
              type: "pair_result",
              success: false,
              reason: "pair_pending"
            })
          })
        );
        return;
      }

      this.onmessage?.(
        new MessageEvent("message", {
          data: JSON.stringify({
            type: "pair_result",
            success: true,
            token: "live-token",
            userId: "flynn"
          })
        })
      );
    });
  }
}

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location">{location.pathname}</div>;
}

describe("usePairingActions", () => {
  const originalWebSocket = globalThis.WebSocket;

  beforeEach(() => {
    vi.useFakeTimers();
    MockPairingWebSocket.reset([]);
    vi.stubGlobal("WebSocket", MockPairingWebSocket);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    if (originalWebSocket) {
      vi.stubGlobal("WebSocket", originalWebSocket);
    }
  });

  it("keeps retrying after pair_pending until approval succeeds", async () => {
    MockPairingWebSocket.reset(["pending", "pending", "success"]);

    const authStore = createAuthSessionStore();

    render(
      <AuthSessionStoreProvider value={authStore}>
        <MemoryRouter initialEntries={["/pair"]}>
          <Routes>
            <Route
              element={
                <>
                  <PairingScreen />
                  <LocationProbe />
                </>
              }
              path="/pair"
            />
            <Route element={<LocationProbe />} path="/chat" />
          </Routes>
        </MemoryRouter>
      </AuthSessionStoreProvider>
    );

    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Flynn" }
    });
    fireEvent.change(screen.getByLabelText("Provider address"), {
      target: { value: "ws://eezo.tail4105e8.ts.net:18800" }
    });
    fireEvent.click(screen.getByRole("button", { name: "Pair browser" }));

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(
      screen.getByRole("heading", { name: "Clawline is waiting on an approved device." })
    ).toBeInTheDocument();
    expect(screen.getByText("Clawline keeps retrying in the background while you wait.")).toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3_000);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(
      screen.getByRole("heading", { name: "Clawline is waiting on an approved device." })
    ).toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3_000);
      await Promise.resolve();
      await Promise.resolve();
    });

    await act(async () => {
      await vi.runOnlyPendingTimersAsync();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByTestId("location")).toHaveTextContent("/chat");
    expect(authStore.getState().session).toMatchObject({
      claimedName: "Flynn",
      serverUrl: "ws://eezo.tail4105e8.ts.net:18800/ws",
      token: "live-token",
      userId: "flynn"
    });
  });
});
