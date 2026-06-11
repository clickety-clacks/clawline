import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Clawline

@MainActor
private final class TestPanGestureRecognizer: UIPanGestureRecognizer {
    private var stubState: UIGestureRecognizer.State = .possible
    var stubLocation: CGPoint = .zero
    var stubTranslation: CGPoint = .zero
    var stubVelocity: CGPoint = .zero

    override var state: UIGestureRecognizer.State {
        get { stubState }
        set { stubState = newValue }
    }

    override func location(in view: UIView?) -> CGPoint {
        stubLocation
    }

    override func translation(in view: UIView?) -> CGPoint {
        stubTranslation
    }

    override func velocity(in view: UIView?) -> CGPoint {
        stubVelocity
    }

    func setStubState(_ state: UIGestureRecognizer.State) {
        stubState = state
    }
}

@MainActor
private final class TestTextView: UITextView {
    private var simulatedFirstResponder = false

    override var isFirstResponder: Bool {
        simulatedFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        simulatedFirstResponder = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        simulatedFirstResponder = false
        return true
    }
}

@MainActor
private final class PanGestureCoordinatorHarness {
    let coordinator: DictationPanGestureInstaller.Coordinator
    let textView: TestTextView
    let textGestureRecognizer = UIPanGestureRecognizer()

    private let window: UIWindow
    private let rootViewController: UIViewController
    private let installerViewController: DictationPanGestureInstaller.InstallerViewController

    init(onEnded: @escaping (DictationPanEvent, Bool) -> Void = { _, _ in }) {
        guard let resolvedWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first else {
            fatalError("Expected active UIWindow for pan coordinator tests")
        }

        coordinator = DictationPanGestureInstaller.debugCoordinatorForTests(
            shouldBegin: { _, _ in true },
            onEnded: onEnded
        )
        textView = TestTextView(frame: CGRect(x: 24, y: 30, width: 220, height: 56))
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.addGestureRecognizer(textGestureRecognizer)

        window = resolvedWindow
        if let existingRoot = window.rootViewController {
            rootViewController = existingRoot
        } else {
            rootViewController = UIViewController()
            window.rootViewController = rootViewController
        }
        installerViewController = DictationPanGestureInstaller.InstallerViewController()

        rootViewController.loadViewIfNeeded()
        rootViewController.view.addSubview(textView)

        installerViewController.coordinator = coordinator
        rootViewController.addChild(installerViewController)
        rootViewController.view.addSubview(installerViewController.view)
        installerViewController.view.frame = rootViewController.view.bounds
        installerViewController.didMove(toParent: rootViewController)

        rootViewController.view.layoutIfNeeded()

        coordinator.attachIfNeeded(from: installerViewController)
    }

    func beginActiveDragThatLocksSelection() {
        sendPan(state: .began)
        sendPan(state: .changed, translation: CGPoint(x: 0, y: -48), velocity: CGPoint(x: 0, y: -320))
        if textView.isSelectable {
            coordinator.debugPrimeTextViewLock(textView)
        }
        #expect(textView.isSelectable == false)
    }

    func beginActiveDragOnFocusedEditor() {
        _ = textView.becomeFirstResponder()
        sendPan(state: .began)
        sendPan(state: .changed, translation: CGPoint(x: 0, y: -48), velocity: CGPoint(x: 0, y: -320))
        if textGestureRecognizer.isEnabled || textView.isScrollEnabled {
            coordinator.debugPrimeTextViewLock(textView)
        }
    }

    func sendPan(state: UIGestureRecognizer.State, translation: CGPoint = .zero, velocity: CGPoint = .zero) {
        let recognizer = TestPanGestureRecognizer()
        recognizer.stubLocation = textView.superview?.convert(textView.center, to: window) ?? textView.center
        recognizer.stubTranslation = translation
        recognizer.stubVelocity = velocity
        recognizer.setStubState(state)
        let selector = NSSelectorFromString("handlePan:")
        #expect(coordinator.responds(to: selector))
        _ = coordinator.perform(selector, with: recognizer)
    }
}

@Suite(.serialized)
struct MessageInputBarPanIntentTests {
    @Test("Editor-origin gestures can enter arbitration without selection")
    func editorOriginGesturesCanEnterArbitrationWithoutSelection() {
        #expect(
            shouldBeginDictationPanGesture(
                startedInEditableRegion: true,
                isSurfaceVisible: true,
                swipeActivationEnabled: true,
                hasSelection: false,
                startedInSelectionGestureRegion: false
            )
        )
    }

    @Test("Clear upward editor-origin swipe arms dictation")
    func clearUpwardEditorOriginSwipeArmsDictation() {
        #expect(
            shouldBeginDictationPanGesture(
                startedInEditableRegion: true,
                isSurfaceVisible: false,
                swipeActivationEnabled: true,
                hasSelection: false,
                startedInSelectionGestureRegion: false
            )
        )
    }

    @Test("Selection-handle region never arms dictation")
    func selectionHandleRegionNeverArmsDictation() {
        #expect(
            !shouldBeginDictationPanGesture(
                startedInEditableRegion: false,
                isSurfaceVisible: true,
                swipeActivationEnabled: true,
                hasSelection: true,
                startedInSelectionGestureRegion: true
            )
        )
    }

    @Test("Existing text selection keeps drag gestures out of dictation")
    func existingSelectionKeepsDragGesturesOutOfDictation() {
        #expect(
            !shouldBeginDictationPanGesture(
                startedInEditableRegion: false,
                isSurfaceVisible: false,
                swipeActivationEnabled: false,
                hasSelection: true,
                startedInSelectionGestureRegion: false
            )
        )
    }

    @Test("Closed-surface interactive reveal still permits walkie hold arming")
    func closedSurfaceInteractiveRevealStillPermitsWalkieHoldArming() {
        #expect(
            shouldArmWalkieHoldDuringPush(
                pushGestureStartedWithSurfaceOpen: false,
                verticallyDominant: true
            )
        )
        #expect(
            !shouldArmWalkieHoldDuringPush(
                pushGestureStartedWithSurfaceOpen: true,
                verticallyDominant: true
            )
        )
        #expect(
            !shouldArmWalkieHoldDuringPush(
                pushGestureStartedWithSurfaceOpen: false,
                verticallyDominant: false
            )
        )
    }

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

    @Test("Surface-open editor taps keep text interaction instead of stealing keyboard activation")
    func surfaceOpenEditorTapKeepsTextInteraction() {
        let decision = classifyDictationPanIntent(
            .init(
                startedInEditableRegion: true,
                isSurfaceOpen: true,
                elapsed: 0.08,
                translation: CGPoint(x: 0, y: 8),
                velocity: CGPoint(x: 0, y: 40)
            )
        )

        #expect(decision == .textEditing)
    }

    @Test("Fast editor-origin velocity waits for upward displacement")
    func fastEditorOriginVelocityWaitsForUpwardDisplacement() {
        let decision = classifyDictationPanIntent(
            .init(
                startedInEditableRegion: true,
                isSurfaceOpen: false,
                elapsed: 0.01,
                translation: .zero,
                velocity: CGPoint(x: 0, y: -500)
            )
        )

        #expect(decision == .undecided)
    }

    @Test("Long editor-origin cursor movement stays text editing")
    func longEditorOriginCursorMovementStaysTextEditing() {
        let decision = classifyDictationPanIntent(
            .init(
                startedInEditableRegion: true,
                isSurfaceOpen: false,
                elapsed: 0.35,
                translation: CGPoint(x: 0, y: -32),
                velocity: CGPoint(x: 0, y: -420)
            )
        )

        #expect(decision == .textEditing)
    }

    @MainActor
    @Test("Cursor drag inside text view can begin arbitration")
    func cursorDragInsideTextViewCanBeginArbitration() {
        let harness = PanGestureCoordinatorHarness()
        guard let window = harness.textView.window else {
            Issue.record("Expected text view to be attached to a window")
            return
        }
        let location = harness.textView.convert(
            CGPoint(x: harness.textView.bounds.midX, y: harness.textView.bounds.midY),
            to: window
        )

        let shouldBegin = harness.coordinator.debugShouldBeginPanForTesting(
            location: location,
            velocity: CGPoint(x: 260, y: -80),
            window: window
        )

        #expect(shouldBegin)
    }

    @MainActor
    @Test("Cursor drag inside text view does not lock text gestures")
    func cursorDragInsideTextViewDoesNotLockTextGestures() {
        let harness = PanGestureCoordinatorHarness()

        harness.sendPan(state: .began, velocity: CGPoint(x: 260, y: -80))
        harness.sendPan(
            state: .changed,
            translation: CGPoint(x: 30, y: -8),
            velocity: CGPoint(x: 260, y: -80)
        )

        #expect(harness.textGestureRecognizer.isEnabled == true)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)
    }

    @MainActor
    @Test("Fast editor-origin velocity does not lock before displacement")
    func fastEditorOriginVelocityDoesNotLockBeforeDisplacement() {
        let harness = PanGestureCoordinatorHarness()
        _ = harness.textView.becomeFirstResponder()

        harness.sendPan(state: .began, velocity: CGPoint(x: 0, y: -500))

        #expect(harness.textGestureRecognizer.isEnabled == true)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)
    }

    @MainActor
    @Test("Clear upward swipe from editor can begin dictation pan")
    func clearUpwardSwipeFromEditorCanBeginDictationPan() {
        let harness = PanGestureCoordinatorHarness()
        guard let window = harness.textView.window else {
            Issue.record("Expected text view to be attached to a window")
            return
        }
        let location = harness.textView.convert(
            CGPoint(x: harness.textView.bounds.midX, y: harness.textView.bounds.midY),
            to: window
        )

        let shouldBegin = harness.coordinator.debugShouldBeginPanForTesting(
            location: location,
            velocity: CGPoint(x: 0, y: -500),
            window: window
        )

        #expect(shouldBegin)
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

    @MainActor
    @Test("Stream switch during active drag restores selectability")
    func streamSwitchDuringActiveDragRestoresSelectability() {
        let harness = PanGestureCoordinatorHarness()
        harness.beginActiveDragThatLocksSelection()

        // Stream switch replaces the input host and tears down the current installer.
        harness.coordinator.prepareForInstallerDisappear()
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)
    }

    @MainActor
    @Test("Pan ended and cancelled both restore selectability")
    func panEndedAndCancelledBothRestoreSelectability() {
        let harness = PanGestureCoordinatorHarness()

        harness.beginActiveDragThatLocksSelection()
        harness.sendPan(state: .ended)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)

        harness.beginActiveDragThatLocksSelection()
        harness.sendPan(state: .cancelled)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)
    }

    @MainActor
    @Test("Focused editor drag disables text gestures without dropping selectability")
    func focusedEditorDragDisablesTextGesturesWithoutDroppingSelectability() {
        let harness = PanGestureCoordinatorHarness()

        harness.beginActiveDragOnFocusedEditor()
        #expect(harness.textView.isFirstResponder)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textGestureRecognizer.isEnabled == false)

        harness.sendPan(state: .ended)
        #expect(harness.textGestureRecognizer.isEnabled == true)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)
    }

    @MainActor
    @Test("Reported behavior 4: input stays responsive after dictation drag teardown")
    func reportedBehaviorInputRemainsResponsiveAfterDictation() {
        let harness = PanGestureCoordinatorHarness()

        harness.beginActiveDragOnFocusedEditor()
        harness.sendPan(state: .ended)

        harness.textView.selectedRange = NSRange(location: 0, length: 0)
        harness.textView.insertText("h")

        #expect(harness.textGestureRecognizer.isEnabled == true)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)
        #expect(harness.textView.text == "h")
    }

    @MainActor
    @Test("Dismiss callback sees editor interaction restored before surface teardown")
    func dismissCallbackRunsAfterEditorInteractionIsRestored() {
        var selectableDuringEndedCallback: Bool?
        var scrollEnabledDuringEndedCallback: Bool?
        var didReceiveCancellation = false
        var harness: PanGestureCoordinatorHarness?

        harness = PanGestureCoordinatorHarness { _, wasCancelled in
            didReceiveCancellation = wasCancelled
            selectableDuringEndedCallback = harness?.textView.isSelectable
            scrollEnabledDuringEndedCallback = harness?.textView.isScrollEnabled
            harness?.coordinator.prepareForInstallerDisappear()
        }

        guard let harness else {
            Issue.record("Expected pan harness")
            return
        }

        harness.beginActiveDragThatLocksSelection()
        harness.sendPan(state: .ended)

        #expect(didReceiveCancellation == false)
        #expect(selectableDuringEndedCallback == true)
        #expect(scrollEnabledDuringEndedCallback == true)
        #expect(harness.textView.isSelectable == true)
        #expect(harness.textView.isScrollEnabled == true)
    }
}
