# T044 Dark Mode Table Regression Retro

Date: 2026-02-15

## 1) Original fix and why it did not work

Original fix (commit `efd73b2`) reintroduced `TableUIKitWrapperView.traitCollectionDidChange` and recreated the hosted `MarkdownTableView` on appearance switches.

Why it did not work:
- It treated the wrapper as the primary reactivity seam, but table cell text is rendered by a nested `UITextView` (`SelectableAttributedText`) via attributed runs.
- The nested text view had no guaranteed trait-reactive refresh path for attributed-run color resolution.
- Result: table chrome could update while text runs stayed visually stale in dark mode, producing low-contrast text.

## 2) How many code paths control table color/appearance reactivity

There are **3** distinct reactivity paths:
1. SwiftUI table chrome path in `MarkdownTableView` (background/header/border/dividers/empty-cell text).
2. UIKit attributed text path in `SelectableAttributedText` (`UITextView` drawing attributed runs for each table cell).
3. UIKit host bridge path in `TableUIKitWrapperView` (trait propagation/rebuild boundary between chat cell UIKit and SwiftUI table).

## 3) Actual root cause

The root cause was a boundary mismatch: color reactivity depended on the host/wrapper layer, but the color that failed was owned by the inner attributed-text renderer (`UITextView`).

Concretely:
- Table text color lived in attributed runs.
- The text renderer did not have its own authoritative trait-change invalidation seam.
- Therefore, color appearance could diverge between table chrome and table text after system appearance changes.

## 4) Right fix

Right fix is to make the color-reactive seam explicit at the text-rendering boundary:

- In `SelectableAttributedText`:
  - add explicit `colorScheme` input and set `UITextView.overrideUserInterfaceStyle` in `updateUIView`.
  - use a `TraitResponsiveTextView` subclass that handles `traitCollectionDidChange` and reassigns `attributedText` to force dynamic UIColor run re-resolution under new traits.
- In call sites (`MarkdownTableView`, `ExpandedMessageSheet`): pass through environment-resolved color scheme.

This keeps color ownership local to the renderer that actually draws attributed runs and prevents recurrence from wrapper-only trait handling.
