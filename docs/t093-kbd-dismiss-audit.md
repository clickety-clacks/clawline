# T093 Keyboard Dismiss Audit (Issue #96)

## Scope
Audit only. No fixes were implemented.

## 1) Keyboard frame/dismiss observers and related hooks

### Keyboard notifications
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:1344`-`1348`
  - `NotificationCenter` observer for `UIResponder.keyboardWillChangeFrameNotification`.
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:1442`
  - `keyboardFrameChanged(_:)` handler computes height/duration/curve and calls `onChange`.

### SwiftUI/state-driven keyboard geometry handling
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:440`
  - Root `GeometryReader` driving layout from `geometry.safeAreaInsets`.
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:465`
  - `KeyboardLayoutGuideReader` callback mutates keyboard state (`keyboardHeight`, duration, curve).
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:528`-`529`
  - Keyboard visibility derived from `keyboardHeight - geometry.safeAreaInsets.bottom`.
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:647`-`653`
  - `onChange` handlers mutate `layoutRevision` for keyboard/safe-area-related values.

### Interactive keyboard dismiss settings
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:1051`
  - Main chat list `UICollectionView.keyboardDismissMode = .interactive`.
- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift:48`
  - Input `UITextView.keyboardDismissMode = .interactive`.

### Items explicitly not present
- No `.onReceive` keyboard notification handlers found in the chat path.

## 2) Main-thread work firing during keyboard dismiss

### Keyboard notification -> SwiftUI state churn (per frame)
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:465`-`481`
  - Callback synchronously mutates multiple `@State` values on each keyboard frame update:
    - `keyboardHeight`
    - `keyboardAnimationDuration`
    - `keyboardAnimationCurve`
    - `lastNonZeroKeyboardHeight` (conditional)
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:647`-`653`
  - Additional `layoutRevision` mutations triggered from keyboard-related `onChange` observers.

### Coordinator transition apply path (main thread)
- `ios/Clawline/Clawline/Views/Chat/ChatLayoutCoordinator.swift:180`-`267`
  - `applyTransitionIfPossible` runs on main actor, mutates bar constraints and list insets.
- `ios/Clawline/Clawline/Views/Chat/ChatLayoutCoordinator.swift:242`-`249`
  - Wraps changes in `UIView.animate` when keyboard reports duration.
- `ios/Clawline/Clawline/Views/Chat/ChatLayoutCoordinator.swift:229`-`233`
  - Calls `barView.setDesiredBottomGap(...)` then `layoutIfNeeded()`.
- `ios/Clawline/Clawline/Views/Chat/ChatLayoutCoordinator.swift:235`-`238`
  - Calls `list.setBottomInset(...)` for all registered lists.

### Collection inset path with expensive side effects
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:431`-`465`
  - `setBottomInset` updates `contentInset`/indicator inset and may adjust content offset.
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:467`-`488`
  - `handleBottomInsetHeightCapChange` executes when bottom inset changes:
    - Iterates all `messagesById`.
    - Calls `viewModel.presentation(for:metrics:)` per message to detect affected bubbles.
    - Invalidates caches + calls `flowLayout.invalidateLayout()`.
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1236`
  - `presentation(for:metrics:)` is on main actor and non-trivial; calling this repeatedly during interactive keyboard updates is a likely jank source.

### Additional high-frequency UI update pressure
- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:64`-`85`, `513`-`687`
  - `updateUIViewController` calls `update(...)`; this reconstructs/apply snapshot logic frequently while keyboard-driven layout is changing.
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift:1540`-`1567`
  - `KeyboardPinnedContainer.updateUIView` repeatedly reassigns rootView/handlers and triggers coordinator apply.

## 3) Focused findings for requested areas

### MessageInputBar
- No direct keyboard notification observer in `MessageInputBar`.
- It still participates in keyboard-driven relayout because parent passes `isKeyboardVisible` and safe area (`ios/Clawline/Clawline/Views/Chat/ChatView.swift:813`-`815`, `825`).

### ChatView
- Owns keyboard state and converts keyboard frame updates to SwiftUI state (`ios/Clawline/Clawline/Views/Chat/ChatView.swift:92`-`96`, `465`-`481`).
- Derives binary visibility via safe-area-subtracted threshold (`ios/Clawline/Clawline/Views/Chat/ChatView.swift:528`-`529`).

### ChatViewModel
- No keyboard-frame observer.
- Indirectly pulled into dismiss-time work via `presentation(for:metrics:)` from `MessageFlowCollectionView` bottom-inset handling (`ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:471`-`474`).

### Scroll view setup
- Interactive dismiss is enabled on both the chat collection and the text view (`MessageFlowCollectionView.swift:1051`, `RichTextEditor.swift:48`).

### Bottom inset / safe area update paths
- Safe area participates in keyboard visibility calculation (`ChatView.swift:528`-`529`).
- Insets and bar gap are applied by coordinator + collection view (`ChatLayoutCoordinator.swift:389`-`399`, `235`-`238`; `MessageFlowCollectionView.swift:431`-`465`).

## 4) Synchronous state mutations on keyboard frame change

Yes, synchronous layout-triggering state changes happen during keyboard frame updates:
- `@State keyboardHeight` set in keyboard callback: `ChatView.swift:468`-`469`.
- `@State keyboardAnimationDuration`/`keyboardAnimationCurve` set in same callback: `ChatView.swift:476`-`481`.
- `@State layoutRevision` incremented in keyboard-related `onChange`: `ChatView.swift:647`-`653`.
- These drive coordinator transition work and UIKit inset/layout updates on main.

## 5) Root-cause hypothesis (ranked)

### Primary hypothesis
Release-time stutter is caused by **main-thread overload in the keyboard frame -> inset update pipeline**, with expensive inset side effects and layout invalidation running during/after drag release.

Most suspect chain:
1. Keyboard frame notification updates `keyboardHeight/duration/curve` (`ChatView.swift:465`-`481`).
2. Coordinator applies transition (`ChatLayoutCoordinator.swift:180`-`267`) and updates list inset.
3. `setBottomInset` triggers `handleBottomInsetHeightCapChange` (`MessageFlowCollectionView.swift:467`-`488`) which can iterate all messages, call `presentation(...)`, invalidate caches, and invalidate layout on main.
4. This can produce a short hitch exactly when release starts the final keyboard animation segment.

### Secondary hypothesis
A discontinuity near hidden-state threshold contributes to perceived pause:
- Keyboard visibility flips at `keyboardHeight - safeAreaBottom <= 0.5` (`ChatView.swift:528`-`529`), causing effective inset to snap to 0 in coordinator inputs (`ChatLayoutCoordinator.swift:20`-`23`, `395`-`398`).
- That binary transition during the final release phase can look like a brief hold/jump.

## 6) Recommended fix approach (do not implement yet)

1. Decouple expensive bubble invalidation work from per-frame inset updates.
- Move `handleBottomInsetHeightCapChange` work off the hot keyboard frame path.
- Coalesce/debounce to run once after dismiss settles instead of every inset delta.

2. Keep keyboard inset continuous through release.
- Avoid binary `keyboardVisible` gating for effective inset in the last phase.
- Use continuous inset math (or delay visibility flip effects) so bottom inset tracks final frames smoothly.

3. Reduce per-frame coordinator/UI churn.
- Gate updates so keyboard frame ticks that do not materially change target inset/bar constraints avoid transition application.
- Keep `layoutIfNeeded`/constraint writes minimal during interactive phase.

4. Validate with targeted instrumentation.
- Add timing around `setBottomInset`, `handleBottomInsetHeightCapChange`, and `applyTransitionIfPossible` to confirm release-frame spikes.

