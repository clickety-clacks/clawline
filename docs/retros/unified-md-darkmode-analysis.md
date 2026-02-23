# Unified Markdown Dark Mode Analysis (Bubble Code Blocks vs Expanded Pane)

## Scope
This is an architecture analysis only. No behavior changes are proposed or implemented in this document.

## Executive summary
Dark mode handling is not unified because the rendering stack is not a single UI technology path:

1. Expanded pane is mostly pure SwiftUI and uses `@Environment(\.colorScheme)`.
2. Bubble path is UIKit (`MessageBubbleUIKitView`) that hosts a mix of UIKit widgets and SwiftUI wrappers.
3. Theme state is propagated through three different mechanisms depending on widget type:
- SwiftUI environment (`colorScheme`) for expanded pane and embedded SwiftUI views.
- UIKit trait collection (`traitCollection.userInterfaceStyle`) for native UIKit views.
- Explicit `isDark` override plumbing from `MessageFlowCollectionView` -> bubble cell -> individual subviews.

Code blocks in bubbles use a custom UIKit view (`CodeBlockUIKitView`) and depend on explicit `isDark` override + async re-highlighting. Tables in bubbles are wrapped SwiftUI (`MarkdownTableView`) inside a hosting controller with explicit override style, and expanded pane code blocks are SwiftUI-native. That is why they diverge.

## Data flow comparison

### Expanded pane (works)
1. `ExpandedMessageSheet` reads `@Environment(\.colorScheme)` and computes `effectiveColorScheme`.
   - `ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift:16`
   - `ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift:25`
2. It renders markdown blocks and for code uses `CodeBlockView`.
   - `ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift:97`
   - `ios/Clawline/Clawline/Views/Chat/ExpandedMessageSheet.swift:109`
3. `CodeBlockView` derives `isDark` from SwiftUI environment and reruns highlight task when `isDark` changes via `.task(id: "\(code)\(isDark)")`.
   - `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/CodeBlockView.swift:15`
   - `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/CodeBlockView.swift:73`

Net effect: appearance updates are directly owned by SwiftUI state changes.

### Bubble code blocks (regression-prone)
1. `MessageFlowCollectionView` reads SwiftUI color scheme and passes boolean `isDark` into UIKit controller update.
   - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:37`
   - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:73`
   - `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:1117`
2. Bubble builds markdown blocks and creates `CodeBlockUIKitView` for `.code` blocks, passing `isDark`.
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:1380`
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:1406`
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:1407`
3. Later appearance updates call `codeView.setAppearanceOverride(isDark:)` across dynamic content views.
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:1262`
4. `CodeBlockUIKitView` computes colors from `explicitIsDarkOverride ?? traitCollection.userInterfaceStyle == .dark`, then re-highlights asynchronously.
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2336`
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2370`
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2377`
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2380`

Net effect: appearance updates depend on a bridge chain and per-view manual propagation.

### Bubble tables (currently working)
1. Bubble creates `TableUIKitWrapperView` for `.table` blocks.
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:1411`
2. Wrapper hosts SwiftUI `MarkdownTableView` and sets hosting/controller override style from bubble `isDark`.
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2531`
   - `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift:2532`
3. `MarkdownTableView` reads `@Environment(\.colorScheme)` and uses dynamic colors.
   - `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/Tables/MarkdownTableView.swift:18`

Net effect: tables are effectively in a SwiftUI color-scheme world once hosted, so they track appearance more reliably.

## Why it is not "set once"
There is no single theming owner across all markdown elements because rendering crosses framework boundaries:

- Parser/renderer output (`UnifiedMarkdownParser` + `UnifiedMarkdownRenderer`) are content/style agnostic except for initial attributed text color.
  - `ios/Clawline/Clawline/Models/UnifiedMarkdownParser.swift:9`
  - `ios/Clawline/Clawline/Views/Chat/UnifiedMarkdownRenderer.swift:8`
- The final visual theme is resolved in view-layer components, and those components are heterogeneous (UIKit vs SwiftUI wrappers).
- Consequently, "set once" only works if all nodes resolve appearance from one source-of-truth in one rendering substrate. Current architecture has at least three appearance channels.

This is an architectural issue, not just a one-off bug.

## Ownership boundary assessment
Current practical ownership is split like this:

1. `UnifiedMarkdownParser`: structural block extraction (`richText`, `code`, `table`).
2. `UnifiedMarkdownRenderer`: attributed text generation for rich text blocks.
3. Bubble/expanded views: actual widget instantiation and appearance binding.

The boundary problem is that appearance logic is duplicated in the view layer by block type:

- `.attributedText` bubble text uses bubble palette.
- `.code` bubble uses bespoke UIKit theming + async highlight refresh.
- `.table` bubble delegates to hosted SwiftUI theming.
- Expanded pane uses SwiftUI-native theming for both code and table widgets.

So markdown block type, view host type, and appearance source are currently entangled.

## Why code blocks diverge from tables and expanded pane
Primary reasons:

1. Different host technology
- Bubble code: custom UIKit widget.
- Bubble table: SwiftUI widget hosted in UIKit.
- Expanded code/table: SwiftUI widgets.

2. Different appearance mutation seams
- Bubble code relies on explicit manual calls (`setAppearanceOverride`) plus trait fallback.
- Tables mostly rely on SwiftUI environment via hosting style.
- Expanded relies directly on SwiftUI environment.

3. Different async update model
- Bubble code re-highlighting is async in a UIKit view and can lag/sequence relative to cell reuse and appearance transitions.
- Expanded code uses SwiftUI `.task(id:)`, naturally keyed to state changes.

## Architectural risk notes
1. Appearance source is duplicated (`colorScheme`, trait collection, explicit `isDark`) and can drift.
2. Bubble has per-widget custom update behavior; consistency depends on each widget correctly implementing dark-mode transitions.
3. Theme behavior is currently a property of host path, not markdown block semantics.
4. Unified markdown currently means unified parsing/rendered block model, not unified appearance lifecycle.

## Conclusion
Dark mode is not unified because the pipeline unifies markdown structure, but not final theming ownership. Code blocks in bubbles get theme updates through a different, more manual path than tables and expanded content. That architectural split explains why tables can behave correctly while bubble code blocks still diverge.
