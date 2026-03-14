# Unified Markdown — Non-Obvious Details

## `MarkdownRenderPlan` is built ONCE per message and reused by both surfaces
The same `MarkdownRenderPlan` (ordered block sequence) drives both the bubble view and the expanded sheet. Surface difference is render options only — not parse logic. Any code that re-parses markdown independently for expanded view re-introduces the dropped-content and ordering bugs (#48, #50).

## Block ordering is strict source order — not split by type
`MarkdownRenderPlan.blocks` preserves the original markdown document order. A text paragraph followed by a code block followed by text must appear in that exact order in both surfaces. Prior code split rendering by type (all text first, then all code blocks), which was the root of #48.

## `==highlight==` syntax is kept in the unified renderer
The custom `==highlight==` syntax for salient highlighting is preserved as part of the unified parse pass. It must not be stripped or treated as unknown markup. Not obvious from the cmark-gfm baseline.
