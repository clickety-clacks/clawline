import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useChatSessionInteractionCoordinator } from "./useChatSessionCoordinator";

function installVisualViewportStub() {
  const listeners = new Map<string, Set<EventListener>>();
  let height = 844;
  let offsetTop = 0;

  const visualViewport = {
    get height() {
      return height;
    },
    get offsetTop() {
      return offsetTop;
    },
    get width() {
      return 390;
    },
    addEventListener(type: string, listener: EventListener) {
      const bucket = listeners.get(type) ?? new Set<EventListener>();
      bucket.add(listener);
      listeners.set(type, bucket);
    },
    removeEventListener(type: string, listener: EventListener) {
      listeners.get(type)?.delete(listener);
    }
  };

  const dispatch = (type: string) => {
    const event = new Event(type);
    for (const listener of listeners.get(type) ?? []) {
      listener.call(visualViewport, event);
    }
  };

  Object.defineProperty(window, "visualViewport", {
    configurable: true,
    get() {
      return visualViewport;
    }
  });

  return {
    setInset(nextInset: number) {
      height = Math.max(0, 844 - nextInset);
      offsetTop = 0;
      dispatch("resize");
      dispatch("scroll");
    }
  };
}

describe("useChatSessionInteractionCoordinator", () => {
  beforeEach(() => {
    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: 844
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    document.body.innerHTML = "";
  });

  it("routes popup selection through the interaction seam", () => {
    const onSelectSession = vi.fn();
    const { result } = renderHook(() =>
      useChatSessionInteractionCoordinator({
        activeSessionKey: "agent:main:clawline:user_1:main",
        onSelectSession,
        orderedSessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:clawline:user_1:side"
        ]
      })
    );

    act(() => {
      result.current.handlePopupSessionSelect("agent:main:clawline:user_1:side");
    });

    expect(onSelectSession).toHaveBeenCalledWith(
      "agent:main:clawline:user_1:side",
      "popup"
    );
  });

  it("owns swipe gesture gating and emits adjacent session switches", () => {
    const onSelectSession = vi.fn();
    const { result } = renderHook(() =>
      useChatSessionInteractionCoordinator({
        activeSessionKey: "agent:main:clawline:user_1:main",
        onSelectSession,
        orderedSessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:main",
          "agent:main:clawline:user_1:side"
        ]
      })
    );

    const swipeTarget = document.createElement("div");

    act(() => {
      result.current.handleChatPanelTouchStart({
        target: swipeTarget,
        touch: { clientX: 280, clientY: 260 }
      });
      result.current.handleChatPanelTouchEnd({
        touch: { clientX: 120, clientY: 250 }
      });
    });

    expect(onSelectSession).toHaveBeenCalledWith("agent:main:main", "swipe");
  });

  it("ignores swipe gestures that begin on interactive controls", () => {
    const onSelectSession = vi.fn();
    const { result } = renderHook(() =>
      useChatSessionInteractionCoordinator({
        activeSessionKey: "agent:main:clawline:user_1:main",
        onSelectSession,
        orderedSessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:main"
        ]
      })
    );

    const button = document.createElement("button");

    act(() => {
      result.current.handleChatPanelTouchStart({
        target: button,
        touch: { clientX: 280, clientY: 260 }
      });
      result.current.handleChatPanelTouchEnd({
        touch: { clientX: 120, clientY: 250 }
      });
    });

    expect(onSelectSession).not.toHaveBeenCalled();
  });

  it("tracks keyboard inset and disables swipe while the composer is focused", async () => {
    const viewport = installVisualViewportStub();
    const onSelectSession = vi.fn();
    const composer = document.createElement("textarea");
    composer.id = "composer-input";
    document.body.appendChild(composer);

    const { result } = renderHook(() =>
      useChatSessionInteractionCoordinator({
        activeSessionKey: "agent:main:clawline:user_1:main",
        onSelectSession,
        orderedSessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:main"
        ]
      })
    );

    act(() => {
      composer.focus();
      window.dispatchEvent(new FocusEvent("focusin"));
      viewport.setInset(280);
    });

    await waitFor(() => {
      expect(result.current.keyboardInset).toBe(280);
    });

    expect(result.current.shouldEnableSwipeNavigation).toBe(false);
    expect(result.current.layoutStyle).toMatchObject({
      "--chat-keyboard-inset": "280px"
    });
  });

  it("does not add extra keyboard inset when the layout viewport already matches the visual viewport", async () => {
    const viewport = installVisualViewportStub();
    const originalInnerHeight = window.innerHeight;
    const onSelectSession = vi.fn();
    const composer = document.createElement("textarea");
    composer.id = "composer-input";
    document.body.appendChild(composer);

    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: 564
    });

    const { result } = renderHook(() =>
      useChatSessionInteractionCoordinator({
        activeSessionKey: "agent:main:clawline:user_1:main",
        onSelectSession,
        orderedSessionKeys: [
          "agent:main:clawline:user_1:main",
          "agent:main:main"
        ]
      })
    );

    act(() => {
      composer.focus();
      window.dispatchEvent(new FocusEvent("focusin"));
      viewport.setInset(280);
    });

    await waitFor(() => {
      expect(result.current.keyboardInset).toBe(0);
    });

    Object.defineProperty(window, "innerHeight", {
      configurable: true,
      value: originalInnerHeight
    });
  });
});
