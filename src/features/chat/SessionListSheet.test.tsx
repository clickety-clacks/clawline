import { readFileSync } from "node:fs";
import { fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import type { StreamRecord } from "../../runtime/chat/chatDomainStore";
import { parseStreamName, resolveStreamDisplayName, SessionListSheet } from "./SessionListSheet";

function streamRecord(input: {
  displayName: string;
  orderIndex?: number;
  sessionKey: string;
}): StreamRecord {
  return {
    createdAt: 10 + (input.orderIndex ?? 0),
    displayName: input.displayName,
    isBuiltIn: false,
    kind: "chat",
    orderIndex: input.orderIndex ?? 0,
    sessionKey: input.sessionKey,
    updatedAt: 10 + (input.orderIndex ?? 0)
  };
}

describe("SessionListSheet", () => {
  it("falls back to a readable name derived from the session key", () => {
    expect(
      resolveStreamDisplayName({
        displayName: "",
        sessionKey: "agent:main:clawline:flynn:research_notes"
      })
    ).toBe("Research Notes");
  });

  it("prefers the provider display name when one is present", () => {
    expect(
      resolveStreamDisplayName({
        displayName: "Personal",
        sessionKey: "agent:main:clawline:flynn:main"
      })
    ).toBe("Personal");
  });

  it("parses the trailing session segment into title case", () => {
    expect(parseStreamName("agent:main:clawline:flynn:side_thread")).toBe("Side Thread");
  });

  it("keeps the stream picker on a measured-width scrolling list", () => {
    const styleText = readFileSync("src/app/styles.css", "utf8");

    expect(styleText).toContain("--session-popover-content-width");
    expect(styleText).toContain(
      "max(18rem, calc(var(--session-popover-content-width, 0px) + 7.75rem))"
    );
    expect(styleText).toContain("width: 100%;");
    expect(styleText).toContain("overflow: auto;");
    expect(styleText).toContain("border-radius: 8px;");
  });

  it("keeps hidden row actions unfocusable and inoperable until swipe reveal", () => {
    const onRenameSession = vi.fn();
    const onDeleteSession = vi.fn();
    render(
      <SessionListSheet
        activeSessionKey="agent:main:clawline:flynn:main"
        filterQuery=""
        isOpen={true}
        onClose={vi.fn()}
        onCreateSession={vi.fn()}
        onDeleteSession={onDeleteSession}
        onFilterQueryChange={vi.fn()}
        onRenameSession={onRenameSession}
        onSelectSession={vi.fn()}
        provisionedSessionKeys={["agent:main:clawline:flynn:main"]}
        streamDotStateBySessionKey={{}}
        streams={[streamRecord({
          displayName: "Main",
          sessionKey: "agent:main:clawline:flynn:main"
        })]}
        transportPhase="live"
        unreadBySessionKey={{}}
      />
    );

    const renameButton = screen.getByRole("button", { name: "Rename", hidden: true });
    const deleteButton = screen.getByRole("button", { name: "Delete Main", hidden: true });

    expect(renameButton).toBeDisabled();
    expect(renameButton).toHaveAttribute("tabindex", "-1");
    expect(deleteButton).toBeDisabled();
    expect(deleteButton).toHaveAttribute("tabindex", "-1");

    fireEvent.click(renameButton);
    expect(onRenameSession).not.toHaveBeenCalled();
    expect(screen.queryByRole("textbox", { name: "Rename Main" })).toBeNull();

    const row = screen.getByRole("button", { name: /Main/ });
    fireEvent.pointerDown(row, { clientX: 200, clientY: 20 });
    fireEvent.pointerMove(row, { clientX: 40, clientY: 22 });
    fireEvent.pointerUp(row);

    expect(renameButton).not.toBeDisabled();
    expect(renameButton).toHaveAttribute("tabindex", "0");
    expect(deleteButton).not.toBeDisabled();
    expect(deleteButton).toHaveAttribute("tabindex", "0");

    fireEvent.click(renameButton);
    expect(screen.getByRole("textbox", { name: "Rename Main" })).toBeInTheDocument();
  });

  it("keeps the popup open and focuses inline rename after Add creates and selects a chat", async () => {
    const onClose = vi.fn();
    const onFilterQueryChange = vi.fn();
    const onSelectSession = vi.fn();
    const createdStream = streamRecord({
      displayName: "New Chat",
      orderIndex: 1,
      sessionKey: "agent:main:clawline:flynn:new_chat"
    });

    function Harness() {
      const [streams, setStreams] = useState([
        streamRecord({
          displayName: "Main",
          sessionKey: "agent:main:clawline:flynn:main"
        })
      ]);

      return (
        <SessionListSheet
          activeSessionKey="agent:main:clawline:flynn:new_chat"
          filterQuery="zzz"
          isOpen={true}
          onClose={onClose}
          onCreateSession={async () => {
            setStreams((current) => [...current, createdStream]);
            return createdStream;
          }}
          onDeleteSession={vi.fn()}
          onFilterQueryChange={onFilterQueryChange}
          onRenameSession={vi.fn()}
          onSelectSession={onSelectSession}
          provisionedSessionKeys={[
            "agent:main:clawline:flynn:main",
            "agent:main:clawline:flynn:new_chat"
          ]}
          streamDotStateBySessionKey={{}}
          streams={streams}
          transportPhase="live"
          unreadBySessionKey={{}}
        />
      );
    }

    render(<Harness />);

    fireEvent.click(screen.getByRole("button", { name: "Add chat" }));

    const renameInput = await screen.findByRole("textbox", { name: "Rename New Chat" });
    expect(screen.getByTestId("session-popover")).toBeInTheDocument();
    expect(renameInput).toHaveFocus();
    expect(renameInput).toHaveValue("New Chat");
    expect(onFilterQueryChange).toHaveBeenCalledWith("");
    expect(onSelectSession).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });
});
