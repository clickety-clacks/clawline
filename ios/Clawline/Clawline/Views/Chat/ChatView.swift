//
//  ChatView.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit
#if canImport(GameController)
import GameController
#endif
import os.log

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ChatView")

private enum CrossChatShortcutLabelAvailability {
    static var current: Bool {
#if targetEnvironment(macCatalyst)
        true
#elseif os(iOS) && canImport(GameController)
        GCKeyboard.coalesced != nil
#else
        false
#endif
    }
}

#if DEBUG
@MainActor
private final class T099OnDisappearProbeStore {
    struct PendingActiveDisappear {
        let vmObject: String
        let chatViewId: String
    }

    static let shared = T099OnDisappearProbeStore()
    var pendingActiveDisappear: PendingActiveDisappear?
}
#endif

// MARK: - ⚠️⚠️⚠️ CRITICAL: DO NOT MODIFY WITHOUT READING ⚠️⚠️⚠️
//
// This file contains a non-obvious keyboard positioning fix that took 7+ iterations to solve.
// If you are an AI agent or developer planning to modify keyboard/focus/state handling here,
// STOP and read this entire comment block first.
//
// CURRENT STRATEGY (2026-01)
// - Ignore SwiftUI keyboard safe area (.ignoresSafeArea(.keyboard)).
// - Place MessageInputBar in an overlay, not a .safeAreaInset.
// - Drive bar position + list bottom inset directly from keyboard height.
// - Keep input focus state in ChatView (stable parent).
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE PROBLEM
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// MessageInputBar needs to reposition when keyboard appears:
// - Keyboard HIDDEN: Concentric alignment with device corners (~26pt from edges)
// - Keyboard VISIBLE: Positioned above keyboard with smaller gap
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// WHY "OBVIOUS" SOLUTIONS FAIL
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// SwiftUI ties @State, @FocusState, and onChange to a view's IDENTITY. When identity changes,
// ALL state resets silently. Views inside .safeAreaInset get RECREATED when geometry changes
// (like keyboard appearing), which resets their state.
//
// THESE APPROACHES WERE TRIED AND FAILED:
//
// 1. @FocusState in MessageInputBar
//    → View recreated on keyboard appear → @FocusState resets → onChange never fires
//
// 2. @State in MessageInputBar for keyboard tracking
//    → Same problem: view recreation resets state
//
// 3. UIKit keyboard notifications in MessageInputBar
//    → onReceive fires, but @State mutation is lost when view recreates
//
// 4. Passing computed Bool from parent
//    → .safeAreaInset content doesn't re-render on parent state change
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// THE SOLUTION (DO NOT CHANGE WITHOUT UNDERSTANDING)
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. @State isInputFocused lives HERE in ChatView (stable parent, survives geometry changes)
// 2. MessageInputBar reports focus via callback: onFocusChange: { scheduleInputFocusChange($0) }
// 3. Offset modifier applied HERE in ChatView (modifiers on .safeAreaInset content DO update)
//
// KEY INSIGHT: .safeAreaInset content body doesn't re-render on parent state change,
// BUT modifiers applied TO that content from the parent DO update.
//
// ═══════════════════════════════════════════════════════════════════════════════════════════
// IF YOU MUST MODIFY THIS CODE
// ═══════════════════════════════════════════════════════════════════════════════════════════
//
// 1. Understand SwiftUI view identity and state lifetime
// 2. Understand why .safeAreaInset causes view recreation
// 3. Test on device with keyboard show/hide cycling
// 4. Verify concentric alignment visually (equal padding on all sides when keyboard hidden)
// 5. The working solution is tagged: `working-keyboard-behaviors`
//
// ═══════════════════════════════════════════════════════════════════════════════════════════

enum StreamPopupSearchFocus: Equatable {
    case none
    case request(id: Int)
}

enum StreamPopupRoute: Equatable {
    case closed
    case popup(searchFocus: StreamPopupSearchFocus)
    case trackPicker
}

struct ResolvedCrossChatMention: Equatable {
    let destinationChatId: String
    let displayName: String
}

enum CrossChatMentionPickerLogic {
    static func query(inputText: String, resolvedMention: ResolvedCrossChatMention?) -> String? {
        guard resolvedMention == nil else { return nil }
        guard inputText.hasPrefix("@") else { return nil }
        return String(inputText.dropFirst())
    }

    static func filteredStreams(
        streams: [StreamSession],
        currentSessionKey: String,
        query: String
    ) -> [StreamSession] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return streams.filter { stream in
            guard stream.sessionKey != currentSessionKey else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return stream.displayName.lowercased().contains(normalizedQuery)
        }
    }

    static func selectionAfterMoving(
        currentSessionKey: String?,
        filteredStreams: [StreamSession],
        step: Int
    ) -> String? {
        guard !filteredStreams.isEmpty else { return nil }
        let currentIndex = currentSessionKey.flatMap { sessionKey in
            filteredStreams.firstIndex { $0.sessionKey == sessionKey }
        } ?? 0
        let nextIndex = min(max(currentIndex + step, 0), filteredStreams.count - 1)
        return filteredStreams[nextIndex].sessionKey
    }
}

@MainActor
@Observable
final class StreamPopupRouteController {
    private(set) var route: StreamPopupRoute = .closed
    private var searchFocusRequestID = 0

    var isPopupPresented: Bool {
        if case .popup = route {
            return true
        }
        return false
    }

    var isTrackPickerPresented: Bool {
        route == .trackPicker
    }

    var popupSearchFocusRequestID: Int? {
        guard case .popup(.request(let id)) = route else { return nil }
        return id
    }

    func openPopup(focusSearch: Bool) {
        if focusSearch {
            searchFocusRequestID &+= 1
            route = .popup(searchFocus: .request(id: searchFocusRequestID))
        } else {
            route = .popup(searchFocus: .none)
        }
    }

    func closePopup() {
        route = .closed
    }

    func presentTrackPicker() {
        route = .trackPicker
    }

    func dismissTrackPicker() {
        route = .closed
    }

    func consumeSearchFocusRequest() {
        guard popupSearchFocusRequestID != nil else { return }
        route = .popup(searchFocus: .none)
    }
}

struct ChatView: View {
    private static var t217DiagnosticBuild: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "T217-typing-cancel-\(build)"
    }

    @Bindable var viewModel: ChatViewModel
    let toastManager: ToastManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthManager.self) private var authManager

    // ⚠️ CRITICAL: This state MUST live here in ChatView, NOT in MessageInputBar.
    // MessageInputBar is inside .safeAreaInset and gets recreated on geometry changes.
    // State in recreated views resets silently. See header comment for full explanation.
    @State private var isInputFocused = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var lastNonZeroKeyboardHeight: CGFloat = 0
    @State private var keyboardAnimationDuration: TimeInterval = 0.3
    @State private var keyboardAnimationCurve: UIView.AnimationCurve = .easeInOut
    @State private var keyboardRefreshToken: Int = 0
    @State private var layoutCoordinator = ChatLayoutCoordinator()
    @State private var layoutRevision: Int = 0
    @State private var selectionRange = NSRange(location: 0, length: 0)
    @State private var pendingInputInsertions: [PendingAttachment] = []
    @State private var inputBarSendButtonConnectionState = SendButtonConnectionStateStore()
    @State private var resolvedCrossChatMention: ResolvedCrossChatMention?
    @State private var highlightedCrossChatMentionSessionKey: String?
    @State private var activeSheet: ChatSheet?
    @State private var isAttachmentMenuPresented = false
    @State private var streamPopupRouteController = StreamPopupRouteController()
    @State private var isPhotosPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var isCancelCurrentPromptDialogPresented = false
    @State private var cancelCurrentPromptSessionKey: String?
    @State private var cancelCurrentPromptRequiresVisibleTyping = false
    @State private var cancelCurrentPromptAnchorFrame: CGRect?
    @State private var latestTypingIndicatorAnchorFrameBySessionKey: [String: CGRect] = [:]
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var focusRequestID = 0
    @State private var shouldRestoreFocusAfterPicker = false
    @State private var scrollButtonStateBySessionKey: [String: ScrollButtonState] = [:]
    @State private var scrollButtonDragTranslation: CGFloat = 0
    @State private var scrollButtonIsDragging = false
    @State private var scrollButtonSuppressNextTap = false
    @State private var scrollButtonIsDetentSettling = false
    @State private var scrollButtonSettleStartOffset: CGFloat?
    @State private var scrollButtonSettleAnimationToken: Int = 0
    @State private var scrollButtonSettleTask: Task<Void, Never>?
    @State private var scrollButtonTapSuppressionTask: Task<Void, Never>?
    @AppStorage("chat.scrollButton.horizontalDetent") private var scrollButtonDetentRawValue = ScrollButtonHorizontalDetent.center.rawValue

    init(viewModel: ChatViewModel, toastManager: ToastManager) {
        self._viewModel = Bindable(wrappedValue: viewModel)
        self.toastManager = toastManager
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.settingsManager) private var settings

    @State private var inputBarHeight: CGFloat = 0
    @State private var isTypingActive = false
    @State private var typingActivityResetTask: Task<Void, Never>?
    @State private var streamToastManager = StreamToastManager()
    @State private var streamToastBusySince: Date?
    @State private var streamToastBusyClearTask: Task<Void, Never>?
    @State private var isCrossChatNotificationStackDocked = false
    @State private var crossChatNotificationReplyPinSlotsBySourceChatId: [String: Int] = [:]
    @State private var crossChatNotificationMeasuredHeightsBySourceChatId: [String: CGFloat] = [:]
    @State private var crossChatNotificationActionMenuSourceChatId: String?
    @State private var crossChatNotificationFocusedSourceChatId: String?
    @State private var crossChatNotificationFocusedReplySourceChatId: String?
    @State private var chatViewTraceId = UUID().uuidString
#if DEBUG
    @State private var lifecycleDebugOverlayVisible = true
    @State private var lifecycleDebugOverlayDismissTask: Task<Void, Never>?
    @State private var probeTaskEnterCount = 0
    @State private var probeOnAppearCount = 0
    @State private var probeOnDisappearCount = 0
    @State private var probeLatestOnAppearConnState = "unknown"
    @State private var probeLatestInstanceId = ""
    @State private var probeLatestVmObject = ""
    @State private var probeLastOnDisappearCause = "unknown"
    @State private var probeLastOnDisappearPreviousVMObject = "-"
    @State private var probeLastOnDisappearPreviousChatViewId = "-"
    @State private var probeLastOnDisappearCurrentVMObject = "-"
    @State private var probeLastOnDisappearCurrentChatViewId = "-"

    private var isLifecycleDebugOverlayEnabled: Bool {
        settings.isLifecycleDebugOverlayEnabled
    }
#endif

    private let streamToastMinimumBusySeconds: TimeInterval = 0.45
    private let typingActivitySettleDelay: Duration = .milliseconds(180)

    private var shouldInvalidateLayoutRevisionOnInputBarHeightChange: Bool {
#if os(visionOS)
        false
#else
        true
#endif
    }

    private var spatialOverlayDepthOffset: CGFloat {
#if os(visionOS)
        48
#else
        0
#endif
    }

    private var isKeyboardVisible: Bool {
        keyboardHeight > 0.5
    }

    private var fontScaleChangeSequence: Int {
        settings.fontScaleChangeSequence
    }

    private enum ChatSheet: Identifiable {
        case expandedMessage(Message)
        case camera

        var id: String {
            switch self {
            case .expandedMessage(let message):
                return "expandedMessage-\(message.id)"
            case .camera:
                return "camera"
            }
        }
    }

    private struct ScrollButtonState: Equatable {
        var isVisible: Bool = false
        var unreadCount: Int = 0
        var firstUnreadMessageId: String?
        var bounceToken: Int = 0
    }

    private enum ScrollButtonHorizontalDetent: String, CaseIterable {
        case left
        case center
        case right

        var unitOffset: CGFloat {
            switch self {
            case .left:
                return -1
            case .center:
                return 0
            case .right:
                return 1
            }
        }
    }

    private let floatingPageDotsBottomGap: CGFloat = 12
    private let floatingScrollButtonBottomGap: CGFloat = 58
    private let scrollButtonHorizontalSideInset: CGFloat = 28
    private let scrollButtonFlickThreshold: CGFloat = 28
    private let scrollButtonSettleDuration: Duration = .milliseconds(420)
    private let scrollButtonTapSuppressionDuration: Duration = .milliseconds(220)
    private let scrollButtonDragTapSuppressionThreshold: CGFloat = 6

    private var scrollButtonDetent: ScrollButtonHorizontalDetent {
        get { ScrollButtonHorizontalDetent(rawValue: scrollButtonDetentRawValue) ?? .center }
        nonmutating set { scrollButtonDetentRawValue = newValue.rawValue }
    }

    private var isDebugForcingScrollButtonVisible: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--debug-force-scroll-button")
#else
        false
#endif
    }

    private func currentMentionPickerQuery() -> String? {
        CrossChatMentionPickerLogic.query(
            inputText: viewModel.inputContent.string,
            resolvedMention: resolvedCrossChatMention
        )
    }

    private func resolveCrossChatMention(_ stream: StreamSession) {
        let queryLength = currentMentionPickerQuery().map { $0.count + 1 } ?? 0
        resolvedCrossChatMention = ResolvedCrossChatMention(
            destinationChatId: stream.sessionKey,
            displayName: stream.displayName
        )
        highlightedCrossChatMentionSessionKey = stream.sessionKey
        let mutable = NSMutableAttributedString(attributedString: viewModel.inputContent)
        if queryLength > 0, mutable.length >= queryLength {
            mutable.deleteCharacters(in: NSRange(location: 0, length: queryLength))
        }
        mutable.removeCrossChatMentionAttachments()
        mutable.insert(
            NSAttributedString(
                attachment: CrossChatMentionTextAttachment(
                    destinationChatId: stream.sessionKey,
                    displayName: stream.displayName
                )
            ),
            at: 0
        )
        if mutable.length == 1 || mutable.string.dropFirst().first?.isWhitespace == false {
            mutable.insert(NSAttributedString(string: " "), at: 1)
        }
        viewModel.inputContent = mutable
        selectionRange = NSRange(location: min(mutable.length, 2), length: 0)
        viewModel.refreshInputEditorContent()
        focusRequestID &+= 1
    }

    private func removeResolvedCrossChatMention(restoreFocus: Bool = true) {
        resolvedCrossChatMention = nil
        highlightedCrossChatMentionSessionKey = nil
        let mutable = NSMutableAttributedString(attributedString: viewModel.inputContent)
        mutable.removeCrossChatMentionAttachments()
        viewModel.inputContent = mutable
        selectionRange = NSRange(location: min(selectionRange.location, mutable.length), length: 0)
        viewModel.refreshInputEditorContent()
        if restoreFocus {
            focusRequestID &+= 1
        }
    }

    private func reconcileResolvedMentionAttachment() {
        guard resolvedCrossChatMention != nil else { return }
        guard !viewModel.inputContent.containsCrossChatMentionAttachment else { return }
        resolvedCrossChatMention = nil
        highlightedCrossChatMentionSessionKey = nil
    }

    private func handleCrossChatMentionMove(filteredStreams: [StreamSession], step: Int) {
        highlightedCrossChatMentionSessionKey = CrossChatMentionPickerLogic.selectionAfterMoving(
            currentSessionKey: highlightedCrossChatMentionSessionKey,
            filteredStreams: filteredStreams,
            step: step
        )
    }

    private func handleCrossChatMentionTab(filteredStreams: [StreamSession]) {
        let target = highlightedCrossChatMentionSessionKey
            .flatMap { sessionKey in filteredStreams.first { $0.sessionKey == sessionKey } }
            ?? filteredStreams.first
        guard let target else { return }
        resolveCrossChatMention(target)
    }

    private func scrollButtonState(for sessionKey: String) -> ScrollButtonState {
        var state = scrollButtonStateBySessionKey[sessionKey] ?? ScrollButtonState()
        if isDebugForcingScrollButtonVisible {
            state.isVisible = true
        }
        return state
    }

    private func mutateScrollButtonState(for sessionKey: String, _ mutate: (inout ScrollButtonState) -> Void) {
        let currentState = scrollButtonStateBySessionKey[sessionKey] ?? ScrollButtonState()
        var state = currentState
        if isDebugForcingScrollButtonVisible {
            state.isVisible = true
        }
        mutate(&state)
        guard state != currentState else { return }
        scrollButtonStateBySessionKey[sessionKey] = state
    }

    private func handleMessageFlowScrollEvent(_ event: MessageFlowScrollEvent) {
        guard !streamPopupRouteController.isPopupPresented else { return }
        switch event {
        case .isAtBottomChanged(let sessionKey, let isAtBottom):
            mutateScrollButtonState(for: sessionKey) { state in
                state.isVisible = !isAtBottom
                if isAtBottom {
                    state.unreadCount = 0
                    state.firstUnreadMessageId = nil
                }
            }
        case .didReceiveNewMessagesWhileScrolledUp(let sessionKey, let newMessageIDs):
            guard let first = newMessageIDs.first else { return }
            mutateScrollButtonState(for: sessionKey) { state in
                state.isVisible = true
                if state.firstUnreadMessageId == nil {
                    state.firstUnreadMessageId = first
                }
                state.unreadCount += newMessageIDs.count
                state.bounceToken &+= 1
            }
        case .didCrossFirstUnreadCenter(let sessionKey, _):
            mutateScrollButtonState(for: sessionKey) { state in
                state.unreadCount = 0
                state.firstUnreadMessageId = nil
            }
        case .didInvalidateFirstUnreadAnchor(let sessionKey):
            mutateScrollButtonState(for: sessionKey) { state in
                state.unreadCount = 0
                state.firstUnreadMessageId = nil
            }
        }
    }

    private func handleDeferredMessageFlowScrollEvent(_ event: MessageFlowScrollEvent) {
        DispatchQueue.main.async {
            handleMessageFlowScrollEvent(event)
        }
    }

    private func scrollButtonMaxHorizontalOffset(containerWidth: CGFloat) -> CGFloat {
        // Keep the floating button comfortably inboard from the edge.
        let buttonRadius: CGFloat = 22
        return max(0, (containerWidth / 2) - scrollButtonHorizontalSideInset - buttonRadius)
    }

    private func scrollButtonHorizontalOffset(
        for detent: ScrollButtonHorizontalDetent,
        containerWidth: CGFloat
    ) -> CGFloat {
        scrollButtonMaxHorizontalOffset(containerWidth: containerWidth) * detent.unitOffset
    }

    private func activeScrollButtonHorizontalOffset(containerWidth: CGFloat) -> CGFloat {
        let maxOffset = scrollButtonMaxHorizontalOffset(containerWidth: containerWidth)
        let base = scrollButtonHorizontalOffset(for: scrollButtonDetent, containerWidth: containerWidth)
        return min(max(base + scrollButtonDragTranslation, -maxOffset), maxOffset)
    }

    private func armScrollButtonTapSuppression() {
        scrollButtonSuppressNextTap = true
        scrollButtonTapSuppressionTask?.cancel()
        scrollButtonTapSuppressionTask = Task { @MainActor in
            try? await Task.sleep(for: scrollButtonTapSuppressionDuration)
            scrollButtonSuppressNextTap = false
        }
    }

    private func resetScrollButtonInteractionState() {
        scrollButtonSettleTask?.cancel()
        scrollButtonTapSuppressionTask?.cancel()
        scrollButtonSettleTask = nil
        scrollButtonTapSuppressionTask = nil
        scrollButtonDragTranslation = 0
        scrollButtonIsDragging = false
        scrollButtonSuppressNextTap = false
        scrollButtonIsDetentSettling = false
        scrollButtonSettleStartOffset = nil
    }

    private func handleScrollButtonDragChanged(_ value: DragGesture.Value, containerWidth: CGFloat) {
        guard !scrollButtonIsDetentSettling else { return }
        scrollButtonIsDragging = true
        let maxOffset = scrollButtonMaxHorizontalOffset(containerWidth: containerWidth)
        let base = scrollButtonHorizontalOffset(for: scrollButtonDetent, containerWidth: containerWidth)
        let clamped = min(max(base + value.translation.width, -maxOffset), maxOffset)
        scrollButtonDragTranslation = clamped - base
    }

    private func handleScrollButtonDragEnded(_ value: DragGesture.Value, containerWidth: CGFloat) {
        handleScrollButtonDragEnded(
            translationWidth: value.translation.width,
            predictedTranslationWidth: value.predictedEndTranslation.width,
            containerWidth: containerWidth
        )
    }

    private func handleScrollButtonDragEnded(
        translationWidth: CGFloat,
        predictedTranslationWidth: CGFloat,
        containerWidth: CGFloat
    ) {
        guard !scrollButtonIsDetentSettling else { return }
        scrollButtonIsDragging = false
        if abs(translationWidth) >= scrollButtonDragTapSuppressionThreshold {
            armScrollButtonTapSuppression()
        }
        let maxOffset = scrollButtonMaxHorizontalOffset(containerWidth: containerWidth)
        guard maxOffset > 0.5 else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                scrollButtonDetent = .center
                scrollButtonDragTranslation = 0
            }
            return
        }

        let base = scrollButtonHorizontalOffset(for: scrollButtonDetent, containerWidth: containerWidth)
        let endOffset = min(max(base + translationWidth, -maxOffset), maxOffset)
        let predictedOffset = min(max(base + predictedTranslationWidth, -maxOffset), maxOffset)
        let flickDelta = predictedOffset - endOffset
        let targetDetent = targetScrollButtonDetent(
            near: endOffset,
            flickDelta: flickDelta,
            containerWidth: containerWidth
        )
        let shouldRunSettleWindow = targetDetent != scrollButtonDetent || abs(endOffset - base) > 0.5

        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            scrollButtonDetent = targetDetent
            scrollButtonDragTranslation = 0
        }
        if shouldRunSettleWindow {
            scrollButtonSettleStartOffset = endOffset
            scrollButtonSettleAnimationToken &+= 1
            scrollButtonIsDetentSettling = true
            scrollButtonSettleTask?.cancel()
            scrollButtonSettleTask = Task { @MainActor in
                try? await Task.sleep(for: scrollButtonSettleDuration)
                scrollButtonIsDetentSettling = false
                scrollButtonSettleStartOffset = nil
            }
        } else {
            scrollButtonSettleStartOffset = nil
        }
    }

    private func targetScrollButtonDetent(
        near endOffset: CGFloat,
        flickDelta: CGFloat,
        containerWidth: CGFloat
    ) -> ScrollButtonHorizontalDetent {
        let detents = ScrollButtonHorizontalDetent.allCases.map {
            ($0, scrollButtonHorizontalOffset(for: $0, containerWidth: containerWidth))
        }

        if abs(flickDelta) >= scrollButtonFlickThreshold {
            if flickDelta > 0 {
                if let nearestToRight = detents.filter({ $0.1 > endOffset + 0.5 }).min(by: { $0.1 < $1.1 }) {
                    return nearestToRight.0
                }
                return .right
            } else {
                if let nearestToLeft = detents.filter({ $0.1 < endOffset - 0.5 }).max(by: { $0.1 < $1.1 }) {
                    return nearestToLeft.0
                }
                return .left
            }
        }

        return detents.min(by: { abs($0.1 - endOffset) < abs($1.1 - endOffset) })?.0 ?? .center
    }

    private func handleScrollButtonTap(sessionKey: String, viewModel: ChatViewModel) {
        guard !scrollButtonIsDetentSettling else { return }
        if scrollButtonSuppressNextTap {
            scrollButtonSuppressNextTap = false
            return
        }
        let current = scrollButtonState(for: sessionKey)
        if current.unreadCount > 0 {
            if let firstUnread = current.firstUnreadMessageId {
                let hasTarget = viewModel.messages(for: sessionKey).contains(where: { $0.id == firstUnread })
                if hasTarget {
                    layoutCoordinator.scrollToMessageCentered(messageId: firstUnread, sessionKey: sessionKey, animated: true)
                    layoutCoordinator.flashMessage(messageId: firstUnread, sessionKey: sessionKey, isUnreadTap: true)
                } else {
                    layoutCoordinator.scrollToBottom(sessionKey: sessionKey, animated: true)
                }
            } else {
                layoutCoordinator.scrollToBottom(sessionKey: sessionKey, animated: true)
            }
            mutateScrollButtonState(for: sessionKey) { s in
                s.unreadCount = 0
                s.firstUnreadMessageId = nil
            }
            return
        }
        layoutCoordinator.scrollToBottom(sessionKey: sessionKey, animated: true, attempts: 1)
    }

    private func scrollButtonControl(
        state: ScrollButtonState,
        containerWidth: CGFloat,
        onTap: @escaping () -> Void
    ) -> some View {
        ScrollToBottomButton(
            isVisible: state.isVisible,
            unreadCount: state.unreadCount,
            bounceToken: state.bounceToken,
            onTap: onTap
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func floatingPageDotsView(
        viewModel: ChatViewModel,
        inputBarTopFromScreenBottom: CGFloat,
        streamSelectorMaxHeight: CGFloat,
        containerWidth: CGFloat,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        let effectiveStreams = viewModel.orderedStreams
        let effectiveSessionKeys = effectiveStreams.map(\.sessionKey)
        if !effectiveSessionKeys.isEmpty {
            streamPageDotsControl(
                viewModel: viewModel,
                effectiveStreams: effectiveStreams,
                streamSelectorMaxHeight: streamSelectorMaxHeight,
                containerWidth: containerWidth,
                bottomSafeAreaInset: bottomSafeAreaInset
            )
            .padding(.bottom, inputBarTopFromScreenBottom + floatingPageDotsBottomGap)
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }


    var body: some View {
        chatBody
    }

    @ViewBuilder
    private var chatBody: some View {
        @Bindable var viewModel = viewModel
        @Bindable var toastManager = toastManager
        let _ = fontScaleChangeSequence

        GeometryReader { geometry in
            chatContent(geometry: geometry, viewModel: viewModel, toastManager: toastManager)
        }
        .background {
            // Background extends edge-to-edge. Admin users with paged TabView have
            // per-page backgrounds for the gradient; regular users get background here.
#if os(visionOS)
            Color.clear
#else
            ChatFlowTheme.pageBackground(colorScheme)
                .ignoresSafeArea()
                .overlay(NoiseOverlayView().ignoresSafeArea())
#endif
        }
        .task {
#if DEBUG
            recordProbeEvent(
                kind: .taskEnter,
                instanceId: viewModel.debugInstanceId,
                vmObject: String(describing: ObjectIdentifier(viewModel)),
                connState: String(describing: viewModel.connectionState)
            )
#endif
            logger.info(
                "[T099-PIN] chatView=\(self.chatViewTraceId, privacy: .public) event=task_enter vm=\(self.viewModel.debugInstanceId, privacy: .public) vmObject=\(String(describing: ObjectIdentifier(self.viewModel)), privacy: .public) scenePhase=\(String(describing: scenePhase), privacy: .public)"
            )
            viewModel.handleSceneActiveStateChanged(isActive: scenePhase == .active)
            await viewModel.onAppear(origin: "ChatView.task[\(chatViewTraceId)] scene=\(String(describing: scenePhase))")
        }
        .onAppear {
#if DEBUG
            recordProbeEvent(
                kind: .onAppear,
                instanceId: viewModel.debugInstanceId,
                vmObject: String(describing: ObjectIdentifier(viewModel)),
                connState: String(describing: viewModel.connectionState)
            )
#endif
            logger.info(
                "[T099-PIN] chatView=\(self.chatViewTraceId, privacy: .public) event=onAppear vm=\(self.viewModel.debugInstanceId, privacy: .public) vmObject=\(String(describing: ObjectIdentifier(self.viewModel)), privacy: .public) scenePhase=\(String(describing: scenePhase), privacy: .public) connState=\(String(describing: self.viewModel.connectionState), privacy: .public)"
            )
        }
        .onDisappear {
#if DEBUG
            recordProbeEvent(
                kind: .onDisappear,
                instanceId: viewModel.debugInstanceId,
                vmObject: String(describing: ObjectIdentifier(viewModel)),
                connState: String(describing: viewModel.connectionState)
            )
#endif
            logger.info(
                "[T099-PIN] chatView=\(self.chatViewTraceId, privacy: .public) event=onDisappear vm=\(self.viewModel.debugInstanceId, privacy: .public) vmObject=\(String(describing: ObjectIdentifier(self.viewModel)), privacy: .public) scenePhase=\(String(describing: scenePhase), privacy: .public)"
            )
            viewModel.onDisappear(origin: "ChatView.onDisappear[\(chatViewTraceId)] scene=\(String(describing: scenePhase))")
            resetScrollButtonInteractionState()
            streamPopupRouteController.closePopup()
#if DEBUG
            lifecycleDebugOverlayDismissTask?.cancel()
            lifecycleDebugOverlayDismissTask = nil
#endif
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.handleSceneActiveStateChanged(isActive: phase == .active)
            guard phase == .active else { return }
            keyboardRefreshToken &+= 1
        }
        .handlePromptFocusCommand(
            onFocusRequested: {
                focusRequestID &+= 1
            }
        )
        .handleStreamPopupCommand(
            hasStreams: !viewModel.orderedStreams.isEmpty,
            onOpen: {
                streamPopupRouteController.openPopup(focusSearch: true)
            }
        )
        .handleStreamNavigationCommands(
            isEnabled: !viewModel.orderedStreams.isEmpty,
            onNavigatePrevious: { navigateStreamByShortcut(step: -1, sessionKeys: viewModel.orderedStreams.map(\.sessionKey)) },
            onNavigateNext: { navigateStreamByShortcut(step: 1, sessionKeys: viewModel.orderedStreams.map(\.sessionKey)) }
        )
#if DEBUG
        .onChange(of: viewModel.lifecycleDebugSequence) { _, _ in
            showLifecycleDebugOverlay()
        }
        .onChange(of: settings.isLifecycleDebugOverlayEnabled) { _, enabled in
            if enabled {
                showLifecycleDebugOverlay()
            } else {
                lifecycleDebugOverlayVisible = false
                lifecycleDebugOverlayDismissTask?.cancel()
                lifecycleDebugOverlayDismissTask = nil
            }
        }
#endif
        .background(
            KeyboardLayoutGuideReader(refreshToken: keyboardRefreshToken) { height, duration, curve in
                if abs(height - keyboardHeight) > 0.5 {
                    withAnimation(nil) {
                        keyboardHeight = height
                    }
                }
                if height > 0.5, lastNonZeroKeyboardHeight <= 0.5 {
                    lastNonZeroKeyboardHeight = height
                    layoutRevision &+= 1
                }
                if abs(duration - keyboardAnimationDuration) > 0.001 {
                    keyboardAnimationDuration = duration
                }
                if curve != keyboardAnimationCurve {
                    keyboardAnimationCurve = curve
                }
            }
        )
        .sheet(item: $activeSheet, content: sheetView)
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoPickerItems,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await withAttachmentStaging {
                    await handlePhotoPickerItems(newItems)
                }
                await MainActor.run {
                    photoPickerItems = []
                    restoreFocusIfNeeded()
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await withAttachmentStaging {
                        await handleDocumentResults(urls)
                    }
                    await MainActor.run { restoreFocusIfNeeded() }
                }
            case .failure:
                restoreFocusIfNeeded()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toastManager.toast)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: streamToastManager.isVisible)
    }

    @ViewBuilder
    private func chatContent(geometry: GeometryProxy,
                             viewModel: ChatViewModel,
                             toastManager: ToastManager) -> some View {
        @Bindable var viewModel = viewModel
        let statusBarTopInset: CGFloat = geometry.safeAreaInsets.top
        let messageListTopInset = geometry.safeAreaInsets.top
        let isCompactLayout = horizontalSizeClass == .compact
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompactLayout)
        let resolvedInputHeight = max(inputBarHeight, MessageInputBarMetrics.minInputBarHeight)
        let keyboardVisibleHeight = max(0, keyboardHeight - geometry.safeAreaInsets.bottom)
        let isKeyboardVisible = keyboardVisibleHeight > 0.5
        let effectiveStreams = viewModel.orderedStreams
        let effectiveSessionKeys = effectiveStreams.map(\.sessionKey)
        let sendButtonConnectionState = viewModel.sendButtonConnectionState
        let showsStreamPager = !effectiveSessionKeys.isEmpty
        let pageIndicatorClearance: CGFloat = {
            guard showsStreamPager else { return 0 }
            return floatingPageDotsBottomGap + StreamPageDotsView.controlHeight
        }()
        let bottomFlowGap: CGFloat = isCompactLayout
            ? metrics.flowGap
            : ChatFlowTheme.Metrics(isCompact: false).flowGap
        let bottomInsetFlowGap = bottomFlowGap
        // Keep the bar gap continuous through the final keyboard-dismiss frames.
        let keyboardInsetProgress = min(1, max(0, keyboardVisibleHeight / 24))
        let belowBarGap: CGFloat = 24 - (12 * keyboardInsetProgress)
        let usesExternalKeyboardInsets: Bool = {
#if os(visionOS)
            // visionOS keyboard geometry can over-report and cause content overlap drift after
            // keyboard transitions. The input bar is pinned from container geometry instead.
            return true
#else
            return false
#endif
        }()
        let layoutInputs = ChatLayoutInputs(
            keyboardHeight: keyboardHeight,
            keyboardVisible: isKeyboardVisible,
            isInputFocused: isInputFocused,
            keyboardAnimationDuration: keyboardAnimationDuration,
            keyboardAnimationCurve: keyboardAnimationCurve,
            safeAreaBottom: geometry.safeAreaInsets.bottom,
            usesExternalKeyboardInsets: usesExternalKeyboardInsets
        )
        let layoutMetrics = ChatLayoutMetrics(
            belowBarGap: belowBarGap,
            flowGap: bottomInsetFlowGap,
            containerPadding: metrics.containerPadding,
            pageIndicatorClearance: pageIndicatorClearance
        )
        let insetLayout = layoutCoordinator.runtimeInsetLayoutState(
            inputs: layoutInputs,
            metrics: layoutMetrics,
            fallbackBarHeight: resolvedInputHeight
        )
        let inputBarTopFromScreenBottom = insetLayout.inputBarTopFromScreenBottom
        let cachedKeyboardHeight = max(layoutInputs.effectiveKeyboardInset, lastNonZeroKeyboardHeight)
        let isLandscape = geometry.size.width > geometry.size.height
        let estimatedKeyboardHeight: CGFloat = {
            if horizontalSizeClass == .regular {
                return isLandscape ? 300 : 360
            }
            return isLandscape ? 216 : 300
        }()
        let truncationKeyboardHeight = cachedKeyboardHeight > 0.5 ? cachedKeyboardHeight : estimatedKeyboardHeight
        let truncationBottomInset = truncationKeyboardHeight + 12 + resolvedInputHeight
            + pageIndicatorClearance + bottomInsetFlowGap - metrics.containerPadding
        let layoutKey = ChatLayoutKey(
            revision: layoutRevision,
            keyboardHeight: keyboardHeight,
            inputHeight: resolvedInputHeight,
            safeAreaBottom: geometry.safeAreaInsets.bottom,
            isInputFocused: isInputFocused,
            keyboardVisible: isKeyboardVisible,
            belowBarGap: belowBarGap,
            flowGap: bottomInsetFlowGap,
            containerPadding: metrics.containerPadding,
            pageIndicatorClearance: pageIndicatorClearance
        )
        let streamSelectorSpacingFromMessageBarTop: CGFloat = 8
        let streamSelectorMaxHeight = max(
            0,
            geometry.size.height
                - inputBarTopFromScreenBottom
                - messageListTopInset
                - streamSelectorSpacingFromMessageBarTop
        )
        let promptFocusShortcutEnabled = !isInputFocused
            && streamPopupRouteController.route == .closed
            && activeSheet == nil
            && !isAttachmentMenuPresented
            && !isPhotosPickerPresented
            && !isFileImporterPresented
        let mentionQuery = CrossChatMentionPickerLogic.query(
            inputText: viewModel.inputContent.string,
            resolvedMention: resolvedCrossChatMention
        )
        let mentionCurrentSessionKey = viewModel.uiSelectedSessionKey.isEmpty
            ? viewModel.engineActiveSessionKey
            : viewModel.uiSelectedSessionKey
        let mentionPickerStreams = CrossChatMentionPickerLogic.filteredStreams(
            streams: effectiveStreams,
            currentSessionKey: mentionCurrentSessionKey,
            query: mentionQuery ?? ""
        )
        let mentionPickerDotStatesBySession = Dictionary(
            uniqueKeysWithValues: mentionPickerStreams.map { ($0.sessionKey, viewModel.streamDotState(for: $0.sessionKey)) }
        )
        let mentionHighlightedSessionKey = highlightedCrossChatMentionSessionKey.flatMap { highlighted in
            mentionPickerStreams.contains { $0.sessionKey == highlighted } ? highlighted : nil
        } ?? mentionPickerStreams.first?.sessionKey
        let isMentionPickerVisible = mentionQuery != nil
        let activeSelectionPopupVisible = isMentionPickerVisible
            || streamPopupRouteController.route != .closed
        let notificationNormalTrailingMargin = metrics.containerPadding / 2
        let notificationCompactLeadingFitMargin = isCompactLayout ? metrics.containerPadding * 2 : 0
        let notificationOverlayTopMargin: CGFloat = 8
        let notificationOverlayMaxHeight = max(
            CrossChatNotificationOverlay.minVisibleBubbleHeight,
            geometry.size.height - notificationOverlayTopMargin - inputBarTopFromScreenBottom - 24
        )
        let notificationOverlayMaxWidth = geometry.size.width
        let keyboardVisibleNotificationBubbles = CrossChatNotificationOverlay.visibleBubbles(
            maxContainerHeight: notificationOverlayMaxHeight,
            bubbles: viewModel.crossChatNotificationBubbles,
            replyPinSlotsBySourceChatId: crossChatNotificationReplyPinSlotsBySourceChatId,
            measuredHeightsBySourceChatId: crossChatNotificationMeasuredHeightsBySourceChatId
        )
        let keyboardVisibleNotificationSourceChatIds = keyboardVisibleNotificationBubbles.map(\.sourceChatId)
        let keyboardVisibleReplySourceChatIds = keyboardVisibleNotificationBubbles
            .filter(\.isReplying)
            .map(\.sourceChatId)
        let notificationShortcutVisibleCount = keyboardVisibleNotificationSourceChatIds.count
        let keyboardOwnershipStore = KeyboardOwnershipSceneFactory.chatScene(
            visibleNotificationSourceChatIds: keyboardVisibleNotificationSourceChatIds,
            mentionPickerVisible: isMentionPickerVisible,
            mentionPickerHasCompletion: !mentionPickerStreams.isEmpty,
            composerFocused: isInputFocused,
            notificationFocusedSourceChatId: crossChatNotificationFocusedSourceChatId,
            notificationReplySourceChatIds: keyboardVisibleReplySourceChatIds,
            notificationReplyFocusedSourceChatId: crossChatNotificationFocusedReplySourceChatId,
            actionMenuSourceChatId: crossChatNotificationActionMenuSourceChatId
        )
        let cancelCurrentPromptDialogCanCancel = cancelCurrentPromptSessionKey.map { sessionKey in
            cancelCurrentPromptRequiresVisibleTyping
                ? viewModel.canCancelVisibleTypingPrompt(in: sessionKey)
                : viewModel.canCancelCurrentPrompt(in: sessionKey)
        } ?? viewModel.canCancelCurrentPrompt

        let messageLayer: AnyView = AnyView(
            pagedStreamView(
                topInset: messageListTopInset,
                truncationBottomInset: truncationBottomInset,
                effectiveSessionKeys: effectiveSessionKeys
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        )

        let rootLayer: AnyView = AnyView(ZStack(alignment: .top) {
            messageLayer
                .compositingGroup()
                .mask(messageViewportFadeMask(topInset: statusBarTopInset))

            streamToastView(
                inputBarTopFromScreenBottom: inputBarTopFromScreenBottom
            )
            .zIndex(30)
            toastBannerView(geometry: geometry, toastManager: toastManager)
            mentionPickerOverlay(
                streams: mentionPickerStreams,
                currentSessionKey: mentionCurrentSessionKey,
                dotStatesBySession: mentionPickerDotStatesBySession,
                highlightedSessionKey: mentionHighlightedSessionKey,
                isVisible: isMentionPickerVisible,
                inputBarTopFromScreenBottom: inputBarTopFromScreenBottom
            )
            .zIndex(40)
            notificationOverlay(
                viewModel: viewModel,
                topMargin: notificationOverlayTopMargin,
                maxContainerHeight: notificationOverlayMaxHeight,
                maxContainerWidth: notificationOverlayMaxWidth,
                normalTrailingMargin: notificationNormalTrailingMargin,
                compactLeadingFitMargin: notificationCompactLeadingFitMargin,
                measuredBubbleHeightsBySourceChatId: $crossChatNotificationMeasuredHeightsBySourceChatId,
                actionMenuSourceChatId: $crossChatNotificationActionMenuSourceChatId,
                focusedSourceChatId: $crossChatNotificationFocusedSourceChatId,
                focusedReplySourceChatId: $crossChatNotificationFocusedReplySourceChatId,
                keyboardOwnershipStore: keyboardOwnershipStore
            )
            .zIndex(20)
            notificationKeyboardShortcutView(
                viewModel: viewModel,
                maxContainerHeight: notificationOverlayMaxHeight,
                measuredHeightsBySourceChatId: crossChatNotificationMeasuredHeightsBySourceChatId,
                keyboardOwnershipStore: keyboardOwnershipStore
            )
        })

        let keyboardRoutedRootLayer: AnyView = AnyView(rootLayer
            .ignoresSafeArea(.keyboard)
            .handleKeyboardScrollCommands(
            isEnabled: keyboardScrollShortcutEnabled,
            keyboardOwnershipStore: keyboardOwnershipStore,
            onScrollDown: { scrollVisibleBubbleContents(.down) },
            onScrollUp: { scrollVisibleBubbleContents(.up) },
            onScrollChatDown: { scrollChatSurface(.down) },
            onScrollChatUp: { scrollChatSurface(.up) }
            )
        )
        let notificationCommand = crossChatNotificationCommand(
            viewModel: viewModel,
            maxContainerHeight: notificationOverlayMaxHeight,
            replyPinSlotsBySourceChatId: crossChatNotificationReplyPinSlotsBySourceChatId,
            measuredHeightsBySourceChatId: crossChatNotificationMeasuredHeightsBySourceChatId,
            keyboardOwnershipStore: keyboardOwnershipStore
        )

        let commandFocusedRootLayer: AnyView = AnyView(keyboardRoutedRootLayer.focusedSceneValue(
            \.crossChatNotificationCommand,
            notificationCommand
        ))

        let lifecycleRootLayer: AnyView = AnyView(commandFocusedRootLayer
        .onReceive(NotificationCenter.default.publisher(for: .clawlineKeyboardCommandIntent)) { notification in
            guard let intent = notification.object as? KeyboardCommandIntent else { return }
            handleRootKeyboardCommandIntent(intent, keyboardOwnershipStore: keyboardOwnershipStore)
        }
        .onChange(of: layoutInputs) { _, _ in
            layoutCoordinator.updateInputs(layoutInputs, metrics: layoutMetrics)
            layoutCoordinator.markInputsChanged()
        }
        .onChange(of: layoutMetrics) { _, _ in
            layoutCoordinator.updateInputs(layoutInputs, metrics: layoutMetrics)
            layoutCoordinator.markInputsChanged()
        }
        .onChange(of: viewModel.engineActiveSessionKey) { _, newValue in
            layoutCoordinator.setActiveSessionKey(newValue)
        }
        .onAppear {
            viewModel.crossChatNotificationDismissAnimator = { updates in
                withAnimation(CrossChatNotificationMotion.hide) {
                    updates()
                }
            }
            viewModel.bindStreamSwitchCoordinatorIfNeeded()
            layoutCoordinator.setActiveSessionKey(viewModel.engineActiveSessionKey)
            layoutCoordinator.updateInputs(layoutInputs, metrics: layoutMetrics)
            layoutCoordinator.markInputsChanged()
            inputBarSendButtonConnectionState.value = sendButtonConnectionState
        }
        .onChange(of: sendButtonConnectionState) { _, newValue in
            inputBarSendButtonConnectionState.value = newValue
        }
        .onChange(of: viewModel.uiSelectionSequence) { _, _ in
            removeResolvedCrossChatMention(restoreFocus: false)
            guard let selectedSessionKey = viewModel.lastUISelectedSessionKey else { return }
            let streamDisplayName = viewModel.stream(for: selectedSessionKey)?.displayName ?? viewModel.activeSessionDisplayName
            let shouldShowBusy = selectedSessionKey != viewModel.engineActiveSessionKey
            StreamSwitchTiming.log("toast_show_called", sessionKey: selectedSessionKey)
            #if !os(visionOS)
            StreamSwitchTiming.log("haptic_fired", sessionKey: selectedSessionKey)
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            #endif
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                // UI-intent path is immediate; spinner stays up through debounce + engine activation.
                streamToastManager.show(displayName: streamDisplayName, sessionKey: selectedSessionKey, isBusy: shouldShowBusy)
            }
            if shouldShowBusy {
                streamToastBusySince = Date()
                streamToastBusyClearTask?.cancel()
                streamToastBusyClearTask = nil
            } else {
                // Same-stream intent has no engine activation phase, so never enter busy state.
                streamToastBusySince = nil
                streamToastBusyClearTask?.cancel()
                streamToastBusyClearTask = nil
            }
        }
        .onChange(of: viewModel.engineActivationCompletedSequence) { _, _ in
            guard let completedSessionKey = viewModel.lastEngineActivationSessionKey else { return }
            guard streamToastManager.isVisible, streamToastManager.sessionKey == completedSessionKey else { return }
            scheduleStreamToastBusyClear()
        }
        .onChange(of: keyboardHeight) { _, _ in layoutRevision &+= 1 }
        .onChange(of: keyboardAnimationDuration) { _, _ in layoutRevision &+= 1 }
        .onChange(of: keyboardAnimationCurve) { _, _ in layoutRevision &+= 1 }
        .onChange(of: inputBarHeight) { _, _ in
            guard shouldInvalidateLayoutRevisionOnInputBarHeightChange else { return }
            layoutRevision &+= 1
        }
        .onChange(of: isInputFocused) { _, _ in layoutRevision &+= 1 }
        .onChange(of: geometry.safeAreaInsets.bottom) { _, _ in layoutRevision &+= 1 }
        .onChange(of: horizontalSizeClass) { _, _ in layoutRevision &+= 1 }
        .overlay(alignment: .bottom) {
#if os(visionOS)
            floatingPageDotsView(
                viewModel: viewModel,
                inputBarTopFromScreenBottom: inputBarTopFromScreenBottom,
                streamSelectorMaxHeight: streamSelectorMaxHeight,
                containerWidth: geometry.size.width,
                bottomSafeAreaInset: geometry.safeAreaInsets.bottom
            )
#else
            EmptyView()
#endif
        }
        .overlay(alignment: .bottom) {
            inputBarOverlay(
                geometry: geometry,
                viewModel: viewModel,
                effectiveStreams: effectiveStreams,
                mentionPickerStreams: mentionPickerStreams,
                isMentionPickerVisible: isMentionPickerVisible,
                notificationVisibleCount: notificationShortcutVisibleCount,
                belowBarGap: belowBarGap,
                isKeyboardVisible: isKeyboardVisible,
                layoutKey: layoutKey,
                streamSelectorMaxHeight: streamSelectorMaxHeight,
                keyboardOwnershipStore: keyboardOwnershipStore
            )
        }
        .overlay(alignment: .bottom) {
#if os(visionOS)
            // visionOS: keep the scroll-to-bottom button in the main SwiftUI overlay.
            // iOS/iPadOS: we pin it to the UIKit keyboardLayoutGuide via KeyboardPinnedContainerView.
            if !activeSelectionPopupVisible {
                let sessionKey = viewModel.uiSelectedSessionKey
                let state = scrollButtonState(for: sessionKey)
                scrollButtonControl(
                    state: state,
                    containerWidth: geometry.size.width,
                    onTap: { handleScrollButtonTap(sessionKey: sessionKey, viewModel: viewModel) }
                )
                .highPriorityGesture(
                    // Keep translation stable while the hosted button itself is repositioned.
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            handleScrollButtonDragChanged(value, containerWidth: geometry.size.width)
                        }
                        .onEnded { value in
                            handleScrollButtonDragEnded(value, containerWidth: geometry.size.width)
                        }
                )
                .offset(x: activeScrollButtonHorizontalOffset(containerWidth: geometry.size.width))
                .padding(.bottom, inputBarTopFromScreenBottom + floatingScrollButtonBottomGap)
                .frame(maxWidth: .infinity, alignment: .center)
            }
#else
            EmptyView()
#endif
        }
        )

        let promptRootLayer: AnyView = AnyView(lifecycleRootLayer.modifier(
            PromptFocusShortcutModifier(
                isEnabled: promptFocusShortcutEnabled,
                hasStreams: !effectiveSessionKeys.isEmpty,
                onOpenStreamPopup: {
                    streamPopupRouteController.openPopup(focusSearch: true)
                },
                onFocusRequested: {
                    focusRequestID &+= 1
                },
                onTextInserted: { text in
                    insertPromptTextFromNoTextOwner(text)
                },
                notificationVisibleCount: notificationShortcutVisibleCount,
                keyboardOwnershipStore: keyboardOwnershipStore
            )
        ))

        let decoratedRootLayer: AnyView = AnyView(promptRootLayer.modifier(
            CancelCurrentPromptConfirmationModifier(
                isPresented: $isCancelCurrentPromptDialogPresented,
                anchorFrame: cancelCurrentPromptAnchorFrame,
                canCancel: cancelCurrentPromptDialogCanCancel,
                canPresentCommand: viewModel.canCancelCurrentPrompt,
                onPresentCommand: { presentCancelCurrentPromptDialog() },
                onConfirm: { confirmCancelCurrentPromptDialog(viewModel: viewModel) }
            )
        ))
#if DEBUG
        decoratedRootLayer.overlay(alignment: .topTrailing) {
            lifecycleDebugOverlay(
                viewModel: viewModel,
                containerHeight: geometry.size.height
            )
        }
#else
        decoratedRootLayer
#endif
    }

    private func confirmCancelCurrentPromptDialog(viewModel: ChatViewModel) {
        if cancelCurrentPromptRequiresVisibleTyping,
           let sessionKey = cancelCurrentPromptSessionKey,
           !viewModel.canCancelVisibleTypingPrompt(in: sessionKey) {
            cancelCurrentPromptSessionKey = nil
            cancelCurrentPromptRequiresVisibleTyping = false
            cancelCurrentPromptAnchorFrame = nil
            return
        }
        viewModel.requestCurrentPromptCancellation(sessionKey: cancelCurrentPromptSessionKey)
        cancelCurrentPromptSessionKey = nil
        cancelCurrentPromptRequiresVisibleTyping = false
        cancelCurrentPromptAnchorFrame = nil
    }

#if DEBUG
    @ViewBuilder
    private func lifecycleDebugOverlay(viewModel: ChatViewModel, containerHeight: CGFloat) -> some View {
        if isLifecycleDebugOverlayEnabled, lifecycleDebugOverlayVisible {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("probe t:\(probeTaskEnterCount) a:\(probeOnAppearCount) d:\(probeOnDisappearCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                    Text("appear state: \(probeLatestOnAppearConnState)")
                        .font(.caption2)
                        .lineLimit(1)
                    Text("vm: \(probeLatestInstanceId)")
                        .font(.caption2)
                        .lineLimit(1)
                    Text("obj: \(probeLatestVmObject)")
                        .font(.caption2)
                        .lineLimit(1)
                    Text("disappear cause: \(probeLastOnDisappearCause)")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Text("dis prev vm/chat: \(probeLastOnDisappearPreviousVMObject) / \(probeLastOnDisappearPreviousChatViewId)")
                        .font(.caption2)
                        .lineLimit(1)
                    Text("dis curr vm/chat: \(probeLastOnDisappearCurrentVMObject) / \(probeLastOnDisappearCurrentChatViewId)")
                        .font(.caption2)
                        .lineLimit(1)
                    Text("lifecycle: \(String(describing: viewModel.lifecycleDebugPhase))")
                        .font(.caption2.weight(.semibold))
                    Text("last gate: \(viewModel.lifecycleDebugLastGateDecision)")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    ForEach(Array(viewModel.lifecycleDebugSignals.suffix(6))) { record in
                        Text("\(record.signal.rawValue) @ \(record.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    if !viewModel.lifecycleDebugStartupGateEvents.isEmpty {
                        Text("gate:")
                            .font(.caption2.weight(.semibold))
                        ForEach(Array(viewModel.lifecycleDebugStartupGateEvents.suffix(6).enumerated()), id: \.offset) { _, event in
                            Text(
                                "\(event.kind.rawValue) @ \(event.timestamp.formatted(date: .omitted, time: .standard)) t:\(event.hasToken ? "1" : "0") v:\(event.hasViewAppeared ? "1" : "0") r:\(event.reconnectEnabled ? "1" : "0") p:\(String(describing: event.phase))"
                            )
                            .font(.caption2)
                            .monospacedDigit()
                            .lineLimit(1)
                        }
                    }
                    if !viewModel.lifecycleDebugObserverEvents.isEmpty {
                        Text("obs:")
                            .font(.caption2.weight(.semibold))
                        ForEach(Array(viewModel.lifecycleDebugObserverEvents.suffix(4))) { record in
                            Text(
                                "\(record.event.rawValue) @ \(record.timestamp.formatted(date: .omitted, time: .standard)) o:\(record.hasObservationTask ? "1" : "0") t:\(record.hasTransportSubscription ? "1" : "0") out:\(record.hasOutputsSubscription ? "1" : "0")"
                            )
                            .font(.caption2)
                            .monospacedDigit()
                            .lineLimit(1)
                        }
                    }
                    if !viewModel.imageSendDebugRecords.isEmpty {
                        Text("image/send:")
                            .font(.caption2.weight(.semibold))
                        Text("send snapshot: \(viewModel.imageSendLastTransportSnapshot)")
                            .font(.caption2)
                            .monospacedDigit()
                            .lineLimit(1)
                        ForEach(Array(viewModel.imageSendDebugRecords.suffix(6))) { record in
                            Text(
                                "\(record.kind.rawValue) @ \(record.timestamp.formatted(date: .omitted, time: .standard)) \(record.detail)"
                            )
                            .font(.caption2)
                            .monospacedDigit()
                            .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: containerHeight * 0.5)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
            .onAppear {
                showLifecycleDebugOverlay()
            }
            .onTapGesture {
                lifecycleDebugOverlayVisible = false
                lifecycleDebugOverlayDismissTask?.cancel()
                lifecycleDebugOverlayDismissTask = nil
            }
            .contextMenu {
                Button("Copy all") {
                    UIPasteboard.general.string = lifecycleDebugOverlayCopyText(viewModel: viewModel)
                }
            }
        }
    }

    private enum ProbeEventKind {
        case taskEnter
        case onAppear
        case onDisappear
    }

    private func recordProbeEvent(
        kind: ProbeEventKind,
        instanceId: String,
        vmObject: String,
        connState: String
    ) {
        probeLatestInstanceId = instanceId
        probeLatestVmObject = vmObject
        switch kind {
        case .taskEnter:
            probeTaskEnterCount &+= 1
        case .onAppear:
            probeOnAppearCount &+= 1
            probeLatestOnAppearConnState = connState
            if scenePhase == .active {
                let pending = T099OnDisappearProbeStore.shared.pendingActiveDisappear
                if let pending {
                    probeLastOnDisappearPreviousVMObject = pending.vmObject
                    probeLastOnDisappearPreviousChatViewId = pending.chatViewId
                    probeLastOnDisappearCurrentVMObject = vmObject
                    probeLastOnDisappearCurrentChatViewId = chatViewTraceId
                    if pending.vmObject != vmObject || pending.chatViewId != chatViewTraceId {
                        probeLastOnDisappearCause = "view_replacement"
                    } else {
                        probeLastOnDisappearCause = "active_same_identity"
                    }
                    T099OnDisappearProbeStore.shared.pendingActiveDisappear = nil
                }
            }
        case .onDisappear:
            probeOnDisappearCount &+= 1
            probeLastOnDisappearPreviousVMObject = vmObject
            probeLastOnDisappearPreviousChatViewId = chatViewTraceId
            probeLastOnDisappearCurrentVMObject = "-"
            probeLastOnDisappearCurrentChatViewId = "-"
            if scenePhase == .active {
                probeLastOnDisappearCause = "pending_active_disappear"
                T099OnDisappearProbeStore.shared.pendingActiveDisappear = .init(
                    vmObject: vmObject,
                    chatViewId: chatViewTraceId
                )
            } else {
                probeLastOnDisappearCause = "app_background"
                T099OnDisappearProbeStore.shared.pendingActiveDisappear = nil
            }
        }
    }

    private func showLifecycleDebugOverlay() {
        guard isLifecycleDebugOverlayEnabled else { return }
        lifecycleDebugOverlayVisible = true
        lifecycleDebugOverlayDismissTask?.cancel()
        lifecycleDebugOverlayDismissTask = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            await MainActor.run {
                lifecycleDebugOverlayVisible = false
                lifecycleDebugOverlayDismissTask = nil
            }
        }
    }

    private func lifecycleDebugOverlayCopyText(viewModel: ChatViewModel) -> String {
        var lines: [String] = []
        lines.append("probe t:\(probeTaskEnterCount) a:\(probeOnAppearCount) d:\(probeOnDisappearCount)")
        lines.append("appear state: \(probeLatestOnAppearConnState)")
        lines.append("vm: \(probeLatestInstanceId)")
        lines.append("obj: \(probeLatestVmObject)")
        lines.append("disappear cause: \(probeLastOnDisappearCause)")
        lines.append("dis prev vm/chat: \(probeLastOnDisappearPreviousVMObject) / \(probeLastOnDisappearPreviousChatViewId)")
        lines.append("dis curr vm/chat: \(probeLastOnDisappearCurrentVMObject) / \(probeLastOnDisappearCurrentChatViewId)")
        lines.append("lifecycle: \(String(describing: viewModel.lifecycleDebugPhase))")
        lines.append("last gate: \(viewModel.lifecycleDebugLastGateDecision)")
        for record in viewModel.lifecycleDebugSignals {
            lines.append("\(record.signal.rawValue) @ \(record.timestamp.formatted(date: .omitted, time: .standard))")
        }
        if !viewModel.lifecycleDebugStartupGateEvents.isEmpty {
            lines.append("gate:")
            for event in viewModel.lifecycleDebugStartupGateEvents {
                lines.append(
                    "\(event.kind.rawValue) @ \(event.timestamp.formatted(date: .omitted, time: .standard)) t:\(event.hasToken ? "1" : "0") v:\(event.hasViewAppeared ? "1" : "0") r:\(event.reconnectEnabled ? "1" : "0") p:\(String(describing: event.phase))"
                )
            }
        }
        if !viewModel.lifecycleDebugObserverEvents.isEmpty {
            lines.append("obs:")
            for record in viewModel.lifecycleDebugObserverEvents {
                lines.append(
                    "\(record.event.rawValue) @ \(record.timestamp.formatted(date: .omitted, time: .standard)) o:\(record.hasObservationTask ? "1" : "0") t:\(record.hasTransportSubscription ? "1" : "0") out:\(record.hasOutputsSubscription ? "1" : "0")"
                )
            }
        }
        if !viewModel.imageSendDebugRecords.isEmpty {
            lines.append("image/send:")
            lines.append("send snapshot: \(viewModel.imageSendLastTransportSnapshot)")
            for record in viewModel.imageSendDebugRecords {
                lines.append(
                    "\(record.kind.rawValue) @ \(record.timestamp.formatted(date: .omitted, time: .standard)) \(record.detail)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }
#endif

    private var appVersionLabel: AttributedString? {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        guard let version, !version.isEmpty else { return nil }
        if let build, !build.isEmpty {
            var green = AttributeContainer()
            green.foregroundColor = .green
            let buildText = AttributedString(build, attributes: green)
            return AttributedString("v\(version) (build ") + buildText + AttributedString(")")
        }
        return AttributedString("v\(version)")
    }

    private func mentionPickerOverlay(
        streams: [StreamSession],
        currentSessionKey: String,
        dotStatesBySession: [String: StreamDotState],
        highlightedSessionKey: String?,
        isVisible: Bool,
        inputBarTopFromScreenBottom: CGFloat
    ) -> AnyView {
        AnyView(
            CrossChatMentionPickerView(
                streams: streams,
                currentSessionKey: currentSessionKey,
                dotStatesBySession: dotStatesBySession,
                highlightedSessionKey: highlightedSessionKey,
                isVisible: isVisible,
                onSelect: { stream in
                    resolveCrossChatMention(stream)
                }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, inputBarTopFromScreenBottom + 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(isVisible)
            .visionOSOverlayDepthOffset(spatialOverlayDepthOffset)
        )
    }

    private func notificationOverlay(
        viewModel: ChatViewModel,
        topMargin: CGFloat,
        maxContainerHeight: CGFloat,
        maxContainerWidth: CGFloat,
        normalTrailingMargin: CGFloat,
        compactLeadingFitMargin: CGFloat,
        measuredBubbleHeightsBySourceChatId: Binding<[String: CGFloat]>,
        actionMenuSourceChatId: Binding<String?>,
        focusedSourceChatId: Binding<String?>,
        focusedReplySourceChatId: Binding<String?>,
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) -> AnyView {
        AnyView(
            ZStack(alignment: .topTrailing) {
                CrossChatNotificationOverlay(
                    viewModel: viewModel,
                    topMargin: topMargin,
                    maxContainerHeight: maxContainerHeight,
                    maxContainerWidth: maxContainerWidth,
                    normalTrailingMargin: normalTrailingMargin,
                    compactLeadingFitMargin: compactLeadingFitMargin,
                    isCollapsed: $isCrossChatNotificationStackDocked,
                    replyPinSlotsBySourceChatId: $crossChatNotificationReplyPinSlotsBySourceChatId,
                    measuredBubbleHeightsBySourceChatId: measuredBubbleHeightsBySourceChatId,
                    actionMenuSourceChatId: actionMenuSourceChatId,
                    focusedSourceChatId: focusedSourceChatId,
                    focusedReplySourceChatId: focusedReplySourceChatId,
                    keyboardOwnershipStore: keyboardOwnershipStore,
                    onNavigateToSource: { sourceChatId in
                        selectStream(sourceChatId, source: .programmatic)
                    }
                )
                .visionOSOverlayDepthOffset(spatialOverlayDepthOffset)
            }
            .frame(
                width: CrossChatNotificationGeometry.layoutHostWidth(maxContainerWidth: maxContainerWidth),
                height: CrossChatNotificationOverlay.overlayHostHeight(
                    topMargin: topMargin,
                    maxContainerHeight: maxContainerHeight
                ),
                alignment: .topTrailing
            )
            .ignoresSafeArea(.container, edges: .horizontal)
        )
    }

    private func crossChatNotificationCommand(
        viewModel: ChatViewModel,
        maxContainerHeight: CGFloat,
        replyPinSlotsBySourceChatId: [String: Int],
        measuredHeightsBySourceChatId: [String: CGFloat],
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) -> CrossChatNotificationCommand? {
        let allBubbles = viewModel.crossChatNotificationBubbles
        let bubbles = CrossChatNotificationOverlay.visibleBubbles(
            maxContainerHeight: maxContainerHeight,
            bubbles: allBubbles,
            replyPinSlotsBySourceChatId: replyPinSlotsBySourceChatId,
            measuredHeightsBySourceChatId: measuredHeightsBySourceChatId
        )
        guard !bubbles.isEmpty else { return nil }
        return CrossChatNotificationCommand(
            hasVisibleNotifications: true,
            visibleCount: bubbles.count,
            keyboardOwnershipStore: keyboardOwnershipStore,
            openActionMenu: { index in
                guard bubbles.indices.contains(index),
                      case .handled(.notificationBubble(_)) = KeyboardCommandRouter
                        .route(intent: .notificationAssignedOpen(index), store: keyboardOwnershipStore)
                        .outcome else { return }
                NotificationCenter.default.post(
                    name: .clawlineOpenNotificationActionMenuCommand,
                    object: index
                )
            },
            dismiss: { index in
                guard bubbles.indices.contains(index),
                      case .handled(.notificationBubble(_)) = KeyboardCommandRouter
                        .route(intent: .notificationAssignedDismiss(index), store: keyboardOwnershipStore)
                        .outcome else { return }
                NotificationCenter.default.post(
                    name: .clawlineDismissNotificationCommand,
                    object: index
                )
            },
            reply: { index in
                guard bubbles.indices.contains(index),
                      case .handled(.notificationBubble(_)) = KeyboardCommandRouter
                        .route(intent: .notificationAssignedReply(index), store: keyboardOwnershipStore)
                        .outcome else { return }
                NotificationCenter.default.post(
                    name: .clawlineReplyNotificationCommand,
                    object: index
                )
            },
            scrollDown: {
                guard case .handled(.notificationBubble(_)) = KeyboardCommandRouter
                    .route(intent: .notificationScrollForward, store: keyboardOwnershipStore)
                    .outcome else { return }
                NotificationCenter.default.post(name: .clawlineScrollNotificationDownCommand, object: nil)
            },
            scrollUp: {
                guard case .handled(.notificationBubble(_)) = KeyboardCommandRouter
                    .route(intent: .notificationScrollBackward, store: keyboardOwnershipStore)
                    .outcome else { return }
                NotificationCenter.default.post(name: .clawlineScrollNotificationUpCommand, object: nil)
            },
            dismissAll: {
                withAnimation(CrossChatNotificationMotion.hide) {
                    viewModel.dismissAllCrossChatNotifications()
                }
            }
        )
    }

    private func handleRootKeyboardCommandIntent(
        _ intent: KeyboardCommandIntent,
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) {
        if let notificationName = ChatRootKeyboardCommandDispatch.notificationName(
            for: intent,
            keyboardOwnershipStore: keyboardOwnershipStore
        ) {
            NotificationCenter.default.post(name: notificationName, object: nil)
        }
    }

    private func notificationKeyboardShortcutView(
        viewModel: ChatViewModel,
        maxContainerHeight: CGFloat,
        measuredHeightsBySourceChatId: [String: CGFloat],
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) -> AnyView {
        AnyView(
            CrossChatNotificationKeyboardShortcuts(
                bubbles: viewModel.crossChatNotificationBubbles,
                maxContainerHeight: maxContainerHeight,
                replyPinSlotsBySourceChatId: crossChatNotificationReplyPinSlotsBySourceChatId,
                measuredHeightsBySourceChatId: measuredHeightsBySourceChatId,
                keyboardOwnershipStore: keyboardOwnershipStore,
                onDismissAll: {
                    withAnimation(CrossChatNotificationMotion.hide) {
                        viewModel.dismissAllCrossChatNotifications()
                    }
                },
                onToggleDock: {
                    NotificationCenter.default.post(name: .clawlineToggleNotificationDockCommand, object: nil)
                }
            )
        )
    }

    @ViewBuilder
    private func streamToastView(inputBarTopFromScreenBottom: CGFloat) -> some View {
        if streamToastManager.isVisible {
            StreamToast(
                displayName: streamToastManager.displayName,
                sessionKey: streamToastManager.sessionKey,
                isBusy: streamToastManager.isBusy
            )
                .padding(.bottom, inputBarTopFromScreenBottom + 50)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    @ViewBuilder
    private func toastBannerView(geometry: GeometryProxy,
                                 toastManager: ToastManager) -> some View {
        if let toast = toastManager.toast {
            ToastBanner(
                message: toast.message,
                actionTitle: toast.actionTitle,
                action: toast.actionTitle == nil ? nil : {
                    toastManager.performAction()
                }
            ) {
                toastManager.dismiss()
            }
            .padding(.top, geometry.safeAreaInsets.top + 12)
            .padding(.horizontal, 24)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func inputBarOverlay(geometry: GeometryProxy,
                                 viewModel: ChatViewModel,
                                 effectiveStreams: [StreamSession],
                                 mentionPickerStreams: [StreamSession],
                                 isMentionPickerVisible: Bool,
                                 notificationVisibleCount: Int,
                                 belowBarGap: CGFloat,
                                 isKeyboardVisible: Bool,
                                 layoutKey: ChatLayoutKey,
                                 streamSelectorMaxHeight: CGFloat,
                                 keyboardOwnershipStore: KeyboardOwnershipStore) -> some View {
        let sessionKey = viewModel.uiSelectedSessionKey
        let effectiveSessionKeys = effectiveStreams.map(\.sessionKey)
        let state = scrollButtonState(for: sessionKey)
        let scrollButtonView: AnyView = AnyView(
            scrollButtonControl(
                state: state,
                containerWidth: geometry.size.width,
                onTap: {
                    handleScrollButtonTap(sessionKey: sessionKey, viewModel: viewModel)
                }
            )
        )
        let pageDotsView: AnyView? = effectiveSessionKeys.isEmpty
            || isMentionPickerVisible
            ? nil
            : AnyView(
                streamPageDotsControl(
                    viewModel: viewModel,
                    effectiveStreams: effectiveStreams,
                    streamSelectorMaxHeight: streamSelectorMaxHeight,
                    containerWidth: geometry.size.width,
                    bottomSafeAreaInset: geometry.safeAreaInsets.bottom
                )
            )

#if os(visionOS)
        let pinnedScrollButtonView: AnyView? = nil
        let pinnedScrollButtonIsVisible = false
        let pinnedScrollButtonGap: CGFloat = 0
        let pinnedScrollButtonHorizontalOffset: CGFloat = 0
        let pinnedScrollButtonMaxHorizontalOffset: CGFloat = 0
        let pinnedScrollButtonSettleStartOffset: CGFloat? = nil
        let pinnedScrollButtonHorizontalAnimationToken: Int = 0
        let onPinnedScrollButtonPanEnded: ((CGFloat, CGFloat) -> Void)? = nil
        let pinnedPageDotsView: AnyView? = nil
        let pinnedPageDotsGap: CGFloat = 0
#else
        let pinnedScrollButtonView: AnyView? = scrollButtonView
        let pinnedScrollButtonIsVisible = !isMentionPickerVisible
            && streamPopupRouteController.route == .closed
            && state.isVisible
        let pinnedScrollButtonGap: CGFloat = floatingScrollButtonBottomGap
        let pinnedScrollButtonHorizontalOffset = scrollButtonHorizontalOffset(
            for: scrollButtonDetent,
            containerWidth: geometry.size.width
        )
        let pinnedScrollButtonMaxHorizontalOffset = scrollButtonMaxHorizontalOffset(
            containerWidth: geometry.size.width
        )
        let pinnedScrollButtonSettleStartOffset = scrollButtonSettleStartOffset
        let pinnedScrollButtonHorizontalAnimationToken = scrollButtonSettleAnimationToken
        let onPinnedScrollButtonPanEnded: ((CGFloat, CGFloat) -> Void)? = { translationWidth, predictedTranslationWidth in
            handleScrollButtonDragEnded(
                translationWidth: translationWidth,
                predictedTranslationWidth: predictedTranslationWidth,
                containerWidth: geometry.size.width
            )
        }
        let pinnedPageDotsView: AnyView? = pageDotsView
        let pinnedPageDotsGap: CGFloat = floatingPageDotsBottomGap
#endif

        return KeyboardPinnedContainer(
            desiredBottomGap: belowBarGap,
            isKeyboardVisible: isKeyboardVisible,
            measuredHeight: $inputBarHeight,
            versionText: appVersionLabel,
            layoutCoordinator: layoutCoordinator,
            layoutKey: layoutKey,
            scrollButtonView: pinnedScrollButtonView,
            scrollButtonIsVisible: pinnedScrollButtonIsVisible,
            scrollButtonGap: pinnedScrollButtonGap,
            scrollButtonHorizontalOffset: pinnedScrollButtonHorizontalOffset,
            scrollButtonMaxHorizontalOffset: pinnedScrollButtonMaxHorizontalOffset,
            scrollButtonHorizontalSettleStartOffset: pinnedScrollButtonSettleStartOffset,
            scrollButtonHorizontalAnimationToken: pinnedScrollButtonHorizontalAnimationToken,
            onScrollButtonPanEnded: onPinnedScrollButtonPanEnded,
            pageDotsView: pinnedPageDotsView,
            pageDotsGap: pinnedPageDotsGap
        ) {
            MessageInputBar(
                content: $viewModel.inputContent,
                selectionRange: $selectionRange,
                pendingInsertions: $pendingInputInsertions,
                placeholderText: viewModel.activeSessionPlaceholderText,
                fontScaleChangeSequence: fontScaleChangeSequence,
                resetToken: viewModel.inputResetToken,
                canSend: viewModel.canSend,
                isSending: viewModel.isSending,
                canCancelSend: viewModel.canCancelSend,
                isStagingAttachments: viewModel.pendingAttachmentStageCount > 0,
                connectionStateStore: inputBarSendButtonConnectionState,
                focusTrigger: focusRequestID,
                bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                isKeyboardVisible: isKeyboardVisible,
                isAttachmentMenuPresented: $isAttachmentMenuPresented,
                resolvedMentionTitle: nil,
                onSend: {
                    clearTypingActivity()
                    if let resolvedCrossChatMention {
                        if viewModel.sendCrossChatMention(to: resolvedCrossChatMention.destinationChatId) {
                            showCrossChatMentionSentToast(resolvedCrossChatMention)
                            removeResolvedCrossChatMention()
                        }
                    } else {
                        viewModel.send()
                    }
                },
                onCancel: { viewModel.cancelSend() },
                onReconnect: { viewModel.reconnect() },
                onAdd: {
                    isAttachmentMenuPresented = true
                },
                onRemoveResolvedMention: {
                    removeResolvedCrossChatMention()
                },
                attachmentMenuContent: {
                    AnyView(
                        AttachmentSourceSheet(
                            onCamera: {
                                isAttachmentMenuPresented = false
                                presentCamera()
                            },
                            onPhotos: {
                                isAttachmentMenuPresented = false
                                presentPhotoPicker()
                            },
                            onFiles: {
                                isAttachmentMenuPresented = false
                                presentFileImporter()
                            }
                        )
                    )
                },
                // ⚠️ This callback is how focus state survives view recreation.
                // DO NOT replace with @Binding or try to use @FocusState directly.
                onFocusChange: { focused in
                    scheduleInputFocusChange(focused)
                },
                onTextEditActivity: {
                    reconcileResolvedMentionAttachment()
                    recordTypingActivity()
                },
                handlesMentionPickerKeyCommands: isMentionPickerVisible,
                mentionPickerHasCompletion: !mentionPickerStreams.isEmpty,
                onMentionPickerTab: {
                    handleCrossChatMentionTab(filteredStreams: mentionPickerStreams)
                },
                onMentionPickerMoveUp: {
                    handleCrossChatMentionMove(filteredStreams: mentionPickerStreams, step: -1)
                },
                onMentionPickerMoveDown: {
                    handleCrossChatMentionMove(filteredStreams: mentionPickerStreams, step: 1)
                },
                onPasteImages: handlePastedImages,
                notificationVisibleCount: notificationVisibleCount,
                keyboardOwnershipStore: keyboardOwnershipStore,
                isCompact: horizontalSizeClass == .compact
            )
        }
        .visionOSInputBarDepthOffset()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func showCrossChatMentionSentToast(_ mention: ResolvedCrossChatMention) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            streamToastManager.show(
                displayName: "Sent to \(mention.displayName)",
                sessionKey: mention.destinationChatId,
                isBusy: false
            )
        }
        streamToastBusySince = nil
        streamToastBusyClearTask?.cancel()
        streamToastBusyClearTask = nil
    }

    @ViewBuilder
    private func messageViewportFadeMask(topInset: CGFloat) -> some View {
        #if os(visionOS)
            spatialViewportEdgeFadeMask()
        #else
            // #31: fade out message content behind the system status bar (mask, not overlay tint).
            statusBarFadeMask(topInset: topInset)
        #endif
    }

    private func spatialViewportEdgeFadeMask() -> some View {
        GeometryReader { proxy in
            let verticalFade = min(CGFloat(88), proxy.size.height / 2)
            let horizontalFade = min(CGFloat(176), proxy.size.width / 2)

            Rectangle()
                .fill(Color.white)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .white],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: verticalFade)
                        Rectangle().fill(Color.white)
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: verticalFade)
                    }
                }
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: horizontalFade)
                        Rectangle().fill(Color.white)
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: horizontalFade)
                    }
                }
        }
    }

    @ViewBuilder
    private func statusBarFadeMask(topInset: CGFloat) -> some View {
        // #31 follow-up: reduce strength + height. This is a mask (not an overlay), so lower alpha
        // means content remains partially visible behind the status bar instead of fully hidden.
        if topInset <= 0 {
            Rectangle().fill(Color.white)
        } else {
            let topAlpha: CGFloat = 0.25
            let fullyHiddenHeight = topInset + 9
            let fadeHeight: CGFloat = 23
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(topAlpha))
                    .frame(height: fullyHiddenHeight)
                LinearGradient(
                    colors: [Color.white.opacity(topAlpha), Color.white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: fadeHeight)
                Rectangle().fill(Color.white)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func inputFieldWidthCap(containerWidth: CGFloat, bottomSafeAreaInset: CGFloat) -> CGFloat {
        MessageInputBar.renderedInputFieldWidthCap(
            containerWidth: containerWidth,
            isCompact: horizontalSizeClass == .compact,
            bottomSafeAreaInset: bottomSafeAreaInset,
            isFieldFocused: isInputFocused
        )
    }

    private func messageList(topInset: CGFloat,
                             truncationBottomInset: CGFloat,
                             sessionKey: String) -> some View {
        let state = scrollButtonState(for: sessionKey)
        let list = MessageFlowCollectionView(
            viewModel: viewModel,
            topInset: topInset,
            isCompact: horizontalSizeClass == .compact,
            isActiveSession: sessionKey == renderPolicySessionKey,
            isRenderPolicyFrozen: viewModel.isRenderPolicyFrozen,
            isInputActive: isInputFocused,
            isTypingActive: isTypingActive,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: state.firstUnreadMessageId,
            unreadCount: state.unreadCount,
            onExpand: { message in
                activeSheet = .expandedMessage(message)
            },
            layoutCoordinator: layoutCoordinator,
            sessionKey: sessionKey,
            sessionStatus: viewModel.sessionStatus(for: sessionKey),
            forceReReadGeneration: viewModel.forceReReadGeneration(for: sessionKey),
            sendIndicatorRevision: viewModel.sendIndicatorRevision,
            fontScaleChangeSequence: fontScaleChangeSequence,
            onScrollEvent: handleDeferredMessageFlowScrollEvent,
            onTypingIndicatorTap: { anchorFrame in
                presentCancelCurrentPromptDialog(sessionKey: sessionKey, anchorFrame: anchorFrame)
            },
            onTypingIndicatorAnchorFrameChanged: { anchorFrame in
                if let anchorFrame {
                    latestTypingIndicatorAnchorFrameBySessionKey[sessionKey] = anchorFrame
                } else {
                    latestTypingIndicatorAnchorFrameBySessionKey.removeValue(forKey: sessionKey)
                }
            },
            onSessionControlSelected: { sessionKey, action, value, enabled in
                viewModel.applySessionControl(
                    sessionKey: sessionKey,
                    action: action,
                    value: value,
                    enabled: enabled
                )
            }
        )
        // We manage keyboard avoidance manually inside the collection view.
        // Prevent SwiftUI from shrinking the view and double-applying the keyboard height.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .contentShape(Rectangle())
        return list
    }

    @ViewBuilder
    private func sheetView(_ sheet: ChatSheet) -> some View {
        switch sheet {
        case .expandedMessage(let message):
            let metrics = ChatFlowTheme.Metrics(isCompact: horizontalSizeClass == .compact)
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            ExpandedMessageSheet(
                message: message,
                presentation: presentation,
                fontScaleChangeSequence: fontScaleChangeSequence,
                terminalConnectionPool: viewModel.terminalConnectionPool
            )
        case .camera:
            #if os(visionOS)
            Color.clear
                .onAppear {
                    activeSheet = nil
                    restoreFocusIfNeeded()
                }
            #else
            CameraPicker(
                onImage: { image in
                    activeSheet = nil
                    Task {
                        await handleCapturedImage(image)
                        await MainActor.run { restoreFocusIfNeeded() }
                    }
                },
                onCancel: {
                    activeSheet = nil
                    restoreFocusIfNeeded()
                }
            )
            #endif
        }
    }

    /// Paged TabView for horizontal swipe between streams.
    @ViewBuilder
    private func pagedStreamView(
        topInset: CGFloat,
        truncationBottomInset: CGFloat,
        effectiveSessionKeys: [String]
    ) -> some View {
        TabView(selection: streamBinding) {
            ForEach(effectiveSessionKeys, id: \.self) { sessionKey in
                messageList(
                    topInset: topInset,
                    truncationBottomInset: truncationBottomInset,
                    sessionKey: sessionKey
                )
                    .contentShape(Rectangle())
                    .background {
#if os(visionOS)
                        Color.clear
#else
                        ChatFlowTheme.pageBackground(colorScheme)
                            .ignoresSafeArea()
                            .overlay(NoiseOverlayView().ignoresSafeArea())
#endif
                    }
                    .tag(sessionKey)
            }
        }
        .overlay {
            // First-frame pager hitch mitigation:
            // SwiftUI lazily realizes neighboring page controllers on first pan recognition.
            // Precreate only the adjacent UIKit shells (+/-1) ahead of drag; content stays deferred
            // by MessageFlowCollectionViewController's offscreen early-return path.
            adjacentPagePrewarmShells(
                topInset: topInset,
                truncationBottomInset: truncationBottomInset,
                effectiveSessionKeys: effectiveSessionKeys
            )
            .frame(width: 0, height: 0)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background {
            // This bridge feeds explicit pager motion/settle events into the coordinator state machine.
            // We avoid speculative timing guesses in ChatView itself.
            StreamPagerScrollObserver(
                onInteractionBegan: {
                    StreamSwitchTiming.log("onInteractionBegan_callback_fired", sessionKey: viewModel.uiSelectedSessionKey)
                    viewModel.streamPagerDidBeginInteraction()
                },
                onSettledAtRest: {
                    StreamSwitchTiming.log("pan_settled_callback_fired", sessionKey: viewModel.uiSelectedSessionKey)
                    viewModel.streamPagerDidSettleAtRest()
                },
                currentSessionKey: {
                    viewModel.uiSelectedSessionKey
                }
            )
            .allowsHitTesting(false)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .scrollContentBackground(.hidden)
        .contentShape(Rectangle())
        .background(Color.clear)
    }

    @ViewBuilder
    private func adjacentPagePrewarmShells(topInset: CGFloat,
                                           truncationBottomInset: CGFloat,
                                           effectiveSessionKeys: [String]) -> some View {
        let prewarmKeys = adjacentPrewarmSessionKeys(effectiveSessionKeys: effectiveSessionKeys)
        ForEach(prewarmKeys, id: \.self) { sessionKey in
            MessageFlowCollectionView(
                viewModel: viewModel,
                topInset: topInset,
                isCompact: horizontalSizeClass == .compact,
                // Keep prewarm pages explicitly offscreen so data/snapshot/layout work stays deferred.
                isActiveSession: false,
                isRenderPolicyFrozen: false,
                isInputActive: isInputFocused,
                isTypingActive: isTypingActive,
                truncationBottomInset: truncationBottomInset,
                firstUnreadMessageId: nil,
                unreadCount: 0,
                onExpand: nil,
                layoutCoordinator: layoutCoordinator,
                // Do not register prewarm shells as live session list views.
                shouldRegisterWithLayoutCoordinator: false,
                sessionKey: sessionKey,
                sessionStatus: viewModel.sessionStatus(for: sessionKey),
                forceReReadGeneration: viewModel.forceReReadGeneration(for: sessionKey),
                sendIndicatorRevision: viewModel.sendIndicatorRevision,
                fontScaleChangeSequence: fontScaleChangeSequence,
                onScrollEvent: nil,
                onTypingIndicatorTap: nil,
                onSessionControlSelected: nil
            )
            .hidden()
        }
    }

    private func adjacentPrewarmSessionKeys(effectiveSessionKeys: [String]) -> [String] {
        guard !effectiveSessionKeys.isEmpty else { return [] }
        let primarySelection = effectiveSessionKeys.contains(viewModel.uiSelectedSessionKey)
            ? viewModel.uiSelectedSessionKey
            : viewModel.engineActiveSessionKey
        guard let centerIndex = effectiveSessionKeys.firstIndex(of: primarySelection) else { return [] }
        var keys: [String] = []
        let lower = centerIndex - 1
        let upper = centerIndex + 1
        if lower >= 0 {
            keys.append(effectiveSessionKeys[lower])
        }
        if upper < effectiveSessionKeys.count {
            keys.append(effectiveSessionKeys[upper])
        }
        return keys
    }

    private var renderPolicySessionKey: String {
        let validKeys = Set(viewModel.orderedStreams.map(\.sessionKey))
        let key = viewModel.engineActiveSessionKey
        if validKeys.contains(key), !key.isEmpty {
            return key
        }
        return viewModel.uiSelectedSessionKey
    }

    /// Binding that syncs TabView selection with uiSelectedSessionKey (intent path).
    private var streamBinding: Binding<String> {
        Binding(
            get: {
                let effectiveSessionKeys = viewModel.orderedStreams.map(\.sessionKey)
                let selected = viewModel.uiSelectedSessionKey
                if effectiveSessionKeys.contains(selected), !selected.isEmpty {
                    return selected
                }
                return effectiveSessionKeys.first ?? viewModel.engineActiveSessionKey
            },
            set: { newSessionKey in
                StreamSwitchTiming.log("tabview_selection_setter_fired", sessionKey: newSessionKey)
                selectStream(newSessionKey, source: .pager)
            }
        )
    }

    private func streamPageDotsControl(
        viewModel: ChatViewModel,
        effectiveStreams: [StreamSession],
        streamSelectorMaxHeight: CGFloat,
        containerWidth: CGFloat,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        let effectiveSessionKeys = effectiveStreams.map(\.sessionKey)
        let dotStateLookup = StreamDotStateLookup { sessionKey in
            viewModel.streamDotState(for: sessionKey)
        }
        let pageDotsMaxWidth = inputFieldWidthCap(
            containerWidth: containerWidth,
            bottomSafeAreaInset: bottomSafeAreaInset
        )
        return StreamPopupTrigger(
            routeController: streamPopupRouteController,
            viewModel: viewModel,
            streams: effectiveStreams,
            sessionKeys: effectiveSessionKeys,
            activeSessionKey: viewModel.uiSelectedSessionKey,
            dotStateLookup: dotStateLookup,
            maxWidth: pageDotsMaxWidth,
            maxAvailableHeight: streamSelectorMaxHeight,
            maxAvailableWidth: containerWidth,
            onSelectStream: { sessionKey in
                selectStream(sessionKey, source: .programmatic)
            },
            onPreviewScrubStream: { sessionKey in
                previewScrubStream(sessionKey, viewModel: viewModel)
            },
            onCommitScrubStream: { sessionKey in
                selectStream(sessionKey, source: .programmatic)
            },
            onCancelScrub: {
                streamToastManager.hide()
            },
            onPrepareForTrackPicker: {
                prepareForAttachmentPicker()
            },
            onTrackPickerDismiss: {
                restoreFocusIfNeeded()
            }
        )
    }

    private func selectStream(_ sessionKey: String, source: ChatViewModel.StreamSwitchSource) {
        StreamSwitchTiming.log("selectStream_called", sessionKey: sessionKey)
        viewModel.requestStreamSwitch(to: sessionKey, source: source)
    }

    private func previewScrubStream(_ sessionKey: String, viewModel: ChatViewModel) {
        let streamDisplayName = viewModel.stream(for: sessionKey)?.displayName ?? sessionKey
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            streamToastManager.show(
                displayName: streamDisplayName,
                sessionKey: sessionKey,
                isBusy: false,
                autoDismiss: false
            )
        }
        streamToastBusySince = nil
        streamToastBusyClearTask?.cancel()
        streamToastBusyClearTask = nil
    }

    private var supportsKeyboardNavigationShortcuts: Bool {
#if targetEnvironment(macCatalyst)
        true
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#elseif os(visionOS)
        true
#else
        false
#endif
    }

    private var keyboardScrollShortcutEnabled: Bool {
        supportsKeyboardNavigationShortcuts
            && streamPopupRouteController.route == .closed
            && activeSheet == nil
            && !isAttachmentMenuPresented
            && !isPhotosPickerPresented
            && !isFileImporterPresented
    }

    private var keyboardNavigationSessionKey: String? {
        let sessionKeys = viewModel.orderedStreams.map(\.sessionKey)
        guard !sessionKeys.isEmpty else { return nil }
        if sessionKeys.contains(viewModel.uiSelectedSessionKey), !viewModel.uiSelectedSessionKey.isEmpty {
            return viewModel.uiSelectedSessionKey
        }
        if sessionKeys.contains(viewModel.engineActiveSessionKey), !viewModel.engineActiveSessionKey.isEmpty {
            return viewModel.engineActiveSessionKey
        }
        return sessionKeys.first
    }

    private func scrollVisibleBubbleContents(_ direction: ChatScrollPageDirection) {
        guard let sessionKey = keyboardNavigationSessionKey else { return }
        layoutCoordinator.scrollVisibleBubbleContents(sessionKey: sessionKey, direction: direction, animated: true)
    }

    private func scrollChatSurface(_ direction: ChatScrollPageDirection) {
        guard let sessionKey = keyboardNavigationSessionKey else { return }
        layoutCoordinator.scrollByPage(sessionKey: sessionKey, direction: direction, animated: true)
    }

    private func navigateStreamByShortcut(step: Int, sessionKeys: [String]) {
        guard let targetSessionKey = ChatKeyboardNavigation.targetSessionKey(
            sessionKeys: sessionKeys,
            currentSessionKey: keyboardNavigationSessionKey,
            step: step
        ) else {
            return
        }
        selectStream(targetSessionKey, source: .programmatic)
    }

    private func scheduleStreamToastBusyClear() {
        streamToastBusyClearTask?.cancel()
        let now = Date()
        let elapsed = streamToastBusySince.map { now.timeIntervalSince($0) } ?? 0
        let remaining = max(0, streamToastMinimumBusySeconds - elapsed)
        streamToastBusyClearTask = Task {
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    streamToastManager.setBusy(false)
                }
            }
        }
    }

    private func recordTypingActivity() {
        if !isTypingActive {
            isTypingActive = true
        }
        typingActivityResetTask?.cancel()
        typingActivityResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: typingActivitySettleDelay)
            } catch {
                return
            }
            clearTypingActivity()
        }
    }

    private func clearTypingActivity() {
        typingActivityResetTask?.cancel()
        typingActivityResetTask = nil
        isTypingActive = false
    }

    private func presentCancelCurrentPromptDialog(sessionKey: String? = nil, anchorFrame: CGRect? = nil) {
        if let sessionKey {
            let canCancelVisibleTypingPrompt = viewModel.canCancelVisibleTypingPrompt(in: sessionKey)
            print("T217DIAG present_request build=\(Self.t217DiagnosticBuild) explicitSession=\(sessionKey) canCancelExplicit=\(canCancelVisibleTypingPrompt) canCancelAny=\(viewModel.canCancelCurrentPrompt)")
            logger.notice(
                "T217DIAG present_request build=\(Self.t217DiagnosticBuild, privacy: .public) explicitSession=\(sessionKey, privacy: .public) canCancelExplicit=\(canCancelVisibleTypingPrompt, privacy: .public) canCancelAny=\(viewModel.canCancelCurrentPrompt, privacy: .public)"
            )
            guard canCancelVisibleTypingPrompt else {
                print("T217DIAG present_result build=\(Self.t217DiagnosticBuild) result=suppressed explicitSession=\(sessionKey)")
                logger.notice(
                    "T217DIAG present_result build=\(Self.t217DiagnosticBuild, privacy: .public) result=suppressed explicitSession=\(sessionKey, privacy: .public)"
                )
                cancelCurrentPromptSessionKey = nil
                cancelCurrentPromptRequiresVisibleTyping = false
                cancelCurrentPromptAnchorFrame = nil
                isCancelCurrentPromptDialogPresented = false
                return
            }
            cancelCurrentPromptSessionKey = sessionKey
            cancelCurrentPromptRequiresVisibleTyping = true
            cancelCurrentPromptAnchorFrame = anchorFrame ?? latestTypingIndicatorAnchorFrameBySessionKey[sessionKey]
        } else {
            print("T217DIAG present_request build=\(Self.t217DiagnosticBuild) explicitSession=nil canCancelAny=\(viewModel.canCancelCurrentPrompt)")
            logger.notice(
                "T217DIAG present_request build=\(Self.t217DiagnosticBuild, privacy: .public) explicitSession=nil canCancelAny=\(viewModel.canCancelCurrentPrompt, privacy: .public)"
            )
            guard viewModel.canCancelCurrentPrompt else {
                print("T217DIAG present_result build=\(Self.t217DiagnosticBuild) result=suppressed explicitSession=nil")
                logger.notice(
                    "T217DIAG present_result build=\(Self.t217DiagnosticBuild, privacy: .public) result=suppressed explicitSession=nil"
                )
                cancelCurrentPromptSessionKey = nil
                cancelCurrentPromptRequiresVisibleTyping = false
                cancelCurrentPromptAnchorFrame = nil
                isCancelCurrentPromptDialogPresented = false
                return
            }
            cancelCurrentPromptSessionKey = nil
            cancelCurrentPromptRequiresVisibleTyping = false
            cancelCurrentPromptAnchorFrame = latestTypingIndicatorAnchorFrameForCurrentPrompt()
        }
        isCancelCurrentPromptDialogPresented = true
        print("T217DIAG present_result build=\(Self.t217DiagnosticBuild) result=presented storedSession=\(cancelCurrentPromptSessionKey ?? "nil")")
        logger.notice(
            "T217DIAG present_result build=\(Self.t217DiagnosticBuild, privacy: .public) result=presented storedSession=\(cancelCurrentPromptSessionKey ?? "nil", privacy: .public)"
        )
    }

    private func latestTypingIndicatorAnchorFrameForCurrentPrompt() -> CGRect? {
        if let anchorFrame = latestTypingIndicatorAnchorFrameBySessionKey[viewModel.uiSelectedSessionKey] {
            return anchorFrame
        }
        if let typingSessionKey = viewModel.typingSessionKey,
           let anchorFrame = latestTypingIndicatorAnchorFrameBySessionKey[typingSessionKey] {
            return anchorFrame
        }
        return nil
    }

    private func insertPromptTextFromNoTextOwner(_ text: String) {
        guard let insertedText = PromptFocusTypingActivation.promptInsertionText(from: text) else { return }
        let mutable = NSMutableAttributedString(attributedString: viewModel.inputContent)
        let insertionRange = clampedPromptSelectionRange(length: mutable.length)
        mutable.replaceCharacters(in: insertionRange, with: NSAttributedString(string: insertedText))
        viewModel.inputContent = mutable
        selectionRange = NSRange(location: insertionRange.location + (insertedText as NSString).length, length: 0)
        recordTypingActivity()
        focusRequestID &+= 1
    }

    private func clampedPromptSelectionRange(length: Int) -> NSRange {
        guard selectionRange.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let safeLocation = min(max(selectionRange.location, 0), length)
        let safeLength = max(0, min(selectionRange.length, length - safeLocation))
        return NSRange(location: safeLocation, length: safeLength)
    }

    private func scheduleInputFocusChange(_ focused: Bool) {
        Task { @MainActor in
            applyInputFocusChange(focused)
        }
    }

    private func applyInputFocusChange(_ focused: Bool) {
        if isInputFocused != focused {
            isInputFocused = focused
        }
        if !focused {
            clearTypingActivity()
        }
    }

    private func deviceCornerRadius() -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let hasRoundedCorners = (window?.safeAreaInsets.bottom ?? 0) > 0
        return hasRoundedCorners ? 50 : 0
    }

    @MainActor
    private func prepareForAttachmentPicker() {
        shouldRestoreFocusAfterPicker = isInputFocused
    }

    @MainActor
    private func restoreFocusIfNeeded() {
        guard shouldRestoreFocusAfterPicker else { return }
        focusRequestID &+= 1
        shouldRestoreFocusAfterPicker = false
    }

    @MainActor
    private func presentCamera() {
        prepareForAttachmentPicker()
#if os(visionOS)
        toastManager.show(error: .cameraUnavailable)
        restoreFocusIfNeeded()
        return
#else
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            toastManager.show(error: .cameraUnavailable)
            restoreFocusIfNeeded()
            return
        }
        activeSheet = .camera
#endif
    }

    @MainActor
    private func presentPhotoPicker() {
        prepareForAttachmentPicker()
        activeSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isPhotosPickerPresented = true
        }
    }

    @MainActor
    private func presentFileImporter() {
        prepareForAttachmentPicker()
        activeSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isFileImporterPresented = true
        }
    }

    private func handleCapturedImage(_ image: UIImage) async {
        guard let attachment = Self.makeImageAttachment(from: image, suggestedFilename: "camera.jpg") else {
            await MainActor.run { toastManager.show(error: .invalidData) }
            return
        }
        await MainActor.run {
            insertAttachments([attachment], source: "camera")
        }
    }

    @MainActor
    private func handlePastedImages(_ images: [UIImage]) {
        logger.info("Pasted \(images.count) image(s) from clipboard")
        Task { @MainActor in
            let attachments = await withAttachmentStaging {
                await Self.buildPastedAttachments(from: images)
            }
            guard !attachments.isEmpty else {
                toastManager.show(error: .invalidData)
                return
            }
            insertAttachments(attachments, source: "paste")
        }
    }

    private func withAttachmentStaging<T>(_ operation: () async -> T) async -> T {
        await MainActor.run {
            viewModel.beginAttachmentStaging()
        }
        let result = await operation()
        await MainActor.run {
            viewModel.endAttachmentStaging()
        }
        return result
    }

    private func handlePhotoPickerItems(_ items: [PhotosPickerItem]) async {
        var attachments: [PendingAttachment] = []
        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let attachment = Self.makeImageAttachment(from: image, suggestedFilename: item.itemIdentifier) {
                attachments.append(attachment)
                continue
            }

            if let data = try? await item.loadTransferable(type: Data.self),
               let attachment = makeVideoAttachment(from: data, item: item, index: index) {
                attachments.append(attachment)
            }
        }
        if attachments.isEmpty {
            await MainActor.run { toastManager.show(error: .invalidData) }
            return
        }
        await MainActor.run {
            insertAttachments(attachments, source: "photo_picker")
        }
    }

    private func makeVideoAttachment(from data: Data, item: PhotosPickerItem, index: Int) -> PendingAttachment? {
        guard !data.isEmpty else { return nil }
        guard let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) }) else {
            return nil
        }
        let mimeType = contentType.preferredMIMEType ?? "video/mp4"
        let fileExtension = contentType.preferredFilenameExtension ?? "mp4"
        let filename = "video-\(index + 1).\(fileExtension)"
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: makeDocumentThumbnail(),
            mimeType: mimeType,
            filename: filename
        )
    }

    private func handleDocumentResults(_ urls: [URL]) async {
        var attachments: [PendingAttachment] = []
        for url in urls {
            do {
                let attachment = try loadDocumentAttachment(from: url)
                attachments.append(attachment)
            } catch let attachmentError as AttachmentError {
                await MainActor.run { toastManager.show(error: attachmentError) }
            } catch {
                await MainActor.run { toastManager.show(error.localizedDescription) }
            }
        }
        guard !attachments.isEmpty else { return }
        await MainActor.run {
            insertAttachments(attachments, source: "file_importer")
        }
    }

    @MainActor
    private func insertAttachments(_ attachments: [PendingAttachment], source: String) {
        guard !attachments.isEmpty else { return }
        viewModel.stageAttachments(attachments, source: source)
        pendingInputInsertions = attachments
    }

    private func loadDocumentAttachment(from url: URL) throws -> PendingAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw AttachmentError.invalidData }
        let mimeType = mimeType(for: url)
        let thumbnail = makeDocumentThumbnail()
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: thumbnail,
            mimeType: mimeType,
            filename: url.lastPathComponent
        )
    }

    private static func makeImageAttachment(from image: UIImage, suggestedFilename: String?) -> PendingAttachment? {
        guard let (data, mimeType) = encodeImage(image) else { return nil }
        return PendingAttachment(
            id: UUID(),
            data: data,
            thumbnail: makeThumbnail(from: image),
            mimeType: mimeType,
            filename: suggestedFilename
        )
    }

    private static func encodeImage(_ image: UIImage) -> (Data, String)? {
        if let data = image.jpegData(compressionQuality: 0.85) {
            return (data, "image/jpeg")
        }
        if let data = image.pngData() {
            return (data, "image/png")
        }
        return nil
    }

    private static func makeThumbnail(from image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 120
        let scale = min(maxDimension / max(image.size.width, image.size.height), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func buildPastedAttachments(from images: [UIImage]) async -> [PendingAttachment] {
        await withCheckedContinuation { continuation in
            let copiedImages = images
            DispatchQueue.global(qos: .userInitiated).async {
                var attachments: [PendingAttachment] = []
                attachments.reserveCapacity(copiedImages.count)
                for (index, image) in copiedImages.enumerated() {
                    let filename = copiedImages.count > 1 ? "pasted-\(index + 1).png" : "pasted.png"
                    if let attachment = makeImageAttachment(from: image, suggestedFilename: filename) {
                        attachments.append(attachment)
                    }
                }
                continuation.resume(returning: attachments)
            }
        }
    }

    private func makeDocumentThumbnail() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.systemGray5.setFill()
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
            path.fill()

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            let symbol = UIImage(systemName: "doc.fill", withConfiguration: symbolConfig)?
                .withRenderingMode(.alwaysTemplate)
            UIColor.systemBlue.setFill()
            symbol?.draw(in: rect.insetBy(dx: 16, dy: 16))
        }
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private struct ToastBanner: View {
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?
        let dismiss: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Text(message)
                    .font(.clawline(.uiLabel).weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
#if os(visionOS)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.3))
            )
#else
            .glassEffect(.regular, in: Capsule())
#endif
            .onTapGesture(perform: dismiss)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        if value.translation.height < -10 {
                            dismiss()
                        }
                    }
            )
            .accessibilityLabel(message)
            .accessibilityHint(actionTitle == nil ? "Dismiss with tap or swipe up." : "Tap Undo to restore or tap elsewhere to dismiss.")
            .accessibilityAddTraits(.isStaticText)
            .onAppear {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

}

private struct VisionOSInputBarDepthOffset: ViewModifier {
    func body(content: Content) -> some View {
#if os(visionOS)
        // #49: subtle z-plane separation for spatial affordance (do not apply on iOS/iPadOS).
        content.offset(z: 24)
#else
        content
#endif
    }
}

private struct VisionOSOverlayDepthOffset: ViewModifier {
    let depth: CGFloat

    func body(content: Content) -> some View {
#if os(visionOS)
        content.offset(z: depth)
#else
        content
#endif
    }
}

private struct StreamPopupTrigger: View {
    @Bindable var routeController: StreamPopupRouteController

    let viewModel: ChatViewModel
    let streams: [StreamSession]
    let sessionKeys: [String]
    let activeSessionKey: String
    let dotStateLookup: StreamDotStateLookup
    let maxWidth: CGFloat?
    let maxAvailableHeight: CGFloat
    let maxAvailableWidth: CGFloat
    let onSelectStream: (String) -> Void
    let onPreviewScrubStream: (String) -> Void
    let onCommitScrubStream: (String) -> Void
    let onCancelScrub: () -> Void
    let onPrepareForTrackPicker: () -> Void
    let onTrackPickerDismiss: () -> Void

    var body: some View {
        StreamPageDotsView(
            sessionKeys: sessionKeys,
            activeSessionKey: activeSessionKey,
            dotStateLookup: dotStateLookup,
            maxWidth: maxWidth,
            onTap: {
                routeController.openPopup(focusSearch: false)
            },
            onScrubPreview: onPreviewScrubStream,
            onScrubCommit: onCommitScrubStream,
            onScrubCancel: onCancelScrub,
            onScrubCandidateHaptic: { style in
                #if !os(visionOS)
                let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
                switch style {
                case .light:
                    feedbackStyle = .light
                case .strong:
                    feedbackStyle = .rigid
                }
                let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
                generator.impactOccurred()
                #endif
            }
        )
        .popover(
            isPresented: popupPresentationBinding,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            StreamManagerSheet(
                viewModel: viewModel,
                streams: streams,
                dotStateLookup: dotStateLookup,
                searchFocusRequestID: routeController.popupSearchFocusRequestID,
                maxAvailableHeight: maxAvailableHeight,
                maxAvailableWidth: maxAvailableWidth,
                onSelectStream: { sessionKey in
                    routeController.closePopup()
                    onSelectStream(sessionKey)
                },
                onRequestTrackPicker: {
                    onPrepareForTrackPicker()
                    routeController.presentTrackPicker()
                },
                onConsumeSearchFocusRequest: {
                    routeController.consumeSearchFocusRequest()
                }
            )
            .presentationCompactAdaptation(.popover)
            .streamManagerPopoverBackgroundInteraction()
        }
        .sheet(
            isPresented: trackPickerPresentationBinding,
            onDismiss: {
                routeController.dismissTrackPicker()
                onTrackPickerDismiss()
            }
        ) {
            TrackPickerSheet(
                viewModel: viewModel,
                onDismissRequested: {
                    routeController.dismissTrackPicker()
                }
            )
        }
    }

    private var popupPresentationBinding: Binding<Bool> {
        Binding(
            get: { routeController.isPopupPresented },
            set: { isPresented in
                if isPresented {
                    routeController.openPopup(focusSearch: false)
                } else {
                    routeController.closePopup()
                }
            }
        )
    }

    private var trackPickerPresentationBinding: Binding<Bool> {
        Binding(
            get: { routeController.isTrackPickerPresented },
            set: { isPresented in
                if isPresented {
                    routeController.presentTrackPicker()
                } else {
                    routeController.dismissTrackPicker()
                }
            }
        )
    }
}

private extension View {
    func visionOSInputBarDepthOffset() -> some View {
        modifier(VisionOSInputBarDepthOffset())
    }

    func visionOSOverlayDepthOffset(_ depth: CGFloat) -> some View {
        modifier(VisionOSOverlayDepthOffset(depth: depth))
    }

    @ViewBuilder
    func streamManagerPopoverBackgroundInteraction() -> some View {
#if os(visionOS)
        self
#else
        self.presentationBackgroundInteraction(.enabled)
#endif
    }

    func handlePromptFocusCommand(
        onFocusRequested: @escaping () -> Void
    ) -> some View {
        modifier(
            PromptFocusCommandModifier(
                onFocusRequested: onFocusRequested
            )
        )
    }

    func handleStreamPopupCommand(
        hasStreams: Bool,
        onOpen: @escaping () -> Void
    ) -> some View {
        modifier(
            StreamPopupCommandModifier(
                hasStreams: hasStreams,
                onOpen: onOpen
            )
        )
    }

    func handleStreamNavigationCommands(
        isEnabled: Bool,
        onNavigatePrevious: @escaping () -> Void,
        onNavigateNext: @escaping () -> Void
    ) -> some View {
        modifier(
            StreamNavigationCommandModifier(
                isEnabled: isEnabled,
                onNavigatePrevious: onNavigatePrevious,
                onNavigateNext: onNavigateNext
            )
        )
    }

    func handleKeyboardScrollCommands(
        isEnabled: Bool,
        keyboardOwnershipStore: KeyboardOwnershipStore,
        onScrollDown: @escaping () -> Void,
        onScrollUp: @escaping () -> Void,
        onScrollChatDown: @escaping () -> Void,
        onScrollChatUp: @escaping () -> Void
    ) -> some View {
        modifier(
            KeyboardScrollCommandModifier(
                isEnabled: isEnabled,
                keyboardOwnershipStore: keyboardOwnershipStore,
                onScrollDown: onScrollDown,
                onScrollUp: onScrollUp,
                onScrollChatDown: onScrollChatDown,
                onScrollChatUp: onScrollChatUp
            )
        )
    }

}

private struct PromptFocusCommandModifier: ViewModifier {
    let onFocusRequested: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .clawlineFocusPromptInputCommand)) { _ in
            onFocusRequested()
        }
    }
}

private struct StreamPopupCommandModifier: ViewModifier {
    let hasStreams: Bool
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .clawlineOpenStreamPopupCommand)) { _ in
            guard hasStreams else { return }
            onOpen()
        }
    }
}

private struct StreamNavigationCommandModifier: ViewModifier {
    let isEnabled: Bool
    let onNavigatePrevious: () -> Void
    let onNavigateNext: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .clawlineNavigateToPreviousStreamCommand)) { _ in
                guard isEnabled else { return }
                onNavigatePrevious()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineNavigateToNextStreamCommand)) { _ in
                guard isEnabled else { return }
                onNavigateNext()
            }
    }
}

private struct KeyboardScrollCommandModifier: ViewModifier {
    let isEnabled: Bool
    var keyboardOwnershipStore = KeyboardOwnershipStore()
    let onScrollDown: () -> Void
    let onScrollUp: () -> Void
    let onScrollChatDown: () -> Void
    let onScrollChatUp: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollDownCommand)) { _ in
                guard isEnabled else { return }
                switch KeyboardCommandRouter.route(intent: .transcriptBubbleScrollForward, store: keyboardOwnershipStore).outcome {
                case .handled(.notificationBubble(_)):
                    NotificationCenter.default.post(name: .clawlineScrollNotificationDownCommand, object: nil)
                case .handled(.transcript):
                    onScrollDown()
                default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollUpCommand)) { _ in
                guard isEnabled else { return }
                switch KeyboardCommandRouter.route(intent: .transcriptBubbleScrollBackward, store: keyboardOwnershipStore).outcome {
                case .handled(.notificationBubble(_)):
                    NotificationCenter.default.post(name: .clawlineScrollNotificationUpCommand, object: nil)
                case .handled(.transcript):
                    onScrollUp()
                default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollChatDownCommand)) { _ in
                guard isEnabled else { return }
                switch KeyboardCommandRouter.route(intent: .transcriptChatScrollForward, store: keyboardOwnershipStore).outcome {
                case .handled(.notificationBubble(_)):
                    NotificationCenter.default.post(name: .clawlineScrollNotificationDownCommand, object: nil)
                case .handled(.transcript):
                    onScrollChatDown()
                default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollChatUpCommand)) { _ in
                guard isEnabled else { return }
                switch KeyboardCommandRouter.route(intent: .transcriptChatScrollBackward, store: keyboardOwnershipStore).outcome {
                case .handled(.notificationBubble(_)):
                    NotificationCenter.default.post(name: .clawlineScrollNotificationUpCommand, object: nil)
                case .handled(.transcript):
                    onScrollChatUp()
                default:
                    break
                }
            }
    }
}

private struct CancelCurrentPromptConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let anchorFrame: CGRect?
    let canCancel: Bool
    let canPresentCommand: Bool
    let onPresentCommand: () -> Void
    let onConfirm: () -> Void

    private var command: CancelCurrentPromptCommand? {
        guard canPresentCommand else { return nil }
        return CancelCurrentPromptCommand {
            onPresentCommand()
        }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: canCancel) { _, newValue in
                if !newValue {
                    isPresented = false
                }
            }
            .focusedSceneValue(\.cancelCurrentPromptCommand, command)
            .overlay {
                if isPresented {
                    GeometryReader { proxy in
                        let proxyFrame = proxy.frame(in: .global)
                        CancelCurrentPromptBubbleOverlay(
                            anchorFrame: resolvedAnchorFrame(in: proxyFrame),
                            proxyFrame: proxyFrame,
                            onDismiss: {
                                isPresented = false
                            },
                            onCancelPrompt: {
                                isPresented = false
                                onConfirm()
                            }
                        )
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(50)
                }
            }
    }

    private func resolvedAnchorFrame(in proxyFrame: CGRect) -> CGRect {
        guard let anchorFrame,
              anchorFrame.isNull == false,
              anchorFrame.isEmpty == false else {
            return CGRect(
                x: proxyFrame.midX - 1,
                y: proxyFrame.midY - 1,
                width: 2,
                height: 2
            )
        }
        return anchorFrame
    }
}

private enum CancelCurrentPromptBubbleTailEdge {
    case top
    case bottom
}

private struct CancelCurrentPromptBubblePlacement {
    let origin: CGPoint
    let size: CGSize
    let tailEdge: CancelCurrentPromptBubbleTailEdge
    let tailCenterX: CGFloat
}

private struct CancelCurrentPromptBubbleOverlay: View {
    let anchorFrame: CGRect
    let proxyFrame: CGRect
    let onDismiss: () -> Void
    let onCancelPrompt: () -> Void

    private let bubbleSize = CGSize(width: 172, height: 78)
    private let margin: CGFloat = 12
    private let gap: CGFloat = 8
    private let cornerRadius: CGFloat = 20
    private let tailWidth: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let placement = placement(in: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)

                Button("Dismiss cancel prompt") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .accessibilityHidden(true)

                CancelCurrentPromptPopup(
                    tailEdge: placement.tailEdge,
                    tailCenterX: placement.tailCenterX,
                    onCancelPrompt: onCancelPrompt
                )
                .frame(width: placement.size.width, height: placement.size.height)
                .position(
                    x: placement.origin.x + placement.size.width / 2,
                    y: placement.origin.y + placement.size.height / 2
                )
            }
            .background(
                CancelCurrentPromptBubbleKeyBridge(
                    onConfirm: onCancelPrompt,
                    onDismiss: onDismiss
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            )
        }
    }

    private func placement(in containerSize: CGSize) -> CancelCurrentPromptBubblePlacement {
        let anchor = CGRect(
            x: anchorFrame.minX - proxyFrame.minX,
            y: anchorFrame.minY - proxyFrame.minY,
            width: anchorFrame.width,
            height: anchorFrame.height
        )

        let fitsAbove = anchor.minY - gap - bubbleSize.height >= margin
        let tailEdge: CancelCurrentPromptBubbleTailEdge = fitsAbove ? .bottom : .top
        let proposedY = fitsAbove
            ? anchor.minY - gap - bubbleSize.height
            : anchor.maxY + gap
        let maxY = max(margin, containerSize.height - margin - bubbleSize.height)
        let y = min(max(proposedY, margin), maxY)

        let proposedX = anchor.width <= 4
            ? anchor.midX - bubbleSize.width / 2
            : anchor.minX
        let maxX = max(margin, containerSize.width - margin - bubbleSize.width)
        let x = min(max(proposedX, margin), maxX)
        let tailInset = cornerRadius + tailWidth / 2
        let tailCenterX = min(max(anchor.midX - x, tailInset), bubbleSize.width - tailInset)

        return CancelCurrentPromptBubblePlacement(
            origin: CGPoint(x: x, y: y),
            size: bubbleSize,
            tailEdge: tailEdge,
            tailCenterX: tailCenterX
        )
    }
}

private struct CancelCurrentPromptPopup: View {
    let tailEdge: CancelCurrentPromptBubbleTailEdge
    let tailCenterX: CGFloat
    let onCancelPrompt: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false

    private let rowHeight: CGFloat = 44
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 12
    private let popupCornerRadius: CGFloat = 20
    private let buttonCornerRadius: CGFloat = 14
    private let tailHeight: CGFloat = 10
    private let tailWidth: CGFloat = 22

    var body: some View {
        content
            .padding(.top, tailEdge == .top ? tailHeight : 0)
            .padding(.bottom, tailEdge == .bottom ? tailHeight : 0)
            .modifier(CancelCurrentPromptBubbleChrome(shape: bubbleShape))
            .overlay {
                bubbleShape
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(bubbleShape)
            .accessibilityElement(children: .contain)
    }

    private var content: some View {
        Button(action: onCancelPrompt) {
            Text("Cancel")
                .font(.clawline(.uiLabel).weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                .contentShape(Rectangle())
                .background(buttonBackground)
                .scaleEffect(isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private var bubbleShape: CancelCurrentPromptBubbleShape {
        CancelCurrentPromptBubbleShape(
            tailEdge: tailEdge,
            tailCenterX: tailCenterX,
            cornerRadius: popupCornerRadius,
            tailWidth: tailWidth,
            tailHeight: tailHeight
        )
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
            .fill(ChatFlowTheme.connectionDisconnected(colorScheme).opacity(isPressed ? 0.82 : 1))
    }
}

private struct CancelCurrentPromptBubbleKeyBridge: UIViewRepresentable {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: KeyCommandView, context: Context) {
        context.coordinator.onConfirm = onConfirm
        context.coordinator.onDismiss = onDismiss
        DispatchQueue.main.async {
            uiView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onConfirm: onConfirm, onDismiss: onDismiss)
    }

    final class Coordinator {
        var onConfirm: () -> Void
        var onDismiss: () -> Void

        init(onConfirm: @escaping () -> Void, onDismiss: @escaping () -> Void) {
            self.onConfirm = onConfirm
            self.onDismiss = onDismiss
        }
    }

    final class KeyCommandView: UIView {
        weak var delegate: Coordinator?

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleDismiss)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleConfirm)),
                UIKeyCommand(input: "\n", modifierFlags: [], action: #selector(handleConfirm))
            ]
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.becomeFirstResponder()
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses {
                guard let key = press.key, key.hasNoCommandModifiers else { continue }
                switch key.keyCode {
                case .keyboardEscape:
                    handleDismiss()
                    return
                case .keyboardReturnOrEnter:
                    handleConfirm()
                    return
                default:
                    continue
                }
            }
            super.pressesBegan(presses, with: event)
        }

        @objc private func handleConfirm() {
            delegate?.onConfirm()
        }

        @objc private func handleDismiss() {
            delegate?.onDismiss()
        }
    }
}

private struct CancelCurrentPromptBubbleChrome: ViewModifier {
    let shape: CancelCurrentPromptBubbleShape

    func body(content: Content) -> some View {
#if os(visionOS)
        content
            .background(.regularMaterial, in: shape)
#else
        content
            .glassEffect(.regular, in: shape)
#endif
    }
}

private struct CancelCurrentPromptBubbleShape: Shape {
    let tailEdge: CancelCurrentPromptBubbleTailEdge
    let tailCenterX: CGFloat
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let bodyRect: CGRect
        switch tailEdge {
        case .top:
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY + tailHeight,
                width: rect.width,
                height: rect.height - tailHeight
            )
        case .bottom:
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: rect.height - tailHeight
            )
        }

        let radius = min(cornerRadius, min(bodyRect.width, bodyRect.height) / 2)
        let clampedTailCenterX = min(
            max(tailCenterX, radius + tailWidth / 2),
            rect.width - radius - tailWidth / 2
        )
        let tailLeftX = rect.minX + clampedTailCenterX - tailWidth / 2
        let tailRightX = rect.minX + clampedTailCenterX + tailWidth / 2

        var path = Path(roundedRect: bodyRect, cornerRadius: radius, style: .continuous)
        var tail = Path()
        switch tailEdge {
        case .top:
            tail.move(to: CGPoint(x: tailLeftX, y: bodyRect.minY + 1))
            tail.addLine(to: CGPoint(x: rect.minX + clampedTailCenterX, y: rect.minY))
            tail.addLine(to: CGPoint(x: tailRightX, y: bodyRect.minY + 1))
        case .bottom:
            tail.move(to: CGPoint(x: tailLeftX, y: bodyRect.maxY - 1))
            tail.addLine(to: CGPoint(x: rect.minX + clampedTailCenterX, y: rect.maxY))
            tail.addLine(to: CGPoint(x: tailRightX, y: bodyRect.maxY - 1))
        }
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}

private struct PromptFocusShortcutModifier: ViewModifier {
    let isEnabled: Bool
    let hasStreams: Bool
    let onOpenStreamPopup: () -> Void
    let onFocusRequested: () -> Void
    let onTextInserted: (String) -> Void
    let notificationVisibleCount: Int
    let keyboardOwnershipStore: KeyboardOwnershipStore

    func body(content: Content) -> some View {
        content.background {
            PromptFocusShortcutHost(
                isEnabled: isEnabled,
                hasStreams: hasStreams,
                onOpenStreamPopup: onOpenStreamPopup,
                onFocusRequested: onFocusRequested,
                onTextInserted: onTextInserted,
                notificationVisibleCount: notificationVisibleCount,
                keyboardOwnershipStore: keyboardOwnershipStore
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }
}

private struct PromptFocusShortcutHost: UIViewRepresentable {
    let isEnabled: Bool
    let hasStreams: Bool
    let onOpenStreamPopup: () -> Void
    let onFocusRequested: () -> Void
    let onTextInserted: (String) -> Void
    let notificationVisibleCount: Int
    let keyboardOwnershipStore: KeyboardOwnershipStore

    func makeUIView(context: Context) -> PromptFocusShortcutView {
        let view = PromptFocusShortcutView()
        view.onOpenStreamPopup = onOpenStreamPopup
        view.onFocusRequested = onFocusRequested
        view.onTextInserted = onTextInserted
        view.isShortcutEnabled = isEnabled
        view.hasStreams = hasStreams
        view.notificationVisibleCount = notificationVisibleCount
        view.keyboardOwnershipStore = keyboardOwnershipStore
        return view
    }

    func updateUIView(_ view: PromptFocusShortcutView, context: Context) {
        view.onOpenStreamPopup = onOpenStreamPopup
        view.onFocusRequested = onFocusRequested
        view.onTextInserted = onTextInserted
        view.isShortcutEnabled = isEnabled
        view.hasStreams = hasStreams
        view.notificationVisibleCount = notificationVisibleCount
        view.keyboardOwnershipStore = keyboardOwnershipStore
        if isEnabled {
            view.activateWhenReady()
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

private final class PromptFocusShortcutView: UIView {
    var onOpenStreamPopup: (() -> Void)?
    var onFocusRequested: (() -> Void)?
    var onTextInserted: ((String) -> Void)?
    var isShortcutEnabled = false
    var hasStreams = false
    var notificationVisibleCount = 0
    var keyboardOwnershipStore = KeyboardOwnershipStore()
    private var hasPendingActivationRetry = false
    private static let keyboardSuppressingInputView = PromptFocusShortcutSuppressedInputView()

    // T221: This hidden responder is the no-text-owner input-intent router. The chat
    // surface owns scroll/selection/content interaction, and Prompt Input owns real
    // editing; this view only bridges ordinary typing from "nothing owns text input"
    // to "Prompt Input should take over."
    override var canBecomeFirstResponder: Bool {
        isShortcutEnabled
    }

    override var inputView: UIView? {
        Self.keyboardSuppressingInputView
    }

    override var keyCommands: [UIKeyCommand]? {
        guard isShortcutEnabled else { return nil }
        let noTextCommands = PromptFocusShortcutConfiguration.keyCommandSpecs.map { spec in
            UIKeyCommand(
                input: spec.input,
                modifierFlags: spec.modifierFlags,
                action: selector(for: spec.action)
            )
        }
        let appCommandShortcuts = ChatAppCommandShortcut
            .keyCommandSpecs(notificationVisibleCount: notificationVisibleCount)
            .map { spec in
            UIKeyCommand(
                input: spec.input,
                modifierFlags: spec.modifierFlags,
                action: spec.action.selector
            )
        }
        return noTextCommands + appCommandShortcuts
    }

    private func selector(for action: PromptFocusShortcutConfiguration.Action) -> Selector {
        switch action {
        case .focusPromptInput:
            return #selector(focusPromptInput)
        case .openStreamPopup:
            return #selector(openStreamPopup)
        }
    }

    func activateWhenReady(textInputRetryCount: Int = 1) {
        guard window != nil else {
            DispatchQueue.main.async { [weak self] in
                self?.activateWhenReady()
            }
            return
        }
        switch PromptFocusShortcutActivation.action(
            isShortcutEnabled: isShortcutEnabled,
            isAlreadyFirstResponder: isFirstResponder,
            currentFirstResponderIsTextInput: window?.clawlineFirstResponder?.isClawlineTextInputResponder == true,
            currentFirstResponderOwnsEmbeddedScroll: window?.clawlineFirstResponder?.ownsClawlineEmbeddedScrollInput == true,
            canRetryAfterTextInput: textInputRetryCount > 0
        ) {
        case .activate:
            hasPendingActivationRetry = false
            becomeFirstResponder()
        case .retryAfterTextInputResigns:
            scheduleActivationRetry(textInputRetryCount: textInputRetryCount - 1)
        case .skip:
            hasPendingActivationRetry = false
        }
    }

    private func scheduleActivationRetry(textInputRetryCount: Int) {
        guard !hasPendingActivationRetry else { return }
        hasPendingActivationRetry = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hasPendingActivationRetry = false
            activateWhenReady(textInputRetryCount: textInputRetryCount)
        }
    }

    @objc private func focusPromptInput(_ sender: UIKeyCommand) {
        guard isShortcutEnabled,
              routeOwnsTranscript(intent: .focusPromptInput) else { return }
        onFocusRequested?()
    }

    @objc private func openStreamPopup(_ sender: UIKeyCommand) {
        guard isShortcutEnabled,
              hasStreams,
              routeOwnsTranscript(intent: .openStreamPopup) else { return }
        onOpenStreamPopup?()
    }

    private func routeOwnsTranscript(intent: KeyboardCommandIntent) -> Bool {
        guard case .handled(.transcript) = KeyboardCommandRouter
            .route(intent: intent, store: keyboardOwnershipStore)
            .outcome else { return false }
        return true
    }
}

// The catcher must stay side-effect-free: no visible UI, no software keyboard, and
// no lasting editing ownership. Hardware/composed text may reach `insertText(_:)`,
// but the responder immediately hands the intent to Prompt Input.
private final class PromptFocusShortcutSuppressedInputView: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 0)
    }
}

extension PromptFocusShortcutView: UIKeyInput {
    var hasText: Bool {
        false
    }

    func insertText(_ text: String) {
        guard isShortcutEnabled else { return }
        // Product invariant: when nothing else owns text input, typing intent reaches Prompt Input.
        onTextInserted?(text)
    }

    func deleteBackward() {}
}

enum PromptFocusShortcutConfiguration {
    enum Action: Equatable {
        case focusPromptInput
        case openStreamPopup
    }

    struct KeyCommandSpec {
        let input: String
        let modifierFlags: UIKeyModifierFlags
        let action: Action
    }

    static let keyCommandSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "/", modifierFlags: [], action: .openStreamPopup),
        KeyCommandSpec(input: ";", modifierFlags: [], action: .openStreamPopup),
        KeyCommandSpec(input: " ", modifierFlags: [], action: .focusPromptInput),
        KeyCommandSpec(input: "\r", modifierFlags: [], action: .focusPromptInput)
    ]
}

enum ChatAppCommandShortcut {
    enum Action: Equatable {
        case focusPromptInput
        case openStreamPopup
        case navigatePreviousStream
        case navigateNextStream
        case scrollDown
        case scrollUp
        case scrollChatDown
        case scrollChatUp
        case scrollNotificationDown
        case scrollNotificationUp
        case notificationNumber

        var selector: Selector {
            switch self {
            case .focusPromptInput:
                return #selector(UIResponder.clawlineFocusPromptInputCommand(_:))
            case .openStreamPopup:
                return #selector(UIResponder.clawlineOpenStreamPopupCommand(_:))
            case .navigatePreviousStream:
                return #selector(UIResponder.clawlineNavigateToPreviousStreamCommand(_:))
            case .navigateNextStream:
                return #selector(UIResponder.clawlineNavigateToNextStreamCommand(_:))
            case .scrollDown:
                return #selector(UIResponder.clawlineScrollDownCommand(_:))
            case .scrollUp:
                return #selector(UIResponder.clawlineScrollUpCommand(_:))
            case .scrollChatDown:
                return #selector(UIResponder.clawlineScrollChatDownCommand(_:))
            case .scrollChatUp:
                return #selector(UIResponder.clawlineScrollChatUpCommand(_:))
            case .scrollNotificationDown:
                return #selector(UIResponder.clawlineScrollNotificationDownCommand(_:))
            case .scrollNotificationUp:
                return #selector(UIResponder.clawlineScrollNotificationUpCommand(_:))
            case .notificationNumber:
                return #selector(UIResponder.clawlineNotificationNumberCommand(_:))
            }
        }
    }

    struct KeyCommandSpec {
        let input: String
        let modifierFlags: UIKeyModifierFlags
        let action: Action
    }

    static let baseKeyCommandSpecs = convert(KeyboardCommandBridge.navigationSpecs + KeyboardCommandBridge.transcriptScrollSpecs)

    static let keyCommandSpecs = keyCommandSpecs(notificationVisibleCount: 0)

    static func keyCommandSpecs(notificationVisibleCount: Int) -> [KeyCommandSpec] {
        convert(KeyboardCommandBridge.appSpecs(notificationVisibleCount: notificationVisibleCount))
    }

    static func scrollKeyCommandSpecs(notificationVisibleCount: Int) -> [KeyCommandSpec] {
        convert(KeyboardCommandBridge.transcriptScrollSpecs)
    }

    static func notificationScrollKeyCommandSpecs(notificationVisibleCount: Int) -> [KeyCommandSpec] {
        convert(KeyboardCommandBridge.notificationScrollSpecs)
    }

    static func prioritizedTextInputKeyCommandSpecs(notificationVisibleCount: Int) -> [KeyCommandSpec] {
        convert(KeyboardCommandBridge.prioritizedTextInputSpecs(notificationVisibleCount: notificationVisibleCount))
    }

    static func notificationNumberKeyCommandSpecs(visibleCount: Int) -> [KeyCommandSpec] {
        convert(KeyboardCommandBridge.notificationNumberSpecs(visibleCount: visibleCount))
    }

    private static func convert(_ specs: [KeyboardCommandBridge.KeyCommandSpec]) -> [KeyCommandSpec] {
        specs.compactMap { spec in
            guard let action = action(for: spec.intent) else { return nil }
            return KeyCommandSpec(
                input: spec.input,
                modifierFlags: spec.modifierFlags,
                action: action
            )
        }
    }

    private static func action(for intent: KeyboardCommandIntent) -> Action? {
        switch intent {
        case .focusPromptInput:
            return .focusPromptInput
        case .openStreamPopup:
            return .openStreamPopup
        case .navigatePreviousStream:
            return .navigatePreviousStream
        case .navigateNextStream:
            return .navigateNextStream
        case .transcriptBubbleScrollForward:
            return .scrollDown
        case .transcriptBubbleScrollBackward:
            return .scrollUp
        case .transcriptChatScrollForward:
            return .scrollChatDown
        case .transcriptChatScrollBackward:
            return .scrollChatUp
        case .notificationScrollForward:
            return .scrollNotificationDown
        case .notificationScrollBackward:
            return .scrollNotificationUp
        case .notificationAssignedOpen,
             .notificationAssignedReply,
             .notificationAssignedDismiss:
            return .notificationNumber
        default:
            return nil
        }
    }
}

enum PromptFocusTypingActivation {
    static func promptInsertionText(from insertedText: String) -> String? {
        guard !insertedText.isEmpty else { return nil }
        guard !["/", ";", " ", "\r", "\n"].contains(insertedText) else { return nil }
        guard insertedText.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return insertedText
    }
}

enum ChatRootKeyboardCommandDispatch {
    static func notificationName(
        for intent: KeyboardCommandIntent,
        keyboardOwnershipStore: KeyboardOwnershipStore
    ) -> Notification.Name? {
        let route = KeyboardCommandRouter.route(intent: intent, store: keyboardOwnershipStore)
        switch route.outcome {
        case .handled(.transcript):
            return transcriptNotificationName(for: intent)
        case .handled(.notificationBubble(_)):
            return notificationScrollName(for: intent)
        default:
            return nil
        }
    }

    private static func transcriptNotificationName(for intent: KeyboardCommandIntent) -> Notification.Name? {
        switch intent {
        case .focusPromptInput:
            return .clawlineFocusPromptInputCommand
        case .openStreamPopup:
            return .clawlineOpenStreamPopupCommand
        case .navigatePreviousStream:
            return .clawlineNavigateToPreviousStreamCommand
        case .navigateNextStream:
            return .clawlineNavigateToNextStreamCommand
        case .transcriptBubbleScrollForward:
            return .clawlineScrollDownCommand
        case .transcriptBubbleScrollBackward:
            return .clawlineScrollUpCommand
        case .transcriptChatScrollForward:
            return .clawlineScrollChatDownCommand
        case .transcriptChatScrollBackward:
            return .clawlineScrollChatUpCommand
        default:
            return nil
        }
    }

    private static func notificationScrollName(for intent: KeyboardCommandIntent) -> Notification.Name? {
        switch intent {
        case .transcriptBubbleScrollForward, .transcriptChatScrollForward:
            return .clawlineScrollNotificationDownCommand
        case .transcriptBubbleScrollBackward, .transcriptChatScrollBackward:
            return .clawlineScrollNotificationUpCommand
        default:
            return nil
        }
    }
}

extension UIResponder {
    @objc func clawlineFocusPromptInputCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineOpenStreamPopupCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineNavigateToPreviousStreamCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineNavigateToNextStreamCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineScrollDownCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineScrollUpCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineScrollChatDownCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineScrollChatUpCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandBridge.intent(input: sender.input, modifierFlags: sender.modifierFlags))
    }

    @objc func clawlineScrollNotificationDownCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandIntent.notificationScrollForward)
    }

    @objc func clawlineScrollNotificationUpCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: KeyboardCommandIntent.notificationScrollBackward)
    }

    @objc func clawlineNotificationNumberCommand(_ sender: UIKeyCommand) {
        guard let intent = KeyboardCommandBridge.intent(
            input: sender.input,
            modifierFlags: sender.modifierFlags
        ) else { return }
        NotificationCenter.default.post(name: .clawlineKeyboardCommandIntent, object: intent)
    }
}

enum ChatKeyboardNavigation {
    static func targetSessionKey(
        sessionKeys: [String],
        currentSessionKey: String?,
        step: Int
    ) -> String? {
        guard !sessionKeys.isEmpty, step != 0 else { return nil }
        guard let currentSessionKey,
              let currentIndex = sessionKeys.firstIndex(of: currentSessionKey) else {
            return sessionKeys.first
        }
        let targetIndex = min(sessionKeys.count - 1, max(0, currentIndex + step))
        guard targetIndex != currentIndex else { return nil }
        return sessionKeys[targetIndex]
    }
}

enum PromptFocusShortcutActivation {
    enum Action: Equatable {
        case activate
        case retryAfterTextInputResigns
        case skip
    }

    static func action(
        isShortcutEnabled: Bool,
        isAlreadyFirstResponder: Bool,
        currentFirstResponderIsTextInput: Bool,
        currentFirstResponderOwnsEmbeddedScroll: Bool,
        canRetryAfterTextInput: Bool
    ) -> Action {
        guard isShortcutEnabled, !isAlreadyFirstResponder else { return .skip }
        guard !currentFirstResponderOwnsEmbeddedScroll else { return .skip }
        guard !currentFirstResponderIsTextInput else {
            return canRetryAfterTextInput ? .retryAfterTextInputResigns : .skip
        }
        return .activate
    }
}

private extension UIResponder {
    static weak var clawlineCurrentFirstResponder: UIResponder?

    var isClawlineTextInputResponder: Bool {
        self is UITextInput
    }

    var ownsClawlineEmbeddedScrollInput: Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if current is WKWebView {
                return true
            }
            responder = current.next
        }
        return false
    }

    @objc func clawlineCaptureFirstResponder(_ sender: Any) {
        UIResponder.clawlineCurrentFirstResponder = self
    }
}

private extension UIWindow {
    var clawlineFirstResponder: UIResponder? {
        UIResponder.clawlineCurrentFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.clawlineCaptureFirstResponder(_:)),
            to: nil,
            from: nil,
            for: nil
        )
        return UIResponder.clawlineCurrentFirstResponder
    }

    static var clawlineCurrentFirstResponderOwnsEmbeddedScroll: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.clawlineFirstResponder?.ownsClawlineEmbeddedScrollInput == true }
    }

    static var clawlineCurrentFirstResponderBlocksKeyboardScroll: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { window in
                guard let responder = window.clawlineFirstResponder else { return false }
                return responder.isClawlineTextInputResponder || responder.ownsClawlineEmbeddedScrollInput
            }
    }
}

private struct KeyboardLayoutGuideReader: UIViewRepresentable {
    typealias UIViewType = KeyboardLayoutGuideObserverView

    let refreshToken: Int
    let onChange: (CGFloat, TimeInterval, UIView.AnimationCurve) -> Void

    func makeUIView(context: Context) -> KeyboardLayoutGuideObserverView {
        let view = KeyboardLayoutGuideObserverView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: KeyboardLayoutGuideObserverView, context: Context) {
        uiView.onChange = onChange
        uiView.refreshIfNeededAsync(refreshToken)
    }
}

private final class KeyboardLayoutGuideObserverView: UIView {
    var onChange: ((CGFloat, TimeInterval, UIView.AnimationCurve) -> Void)?
    private var lastHeight: CGFloat = 0
    private var lastDuration: TimeInterval = 0
    private var lastCurve: UIView.AnimationCurve = .easeInOut
    private var lastRefreshToken: Int = 0
    private var needsForegroundRefresh: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForeground(_:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refreshIfNeededAsync(_ token: Int) {
        guard token != lastRefreshToken else { return }
        lastRefreshToken = token
        DispatchQueue.main.async { [weak self] in
            self?.refreshFromLayoutGuide()
        }
    }

    private func refreshFromLayoutGuide() {
        guard let window else {
            // When returning from another app, notifications can arrive before the view is attached.
            // Retry on the next tick once a window exists.
            DispatchQueue.main.async { [weak self] in
                self?.refreshFromLayoutGuide()
            }
            return
        }
        window.layoutIfNeeded()
        layoutIfNeeded()
        let guideFrame = keyboardLayoutGuide.layoutFrame
        let frameInWindow = convert(guideFrame, to: window)
        let windowBounds = window.bounds
        let result = heightFromFrame(frameInWindow, windowBounds: windowBounds)
        let height = result.height
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
        }
        onChange?(height, lastDuration, lastCurve)
    }

    private func heightFromFrame(
        _ frameInWindow: CGRect,
        windowBounds: CGRect
    ) -> (height: CGFloat, isFloating: Bool) {
        let widthDelta = windowBounds.width - frameInWindow.width
        let isFloating = widthDelta > 1
            || frameInWindow.minX > 1
            || frameInWindow.maxX < windowBounds.maxX - 1
        let height: CGFloat
        if isFloating {
            height = 0
        } else {
            height = max(0, windowBounds.maxY - frameInWindow.minY)
        }
        return (height, isFloating)
    }

    @objc private func willEnterForeground(_ notification: Notification) {
        // #24: Keyboard notifications aren't guaranteed when returning to foreground with the keyboard already up.
        // Schedule one foreground refresh after layout settles.
        scheduleForegroundRefresh()
    }

    @objc private func didBecomeActive(_ notification: Notification) {
        // #12200: Keyboard can be dismissed while we're backgrounded (e.g. web form in Safari/WebView).
        // Ensure we re-sample from `keyboardLayoutGuide` after activation, not just on keyboard notifications.
        scheduleForegroundRefresh()
    }

    private func scheduleForegroundRefresh() {
        guard !needsForegroundRefresh else { return }
        needsForegroundRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needsForegroundRefresh = false
            self.refreshFromLayoutGuide()
        }
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.3
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut
#if os(visionOS)
        let screenHeight = window?.bounds.height ?? endFrame.maxY
        let height = max(0, screenHeight - endFrame.origin.y)
#else
        let height: CGFloat
        if let window {
            let frameInWindow = window.convert(endFrame, from: nil)
            let windowBounds = window.bounds
            let result = heightFromFrame(frameInWindow, windowBounds: windowBounds)
            height = result.height
        } else {
            let screenHeight = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
                .first ?? endFrame.maxY
            height = max(0, screenHeight - endFrame.origin.y)
        }
#endif
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
        }
        if abs(duration - lastDuration) > 0.001 {
            lastDuration = duration
        }
        if curve != lastCurve {
            lastCurve = curve
        }
        onChange?(height, duration, curve)
    }
}

private struct KeyboardPinnedContainer<Content: View>: UIViewRepresentable {
    typealias UIViewType = KeyboardPinnedContainerView<Content>

    let desiredBottomGap: CGFloat
    let isKeyboardVisible: Bool
    @Binding var measuredHeight: CGFloat
    let versionText: AttributedString?
    let layoutCoordinator: ChatLayoutCoordinator
    let layoutKey: ChatLayoutKey
    let scrollButtonView: AnyView?
    let scrollButtonIsVisible: Bool
    let scrollButtonGap: CGFloat
    let scrollButtonHorizontalOffset: CGFloat
    let scrollButtonMaxHorizontalOffset: CGFloat
    let scrollButtonHorizontalSettleStartOffset: CGFloat?
    let scrollButtonHorizontalAnimationToken: Int
    let onScrollButtonPanEnded: ((CGFloat, CGFloat) -> Void)?
    let pageDotsView: AnyView?
    let pageDotsGap: CGFloat
    let content: Content

    init(
        desiredBottomGap: CGFloat,
        isKeyboardVisible: Bool,
        measuredHeight: Binding<CGFloat>,
        versionText: AttributedString? = nil,
        layoutCoordinator: ChatLayoutCoordinator,
        layoutKey: ChatLayoutKey,
        scrollButtonView: AnyView? = nil,
        scrollButtonIsVisible: Bool = false,
        scrollButtonGap: CGFloat = 0,
        scrollButtonHorizontalOffset: CGFloat = 0,
        scrollButtonMaxHorizontalOffset: CGFloat = 0,
        scrollButtonHorizontalSettleStartOffset: CGFloat? = nil,
        scrollButtonHorizontalAnimationToken: Int = 0,
        onScrollButtonPanEnded: ((CGFloat, CGFloat) -> Void)? = nil,
        pageDotsView: AnyView? = nil,
        pageDotsGap: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.desiredBottomGap = desiredBottomGap
        self.isKeyboardVisible = isKeyboardVisible
        self._measuredHeight = measuredHeight
        self.versionText = versionText
        self.layoutCoordinator = layoutCoordinator
        self.layoutKey = layoutKey
        self.scrollButtonView = scrollButtonView
        self.scrollButtonIsVisible = scrollButtonIsVisible
        self.scrollButtonGap = scrollButtonGap
        self.scrollButtonHorizontalOffset = scrollButtonHorizontalOffset
        self.scrollButtonMaxHorizontalOffset = scrollButtonMaxHorizontalOffset
        self.scrollButtonHorizontalSettleStartOffset = scrollButtonHorizontalSettleStartOffset
        self.scrollButtonHorizontalAnimationToken = scrollButtonHorizontalAnimationToken
        self.onScrollButtonPanEnded = onScrollButtonPanEnded
        self.pageDotsView = pageDotsView
        self.pageDotsGap = pageDotsGap
        self.content = content()
    }

    func makeUIView(context: Context) -> KeyboardPinnedContainerView<Content> {
        let container = KeyboardPinnedContainerView(rootView: content, versionText: versionText)
        return container
    }

    func updateUIView(_ uiView: KeyboardPinnedContainerView<Content>, context: Context) {
        uiView.hostingController.rootView = content
        uiView.updateVersionText(versionText)
        uiView.updateScrollButton(
            scrollButtonView,
            isVisible: scrollButtonIsVisible,
            gap: scrollButtonGap,
            horizontalOffset: scrollButtonHorizontalOffset,
            maxHorizontalOffset: scrollButtonMaxHorizontalOffset,
            horizontalSettleStartOffset: scrollButtonHorizontalSettleStartOffset,
            horizontalAnimationToken: scrollButtonHorizontalAnimationToken
        )
        uiView.setOnScrollButtonPanEnded(onScrollButtonPanEnded)
        uiView.updatePageDots(pageDotsView, gap: pageDotsGap)
        // Seed the pinned gap immediately on every SwiftUI update so launch layout matches the
        // steady-state hidden-keyboard position even before coordinator-driven transitions fire.
        if uiView.updateDesiredBottomGapIfNeeded(desiredBottomGap, isKeyboardVisible: isKeyboardVisible) {
            uiView.layoutIfNeeded()
        }
        uiView.setOnBarHeightChange { [weak layoutCoordinator] height in
            // Break potential SwiftUI layout cycles by only propagating meaningful bar height changes.
            // (On some iOS 26.2 devices we observed AttributeGraph "cycle detected" during launch.)
            let snapped = (height * 2).rounded() / 2  // half-point granularity
            if abs(measuredHeight - snapped) > 1.0 {
                DispatchQueue.main.async {
                    _measuredHeight.wrappedValue = snapped
                }
                layoutCoordinator?.updateBarHeight(snapped)
            } else if measuredHeight <= 0.5, snapped > 0.5 {
                // First non-zero measurement after mount: always inform coordinator.
                layoutCoordinator?.updateBarHeight(snapped)
            }
        }
        layoutCoordinator.registerBarView(uiView)
        layoutCoordinator.applyTransitionIfPossible(reason: "KeyboardPinnedContainer.updateUIView")
        _ = layoutKey
    }
}

enum KeyboardPinnedHitTesting {
    @MainActor
    static func contains(
        _ point: CGPoint,
        in candidate: UIView,
        from container: UIView,
        event: UIEvent?
    ) -> Bool {
        guard !candidate.isHidden, candidate.isUserInteractionEnabled, candidate.alpha > 0.01 else { return false }

        let pointInCandidate = container.convert(point, to: candidate)
        if candidate.hitTest(pointInCandidate, with: event) != nil {
            return true
        }
        if candidate.point(inside: pointInCandidate, with: event) {
            return true
        }
        if let presentationFrame = candidate.layer.presentation()?.frame,
           presentationFrame.contains(point) {
            return true
        }
        return false
    }
}

enum KeyboardPinnedChromeEventRouting {
    static func scrollButtonHostReceivesEvents(hasView: Bool, isVisible: Bool) -> Bool {
        hasView && isVisible
    }

    static func scrollButtonHostIsHidden(hasView: Bool, isVisible: Bool) -> Bool {
        !hasView || !isVisible
    }
}

private final class KeyboardPinnedContainerView<Content: View>: UIView, KeyboardPinnedContainerViewProtocol {
    let hostingController: UIHostingController<Content>
    let versionLabel: UILabel
    private var scrollButtonHost: UIHostingController<AnyView>?
    private var scrollButtonPanGestureRecognizer: UIPanGestureRecognizer?
    private var scrollButtonBottomToBarTop: NSLayoutConstraint?
    private var scrollButtonCenterX: NSLayoutConstraint?
    private var lastScrollButtonHorizontalAnimationToken: Int = 0
    private var scrollButtonBaseHorizontalOffset: CGFloat = 0
    private var scrollButtonMaxHorizontalOffset: CGFloat = 0
    private var scrollButtonLiveTranslation: CGFloat = 0
    private var scrollButtonIsPanning = false
    private var onScrollButtonPanEnded: ((CGFloat, CGFloat) -> Void)?
    private var pageDotsHost: UIHostingController<AnyView>?
    private var pageDotsBottomToBarTop: NSLayoutConstraint?
    private var minHeightConstraint: NSLayoutConstraint?
    private var hostingBottomToKeyboard: NSLayoutConstraint?
    private var hostingBottomToContainer: NSLayoutConstraint?
    private var versionLabelBottomToKeyboard: NSLayoutConstraint?
    private var versionLabelBottomToContainer: NSLayoutConstraint?
    private var onBarHeightChange: ((CGFloat) -> Void)?
    private var lastMeasuredHeight: CGFloat = 0
    private var lastDesiredBottomGap: CGFloat?
    private var lastPinnedKeyboardVisible: Bool?

    init(rootView: Content, versionText: AttributedString?) {
        hostingController = UIHostingController(rootView: rootView)
        versionLabel = UILabel()
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        if #available(iOS 16.0, visionOS 1.0, *) {
            hostingController.sizingOptions = [.intrinsicContentSize]
            hostingController.safeAreaRegions = []
        }
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false

        versionLabel.font = .preferredFont(forTextStyle: .caption2)
        versionLabel.textColor = .secondaryLabel
        versionLabel.textAlignment = .right
        if let versionText {
            versionLabel.attributedText = NSAttributedString(versionText)
        }
        versionLabel.isHidden = versionText == nil

#if !os(visionOS)
        // When keyboard is hidden the layout guide defaults to the safe-area
        // bottom, which already accounts for the home indicator. Setting this
        // to false makes the guide collapse to the view's own bottom edge so
        // desiredBottomGap is measured from the physical screen edge (needed
        // for concentric alignment with device corners).
        keyboardLayoutGuide.usesBottomSafeArea = false
#endif
    }

    var containerView: UIView { self }

    var barHeight: CGFloat {
        hostingController.view?.bounds.height ?? 0
    }

    func setOnBarHeightChange(_ handler: @escaping (CGFloat) -> Void) {
        onBarHeightChange = handler
    }

    func updateVersionText(_ text: AttributedString?) {
        if let text {
            versionLabel.attributedText = NSAttributedString(text)
        } else {
            versionLabel.attributedText = nil
        }
        // Only hide for nil text; keyboard-driven hiding is handled by the coordinator
        if text == nil {
            versionLabel.isHidden = true
        }
    }

    func updateScrollButton(
        _ view: AnyView?,
        isVisible: Bool,
        gap: CGFloat,
        horizontalOffset: CGFloat,
        maxHorizontalOffset: CGFloat,
        horizontalSettleStartOffset: CGFloat?,
        horizontalAnimationToken: Int
    ) {
#if os(visionOS)
        _ = view
        _ = isVisible
        _ = gap
        _ = horizontalOffset
        _ = maxHorizontalOffset
        _ = horizontalSettleStartOffset
        _ = horizontalAnimationToken
        return
#else
        // Ensure the bar view is mounted so we can anchor the scroll button above it.
        ensureConstraints(desiredBottomGap: 0)
        guard let hostingView = hostingController.view else { return }

        if scrollButtonHost == nil {
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host.view)
            scrollButtonHost = host

            let bottom = host.view.bottomAnchor.constraint(equalTo: hostingView.topAnchor, constant: -gap)
            let centerX = host.view.centerXAnchor.constraint(equalTo: centerXAnchor, constant: horizontalOffset)
            scrollButtonBottomToBarTop = bottom
            scrollButtonCenterX = centerX
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollButtonPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            host.view.addGestureRecognizer(pan)
            scrollButtonPanGestureRecognizer = pan
            NSLayoutConstraint.activate([
                centerX,
                bottom,
            ])
        }

        scrollButtonBaseHorizontalOffset = horizontalOffset
        scrollButtonMaxHorizontalOffset = maxHorizontalOffset
        scrollButtonHost?.rootView = view ?? AnyView(EmptyView())
        let scrollButtonReceivesEvents = KeyboardPinnedChromeEventRouting.scrollButtonHostReceivesEvents(
            hasView: view != nil,
            isVisible: isVisible
        )
        if !scrollButtonReceivesEvents, scrollButtonIsPanning {
            scrollButtonIsPanning = false
            scrollButtonLiveTranslation = 0
            scrollButtonHost?.view.transform = .identity
        }
        scrollButtonHost?.view.isHidden = KeyboardPinnedChromeEventRouting.scrollButtonHostIsHidden(
            hasView: view != nil,
            isVisible: isVisible
        )
        scrollButtonHost?.view.isUserInteractionEnabled = scrollButtonReceivesEvents
        scrollButtonPanGestureRecognizer?.isEnabled = scrollButtonReceivesEvents
        scrollButtonBottomToBarTop?.constant = -gap
        if scrollButtonIsPanning {
            scrollButtonCenterX?.constant = horizontalOffset
            if scrollButtonHost?.view.transform.tx != scrollButtonLiveTranslation {
                scrollButtonHost?.view.transform = CGAffineTransform(translationX: scrollButtonLiveTranslation, y: 0)
            }
            return
        }
        let shouldAnimateOffset = horizontalAnimationToken != lastScrollButtonHorizontalAnimationToken
        lastScrollButtonHorizontalAnimationToken = horizontalAnimationToken

        if shouldAnimateOffset {
            if let horizontalSettleStartOffset {
                scrollButtonHost?.view.transform = .identity
                scrollButtonCenterX?.constant = horizontalSettleStartOffset
                // Force the spring to start from the drag-release position.
                layoutIfNeeded()
            }
            scrollButtonCenterX?.constant = horizontalOffset
            UIView.animate(
                withDuration: 0.46,
                delay: 0,
                usingSpringWithDamping: 0.68,
                initialSpringVelocity: 0.78,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.layoutIfNeeded()
            }
        } else {
            scrollButtonHost?.view.transform = .identity
            scrollButtonCenterX?.constant = horizontalOffset
            layoutIfNeeded()
        }
#endif
    }

    func setOnScrollButtonPanEnded(_ handler: ((CGFloat, CGFloat) -> Void)?) {
        onScrollButtonPanEnded = handler
    }

    func updatePageDots(_ view: AnyView?, gap: CGFloat) {
#if os(visionOS)
        _ = view
        _ = gap
        return
#else
        // Mount above the input bar so dots track the same runtime anchor as the bar.
        ensureConstraints(desiredBottomGap: 0)
        guard let hostingView = hostingController.view else { return }

        if pageDotsHost == nil {
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            host.view.clipsToBounds = false
            host.view.translatesAutoresizingMaskIntoConstraints = false
            if #available(iOS 16.0, visionOS 1.0, *) {
                // Give the raw UIKit host its real capsule size on first layout so
                // the pinned-container hit test matches the visible pager control.
                host.sizingOptions = [.intrinsicContentSize]
                host.safeAreaRegions = []
            }
            addSubview(host.view)
            pageDotsHost = host

            let bottom = host.view.bottomAnchor.constraint(equalTo: hostingView.topAnchor, constant: -gap)
            pageDotsBottomToBarTop = bottom
            NSLayoutConstraint.activate([
                host.view.centerXAnchor.constraint(equalTo: centerXAnchor),
                bottom,
            ])
        }

        pageDotsHost?.rootView = view ?? AnyView(EmptyView())
        pageDotsHost?.view.isHidden = (view == nil)
        pageDotsHost?.view.isUserInteractionEnabled = (view != nil)
        pageDotsBottomToBarTop?.constant = -gap
        syncPageDotsHostLayout()
#endif
    }

    private func syncPageDotsHostLayout() {
        guard let pageDotsView = pageDotsHost?.view else { return }
        pageDotsView.invalidateIntrinsicContentSize()
        pageDotsView.setNeedsLayout()
        setNeedsLayout()
        layoutIfNeeded()
    }

    func setDesiredBottomGap(_ gap: CGFloat, isKeyboardVisible: Bool) {
        ensureConstraints(desiredBottomGap: gap)
#if os(visionOS)
        hostingBottomToContainer?.constant = -gap
#else
        hostingBottomToKeyboard?.constant = -gap
        hostingBottomToContainer?.constant = -gap
        // `keyboardLayoutGuide` can report a stale non-zero frame on cold launch.
        // Stay pinned to the container bottom until we know the keyboard is truly visible.
        hostingBottomToKeyboard?.isActive = isKeyboardVisible
        hostingBottomToContainer?.isActive = !isKeyboardVisible
        let hasVersionText = versionLabel.attributedText != nil && !versionLabel.attributedText!.string.isEmpty
        versionLabelBottomToKeyboard?.isActive = isKeyboardVisible
        versionLabelBottomToContainer?.isActive = !isKeyboardVisible
        versionLabel.isHidden = isKeyboardVisible || !hasVersionText
#endif
    }

    @discardableResult
    func updateDesiredBottomGapIfNeeded(_ gap: CGFloat, isKeyboardVisible: Bool) -> Bool {
        let gapChanged = lastDesiredBottomGap.map { abs($0 - gap) > 0.5 } ?? true
        let visibilityChanged = lastPinnedKeyboardVisible != isKeyboardVisible
        guard gapChanged || visibilityChanged else { return false }
        lastDesiredBottomGap = gap
        lastPinnedKeyboardVisible = isKeyboardVisible
        setDesiredBottomGap(gap, isKeyboardVisible: isKeyboardVisible)
        return true
    }

#if !os(visionOS)
    @objc
    private func handleScrollButtonPan(_ recognizer: UIPanGestureRecognizer) {
        guard scrollButtonHost?.view.isHidden == false else { return }

        switch recognizer.state {
        case .began, .changed:
            scrollButtonIsPanning = true
            scrollButtonLiveTranslation = clampedScrollButtonTranslation(for: recognizer.translation(in: self).x)
            if scrollButtonHost?.view.transform.tx != scrollButtonLiveTranslation {
                scrollButtonHost?.view.transform = CGAffineTransform(translationX: scrollButtonLiveTranslation, y: 0)
            }
        case .ended, .cancelled, .failed:
            let endTranslation = clampedScrollButtonTranslation(for: recognizer.translation(in: self).x)
            let projectedAdditionalTranslation = projectedScrollButtonTranslation(
                fromVelocity: recognizer.velocity(in: self).x
            )
            let projectedTranslation = clampedScrollButtonTranslation(
                for: recognizer.translation(in: self).x + projectedAdditionalTranslation
            )
            scrollButtonIsPanning = false
            scrollButtonLiveTranslation = endTranslation
            onScrollButtonPanEnded?(endTranslation, projectedTranslation)
        default:
            break
        }
    }

    private func clampedScrollButtonTranslation(for translationX: CGFloat) -> CGFloat {
        let clampedOffset = min(
            max(scrollButtonBaseHorizontalOffset + translationX, -scrollButtonMaxHorizontalOffset),
            scrollButtonMaxHorizontalOffset
        )
        return clampedOffset - scrollButtonBaseHorizontalOffset
    }

    private func projectedScrollButtonTranslation(fromVelocity velocityX: CGFloat) -> CGFloat {
        // Match SwiftUI's flick handoff more closely by projecting the pan velocity
        // through UIKit's standard deceleration curve instead of a fixed-time scale.
        let decelerationRate = UIScrollView.DecelerationRate.normal.rawValue
        return (velocityX / 1000) * decelerationRate / (1 - decelerationRate)
    }
#endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        layoutIfNeeded()
        if let hitView = hostingController.view,
           KeyboardPinnedHitTesting.contains(point, in: hitView, from: self, event: event) {
            return true
        }
        if let scrollButtonHost,
           KeyboardPinnedHitTesting.contains(point, in: scrollButtonHost.view, from: self, event: event) {
            return true
        }
        if let pageDotsHost,
           KeyboardPinnedHitTesting.contains(point, in: pageDotsHost.view, from: self, event: event) {
            return true
        }
        if KeyboardPinnedHitTesting.contains(point, in: versionLabel, from: self, event: event) {
            return true
        }
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = barHeight
        guard abs(height - lastMeasuredHeight) > 0.5 else { return }
        lastMeasuredHeight = height
        onBarHeightChange?(height)
    }

    private func ensureConstraints(desiredBottomGap: CGFloat) {
        guard let hostingView = hostingController.view else { return }
#if os(visionOS)
        if hostingBottomToContainer == nil {
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setContentHuggingPriority(.required, for: .vertical)
            hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
            addSubview(hostingView)

            versionLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(versionLabel)

            let bottomToContainerConstraint = hostingView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -desiredBottomGap
            )
            let topConstraint = hostingView.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor
            )
            topConstraint.priority = .defaultLow

            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                bottomToContainerConstraint,
                topConstraint,
                versionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                versionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                versionLabel.bottomAnchor.constraint(equalTo: hostingView.topAnchor, constant: -4),
            ])
            hostingBottomToContainer = bottomToContainerConstraint
        }
#else
        if minHeightConstraint == nil {
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setContentHuggingPriority(.defaultHigh, for: .vertical)
            hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
            addSubview(hostingView)

            versionLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(versionLabel)

            let minHeight = hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: MessageInputBarMetrics.minInputBarHeight)
            let topConstraint = hostingView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor)
            topConstraint.priority = .defaultLow

            let hostingToKeyboard = hostingView.bottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor,
                constant: -desiredBottomGap
            )
            let hostingToContainer = hostingView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -desiredBottomGap
            )
            hostingToContainer.isActive = false

            let versionToKeyboard = versionLabel.bottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor,
                constant: -4
            )
            let versionToContainer = versionLabel.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -4
            )
            versionToContainer.priority = .defaultLow
            versionToContainer.isActive = false

            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                minHeight,
                topConstraint,
                hostingToKeyboard,
                hostingToContainer,
                versionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                versionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                versionToKeyboard,
                versionToContainer,
            ])

            minHeightConstraint = minHeight
            hostingBottomToKeyboard = hostingToKeyboard
            hostingBottomToContainer = hostingToContainer
            versionLabelBottomToKeyboard = versionToKeyboard
            versionLabelBottomToContainer = versionToContainer
        }
#endif
    }
}

// MARK: - Pager Scroll Observer
// We use a tiny UIKit bridge to detect when the TabView pager is actively moving vs truly settled.
// SwiftUI's page-style TabView does not expose explicit "deceleration ended" hooks.
// This observer emits two high-signal lifecycle events:
// - interaction began
// - scroll settled at rest (not dragging/tracking/decelerating)
private struct StreamPagerScrollObserver: UIViewRepresentable {
    let onInteractionBegan: @MainActor () -> Void
    let onSettledAtRest: @MainActor () -> Void
    let currentSessionKey: @MainActor () -> String

    func makeUIView(context: Context) -> StreamPagerProbeView {
        let view = StreamPagerProbeView()
        view.onInteractionBegan = onInteractionBegan
        view.onSettledAtRest = onSettledAtRest
        view.currentSessionKey = currentSessionKey
        return view
    }

    func updateUIView(_ uiView: StreamPagerProbeView, context: Context) {
        uiView.onInteractionBegan = onInteractionBegan
        uiView.onSettledAtRest = onSettledAtRest
        uiView.currentSessionKey = currentSessionKey
        uiView.attachIfNeeded()
    }
}

private final class StreamPagerProbeView: UIView {
    var onInteractionBegan: (@MainActor () -> Void)?
    var onSettledAtRest: (@MainActor () -> Void)?
    var currentSessionKey: (@MainActor () -> String)?

    private weak var observedPagerScrollView: UIScrollView?
    private var settlePollTimer: Timer?
    private var didEmitInteractionForCurrentGesture = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        settlePollTimer?.invalidate()
        if let pan = observedPagerScrollView?.panGestureRecognizer {
            pan.removeTarget(self, action: #selector(handlePagerPan(_:)))
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard let root = superview else { return }
        guard let pagerScrollView = findPagerScrollView(in: root) else { return }
        guard observedPagerScrollView !== pagerScrollView else { return }

        // If SwiftUI re-parents/recreates the page stack, detach old observer before reattaching.
        if let oldPan = observedPagerScrollView?.panGestureRecognizer {
            oldPan.removeTarget(self, action: #selector(handlePagerPan(_:)))
        }
        observedPagerScrollView = pagerScrollView
        pagerScrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePagerPan(_:)))
    }

    @objc
    private func handlePagerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            // Emit once per gesture to avoid noisy state churn while finger moves.
            if !didEmitInteractionForCurrentGesture {
                didEmitInteractionForCurrentGesture = true
                StreamSwitchTiming.markGestureBegan(sessionKey: currentSessionKey?())
                onInteractionBegan?()
            }
            settlePollTimer?.invalidate()
            settlePollTimer = nil
        case .ended, .cancelled, .failed:
            StreamSwitchTiming.log("pan_gesture_ended", sessionKey: currentSessionKey?())
            didEmitInteractionForCurrentGesture = false
            startSettlePolling()
        default:
            break
        }
    }

    private func startSettlePolling() {
        settlePollTimer?.invalidate()
        // Polling is intentionally scoped to the post-gesture window.
        // We are not doing continuous per-frame work outside gesture completion.
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self, let scrollView = self.observedPagerScrollView else {
                timer.invalidate()
                return
            }
            let isAtRest = !scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating
            guard isAtRest else { return }
            timer.invalidate()
            self.settlePollTimer = nil
            self.onSettledAtRest?()
        }
        settlePollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // The pager scroll view is the paging-enabled ancestor/descendant around TabView(.page).
    // Message lists are UICollectionViews and are not paging-enabled, so this selector is precise enough.
    private func findPagerScrollView(in root: UIView) -> UIScrollView? {
        if let scrollView = root as? UIScrollView,
           scrollView.isPagingEnabled {
            return scrollView
        }
        for child in root.subviews {
            if let match = findPagerScrollView(in: child) {
                return match
            }
        }
        return nil
    }
}

private struct StreamSwitcherHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct InputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CrossChatNotificationEntriesHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


// MARK: - Previews

private struct PreviewDevice: DeviceIdentifying {
    let deviceId = "preview-device"
}

private final class PreviewChatService: ChatServicing {
    var incomingMessages: AsyncStream<Message> {
        AsyncStream { _ in }
    }
    var connectionState: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }
    var serviceEvents: AsyncStream<ChatServiceEvent> {
        AsyncStream { _ in }
    }
    var lifecycleTransportEvents: AsyncStream<LifecycleTransportEvent> {
        AsyncStream { _ in }
    }
    var isTransportReadyForSend: Bool { true }
    func connect(token: String, lastMessageId: String?) async throws {}
    func startConnectionAttempt(epoch: Int, lastMessageId: String?, token: String) {}
    func stopConnectionAttempt() {}
    func disconnect() {}
    func replayCursorSnapshot() -> [String: String] { [:] }
    func setReplayCursor(_ cursor: String?, for sessionKey: String) {}
    func seedReplayCursorIfMissing(_ cursor: String?, for sessionKey: String) {}
    func clearReplayCursors() {}
    func send(id: String, content: String, attachments: [WireAttachment], sessionKey: String?) async throws {}
    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) async throws {}
    func publishReadState(sessionKey: String, lastReadMessageId: String) async throws {}
    func fetchStreams() async throws -> [StreamSession] { [] }
    func fetchTrackableSessions() async throws -> [TrackableSession] { [] }
    func fetchSessionStatus(sessionKey: String) async throws -> SessionStatus {
        throw ProviderChatService.Error.notConnected
    }
    func applySessionControl(
        sessionKey: String,
        action: SessionControlAction,
        value: String?,
        enabled: Bool?
    ) async throws -> SessionControlResponse {
        throw ProviderChatService.Error.notConnected
    }
    func adoptStream(sessionKey: String) async throws -> StreamSession {
        StreamSession(
            sessionKey: sessionKey,
            displayName: "Preview Adopted",
            kind: "custom",
            orderIndex: 0,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date(),
            trackingMode: .adopted
        )
    }
    func createStream(displayName: String, idempotencyKey: String) async throws -> StreamSession {
        StreamSession(
            sessionKey: "preview",
            displayName: displayName,
            kind: "custom",
            orderIndex: 0,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
    func renameStream(sessionKey: String, displayName: String) async throws -> StreamSession {
        StreamSession(
            sessionKey: sessionKey,
            displayName: displayName,
            kind: "custom",
            orderIndex: 0,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
    func deleteStream(sessionKey: String, idempotencyKey: String?) async throws -> String { sessionKey }
}

private struct AttachmentSourceSheet: View {
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let rowHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 2
    private let rowHorizontalInset: CGFloat = 12
    private let outerVerticalPadding: CGFloat = 20
    private let popupCornerRadius: CGFloat = 20
    private let minimumPopoverWidth: CGFloat = 280
    private let idealPopoverWidth: CGFloat = 320
    private let maximumPopoverWidth: CGFloat = 360

    private var rowCount: Int {
#if os(visionOS)
        2
#else
        3
#endif
    }

    private var popoverHeight: CGFloat {
        (CGFloat(rowCount) * rowHeight)
            + (CGFloat(max(0, rowCount - 1)) * rowSpacing)
            + (outerVerticalPadding * 2)
    }

    private var effectiveColorScheme: ColorScheme { colorScheme }
    var body: some View {
        VStack(spacing: rowSpacing) {
#if !os(visionOS)
            AttachmentActionButton(
                title: "Camera",
                icon: "camera.fill",
                action: onCamera,
                rowHeight: rowHeight,
                horizontalInset: rowHorizontalInset
            )
#endif

            AttachmentActionButton(
                title: "Photos",
                icon: "photo.on.rectangle",
                action: onPhotos,
                rowHeight: rowHeight,
                horizontalInset: rowHorizontalInset
            )

            AttachmentActionButton(
                title: "Files",
                icon: "doc.fill",
                action: onFiles,
                rowHeight: rowHeight,
                horizontalInset: rowHorizontalInset
            )
        }
        .padding(.vertical, outerVerticalPadding)
        .frame(
            minWidth: minimumPopoverWidth,
            idealWidth: idealPopoverWidth,
            maxWidth: maximumPopoverWidth
        )
        .frame(height: popoverHeight, alignment: .top)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }
}

private struct AttachmentActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    let rowHeight: CGFloat
    let horizontalInset: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false

    private var effectiveColorScheme: ColorScheme { colorScheme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(ChatFlowTheme.sage(effectiveColorScheme))
                    .frame(width: 24)

                Text(title)
                    .font(.clawline(.subsectionHeader).weight(.regular))
                    .foregroundStyle(ChatFlowTheme.warmBrown(effectiveColorScheme))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.clawline(.uiLabel).weight(.semibold))
                    .foregroundStyle(ChatFlowTheme.warmBrown(effectiveColorScheme).opacity(0.4))
            }
            .padding(.horizontal, horizontalInset)
            .frame(height: rowHeight, alignment: .center)
            .background(rowBackground)
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(isPressed ? (effectiveColorScheme == .dark ? 0.10 : 0.06) : 0))
    }
}

private struct CrossChatMentionPickerView: View {
    @Environment(\.colorScheme) private var colorScheme

    let streams: [StreamSession]
    let currentSessionKey: String
    let dotStatesBySession: [String: StreamDotState]
    let highlightedSessionKey: String?
    let isVisible: Bool
    let onSelect: (StreamSession) -> Void

    private let rowHeight: CGFloat = 38
    private let rowSpacing: CGFloat = 4
    private let visibleRowLimit = 6
    private let chromePadding: CGFloat = 6

    private var maxListHeight: CGFloat {
        let visibleRows = max(1, min(visibleRowLimit, max(streams.count, 1)))
        let rowTotal = CGFloat(visibleRows) * rowHeight
        let spacingTotal = CGFloat(max(0, visibleRows - 1)) * rowSpacing
        return rowTotal + spacingTotal
    }

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: rowSpacing) {
                if streams.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.clawline(.secondaryLabel).weight(.semibold))
                            .frame(width: 18)
                        Text("No matching chats")
                            .font(.clawline(.uiLabel))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: rowHeight)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: rowSpacing) {
                                ForEach(streams, id: \.sessionKey) { stream in
                                    Button(action: { onSelect(stream) }) {
                                        HStack(spacing: 10) {
#if os(visionOS)
                                            statusDot(for: stream)
#else
                                            Image(systemName: "bubble.left.and.bubble.right")
                                                .font(.clawline(.secondaryLabel).weight(.semibold))
                                                .frame(width: 18)
#endif
                                            Text(stream.displayName)
                                                .font(.clawline(.uiLabel))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Spacer(minLength: 8)
                                        }
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 12)
                                        .frame(height: rowHeight)
                                        .background(rowBackground(for: stream))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Mention \(stream.displayName)")
                                    .id(stream.sessionKey)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: maxListHeight)
                        .clipShape(Rectangle())
                        .onChange(of: highlightedSessionKey) { _, highlighted in
                            guard let highlighted else { return }
                            withAnimation(.easeInOut(duration: 0.16)) {
                                proxy.scrollTo(highlighted, anchor: .center)
                            }
                        }
                    }
                }
            }
            .padding(chromePadding)
            .frame(maxWidth: 390)
            .modifier(CrossChatMentionPickerChrome())
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func rowBackground(for stream: StreamSession) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(stream.sessionKey == highlightedSessionKey ? Color.primary.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func statusDot(for stream: StreamSession) -> some View {
        let isCurrent = stream.sessionKey == currentSessionKey
        let dotState = dotStatesBySession[stream.sessionKey] ?? .inactive
        Circle()
            .fill(
                StreamDotColor.resolve(
                    isActive: isCurrent,
                    dotState: dotState,
                    colorScheme: colorScheme
                )
            )
            .frame(width: 8, height: 8)
            .frame(width: 18)
            .shadow(
                color: isCurrent ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                radius: isCurrent ? StreamDotColor.activeOuterGlowRadius(colorScheme: colorScheme) : 0
            )
            .shadow(
                color: isCurrent ? StreamDotColor.activeGlow(colorScheme: colorScheme) : .clear,
                radius: isCurrent ? StreamDotColor.activeInnerGlowRadius(colorScheme: colorScheme) : 0
            )
    }
}

private struct CrossChatMentionPickerChrome: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    func body(content: Content) -> some View {
#if os(visionOS)
        content
            .glassBackgroundEffect(in: shape)
#else
        content
            .glassEffect(.regular, in: shape)
#endif
    }
}

private enum CrossChatNotificationMotion {
    static let duration: TimeInterval = 0.30
    static let reveal = Animation.easeOut(duration: duration)
    static let hide = Animation.easeIn(duration: duration)
    static let resize = Animation.easeInOut(duration: duration)
}

enum CrossChatNotificationMarkdownRenderer {
    private static let metrics = ChatFlowTheme.Metrics(isCompact: true)

    static func renderBlocks(
        content: String,
        messageID: String,
        baseFont: UIFont,
        inkColor: UIColor,
        lineSpacing: CGFloat,
        isDark: Bool
    ) -> [RenderedMarkdownBlock] {
        let markdown = content.isEmpty ? "Assistant reply" : content
        let plan = UnifiedMarkdownParser.parse(
            markdown: markdown,
            messageID: messageID,
            metrics: metrics
        )
        let rendered = UnifiedMarkdownRenderer.render(
            plan: plan,
            baseFont: baseFont,
            inkColor: inkColor,
            lineSpacing: lineSpacing,
            stripDetectedURLs: false,
            role: .assistant,
            isDark: isDark
        )
        guard !rendered.isEmpty else {
            let attributed = UnifiedMarkdownRenderer.renderNSAttributedString(
                markdown: markdown,
                baseFont: baseFont,
                inkColor: inkColor,
                lineSpacing: lineSpacing
            ) ?? NSAttributedString(
                string: markdown,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: inkColor
                ]
            )
            return [.attributedText(attributed)]
        }
        return rendered
    }
}

enum CrossChatNotificationGeometry {
    static func layoutHostWidth(maxContainerWidth: CGFloat) -> CGFloat {
        max(0, maxContainerWidth)
    }

    static func isFullyInsideViewport(
        minX: CGFloat,
        maxX: CGFloat,
        viewportWidth: CGFloat,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        minX >= -tolerance && maxX <= viewportWidth + tolerance
    }
}

private struct CrossChatNotificationOverlay: View {
    @Bindable var viewModel: ChatViewModel
    let topMargin: CGFloat
    let maxContainerHeight: CGFloat
    let maxContainerWidth: CGFloat
    let normalTrailingMargin: CGFloat
    let compactLeadingFitMargin: CGFloat
    @Binding var isCollapsed: Bool
    @Binding var replyPinSlotsBySourceChatId: [String: Int]
    @Binding var measuredBubbleHeightsBySourceChatId: [String: CGFloat]
    @Binding var actionMenuSourceChatId: String?
    @Binding var focusedSourceChatId: String?
    @Binding var focusedReplySourceChatId: String?
    var keyboardOwnershipStore = KeyboardOwnershipStore()
    let onNavigateToSource: (String) -> Void
    @State private var showShortcutLabels = CrossChatShortcutLabelAvailability.current
    @State private var actionMenuSelection: CrossChatNotificationActionMenuItem = .goToChat
    @State private var scrollViewsBySourceChatId: [String: WeakScrollViewBox] = [:]
    @State private var previewingCollapsedSourceChatIds: Set<String> = []
    @State private var collapsedPreviewTasksBySourceChatId: [String: Task<Void, Never>] = [:]
    @State private var bubbleDragOffsetsBySourceChatId: [String: CGFloat] = [:]
    @State private var dismissSwipeActiveSourceChatIds: Set<String> = []
    @State private var gestureAxisLocksBySourceChatId: [String: CrossChatNotificationGestureAxisLock] = [:]
    @FocusState private var isActionMenuFocused: Bool

    private static let maxVisibleBubbleCount = 10
    static let minimumStackWidth: CGFloat = 280
    static let minVisibleBubbleHeight: CGFloat = 104
    private static let minReplyBubbleHeight: CGFloat = 104
    private static let maxBubbleHeight: CGFloat = 164
    private static let bubbleSpacing: CGFloat = 10
    private static let maxStackWidth: CGFloat = 562.5
    private static let bubbleCornerRadius: CGFloat = 18
    private static let collapsedPeekWidth: CGFloat = bubbleCornerRadius
    private static let collapseSwipeThreshold: CGFloat = 44
    private static let dragPliabilityLimit: CGFloat = 82
    // Drag is rubber-banded to `dragPliabilityLimit`; the rest covers card corner,
    // dismiss blur, shadow/material halo, and pixel rounding outside the bubble frame.
    static let motionOverflowBleed: CGFloat = dragPliabilityLimit
        + bubbleCornerRadius
        + MessageInputBar.sendButtonColoredBackingBlurRadius
        + 24
    static let revealAnimation = CrossChatNotificationMotion.reveal
    static let hideAnimation = CrossChatNotificationMotion.hide
    static let resizeAnimation = CrossChatNotificationMotion.resize
    private static let notificationTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing)
            .combined(with: .opacity)
            .animation(revealAnimation),
        removal: .move(edge: .trailing)
            .combined(with: .opacity)
            .animation(hideAnimation)
    )

    static func visibleCapacity(maxContainerHeight: CGFloat) -> Int {
        let slotHeight = minVisibleBubbleHeight + bubbleSpacing
        let capacity = Int((maxContainerHeight + bubbleSpacing) / slotHeight)
        return max(1, min(maxVisibleBubbleCount, capacity))
    }

    static func motionContainerHeight(maxContainerHeight: CGFloat) -> CGFloat {
        maxContainerHeight + motionOverflowBleed
    }

    static func overlayHostHeight(topMargin: CGFloat, maxContainerHeight: CGFloat) -> CGFloat {
        topMargin + motionContainerHeight(maxContainerHeight: maxContainerHeight) + 12
    }

    static func visibleCapacity(
        maxContainerHeight: CGFloat,
        bubbles: [CrossChatNotificationBubble],
        measuredHeightsBySourceChatId: [String: CGFloat] = [:]
    ) -> Int {
        guard !bubbles.isEmpty else { return 1 }
        var usedHeight: CGFloat = 0
        var capacity = 0
        for bubble in bubbles.prefix(maxVisibleBubbleCount) {
            let nextHeight = measuredHeightsBySourceChatId[bubble.sourceChatId]
                ?? estimatedUnmeasuredHeight(for: bubble)
            let nextUsedHeight = usedHeight
                + nextHeight
                + (capacity == 0 ? 0 : bubbleSpacing)
            guard capacity == 0 || nextUsedHeight <= maxContainerHeight else {
                break
            }
            usedHeight = nextUsedHeight
            capacity += 1
        }
        return max(1, capacity)
    }

    private static func estimatedUnmeasuredHeight(for bubble: CrossChatNotificationBubble) -> CGFloat {
        if bubble.isReplying {
            return minReplyBubbleHeight
        }
        return minVisibleBubbleHeight
    }

    static func visibleBubbles(
        maxContainerHeight: CGFloat,
        bubbles: [CrossChatNotificationBubble],
        replyPinSlotsBySourceChatId: [String: Int] = [:],
        measuredHeightsBySourceChatId: [String: CGFloat] = [:]
    ) -> [CrossChatNotificationBubble] {
        let capacity = visibleCapacity(
            maxContainerHeight: maxContainerHeight,
            bubbles: bubbles,
            measuredHeightsBySourceChatId: measuredHeightsBySourceChatId
        )
        let orderedBubbles = applyReplyPins(
            to: bubbles,
            replyPinSlotsBySourceChatId: replyPinSlotsBySourceChatId,
            visibleCapacity: capacity
        )
        return selectVisibleBubblesWithPinnedReplies(
            orderedBubbles,
            visibleCapacity: capacity
        )
    }

    private var visibleBubbles: [CrossChatNotificationBubble] {
        Self.visibleBubbles(
            maxContainerHeight: maxContainerHeight,
            bubbles: viewModel.crossChatNotificationBubbles,
            replyPinSlotsBySourceChatId: replyPinSlotsBySourceChatId,
            measuredHeightsBySourceChatId: measuredBubbleHeightsBySourceChatId
        )
    }

    private var orderedBubbles: [CrossChatNotificationBubble] {
        Self.applyReplyPins(
            to: viewModel.crossChatNotificationBubbles,
            replyPinSlotsBySourceChatId: replyPinSlotsBySourceChatId,
            visibleCapacity: Self.visibleCapacity(maxContainerHeight: maxContainerHeight)
        )
    }

    private var visibleCapacity: Int {
        visibleBubbles.count
    }

    private var maxBubbleHeight: CGFloat {
        Self.maxBubbleHeight
    }

    private var stackWidth: CGFloat {
        let externalHorizontalMargin = isCollapsed
            ? 0
            : normalTrailingMargin + compactLeadingFitMargin
        return min(Self.maxStackWidth, max(0, maxContainerWidth - externalHorizontalMargin))
    }

    private var motionContainerWidth: CGFloat {
        stackWidth
            + (Self.motionOverflowBleed * 2)
            + (isCollapsed ? 0 : normalTrailingMargin)
    }

    private var collapsedOffset: CGFloat {
        max(0, stackWidth - Self.collapsedPeekWidth)
    }

    private var visibleBubbleIdentity: [String] {
        visibleBubbles.map { bubble in
            Self.notificationBubbleActivityIdentity(bubble)
        }
    }

    private var visibleSourceChatIds: [String] {
        visibleBubbles.map(\.sourceChatId)
    }

    private var visibleReplySignature: [String] {
        visibleBubbles.map { "\($0.sourceChatId):\($0.isReplying)" }
    }

    private var allBubbleActivitySignaturesBySourceChatId: [String: String] {
        Dictionary(
            uniqueKeysWithValues: viewModel.crossChatNotificationBubbles.map { bubble in
                (bubble.sourceChatId, Self.notificationBubbleActivityIdentity(bubble))
            }
        )
    }

    private var actionMenuBubble: (index: Int, bubble: CrossChatNotificationBubble)? {
        guard let actionMenuSourceChatId,
              let index = visibleBubbles.firstIndex(where: { $0.sourceChatId == actionMenuSourceChatId }) else {
            return nil
        }
        return (index, visibleBubbles[index])
    }

    private var hasActiveReply: Bool {
        viewModel.crossChatNotificationBubbles.contains { $0.isReplying }
    }

    var body: some View {
        if !visibleBubbles.isEmpty {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .frame(
                        width: motionContainerWidth,
                        height: Self.overlayHostHeight(
                            topMargin: topMargin,
                            maxContainerHeight: maxContainerHeight
                        )
                    )
                    .allowsHitTesting(false)

                VStack(alignment: .trailing, spacing: Self.bubbleSpacing) {
                    ForEach(Array(visibleBubbles.enumerated()), id: \.element.sourceChatId) { index, bubble in
                        let isReplySendActive = viewModel.isSendingCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                        let canSendReply = viewModel.canImmediatelySendCrossChatNotificationReply(
                            sourceChatId: bubble.sourceChatId
                        )
                        CrossChatNotificationBubbleView(
                            bubble: bubble,
                            assignedNumber: index,
                            visibleNotificationCount: visibleBubbles.count,
                            showShortcutLabel: showShortcutLabels,
                            maxBubbleHeight: maxBubbleHeight,
                            maxBubbleWidth: stackWidth,
                            bubbleCornerRadius: Self.bubbleCornerRadius,
                            isSending: isReplySendActive,
                            canCancelSend: viewModel.canCancelSend,
                            canSendReply: canSendReply,
                            connectionState: viewModel.sendButtonConnectionState,
                            replyDraft: Binding(
                                get: {
                                    viewModel.crossChatNotificationBubblesBySourceChatId[bubble.sourceChatId]?.replyDraft ?? ""
                                },
                                set: { newValue in
                                    viewModel.setCrossChatNotificationReplyDraft(
                                        sourceChatId: bubble.sourceChatId,
                                        draft: newValue
                                    )
                                }
                            ),
                            onDismiss: {
                                unpinReply(sourceChatId: bubble.sourceChatId)
                                dismissNotification(sourceChatId: bubble.sourceChatId)
                            },
                            onReply: {
                                animateNotificationResize {
                                    if bubble.isReplying {
                                        unpinReply(sourceChatId: bubble.sourceChatId)
                                        clearReplyFocus(sourceChatId: bubble.sourceChatId)
                                    } else {
                                        pinReply(sourceChatId: bubble.sourceChatId)
                                    }
                                    viewModel.toggleCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                                }
                            },
                            onCancelReply: {
                                animateNotificationResize {
                                    unpinReply(sourceChatId: bubble.sourceChatId)
                                    clearReplyFocus(sourceChatId: bubble.sourceChatId)
                                    viewModel.closeCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                                }
                            },
                            onDismissAll: {
                                dismissAllNotifications()
                            },
                            onNavigate: {
                                closeActionMenu()
                                unpinReply(sourceChatId: bubble.sourceChatId)
                                clearReplyFocus(sourceChatId: bubble.sourceChatId)
                                onNavigateToSource(bubble.sourceChatId)
                            },
                            onSendReply: {
                                viewModel.sendCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                            },
                            onCancelSend: {
                                if isReplySendActive {
                                    viewModel.cancelSend()
                                }
                            },
                            onReconnect: {
                                viewModel.reconnect()
                            },
                            onActivate: {
                                focusedSourceChatId = bubble.sourceChatId
                            },
                            onReplyFocusChange: { isFocused in
                                if isFocused {
                                    focusedReplySourceChatId = bubble.sourceChatId
                                } else {
                                    clearReplyFocus(sourceChatId: bubble.sourceChatId)
                                }
                            },
                            isActionMenuOpen: actionMenuSourceChatId == bubble.sourceChatId,
                            actionMenuSelection: actionMenuSelection,
                            keyboardOwnershipStore: keyboardOwnershipStore,
                            onActionMenuSelectionChange: { selection in
                                actionMenuSelection = selection
                            },
                            onActionMenuAction: { item in
                                handleActionMenuAction(item, bubble: bubble)
                            },
                            onRegisterScrollView: { scrollView in
                                registerScrollView(sourceChatId: bubble.sourceChatId, scrollView: scrollView)
                            },
                            isDismissSwipeActive: dismissSwipeActiveSourceChatIds.contains(bubble.sourceChatId),
                            isContentScrollLocked: gestureAxisLocksBySourceChatId[bubble.sourceChatId] == .horizontalSwipe,
                            onContentScrollDragChanged: { translation in
                                handleNotificationContentDragChanged(translation, sourceChatId: bubble.sourceChatId)
                            },
                            onContentScrollDragEnded: {
                                handleNotificationContentDragEnded(sourceChatId: bubble.sourceChatId)
                            }
                        )
                        .offset(x: horizontalOffset(for: bubble) + (bubbleDragOffsetsBySourceChatId[bubble.sourceChatId] ?? 0))
                        .transition(Self.notificationTransition)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: CrossChatNotificationGestureAxisLock.minimumDistance)
                                .onChanged { value in
                                    handleBubbleDragChanged(value, sourceChatId: bubble.sourceChatId)
                                }
                                .onEnded { value in
                                    handleBubbleDrag(value, sourceChatId: bubble.sourceChatId)
                                }
                        )
                        .zIndex(actionMenuSourceChatId == bubble.sourceChatId ? 1 : 0)
                    }
                }
                .padding(.vertical, 2)
                .frame(width: stackWidth, alignment: .topTrailing)
                .frame(maxHeight: maxContainerHeight, alignment: .topTrailing)
                .padding(.top, topMargin)
                .padding(.trailing, (isCollapsed ? 0 : normalTrailingMargin) + Self.motionOverflowBleed)
                .animation(Self.revealAnimation, value: visibleBubbleIdentity)
                .onPreferenceChange(CrossChatNotificationBubbleHeightPreferenceKey.self) { heights in
                    let activeSourceChatIds = Set(viewModel.crossChatNotificationBubbles.map(\.sourceChatId))
                    let next = heights.filter { activeSourceChatIds.contains($0.key) }
                    guard measuredBubbleHeightsBySourceChatId != next else { return }
                    measuredBubbleHeightsBySourceChatId = next
                }
                .overlay(alignment: .top) {
                    actionMenuOverlay()
                }
                .overlay(alignment: .trailing) {
                    if isCollapsed {
                        Button {
                            restoreDock()
                        } label: {
                            Color.clear
                                .frame(width: Self.collapsedPeekWidth)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show notifications")
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded(handlePeekDrag)
                        )
                    }
                }
            }
            .offset(x: Self.motionOverflowBleed)
            .transition(Self.notificationTransition)
            .animation(isCollapsed ? Self.hideAnimation : Self.revealAnimation, value: isCollapsed)
            .onAppear {
                showShortcutLabels = CrossChatShortcutLabelAvailability.current
                viewModel.closeOverflowingCrossChatNotificationReplies(visibleSourceChatIds: Set(visibleBubbles.map(\.sourceChatId)))
                if isCollapsed {
                    startCollapsedPreview(sourceChatIds: visibleBubbles.map(\.sourceChatId))
                }
            }
            .onDisappear {
                clearAllCollapsedPreviews()
                isCollapsed = false
                bubbleDragOffsetsBySourceChatId = [:]
                dismissSwipeActiveSourceChatIds = []
                clearAllGestureAxisLocks()
            }
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(GameController)
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
                showShortcutLabels = CrossChatShortcutLabelAvailability.current
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
                showShortcutLabels = CrossChatShortcutLabelAvailability.current
            }
#endif
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollNotificationDownCommand)) { _ in
                guard let sourceChatId = routedNotificationSourceChatId(for: .notificationScrollForward) else { return }
                scrollNotification(sourceChatId: sourceChatId, direction: .down)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollNotificationUpCommand)) { _ in
                guard let sourceChatId = routedNotificationSourceChatId(for: .notificationScrollBackward) else { return }
                scrollNotification(sourceChatId: sourceChatId, direction: .up)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineToggleNotificationDockCommand)) { _ in
                guard routedNotificationSourceChatId(for: .notificationToggleDock) != nil else { return }
                toggleDock()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineOpenNotificationActionMenuCommand)) { notification in
                guard let index = notification.object as? Int,
                      visibleBubbles.indices.contains(index) else { return }
                guard let sourceChatId = routedNotificationSourceChatId(for: .notificationAssignedOpen(index)),
                      visibleBubbles.contains(where: { $0.sourceChatId == sourceChatId }) else { return }
                if isCollapsed {
                    restoreDock()
                }
                actionMenuSelection = .goToChat
                actionMenuSourceChatId = sourceChatId
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineReplyNotificationCommand)) { notification in
                guard let index = notification.object as? Int,
                      visibleBubbles.indices.contains(index) else { return }
                guard let sourceChatId = routedNotificationSourceChatId(for: .notificationAssignedReply(index)),
                      let bubble = visibleBubbles.first(where: { $0.sourceChatId == sourceChatId }) else { return }
                closeActionMenu()
                animateNotificationResize {
                    if bubble.isReplying {
                        unpinReply(sourceChatId: bubble.sourceChatId)
                        clearReplyFocus(sourceChatId: bubble.sourceChatId)
                        viewModel.closeCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                    } else {
                        pinReply(sourceChatId: bubble.sourceChatId)
                        viewModel.openCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineDismissNotificationCommand)) { notification in
                guard let index = notification.object as? Int,
                      visibleBubbles.indices.contains(index) else { return }
                guard let sourceChatId = routedNotificationSourceChatId(for: .notificationAssignedDismiss(index)),
                      visibleBubbles.contains(where: { $0.sourceChatId == sourceChatId }) else { return }
                closeActionMenu()
                unpinReply(sourceChatId: sourceChatId)
                dismissNotification(sourceChatId: sourceChatId)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineKeyboardCommandIntent)) { notification in
                guard let intent = notification.object as? KeyboardCommandIntent else { return }
                handleKeyboardCommandIntent(intent)
            }
            .onChange(of: visibleCapacity) { _, newCapacity in
                viewModel.closeOverflowingCrossChatNotificationReplies(visibleSourceChatIds: Set(visibleBubbles.map(\.sourceChatId)))
            }
            .onChange(of: visibleSourceChatIds) { _, sourceChatIds in
                let sourceChatIdSet = Set(sourceChatIds)
                if let actionMenuSourceChatId, !sourceChatIdSet.contains(actionMenuSourceChatId) {
                    closeActionMenu()
                }
                if let focusedSourceChatId, !sourceChatIdSet.contains(focusedSourceChatId) {
                    self.focusedSourceChatId = nil
                }
                if let focusedReplySourceChatId, !sourceChatIdSet.contains(focusedReplySourceChatId) {
                    self.focusedReplySourceChatId = nil
                }
                pruneGestureAxisLocks(visibleSourceChatIds: sourceChatIdSet)
            }
            .onChange(of: visibleReplySignature) { _, _ in
                closeActionMenuIfSourceIsReplying()
                clearReplyFocusIfClosed()
                updateReplyPins()
            }
            .onChange(of: viewModel.crossChatNotificationBubbles.map { bubble in
                Self.notificationBubbleActivityIdentity(bubble)
            }) { _, _ in
                viewModel.closeOverflowingCrossChatNotificationReplies(visibleSourceChatIds: Set(visibleBubbles.map(\.sourceChatId)))
            }
            .onChange(of: allBubbleActivitySignaturesBySourceChatId) { oldValue, newValue in
                guard isCollapsed else { return }
                let changedSourceChatIds = newValue.compactMap { sourceChatId, signature in
                    oldValue[sourceChatId] == signature ? nil : sourceChatId
                }
                startCollapsedPreview(sourceChatIds: changedSourceChatIds)
            }
        }
    }

    private func horizontalOffset(for bubble: CrossChatNotificationBubble) -> CGFloat {
        guard isCollapsed,
              !previewingCollapsedSourceChatIds.contains(bubble.sourceChatId) else {
            return 0
        }
        return collapsedOffset
    }

    private func rubberBandOffset(for horizontal: CGFloat) -> CGFloat {
        let magnitude = abs(horizontal)
        guard magnitude > 0 else { return 0 }
        let pliableMagnitude = (magnitude * Self.dragPliabilityLimit) / (magnitude + Self.dragPliabilityLimit)
        return horizontal < 0 ? -pliableMagnitude : pliableMagnitude
    }

    static func applyReplyPins(
        to bubbles: [CrossChatNotificationBubble],
        replyPinSlotsBySourceChatId: [String: Int],
        visibleCapacity: Int
    ) -> [CrossChatNotificationBubble] {
        let pinnedBubbles = bubbles
            .filter { $0.isReplying && replyPinSlotsBySourceChatId[$0.sourceChatId] != nil }
            .sorted {
                let leftSlot = replyPinSlotsBySourceChatId[$0.sourceChatId] ?? 0
                let rightSlot = replyPinSlotsBySourceChatId[$1.sourceChatId] ?? 0
                if leftSlot == rightSlot {
                    if $0.lastAssistantActivityAt == $1.lastAssistantActivityAt {
                        return $0.sourceChatId < $1.sourceChatId
                    }
                    return $0.lastAssistantActivityAt > $1.lastAssistantActivityAt
                }
                return leftSlot < rightSlot
            }
        guard !pinnedBubbles.isEmpty else { return bubbles }

        let pinnedSourceChatIds = Set(pinnedBubbles.map(\.sourceChatId))
        let unpinnedBubbles = bubbles.filter { !pinnedSourceChatIds.contains($0.sourceChatId) }
        let maxSlot = max(0, visibleCapacity - 1)
        var unpinnedIndex = 0
        var nextOrder: [CrossChatNotificationBubble] = []

        for slot in 0..<(bubbles.count + pinnedBubbles.count + 1) {
            let pinnedAtSlot = pinnedBubbles.filter {
                min(maxSlot, max(0, replyPinSlotsBySourceChatId[$0.sourceChatId] ?? 0)) == slot
            }
            nextOrder.append(contentsOf: pinnedAtSlot)
            if pinnedAtSlot.isEmpty, unpinnedIndex < unpinnedBubbles.count {
                nextOrder.append(unpinnedBubbles[unpinnedIndex])
                unpinnedIndex += 1
            }
            if nextOrder.count >= bubbles.count {
                break
            }
        }

        if unpinnedIndex < unpinnedBubbles.count {
            nextOrder.append(contentsOf: unpinnedBubbles[unpinnedIndex...])
        }
        return nextOrder
    }

    static func selectVisibleBubblesWithPinnedReplies(
        _ orderedBubbles: [CrossChatNotificationBubble],
        visibleCapacity: Int
    ) -> [CrossChatNotificationBubble] {
        var visibleBubbles = Array(orderedBubbles.prefix(visibleCapacity))
        var visibleSourceChatIds = Set(visibleBubbles.map(\.sourceChatId))
        let hiddenReplyBubbles = orderedBubbles.filter {
            $0.isReplying && !visibleSourceChatIds.contains($0.sourceChatId)
        }
        guard !hiddenReplyBubbles.isEmpty else { return visibleBubbles }

        for replyBubble in hiddenReplyBubbles {
            while visibleBubbles.count >= visibleCapacity,
                  let removableIndex = visibleBubbles.lastIndex(where: { !$0.isReplying }) {
                visibleSourceChatIds.remove(visibleBubbles[removableIndex].sourceChatId)
                visibleBubbles.remove(at: removableIndex)
            }
            visibleBubbles.append(replyBubble)
            visibleSourceChatIds.insert(replyBubble.sourceChatId)
        }

        let orderIndexBySourceChatId = Dictionary(
            uniqueKeysWithValues: orderedBubbles.enumerated().map { index, bubble in
                (bubble.sourceChatId, index)
            }
        )
        return visibleBubbles.sorted {
            (orderIndexBySourceChatId[$0.sourceChatId] ?? 0)
                < (orderIndexBySourceChatId[$1.sourceChatId] ?? 0)
        }
    }

    static func notificationBubbleActivityIdentity(_ bubble: CrossChatNotificationBubble) -> String {
        let entriesIdentity = bubble.entries
            .map { entry in
                "\(entry.id):\(entry.timestamp.timeIntervalSinceReferenceDate):\(entry.content.hashValue)"
            }
            .joined(separator: ",")
        return "\(bubble.sourceChatId):\(bubble.lastAssistantActivityAt.timeIntervalSinceReferenceDate):\(entriesIdentity)"
    }

    private func updateReplyPins() {
        let maxSlot = max(0, visibleCapacity - 1)
        var next: [String: Int] = [:]
        for bubble in orderedBubbles where bubble.isReplying {
            let fallbackSlot = min(
                maxSlot,
                max(
                    0,
                    orderedBubbles.firstIndex(where: { $0.sourceChatId == bubble.sourceChatId }) ?? 0
                )
            )
            next[bubble.sourceChatId] = min(maxSlot, replyPinSlotsBySourceChatId[bubble.sourceChatId] ?? fallbackSlot)
        }
        if next != replyPinSlotsBySourceChatId {
            replyPinSlotsBySourceChatId = next
        }
    }

    private func closeActionMenuIfSourceIsReplying() {
        guard let actionMenuSourceChatId,
              visibleBubbles.first(where: { $0.sourceChatId == actionMenuSourceChatId })?.isReplying == true else {
            return
        }
        closeActionMenu()
    }

    private func clearReplyFocus(sourceChatId: String) {
        if focusedReplySourceChatId == sourceChatId {
            focusedReplySourceChatId = nil
        }
    }

    private func clearReplyFocusIfClosed() {
        guard let focusedReplySourceChatId else { return }
        if visibleBubbles.first(where: { $0.sourceChatId == focusedReplySourceChatId })?.isReplying != true {
            self.focusedReplySourceChatId = nil
        }
    }

    private func pinReply(sourceChatId: String) {
        let maxSlot = max(0, visibleCapacity - 1)
        let currentSlot = visibleBubbles.firstIndex(where: { $0.sourceChatId == sourceChatId }) ?? 0
        replyPinSlotsBySourceChatId[sourceChatId] = min(maxSlot, max(0, currentSlot))
        if isCollapsed {
            restoreDock()
        }
    }

    private func unpinReply(sourceChatId: String) {
        replyPinSlotsBySourceChatId.removeValue(forKey: sourceChatId)
    }

    private func registerScrollView(sourceChatId: String, scrollView: UIScrollView?) {
        if let scrollView {
            scrollViewsBySourceChatId[sourceChatId] = WeakScrollViewBox(scrollView)
            scrollView.isScrollEnabled = gestureAxisLocksBySourceChatId[sourceChatId] != .horizontalSwipe
        } else {
            setGestureAxisLock(.none, sourceChatId: sourceChatId)
            scrollViewsBySourceChatId.removeValue(forKey: sourceChatId)
        }
    }

    private func setGestureAxisLock(_ lock: CrossChatNotificationGestureAxisLock, sourceChatId: String) {
        switch lock {
        case .none:
            gestureAxisLocksBySourceChatId[sourceChatId] = nil
        case .verticalScroll, .horizontalSwipe:
            gestureAxisLocksBySourceChatId[sourceChatId] = lock
        }
        scrollViewsBySourceChatId[sourceChatId]?.scrollView?.isScrollEnabled = lock != .horizontalSwipe
    }

    private func clearAllGestureAxisLocks() {
        for box in scrollViewsBySourceChatId.values {
            box.scrollView?.isScrollEnabled = true
        }
        gestureAxisLocksBySourceChatId = [:]
    }

    private func pruneGestureAxisLocks(visibleSourceChatIds: Set<String>) {
        for sourceChatId in gestureAxisLocksBySourceChatId.keys where !visibleSourceChatIds.contains(sourceChatId) {
            setGestureAxisLock(.none, sourceChatId: sourceChatId)
        }
    }

    @ViewBuilder
    private func actionMenuOverlay() -> some View {
        if let actionMenuBubble {
            CrossChatNotificationActionMenu(
                assignedNumber: actionMenuBubble.index,
                visibleNotificationCount: visibleBubbles.count,
                keyboardOwnershipStore: keyboardOwnershipStore,
                selection: actionMenuSelection,
                onSelectionChange: { selection in
                    actionMenuSelection = selection
                },
                onActivate: { item in
                    handleActionMenuAction(item, bubble: actionMenuBubble.bubble)
                },
                onCancel: {
                    closeActionMenu()
                }
            )
            .frame(width: 220)
            .focused($isActionMenuFocused)
            .onAppear {
                isActionMenuFocused = true
            }
            .onChange(of: actionMenuSelection) { _, _ in
                isActionMenuFocused = true
            }
            .padding(.top, CGFloat(actionMenuBubble.index) * (Self.minVisibleBubbleHeight + Self.bubbleSpacing))
            .zIndex(100)
        }
    }

    private func scrollNotification(sourceChatId: String, direction: ChatScrollPageDirection) {
        guard let scrollView = scrollViewsBySourceChatId[sourceChatId]?.scrollView else {
            return
        }

        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(
            minY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        guard maxY - minY > 0.5 else { return }

        let lineIncrement: CGFloat = 56
        let targetY = scrollView.contentOffset.y + (direction == .down ? lineIncrement : -lineIncrement)
        let clampedY = max(minY, min(targetY, maxY))
        guard abs(scrollView.contentOffset.y - clampedY) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: clampedY), animated: true)
    }

    private func routedNotificationSourceChatId(for intent: KeyboardCommandIntent) -> String? {
        if case .handled(.notificationBubble(let sourceChatId)) = KeyboardCommandRouter
            .route(intent: intent, store: keyboardOwnershipStore)
            .outcome {
            return sourceChatId
        }
        return nil
    }

    private func handleKeyboardCommandIntent(_ intent: KeyboardCommandIntent) {
        let route = KeyboardCommandRouter.route(intent: intent, store: keyboardOwnershipStore)
        switch intent {
        case .notificationAssignedOpen(let index):
            guard case .handled(.notificationBubble(let sourceChatId)) = route.outcome else { return }
            guard visibleBubbles.indices.contains(index),
                  visibleBubbles.contains(where: { $0.sourceChatId == sourceChatId }) else { return }
            if isCollapsed {
                restoreDock()
            }
            actionMenuSelection = .goToChat
            actionMenuSourceChatId = sourceChatId
        case .notificationAssignedReply(let index):
            guard case .handled(.notificationBubble(let sourceChatId)) = route.outcome else { return }
            guard visibleBubbles.indices.contains(index),
                  let bubble = visibleBubbles.first(where: { $0.sourceChatId == sourceChatId }) else { return }
            closeActionMenu()
            animateNotificationResize {
                if bubble.isReplying {
                    unpinReply(sourceChatId: bubble.sourceChatId)
                    clearReplyFocus(sourceChatId: bubble.sourceChatId)
                    viewModel.closeCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                } else {
                    pinReply(sourceChatId: bubble.sourceChatId)
                    viewModel.openCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                }
            }
        case .notificationAssignedDismiss(let index):
            guard case .handled(.notificationBubble(let sourceChatId)) = route.outcome else { return }
            guard visibleBubbles.indices.contains(index),
                  visibleBubbles.contains(where: { $0.sourceChatId == sourceChatId }) else { return }
            closeActionMenu()
            unpinReply(sourceChatId: sourceChatId)
            clearReplyFocus(sourceChatId: sourceChatId)
            dismissNotification(sourceChatId: sourceChatId)
        case .notificationDismissAll:
            guard case .handled(.notificationBubble(_)) = route.outcome else { return }
            dismissAllNotifications()
        case .notificationToggleDock:
            guard case .handled(.notificationBubble(_)) = route.outcome else { return }
            toggleDock()
        case .notificationScrollForward:
            guard case .handled(.notificationBubble(let sourceChatId)) = route.outcome else { return }
            scrollNotification(sourceChatId: sourceChatId, direction: .down)
        case .notificationScrollBackward:
            guard case .handled(.notificationBubble(let sourceChatId)) = route.outcome else { return }
            scrollNotification(sourceChatId: sourceChatId, direction: .up)
        default:
            break
        }
    }

    private func handleBubbleDragChanged(_ value: DragGesture.Value, sourceChatId: String) {
        let horizontal = value.translation.width
        let ownership = CrossChatNotificationGestureAxisLock.ownership(for: value.translation)
        guard ownership != .verticalScroll,
              gestureAxisLocksBySourceChatId[sourceChatId] != .verticalScroll else {
            bubbleDragOffsetsBySourceChatId[sourceChatId] = nil
            dismissSwipeActiveSourceChatIds.remove(sourceChatId)
            return
        }
        guard ownership == .horizontalSwipe else { return }
        setGestureAxisLock(.horizontalSwipe, sourceChatId: sourceChatId)
        bubbleDragOffsetsBySourceChatId[sourceChatId] = rubberBandOffset(for: horizontal)
        if horizontal <= -Self.collapseSwipeThreshold {
            dismissSwipeActiveSourceChatIds.insert(sourceChatId)
        } else {
            dismissSwipeActiveSourceChatIds.remove(sourceChatId)
        }
    }

    private func handleBubbleDrag(_ value: DragGesture.Value, sourceChatId: String) {
        let horizontal = value.translation.width
        let activeLock = gestureAxisLocksBySourceChatId[sourceChatId]
        withAnimation(Self.resizeAnimation) {
            bubbleDragOffsetsBySourceChatId[sourceChatId] = nil
            dismissSwipeActiveSourceChatIds.remove(sourceChatId)
        }
        setGestureAxisLock(.none, sourceChatId: sourceChatId)
        guard CrossChatNotificationGestureAxisLock.allowsBubbleSwipeCompletion(
            activeLock: activeLock,
            finalTranslation: value.translation,
            completionThreshold: Self.collapseSwipeThreshold
        ) else { return }
        if horizontal > 0 {
            if isCollapsed {
                clearCollapsedPreview(sourceChatId: sourceChatId)
            } else {
                dock()
            }
        } else {
            closeActionMenu()
            unpinReply(sourceChatId: sourceChatId)
            dismissNotification(sourceChatId: sourceChatId)
        }
    }

    private func handleNotificationContentDragChanged(_ translation: CGSize, sourceChatId: String) {
        guard CrossChatNotificationGestureAxisLock.ownership(for: translation) == .verticalScroll,
              gestureAxisLocksBySourceChatId[sourceChatId] != .horizontalSwipe else {
            return
        }
        bubbleDragOffsetsBySourceChatId[sourceChatId] = nil
        dismissSwipeActiveSourceChatIds.remove(sourceChatId)
        setGestureAxisLock(.verticalScroll, sourceChatId: sourceChatId)
    }

    private func handleNotificationContentDragEnded(sourceChatId: String) {
        if gestureAxisLocksBySourceChatId[sourceChatId] == .verticalScroll {
            setGestureAxisLock(.none, sourceChatId: sourceChatId)
        }
    }

    private func handlePeekDrag(_ value: DragGesture.Value) {
        let horizontal = value.translation.width
        guard abs(horizontal) > abs(value.translation.height),
              abs(horizontal) >= Self.collapseSwipeThreshold else { return }
        if horizontal < 0 {
            restoreDock()
        }
    }

    private func dock() {
        guard !hasActiveReply else { return }
        clearAllCollapsedPreviews()
        withAnimation(Self.hideAnimation) {
            isCollapsed = true
        }
    }

    private func restoreDock() {
        clearAllCollapsedPreviews()
        withAnimation(Self.revealAnimation) {
            isCollapsed = false
        }
    }

    private func toggleDock() {
        guard !hasActiveReply else {
            if isCollapsed {
                restoreDock()
            }
            return
        }
        clearAllCollapsedPreviews()
        let animation = isCollapsed ? Self.revealAnimation : Self.hideAnimation
        withAnimation(animation) {
            isCollapsed.toggle()
        }
    }

    private func clearCollapsedPreview(sourceChatId: String) {
        collapsedPreviewTasksBySourceChatId[sourceChatId]?.cancel()
        collapsedPreviewTasksBySourceChatId[sourceChatId] = nil
        previewingCollapsedSourceChatIds.remove(sourceChatId)
    }

    private func clearAllCollapsedPreviews() {
        for task in collapsedPreviewTasksBySourceChatId.values {
            task.cancel()
        }
        collapsedPreviewTasksBySourceChatId = [:]
        previewingCollapsedSourceChatIds.removeAll()
    }

    private func startCollapsedPreview(sourceChatIds: [String]) {
        guard isCollapsed else { return }
        let visibleSourceChatIds = Set(visibleBubbles.map(\.sourceChatId))
        for sourceChatId in sourceChatIds where visibleSourceChatIds.contains(sourceChatId) {
            collapsedPreviewTasksBySourceChatId[sourceChatId]?.cancel()
            withAnimation(Self.revealAnimation) {
                _ = previewingCollapsedSourceChatIds.insert(sourceChatId)
            }
            collapsedPreviewTasksBySourceChatId[sourceChatId] = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                guard isCollapsed else {
                    clearCollapsedPreview(sourceChatId: sourceChatId)
                    return
                }
                withAnimation(Self.hideAnimation) {
                    _ = previewingCollapsedSourceChatIds.remove(sourceChatId)
                }
                collapsedPreviewTasksBySourceChatId[sourceChatId] = nil
            }
        }
    }

    private func closeActionMenu() {
        actionMenuSourceChatId = nil
        actionMenuSelection = .goToChat
    }

    private func handleActionMenuAction(
        _ item: CrossChatNotificationActionMenuItem,
        bubble: CrossChatNotificationBubble
    ) {
        closeActionMenu()
        switch item {
        case .goToChat:
            unpinReply(sourceChatId: bubble.sourceChatId)
            clearReplyFocus(sourceChatId: bubble.sourceChatId)
            onNavigateToSource(bubble.sourceChatId)
        case .reply:
            animateNotificationResize {
                if bubble.isReplying {
                    unpinReply(sourceChatId: bubble.sourceChatId)
                    clearReplyFocus(sourceChatId: bubble.sourceChatId)
                    viewModel.closeCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                } else {
                    pinReply(sourceChatId: bubble.sourceChatId)
                    viewModel.openCrossChatNotificationReply(sourceChatId: bubble.sourceChatId)
                }
            }
        case .dismiss:
            unpinReply(sourceChatId: bubble.sourceChatId)
            clearReplyFocus(sourceChatId: bubble.sourceChatId)
            dismissNotification(sourceChatId: bubble.sourceChatId)
        }
    }

    private func animateNotificationResize(_ updates: () -> Void) {
        withAnimation(Self.resizeAnimation) {
            updates()
        }
    }

    private func dismissNotification(sourceChatId: String) {
        clearReplyFocus(sourceChatId: sourceChatId)
        withAnimation(Self.hideAnimation) {
            viewModel.dismissCrossChatNotification(sourceChatId: sourceChatId)
        }
    }

    private func dismissAllNotifications() {
        focusedReplySourceChatId = nil
        focusedSourceChatId = nil
        closeActionMenu()
        withAnimation(Self.hideAnimation) {
            viewModel.dismissAllCrossChatNotifications()
        }
    }
}

private final class WeakScrollViewBox {
    weak var scrollView: UIScrollView?

    init(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
    }
}

private extension UIScrollView {
    func clawlineClampNotificationContentOffset() {
        layoutIfNeeded()
        let minY = -adjustedContentInset.top
        let maxY = max(
            minY,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
        let clampedY = max(minY, min(contentOffset.y, maxY))
        guard abs(contentOffset.y - clampedY) > 0.5 else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: clampedY), animated: false)
    }
}

private extension UIKey {
    var hasNoCommandModifiers: Bool {
        modifierFlags.intersection([.command, .shift, .alternate, .control]).isEmpty
    }
}

private struct NotificationScrollViewResolver: UIViewRepresentable {
    let onResolve: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolve()
    }

    final class ResolverView: UIView {
        var onResolve: ((UIScrollView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var view: UIView? = self.superview
                while let current = view {
                    if let scrollView = current as? UIScrollView {
                        self.onResolve?(scrollView)
                        scrollView.clawlineClampNotificationContentOffset()
                        DispatchQueue.main.async { [weak scrollView] in
                            scrollView?.clawlineClampNotificationContentOffset()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak scrollView] in
                            scrollView?.clawlineClampNotificationContentOffset()
                        }
                        return
                    }
                    view = current.superview
                }
                self.onResolve?(nil)
            }
        }
    }
}

private struct CrossChatNotificationBubbleHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct CrossChatNotificationBubbleView: View {
    let bubble: CrossChatNotificationBubble
    let assignedNumber: Int
    let visibleNotificationCount: Int
    let showShortcutLabel: Bool
    let maxBubbleHeight: CGFloat
    let maxBubbleWidth: CGFloat
    let bubbleCornerRadius: CGFloat
    let isSending: Bool
    let canCancelSend: Bool
    let canSendReply: Bool
    let connectionState: SendButtonConnectionState
    @Binding var replyDraft: String
    let onDismiss: () -> Void
    let onReply: () -> Void
    let onCancelReply: () -> Void
    let onDismissAll: () -> Void
    let onNavigate: () -> Void
    let onSendReply: () -> Void
    let onCancelSend: () -> Void
    let onReconnect: () -> Void
    let onActivate: () -> Void
    let onReplyFocusChange: (Bool) -> Void
    let isActionMenuOpen: Bool
    let actionMenuSelection: CrossChatNotificationActionMenuItem
    var keyboardOwnershipStore = KeyboardOwnershipStore()
    let onActionMenuSelectionChange: (CrossChatNotificationActionMenuItem) -> Void
    let onActionMenuAction: (CrossChatNotificationActionMenuItem) -> Void
    let onRegisterScrollView: (UIScrollView?) -> Void
    let isDismissSwipeActive: Bool
    let isContentScrollLocked: Bool
    let onContentScrollDragChanged: (CGSize) -> Void
    let onContentScrollDragEnded: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isClearAllConfirmationPresented = false
    @State private var measuredEntriesHeight: CGFloat = 0
    @State private var measuredReplyFieldHeight: CGFloat = 0

    private let controlSize: CGFloat = 44
    private let normalContentSpacing: CGFloat = 6
    private let normalTopPadding: CGFloat = 4
    private let normalBottomPadding: CGFloat = 6
    private let replyTopPadding: CGFloat = 3
    private let replyBottomPadding: CGFloat = 10
    private let notificationAccentWidth: CGFloat = 14
    private let notificationAccentOpacity: Double = 0.40
    private let accentContentGap: CGFloat = 10
    private var accentReplyGestureWidth: CGFloat { notificationAccentWidth + accentContentGap }
    private let entriesBottomBreathingRoom: CGFloat = 8
    private let resizeAnimation = CrossChatNotificationMotion.resize

    private var inputBarColorScheme: ColorScheme {
        return colorScheme
    }

    private var visionOSBorderColor: Color {
        Color.white.opacity(0.5)
    }

    private var contentMaxHeight: CGFloat {
        let headerAndPadding = controlSize + normalContentSpacing + normalTopPadding + normalBottomPadding
        return max(44, maxBubbleHeight - headerAndPadding)
    }

    private var entriesAnimationKey: String {
        bubble.entries
            .map { "\($0.id):\($0.content.count)" }
            .joined(separator: "|")
    }

    private var resolvedEntriesHeight: CGFloat? {
        guard measuredEntriesHeight > 0 else { return nil }
        return min(measuredEntriesHeight, contentMaxHeight)
    }

    private var entriesNeedScroll: Bool {
        measuredEntriesHeight > contentMaxHeight + 0.5
    }

    private var notificationAccentColor: Color {
        ChatFlowTheme.notificationAccent(colorScheme)
    }

    private var notificationDismissActiveColor: Color {
        StreamDotColor.resolve(
            isActive: false,
            dotState: .unread,
            colorScheme: colorScheme
        )
    }

    private var notificationBodyInkColor: UIColor {
        UIColor.label.withAlphaComponent(colorScheme == .dark ? 0.82 : 0.74)
    }

    private func notificationFont(_ role: ClawlineTextRole, weight: Font.Weight? = nil) -> Font {
        let pointSize = UIFont.clawline(role).pointSize + 2
        if let weight {
            return .system(size: pointSize, weight: weight)
        }
        return .system(size: pointSize)
    }

    private func notificationUIFont(_ role: ClawlineTextRole) -> UIFont {
        UIFont.systemFont(ofSize: UIFont.clawline(role).pointSize + 2)
    }

    private var replyFieldFont: UIFont {
        notificationUIFont(.secondaryLabel)
    }

    private var replyFieldHeight: CGFloat {
        let minimumHeight = NotificationReplyTextInputConfiguration.height(
            forVisibleLines: 1,
            font: replyFieldFont
        )
        return max(minimumHeight, measuredReplyFieldHeight)
    }

    private func activateReplySendControl() {
        guard !isSending else { return }
        switch connectionState {
        case .connected:
            guard canSendReply else { return }
            onSendReply()
        case .disconnected:
            onReconnect()
        case .reconnecting:
            break
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: bubble.isReplying ? 4 : normalContentSpacing) {
            HStack(spacing: 8) {
                if showShortcutLabel {
                    Text("⌘\(assignedNumber)")
                        .font(notificationFont(.secondaryLabel))
                        .monospacedDigit()
                        .lineLimit(1)
                        .accessibilityLabel("Shortcut Command \(assignedNumber)")
                }

                Text(bubble.sourceTitle)
                    .font(notificationFont(.uiLabel, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNavigate)

                Spacer(minLength: 8)

                Button {
                    if isActionMenuOpen {
                        onActionMenuAction(.reply)
                    } else {
                        onReply()
                    }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.clawline(.uiLabel).weight(.semibold))
                        .foregroundStyle(bubble.isReplying ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .frame(width: controlSize, height: controlSize)
                .buttonStyle(.plain)
                .accessibilityLabel(bubble.isReplying ? "Close reply" : "Reply")
                .accessibilityAddTraits(bubble.isReplying ? .isSelected : [])

                Button(action: onDismiss) {
                    ZStack {
                        Circle()
                            .fill(notificationDismissActiveColor.opacity(colorScheme == .dark ? 0.42 : 0.34))
                            .frame(width: controlSize, height: controlSize)
                            .blur(radius: MessageInputBar.sendButtonColoredBackingBlurRadius)
                            .opacity(isDismissSwipeActive ? 1 : 0)
                            .animation(
                                isDismissSwipeActive
                                    ? .easeOut(duration: 0.16).delay(0.08)
                                    : .easeOut(duration: 0.10),
                                value: isDismissSwipeActive
                            )
                            .allowsHitTesting(false)

                        Image(systemName: "xmark")
                            .font(.clawline(.uiLabel).weight(.semibold))
                            .foregroundStyle(isDismissSwipeActive ? notificationDismissActiveColor : Color.primary)
                            .animation(.easeOut(duration: 0.10), value: isDismissSwipeActive)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .frame(width: controlSize, height: controlSize)
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .highPriorityGesture(
                    LongPressGesture().onEnded { _ in
                        isClearAllConfirmationPresented = true
                    }
                )
            }

            if !bubble.isReplying {
                ZStack(alignment: .topLeading) {
                    notificationEntriesContent()
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: CrossChatNotificationEntriesHeightPreferenceKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                        .hidden()
                        .allowsHitTesting(false)

                    if entriesNeedScroll {
                        ScrollView(.vertical) {
                            notificationEntriesContent()
                                .padding(.bottom, entriesBottomBreathingRoom)
                        }
                        .frame(height: resolvedEntriesHeight ?? contentMaxHeight, alignment: .top)
                        .scrollIndicators(.visible)
                        .scrollDisabled(isContentScrollLocked)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: CrossChatNotificationGestureAxisLock.minimumDistance)
                                .onChanged { value in
                                    onContentScrollDragChanged(value.translation)
                                }
                                .onEnded { _ in
                                    onContentScrollDragEnded()
                                }
                        )
                        .background(
                            NotificationScrollViewResolver(onResolve: onRegisterScrollView)
                        )
                    } else {
                        notificationEntriesContent()
                            .padding(.bottom, entriesBottomBreathingRoom)
                            .background(
                                NotificationScrollViewResolver { _ in
                                    onRegisterScrollView(nil)
                                }
                            )
                    }
                }
                .frame(height: resolvedEntriesHeight, alignment: .top)
                .frame(maxHeight: contentMaxHeight, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture(perform: onNavigate)
                .clipped()
                .onPreferenceChange(CrossChatNotificationEntriesHeightPreferenceKey.self) { height in
                    guard abs(measuredEntriesHeight - height) > 0.5 else { return }
                    withAnimation(resizeAnimation) {
                        measuredEntriesHeight = height
                    }
                }
                .animation(resizeAnimation, value: entriesAnimationKey)
                .animation(resizeAnimation, value: resolvedEntriesHeight)
                .animation(resizeAnimation, value: contentMaxHeight)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if bubble.isReplying {
                HStack(alignment: .bottom, spacing: 8) {
                    NotificationReplyTextInput(
                        sourceChatId: bubble.sourceChatId,
                        text: $replyDraft,
                        measuredHeight: $measuredReplyFieldHeight,
                        font: replyFieldFont,
                        textColor: UIColor.label,
                        tintColor: UIColor(notificationAccentColor),
                        visibleNotificationCount: visibleNotificationCount,
                        keyboardOwnershipStore: keyboardOwnershipStore,
                        onSubmit: activateReplySendControl,
                        onCancel: onCancelReply,
                        onFocusChange: onReplyFocusChange
                    )
                        .frame(height: replyFieldHeight)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    MessageSendControl(
                        isSending: isSending,
                        canCancelSend: canCancelSend,
                        canSend: canSendReply,
                        isStagingAttachments: false,
                        connectionState: connectionState,
                        sendButtonSize: controlSize,
                        inputBarColorScheme: inputBarColorScheme,
                        uiColorScheme: colorScheme,
                        visionOSBorderColor: visionOSBorderColor,
                        onSend: onSendReply,
                        onCancel: onCancelSend,
                        onReconnect: onReconnect
                    )
                    .frame(width: controlSize, height: controlSize)
                    .accessibilityLabel("Send reply")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

        }
        .foregroundStyle(.primary)
        .padding(.leading, notificationAccentWidth + accentContentGap)
        .padding(.trailing, 12)
        .padding(.top, bubble.isReplying ? replyTopPadding : normalTopPadding)
        .padding(.bottom, bubble.isReplying ? replyBottomPadding : normalBottomPadding)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: maxBubbleWidth, alignment: .topLeading)
        .animation(resizeAnimation, value: bubble.isReplying)
        .animation(resizeAnimation, value: maxBubbleHeight)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CrossChatNotificationBubbleHeightPreferenceKey.self,
                    value: [bubble.sourceChatId: proxy.size.height]
                )
            }
        )
        .onHover { isHovering in
            if isHovering {
                onActivate()
            }
        }
        .onTapGesture(perform: onActivate)
#if os(visionOS)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
#else
        .background(alignment: .leading) {
            Rectangle()
                .fill(notificationAccentColor.opacity(notificationAccentOpacity))
                .frame(width: notificationAccentWidth)
                .allowsHitTesting(false)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
#endif
        .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
        .overlay {
            RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: accentReplyGestureWidth)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: CrossChatNotificationAccentReplyGesture.minimumDistance)
                        .onEnded { value in
                            guard CrossChatNotificationAccentReplyGesture.shouldToggleReply(
                                translation: value.translation
                            ) else {
                                return
                            }
                            onReply()
                        }
                )
        }
        .confirmationDialog(
            "Clear all notifications?",
            isPresented: $isClearAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear All Notifications", role: .destructive, action: onDismissAll)
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func notificationEntriesContent() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bubble.entries) { entry in
                let renderedBlocks = CrossChatNotificationMarkdownRenderer.renderBlocks(
                    content: entry.content,
                    messageID: entry.id,
                    baseFont: notificationUIFont(.secondaryLabel),
                    inkColor: notificationBodyInkColor,
                    lineSpacing: 2,
                    isDark: colorScheme == .dark
                )
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(renderedBlocks.enumerated()), id: \.offset) { _, block in
                        notificationMarkdownBlock(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func notificationMarkdownBlock(_ block: RenderedMarkdownBlock) -> some View {
        switch block {
        case .attributedText(let attributed):
            SelectableAttributedText(
                attributedString: attributed,
                alignment: .left,
                colorScheme: colorScheme,
                onSelectionChange: { _ in },
                onLinkTap: { _ in onNavigate() }
            )
            .allowsHitTesting(false)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .table(let model):
            MarkdownTableView(
                model: model,
                role: .assistant,
                metrics: ChatFlowTheme.Metrics(isCompact: true),
                maxLineWidth: max(1, maxBubbleWidth - notificationAccentWidth - accentContentGap - 12),
                isExpanded: true,
                onExpand: {},
                onCollapse: {}
            )
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

enum CrossChatNotificationAccentReplyGesture {
    static let minimumDistance: CGFloat = 18

    static func shouldToggleReply(translation: CGSize) -> Bool {
        abs(translation.height) >= minimumDistance
            && abs(translation.height) > abs(translation.width)
    }
}

enum CrossChatNotificationGestureAxisLock: Equatable {
    case none
    case verticalScroll
    case horizontalSwipe

    static let minimumDistance: CGFloat = 20

    static func ownership(for translation: CGSize) -> CrossChatNotificationGestureAxisLock {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard max(horizontal, vertical) >= minimumDistance else { return .none }
        if horizontal > vertical {
            return .horizontalSwipe
        }
        if vertical > horizontal {
            return .verticalScroll
        }
        return .none
    }

    static func allowsBubbleSwipeCompletion(
        activeLock: CrossChatNotificationGestureAxisLock?,
        finalTranslation: CGSize,
        completionThreshold: CGFloat
    ) -> Bool {
        activeLock != .verticalScroll
            && ownership(for: finalTranslation) == .horizontalSwipe
            && abs(finalTranslation.width) >= completionThreshold
    }
}

enum NotificationReplyTextInputConfiguration {
    static let textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    static let maximumVisibleLines = 5

    static func height(forVisibleLines lines: Int, font: UIFont) -> CGFloat {
        ceil(font.lineHeight * CGFloat(lines))
    }

    static func configure(
        _ textView: UITextView,
        font: UIFont,
        textColor: UIColor,
        tintColor: UIColor,
        visibleNotificationCount: Int
    ) {
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        textView.textContainerInset = textContainerInset
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.adjustsFontForContentSizeCategory = true
        textView.returnKeyType = .send
        if let replyTextView = textView as? NotificationReplyUITextView {
            replyTextView.enforceSendReturnKey()
        } else if textView.isFirstResponder {
            textView.reloadInputViews()
        }
        textView.autocorrectionType = .yes
        textView.smartQuotesType = .yes
        textView.smartDashesType = .yes
        textView.smartInsertDeleteType = .yes
#if !os(visionOS)
        textView.keyboardDismissMode = .interactive
#endif
        textView.isEditable = true
        textView.isSelectable = true
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let replyTextView = textView as? NotificationReplyUITextView {
            replyTextView.visibleNotificationCount = visibleNotificationCount
        }
    }
}

struct NotificationReplyTextInput: UIViewRepresentable {
    let sourceChatId: String
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let visibleNotificationCount: Int
    var keyboardOwnershipStore = KeyboardOwnershipStore()
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeUIView(context: Context) -> NotificationReplyUITextView {
        let textView = NotificationReplyUITextView()
        textView.delegate = context.coordinator
        textView.onCancel = onCancel
        textView.sourceChatId = sourceChatId
        textView.keyboardOwnershipStore = keyboardOwnershipStore
        textView.wantsInitialFocus = true
        NotificationReplyTextInputConfiguration.configure(
            textView,
            font: font,
            textColor: textColor,
            tintColor: tintColor,
            visibleNotificationCount: visibleNotificationCount
        )
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: NotificationReplyUITextView, context: Context) {
        context.coordinator.parent = self
        textView.onCancel = onCancel
        textView.sourceChatId = sourceChatId
        textView.keyboardOwnershipStore = keyboardOwnershipStore
        NotificationReplyTextInputConfiguration.configure(
            textView,
            font: font,
            textColor: textColor,
            tintColor: tintColor,
            visibleNotificationCount: visibleNotificationCount
        )
        if textView.text != text {
            textView.text = text
        }
        context.coordinator.updateHeight(for: textView)
        textView.focusIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NotificationReplyUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let maxHeight = NotificationReplyTextInputConfiguration.height(
            forVisibleLines: NotificationReplyTextInputConfiguration.maximumVisibleLines,
            font: font
        )
        let minimumHeight = NotificationReplyTextInputConfiguration.height(
            forVisibleLines: 1,
            font: font
        )
        let fittingHeight = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let resolvedHeight = min(max(fittingHeight, minimumHeight), maxHeight)
        return CGSize(width: width, height: resolvedHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NotificationReplyTextInput

        init(parent: NotificationReplyTextInput) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            updateHeight(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if replacement == "\n" {
                // UIKit's software-keyboard text delegate reports only the replacement text,
                // so Return and software Shift-Return are not distinguishable here. Hardware
                // modified Return is handled by keyCommands before this submit path.
                if parent.isOwnedReplyRoute(.textSubmit) {
                    parent.onSubmit()
                } else {
                    return true
                }
                return false
            }
            return true
        }

        func updateHeight(for textView: UITextView) {
            let maxHeight = NotificationReplyTextInputConfiguration.height(
                forVisibleLines: NotificationReplyTextInputConfiguration.maximumVisibleLines,
                font: parent.font
            )
            let minimumHeight = NotificationReplyTextInputConfiguration.height(
                forVisibleLines: 1,
                font: parent.font
            )
            let fittingHeight = textView.sizeThatFits(
                CGSize(width: max(1, textView.bounds.width), height: .greatestFiniteMagnitude)
            ).height
            let resolvedHeight = min(max(fittingHeight, minimumHeight), maxHeight)
            textView.isScrollEnabled = fittingHeight > maxHeight + 0.5
            guard abs(parent.measuredHeight - resolvedHeight) > 0.5 else { return }
            DispatchQueue.main.async {
                self.parent.measuredHeight = resolvedHeight
            }
        }
    }

    func isOwnedReplyRoute(_ intent: KeyboardCommandIntent) -> Bool {
        if case .handled(.notificationReply(let routedSourceChatId)) = KeyboardCommandRouter
            .route(intent: intent, store: keyboardOwnershipStore)
            .outcome,
           routedSourceChatId == sourceChatId {
            return true
        }
        return false
    }
}

final class NotificationReplyUITextView: UITextView {
    var sourceChatId = ""
    var onCancel: (() -> Void)?
    var wantsInitialFocus = false
    var visibleNotificationCount = 0
    var keyboardOwnershipStore = KeyboardOwnershipStore()

    func enforceSendReturnKey() {
        returnKeyType = .send
        if isFirstResponder {
            reloadInputViews()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let prioritizedNotificationCommands = ChatAppCommandShortcut
            .prioritizedTextInputKeyCommandSpecs(notificationVisibleCount: visibleNotificationCount)
            .filter {
                guard let intent = KeyboardCommandBridge.intent(input: $0.input, modifierFlags: $0.modifierFlags) else {
                    return false
                }
                guard case .handled(.notificationBubble(_)) = KeyboardCommandRouter
                    .route(intent: intent, store: keyboardOwnershipStore)
                    .outcome else { return false }
                return true
            }
            .map {
                UIKeyCommand(
                    input: $0.input,
                    modifierFlags: $0.modifierFlags,
                    action: $0.action.selector
                )
            }
        let escapeCommand = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(didPressEscape)
        )
        let modifiedReturnCommands = KeyboardCommandBridge.textInputSpecs.compactMap { spec -> UIKeyCommand? in
            guard spec.intent == .textModifiedNewline else { return nil }
            return UIKeyCommand(
                input: spec.input,
                modifierFlags: spec.modifierFlags,
                action: #selector(didPressModifiedReturn)
            )
        }
        return prioritizedNotificationCommands + [escapeCommand] + modifiedReturnCommands + (super.keyCommands ?? [])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        enforceSendReturnKey()
        focusIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        enforceSendReturnKey()
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            enforceSendReturnKey()
        }
        return didBecomeFirstResponder
    }

    func focusIfNeeded() {
        guard wantsInitialFocus, window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, wantsInitialFocus, window != nil, !isFirstResponder else { return }
            _ = becomeFirstResponder()
            wantsInitialFocus = false
        }
    }

    @objc private func didPressEscape(_ sender: UIKeyCommand) {
        guard case .handled(.notificationReply(let routedSourceChatId)) = KeyboardCommandRouter
            .route(intent: .textCancel, store: keyboardOwnershipStore)
            .outcome,
              routedSourceChatId == sourceChatId else { return }
        onCancel?()
    }

    @objc private func didPressModifiedReturn(_ sender: UIKeyCommand) {
        guard case .handled(.notificationReply(let routedSourceChatId)) = KeyboardCommandRouter
            .route(intent: .textModifiedNewline, store: keyboardOwnershipStore)
            .outcome,
              routedSourceChatId == sourceChatId else { return }
        insertPlainText("\n")
    }

    private func insertPlainText(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: typingAttributes)
        let range = selectedRange
        textStorage.replaceCharacters(in: range, with: attributed)
        selectedRange = NSRange(location: range.location + attributed.length, length: 0)
        delegate?.textViewDidChange?(self)
    }
}

private extension UIKeyModifierFlags {
    init(eventModifiers: EventModifiers) {
        self.init()
        if eventModifiers.contains(.command) {
            insert(.command)
        }
        if eventModifiers.contains(.shift) {
            insert(.shift)
        }
        if eventModifiers.contains(.option) {
            insert(.alternate)
        }
        if eventModifiers.contains(.control) {
            insert(.control)
        }
    }
}

enum CrossChatNotificationActionMenuItem: CaseIterable, Identifiable {
    case goToChat
    case reply
    case dismiss

    var id: Self { self }

    var title: String {
        switch self {
        case .goToChat:
            return "Go to Chat…"
        case .reply:
            return "Reply…"
        case .dismiss:
            return "Dismiss"
        }
    }

    func shortcutLabel(assignedNumber: Int) -> String? {
        switch self {
        case .goToChat:
            return nil
        case .reply:
            return "⇧⌘\(assignedNumber)"
        case .dismiss:
            return "⌥⇧⌘\(assignedNumber)"
        }
    }

    func moved(step: Int) -> Self {
        let items = Self.allCases
        guard let currentIndex = items.firstIndex(of: self) else { return .goToChat }
        let nextIndex = min(max(currentIndex + step, 0), items.count - 1)
        return items[nextIndex]
    }
}

private struct CrossChatNotificationActionMenu: View {
    @Environment(\.colorScheme) private var colorScheme

    let assignedNumber: Int
    let visibleNotificationCount: Int
    let keyboardOwnershipStore: KeyboardOwnershipStore
    let selection: CrossChatNotificationActionMenuItem
    let onSelectionChange: (CrossChatNotificationActionMenuItem) -> Void
    let onActivate: (CrossChatNotificationActionMenuItem) -> Void
    let onCancel: () -> Void

    private func notificationFont(_ role: ClawlineTextRole, weight: Font.Weight? = nil) -> Font {
        let pointSize = UIFont.clawline(role).pointSize + 2
        if let weight {
            return .system(size: pointSize, weight: weight)
        }
        return .system(size: pointSize)
    }

    private func routeMenuIntent(_ intent: KeyboardCommandIntent) -> Bool {
        guard assignedNumber < visibleNotificationCount else { return false }
        guard case .handled(.notificationActionMenu(_)) = KeyboardCommandRouter
            .route(intent: intent, store: keyboardOwnershipStore)
            .outcome else { return false }
        return true
    }

    var body: some View {
        let menuShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let selectionColor = ChatFlowTheme.notificationAccent(colorScheme)

        VStack(spacing: 2) {
            ForEach(CrossChatNotificationActionMenuItem.allCases) { item in
                Button {
                    onActivate(item)
                } label: {
                    HStack(spacing: 14) {
                        Text(item.title)
                            .font(notificationFont(.secondaryLabel, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if let shortcut = item.shortcutLabel(assignedNumber: assignedNumber) {
                            Text(shortcut)
                                .font(notificationFont(.secondaryLabel))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(item == selection ? selectionColor.opacity(0.24) : Color.clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                item == selection ? selectionColor.opacity(0.58) : Color.clear,
                                lineWidth: 0.8
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .onHover { isHovering in
                    if isHovering {
                        onSelectionChange(item)
                    }
                }
            }
        }
        .padding(5)
        .frame(width: 220, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            menuShape
                .fill(.regularMaterial)
            menuShape
                .fill(Color(uiColor: .systemBackground).opacity(0.84))
        }
        .overlay {
            menuShape
                .strokeBorder(Color.primary.opacity(0.30), lineWidth: 0.9)
        }
        .shadow(color: Color.black.opacity(0.34), radius: 22, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 2)
#if compiler(>=6.0) && !os(visionOS)
        .glassEffect(.regular, in: menuShape)
#endif
        .focusable()
        .onKeyPress(.upArrow) {
            guard routeMenuIntent(.menuNavigateUp) else { return .ignored }
            onSelectionChange(selection.moved(step: -1))
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard routeMenuIntent(.menuNavigateDown) else { return .ignored }
            onSelectionChange(selection.moved(step: 1))
            return .handled
        }
        .onKeyPress(.return) {
            guard routeMenuIntent(.menuActivate) else { return .ignored }
            onActivate(selection)
            return .handled
        }
        .onKeyPress(.escape) {
            guard routeMenuIntent(.menuCancel) else { return .ignored }
            onCancel()
            return .handled
        }
        .background(
            CrossChatNotificationActionMenuKeyBridge(
                assignedNumber: assignedNumber,
                visibleNotificationCount: visibleNotificationCount,
                keyboardOwnershipStore: keyboardOwnershipStore,
                selection: selection,
                onSelectionChange: onSelectionChange,
                onActivate: onActivate,
                onCancel: onCancel
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }
}

private struct CrossChatNotificationActionMenuKeyBridge: UIViewRepresentable {
    let assignedNumber: Int
    let visibleNotificationCount: Int
    let keyboardOwnershipStore: KeyboardOwnershipStore
    let selection: CrossChatNotificationActionMenuItem
    let onSelectionChange: (CrossChatNotificationActionMenuItem) -> Void
    let onActivate: (CrossChatNotificationActionMenuItem) -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.delegate = context.coordinator
        view.assignedNumber = assignedNumber
        view.visibleNotificationCount = visibleNotificationCount
        view.keyboardOwnershipStore = keyboardOwnershipStore
        return view
    }

    func updateUIView(_ uiView: KeyCommandView, context: Context) {
        uiView.assignedNumber = assignedNumber
        uiView.visibleNotificationCount = visibleNotificationCount
        uiView.keyboardOwnershipStore = keyboardOwnershipStore
        context.coordinator.selection = selection
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onActivate = onActivate
        DispatchQueue.main.async { [weak uiView] in
            uiView?.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: selection,
            onSelectionChange: onSelectionChange,
            onActivate: onActivate,
            onCancel: onCancel
        )
    }

    final class Coordinator {
        var selection: CrossChatNotificationActionMenuItem
        var onSelectionChange: (CrossChatNotificationActionMenuItem) -> Void
        var onActivate: (CrossChatNotificationActionMenuItem) -> Void
        var onCancel: () -> Void

        init(
            selection: CrossChatNotificationActionMenuItem,
            onSelectionChange: @escaping (CrossChatNotificationActionMenuItem) -> Void,
            onActivate: @escaping (CrossChatNotificationActionMenuItem) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.selection = selection
            self.onSelectionChange = onSelectionChange
            self.onActivate = onActivate
            self.onCancel = onCancel
        }

        func move(step: Int) {
            onSelectionChange(selection.moved(step: step))
        }

        func activate() {
            onActivate(selection)
        }

        func cancel() {
            onCancel()
        }
    }

    final class KeyCommandView: UIView {
        weak var delegate: Coordinator?
        var assignedNumber = 0
        var visibleNotificationCount = 0
        var keyboardOwnershipStore = KeyboardOwnershipStore()

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            let menuCommands = KeyboardCommandBridge.menuSpecs.compactMap { spec -> UIKeyCommand? in
                guard let selector = selector(for: spec.intent) else { return nil }
                return UIKeyCommand(
                    input: spec.input,
                    modifierFlags: spec.modifierFlags,
                    action: selector
                )
            }
            let notificationNumberCommands = ChatAppCommandShortcut
                .notificationNumberKeyCommandSpecs(visibleCount: visibleNotificationCount)
                .map { spec in
                    UIKeyCommand(
                        input: spec.input,
                        modifierFlags: spec.modifierFlags,
                        action: spec.action.selector
                    )
            }
            let notificationScrollCommands = ChatAppCommandShortcut
                .notificationScrollKeyCommandSpecs(notificationVisibleCount: visibleNotificationCount)
                .map { spec in
                    UIKeyCommand(
                        input: spec.input,
                        modifierFlags: spec.modifierFlags,
                        action: spec.action.selector
                    )
            }
            return menuCommands + notificationNumberCommands + notificationScrollCommands
        }

        private func selector(for intent: KeyboardCommandIntent) -> Selector? {
            switch intent {
            case .menuNavigateUp:
                return #selector(handleUp)
            case .menuNavigateDown:
                return #selector(handleDown)
            case .menuActivate:
                return #selector(handleReturn)
            case .menuCancel:
                return #selector(handleEscape)
            default:
                return nil
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.becomeFirstResponder()
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses {
                guard let key = press.key, key.hasNoCommandModifiers else { continue }
                switch key.keyCode {
                case .keyboardUpArrow:
                    handleUp()
                    return
                case .keyboardDownArrow:
                    handleDown()
                    return
                case .keyboardReturnOrEnter:
                    handleReturn()
                    return
                case .keyboardEscape:
                    handleEscape()
                    return
                default:
                    continue
                }
            }
            super.pressesBegan(presses, with: event)
        }

        @objc private func handleUp() {
            guard routes(.menuNavigateUp) else { return }
            delegate?.move(step: -1)
        }

        @objc private func handleDown() {
            guard routes(.menuNavigateDown) else { return }
            delegate?.move(step: 1)
        }

        @objc private func handleReturn() {
            guard routes(.menuActivate) else { return }
            delegate?.activate()
        }

        @objc private func handleEscape() {
            guard routes(.menuCancel) else { return }
            delegate?.cancel()
        }

        private func routes(_ intent: KeyboardCommandIntent) -> Bool {
            guard assignedNumber < visibleNotificationCount else { return false }
            guard case .handled(.notificationActionMenu(_)) = KeyboardCommandRouter
                .route(intent: intent, store: keyboardOwnershipStore)
                .outcome else { return false }
            return true
        }
    }
}

enum CrossChatNotificationGlobalShortcut {
    enum Action: Equatable {
        case scrollDown
        case scrollUp

        var notificationName: Notification.Name {
            switch self {
            case .scrollDown:
                return .clawlineScrollNotificationDownCommand
            case .scrollUp:
                return .clawlineScrollNotificationUpCommand
            }
        }
    }

    struct Spec: Equatable {
        let input: Character
        let modifiers: EventModifiers
        let action: Action
    }

    static func scrollSpecs(visibleNotificationCount: Int) -> [Spec] {
        KeyboardCommandBridge
            .hiddenNotificationSwiftUIFallbackSpecs(visibleNotificationCount: visibleNotificationCount)
            .compactMap { spec in
                switch spec.intent {
                case .notificationScrollForward:
                    return Spec(input: spec.input, modifiers: spec.modifiers, action: .scrollDown)
                case .notificationScrollBackward:
                    return Spec(input: spec.input, modifiers: spec.modifiers, action: .scrollUp)
                default:
                    return nil
                }
            }
    }
}

private struct CrossChatNotificationKeyboardShortcuts: View {
    let bubbles: [CrossChatNotificationBubble]
    let maxContainerHeight: CGFloat
    let replyPinSlotsBySourceChatId: [String: Int]
    let measuredHeightsBySourceChatId: [String: CGFloat]
    let keyboardOwnershipStore: KeyboardOwnershipStore
    let onDismissAll: () -> Void
    let onToggleDock: () -> Void

    private var visibleBubbles: [CrossChatNotificationBubble] {
        CrossChatNotificationOverlay.visibleBubbles(
            maxContainerHeight: maxContainerHeight,
            bubbles: bubbles,
            replyPinSlotsBySourceChatId: replyPinSlotsBySourceChatId,
            measuredHeightsBySourceChatId: measuredHeightsBySourceChatId
        )
    }

    var body: some View {
        if !visibleBubbles.isEmpty {
            ZStack {
                ForEach(Array(visibleBubbles.enumerated()), id: \.element.sourceChatId) { index, _ in
                    Button("") {
                        routeAssignedShortcut(.notificationAssignedOpen(index), index: index) {
                            NotificationCenter.default.post(
                                name: .clawlineOpenNotificationActionMenuCommand,
                                object: index
                            )
                        }
                    }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    Button("") {
                        routeAssignedShortcut(.notificationAssignedReply(index), index: index) {
                            NotificationCenter.default.post(
                                name: .clawlineReplyNotificationCommand,
                                object: index
                            )
                        }
                    }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command, .shift])
                    Button("") {
                        routeAssignedShortcut(.notificationAssignedDismiss(index), index: index) {
                            NotificationCenter.default.post(
                                name: .clawlineDismissNotificationCommand,
                                object: index
                            )
                        }
                    }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command, .shift, .option])
                }
                Button("") {
                    routeNotificationStackShortcut(.notificationDismissAll) {
                        onDismissAll()
                    }
                }
                    .keyboardShortcut("-", modifiers: .command)
                Button("") {
                    routeNotificationStackShortcut(.notificationToggleDock) {
                        onToggleDock()
                    }
                }
                    .keyboardShortcut("\\", modifiers: .command)
                ForEach(
                    Array(CrossChatNotificationGlobalShortcut.scrollSpecs(visibleNotificationCount: visibleBubbles.count).enumerated()),
                    id: \.offset
                ) { _, spec in
                    Button("") {
                        routeScrollShortcut(spec)
                    }
                    .keyboardShortcut(KeyEquivalent(spec.input), modifiers: spec.modifiers)
                }
            }
            .opacity(0.001)
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
    }

    private func routeAssignedShortcut(
        _ intent: KeyboardCommandIntent,
        index: Int,
        perform action: () -> Void
    ) {
        guard visibleBubbles.indices.contains(index),
              case .handled(.notificationBubble(_)) = KeyboardCommandRouter
                .route(intent: intent, store: keyboardOwnershipStore)
                .outcome else { return }
        action()
    }

    private func routeScrollShortcut(_ spec: CrossChatNotificationGlobalShortcut.Spec) {
        let intent: KeyboardCommandIntent
        switch spec.action {
        case .scrollDown:
            intent = .notificationScrollForward
        case .scrollUp:
            intent = .notificationScrollBackward
        }
        guard case .handled(.notificationBubble(_)) = KeyboardCommandRouter
            .route(intent: intent, store: keyboardOwnershipStore)
            .outcome else { return }
        NotificationCenter.default.post(name: spec.action.notificationName, object: nil)
    }

    private func routeNotificationStackShortcut(
        _ intent: KeyboardCommandIntent,
        perform action: () -> Void
    ) {
        guard case .handled(.notificationBubble(_)) = KeyboardCommandRouter
            .route(intent: intent, store: keyboardOwnershipStore)
            .outcome else { return }
        action()
    }
}

private final class PreviewUploadService: UploadServicing {
    func upload(data: Data, mimeType: String, filename: String?) async throws -> String { "preview-asset" }
    func download(assetId: String) async throws -> Data { Data() }
}

#Preview("Empty Chat") {
    let device = PreviewDevice()
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    let toastManager = ToastManager()
    let viewModel = ChatViewModel(
        auth: auth,
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: toastManager,
        salientHighlightService: SalientHighlightService()
    )
    return ChatView(
        viewModel: viewModel,
        toastManager: toastManager
    )
    .environment(auth)
}

#Preview("With Messages") {
    let device = PreviewDevice()
    let auth = AuthManager()
    auth.storeCredentials(token: "preview-token", userId: "preview-user")
    auth.updateAdminStatus(true)
    let toastManager = ToastManager()
    let viewModel = ChatViewModel(
        auth: auth,
        chatService: PreviewChatService(),
        settings: SettingsManager(),
        device: device,
        uploadService: PreviewUploadService(),
        toastManager: toastManager,
        salientHighlightService: SalientHighlightService()
    )
    return ChatView(
        viewModel: viewModel,
        toastManager: toastManager
    )
    .environment(auth)
}
