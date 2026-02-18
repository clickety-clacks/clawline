# T044 Dark/Light Table Audit + Architecture Retro

Date: 2026-02-17

## Scope

Audit target:
- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/Tables/MarkdownTableView.swift`
- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/Tables/SelectableAttributedText.swift`
- `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift` (`TableUIKitWrapperView`)
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
- `ios/Clawline/Clawline/Models/MessagePresentation.swift`

## 1) Prior fixes attempted and why they failed

### Attempt A: `efd73b2`
Change:
- Reintroduced `TableUIKitWrapperView.traitCollectionDidChange` and recreated hosted `MarkdownTableView` on appearance change.

Why it failed:
- Treated wrapper rebuild as primary reactive seam.
- Table text color is actually resolved in nested attributed runs inside `UITextView` (`SelectableAttributedText`), not wrapper chrome.
- Wrapper-level rebuild did not establish a single authoritative mutation seam for text color resolution.

### Attempt B: `93a37e4e9`
Change:
- Converted table chrome/text colors to dynamic `UIColor` providers in `MarkdownTableView`.
- Removed explicit `colorScheme` plumbing from wrapper/sheet callsites.

Why it failed:
- Improved color definition but not ownership boundaries.
- Dynamic colors still need consistent trait source and consistent rerender triggers.
- Color creation and rerender triggering remained split across multiple layers.

### Attempt C: `b15e0eef0`
Change:
- Added `colorScheme` input to `SelectableAttributedText`.
- Set `UITextView.overrideUserInterfaceStyle` in `updateUIView`.
- Added `TraitResponsiveTextView.traitCollectionDidChange` to reassign attributed text.

Why it still bounced:
- This improved inner text refresh but left overall system with multiple appearance mutation seams.
- Bubble-level appearance uses explicit `isDark` flow; table subtree still depended on internal trait/environment propagation paths.
- System remained vulnerable to seam drift.

## 2) Full path map: color creation/resolution (end-to-end)

### Path A: Data model creation
1. `MessagePresentationBuilder.makeCell` creates `TableModel.Cell.attributed` from markdown/plain text.
2. No concrete color is attached there (content only).

### Path B: SwiftUI table chrome colors
1. `MarkdownTableView` defines chrome tokens (`headerFillColor`, `backgroundFillColor`, `borderColorValue`, divider colors, empty text color) using `dynamicColor`.
2. `dynamicColor` creates `UIColor(dynamicProvider:)`.
3. SwiftUI wraps those as `Color(uiColor:)` for fills/strokes/text.
4. Final color resolves at render time using effective trait collection.

### Path C: Table text run colors
1. `MarkdownTableView.styledAttributedString` copies `cell.attributed` into `NSMutableAttributedString`.
2. Applies `.foregroundColor = tableTextColor` where `tableTextColor` is a dynamic `UIColor`.
3. Applies inline-code `.backgroundColor = inlineCodeBackgroundColor()` (also dynamic `UIColor`).
4. Passes this attributed string into `SelectableAttributedText`.
5. `UITextView` (TextKit) resolves dynamic run colors under its current trait collection.

## 3) Full path map: rerender/trait-change triggers

### Trigger path 1: Chat-level appearance update
1. `MessageFlowCollectionView` receives SwiftUI appearance (`isDark`).
2. `MessageFlowCollectionViewController.update` detects `currentIsDark` change.
3. Sets `forceReconfigureAll = true`.
4. Snapshot reconfigures all visible message cells.
5. `MessageBubbleUIKitView.configure` reruns for each cell with explicit `isDark`.

### Trigger path 2: Table host rebuild
1. `MessageBubbleUIKitView.configure` creates/configures `TableUIKitWrapperView`.
2. Wrapper rebuilds hosted `MarkdownTableView` tree.
3. Hosted SwiftUI body recomputes table chrome and attributed strings.

### Trigger path 3: TextKit-local trait refresh
1. `SelectableAttributedText.updateUIView` sets text view `overrideUserInterfaceStyle` and reassigns attributed text.
2. `TraitResponsiveTextView.traitCollectionDidChange` also reassigns attributed text when color appearance changes.
3. This forces TextKit to re-resolve dynamic UIColor attributes.

## 4) Where the paths disconnected (actual root cause)

The disconnect was between:
- **Color mutation seam ownership**: split across SwiftUI environment/traits and UIKit explicit `isDark`.
- **Rerender seam ownership**: split across wrapper rebuilds, representable updates, and text view trait callbacks.

Concrete architecture failure:
- Bubble appearance state had one explicit source (`isDark` from `MessageFlowCollectionView`), while table appearance had additional inferred trait/environment sources.
- That created multiple write paths for the same logical state ("table appearance mode"), violating mutation seam discipline.
- With split seams, dark/light updates could apply to some table layers (chrome/text) while another layer remained stale.

## 5) Architecture-principles review findings

Reference: `~/.codex/skills/architecture-principles/SKILL.md`

### Principle 3 (Separation of concerns first): violated
- Table color ownership was not localized; wrapper, SwiftUI view, and nested UITextView each participated in appearance mutation.
- Prior fixes addressed symptoms in one layer at a time.

### Principle 6 (State mutation seam discipline): violated
- Appearance state for tables had **multiple mutation seams**:
  1. Bubble-level explicit `isDark` path (UIKit configure).
  2. SwiftUI environment `colorScheme`.
  3. UIKit trait inference inside hosted view/text view.
- No single authoritative seam guaranteed consistency.

### Principle 1 (Pattern propagation): risk
- Leaving split seams would normalize "appearance by inference" in some components and "appearance by explicit parameter" in others.
- That shape invites repeat regressions.

## 6) Recommended fix (architecture)

Set one authoritative seam for table appearance in bubble context:
- Use bubble-level explicit `isDark` as the source of truth for the table host boundary.
- Apply that explicitly in `TableUIKitWrapperView` by setting hosting controller style at configure time.
- Keep inner `SelectableAttributedText` trait refresh as renderer-local invalidation, not a competing source of truth.

This preserves right-weight architecture (no new subsystem) while collapsing split mutation seams into one explicit handoff boundary.

## 7) Implemented fix

Implemented in `MessageBubbleUIKitView.swift`:
- `TableUIKitWrapperView.configure` now accepts `isDark`.
- Wrapper sets:
  - `hostingController.overrideUserInterfaceStyle`
  - `hostingController.view.overrideUserInterfaceStyle`
- Caller (`MessageBubbleUIKitView.configure`) passes `effectiveIsDark` to table wrapper.

Result:
- Table host and bubble now share the same appearance mutation seam.
- Dynamic UIColor resolution in table chrome and attributed runs resolves under that explicit style boundary.
