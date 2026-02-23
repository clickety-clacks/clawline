# Unified Markdown Architecture Assessment (T057)

Date: 2026-02-19
Branch: `unified-md`
Scope: Raw markdown string -> parser -> render plan -> rendered blocks -> bubble/expanded UI pixels.

## 1. End-to-End Data Flow

1. Raw message text enters `MessagePresentationBuilder.build`.
2. Builder calls `UnifiedMarkdownParser.parse(markdown:messageID:metrics:)` (`ios/Clawline/Clawline/Models/MessagePresentation.swift:291`).
3. Parser builds `MarkdownRenderPlan` blocks (`.richText`, `.code`, `.table`) using `swift-markdown` `Document` top-level children (`ios/Clawline/Clawline/Models/UnifiedMarkdownParser.swift:14-63`).
4. Builder converts plan blocks into legacy `MessagePart` values for broader app policy/sizing/chromeless decisions (`ios/Clawline/Clawline/Models/MessagePresentation.swift:321-347`).
5. Bubble and expanded both render from `presentation.markdownRenderPlan` via `UnifiedMarkdownRenderer.render(...)`:
- Bubble: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:621-624`
- Expanded: `ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift:153-166`
6. Renderer converts each `.richText` markdown source into `NSAttributedString` and passes `.code`/`.table` through (`ios/Clawline/Clawline/Views/Chat/UnifiedMarkdownRenderer.swift:8-40`).
7. Bubble lays out each rendered block using `addRenderedMarkdownBlocks(...)` with separate views per block (`ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:1380-1424`).
8. Expanded lays out each rendered block via SwiftUI `ForEach` (`ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift:97-122`).

## 2. Transformation Inventory (merge/split/mutate points)

I counted 13 material transformation points.

### Parse stage

1. **AST split:** top-level `Document.children` become distinct plan blocks (`UnifiedMarkdownParser.swift:24-40`).
2. **Rich text canonicalization:** each non-code/non-table child is stringified with `child.format()` and trimmed (`UnifiedMarkdownParser.swift:17-21,39`).
3. **Table conversion:** `Table` AST -> `TableModel`, with fallback to rich text (`UnifiedMarkdownParser.swift:30-35,108-229`).
4. **Plan plain-text metrics merge:** all blocks collapse into one metrics string for word count/flags (`UnifiedMarkdownParser.swift:42-47`).
5. **Emoji classification (plan-level):** `isEmojiOnly` inferred from all plan blocks and markdown-stripped plain text (`UnifiedMarkdownParser.swift:49-56,90-106`).

### Presentation-builder stage

6. **Plan -> legacy parts projection:** rich text becomes either `.markdown` or `.inlineEmoji`; code/table preserved as parts (`MessagePresentation.swift:321-344`).
7. **URL extraction merge:** URLs extracted from rich-text sources into occurrence + unique lists (`MessagePresentation.swift:325,349-357`).
8. **Secondary emoji classification (legacy):** builder re-detects emoji using `isEmojiOnly(_:)` (`MessagePresentation.swift:331-334,1135-1139`).

### Renderer stage

9. **Markdown -> attributed conversion:** `.richText` uses `AttributedString(markdown:, .full)` fallback `.inlineOnlyPreservingWhitespace` (`UnifiedMarkdownRenderer.swift:53-60`).
10. **Typography/style mutation:** renderer rewrites fonts/colors/paragraph styles and injects heading style overrides (`UnifiedMarkdownRenderer.swift:62-105,304-396`).
11. **URL stripping mutation (bubble option):** optional URL removal + trim + newline-collapse (`\n{3,} -> \n\n`) (`UnifiedMarkdownRenderer.swift:30-33,122-151`).
12. **Highlight syntax mutation:** sentinel preprocessing + in-place range replacement for `==...==` (`UnifiedMarkdownRenderer.swift:186-292,153-184`).

### Surface/layout stage

13. **Block-to-view split:** bubble and expanded materialize each rendered block into separate UI units (bubble `UITextView`/supplementals/code/table views; expanded `SelectableAttributedText`/code/table views).

## 3. Ownership Boundaries (Current)

## Parser (`UnifiedMarkdownParser`)

Owns:
- Top-level structural segmentation from markdown AST.
- Table model creation + fallback.
- Plan-level textual metrics (`plainTextForMetrics`) and one emoji-only flag.

Does not own:
- Surface-specific style and link stripping.
- Bubble/expanded layout decisions.

## Renderer (`UnifiedMarkdownRenderer`)

Owns:
- Markdown-to-attributed conversion for rich text.
- Surface option divergence (URL stripping, mark highlight color).
- Inline style normalization and heading emphasis.

Does not own:
- Higher-level layout spacing between rendered blocks.
- Attachment/link-card/media ordering.

## Bubble/Expanded views

Own:
- Physical view composition (stack ordering, per-block containers, code/table widgets).
- Surface interaction concerns (selection, link taps, expand behavior, salient highlight application in bubble).

Do not own:
- Markdown parse semantics.

## Actual boundary violation still present

`MessagePresentationBuilder` still re-classifies content from plan blocks into legacy part semantics (notably emoji and textual block semantics), so unified ownership is not complete.

## 4. Redundant Paths / Legacy Debt

## 4.1 Dead pre-unified parser path still in `MessagePresentationBuilder`

`processTextSegment(...)` and its dependency chain (`parseTable`, `splitRow`, `shouldBufferTableCandidate`, `looksLikeMarkdown`, `Segmenter`, etc.) remain in file but are no longer called from `build`.

Evidence:
- `processTextSegment` declaration exists (`MessagePresentation.swift:402`) but no call site in repo.
- All line-based table/fence logic under this path is effectively dead code.

Impact:
- Increases cognitive load during debugging.
- Creates false confidence because there are now two parser designs in one file (AST parser active, line parser inert).

## 4.2 Dual emoji-only decision paths still active

1. Plan-level `isEmojiOnly` (`UnifiedMarkdownParser.isEmojiOnlyText`) with 1..3 character bound.
2. Builder-level `isEmojiOnly(_:)` that checks `trimmed.allSatisfy { $0.isEmoji }` without the same bound semantics.

Then bubble/expanded still use legacy `.inlineEmoji` and `chromelessStyle` checks in places.

Impact:
- Multiple non-identical definitions of "emoji-only" can diverge by input shape.

## 4.3 Legacy `MessagePart` still drives size/chrome heuristics

Examples:
- `MessageFlowRules.hasBlockContent/hasMultipleTextBlocks` inspect `parts`, not render plan (`MessageFlowRules.swift:47-61`).
- Bubble text measurement uses `textContent(from: presentation)` built from `parts` (`MessageBubbleUIKitView.swift:1455-1477,1602-1663`).

Impact:
- Sizing behavior can drift from what unified renderer actually outputs.

## 5. What Broke Twice (Block Spacing) and Why

## First break

- Non-widget markdown blocks were merged before rendering (old parser behavior).
- A single attributed run represented many logical block nodes.
- Block spacing relied on markdown string interpretation side effects rather than explicit layout units.

## First fix

- Parser changed to emit one `.richText` per top-level AST child.

## Second break

- Bubble had an independent merge seam in view layer (pre-v2): it precombined attributed blocks for baseline text/highlight state.
- Even with parser fixed, bubble could still collapse to one visible attributed run.

## Why it survived the first fix

- The first fix corrected the parser seam only.
- A second hidden mutation seam in bubble was not included in the initial boundary audit.
- This is a classic split-seam failure: same state (visible text composition) had more than one write path across layers.

## 6. Fragility Map (What Else Looks Brittle)

1. **Split ownership between plan and legacy parts:** unified plan exists, but many downstream decisions still rely on `MessagePart` projection.
2. **Emoji classification duplication:** parser and builder logic are different and both still influence rendering/chrome behavior.
3. **Renderer text semantics depend on `AttributedString(.full)` behavior:** platform parser normalization of block whitespace remains a risk surface.
4. **Heading restyling is string-search based:** `applyHeadingStyles` finds heading text in rendered string post-parse, which can mis-target repeated text tokens (`UnifiedMarkdownRenderer.swift:313-359`).
5. **Bubble salient highlighting only targets primary text container:** multi-block text only has first block highlight-managed (`MessageBubbleUIKitView.swift:1394-1404,1042-1095`).
6. **Sizing uses legacy text flattening:** `textContent(from:)` joins parts with `\n\n`, independent of rendered block reality; can mis-estimate complex markdown sizes (`MessageBubbleUIKitView.swift:1455-1477`).
7. **Dead code retained in core builder file:** makes it easy to patch wrong path under incident pressure.
8. **Expanded emoji path still depends on legacy `.inlineEmoji` parts:** shared ownership instead of plan-only ownership (`ExpandedMessageSheet.swift:169-177`).

## 7. Recommended Boundary Model (Assessment Outcome)

The intended unified architecture is mostly present but not fully enforced. A stricter model would be:

1. Parser is sole owner of structural + text-mode classification.
2. Renderer is sole owner of rich-text attributed transformation.
3. Surfaces only layout rendered blocks and apply surface-local interaction styling.
4. Legacy `MessagePart` remains for non-markdown attachments/media routing only, not markdown text semantics.

Until those boundaries are fully enforced, regressions like spacing/emoji divergence can recur through cross-layer re-interpretation.

## 8. Confidence

High confidence on:
- Double-break root cause chain.
- Dead pre-unified path presence.
- Remaining split ownership seams.

Medium confidence on:
- Frequency/impact of heading restyling mis-target in production content (identified as a plausible fragility, not a reproduced incident).
