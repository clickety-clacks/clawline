# T057: Unified Markdown Rendering in Clawline iOS

Status: Implementation-ready (trimmed)
Last updated: 2026-02-16
Owner: Spec agent (SME)
Related issues: #48, #50
Decision record: Flynn decision on 2026-02-07 to use `swiftlang/swift-markdown` (cmark-gfm)

## 1. Goal

Unify markdown rendering into one path used by both:

1. Bubble view (`MessageBubbleUIKitView`)
2. Expanded sheet (`ExpandedMessageSheet`)

Success criteria:

1. One parser/renderer pipeline for both surfaces.
2. Correct source ordering across text/code/table blocks (#48).
3. No dropped markdown content in expanded view (#48).
4. Code fences do not regress to plain text (#50).

## 2. Scope and Non-Goals

In scope:

1. Replace split markdown paths with one shared parse/render flow.
2. Use `swift-markdown` AST as the source of truth.
3. Keep `==highlight==` behavior in the unified renderer.

Out of scope:

1. Visual redesign.
2. Rewriting non-markdown attachment/media rendering.
3. Single-`UITextView` architecture work.

## 3. Architecture

### 3.1 Pipeline

```text
raw markdown
  -> UnifiedMarkdownParser (swift-markdown AST)
  -> MarkdownRenderPlan (ordered logical blocks)
  -> UnifiedMarkdownRenderer (surface options)
  -> [RenderedMarkdownBlock]
  -> consumed by bubble and expanded
```

Invariants:

1. `MarkdownRenderPlan` is built once per message presentation and reused by both surfaces.
2. Bubble and expanded consume the same ordered block sequence.
3. Surface difference is options only (not parse logic).

### 3.2 Data model

```swift
enum MarkdownRenderBlock: Equatable {
    case richText(markdownSource: String)
    case code(language: String?, code: String)
    case table(TableModel)
}

struct MarkdownRenderPlan: Equatable {
    let blocks: [MarkdownRenderBlock]     // strict source order
    let plainTextForMetrics: String       // word count / accessibility text input
    let containsTextualContent: Bool
    let isEmojiOnly: Bool
}

struct MarkdownRenderOptions: Equatable {
    let baseFont: UIFont
    let inkColor: UIColor
    let lineSpacing: CGFloat
    let stripDetectedURLs: Bool
    let markHighlightColor: UIColor?
}

enum RenderedMarkdownBlock: Equatable {
    case attributedText(NSAttributedString)
    case code(language: String?, code: String)
    case table(TableModel)
}
```

`TableModel` note:

1. Use the existing `TableModel` already defined in `ios/Clawline/Clawline/Models/MessagePresentation.swift`.
2. Do not introduce a new `TableModel` type for T057.

### 3.3 Surface options

1. Bubble renders with `stripDetectedURLs = true`.
2. Expanded renders with `stripDetectedURLs = false`.
3. Parse output (`MarkdownRenderPlan`) is identical for both surfaces.

## 4. AST Mapping and Fallback Rules

### 4.1 Primary mapping

Source of truth: `swift-markdown` `Document` AST.

Top-level mapping:

1. `CodeBlock` -> `.code(language, code)`
2. `Table` -> `.table(TableModel)`
3. Other contiguous non-code/non-table blocks -> merged `.richText(markdownSource:)`

Required behavior:

1. Preserve source order exactly.
2. No line-based pre-segmentation.
3. No regrouping by block type after parse.

### 4.2 Nested structures

T057 behavior:

1. Nested code/table content inside container blocks (quote/list/etc.) stays in container `.richText`.
2. T057 does not flatten nested structures into top-level extracted blocks.

### 4.3 Code block behavior and fallback

1. Fenced and indented code blocks recognized by `swift-markdown` render as `.code`.
2. Language info string maps to optional `language`.
3. If code conversion fails, fallback to `.richText` for original span.
4. Malformed fence input remains `.richText`.
5. Never crash; preserve content.

### 4.4 Table behavior and fallback

1. AST `Table` nodes map to `.table(TableModel)`.
2. Existing `MarkdownTableView` remains the table UI renderer.
3. If table conversion fails, fallback to `.richText` for original span.
4. Non-GFM table-like text stays `.richText`.
5. Never drop content.

### 4.5 `==highlight==` integration

1. Highlight handling exists only in `UnifiedMarkdownRenderer`.
2. Reuse existing T055/T056 sentinel-based highlight logic from current renderer.
3. Apply to `.richText` output only.
4. Inline code and fenced code must remain unhighlighted.

## 5. Selection Constraints (T057)

1. Continuous native selection across separate block views is not a T057 requirement.
2. Selection behavior must not regress from current product behavior.
3. Code/table interactions remain with existing code/table views.

## 6. Replacement Map

Replaced:

1. Markdown-first segmentation heuristics in `MessagePresentationBuilder`.
2. `ChatMarkdownRenderer` split authority.
3. `MessageTextPartRenderer` split assembly path.
4. Bubble/expanded markdown regrouping loops.

Stays:

1. `CodeBlockUIKitView` and `MarkdownTableView`.
2. Non-markdown attachment/media rendering.
3. Link-card policy difference (bubble strips URL text, expanded does not).

## 7. Cutover Plan

Single cutover:

1. Implement unified parser and renderer.
2. Switch both bubble and expanded to consume unified rendered blocks.
3. Remove legacy markdown split path.
4. Validate with acceptance matrix below.

## 8. Risks

1. Edge markdown parsing differs from old heuristics.
2. Table conversion failures on malformed input.
3. Highlight leakage into code spans.
4. Ordering/truncation regressions in mixed content.

Mitigation principle:

1. Prefer fallback to `.richText` over dropping content.
2. Validate behavior via acceptance matrix.

## 9. Acceptance Test Matrix (WHAT)

All rows are required for T057 completion.

| ID | Regression | Fixture Input | Surface(s) | Expected Result |
|---|---|---|---|---|
| R48-01 | #48 order drift | `text -> fenced code -> text -> table -> text` | Bubble + Expanded | Identical block type sequence and source order |
| R48-02 | #48 missing expanded chunks | Long markdown that truncates in bubble and fully renders in expanded | Bubble + Expanded | Expanded contains all markdown blocks in source order; none missing |
| R48-03 | #48 dual-path divergence | Mixed list/quote/heading/code/table document | Bubble + Expanded | Both surfaces render from same unified plan; differences limited to surface options |
| R50-01 | #50 fenced block plain-text regression | Standard fenced code with language + trailing prose | Bubble + Expanded | Fence renders as code block, not plain markdown text |
| R50-02 | #50 edge fence pattern | Colon-prefixed line before fence + multiline code body | Bubble + Expanded | Code block classification stable; surrounding prose preserved |
| R50-03 | #50 whitespace/malformed fence variant | Fence with unusual whitespace and no language | Bubble + Expanded | Valid fence -> code block; invalid fence -> rich text fallback; no crash/drop |
| R50-04 | #50 multiple code blocks | `text + code + text + code + text` | Bubble + Expanded | All code blocks render as code blocks in correct order |
| HL-01 | highlight parity | Mixed markdown with `==mark==` + inline code + fenced code | Bubble + Expanded | Highlight appears in rich text only; code literals remain unhighlighted |
| TB-01 | table fallback safety | Broken GFM table input | Bubble + Expanded | No crash; content preserved via rich text fallback |

## 10. Definition of Done

1. Bubble and expanded both use one markdown parse/render path.
2. Legacy split markdown path is removed.
3. Acceptance matrix passes for #48/#50/highlight/table fallback.
4. No known content-drop or code-block-plain-text regressions remain.

## 11. Expected Touchpoints

1. `ios/Clawline/Clawline/Models/MessagePresentation.swift`
2. `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift`
3. `ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift`
4. `ios/Clawline/Clawline/Views/Chat/ChatMarkdownRenderer.swift` (replace/remove)
5. `ios/Clawline/Clawline/Views/Chat/MessageTextPartRenderer.swift` (replace/remove)
6. `ios/Clawline/ClawlineTests/...` markdown regression coverage

## 12. Addendum: Emoji-Only Ownership Cleanup (2026-02-19)

Problem statement:

1. Emoji-only behavior is currently split across parser, builder, presentation style, and bubble render gate.
2. Bubble can apply amplified emoji styling, but unified markdown block rendering later overwrites `bodyLabel.attributedText`.
3. Result: amplified emoji is clobbered by normal markdown text rendering.

Design change:

1. Unified markdown pipeline is the only owner of emoji-only classification.
2. Replace boolean `MarkdownRenderPlan.isEmojiOnly` with a single text mode:

```swift
enum MarkdownTextMode: Equatable {
    case standard
    case emojiOnly(emojiCount: Int)
}

struct MarkdownRenderPlan: Equatable {
    let blocks: [MarkdownRenderBlock]
    let plainTextForMetrics: String
    let containsTextualContent: Bool
    let textMode: MarkdownTextMode
}
```

3. `UnifiedMarkdownParser` sets `textMode` once when creating the plan.
4. All downstream rendering decisions consume `plan.textMode`; no re-detection.

Flow after cleanup:

1. Build one `MarkdownRenderPlan`.
2. If `plan.textMode == .emojiOnly`:
3. Render emoji via one dedicated unified path (`bodyLabel.attributedText` set once with amplified emoji attributes).
4. Skip unified markdown block rendering pass entirely.
5. If `plan.textMode == .standard`, run normal unified markdown block rendering.

Removals (single-gate enforcement):

1. Remove `MessagePresentationBuilder.isEmojiOnly()` decision point.
2. Remove `MessagePresentation.chromelessStyle` emoji inference based on parts.
3. Remove bubble gate requiring both `chromelessStyle == .emoji` and `.inlineEmoji` first-part checks.
4. Remove legacy `.inlineEmoji` vs `.markdown` branch ownership for emoji-only messages.

Post-change invariant:

1. Emoji-only is decided exactly once in unified markdown planning.
2. Exactly one render path executes for message text: emoji-only path or standard markdown path.
3. Emoji-only path and markdown block pass are mutually exclusive, so attributed text cannot be clobbered.
