//
//  ChatLayoutCoordinator.swift
//  Clawline
//
//  Created by Codex on 2/1/26.
//

import Observation
import UIKit

struct ChatLayoutInputs: Equatable {
    let keyboardHeight: CGFloat
    let keyboardVisible: Bool
    let isInputFocused: Bool
    let keyboardAnimationDuration: TimeInterval
    let keyboardAnimationCurve: UIView.AnimationCurve
    let safeAreaBottom: CGFloat
    let usesExternalKeyboardInsets: Bool

    var effectiveKeyboardInset: CGFloat {
        guard !usesExternalKeyboardInsets else { return 0 }
        let visibleHeight = max(0, keyboardHeight - safeAreaBottom)
        guard visibleHeight > 0.5 else { return 0 }
        // Keep a continuous release near dismiss, but preserve full keyboard inset when clearly visible.
        let blendProgress = min(1, visibleHeight / 24)
        let compensatedSafeArea = safeAreaBottom * (1 - blendProgress)
        return max(0, keyboardHeight - compensatedSafeArea)
    }
}

struct ChatLayoutMetrics: Equatable {
    let belowBarGap: CGFloat
    let flowGap: CGFloat
    let containerPadding: CGFloat
    let pageIndicatorClearance: CGFloat
}

struct ChatInsetLayoutState: Equatable {
    let barHeight: CGFloat
    let keyboardInset: CGFloat
    let inputBarTopFromScreenBottom: CGFloat
    let listBottomInset: CGFloat
}

struct ChatLayoutTransition: Equatable {
    let animationDuration: TimeInterval
    let animationOptions: UIView.AnimationOptions
    let animateInsets: Bool
    let animateBarPosition: Bool
    let scrollAction: ScrollAction
    let keyboardDelta: CGFloat
}

enum ScrollAction: Equatable {
    case none
    case scrollToBottom(animated: Bool)
    case adjustOffset(delta: CGFloat)
}

struct ChatLayoutKey: Equatable {
    let revision: Int
    let keyboardHeightBucket: Int
    let inputHeightBucket: Int
    let safeAreaBottomBucket: Int
    let isInputFocused: Bool
    let keyboardVisible: Bool
    let belowBarGapBucket: Int
    let flowGapBucket: Int
    let containerPaddingBucket: Int
    let pageIndicatorClearanceBucket: Int

    init(revision: Int,
         keyboardHeight: CGFloat,
         inputHeight: CGFloat,
         safeAreaBottom: CGFloat,
         isInputFocused: Bool,
         keyboardVisible: Bool,
         belowBarGap: CGFloat,
         flowGap: CGFloat,
         containerPadding: CGFloat,
         pageIndicatorClearance: CGFloat) {
        func bucket(_ value: CGFloat) -> Int { Int((value / 0.5).rounded()) }
        self.revision = revision
        self.keyboardHeightBucket = bucket(keyboardHeight)
        self.inputHeightBucket = bucket(inputHeight)
        self.safeAreaBottomBucket = bucket(safeAreaBottom)
        self.isInputFocused = isInputFocused
        self.keyboardVisible = keyboardVisible
        self.belowBarGapBucket = bucket(belowBarGap)
        self.flowGapBucket = bucket(flowGap)
        self.containerPaddingBucket = bucket(containerPadding)
        self.pageIndicatorClearanceBucket = bucket(pageIndicatorClearance)
    }
}

protocol KeyboardPinnedContainerViewProtocol: AnyObject {
    var containerView: UIView { get }
    var barHeight: CGFloat { get }
    func setDesiredBottomGap(_ gap: CGFloat, isKeyboardVisible: Bool)
    func setOnBarHeightChange(_ handler: @escaping (CGFloat) -> Void)
}

@MainActor
@Observable
final class ChatLayoutCoordinator {
    @ObservationIgnored private var barView: KeyboardPinnedContainerViewProtocol?
    @ObservationIgnored private var listViews: [String: WeakBox<MessageFlowCollectionViewController>] = [:]
    @ObservationIgnored private var activeSessionKey: String = ""
    @ObservationIgnored private var latestInputs: ChatLayoutInputs?
    @ObservationIgnored private var latestMetrics: ChatLayoutMetrics?
    @ObservationIgnored private var previousInputs: ChatLayoutInputs?
    @ObservationIgnored private var lastAppliedInset: CGFloat = 0
    @ObservationIgnored private var lastAppliedBarHeight: CGFloat = 0
    @ObservationIgnored private var lastAppliedBelowBarGap: CGFloat = 0
    @ObservationIgnored private var lastAppliedKeyboardVisible: Bool = false
    @ObservationIgnored private var barHeightCache: CGFloat = 0
    @ObservationIgnored private var lastKnownGoodBarHeight: CGFloat = 0
    @ObservationIgnored private var barHeightCandidate: CGFloat = 0
    @ObservationIgnored private var barHeightCandidateApplyIndex: Int = 0
    @ObservationIgnored private var hasStableBarHeight: Bool = false
    @ObservationIgnored private var applyIndex: Int = 0
    @ObservationIgnored private var isApplyingTransition: Bool = false
    @ObservationIgnored private var pendingInputs: (ChatLayoutInputs, ChatLayoutMetrics)?
    @ObservationIgnored private var didApplyThisTick: Bool = false
    @ObservationIgnored private var pendingFallback: Bool = false

    func registerBarView(_ view: KeyboardPinnedContainerViewProtocol) {
        dispatchPrecondition(condition: .onQueue(.main))
        barView = view
        applyTransitionIfPossible(reason: "registerBarView")
    }

    func registerListView(_ view: MessageFlowCollectionViewController, sessionKey: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        listViews[sessionKey] = WeakBox(view)
        applyLatestInset(to: view, isActive: sessionKey == activeSessionKey)
    }

    func setActiveSessionKey(_ sessionKey: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        activeSessionKey = sessionKey
    }

    func scrollToBottom(animated: Bool, attempts: Int = 2) {
        dispatchPrecondition(condition: .onQueue(.main))
        scrollToBottom(sessionKey: activeSessionKey, animated: animated, attempts: attempts)
    }

    func scrollToBottom(sessionKey: String, animated: Bool, attempts: Int = 2) {
        dispatchPrecondition(condition: .onQueue(.main))
        listViews[sessionKey]?.value?.scheduleScrollToBottom(animated: animated, attempts: attempts)
    }

    func scrollToTop(animated: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        scrollToTop(sessionKey: activeSessionKey, animated: animated)
    }

    func scrollToTop(sessionKey: String, animated: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        listViews[sessionKey]?.value?.scrollToTop(animated: animated)
    }

    func scrollToMessageCentered(messageId: String, sessionKey: String, animated: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        listViews[sessionKey]?.value?.scrollToMessageCentered(messageId: messageId, animated: animated)
    }

    func flashMessage(messageId: String, sessionKey: String, isUnreadTap: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        listViews[sessionKey]?.value?.requestFlashMessage(messageId: messageId, isUnreadTap: isUnreadTap)
    }

    func updateInputs(_ inputs: ChatLayoutInputs, metrics: ChatLayoutMetrics) {
        dispatchPrecondition(condition: .onQueue(.main))
        latestInputs = inputs
        latestMetrics = metrics
    }

    func markInputsChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        didApplyThisTick = false
        guard !pendingFallback else { return }
        pendingFallback = true
        Task { @MainActor [weak self] in
            self?.runPendingFallbackIfNeeded()
        }
    }

    func applyTransitionIfPossible(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        didApplyThisTick = true
        cleanupListRefs()
        guard let barView, let inputs = latestInputs, let metrics = latestMetrics else {
            if let inputs = latestInputs, let metrics = latestMetrics {
                pendingInputs = (inputs, metrics)
            }
            return
        }
        if isApplyingTransition {
            pendingInputs = (inputs, metrics)
            return
        }
        applyIndex += 1
        let wasUsingBootstrap = !hasStableBarHeight
        let currentBarHeight = currentInsetBarHeight(for: inputs, metrics: metrics)
        let isUsingBootstrap = !hasStableBarHeight
        let didJustStabilize = wasUsingBootstrap && !isUsingBootstrap
        let targetInset = targetBottomInset(for: inputs, metrics: metrics, barHeight: currentBarHeight)
        let previousInset = lastAppliedInset
        let insetChanged = abs(targetInset - previousInset) > 0.5
        let gapChanged = abs(lastAppliedBelowBarGap - metrics.belowBarGap) > 1
            || lastAppliedKeyboardVisible != inputs.keyboardVisible
        let barHeightChanged = abs(currentBarHeight - lastAppliedBarHeight) > 0.5
        if !insetChanged, !gapChanged, !barHeightChanged {
            previousInputs = inputs
            return
        }
        let list = activeListView()
        let wasNearBottom = list?.isNearBottom(extraMargin: max(MessageFlowCollectionViewController.atBottomThreshold, previousInset)) ?? false
        let keyboardJustAppeared = inputs.isInputFocused && !(previousInputs?.isInputFocused ?? false)
        let transition = computeTransition(
            inputs: inputs,
            previousInputs: previousInputs,
            previousInset: previousInset,
            targetInset: targetInset,
            barHeight: currentBarHeight,
            previousBarHeight: lastAppliedBarHeight,
            isUserInteracting: list?.isActivelyDraggingOrTracking ?? false,
            isPinnedToBottomIntent: list?.isPinnedToBottomIntent ?? false,
            didJustStabilize: didJustStabilize,
            wasNearBottom: wasNearBottom,
            keyboardJustAppeared: keyboardJustAppeared
        )
        previousInputs = inputs
        lastAppliedBarHeight = currentBarHeight
        isApplyingTransition = transition.animateInsets || transition.animateBarPosition
        lastAppliedInset = targetInset

        let applyChanges = { [weak self] in
            guard let self else { return }
            if gapChanged {
                self.lastAppliedBelowBarGap = metrics.belowBarGap
                self.lastAppliedKeyboardVisible = inputs.keyboardVisible
                barView.setDesiredBottomGap(metrics.belowBarGap, isKeyboardVisible: inputs.keyboardVisible)
                barView.containerView.layoutIfNeeded()
            }
            if insetChanged {
                for list in self.listViews.values.compactMap({ $0.value }) {
                    if abs(list.currentBottomInset - targetInset) > 0.5 {
                        list.setBottomInset(targetInset)
                    }
                }
            }
        }

        if transition.animateInsets || transition.animateBarPosition {
            UIView.animate(
                withDuration: transition.animationDuration,
                delay: 0,
                options: [transition.animationOptions, .beginFromCurrentState]
            ) {
                applyChanges()
            } completion: { [weak self] _ in
                guard let self else { return }
                self.isApplyingTransition = false
                self.performScrollAction(transition.scrollAction)
                if let pending = self.pendingInputs {
                    self.pendingInputs = nil
                    self.updateInputs(pending.0, metrics: pending.1)
                    self.applyTransitionIfPossible(reason: "pendingCompletion")
                }
            }
        } else {
            applyChanges()
            performScrollAction(transition.scrollAction)
            isApplyingTransition = false
        }
    }

    func computeTransition(
        inputs: ChatLayoutInputs,
        previousInputs: ChatLayoutInputs?,
        previousInset: CGFloat,
        targetInset: CGFloat,
        barHeight: CGFloat,
        previousBarHeight: CGFloat,
        isUserInteracting: Bool,
        isPinnedToBottomIntent: Bool,
        didJustStabilize: Bool,
        wasNearBottom: Bool,
        keyboardJustAppeared: Bool
    ) -> ChatLayoutTransition {
        let keyboardDelta = inputs.keyboardHeight - (previousInputs?.keyboardHeight ?? 0)
        let keyboardChanged = abs(keyboardDelta) > 0.5
        let barHeightDelta = barHeight - previousBarHeight
        let barHeightChanged = abs(barHeightDelta) > 0.5
        let duration: TimeInterval
        let options = animationOptions(from: inputs.keyboardAnimationCurve)
        if didJustStabilize {
            duration = inputs.keyboardVisible
                ? (inputs.keyboardAnimationDuration > 0 ? inputs.keyboardAnimationDuration : 0.3)
                : 0
        } else if keyboardChanged {
            duration = inputs.keyboardAnimationDuration > 0 ? inputs.keyboardAnimationDuration : 0.3
        } else if barHeightChanged {
            duration = 0.3
        } else {
            duration = 0
        }
        let animate = duration > 0
        let isInsetDecreasing = targetInset < previousInset
        let insetDelta = targetInset - previousInset
        let scrollAction: ScrollAction
        // If the inset isn't meaningfully changing, never issue scroll actions. On visionOS in
        // spatial windows we can see frequent relayout ticks; an unconditional "keep pinned"
        // scroll-to-bottom can create visible oscillation ("flapping") when already at bottom.
        if abs(insetDelta) <= 0.5 {
            scrollAction = .none
        } else if isUserInteracting {
            scrollAction = .none
        } else if keyboardJustAppeared && wasNearBottom {
            scrollAction = .scrollToBottom(animated: false)
        } else if !isInsetDecreasing {
            if wasNearBottom {
                scrollAction = .scrollToBottom(animated: false)
            } else if abs(insetDelta) > 0.5 {
                scrollAction = .adjustOffset(delta: insetDelta)
            } else {
                scrollAction = .none
            }
        } else {
            // #15: When the input bar shrinks (multi-line -> single-line) the bottom inset decreases.
            // If we were pinned near the bottom, keep the bottom anchored by adjusting contentOffset
            // by the inset delta; otherwise the scroll view can appear to have extra "bottom padding".
            if wasNearBottom && abs(insetDelta) > 0.5 {
                // Pinned lists already apply this delta inside `setBottomInset`.
                // Applying it again here can double-shift content downward.
                scrollAction = isPinnedToBottomIntent ? .none : .adjustOffset(delta: insetDelta)
            } else {
                scrollAction = .none
            }
        }
        return ChatLayoutTransition(
            animationDuration: duration,
            animationOptions: options,
            animateInsets: animate,
            animateBarPosition: animate,
            scrollAction: scrollAction,
            keyboardDelta: keyboardDelta
        )
    }

    func updateBarHeight(_ height: CGFloat) {
        dispatchPrecondition(condition: .onQueue(.main))
        let sanitizedHeight = max(0, height)
        if sanitizedHeight > 0.5 {
            lastKnownGoodBarHeight = sanitizedHeight
            if !hasStableBarHeight {
                hasStableBarHeight = true
            }
        } else if hasStableBarHeight, lastKnownGoodBarHeight > 0.5 {
            // Ignore transient zero-height reports during keyboard transitions.
            // The input bar remains mounted; collapsing to zero causes inset underfill/overlap.
            return
        }
        guard abs(barHeightCache - sanitizedHeight) > 0.5 else { return }
        barHeightCache = sanitizedHeight
        // The initial inset application often runs before the input bar has a measured height,
        // so we bootstrap with `minInputBarHeight`. Once the real height is known (layoutSubviews),
        // schedule a re-apply so the bottom inset includes the true bar height + flow gap.
        applyTransitionIfPossible(reason: "barHeight")
    }

    func currentInsetBarHeight(for inputs: ChatLayoutInputs, metrics: ChatLayoutMetrics) -> CGFloat {
        let candidate = barHeightCache
        if candidate > 0.5 {
            if barHeightCandidate <= 0.5 {
                // First real measurement after bootstrap: adopt immediately so underfilled lists
                // account for the full input bar height without waiting for another transition tick.
                barHeightCandidate = candidate
                barHeightCandidateApplyIndex = applyIndex
                hasStableBarHeight = true
            } else if abs(candidate - barHeightCandidate) < 0.5 {
                if applyIndex - barHeightCandidateApplyIndex >= 1 {
                    hasStableBarHeight = true
                }
            } else {
                barHeightCandidate = candidate
                barHeightCandidateApplyIndex = applyIndex
            }
        }
        if hasStableBarHeight {
            if barHeightCache > 0.5 {
                return barHeightCache
            }
            if lastKnownGoodBarHeight > 0.5 {
                return lastKnownGoodBarHeight
            }
        }
        return MessageInputBarMetrics.minInputBarHeight
    }

    private func targetBottomInset(for inputs: ChatLayoutInputs, metrics: ChatLayoutMetrics, barHeight: CGFloat) -> CGFloat {
        Self.insetLayoutState(inputs: inputs, metrics: metrics, barHeight: barHeight).listBottomInset
    }

    static func insetLayoutState(inputs: ChatLayoutInputs, metrics: ChatLayoutMetrics, barHeight: CGFloat) -> ChatInsetLayoutState {
        let resolvedBarHeight = max(0, barHeight)
        let keyboardInset = inputs.effectiveKeyboardInset
        let inputBarTopFromScreenBottom = keyboardInset + metrics.belowBarGap + resolvedBarHeight
        let listBottomInset = inputBarTopFromScreenBottom + metrics.pageIndicatorClearance
            + metrics.flowGap - metrics.containerPadding
        return ChatInsetLayoutState(
            barHeight: resolvedBarHeight,
            keyboardInset: keyboardInset,
            inputBarTopFromScreenBottom: inputBarTopFromScreenBottom,
            listBottomInset: listBottomInset
        )
    }

    func runtimeInsetLayoutState(inputs: ChatLayoutInputs,
                                 metrics: ChatLayoutMetrics,
                                 fallbackBarHeight: CGFloat) -> ChatInsetLayoutState {
        dispatchPrecondition(condition: .onQueue(.main))
        let barHeight = {
            if barHeightCache > 0.5 {
                return barHeightCache
            }
            if lastKnownGoodBarHeight > 0.5 {
                return lastKnownGoodBarHeight
            }
            return max(fallbackBarHeight, MessageInputBarMetrics.minInputBarHeight)
        }()
        return Self.insetLayoutState(inputs: inputs, metrics: metrics, barHeight: barHeight)
    }

    private func animationOptions(from curve: UIView.AnimationCurve) -> UIView.AnimationOptions {
        switch curve {
        case .easeInOut: return .curveEaseInOut
        case .easeIn: return .curveEaseIn
        case .easeOut: return .curveEaseOut
        case .linear: return .curveLinear
        @unknown default: return .curveEaseInOut
        }
    }

    private func activeListView() -> MessageFlowCollectionViewController? {
        listViews[activeSessionKey]?.value
    }

    private func runPendingFallbackIfNeeded() {
        pendingFallback = false
        if !didApplyThisTick {
            applyTransitionIfPossible(reason: "fallback")
        }
    }

    private func applyLatestInset(to view: MessageFlowCollectionViewController, isActive: Bool) {
        guard let inputs = latestInputs, let metrics = latestMetrics, let barView else { return }
        let barHeight = currentInsetBarHeight(for: inputs, metrics: metrics)
        let targetInset = targetBottomInset(for: inputs, metrics: metrics, barHeight: barHeight)
        let previousInset = view.currentBottomInset
        view.setBottomInset(targetInset)
        if isActive {
            let delta = targetInset - previousInset
            // Active pinned lists already self-correct in `setBottomInset`.
            if abs(delta) > 0.5, !view.isPinnedToBottomIntent {
                view.adjustContentOffsetForBottomInsetChange(delta: delta)
            }
        }
        barView.setDesiredBottomGap(metrics.belowBarGap, isKeyboardVisible: inputs.keyboardVisible)
        barView.containerView.layoutIfNeeded()
        lastAppliedInset = targetInset
        lastAppliedBarHeight = barHeight
    }

    private func performScrollAction(_ action: ScrollAction) {
        guard let list = activeListView() else { return }
        switch action {
        case .none:
            break
        case .scrollToBottom(let animated):
            list.scheduleScrollToBottom(animated: animated)
        case .adjustOffset(let delta):
            list.adjustContentOffsetForBottomInsetChange(delta: delta)
        }
    }

    private func cleanupListRefs() {
        listViews = listViews.filter { $0.value.value != nil }
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T?) {
        self.value = value
    }
}
