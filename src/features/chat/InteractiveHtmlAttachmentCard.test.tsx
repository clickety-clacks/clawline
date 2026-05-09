import { act, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { TransportMachine } from "../../runtime/transport/transportMachine";
import { INTERACTIVE_HTML_ATTACHMENT_MIME } from "../../protocol/interactive-html-wire";
import { renderWithProviders } from "../../test/support/renderWithProviders";
import { InteractiveHtmlAttachmentCard } from "./InteractiveHtmlAttachmentCard";

function makeTransportStore(sendInteractiveCallback = vi.fn(async () => {})): TransportMachine {
  const state = {
    failureReason: null,
    isBrowserOnline: true,
    phase: "live" as const,
    retryAttempt: 0
  };

  return {
    getState() {
      return state;
    },
    retryNow() {},
    async publishReadState() {},
    sendInteractiveCallback,
    async sendMessage() {},
    subscribe() {
      return () => {};
    }
  };
}

function makeAttachment(html: string) {
  return {
    type: "document" as const,
    mimeType: INTERACTIVE_HTML_ATTACHMENT_MIME,
    data: btoa(
      JSON.stringify({
        version: 1,
        html,
        metadata: {
          title: "Interactive Demo",
          height: "auto",
          maxHeight: 360
        }
      })
    )
  };
}

function bridgeTokenFor(iframe: HTMLIFrameElement) {
  const srcDoc = iframe.getAttribute("srcdoc") ?? "";
  const match = srcDoc.match(/const token = "([^"]+)";/);
  if (!match) {
    throw new Error("Missing bridge token");
  }
  return match[1];
}

function postInteractiveMessage(
  iframe: HTMLIFrameElement,
  payload: Record<string, unknown>
) {
  const source = iframe.contentWindow;
  if (!source) {
    throw new Error("Interactive iframe has no contentWindow");
  }

  window.dispatchEvent(
    new MessageEvent("message", {
      data: {
        __clawlineInteractiveHtml: true,
        token: bridgeTokenFor(iframe),
        ...payload
      },
      source
    })
  );
}

async function flushEffects() {
  await act(async () => {
    await Promise.resolve();
  });
}

describe("InteractiveHtmlAttachmentCard", () => {
  it("injects sandboxing, CSP, and bridge scaffolding", () => {
    const transportStore = makeTransportStore();
    renderWithProviders(
      <InteractiveHtmlAttachmentCard
        attachment={makeAttachment("<body><p>Hello</p></body>")}
        messageId="s_html_1"
      />,
      { transportMachine: transportStore }
    );

    const iframe = screen.getByTestId("interactive-html-frame-s_html_1");
    expect(iframe).toHaveAttribute("sandbox", "allow-scripts");
    expect(iframe.getAttribute("sandbox")).not.toContain("allow-same-origin");

    const srcDoc = iframe.getAttribute("srcdoc") ?? "";
    expect(srcDoc).toContain("Content-Security-Policy");
    expect(srcDoc).toContain("connect-src 'none'");
    expect(srcDoc).toContain("window.webkit.messageHandlers.clawline");
    expect(srcDoc).toContain("window.Clawline = bridge");
  });

  it("accepts allowed bridge actions, locks one resize, and ignores foreign messages", async () => {
    const sendInteractiveCallback = vi.fn(async () => {});
    const transportStore = makeTransportStore(sendInteractiveCallback);
    renderWithProviders(
      <InteractiveHtmlAttachmentCard
        attachment={makeAttachment("<body><p>Hello</p></body>")}
        messageId="s_html_2"
      />,
      { transportMachine: transportStore }
    );

    const iframe = screen.getByTestId("interactive-html-frame-s_html_2") as HTMLIFrameElement;
    await flushEffects();

    act(() => {
      window.dispatchEvent(
        new MessageEvent("message", {
          data: {
            __clawlineInteractiveHtml: true,
            token: "wrong-token",
            kind: "bridge",
            action: "ping",
            data: { value: 99 }
          },
          source: iframe.contentWindow as Window
        })
      );
    });
    expect(sendInteractiveCallback).not.toHaveBeenCalled();

    act(() => {
      postInteractiveMessage(iframe, { kind: "measure", height: 180 });
    });
    expect(iframe.style.height).toBe("180px");

    act(() => {
      postInteractiveMessage(iframe, {
        kind: "bridge",
        action: "ping",
        data: { value: 7 }
      });
    });
    expect(sendInteractiveCallback).toHaveBeenCalledWith({
      action: "ping",
      data: { value: 7 },
      messageId: "s_html_2"
    });

    act(() => {
      postInteractiveMessage(iframe, {
        kind: "bridge",
        action: "_resize",
        height: 320
      });
    });
    expect(iframe.style.height).toBe("320px");

    act(() => {
      postInteractiveMessage(iframe, {
        kind: "bridge",
        action: "_resize",
        height: 120
      });
    });
    expect(iframe.style.height).toBe("320px");
  });

  it("replaces the iframe with the close summary", async () => {
    const transportStore = makeTransportStore();
    renderWithProviders(
      <InteractiveHtmlAttachmentCard
        attachment={makeAttachment("<body><p>Hello</p></body>")}
        messageId="s_html_3"
      />,
      { transportMachine: transportStore }
    );

    const iframe = screen.getByTestId("interactive-html-frame-s_html_3") as HTMLIFrameElement;
    await flushEffects();
    act(() => {
      postInteractiveMessage(iframe, {
        kind: "bridge",
        action: "_close",
        summary: "Closed summary"
      });
    });

    expect(screen.queryByTestId("interactive-html-frame-s_html_3")).not.toBeInTheDocument();
    expect(screen.getByText("Closed summary")).toBeInTheDocument();
  });
});
