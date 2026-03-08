import Testing
import UIKit
@testable import Clawline

@MainActor
struct MessageFlowCollectionViewKeyboardTests {
    @Test("Focused editor disables interactive keyboard dismissal")
    func focusedEditorDisablesInteractiveKeyboardDismissal() {
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(true) == .none)
        #expect(MessageFlowCollectionView.keyboardDismissModeForInputFocus(false) == .interactive)
    }
}
