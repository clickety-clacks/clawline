import CoreFoundation
import Testing
import UIKit
@testable import Clawline

struct ChatLayoutCoordinatorTests {
    @Test("Keyboard appearance uses keyboard duration and scrolls when near bottom")
    @MainActor
    func keyboardAppearanceTransition() {
        let coordinator = ChatLayoutCoordinator()
        let previousInputs = ChatLayoutInputs(
            keyboardHeight: 0,
            keyboardVisible: false,
            isInputFocused: false,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: true
        )
        let inputs = ChatLayoutInputs(
            keyboardHeight: 320,
            keyboardVisible: true,
            isInputFocused: true,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: true
        )
        let transition = coordinator.computeTransition(
            inputs: inputs,
            previousInputs: previousInputs,
            previousInset: 100,
            targetInset: 200,
            barHeight: 44,
            previousBarHeight: 44,
            isUserInteracting: false,
            isPinnedToBottomIntent: true,
            didJustStabilize: false,
            wasNearBottom: true,
            keyboardJustAppeared: true
        )

        #expect(transition.animationDuration == 0.25)
        #expect(transition.animateInsets)
        #expect(transition.scrollAction == .scrollToBottom(animated: false))
    }

    @Test("Input collapse uses default duration and skips scroll adjustments")
    @MainActor
    func inputCollapseTransition() {
        let coordinator = ChatLayoutCoordinator()
        let inputs = ChatLayoutInputs(
            keyboardHeight: 320,
            keyboardVisible: true,
            isInputFocused: true,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: true
        )
        let transition = coordinator.computeTransition(
            inputs: inputs,
            previousInputs: inputs,
            previousInset: 200,
            targetInset: 140,
            barHeight: 44,
            previousBarHeight: 88,
            isUserInteracting: false,
            isPinnedToBottomIntent: false,
            didJustStabilize: false,
            wasNearBottom: false,
            keyboardJustAppeared: false
        )

        #expect(transition.animationDuration == 0.3)
        #expect(transition.scrollAction == .none)
    }

    @Test("Bootstrap stabilization avoids animation when keyboard hidden")
    @MainActor
    func bootstrapStabilizationNoAnimation() {
        let coordinator = ChatLayoutCoordinator()
        let inputs = ChatLayoutInputs(
            keyboardHeight: 0,
            keyboardVisible: false,
            isInputFocused: false,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: true
        )
        let transition = coordinator.computeTransition(
            inputs: inputs,
            previousInputs: inputs,
            previousInset: 100,
            targetInset: 120,
            barHeight: 44,
            previousBarHeight: 44,
            isUserInteracting: false,
            isPinnedToBottomIntent: false,
            didJustStabilize: true,
            wasNearBottom: false,
            keyboardJustAppeared: false
        )

        #expect(transition.animationDuration == 0)
        #expect(!transition.animateInsets)
    }

    @Test("User interaction suppresses scroll actions")
    @MainActor
    func interactiveDismissSuppressesScroll() {
        let coordinator = ChatLayoutCoordinator()
        let inputs = ChatLayoutInputs(
            keyboardHeight: 200,
            keyboardVisible: true,
            isInputFocused: true,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: true
        )
        let transition = coordinator.computeTransition(
            inputs: inputs,
            previousInputs: inputs,
            previousInset: 140,
            targetInset: 160,
            barHeight: 44,
            previousBarHeight: 44,
            isUserInteracting: true,
            isPinnedToBottomIntent: true,
            didJustStabilize: false,
            wasNearBottom: true,
            keyboardJustAppeared: true
        )

        #expect(transition.scrollAction == .none)
    }

    @Test("Inset decrease while pinned does not double-apply offset correction")
    @MainActor
    func pinnedInsetDecreaseSkipsExtraAdjust() {
        let coordinator = ChatLayoutCoordinator()
        let inputs = ChatLayoutInputs(
            keyboardHeight: 300,
            keyboardVisible: true,
            isInputFocused: true,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: true
        )
        let transition = coordinator.computeTransition(
            inputs: inputs,
            previousInputs: inputs,
            previousInset: 220,
            targetInset: 180,
            barHeight: 44,
            previousBarHeight: 44,
            isUserInteracting: false,
            isPinnedToBottomIntent: true,
            didJustStabilize: false,
            wasNearBottom: true,
            keyboardJustAppeared: false
        )

        #expect(transition.scrollAction == .none)
    }

    @Test("T071: First measured bar height immediately updates list bottom inset")
    @MainActor
    func firstMeasuredBarHeightAppliesWithoutSecondTick() {
        let coordinator = ChatLayoutCoordinator()
        let metrics = ChatLayoutMetrics(
            belowBarGap: 24,
            flowGap: 10,
            containerPadding: 12
        )
        let inputs = ChatLayoutInputs(
            keyboardHeight: 0,
            keyboardVisible: false,
            isInputFocused: false,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: true
        )

        let bootstrapHeight = coordinator.currentInsetBarHeight(for: inputs, metrics: metrics)
        #expect(abs(bootstrapHeight - MessageInputBarMetrics.minInputBarHeight) <= 0.5)

        coordinator.updateBarHeight(88)
        let resolvedHeight = coordinator.currentInsetBarHeight(for: inputs, metrics: metrics)
        #expect(abs(resolvedHeight - 88) <= 0.5)
    }

    @Test("T071: Hidden keyboard height does not inflate bottom inset")
    @MainActor
    func hiddenKeyboardHeightIgnoredForInsets() {
        let inputs = ChatLayoutInputs(
            keyboardHeight: 34,
            keyboardVisible: false,
            isInputFocused: false,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 34,
            usesExternalKeyboardInsets: false
        )
        let metrics = ChatLayoutMetrics(
            belowBarGap: 24,
            flowGap: 10,
            containerPadding: 12
        )

        let state = ChatLayoutCoordinator.insetLayoutState(inputs: inputs, metrics: metrics, barHeight: 88)
        #expect(abs(state.keyboardInset) <= 0.5)
        #expect(abs(state.listBottomInset - 110) <= 0.5)
    }

    @Test("T071: Transient zero bar height does not collapse inset after stabilization")
    @MainActor
    func transientZeroBarHeightIsIgnoredAfterStabilization() {
        let coordinator = ChatLayoutCoordinator()
        let metrics = ChatLayoutMetrics(
            belowBarGap: 24,
            flowGap: 10,
            containerPadding: 12
        )
        let inputs = ChatLayoutInputs(
            keyboardHeight: 0,
            keyboardVisible: false,
            isInputFocused: false,
            keyboardAnimationDuration: 0.25,
            keyboardAnimationCurve: .easeInOut,
            safeAreaBottom: 0,
            usesExternalKeyboardInsets: false
        )

        coordinator.updateBarHeight(88)
        _ = coordinator.currentInsetBarHeight(for: inputs, metrics: metrics)
        let before = coordinator.runtimeInsetLayoutState(
            inputs: inputs,
            metrics: metrics,
            fallbackBarHeight: MessageInputBarMetrics.minInputBarHeight
        )

        coordinator.updateBarHeight(0)
        let after = coordinator.runtimeInsetLayoutState(
            inputs: inputs,
            metrics: metrics,
            fallbackBarHeight: MessageInputBarMetrics.minInputBarHeight
        )

        #expect(abs(before.barHeight - 88) <= 0.5)
        #expect(abs(after.barHeight - 88) <= 0.5)
        #expect(abs(after.listBottomInset - before.listBottomInset) <= 0.5)
    }
}
