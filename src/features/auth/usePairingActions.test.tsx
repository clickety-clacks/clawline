import { act, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { PairingScreen } from "./PairingScreen";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore
} from "../../runtime/auth/authSessionStore";

class MockPairingWebSocket {
  static instances: MockPairingWebSocket[] = [];
  static nextBehaviors: Array<"pending" | "success"> = [];

  static reset(behaviors: Array<"pending" | "success">) {
    MockPairingWebSocket.instances = [];
    MockPairingWebSocket.nextBehaviors = [...behaviors];
  }

  readonly behavior: "pending" | "success";
  closeCount = 0;
  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent<string>) => void) | null = null;
  onopen: ((event: Event) => void) | null = null;
  sentMessages: string[] = [];

  constructor(_url: string | URL) {
    this.behavior = MockPairingWebSocket.nextBehaviors.shift() ?? "success";
    MockPairingWebSocket.instances.push(this);
    queueMicrotask(() => {
      this.onopen?.(new Event("open"));
    });
  }

  close() {
    this.closeCount += 1;
    this.onclose?.(new CloseEvent("close"));
  }

  send(data: string) {
    this.sentMessages.push(data);

    queueMicrotask(() => {
      if (this.behavior === "pending") {
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

      this.approve();
    });
  }

  approve() {
    this.onmessage?.(
      new MessageEvent("message", {
        data: JSON.stringify({
          type: "pair_result",
          success: true,
          token: "live-token",
          userId: "clawline_web_test"
        })
      })
    );
  }

  closeFromProvider() {
    this.onclose?.(new CloseEvent("close"));
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
    window.localStorage.clear();
    vi.stubGlobal("WebSocket", MockPairingWebSocket);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    if (originalWebSocket) {
      vi.stubGlobal("WebSocket", originalWebSocket);
    }
  });

  it("keeps the pending pairing socket open instead of polling pair_request every 3 seconds", async () => {
    MockPairingWebSocket.reset(["pending"]);

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
      target: { value: "Clawline Web Test" }
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
    expect(screen.getByText("Clawline is keeping this pairing request open while you wait.")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Retry pairing" })).not.toBeInTheDocument();
    expect(MockPairingWebSocket.instances).toHaveLength(1);
    expect(MockPairingWebSocket.instances[0].sentMessages).toHaveLength(1);
    expect(MockPairingWebSocket.instances[0].closeCount).toBe(0);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(9_000);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(
      screen.getByRole("heading", { name: "Clawline is waiting on an approved device." })
    ).toBeInTheDocument();
    expect(MockPairingWebSocket.instances).toHaveLength(1);
    expect(MockPairingWebSocket.instances[0].sentMessages).toHaveLength(1);
    expect(MockPairingWebSocket.instances[0].closeCount).toBe(0);

    await act(async () => {
      MockPairingWebSocket.instances[0].approve();
    });

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByTestId("location")).toHaveTextContent("/chat");
    expect(authStore.getState().session).toMatchObject({
      claimedName: "Clawline Web Test",
      serverUrl: "ws://eezo.tail4105e8.ts.net:18800/ws",
      token: "live-token",
      userId: "clawline_web_test"
    });
  });

  it("resubmits only when the user retries after the pending socket stalls", async () => {
    MockPairingWebSocket.reset(["pending", "success"]);

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
      target: { value: "Clawline Web Test" }
    });
    fireEvent.change(screen.getByLabelText("Provider address"), {
      target: { value: "ws://eezo.tail4105e8.ts.net:18800" }
    });
    fireEvent.click(screen.getByRole("button", { name: "Pair browser" }));

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(MockPairingWebSocket.instances).toHaveLength(1);
    expect(MockPairingWebSocket.instances[0].sentMessages).toHaveLength(1);

    act(() => {
      MockPairingWebSocket.instances[0].closeFromProvider();
    });

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByRole("alert")).toHaveTextContent("Provider closed the pairing socket.");
    expect(screen.getByText("The pairing socket is no longer waiting. Retry to resubmit after checking approval.")).toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(9_000);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(MockPairingWebSocket.instances).toHaveLength(1);
    expect(MockPairingWebSocket.instances[0].sentMessages).toHaveLength(1);

    fireEvent.click(screen.getByRole("button", { name: "Retry pairing" }));

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(MockPairingWebSocket.instances).toHaveLength(2);
    expect(MockPairingWebSocket.instances[1].sentMessages).toHaveLength(1);
    expect(screen.getByTestId("location")).toHaveTextContent("/chat");
  });
});
