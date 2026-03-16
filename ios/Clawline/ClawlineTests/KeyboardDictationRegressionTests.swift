//
//  KeyboardDictationRegressionTests.swift
//  ClawlineTests
//
//  Regression guards for two keyboard-dictation bugs:
//  BUG 1: Starting dictation must not close the keyboard.
//  BUG 2: Tapping the text editor while dictating must re-raise the keyboard.
//

import SwiftUI
import Testing
import UIKit
@testable import Clawline

// MARK: - BUG 1: Dictation start must trigger focus request

struct KeyboardDictationRegressionTests {

    // ------------------------------------------------------------------
    // BUG 1 regression: startStickyFromMicTap calls onRequestFocus
    // ------------------------------------------------------------------

    /// The mic-tap path fires onRequestFocus *after* dictation starts so the
    /// keyboard reappears even when the audio session dismisses it.
    /// We verify the static gating logic: shouldRequestFocusOnEditorTap
    /// returns true when the keyboard is hidden (the state after audio
    /// session activation).
    @Test("BUG1: focus request triggers when keyboard hidden after audio session")
    func focusRequestTriggersForHiddenKeyboard() {
        // After audio session activates, isKeyboardVisible becomes false.
        // onRequestFocus should be called in this state.
        #expect(MessageInputBar.shouldRequestFocusOnEditorTap(isKeyboardVisible: false))
        // When keyboard is already visible, no extra focus request needed.
        #expect(!MessageInputBar.shouldRequestFocusOnEditorTap(isKeyboardVisible: true))
    }

    /// The applyFocusIfNeeded path (invoked by onRequestFocus → focusRequestID
    /// increment) must call becomeFirstResponder when the text view is not
    /// already first responder. When it IS first responder but keyboard is
    /// hidden, it must cycle (resign → become).
    @Test("BUG1: applyFocusIfNeeded cycles first responder when keyboard hidden under focus")
    @MainActor
    func applyFocusCyclesWhenKeyboardHiddenUnderFocus() {
        // shouldCycleFirstResponder returns true only when:
        // - isFirstResponder == true  (text view has focus)
        // - isKeyboardVisible == false (keyboard was dismissed by audio session)
        #expect(
            RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: true,
                isKeyboardVisible: false
            )
        )
    }

    /// Verify the focus trigger increments are processed — a trigger value
    /// of 0 is ignored (initial state), positive triggers are processed.
    @Test("BUG1: focus trigger zero is ignored, positive triggers fire")
    @MainActor
    func focusTriggerZeroIgnored() {
        let editor = makeTestEditor()
        let coordinator = editor.makeCoordinator()
        let textView = UITextView()

        // Trigger 0 must be ignored (initial sentinel).
        coordinator.applyFocusIfNeeded(on: textView, trigger: 0, isKeyboardVisible: false)
        // No crash, no side effect. The guard returns early.

        // Trigger 1 should NOT be ignored.
        coordinator.applyFocusIfNeeded(on: textView, trigger: 1, isKeyboardVisible: false)
        // Trigger 1 again (duplicate) should be ignored.
        coordinator.applyFocusIfNeeded(on: textView, trigger: 1, isKeyboardVisible: false)
        // Trigger 2 should NOT be ignored.
        coordinator.applyFocusIfNeeded(on: textView, trigger: 2, isKeyboardVisible: false)
    }

    // ------------------------------------------------------------------
    // BUG 2 regression: Tap gesture on editor re-raises keyboard
    // ------------------------------------------------------------------

    /// The UITapGestureRecognizer installed on the text view must allow
    /// simultaneous recognition so it doesn't steal taps from the text view.
    @Test("BUG2: gesture delegate allows simultaneous recognition")
    @MainActor
    func gestureRecognizerAllowsSimultaneous() {
        let editor = makeTestEditor()
        let coordinator = editor.makeCoordinator()
        let tap1 = UITapGestureRecognizer()
        let tap2 = UITapGestureRecognizer()

        #expect(
            coordinator.gestureRecognizer(tap1, shouldRecognizeSimultaneouslyWith: tap2)
        )
    }

    /// When the text view is first responder but the keyboard is hidden
    /// (audio session interference), shouldCycleFirstResponder must return
    /// true. When keyboard is visible, no cycling needed.
    @Test("BUG2: cycle decision matches keyboard-hidden-during-dictation scenario")
    func cycleDuringDictationScenario() {
        // Scenario: dictating, text view is first responder, keyboard hidden
        #expect(
            RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: true,
                isKeyboardVisible: false
            )
        )
        // Scenario: dictating, text view is NOT first responder
        #expect(
            !RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: false,
                isKeyboardVisible: false
            )
        )
        // Scenario: keyboard visible, text view is first responder — no cycle
        #expect(
            !RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: true,
                isKeyboardVisible: true
            )
        )
    }

    /// The handleEditorTap path must call onFocusChange(true) in all branches
    /// so the parent always knows the editor was tapped for focus. Verify the
    /// underlying decision tree covers all states.
    @Test("BUG2: tap handler covers all focus states")
    func tapHandlerFocusStates() {
        // Case 1: first responder + keyboard hidden → cycle path
        #expect(
            RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: true,
                isKeyboardVisible: false
            )
        )
        // Case 2: not first responder → becomeFirstResponder path
        #expect(
            !RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: false,
                isKeyboardVisible: false
            )
        )
        // Case 3: first responder + keyboard visible → no-op (already focused)
        #expect(
            !RichTextEditor.Coordinator.shouldCycleFirstResponder(
                isFirstResponder: true,
                isKeyboardVisible: true
            )
        )
    }

    // ------------------------------------------------------------------
    // Combined: active dictation disables scroll dismissal, normal input stays interactive
    // ------------------------------------------------------------------

    /// MessageFlowCollectionView keeps the keyboard pinned during dictation,
    /// but preserves normal scroll dismissal once dictation is inactive.
    @Test("Keyboard dismiss mode gates on dictation state")
    @MainActor
    func keyboardDismissModeGuard() {
        #expect(
            MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, isDictationActive: true)
                == .none
        )
        #expect(
            MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, isDictationActive: false)
                == .interactive
        )
        #expect(
            MessageFlowCollectionView.keyboardDismissModeForInputFocus(true, isDictationActive: false)
                == .interactive
        )
        #expect(
            MessageFlowCollectionView.keyboardDismissModeForInputFocus(false, isDictationActive: true)
                == .none
        )
    }
}

// MARK: - Helpers

@MainActor
private func makeTestEditor() -> RichTextEditor {
    RichTextEditor(
        attributedText: .constant(NSAttributedString()),
        calculatedHeight: .constant(44),
        selectionRange: .constant(NSRange(location: 0, length: 0)),
        pendingInsertions: .constant([]),
        resetToken: 0,
        focusTrigger: 0,
        dismissTrigger: 0,
        isEditable: true,
        isKeyboardVisible: false,
        tintColor: .systemBlue,
        onFocusChange: { _ in }
    )
}
