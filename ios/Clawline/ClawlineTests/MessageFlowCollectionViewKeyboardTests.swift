import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageFlowCollectionViewKeyboardTests {
    @Test("Active dictation disables scroll-driven keyboard dismissal")
    func activeDictationDisablesScrollDrivenKeyboardDismissal() {
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, isDictationActive: true) == .none)
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, isDictationActive: true) == .none)
    }

    @Test("Inactive dictation preserves normal interactive dismissal")
    func inactiveDictationPreservesInteractiveDismissal() {
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, isDictationActive: false) == .interactive)
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, isDictationActive: false) == .interactive)
    }
}
