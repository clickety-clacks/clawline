import CoreGraphics
import Foundation
import SwiftUI
import UIKit
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

    @MainActor
    @Test("Text selection lock restores on installer teardown")
    func textSelectionLockRestoresOnInstallerTeardown() {
        let coordinator = DictationPanGestureInstaller.debugCoordinatorForTests()
        let textView = UITextView()
        textView.isSelectable = true
        textView.isScrollEnabled = true

        coordinator.debugPrimeTextViewLock(textView)
        #expect(textView.isSelectable == false)

        coordinator.prepareForInstallerDisappear()
        #expect(textView.isSelectable == true)
        #expect(textView.isScrollEnabled == true)
    }

    @MainActor
    @Test("Text selection lock restores when app backgrounds mid-drag")
    func textSelectionLockRestoresWhenAppBackgrounds() {
        let coordinator = DictationPanGestureInstaller.debugCoordinatorForTests()
        let textView = UITextView()
        textView.isSelectable = true
        textView.isScrollEnabled = true

        coordinator.debugPrimeTextViewLock(textView)
        #expect(textView.isSelectable == false)

        coordinator.handleScenePhaseChanged(.background)
        #expect(textView.isSelectable == true)
        #expect(textView.isScrollEnabled == true)
    }
}
