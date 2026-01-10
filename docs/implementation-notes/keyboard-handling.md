# Keyboard Handling Implementation

## Problem

Input bars need different bottom padding depending on keyboard state:
- **Keyboard hidden**: Concentric padding (~26pt) to align with device corner radius
- **Keyboard visible**: Minimal padding (~12pt) above keyboard

The challenge: changing padding without a visible jump during keyboard transitions.

## Why Standard Approaches Fail

You might think to use `@FocusState` or `keyboardWillChangeFrameNotification` to detect keyboard state. **Don't.**

State-based keyboard detection updates **asynchronously** from SwiftUI's layout-based keyboard avoidance:

1. User taps text field
2. SwiftUI's layout system adjusts safe areas and moves content (IMMEDIATE, same frame)
3. `@FocusState` or keyboard notification updates state (DELAYED, different frame)
4. Our padding depends on state, so it's still wrong while view has already moved
5. Visible jump when state finally updates

The core issue: SwiftUI's keyboard avoidance operates at the **layout level**, but `@FocusState` and keyboard notifications operate at the **state level**. These are not synchronized.

## Solution: Safe Area Insets as Source of Truth

Instead of state-based detection, track safe area inset changes via `GeometryReader`:

```swift
@State private var baselineSafeAreaBottom: CGFloat = 0
@State private var currentSafeAreaBottom: CGFloat = 0

private var isKeyboardVisible: Bool {
    currentSafeAreaBottom > baselineSafeAreaBottom + 10
}

var body: some View {
    GeometryReader { geometry in
        // ... content ...
        .onChange(of: geometry.safeAreaInsets.bottom) { _, newValue in
            currentSafeAreaBottom = newValue
        }
        .onAppear {
            baselineSafeAreaBottom = geometry.safeAreaInsets.bottom
            currentSafeAreaBottom = geometry.safeAreaInsets.bottom
        }
    }
}
```

### Why This Works

Safe area insets are part of SwiftUI's layout system. When the keyboard appears:
- SwiftUI adjusts `safeAreaInsets.bottom` in the layout pass
- Our `onChange` fires in the **same pass**
- Padding updates synchronously with keyboard avoidance
- No jump because everything happens in one frame

### Key Insight

**Layout-based detection** (safe area insets) is synchronous with layout changes.
**State-based detection** (`@FocusState`, notifications) is asynchronous.

## Implementation Notes

- Baseline safe area on Face ID devices is ~34pt (home indicator)
- The 10pt threshold prevents false positives from minor fluctuations
- Must test on physical device - simulator behavior can differ
- See `ChatView.swift` for full implementation with inline documentation
