# visionOS Codepath Audit

Date: 2026-03-30

Scope:
- Shared Clawline client target only: `ios/Clawline/Clawline/`
- Compile-time and runtime visionOS branches that affect chat/UI behavior
- `Clawline Spatial/` app entry remains out of scope; that target is expected to differ

Method:
- Rescanned current source for `#if os(visionOS)`, `#if !os(visionOS)`, and visionOS-specific runtime branches
- Re-read the current shared codepaths around chat layout, message flow, link previews/cards, composer, and theme surfaces
- Checked local docs/specs for explicit product intent
- Used `engram explain` on three suspicious areas:
  - `MessageInputBar.swift:125-145`
  - `MessageFlowCollectionView.swift:1905-1913`
  - `CodeBlockView.swift:19-24`
  Engram gave provenance lineage but did not surface decisive product rationale for those divergences

Product answers from Flynn applied in this revision:
- “composer” means the bottom message input area: text field + add/send + growing bar
- visionOS single-link preview cap should stay at 75%
- code blocks and markdown behavior on visionOS should be exactly the same as iPad/iPhone
- appearance/theme also need to be untangled as part of this work

## Bottom Line

The current shared target has a real visionOS divergence surface, but it breaks into three very different buckets:

- Keep:
  - keyboard/input-bar pinning geometry
  - capability gates like camera, haptics, and browser presentation
  - spatial sizing where product intent explicitly differs, including the 75% single-link preview cap
  - visionOS material fallback where Liquid Glass APIs are unavailable
  - a composer appearance that does not shift with app theme
- Kill:
  - disabled syntax highlighting in `CodeBlockView`
  - most per-view appearance forks that read `settings.appearanceMode` only on visionOS
  - visionOS-only typing/input-bar growth defer behavior if the performance invariant is supposed to apply cross-platform
- Keep, but re-home:
  - a small amount of explicit UIKit style bridging is still needed, but it should hang off one shared effective theme source instead of scattered visionOS-only branches
  - the composer's non-shifting appearance should stay, but not as a visionOS-only rule

The major theme conclusion is this:

Current visionOS appearance handling is mostly workaround accumulation, not intended product differentiation.

The codebase should keep one shared appearance model across iPhone, iPad, and visionOS, then keep only the narrow platform-specific pieces that are actually about platform capabilities or spatial geometry.

## Concrete Audit

| Files / lines | Area / feature | What differs on visionOS | Necessary? | Intent vs drift | Opinion |
| --- | --- | --- | --- | --- | --- |
| `Views/RootView.swift:59-61,93-104`; `Settings/SettingsView.swift:16-21`; `Views/Chat/MessageFlowCollectionView.swift:46-50,76-80,2000-2007`; `Views/Chat/ExpandedMessageSheet.swift:27-32`; `Views/Chat/ChatView.swift:2846-2851,2918-2923`; `Views/Chat/ChannelToast.swift:20-25`; `DesignSystem/ChatFlowOrganic/Components/ScrollToBottomButton.swift:21-27`; `DesignSystem/ChatFlowOrganic/Components/CodeBlockView.swift:27-32` | Appearance / theme resolution | visionOS repeatedly bypasses the environment `colorScheme` and reads `settings.appearanceMode` directly; `RootView` also applies `.preferredColorScheme(...)` only on visionOS; `MessageFlowCollectionView` additionally forces `overrideUserInterfaceStyle` only on visionOS | Partly | Shared product intent, workaround implementation | This is the main workaround cluster. The product intent is shared appearance, not a visionOS-only theme fork. Keep one root/theme bridge, kill the scattered per-view visionOS checks. |
| `DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift:125-161,194-223,324-340,438-442` | Composer theme / appearance toggle | visionOS keeps the composer dark regardless of selected appearance, adds a visionOS-only appearance toggle button in the composer, and uses a separate palette for editor chrome and controls | Partly | Product intent is real, platform scoping is drift | Flynn clarified that the composer should not shift with theme. Keep the non-shifting composer behavior, but kill the fact that it is implemented only on visionOS. The composer theme rule should be shared, while the visionOS-only control/palette branching should be simplified around that shared rule. |
| `Views/Chat/ChatView.swift:173-178`; `Views/Chat/MessageFlowCollectionView.swift:1905-1913`; `docs/implementation_details/efficient-flow-layout.md` | Typing / input lag / input-bar growth | visionOS suppresses `layoutRevision` invalidation on input-bar height change and skips treating `truncationBottomInset` changes as active-typing update blockers; iOS/iPad still react more eagerly | No, not as platform-only behavior | Likely accidental drift | The local layout doc states this as a general interaction-performance invariant, not a visionOS-only rule. This should likely be shared once verified safe. |
| `Views/Chat/ChatView.swift:668-707,2183-2612`; `Views/Chat/MessageFlowCollectionView.swift:926-957` | Keyboard geometry / pinned composer layout | visionOS adds 25% top and bottom spatial insets, uses container-bottom pinning instead of `keyboardLayoutGuide`, samples keyboard height from window bounds, and keeps the collection view in `view.bounds` instead of extending to window bounds | Yes | Matches platform geometry | This should remain different. It is a real platform/layout difference, not theme drift. |
| `Views/Chat/ChatView.swift:842-879,1192-1208,2380-2476`; `Views/Chat/StreamPageDotsView.swift:81-84`; `DesignSystem/ChatFlowOrganic/Components/ScrollToBottomButton.swift:52-57` | Page dots / scroll-to-bottom placement | visionOS renders page dots and the scroll-to-bottom control in SwiftUI bottom overlays; iOS/iPad pins them to the UIKit keyboard host; `StreamPageDotsView` also skips the iOS glass effect on visionOS | Mostly yes | Mostly intended | The placement divergence is justified by keyboard-host differences. The visual finish difference is primarily material fallback, not theme intent. |
| `Views/Chat/ChatView.swift:1540-1579`; `Views/Chat/StreamManagerSheet.swift:11-320`; upstream geometry at `Views/Chat/ChatView.swift:668-707` | Popup layout / cropping | The popup view itself is shared. I found no direct visionOS guard in `StreamManagerSheet.swift`. The likely difference is indirect: visionOS-specific composer/stream geometry changes the `maxAvailableHeight` passed into the popup | Shared popup, indirect geometry differs | Likely accidental symptom, not popup intent | If Flynn is seeing popup crop/layout problems on visionOS, investigate the geometry provider first, not the popup body. I do not see evidence that the popup is meant to differ on visionOS. |
| `Views/Chat/LinkCardUIKitView.swift:270-282`; `Views/Chat/LinkPreviewView.swift:862-869` | URL cards / previews tap behavior | visionOS opens links via `UIApplication.shared.open`; iOS/iPad presents `SFSafariViewController` in-app | Yes | Capability-driven | Legitimate platform fork unless product later wants a visionOS in-app browser surface. |
| `Views/Chat/BubbleSizingV2.swift:87-123`; `Views/Chat/MessageFlowCollectionView.swift:3493-3534,3873-3890`; design-system note in `design-system/design-system.html:995-1003,1024` | URL preview sizing / crop behavior | visionOS uses platform-aware bubble sizing: single-link bubbles cap at 75% of current window height, effective container height is capped, and mixed text+media bubbles disable outer scroll more aggressively | Yes for the single-link cap; partly for the rest | Intent confirmed for 75% cap; other heuristics are implementation choices | The 75% single-link cap is now explicitly keep. It is the most plausible intentional contributor to different preview height/crop behavior. The other visionOS sizing heuristics are still worth scrutinizing, but they are no longer blocked by product ambiguity on the cap. |
| `Views/Chat/MessageFlowCollectionView.swift:986-1112`; `Views/Chat/MessageBubbleUIKitView.swift:1095-1099,1251-1255` | Edge fade / scroll chrome | visionOS fades visible cells near top/bottom, shifts bubble fade start to `0.95`, and skips scroll-indicator bottom inset adjustment | Partly | Fade looks intentional; indicator skip looks workaround-ish | The spatial fade treatment is defensible as a visionOS visual cue. The indicator-inset skip still reads like workaround residue. |
| `Views/Chat/MessageFlowCollectionView.swift:2212-2253` | Snapshot apply path | The remaining visionOS-specific code after snapshot apply is just `updateVisibleCellOpacity()` to restore the spatial fade pass | Yes, if fade remains | Acceptable | This is no longer a major separate data path. |
| `DesignSystem/ChatFlowOrganic/Components/CodeBlockView.swift:19-24` | Code blocks / syntax highlighting | visionOS disables syntax highlighting entirely and falls back to plain text | No | Product-confirmed drift | Flynn said code blocks and markdown behavior should be exactly the same across platforms. This branch should be removed. |
| `DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift:49-51`; `Views/Chat/MessageFlowCollectionView.swift:3167-3169` | Interactive keyboard dismiss | visionOS skips `.keyboardDismissMode = .interactive` in both the editor and collection view | Yes | Capability / interaction-model driven | This should stay different. It is about input mechanics, not appearance. |
| `Views/Chat/ChatView.swift:1694-1705,1372-1392,2855-2883`; `DesignSystem/ChatFlowOrganic/Components/CameraPicker.swift:8-60`; `ViewModels/ChatViewModel.swift:645-649`; `Views/Chat/ChatView.swift:806-810` | Camera / haptics / attachment actions | visionOS hides camera affordances, rejects camera presentation, and skips haptics | Yes | Clearly intended capability gating | This should remain different. |
| `Views/Chat/ChannelToast.swift:28-40,69-76`; `Views/Chat/ChatView.swift:1947-1954` | Toast chrome / contrast | visionOS uses solid fills and different text-color logic instead of the iOS glass treatment | Partly | Mostly fallback, some workaround accumulation | The material fallback is required. The extra contrast logic is probably not a product-level theme split. It should be reevaluated after appearance propagation is unified. |

## Focused Callouts

### URL cards / previews

The explicit visionOS branch inside the preview/card views is only the tap-open path:
- `LinkCardUIKitView` and `LinkPreviewView` open externally on visionOS

The more likely cause of visionOS-only preview crop/height differences is the sizing path:
- `BubbleSizingV2` gives visionOS its own single-link height cap
- `MessageFlowCollectionView` caps effective container height on visionOS
- mixed media bubbles disable outer scroll more aggressively on visionOS

Product intent is now clear on the most important part:
- keep the 75% single-link cap on visionOS

So if Flynn is chasing URL-card/preview crop regressions, I would investigate the other spatial sizing heuristics around that cap, not the cap itself.

### Popup layout / cropping

I did not find a popup-specific visionOS codepath in `StreamManagerSheet.swift`.

That matters. Popup crop/layout bugs are more likely caused by shared popup UI receiving different geometry inputs on visionOS:
- larger spatial top/bottom insets
- container-bottom composer pinning
- different `streamSelectorMaxHeight` calculation

That is an accidental consequence until proven otherwise, not evidence that the popup is meant to differ on visionOS.

### Typing / input lag / input-bar growth

This is still the strongest accidental-drift candidate:

- `ChatView` disables layout-revision invalidation from composer-height changes on visionOS
- `MessageFlowCollectionView` avoids re-running the active-session update when `truncationBottomInset` changes during typing on visionOS
- `efficient-flow-layout.md` states the deferred-recalc rule as a general interaction invariant

That reads like a performance fix that landed only on visionOS even though the intended behavior is broader.

### Appearance / theme behavior

This is the part that most needs a keep-vs-kill cleanup.

What looks required:
- some root-level propagation from app appearance setting into actual SwiftUI/UIKit color traits
- explicit UIKit style bridging for hosted UIKit/SwiftUI seams that need deterministic trait resolution

What looks like workaround accumulation:
- repeated `#if os(visionOS)` appearance reads in leaf views
- visionOS-only scoping of the composer appearance rule
- theme logic split between `colorScheme`, `settings.appearanceMode`, and ad hoc UIKit overrides

The product intent is shared appearance across iPhone, iPad, and visionOS. The code should reflect that.

## Theme / Appearance Keep-vs-Kill Map

### Keep

| Current behavior | Files | Keep? | Why |
| --- | --- | --- | --- |
| One user-controlled app appearance setting exists | `SettingsManager.appearanceMode`, `SettingsManager.preferredColorScheme` | Keep | Product intent is shared theme behavior across platforms. |
| A root-level mechanism must drive effective app appearance into the tree | currently `RootView.swift:59-61` on visionOS only | Keep the concept, not the current asymmetric implementation | The app needs one authoritative appearance propagation path. |
| Composer appearance does not shift with theme | currently `MessageInputBar.swift:125-161` on visionOS only | Keep the behavior, not the platform restriction | Flynn explicitly clarified this is intentional product behavior. |
| UIKit style bridging where hosted UIKit/SwiftUI content needs explicit trait resolution | `MessageFlowCollectionView.swift:2000-2007`, `SelectableAttributedText.swift:33-39`, `MessageBubbleUIKitView.swift:2563-2572,2653-2657` | Keep | These are bridge seams, not product divergences. They should consume one shared effective theme value. |
| visionOS material fallback where `glassEffect` is unavailable | multiple chat/pairing controls | Keep | Capability/API difference, not theme drift. |

### Kill

| Current behavior | Files | Kill? | Why |
| --- | --- | --- | --- |
| Leaf views on visionOS read `settings.appearanceMode` while iPhone/iPad read `colorScheme` | `SettingsView.swift`, `ExpandedMessageSheet.swift`, `ChannelToast.swift`, `ScrollToBottomButton.swift`, `ChatView.swift` attachment sheet types, `CodeBlockView.swift`, `MessageFlowCollectionView.swift` make/update path | Kill | This is workaround accumulation. Leaf views should not own platform-specific theme resolution. |
| Composer non-shifting theme exists only on visionOS instead of being a shared rule | `MessageInputBar.swift:125-161` and related palette branches | Kill the platform restriction | The composer rule is intentional, but the platform-only implementation is drift. |
| Composer-local appearance toggle exists only on visionOS | `MessageInputBar.swift:194-223` | Kill or move out of the composer-specific platform fork | The product rule is about composer appearance stability, not about a visionOS-only composer control owning theme changes. |
| Syntax highlighting disabled on visionOS | `CodeBlockView.swift:19-24` | Kill | Flynn explicitly wants code/markdown behavior identical across platforms. |

### Keep, But Move / Simplify

| Current behavior | Files | Action | Why |
| --- | --- | --- | --- |
| `RootView` applies `.preferredColorScheme(...)` only on visionOS | `RootView.swift:59-61` | Move to a shared root theme propagation strategy | The asymmetry causes downstream forks. |
| `MessageFlowCollectionView` computes `isDark` from `settings.appearanceMode` only on visionOS | `MessageFlowCollectionView.swift:46-50,76-80` | Keep explicit `isDark` bridging, but feed it from one shared effective theme source | The collection view needs a concrete trait value, but not a platform-specific decision tree. |
| Toast and button contrast tweaks on visionOS | `ChannelToast.swift`, `ScrollToBottomButton.swift` | Reevaluate after shared theme propagation is fixed | Some of this may become unnecessary once the theme source is consistent. |

## Recommended Theme Untangling Direction

Concrete target architecture:

1. One shared effective appearance source
   - The app-level appearance setting remains the product source of truth.
   - Root applies the effective appearance consistently across iPhone, iPad, and visionOS.

2. Leaf views stop branching on platform for theme resolution
   - Most current `effectiveColorScheme` helpers disappear.
   - Leaf views consume the propagated environment color scheme or one shared resolved-theme helper.

3. UIKit bridges stay explicit
   - `MessageFlowCollectionView`
   - `SelectableAttributedText`
   - `MessageBubbleUIKitView` / table wrappers
   These should still receive deterministic dark/light style values, but from the same shared source.

4. Composer rejoins the shared theme system
   - Keep the non-shifting composer appearance rule as product behavior.
   - Remove the fact that this rule is visionOS-only.
   - Reevaluate whether the inline appearance control belongs in the composer at all once theme ownership is centralized.
   - Keep only platform differences that are about materials, geometry, and input mechanics.

## Recommendations

Priority order:

1. Keep the non-shifting composer appearance rule, but make it a shared rule instead of a visionOS-only fork.
2. Remove the `CodeBlockView` visionOS syntax-highlighting disable path.
3. Untangle appearance propagation so a single shared theme source drives all platforms.
4. Keep the 75% visionOS single-link preview cap, but investigate the other spatial sizing heuristics around preview crop/layout.
5. Treat the visionOS-only typing/input-bar growth defer path as likely accidental drift and evaluate sharing it with iOS/iPad.
6. Leave capability and keyboard-geometry forks alone unless a specific bug proves them wrong.

## Product-Intent Blockers

None at this point. Flynn’s answers are sufficient to classify the main open items:
- composer should not shift with theme, but that rule should not stay visionOS-only
- 75% visionOS single-link preview cap should stay
- code/markdown behavior should be shared
- appearance/theme should be unified instead of split
