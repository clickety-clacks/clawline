# Unified Markdown DRY Audit

## Principle Applied
Architecture principle 8 (DRY): one concept should have one implementation, and behavior changes should apply everywhere from one place.

## Audit Scope
Pipeline from markdown input to rendered bubble/expanded content:
- `UnifiedMarkdownParser`
- `UnifiedMarkdownRenderer`
- `MessagePresentationBuilder`
- Bubble/expanded markdown view composition

## Findings (ordered by severity)

### 1) Critical: two parsers exist in practice (one unified, one legacy dead path)
`MessagePresentationBuilder.build` uses `UnifiedMarkdownParser.parse` as the active path (`ios/Clawline/Clawline/Models/MessagePresentation.swift:291`), but the file still contains a full legacy segment/table parser stack (`processTextSegment`, `parseTable`, `Segmenter`, table cell parsing) that is no longer called.

Evidence:
- Active unified parse entry: `ios/Clawline/Clawline/Models/MessagePresentation.swift:291`
- Legacy parser entry exists: `ios/Clawline/Clawline/Models/MessagePresentation.swift:402`
- No call sites for `processTextSegment`: only declaration hit in repo
  - `ios/Clawline/Clawline/Models/MessagePresentation.swift:402`

Why this violates DRY:
- Markdown parsing rules now exist in two places conceptually, even if one is dormant.
- Future edits can accidentally patch the wrong parser, or resurrect old behavior by calling legacy helpers.
- This is the largest source of architecture ambiguity in the unified pipeline.

### 2) High: emoji-only semantics are implemented in multiple places with different rules
Emoji-only logic is split across parser, part builder, and chromeless routing with non-identical criteria.

Implementations:
- Parser emoji-only (1-3 characters + `isUnifiedMarkdownEmoji`):
  - `ios/Clawline/Clawline/Models/UnifiedMarkdownParser.swift:100`
- Presentation builder emoji check (`allSatisfy { $0.isEmoji }`, no 1-3 limit):
  - `ios/Clawline/Clawline/Models/MessagePresentation.swift:1135`
- Chromeless emoji gate (scalar count 1-3):
  - `ios/Clawline/Clawline/Models/MessagePresentation.swift:245`

Why this violates DRY:
- "Is emoji-only" is a single domain concept with three implementations.
- A behavior tweak requires touching multiple sites, with mismatch risk (already observed in recent regressions).

### 3) High: markdown render option composition duplicated across bubble and expanded surfaces
Both views independently build `MarkdownRenderOptions` with mostly identical fields and policy.

Evidence:
- Bubble options creation: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:611`
- Expanded options creation: `ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift:154`

Why this violates DRY:
- Same rendering concept (font/ink/line spacing/highlight rules) is configured in two places.
- Changing default markdown style policy requires synchronized edits across both surfaces.

### 4) Medium: duplicated UIKit hosting wrapper pattern for markdown widgets
`CodeBlockUIKitView` and `TableUIKitWrapperView` both implement nearly identical "host SwiftUI view in UIKit + set style + size fitting" infrastructure.

Evidence:
- Code wrapper: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2265`
- Table wrapper: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2359`

Why this violates DRY:
- Common hosting concerns (controller lifecycle, constraints, interface style propagation, measurement) are repeated.
- Bug fixes in hosting behavior must be patched in both wrappers.

### 5) Medium: text-content presence checks are repeated rather than centralized
Bubble view computes text presence by scanning rendered blocks (`hasTextContent`) and separately scans again for code/table existence to decide render path.

Evidence:
- `hasTextContent` scan: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:648`
- second scan for `.code`/`.table`: `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:677`

Why this violates DRY:
- Content-presence policy is duplicated in ad hoc checks instead of one utility.
- This is a smaller duplication, but contributes to brittle branching in bubble layout.

## Overall Assessment
The unified pipeline is strongest at AST-to-render-block conversion, but DRY breaks at boundaries:
1. legacy parser code still co-located with unified builder,
2. emoji classification split across parser/presentation/chromeless routing,
3. per-surface render option assembly duplicated.

By principle 8, these are architectural DRY violations because behavior cannot be reliably changed in one place and get consistent results everywhere.
