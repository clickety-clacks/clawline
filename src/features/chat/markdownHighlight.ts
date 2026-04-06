import { visit } from "unist-util-visit";

const MARK_OPEN_SENTINEL = "\u{E000}";
const MARK_CLOSE_SENTINEL = "\u{E001}";

type MarkdownParent = {
  children?: MarkdownNode[];
  data?: {
    hName?: string;
  };
  type: string;
};

type MarkdownText = {
  type: "text";
  value: string;
};

type MarkdownNode = MarkdownParent | MarkdownText;

function isTextNode(node: MarkdownNode): node is MarkdownText {
  return node.type === "text";
}

function countConsecutiveBackticks(characters: string[], start: number) {
  let count = 0;
  while (start + count < characters.length && characters[start + count] === "`") {
    count += 1;
  }
  return count;
}

export function preprocessDoubleEqualsHighlights(markdown: string) {
  const characters = Array.from(markdown);
  if (characters.length < 4) {
    return markdown;
  }

  const delimiterPositions: number[] = [];
  let index = 0;
  let inFence = false;
  let inlineCodeDelimiterLength: number | null = null;
  let isLineStart = true;

  while (index < characters.length) {
    const character = characters[index];

    if (character === "\n") {
      isLineStart = true;
      index += 1;
      continue;
    }

    if (character === "`") {
      const tickCount = countConsecutiveBackticks(characters, index);

      if (inlineCodeDelimiterLength === null && tickCount >= 3 && isLineStart) {
        inFence = !inFence;
        index += tickCount;
        isLineStart = false;
        continue;
      }

      if (!inFence) {
        if (inlineCodeDelimiterLength !== null) {
          if (tickCount === inlineCodeDelimiterLength) {
            inlineCodeDelimiterLength = null;
            index += tickCount;
            isLineStart = false;
            continue;
          }
        } else {
          inlineCodeDelimiterLength = tickCount;
          index += tickCount;
          isLineStart = false;
          continue;
        }
      }

      index += tickCount;
      isLineStart = false;
      continue;
    }

    if (
      !inFence &&
      inlineCodeDelimiterLength === null &&
      character === "=" &&
      index + 1 < characters.length &&
      characters[index + 1] === "="
    ) {
      delimiterPositions.push(index);
      index += 2;
      isLineStart = false;
      continue;
    }

    if (character !== " " && character !== "\t" && character !== "\r") {
      isLineStart = false;
    }
    index += 1;
  }

  let open: number | null = null;
  const pairs: Array<{ open: number; close: number }> = [];
  for (const delimiter of delimiterPositions) {
    if (open === null) {
      open = delimiter;
      continue;
    }

    if (delimiter > open + 2) {
      pairs.push({ open, close: delimiter });
      open = null;
      continue;
    }

    open = delimiter;
  }

  if (pairs.length === 0) {
    return markdown;
  }

  const replacements = new Map<number, string>();
  for (const pair of pairs) {
    replacements.set(pair.open, MARK_OPEN_SENTINEL);
    replacements.set(pair.close, MARK_CLOSE_SENTINEL);
  }

  let output = "";
  index = 0;
  while (index < characters.length) {
    const replacement = replacements.get(index);
    if (replacement) {
      output += replacement;
      index += 2;
      continue;
    }

    output += characters[index];
    index += 1;
  }

  return output;
}

function createTextNode(value: string): MarkdownText {
  return {
    type: "text",
    value
  };
}

function createMarkNode(children: MarkdownNode[]): MarkdownParent {
  return {
    type: "mark",
    data: {
      hName: "mark"
    },
    children
  };
}

function splitSentinelText(value: string) {
  return value.split(new RegExp(`(${MARK_OPEN_SENTINEL}|${MARK_CLOSE_SENTINEL})`, "g"));
}

function transformChildren(children: MarkdownNode[]) {
  const output: MarkdownNode[] = [];
  let highlightedChildren: MarkdownNode[] | null = null;

  const pushNode = (node: MarkdownNode) => {
    if (highlightedChildren) {
      highlightedChildren.push(node);
      return;
    }
    output.push(node);
  };

  for (const child of children) {
    if (isTextNode(child)) {
      const segments = splitSentinelText(child.value);
      for (const segment of segments) {
        if (!segment) {
          continue;
        }

        if (segment === MARK_OPEN_SENTINEL) {
          if (!highlightedChildren) {
            highlightedChildren = [];
          }
          continue;
        }

        if (segment === MARK_CLOSE_SENTINEL) {
          if (highlightedChildren && highlightedChildren.length > 0) {
            output.push(createMarkNode(highlightedChildren));
          }
          highlightedChildren = null;
          continue;
        }

        pushNode(createTextNode(segment));
      }
      continue;
    }

    pushNode(child);
  }

  if (highlightedChildren && highlightedChildren.length > 0) {
    output.push(createTextNode(MARK_OPEN_SENTINEL));
    output.push(...highlightedChildren);
  }

  return output;
}

export function remarkDoubleEqualsHighlight() {
  return function transform(tree: MarkdownNode) {
    visit(tree, (node) => {
      return Array.isArray((node as MarkdownParent).children);
    }, (node) => {
      const parent = node as MarkdownParent;
      if (!parent.children) {
        return;
      }

      parent.children = transformChildren(parent.children);
    });
  };
}
