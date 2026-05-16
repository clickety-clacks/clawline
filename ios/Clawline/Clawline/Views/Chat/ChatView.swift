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
import os.log

private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "ChatView")

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
        .handleKeyboardScrollCommands(
            isEnabled: keyboardScrollShortcutEnabled,
            onScrollDown: { scrollVisibleBubbleContents(.down) },
            onScrollUp: { scrollVisibleBubbleContents(.up) },
            onScrollChatDown: { scrollChatSurface(.down) },
            onScrollChatUp: { scrollChatSurface(.up) }
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

        ZStack(alignment: .top) {
            messageLayer
                // #31: fade out message content behind the system status bar (mask, not overlay tint).
                .compositingGroup()
                .mask(statusBarFadeMask(topInset: statusBarTopInset))

            streamToastView(
                inputBarTopFromScreenBottom: inputBarTopFromScreenBottom
            )
            toastBannerView(geometry: geometry, toastManager: toastManager)
        }
        .ignoresSafeArea(.keyboard)
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
                belowBarGap: belowBarGap,
                isKeyboardVisible: isKeyboardVisible,
                layoutKey: layoutKey,
                streamSelectorMaxHeight: streamSelectorMaxHeight
            )
        }
        .overlay(alignment: .bottom) {
#if os(visionOS)
            // visionOS: keep the scroll-to-bottom button in the main SwiftUI overlay.
            // iOS/iPadOS: we pin it to the UIKit keyboardLayoutGuide via KeyboardPinnedContainerView.
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
#else
            EmptyView()
#endif
        }
        .modifier(
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
                }
            )
        )
        .modifier(
            CancelCurrentPromptConfirmationModifier(
                isPresented: $isCancelCurrentPromptDialogPresented,
                anchorFrame: cancelCurrentPromptAnchorFrame,
                canCancel: cancelCurrentPromptDialogCanCancel,
                canPresentCommand: viewModel.canCancelCurrentPrompt,
                onPresentCommand: { presentCancelCurrentPromptDialog() },
                onConfirm: {
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
            )
        )
#if DEBUG
        .overlay(alignment: .topTrailing) {
            lifecycleDebugOverlay(
                viewModel: viewModel,
                containerHeight: geometry.size.height
            )
        }
#endif
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
                                 belowBarGap: CGFloat,
                                 isKeyboardVisible: Bool,
                                 layoutKey: ChatLayoutKey,
                                 streamSelectorMaxHeight: CGFloat) -> some View {
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
        let pinnedScrollButtonIsVisible = state.isVisible
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
                isStagingAttachments: viewModel.pendingAttachmentStageCount > 0,
                connectionStateStore: inputBarSendButtonConnectionState,
                focusTrigger: focusRequestID,
                bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                isKeyboardVisible: isKeyboardVisible,
                isAttachmentMenuPresented: $isAttachmentMenuPresented,
                onSend: {
                    clearTypingActivity()
                    viewModel.send()
                },
                onCancel: { viewModel.cancelSend() },
                onReconnect: { viewModel.reconnect() },
                onAdd: {
                    isAttachmentMenuPresented = true
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
                    recordTypingActivity()
                },
                onPasteImages: handlePastedImages,
                isCompact: horizontalSizeClass == .compact
            )
        }
        .visionOSInputBarDepthOffset()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
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
        let dotStatesBySession = Dictionary(
            uniqueKeysWithValues: effectiveSessionKeys.map { ($0, viewModel.streamDotState(for: $0)) }
        )
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
            dotStatesBySession: dotStatesBySession,
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
        ChatKeyboardScrollRouting.isEnabled(
            platformSupportsKeyboardNavigation: supportsKeyboardNavigationShortcuts,
            streamPopupRoute: streamPopupRouteController.route,
            activeSheetPresented: activeSheet != nil || isAttachmentMenuPresented,
            photosPickerPresented: isPhotosPickerPresented,
            fileImporterPresented: isFileImporterPresented
        )
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

private struct StreamPopupTrigger: View {
    @Bindable var routeController: StreamPopupRouteController

    let viewModel: ChatViewModel
    let streams: [StreamSession]
    let sessionKeys: [String]
    let activeSessionKey: String
    let dotStatesBySession: [String: StreamDotState]
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
            dotStatesBySession: dotStatesBySession,
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
                dotStatesBySession: dotStatesBySession,
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
            .presentationBackground(.clear)
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
        onScrollDown: @escaping () -> Void,
        onScrollUp: @escaping () -> Void,
        onScrollChatDown: @escaping () -> Void,
        onScrollChatUp: @escaping () -> Void
    ) -> some View {
        modifier(
            KeyboardScrollCommandModifier(
                isEnabled: isEnabled,
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
    let onScrollDown: () -> Void
    let onScrollUp: () -> Void
    let onScrollChatDown: () -> Void
    let onScrollChatUp: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollDownCommand)) { _ in
                guard isEnabled, !UIWindow.clawlineCurrentFirstResponderOwnsEmbeddedScroll else { return }
                onScrollDown()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollUpCommand)) { _ in
                guard isEnabled, !UIWindow.clawlineCurrentFirstResponderOwnsEmbeddedScroll else { return }
                onScrollUp()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollChatDownCommand)) { _ in
                guard isEnabled, !UIWindow.clawlineCurrentFirstResponderOwnsEmbeddedScroll else { return }
                onScrollChatDown()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clawlineScrollChatUpCommand)) { _ in
                guard isEnabled, !UIWindow.clawlineCurrentFirstResponderOwnsEmbeddedScroll else { return }
                onScrollChatUp()
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

    func body(content: Content) -> some View {
        content.background {
            PromptFocusShortcutHost(
                isEnabled: isEnabled,
                hasStreams: hasStreams,
                onOpenStreamPopup: onOpenStreamPopup,
                onFocusRequested: onFocusRequested,
                onTextInserted: onTextInserted
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

    func makeUIView(context: Context) -> PromptFocusShortcutView {
        let view = PromptFocusShortcutView()
        view.onOpenStreamPopup = onOpenStreamPopup
        view.onFocusRequested = onFocusRequested
        view.onTextInserted = onTextInserted
        view.isShortcutEnabled = isEnabled
        view.hasStreams = hasStreams
        return view
    }

    func updateUIView(_ view: PromptFocusShortcutView, context: Context) {
        view.onOpenStreamPopup = onOpenStreamPopup
        view.onFocusRequested = onFocusRequested
        view.onTextInserted = onTextInserted
        view.isShortcutEnabled = isEnabled
        view.hasStreams = hasStreams
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
        let appCommandShortcuts = ChatAppCommandShortcut.keyCommandSpecs.map { spec in
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
        guard isShortcutEnabled else { return }
        onFocusRequested?()
    }

    @objc private func openStreamPopup(_ sender: UIKeyCommand) {
        guard isShortcutEnabled, hasStreams else { return }
        onOpenStreamPopup?()
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
    enum Action {
        case focusPromptInput
        case openStreamPopup
        case navigatePreviousStream
        case navigateNextStream
        case scrollDown
        case scrollUp
        case scrollChatDown
        case scrollChatUp

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
            }
        }
    }

    struct KeyCommandSpec {
        let input: String
        let modifierFlags: UIKeyModifierFlags
        let action: Action
    }

    static let keyCommandSpecs: [KeyCommandSpec] = [
        KeyCommandSpec(input: "l", modifierFlags: [.command], action: .focusPromptInput),
        KeyCommandSpec(input: ";", modifierFlags: [.command], action: .openStreamPopup),
        KeyCommandSpec(input: "h", modifierFlags: [.command, .shift], action: .navigatePreviousStream),
        KeyCommandSpec(input: "l", modifierFlags: [.command, .shift], action: .navigateNextStream),
        KeyCommandSpec(input: "j", modifierFlags: [.command], action: .scrollDown),
        KeyCommandSpec(input: "k", modifierFlags: [.command], action: .scrollUp),
        KeyCommandSpec(input: "j", modifierFlags: [.command, .shift], action: .scrollChatDown),
        KeyCommandSpec(input: "k", modifierFlags: [.command, .shift], action: .scrollChatUp)
    ]
}

enum ChatShortcutRouting {
    enum Owner: Equatable {
        case appCommand
        case noTextResponder
        case textInput
    }

    static func owner(input: String, modifierFlags: UIKeyModifierFlags) -> Owner {
        let normalizedInput = input.lowercased()
        if modifierFlags == [.command], normalizedInput == ";" {
            return .appCommand
        }
        if modifierFlags == [.command], normalizedInput == "l" {
            return .appCommand
        }
        if modifierFlags == [.command, .shift], ["h", "l"].contains(normalizedInput) {
            return .appCommand
        }
        if modifierFlags == [.command], ["j", "k"].contains(normalizedInput) {
            return .appCommand
        }
        if modifierFlags == [.command, .shift], ["j", "k"].contains(normalizedInput) {
            return .appCommand
        }
        if modifierFlags.contains(.command) {
            return .textInput
        }
        return ["/", ";", " ", "\r"].contains(input) ? .noTextResponder : .textInput
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

enum ChatKeyboardScrollRouting {
    static func isEnabled(
        platformSupportsKeyboardNavigation: Bool,
        streamPopupRoute: StreamPopupRoute,
        activeSheetPresented: Bool,
        photosPickerPresented: Bool,
        fileImporterPresented: Bool
    ) -> Bool {
        platformSupportsKeyboardNavigation
            && streamPopupRoute == .closed
            && !activeSheetPresented
            && !photosPickerPresented
            && !fileImporterPresented
    }
}

extension UIResponder {
    @objc func clawlineFocusPromptInputCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineFocusPromptInputCommand, object: nil)
    }

    @objc func clawlineOpenStreamPopupCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineOpenStreamPopupCommand, object: nil)
    }

    @objc func clawlineNavigateToPreviousStreamCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineNavigateToPreviousStreamCommand, object: nil)
    }

    @objc func clawlineNavigateToNextStreamCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineNavigateToNextStreamCommand, object: nil)
    }

    @objc func clawlineScrollDownCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineScrollDownCommand, object: nil)
    }

    @objc func clawlineScrollUpCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineScrollUpCommand, object: nil)
    }

    @objc func clawlineScrollChatDownCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineScrollChatDownCommand, object: nil)
    }

    @objc func clawlineScrollChatUpCommand(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .clawlineScrollChatUpCommand, object: nil)
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
        scrollButtonHost?.view.isHidden = (view == nil)
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
#if os(visionOS)
    @Environment(\.dismiss) private var dismiss
#endif

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
        3
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
#if os(visionOS)
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .font(.clawline(.uiLabel).weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .frame(height: rowHeight, alignment: .center)
            .padding(.horizontal, rowHorizontalInset)
#endif
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
