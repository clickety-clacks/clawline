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
private final class PanGestureCoordinatorHarness {
    let coordinator: DictationPanGestureInstaller.Coordinator
    let textView: UITextView

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

        coordinator = DictationPanGestureInstaller.debugCoordinatorForTests(onEnded: onEnded)
        textView = UITextView(frame: CGRect(x: 24, y: 30, width: 220, height: 56))
        textView.isSelectable = true
        textView.isScrollEnabled = true

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
