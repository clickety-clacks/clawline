import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageFlowCollectionViewKeyboardTests {
    @Test("Keyboard-pinned mode disables scroll-driven keyboard dismissal")
    func keyboardPinnedModeDisablesScrollDrivenKeyboardDismissal() {
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, keepsKeyboardPinned: true) == .none)
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, keepsKeyboardPinned: true) == .none)
    }

    @Test("Normal mode preserves interactive keyboard dismissal")
    func normalModePreservesInteractiveDismissal() {
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, keepsKeyboardPinned: false) == .interactive)
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, keepsKeyboardPinned: false) == .interactive)
    }
}
