import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { TransportPhase } from "../../runtime/transport/transportMachine";
import { useChatSessionCoordinator } from "./useChatSessionCoordinator";

const STREAMS = [
  {
    sessionKey: "agent:main:clawline:user_1:main",
    displayName: "Personal",
    kind: "main" as const,
    orderIndex: 0,
    isBuiltIn: true,
    createdAt: 10,
    updatedAt: 10,
    adopted: false
  },
  {
    sessionKey: "agent:main:clawline:user_1:side",
    displayName: "Side Thread",
    kind: "custom" as const,
    orderIndex: 1,
    isBuiltIn: false,
    createdAt: 11,
    updatedAt: 11,
    adopted: false
  }
];

interface CoordinatorHookProps {
  routeSessionKey?: string;
  transportPhase: TransportPhase;
}

describe("useChatSessionCoordinator", () => {
  it("mirrors the current route-driven active session behavior", async () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: STREAMS.map((stream) => stream.sessionKey),
        routeSessionKey: "agent:main:clawline:user_1:side",
        streams: STREAMS,
        transportPhase: "live"
      })
    );

    await waitFor(() => {
      expect(result.current.activeSessionKey).toBe("agent:main:clawline:user_1:side");
    });

    expect(result.current.activeSessionKey).toBe("agent:main:clawline:user_1:side");
    expect(result.current.firstProviderValidSessionKey).toBe("agent:main:clawline:user_1:main");
    expect(result.current.transition.bootRequestedSessionKey).toBeNull();
  });

  it("keeps the route-selected session engine-active until stream inventory proves otherwise", async () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: [],
        routeSessionKey: "agent:main:clawline:user_1:side",
        streams: [],
        transportPhase: "replaying"
      })
    );

    await waitFor(() => {
      expect(result.current.activeSessionKey).toBe("agent:main:clawline:user_1:side");
    });

    expect(result.current.activeSessionKey).toBe("agent:main:clawline:user_1:side");
    expect(result.current.routeSessionExists).toBe(false);
  });

  it("does not activate a fallback before router navigation commits it", async () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: ["agent:main:clawline:user_1:main"],
        routeSessionKey: undefined,
        streams: STREAMS,
        transportPhase: "replaying"
      })
    );

    await waitFor(() => {
      expect(result.current.firstProviderValidSessionKey).toBe("agent:main:clawline:user_1:main");
    });

    expect(result.current.activeSessionKey).toBeUndefined();
    expect(result.current.transition.bootRequestedSessionKey).toBeNull();
  });

  it("leaves a missing route inactive until route reconciliation commits a valid URL", async () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: ["agent:main:clawline:user_1:main"],
        routeSessionKey: "agent:main:clawline:user_1:missing",
        streams: STREAMS,
        transportPhase: "live"
      })
    );

    await waitFor(() => {
      expect(result.current.firstProviderValidSessionKey).toBe("agent:main:clawline:user_1:main");
    });

    expect(result.current.activeSessionKey).toBeUndefined();
    expect(result.current.routeSessionExists).toBe(false);
  });

  it("keeps existing unprovisioned route sessions active for unavailable-shell rendering", async () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: [],
        routeSessionKey: "agent:main:clawline:user_1:side",
        streams: STREAMS,
        transportPhase: "live"
      })
    );

    await waitFor(() => {
      expect(result.current.firstProviderValidSessionKey).toBe("agent:main:clawline:user_1:main");
    });

    expect(result.current.activeSessionKey).toBe("agent:main:clawline:user_1:side");
    expect(result.current.routeSessionExists).toBe(true);
  });

  it("keeps the current active session until router navigation commits the switch", async () => {
    const { result, rerender } = renderHook(
      ({ routeSessionKey, transportPhase }: CoordinatorHookProps) =>
        useChatSessionCoordinator({
          provisionedSessionKeys: STREAMS.map((stream) => stream.sessionKey),
          routeSessionKey,
          streams: STREAMS,
          transportPhase
        }),
      {
        initialProps: {
          routeSessionKey: "agent:main:clawline:user_1:main",
          transportPhase: "replaying"
        } satisfies CoordinatorHookProps
      }
    );

    act(() => {
      result.current.openSessionList();
      result.current.openStreamManager();
      result.current.requestSessionSwitch("agent:main:clawline:user_1:side", "popup");
    });

    expect(result.current.isSessionListOpen).toBe(false);
    expect(result.current.isStreamManagerOpen).toBe(false);
    expect(result.current.activeSessionKey).toBe("agent:main:clawline:user_1:main");
    expect(result.current.transition.source).toBe("popup");

    const rerenderCoordinator = rerender as (props: CoordinatorHookProps) => void;

    rerenderCoordinator({
      routeSessionKey: "agent:main:clawline:user_1:side",
      transportPhase: "live"
    });

    expect(result.current.activeSessionKey).toBe("agent:main:clawline:user_1:side");
  });

  it("owns popup and stream-manager visibility state directly", () => {
    const { result } = renderHook(() =>
      useChatSessionCoordinator({
        provisionedSessionKeys: STREAMS.map((stream) => stream.sessionKey),
        routeSessionKey: "agent:main:clawline:user_1:main",
        streams: STREAMS,
        transportPhase: "live"
      })
    );

    act(() => {
      result.current.openSessionList();
    });
    expect(result.current.isSessionListOpen).toBe(true);
    expect(result.current.isStreamManagerOpen).toBe(false);

    act(() => {
      result.current.openStreamManager();
    });
    expect(result.current.isSessionListOpen).toBe(false);
    expect(result.current.isStreamManagerOpen).toBe(true);

    act(() => {
      result.current.closeStreamManager();
      result.current.openSessionList();
      result.current.closeSessionList();
    });
    expect(result.current.isSessionListOpen).toBe(false);
    expect(result.current.isStreamManagerOpen).toBe(false);
  });
});
