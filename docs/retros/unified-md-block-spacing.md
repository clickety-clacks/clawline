# Unified Markdown Block Spacing Retro (T057 Bounce)

Date: 2026-02-19
Branch: `unified-md`
Scope: Why block-level spacing regressed for non-widget markdown content, and what boundary change fixes it.

## Summary

Block spacing regressed because the unified parser collapsed multiple top-level markdown block nodes into a single `.richText(markdownSource:)` payload before rendering. The renderer then fed that merged markdown through `AttributedString(markdown:, interpretedSyntax: .full)`, which flattens many block separators when converted/displayed in our attributed-text views. Since tables/code are rendered through dedicated UIKit views, they retained spacing while heading/paragraph/list/blockquote/thematic-break content lost vertical separation.

This is an ownership/seam miss: block separation was implicitly delegated to markdown string formatting/parsing behavior instead of being represented as explicit render blocks in our own pipeline.

## Architecture-Principles Audit

### 1. Pattern propagation

The parser established a "merge contiguous rich text" pattern. Everything downstream copied that shape: one attributed payload represented many logical blocks.

### 2. Separation of concerns

`UnifiedMarkdownParser` should own structural segmentation of top-level blocks. Instead, it merged top-level blocks and relied on the renderer/`AttributedString` implementation to preserve visual structure.

### 3. Mutation seam discipline

Spacing responsibility was split:
- Parser mutated block boundaries via merge.
- Renderer interpreted merged markdown and mutated whitespace semantics.
- UI views only rendered resulting attributed runs.

No single seam guaranteed "one top-level markdown block maps to one text render block." That made spacing fragile.

## End-to-End Pipeline Audit (where separation should happen)

## A. `Document(parsing:)` (source of truth)

Top-level children already encode block boundaries (heading, paragraph, list, blockquote, thematic break, etc.).

Expected spacing responsibility:
- Preserve each top-level non-widget node as an independent render unit unless explicitly transformed by spec.

## B. `UnifiedMarkdownParser.parse` (old behavior)

Previous T057 behavior:
- Buffered contiguous non-code/non-table children.
- Joined their `.format()` output using `"\n\n"`.
- Emitted one `.richText` for the merged region.

Why this failed:
- Structural boundaries became text delimiters inside a single markdown string.
- Renderer no longer knew block edges as first-class units.

## C. `UnifiedMarkdownRenderer.renderNSAttributedString`

Behavior:
- Used `AttributedString(markdown:, .full)` first.
- Applied typography/color adjustments to resulting attributed text.

Observed issue:
- In merged rich-text payloads, `.full` parsing collapses/normalizes block separators for several block combinations.
- Resulting attributed text can visually behave like one inline run.

Expected spacing responsibility:
- Renderer styles content; it should not be the only layer preserving block boundaries.

## D. Bubble + Expanded consumers

`MessageBubbleUIKitView` and `ExpandedMessageSheet` render `[RenderedMarkdownBlock]` in order.

Good:
- They can provide separation between distinct attributed blocks (stack spacing / separate text containers).

Limitation before fix:
- Parser often provided only one attributed block for all non-widget content, so UI had no block boundaries to space.

## Root Cause

Primary root cause: parser-level block-boundary collapse.

Contributing factor: renderer reliance on markdown->attributed conversion semantics for spacing preservation.

Not root cause:
- Dedicated table/code block views (these remained correctly separated).

## Fix Strategy

1. Parser emits one `.richText` block per top-level non-code/non-table AST child (no contiguous merge buffer).
2. Renderer continues styling each `.richText` block.
3. Bubble/expanded keep rendering ordered blocks; spacing now comes from explicit block boundaries.
4. Add an interleaved all-block-types regression test asserting:
- shared sequence across bubble/expanded,
- many attributed blocks (not one collapsed run),
- expected content is present and in source order.

## Why this is the right seam

This restores a clean mutation seam:
- Structural segmentation is decided once in `UnifiedMarkdownParser` from AST boundaries.
- Renderer only transforms style for each block.
- UI layers only lay out blocks.

That boundary prevents recurrence of "everything became one attributed run" regressions.

## Second Bounce Addendum (Bubble-Layer Re-merge)

After parser boundary fixes, device behavior still collapsed block spacing in bubbles because the bubble view had a second merge layer.

What happened:

1. `MessageBubbleUIKitView.configure` pre-populated `bodyLabel` using `combinedMarkdownText(from: renderedMarkdownBlocks)`.
2. That helper concatenated all `.attributedText` blocks into one attributed run separated by literal `"\n\n"`.
3. `salientBaseAttributedText` was captured from that merged body label before block layout.
4. Salient highlight application could then reapply the merged attributed run to `bodyLabel`, effectively bypassing per-block layout intent.

Why parser fix alone was insufficient:

- Parser now emitted proper top-level rich-text block boundaries.
- Bubble rendering still had an independent mutation path that reintroduced merge semantics in the view layer.

Boundary correction (v2):

1. Remove merged baseline path from visible text setup (no `combinedMarkdownText` primary usage).
2. `addRenderedMarkdownBlocks()` is the only non-emoji path that sets visible text content.
3. Set `salientBaseAttributedText` from the primary attributed block chosen inside `addRenderedMarkdownBlocks()`, so salient highlighting tracks per-block content instead of a synthetic merged string.
4. Keep chromeless emoji as a dedicated branch with its own single text container.

Resulting invariant:

- For non-emoji markdown text, bubble visible content is sourced exclusively from ordered rendered blocks, one text container per block (primary + supplemental containers), with no hidden re-merge stage.
