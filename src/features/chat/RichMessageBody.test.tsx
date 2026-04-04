import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { RichMessageBody } from "./RichMessageBody";
import { preprocessDoubleEqualsHighlights } from "./markdownHighlight";

describe("RichMessageBody", () => {
  it("preprocesses double-equals highlights outside code only", () => {
    const content = [
      "Please ==watch this== carefully.",
      "",
      "`==not inline==`",
      "",
      "```ts",
      "const value = '==not fenced==';",
      "```"
    ].join("\n");

    const normalized = preprocessDoubleEqualsHighlights(content);

    expect(normalized).toContain("\u{E000}watch this\u{E001}");
    expect(normalized).toContain("`==not inline==`");
    expect(normalized).toContain("const value = '==not fenced==';");
  });

  it("renders double-equals highlights as mark elements while preserving nested markdown", () => {
    render(<RichMessageBody content={"before ==bright *signal*== after"} />);

    const mark = screen.getByText("bright").closest("mark");
    expect(mark).not.toBeNull();
    expect(mark).toHaveTextContent("bright signal");
    expect(within(mark as HTMLElement).getByText("signal").tagName).toBe("EM");
  });

  it("does not render mark elements for inline code or fenced code markers", () => {
    render(
      <RichMessageBody
        content={[
          "==outside==",
          "",
          "`==inside inline code==`",
          "",
          "```ts",
          "const label = '==inside fence==';",
          "```"
        ].join("\n")}
      />
    );

    expect(screen.getAllByText("outside")[0].closest("mark")).not.toBeNull();
    expect(screen.getByText("==inside inline code==").closest("mark")).toBeNull();
    expect(screen.getByText("const label = '==inside fence==';").closest("mark")).toBeNull();
  });
});
