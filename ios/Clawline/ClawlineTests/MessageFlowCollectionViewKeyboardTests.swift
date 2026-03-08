import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageFlowCollectionViewKeyboardTests {
    @Test("Active dictation preserves interactive keyboard dismissal")
    func activeDictationPreservesInteractiveKeyboardDismissal() {
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, isDictationActive: true) == .interactive)
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, isDictationActive: true) == .interactive)
    }

    @Test("Inactive dictation preserves normal interactive dismissal")
    func inactiveDictationPreservesInteractiveDismissal() {
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, isDictationActive: false) == .interactive)
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, isDictationActive: false) == .interactive)
    }
}
