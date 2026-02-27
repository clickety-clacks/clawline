import CoreGraphics
import Foundation
import Testing
@testable import Clawline

struct MessageInputBarPanIntentTests {
    @Test("Editable-region tap-like gesture resolves to text editing")
    func editableRegionTapResolvesToTextEditing() {
        let decision = classifyDictationPanIntent(
            .init(
                startedInEditableRegion: true,
                isSurfaceOpen: true,
                elapsed: 0.09,
                translation: CGPoint(x: 1, y: 2),
                velocity: CGPoint(x: 0, y: 0)
            )
        )

        #expect(decision == .textEditing)
    }

    @Test("Editable-region quick upward gesture still resolves to dictation")
    func editableRegionQuickUpResolvesToDictation() {
        let decision = classifyDictationPanIntent(
            .init(
                startedInEditableRegion: true,
                isSurfaceOpen: false,
                elapsed: 0.08,
                translation: CGPoint(x: 0, y: -26),
                velocity: CGPoint(x: 0, y: -350)
            )
        )

        #expect(decision == .dictation)
    }
}
