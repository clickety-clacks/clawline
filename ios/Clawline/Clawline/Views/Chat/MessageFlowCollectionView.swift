//
//  MessageFlowCollectionView.swift
//  Clawline
//
//  Created by Codex on 1/18/26.
//

import OSLog
import SwiftUI
import UIKit

enum MessageFlowScrollEvent: Equatable {
    case isAtBottomChanged(sessionKey: String, isAtBottom: Bool)
    case transcriptScrollActiveChanged(sessionKey: String, isActive: Bool)
    case didReceiveNewMessagesWhileScrolledUp(sessionKey: String, newMessageIDs: [String])
    case didCrossFirstUnreadCenter(sessionKey: String, messageId: String)
    case didInvalidateFirstUnreadAnchor(sessionKey: String)
}

enum TypingIndicatorMorph {
    static func shouldMorph(
        wasShowingTypingIndicator: Bool,
        targetMessageId: String?,
        insertedIds: Set<String>
    ) -> Bool {
        guard wasShowingTypingIndicator,
              let targetMessageId else {
            return false
        }
        return insertedIds.contains(targetMessageId)
    }
}

enum ShowOnlyUserMessagesChatCollapse {
    static let animationDuration: TimeInterval = 0.3
    static let normalMenuLabel = "Hide Assistant Messages"
    static let collapsedMenuLabel = "Show Only User Messages"

    static func menuLabel(isCollapsed: Bool) -> String {
        isCollapsed ? collapsedMenuLabel : normalMenuLabel
    }

    static func visibleMessages(from messages: [Message], isCollapsed: Bool) -> [Message] {
        guard isCollapsed else { return messages }
        return messages.filter { $0.role == .user }
    }

    static func doubledCount(_ count: Int, isCollapsed: Bool) -> Int {
        isCollapsed ? count * 2 : count
    }
}

enum StreamMessageSearch {
    static func filteredMessages(from messages: [Message], query: String) -> [Message] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return messages }
        return messages.filter { $0.content.localizedStandardContains(trimmedQuery) }
    }
}

enum ChatDateLabelCalendar {
    static func startOfDay(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.startOfDay(for: date)
    }

    static func isSameDay(_ left: Date, _ right: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.isDate(left, inSameDayAs: right)
    }

    static func isYesterday(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}

enum ChatVisibleBubbleContentScroll {
    static var lineIncrement: CGFloat {
        ceil(UIFont.clawline(.bodyText).lineHeight + 4)
    }

    static let commandIncrement: CGFloat = 224

    @discardableResult
    static func scrollVisibleScrollableContent(
        in root: UIView,
        visibleIn viewport: UIView,
        direction: ChatScrollPageDirection,
        animated: Bool
    ) -> Int {
        root.layoutIfNeeded()
        let scrollViews = topLevelVisibleVerticalScrollViews(in: root, visibleIn: viewport)
        var scrolledCount = 0
        for scrollView in scrollViews {
            if scroll(scrollView, direction: direction, animated: animated) {
                scrolledCount += 1
            }
        }
        return scrolledCount
    }

    static func topLevelVisibleVerticalScrollViews(in root: UIView, visibleIn viewport: UIView) -> [UIScrollView] {
        root.layoutIfNeeded()
        return topLevelVisibleVerticalScrollViews(in: root, visibleIn: viewport, ancestorScrollAccepted: false)
    }

    private static func topLevelVisibleVerticalScrollViews(
        in view: UIView,
        visibleIn viewport: UIView,
        ancestorScrollAccepted: Bool
    ) -> [UIScrollView] {
        guard !view.isHidden, view.alpha > 0.01 else { return [] }

        let viewIsAcceptedScroll = (view as? UIScrollView).map { scrollView in
            isVisible(scrollView, in: viewport) && isVerticallyScrollable(scrollView)
        } ?? false

        if !ancestorScrollAccepted, viewIsAcceptedScroll, let scrollView = view as? UIScrollView {
            return [scrollView]
        }

        return view.subviews.flatMap { child in
            topLevelVisibleVerticalScrollViews(
                in: child,
                visibleIn: viewport,
                ancestorScrollAccepted: ancestorScrollAccepted || viewIsAcceptedScroll
            )
        }
    }

    private static func scroll(
        _ scrollView: UIScrollView,
        direction: ChatScrollPageDirection,
        animated: Bool
    ) -> Bool {
        let inset = scrollView.contentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard visibleHeight > 1, maxY > minY else { return false }

        let pageIncrement = max(80, visibleHeight * 0.82)
        let increment = min(commandIncrement, max(1, pageIncrement - 1))
        let delta = direction == .down ? increment : -increment
        let targetY = min(max(scrollView.contentOffset.y + delta, minY), maxY)
        guard abs(targetY - scrollView.contentOffset.y) > 0.5 else { return false }

        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: animated)
        return true
    }

    private static func isVerticallyScrollable(_ scrollView: UIScrollView) -> Bool {
        guard scrollView.isScrollEnabled else { return false }
        guard scrollView.bounds.height > 1 else { return false }
        let inset = scrollView.contentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        return maxY > minY + 0.5
    }

    private static func isVisible(_ view: UIView, in viewport: UIView) -> Bool {
        guard view.window != nil || viewport.window == nil else { return false }
        let rect = view.convert(view.bounds, to: viewport)
        return rect.width > 1 && rect.height > 1 && viewport.bounds.intersects(rect)
    }
}

@MainActor
struct MessageFlowCollectionView: UIViewControllerRepresentable {
    var viewModel: ChatViewModel
    var topInset: CGFloat
    var isCompact: Bool
    var isActiveSession: Bool
    var isRenderPolicyFrozen: Bool
    var isInputActive: Bool
    var keepsKeyboardPinned: Bool = false
    var isTypingActive: Bool
    var truncationBottomInset: CGFloat
    var trailingContentInset: CGFloat = 0
    var firstUnreadMessageId: String?
    var unreadCount: Int
    var onExpand: ((Message) -> Void)?
    var onOpenDetail: ((Message) -> Void)?
    var layoutCoordinator: ChatLayoutCoordinator
    var shouldRegisterWithLayoutCoordinator: Bool = true
    /// Optional session override - if provided, shows messages for this session instead of activeSessionKey
    var sessionKey: String?
    var sessionStatus: SessionStatus?
    var sessionStatusUnavailable: Bool = false
    var streamSearchQuery: String = ""
    var messageProjectionPublicationSequence: Int = 0
    var forceReReadGeneration: Int = 0
    var sendIndicatorRevision: Int = 0
    var fontScaleChangeSequence: Int = 0
    var onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)?
    var onTypingIndicatorTap: (@MainActor (CGRect) -> Void)?
    var onTypingIndicatorAnchorFrameChanged: (@MainActor (CGRect?) -> Void)? = nil
    var onSessionControlSelected: (@MainActor (String, SessionControlAction, String?, Bool?) -> Void)?
    var onFooterTestMenuSelected: (@MainActor (FooterTestMenuAction) -> Void)?
    var onInsertMessageIntoPrompt: (@MainActor (Message) -> Void)?
    var onReferenceMessageInPrompt: (@MainActor (Message) -> Void)?
    var onShowOnlyUserMessagesModeChanged: (@MainActor (String, Bool) -> Void)?
    var onStreamSearchQueryChanged: (@MainActor (String, String) -> Void)?
    var onKeyboardDismissModeChanged: (@MainActor (String) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.allowsTransparentWindowBackground) private var allowsTransparentWindowBackground

#if !os(visionOS)
    static func keyboardDismissModeForInputFocus(
        _ isInputActive: Bool,
        keepsKeyboardPinned: Bool
    ) -> UIScrollView.KeyboardDismissMode {
        let _ = isInputActive
        return keepsKeyboardPinned ? .none : .interactive
    }
#endif

    func makeUIViewController(context _: Context) -> MessageFlowCollectionViewController {
        let controller = MessageFlowCollectionViewController()
        let isDark = colorScheme == .dark
        controller.prepareInitialAppearance(
            isDark: isDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
        controller.loadViewIfNeeded()
        controller.update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            keepsKeyboardPinned: keepsKeyboardPinned,
            isTypingActive: isTypingActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            trailingContentInset: trailingContentInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            onOpenDetail: onOpenDetail,
            sessionKey: sessionKey,
            sessionStatus: sessionStatus,
            sessionStatusUnavailable: sessionStatusUnavailable,
            streamSearchQuery: streamSearchQuery,
            forceReReadGeneration: forceReReadGeneration,
            sendIndicatorRevision: sendIndicatorRevision,
            fontScaleChangeSequence: fontScaleChangeSequence,
            onScrollEvent: onScrollEvent,
            onTypingIndicatorTap: onTypingIndicatorTap,
            onTypingIndicatorAnchorFrameChanged: onTypingIndicatorAnchorFrameChanged,
            onSessionControlSelected: onSessionControlSelected,
            onFooterTestMenuSelected: onFooterTestMenuSelected,
            onInsertMessageIntoPrompt: onInsertMessageIntoPrompt,
            onReferenceMessageInPrompt: onReferenceMessageInPrompt,
            onShowOnlyUserMessagesModeChanged: onShowOnlyUserMessagesModeChanged,
            onStreamSearchQueryChanged: onStreamSearchQueryChanged,
            onKeyboardDismissModeChanged: onKeyboardDismissModeChanged,
            isDark: isDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
        if shouldRegisterWithLayoutCoordinator, let sessionKey {
            layoutCoordinator.registerListView(controller, sessionKey: sessionKey)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MessageFlowCollectionViewController, context _: Context) {
        _ = messageProjectionPublicationSequence
        let isDark = colorScheme == .dark
        uiViewController.update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            keepsKeyboardPinned: keepsKeyboardPinned,
            isTypingActive: isTypingActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            trailingContentInset: trailingContentInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            onOpenDetail: onOpenDetail,
            sessionKey: sessionKey,
            sessionStatus: sessionStatus,
            sessionStatusUnavailable: sessionStatusUnavailable,
            streamSearchQuery: streamSearchQuery,
            forceReReadGeneration: forceReReadGeneration,
            sendIndicatorRevision: sendIndicatorRevision,
            fontScaleChangeSequence: fontScaleChangeSequence,
            onScrollEvent: onScrollEvent,
            onTypingIndicatorTap: onTypingIndicatorTap,
            onTypingIndicatorAnchorFrameChanged: onTypingIndicatorAnchorFrameChanged,
            onSessionControlSelected: onSessionControlSelected,
            onFooterTestMenuSelected: onFooterTestMenuSelected,
            onInsertMessageIntoPrompt: onInsertMessageIntoPrompt,
            onReferenceMessageInPrompt: onReferenceMessageInPrompt,
            onShowOnlyUserMessagesModeChanged: onShowOnlyUserMessagesModeChanged,
            onStreamSearchQueryChanged: onStreamSearchQueryChanged,
            onKeyboardDismissModeChanged: onKeyboardDismissModeChanged,
            isDark: isDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
        if shouldRegisterWithLayoutCoordinator, let sessionKey {
            layoutCoordinator.registerListView(uiViewController, sessionKey: sessionKey)
        }
    }
}

enum FooterTestMenuAction {
    case settings
    case logout
}

final class MessageFlowCollectionViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    private struct UpdateRequest {
        let viewModel: ChatViewModel
        let isCompact: Bool
        let isActiveSession: Bool
        let isRenderPolicyFrozen: Bool
        let isInputActive: Bool
        let keepsKeyboardPinned: Bool
        let isTypingActive: Bool
        let topInset: CGFloat
        let truncationBottomInset: CGFloat
        let trailingContentInset: CGFloat
        let firstUnreadMessageId: String?
        let unreadCount: Int
        let onExpand: ((Message) -> Void)?
        let onOpenDetail: ((Message) -> Void)?
        let sessionKey: String?
        let sessionStatus: SessionStatus?
        let sessionStatusUnavailable: Bool
        let streamSearchQuery: String
        let forceReReadGeneration: Int
        let sendIndicatorRevision: Int
        let fontScaleChangeSequence: Int
        let onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)?
        let onTypingIndicatorTap: (@MainActor (CGRect) -> Void)?
        let onTypingIndicatorAnchorFrameChanged: (@MainActor (CGRect?) -> Void)?
        let onSessionControlSelected: (@MainActor (String, SessionControlAction, String?, Bool?) -> Void)?
        let onFooterTestMenuSelected: (@MainActor (FooterTestMenuAction) -> Void)?
        let onInsertMessageIntoPrompt: (@MainActor (Message) -> Void)?
        let onReferenceMessageInPrompt: (@MainActor (Message) -> Void)?
        let onShowOnlyUserMessagesModeChanged: (@MainActor (String, Bool) -> Void)?
        let onStreamSearchQueryChanged: (@MainActor (String, String) -> Void)?
        let onKeyboardDismissModeChanged: (@MainActor (String) -> Void)?
        let isDark: Bool?
        let allowsTransparentWindowBackground: Bool
    }

    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    private let typingCancelDiagnosticLogger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "T217TypingCancel")
    private static var t217DiagnosticBuild: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "T217-typing-cancel-\(build)"
    }

    static func shouldUpdateCollectionFrame(current: CGRect, target: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(current.minX - target.minX) > tolerance ||
            abs(current.minY - target.minY) > tolerance ||
            abs(current.width - target.width) > tolerance ||
            abs(current.height - target.height) > tolerance
    }

    static func targetCollectionFrame(
        viewBounds: CGRect,
        windowBounds: CGRect?,
        viewOriginInWindow: CGPoint?,
        preservesHorizontallyConstrainedHostWidth: Bool = true,
        fillsHorizontallyConstrainedHostToWindow: Bool = false,
        tolerance: CGFloat = 1
    ) -> CGRect {
        guard let windowBounds, let viewOriginInWindow else {
            return viewBounds
        }

        let isHorizontallyConstrained = viewBounds.width < windowBounds.width - tolerance
        if fillsHorizontallyConstrainedHostToWindow && isHorizontallyConstrained {
            return CGRect(
                x: -viewOriginInWindow.x,
                y: -viewOriginInWindow.y,
                width: windowBounds.width,
                height: windowBounds.height
            )
        }

        let width = preservesHorizontallyConstrainedHostWidth && isHorizontallyConstrained
            ? viewBounds.width
            : windowBounds.width
        return CGRect(
            x: 0,
            y: -viewOriginInWindow.y,
            width: width,
            height: windowBounds.height
        )
    }

    static func flowSectionInset(containerPadding: CGFloat, trailingContentInset: CGFloat) -> UIEdgeInsets {
        UIEdgeInsets(
            top: containerPadding,
            left: containerPadding,
            bottom: containerPadding,
            right: containerPadding + max(0, trailingContentInset)
        )
    }

    private var collectionView: UICollectionView!
    private var channelOverride: String?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var flowLayout: MessageFlowLayout!
    private let uiKitBubbleSizer = MessageBubbleUIKitView(enableDataDetectors: false)
    private var currentIsDark: Bool = true
    private var allowsTransparentWindowBackground = false
    private var currentSendIndicatorRevision: Int = 0
    private let bubbleSizingV2Enabled = BubbleSizingV2.isEnabled
    private let bubbleSizingV2MeasurementCache = BubbleSizingV2.LRUCache<BubbleSizingV2.CacheKey, BubbleSizingV2.Measurement>(maxEntries: 800)
    private let bubbleSizingV2LayoutStateCache = BubbleSizingV2.LRUCache<BubbleSizingV2.CacheKey, BubbleSizingV2.LayoutState>(maxEntries: 800)
    private let bubbleSizingV2LinkPreviewHeightCache = BubbleSizingV2.LinkPreviewHeightCache()
    private struct ScrollSnapshot: Equatable {
        var atBottom: Bool
        var distanceFromBottom: CGFloat
        var timestamp: TimeInterval
    }

    private enum RestorePhase: Equatable {
        case none
        case pendingTail
        case pendingFullConfirmation
        case confirmed
    }

    private var bubbleSizingV2LastScrollActivityTime: CFAbsoluteTime = 0
    private static let bubbleSizingV2RemeasureDebounceSeconds: TimeInterval = 0.45
    private static let bubbleSizingV2RemeasureMaxWaitSeconds: TimeInterval = 2.5
    private static let bubbleSizingV2RestSettleDelaySeconds: TimeInterval = 0.12
    private static let previewRemeasureRestPollSeconds: TimeInterval = 0.06
    private static let bottomInsetHeightCapInvalidationDebounceSeconds: TimeInterval = 0.20
    private static let restoreMaxConfirmationRetries: Int = 3
    private static let typingIndicatorTapTargetLeadingOutset: CGFloat = 8
    private static let typingIndicatorTapTargetTrailingOutset: CGFloat = 44

    static func chatPageBackgroundColor(
        isDark: Bool,
        allowsTransparentWindowBackground: Bool = false
    ) -> UIColor {
        if allowsTransparentWindowBackground {
            return .clear
        }
        return isDark ? .clear : UIColor(ChatFlowTheme.pageBackgroundTopColor(.light))
    }

    func prepareInitialAppearance(isDark: Bool, allowsTransparentWindowBackground: Bool) {
        currentIsDark = isDark
        self.allowsTransparentWindowBackground = allowsTransparentWindowBackground
        if isViewLoaded {
            applyChatPageBackground(isDark: isDark)
        }
    }

    private func reportKeyboardDismissModeIfNeeded() {
#if !os(visionOS)
        guard let onKeyboardDismissModeChanged else { return }
        let mode: String
        switch collectionView.keyboardDismissMode {
        case .none:
            mode = "none"
        case .interactive:
            mode = "interactive"
        case .onDrag:
            mode = "onDrag"
        @unknown default:
            mode = "unknown"
        }
        onKeyboardDismissModeChanged("keyboardDismissMode=\(mode);keyboardPinned=\(keepsKeyboardPinned ? 1 : 0)")
#endif
    }

    private var messagesById: [String: Message] = [:]
    private var dateSeparatorTextByItemId: [String: String] = [:]
    /// Substrate run-collapse (step 2): synthetic item id -> the message ids
    /// it summarizes, computed fresh each snapshot build (view-model DATA).
    private var substrateRunMemberIdsByItemId: [String: [String]] = [:]
    /// Transient UI state (never persisted): which collapsed-run anchor ids
    /// are currently expanded. Keyed by the run's synthetic item id.
    private var expandedSubstrateRunItemIds: Set<String> = []
    /// Message ids currently shown individually because their run is
    /// expanded (drives SubstrateRowCell's indent-under-run presentation).
    private var expandedRunMemberMessageIds: Set<String> = []
    /// Segment-anchor (step 3b): transient UI state (never persisted), toggled
    /// by tapping the marker divider. When true, everything before the last
    /// reliable boundary (ChatViewModel.lastReliableBoundaryTimestamp) is
    /// hidden from the snapshot.
    private var isSegmentAnchorActive: Bool = false
    private struct PerStreamRuntimeState {
        typealias MessageLoadCallback = @MainActor () -> Void

        var sbbState: SBBState = .atBottom
        var lastReportedHideIndicator: Bool?
        var lastSeenBottomInsetForSBB: CGFloat?

        var firstUnreadMessageId: String?
        var unreadCount: Int = 0
        var firstUnreadWasBelowViewportCenter: Bool?
        var didCrossAndClearFirstUnreadId: String?
        var pendingFlashMessageId: String?
        var pendingFlashIsUnreadTap: Bool = false
        var isShowingOnlyUserMessages: Bool = false

        var pendingScrollRestoreState: PersistedScrollState?
        var restorePhase: RestorePhase = .none
        var restoreGeneration: Int = 0
        var lastSeenForceReReadGeneration: Int = 0
        var restoredScrollGenerations: Set<Int> = []
        var restoreConfirmationRetries: Int = 0
        var lastKnownScrollSnapshot: ScrollSnapshot?
        var scrollStateWriteDebounceTimer: Timer?
        var suspendScrollPersistenceUntilRestoreConfirmed = false
        var registeredMessageLoadCallbacksByMessageId: [String: [MessageLoadCallback]] = [:]

        var lastMessageId: String?
        var pendingScrollToBottomAfterInteractionEnd: Bool = false
        var pendingScrollToBottomAttempts: Int = 0
        var pendingScrollToBottomAnimated: Bool = false
        var pendingScrollToBottomWorkItem: DispatchWorkItem?

        var wasShowingTypingIndicator: Bool = false
        var liveProgress: LiveAgentProgress?
        var morphTargetMessageId: String?
        var deferScrollToBottomUntilMorphCompletes = false

        var fingerprints: [String: Int] = [:]
        var sizeCache: [String: CGSize] = [:]
        var lastMeasuredSizes: [String: CGSize] = [:]
        var pendingReconfigureIds: Set<String> = []
        var dirtySizeIds: Set<String> = []
        var pendingEntranceAnimationIds: Set<String> = []

        var bubbleSizingV2KeysByMessageId: [String: Set<BubbleSizingV2.CacheKey>] = [:]
        var bubbleSizingV2LinkPreviewStateVersionByMessageId: [String: Int] = [:]
        var bubbleSizingV2RemeasureBatchStartTime: CFAbsoluteTime?
        var bubbleSizingV2RemeasureDeferredUntilNearBottom = false
        var bubbleSizingV2PendingRemeasureIds: Set<String> = []
        var bubbleSizingV2PendingLiveMeasurementIds: Set<String> = []
        var bubbleSizingV2AcceptedRemeasureKeys: Set<BubbleSizingV2AcceptedRemeasureKey> = []
        var bubbleSizingV2ScrollSettleEpoch: UInt64 = 0
        var bubbleSizingV2RemeasureDebounceTimer: Timer?
        var bubbleSizingV2DeferredFlushTimer: Timer?
        var deferredPreviewRemeasureIds: Set<String> = []
        var deferredPreviewRemeasureTimer: Timer?

        var deferredBottomInsetRemeasureIds: Set<String> = []
        var bottomInsetRemeasureTimer: Timer?
        var pendingBottomInsetHeightCapInvalidation: DispatchWorkItem?
        var lastAppliedMessageSetIdentity: MessageSetIdentity?
    }

    private struct MessageSetIdentity: Equatable {
        let sessionKey: String
        let messageCount: Int
        let lastMessageId: String?
        let messageListRevision: Int
        let messageProjectionPublicationSequence: Int
        let isShowingOnlyUserMessages: Bool
        let streamSearchQuery: String
        let firstUnreadMessageId: String?
        let unreadCount: Int
        let sessionStatus: SessionStatus?
        let liveProgress: LiveAgentProgress?
        let forceReReadGeneration: Int
        let sendIndicatorRevision: Int
        let fontScaleChangeSequence: Int
        let isCompact: Bool
        let topInset: CGFloat
        let trailingContentInset: CGFloat
        let truncationBottomInset: CGFloat
        let allowsTransparentWindowBackground: Bool
        let isDark: Bool?
    }

    private var perStreamStateBySessionKey: [String: PerStreamRuntimeState] = [:]
    private var isUpdatePassInFlight = false
    private var isSnapshotApplyInFlight = false
    private var queuedUpdateRequest: UpdateRequest?
    private var queuedDiffableSnapshotApplies: [() -> Void] = []
    private var isWebBubbleSnapshotApplyQueued = false
    private var lastAppliedEffectiveSessionKey: String?
    private var invalidationScheduled = false
    private var viewModel: ChatViewModel?
    private var messageRemovalObserverToken: UUID?
    private var isCompact: Bool = true
    private var isActiveSession: Bool = true
    private var isRenderPolicyFrozen: Bool = false
    private var isInputActive: Bool = false
    private var keepsKeyboardPinned: Bool = false
    private var isTypingActive: Bool = false
    private var sessionStatus: SessionStatus?
    private var sessionStatusUnavailable = false
    private var liveProgress: LiveAgentProgress?
    private var topInset: CGFloat = 0
    private var truncationBottomInset: CGFloat = 0
    private var trailingContentInset: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var lastMeasurementContentWidth: CGFloat?
    private var lastMeasurementMetricsFingerprint: Int?
    private var pendingBoundsChange = false
    private var forceReconfigureAll = false
    /// Last tightbeam gate value this controller rendered with. Controller-owned
    /// because the view model instance is stable across updates.
    private var currentIsTightbeam: Bool?
    /// Last harness options this controller rendered with, controller-owned for
    /// the same reason.
    private var currentHarnessOptions: [String]?
    private var currentFontScaleChangeSequence: Int = 0
    private var onExpand: ((Message) -> Void)?
    private var onOpenDetail: ((Message) -> Void)?
    private var onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)?
    private var onTypingIndicatorTap: (@MainActor (CGRect) -> Void)?
    private var onTypingIndicatorAnchorFrameChanged: (@MainActor (CGRect?) -> Void)?
    private var lastReportedTypingIndicatorAnchorFrame: CGRect?
    private var onSessionControlSelected: (@MainActor (String, SessionControlAction, String?, Bool?) -> Void)?
    private var onFooterTestMenuSelected: (@MainActor (FooterTestMenuAction) -> Void)?
    private var onInsertMessageIntoPrompt: (@MainActor (Message) -> Void)?
    private var onReferenceMessageInPrompt: (@MainActor (Message) -> Void)?
    private var onShowOnlyUserMessagesModeChanged: (@MainActor (String, Bool) -> Void)?
    private var onStreamSearchQueryChanged: (@MainActor (String, String) -> Void)?
    private var onKeyboardDismissModeChanged: (@MainActor (String) -> Void)?
    private let webBubbleCoordinator = WebBubbleCoordinator()
    private var lastMessages: [Message] = []
    private var activeWindowReachesProjectionTail = true
    private var streamSearchQuery = ""
    private var lastEffectiveStream: ChatStream?
    private var showOnlyUserMessagesTransitionSessionKeys: Set<String> = []
    private var pendingShowOnlyUserMessagesRevealTargetBySessionKey: [String: String] = [:]
    private struct PendingDirectNavigation {
        let messageId: String
        let animated: Bool
        let flash: Bool
    }
    private var pendingDirectNavigationBySessionKey: [String: PendingDirectNavigation] = [:]
    private var pendingTranscriptTruthBottomBySessionKey: [String: Bool] = [:]
    // Bounded stream materialization. The view model owns complete transcript truth;
    // this controller owns only a fixed projection window.
    // WHY N=50: device measurements showed 500-item first apply taking 1.4-2.7s.
    // A 50-item first paint targets ~10% of that cost while still showing meaningful recent context.
    static let stagedMaterializationTailWindowCount = 50

    static func stagedMaterializationTailWindowCount(isShowingOnlyUserMessages: Bool) -> Int {
        ShowOnlyUserMessagesChatCollapse.doubledCount(
            stagedMaterializationTailWindowCount,
            isCollapsed: isShowingOnlyUserMessages
        )
    }

    static func maximumBoundedSnapshotItemCount(messageWindowCount: Int) -> Int {
        (messageWindowCount * 3) + 2
    }

#if DEBUG
    struct DebugBoundedMaterializationProbe {
        let snapshotItemCount: Int
        let sizeQueryCount: Int
        let messageCount: Int
        let dateSeparatorCount: Int
        let webBubbleCount: Int
        let typingIndicatorCount: Int
        let footerCount: Int
    }

    enum DebugMaterializationProjection {
        case transcript
        case userOnly
        case transcriptSearch(String)
        case userOnlySearch(String)
    }

    enum DebugMaterializationEvent {
        case messagesUpdated(totalCount: Int, followsTail: Bool)
        case messagesUpdatedWithUnread(totalCount: Int, unreadIndex: Int, followsTail: Bool)
        case shifted(lowerBound: Int, totalCount: Int, anchorMessageID: String?)
        case edgeShift(older: Bool, residual: CGFloat?)
        case directTarget(index: Int, totalCount: Int, messageID: String)
        case projectionEdge(tail: Bool)
    }

    struct DebugMaterializationState: Equatable {
        let lowerBound: Int
        let upperBound: Int
        let logicalTotalCount: Int
        let revision: Int
        let unreadOutsideWindow: Bool
        let pendingAction: String?
        let hasViewportAnchor: Bool
    }

    func debugBoundedMaterializationProbe() -> DebugBoundedMaterializationProbe {
        let layout = collectionView.collectionViewLayout as? MessageFlowLayout
        let itemIDs = dataSource.snapshot().itemIdentifiers
        let dateSeparatorCount = itemIDs.count { $0.hasPrefix(DateSeparatorCell.itemIdPrefix) }
        let webBubbleCount = itemIDs.count { $0.hasPrefix("web_") }
        let typingIndicatorCount = itemIDs.count { $0 == TypingIndicatorCell.itemId }
        let footerCount = itemIDs.count { $0 == SessionMetadataFooterCell.itemId }
        return DebugBoundedMaterializationProbe(
            snapshotItemCount: itemIDs.count,
            sizeQueryCount: layout?.lastPrepareSizeQueryCount ?? 0,
            messageCount: itemIDs.count - dateSeparatorCount - webBubbleCount - typingIndicatorCount - footerCount,
            dateSeparatorCount: dateSeparatorCount,
            webBubbleCount: webBubbleCount,
            typingIndicatorCount: typingIndicatorCount,
            footerCount: footerCount
        )
    }

    @discardableResult
    func debugAdvanceMaterialization(
        sessionKey: String,
        projection: DebugMaterializationProjection? = nil,
        event: DebugMaterializationEvent
    ) -> DebugMaterializationState {
        if let projection {
            _ = enqueueMaterializationEvent(
                sessionKey: sessionKey,
                event: .projectionSelected(debugProjectionKey(projection))
            )
        }
        let productionEvent: MaterializationEvent = switch event {
        case let .messagesUpdated(totalCount, followsTail):
            .messagesUpdated(
                totalCount: totalCount,
                firstUnreadProjectedIndex: nil,
                followsProjectionTail: followsTail
            )
        case let .messagesUpdatedWithUnread(totalCount, unreadIndex, followsTail):
            .messagesUpdated(
                totalCount: totalCount,
                firstUnreadProjectedIndex: unreadIndex,
                followsProjectionTail: followsTail
            )
        case let .shifted(lowerBound, totalCount, anchorMessageID):
            .shifted(
                windowBounds: WindowBounds(lowerBound: lowerBound, upperBound: totalCount),
                totalCount: totalCount,
                viewportAnchor: anchorMessageID.map {
                    BubbleSizingV2ViewportAnchor(messageId: $0, contentOffsetY: 0, frameMinY: 0)
                },
                postApplyAction: nil
            )
        case let .edgeShift(older, residual):
            .edgeShift(
                direction: older ? .older : .newer,
                residual: residual,
                viewportAnchor: nil
            )
        case let .directTarget(index, totalCount, messageID):
            .directTarget(
                projectedIndex: index,
                totalCount: totalCount,
                action: .centerMessage(id: messageID, animated: false, flash: true)
            )
        case let .projectionEdge(tail):
            .projectionEdge(
                tail: tail,
                action: .scrollProjectionEdge(tail: tail, animated: false)
            )
        }
        _ = enqueueMaterializationEvent(sessionKey: sessionKey, event: productionEvent)
        return debugMaterializationState(sessionKey: sessionKey)
    }

    func debugCurrentMaterializationState(sessionKey: String) -> DebugMaterializationState {
        debugMaterializationState(sessionKey: sessionKey)
    }

    func debugRunMaterializationRefreshPass() {
        runMaterializationRefreshPass()
    }

    func debugSuppressAutomatedPostApplyScrolling(_ suppressed: Bool) {
        _debugSuppressAutomatedPostApplyScrolling = suppressed
    }

    func debugBumpRestoreGeneration(sessionKey: String) {
        mutateState(for: sessionKey) { $0.restoreGeneration &+= 1 }
    }

    func debugMaterializationApplyCounts(
        sessionKey: String
    ) -> (effectApplyCompletions: Int, compensationAttempts: Int) {
        (
            _debugEffectApplyCompletionCountBySessionKey[sessionKey, default: 0],
            _debugViewportCompensationAttemptCountBySessionKey[sessionKey, default: 0]
        )
    }

    func debugPersistMaterializationLocation(
        sessionKey: String,
        projection: DebugMaterializationProjection,
        lowerBound: Int,
        totalCount: Int,
        distanceFromBottom: CGFloat
    ) {
        _ = debugAdvanceMaterialization(
            sessionKey: sessionKey,
            projection: projection,
            event: .shifted(lowerBound: lowerBound, totalCount: totalCount, anchorMessageID: nil)
        )
        persistScrollSnapshot(
            ScrollSnapshot(
                atBottom: distanceFromBottom == 0,
                distanceFromBottom: distanceFromBottom,
                timestamp: Date().timeIntervalSince1970
            ),
            for: sessionKey
        )
    }

    func debugLoadPersistedMaterializationLocation(
        sessionKey: String,
        projection: DebugMaterializationProjection
    ) -> (base: String?, query: String?, lowerBound: Int?, distanceFromBottom: Double)? {
        let key = debugProjectionKey(projection)
        guard let state = loadPersistedScrollState(
            for: sessionKey,
            projectionBase: key.base == .userOnly ? "userOnly" : "transcript",
            searchQuery: key.searchQuery
        ) else { return nil }
        return (state.projectionBase, state.searchQuery, state.projectionLowerBound, state.distanceFromBottom)
    }

    func debugClearPersistedMaterializationLocations(
        sessionKey: String,
        projections: [DebugMaterializationProjection]
    ) {
        let defaults = UserDefaults.standard
        for projection in projections {
            let key = debugProjectionKey(projection)
            defaults.removeObject(forKey: scrollStateDefaultsKey(
                for: sessionKey,
                projectionBase: key.base == .userOnly ? "userOnly" : "transcript",
                searchQuery: key.searchQuery
            ))
        }
        defaults.removeObject(forKey: scrollStateDefaultsKey(for: sessionKey))
    }

    private func debugProjectionKey(_ projection: DebugMaterializationProjection) -> MaterializationProjectionKey {
        switch projection {
        case .transcript:
            MaterializationProjectionKey(base: .transcript, searchQuery: "")
        case .userOnly:
            MaterializationProjectionKey(base: .userOnly, searchQuery: "")
        case let .transcriptSearch(query):
            MaterializationProjectionKey(base: .transcript, searchQuery: query)
        case let .userOnlySearch(query):
            MaterializationProjectionKey(base: .userOnly, searchQuery: query)
        }
    }

    private func debugMaterializationState(sessionKey: String) -> DebugMaterializationState {
        let state = materializationStateBySessionKey[sessionKey]
        let effect = pendingMaterializationEffectBySessionKey[sessionKey]
        let pendingAction: String? = switch effect?.postApplyAction {
        case .scrollProjectionEdge(tail: true, animated: _): "tail"
        case .scrollProjectionEdge(tail: false, animated: _): "top"
        case .replayResidual: "residual"
        case .centerMessage: "center"
        case nil: nil
        }
        return DebugMaterializationState(
            lowerBound: state?.windowBounds.lowerBound ?? 0,
            upperBound: state?.windowBounds.upperBound ?? 0,
            logicalTotalCount: state?.logicalTotalCount ?? 0,
            revision: state?.revision ?? 0,
            unreadOutsideWindow: state?.unreadOutsideTailWindow ?? false,
            pendingAction: pendingAction,
            hasViewportAnchor: effect?.viewportAnchor != nil
        )
    }

    func debugInsertWebBubbleItems(_ items: [WebBubbleItem]) {
        items.forEach { webBubbleCoordinator.debugInsertItem($0) }
        applySnapshotForWebBubbles()
    }

    func debugSeedAuthoritativeRemovalState(
        sessionKey: String,
        messageId: String,
        callback: @escaping @MainActor () -> Void
    ) {
        withBoundSessionKey(sessionKey) {
            _ = writeMeasuredSize(
                messageId: messageId,
                measurement: CGSize(width: 100, height: 40)
            )
        }
        registerOnMessageLoad(sessionKey: sessionKey, messageId: messageId, callback: callback)
    }

    func debugAuthoritativeRemovalState(
        sessionKey: String,
        messageId: String
    ) -> (hasSize: Bool, callbackCount: Int) {
        let state = readState(for: sessionKey)
        return (
            state.sizeCache[messageId] != nil || state.lastMeasuredSizes[messageId] != nil,
            state.registeredMessageLoadCallbacksByMessageId[messageId]?.count ?? 0
        )
    }
#endif

    private enum MaterializationStage: String {
        case tail
        case full
    }

    private struct WindowBounds {
        var lowerBound: Int
        var upperBound: Int

        static let empty = WindowBounds(lowerBound: 0, upperBound: 0)
    }

    private struct MaterializationState {
        var stage: MaterializationStage
        var windowBounds: WindowBounds
        var unreadOutsideTailWindow: Bool
        var logicalTotalCount: Int
        var revision: Int
    }

    private enum MaterializationShiftDirection: Equatable {
        case older
        case newer
    }

    private enum MaterializationPostApplyAction {
        case scrollProjectionEdge(tail: Bool, animated: Bool)
        case replayResidual(CGFloat)
        case centerMessage(id: String, animated: Bool, flash: Bool)
    }

    private struct MaterializationEffect {
        let sessionKey: String
        let projectionKey: MaterializationProjectionKey
        let materializationRevision: Int
        let restoreGeneration: Int
        let viewportAnchor: BubbleSizingV2ViewportAnchor?
        let postApplyAction: MaterializationPostApplyAction?
    }

    private enum MaterializationEvent {
        case projectionSelected(MaterializationProjectionKey)
        case messagesUpdated(totalCount: Int,
                             firstUnreadProjectedIndex: Int?,
                             followsProjectionTail: Bool)
        case shifted(windowBounds: WindowBounds,
                     totalCount: Int,
                     viewportAnchor: BubbleSizingV2ViewportAnchor?,
                     postApplyAction: MaterializationPostApplyAction?)
        case edgeShift(direction: MaterializationShiftDirection,
                       residual: CGFloat?,
                       viewportAnchor: BubbleSizingV2ViewportAnchor?)
        case directTargetRequested(id: String, animated: Bool, flash: Bool)
        case directTargetCancelled
        case directTarget(projectedIndex: Int,
                          totalCount: Int,
                          action: MaterializationPostApplyAction)
        case transcriptTruthTargetRequested(animated: Bool)
        case projectionEdge(tail: Bool,
                            action: MaterializationPostApplyAction)
    }

    private struct MaterializationEventEnvelope {
        let sessionKey: String
        let event: MaterializationEvent
    }

    private struct MaterializationPlan {
        var stage: MaterializationStage
        var windowBounds: WindowBounds
        var unreadOutsideTailWindow: Bool
        var revision: Int
    }

    private struct MaterializationProjectionKey: Hashable {
        let base: MessageProjectionBase
        let searchQuery: String
    }

    private var materializationStateBySessionKey: [String: MaterializationState] = [:]
    private var materializationStateByProjectionBySessionKey: [String: [MaterializationProjectionKey: MaterializationState]] = [:]
    private var activeMaterializationProjectionKeyBySessionKey: [String: MaterializationProjectionKey] = [:]
    private var lastAppliedMaterializationRevisionBySessionKey: [String: Int] = [:]
    private var pendingMaterializationEffectBySessionKey: [String: MaterializationEffect] = [:]
#if DEBUG
    private var _debugEffectApplyCompletionCountBySessionKey: [String: Int] = [:]
    private var _debugViewportCompensationAttemptCountBySessionKey: [String: Int] = [:]
    private var _debugSuppressAutomatedPostApplyScrolling = false
#endif
    private var materializationEventQueue: [MaterializationEventEnvelope] = []
    private var isMaterializationQueueProcessing = false
    private var lastMaterializationPlanBySessionKey: [String: MaterializationPlan] = [:]
    // Typing indicator morph is a bespoke overlay animation. During the morph we must prevent
    // normal lifecycle behaviors from fighting it:
    // - `willDisplay` resets (alpha/transform) can overwrite our fade-in target cell state.
    // - auto scroll-to-bottom can start a concurrent scroll animation and re-layout mid-morph.

    // T036: Persist and restore scroll position per session key so app relaunch resumes where the user left off.
    // We store distance-from-bottom so async remeasures or new message insertions don't invalidate the anchor.
    private struct PersistedScrollState: Codable, Equatable {
        var atBottom: Bool
        var distanceFromBottom: Double
        var savedAtEpochSeconds: Double
        var projectionBase: String?
        var searchQuery: String?
        var projectionLowerBound: Int?
    }

    private static let scrollStateWriteDebounceSeconds: TimeInterval = 0.35
    // iPad mini 6th gen portrait reference size used as the max chat geometry envelope on large screens.
    private static let bubbleReferenceSize = CGSize(width: 744, height: 1133)
    /// Single source of truth for what “at bottom” means across:
    /// - SBB visibility
    /// - auto-scroll / pinned-to-bottom intent transitions
    /// - scroll-state persistence
    /// - keyboard/inset pinning decisions
    ///
    /// Keeping this unified avoids threshold mismatches (e.g. auto-scroll happens but SBB stays visible).
    static let atBottomThreshold: CGFloat = 24

    // State-machine-driven SBB visibility.
    // Note: we preserve the existing `isAtBottomChanged(isAtBottom:)` event as the visibility signal
    // (true => indicator hidden), but the underlying truth is `sbbState` with pinned intent.
    private enum SBBState: Equatable {
        case atBottom
        case atBottomDragging
        case scrolledUp
        case scrolledUpUnread

        var isPinnedToBottomIntent: Bool {
            switch self {
            case .atBottom, .atBottomDragging:
                return true
            case .scrolledUp, .scrolledUpUnread:
                return false
            }
        }

        var shouldHideIndicator: Bool {
            switch self {
            case .atBottom, .atBottomDragging:
                return true
            case .scrolledUp, .scrolledUpUnread:
                return false
            }
        }
    }

    private var isPostingSalientScrolling: Bool = false

    private func readState(for sessionKey: String) -> PerStreamRuntimeState {
        perStreamStateBySessionKey[sessionKey] ?? PerStreamRuntimeState()
    }

    private func mutateState(for sessionKey: String, _ body: (inout PerStreamRuntimeState) -> Void) {
        var state = perStreamStateBySessionKey[sessionKey] ?? PerStreamRuntimeState()
        body(&state)
        perStreamStateBySessionKey[sessionKey] = state
    }

    private func callbackSessionKey() -> String? {
        lastAppliedEffectiveSessionKey
    }

    private func activeSessionGenerationToken() -> (sessionKey: String, generation: Int)? {
        guard let sessionKey = callbackSessionKey() else { return nil }
        return (sessionKey, readState(for: sessionKey).restoreGeneration)
    }

    private func activeStateKey() -> String? {
        if let lastAppliedEffectiveSessionKey {
            return lastAppliedEffectiveSessionKey
        }
        if let channelOverride, !channelOverride.isEmpty {
            return channelOverride
        }
        return nil
    }

    @discardableResult
    private func withBoundSessionKey<T>(_ sessionKey: String, _ body: () -> T) -> T {
        let previous = lastAppliedEffectiveSessionKey
        lastAppliedEffectiveSessionKey = sessionKey
        defer { lastAppliedEffectiveSessionKey = previous }
        return body()
    }

    // Transitional accessors: existing call sites compile while state ownership moves
    // behind per-stream seams. All writes are session-keyed through `mutateState(for:_:)`.
    private var firstUnreadMessageId: String? {
        get { activeStateKey().flatMap { readState(for: $0).firstUnreadMessageId } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.firstUnreadMessageId = newValue }
        }
    }

    private var unreadCount: Int {
        get { activeStateKey().map { readState(for: $0).unreadCount } ?? 0 }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.unreadCount = newValue }
        }
    }

    private var pendingBottomInsetHeightCapInvalidation: DispatchWorkItem? {
        get { activeStateKey().flatMap { readState(for: $0).pendingBottomInsetHeightCapInvalidation } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingBottomInsetHeightCapInvalidation = newValue }
        }
    }

    private var fingerprints: [String: Int] {
        get { activeStateKey().map { readState(for: $0).fingerprints } ?? [:] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.fingerprints = newValue }
        }
    }

    private var lastAppliedMessageSetIdentity: MessageSetIdentity? {
        get { activeStateKey().flatMap { readState(for: $0).lastAppliedMessageSetIdentity } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.lastAppliedMessageSetIdentity = newValue }
        }
    }

    private var lastMeasuredSizes: [String: CGSize] {
        get { activeStateKey().map { readState(for: $0).lastMeasuredSizes } ?? [:] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.lastMeasuredSizes = newValue }
        }
    }

    private var sizeCache: [String: CGSize] {
        get { activeStateKey().map { readState(for: $0).sizeCache } ?? [:] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.sizeCache = newValue }
        }
    }

    private var pendingReconfigureIds: Set<String> {
        get { activeStateKey().map { readState(for: $0).pendingReconfigureIds } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingReconfigureIds = newValue }
        }
    }

    private var dirtySizeIds: Set<String> {
        get { activeStateKey().map { readState(for: $0).dirtySizeIds } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.dirtySizeIds = newValue }
        }
    }

    private var lastMessageId: String? {
        get { activeStateKey().flatMap { readState(for: $0).lastMessageId } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.lastMessageId = newValue }
        }
    }

    private var wasShowingTypingIndicator: Bool {
        get { activeStateKey().map { readState(for: $0).wasShowingTypingIndicator } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.wasShowingTypingIndicator = newValue }
        }
    }

    private var firstUnreadWasBelowViewportCenter: Bool? {
        get { activeStateKey().flatMap { readState(for: $0).firstUnreadWasBelowViewportCenter } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.firstUnreadWasBelowViewportCenter = newValue }
        }
    }

    private var didCrossAndClearFirstUnreadId: String? {
        get { activeStateKey().flatMap { readState(for: $0).didCrossAndClearFirstUnreadId } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.didCrossAndClearFirstUnreadId = newValue }
        }
    }

    private var pendingFlashMessageId: String? {
        get { activeStateKey().flatMap { readState(for: $0).pendingFlashMessageId } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingFlashMessageId = newValue }
        }
    }

    private var pendingFlashIsUnreadTap: Bool {
        get { activeStateKey().map { readState(for: $0).pendingFlashIsUnreadTap } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingFlashIsUnreadTap = newValue }
        }
    }

    private var pendingEntranceAnimationIds: Set<String> {
        get { activeStateKey().map { readState(for: $0).pendingEntranceAnimationIds } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingEntranceAnimationIds = newValue }
        }
    }

    private var pendingScrollToBottomAfterInteractionEnd: Bool {
        get { activeStateKey().map { readState(for: $0).pendingScrollToBottomAfterInteractionEnd } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingScrollToBottomAfterInteractionEnd = newValue }
        }
    }

    private var morphTargetMessageId: String? {
        get { activeStateKey().flatMap { readState(for: $0).morphTargetMessageId } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.morphTargetMessageId = newValue }
        }
    }

    private var deferScrollToBottomUntilMorphCompletes: Bool {
        get { activeStateKey().map { readState(for: $0).deferScrollToBottomUntilMorphCompletes } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.deferScrollToBottomUntilMorphCompletes = newValue }
        }
    }

    private var scrollPersistenceKey: String? {
        get { activeStateKey() }
        set { _ = newValue }
    }

    private var pendingScrollRestoreState: PersistedScrollState? {
        get { activeStateKey().flatMap { readState(for: $0).pendingScrollRestoreState } }
        set {
            guard let key = activeStateKey() else { return }
            let previous = readState(for: key).pendingScrollRestoreState
            if previous != newValue {
                logPendingScrollRestoreStateChange(
                    sessionKey: key,
                    from: previous,
                    to: newValue,
                    reason: "activeStateSetter"
                )
            }
            mutateState(for: key) { $0.pendingScrollRestoreState = newValue }
        }
    }

    private var restoredScrollKeys: Set<String> {
        get {
            guard let key = activeStateKey() else { return [] }
            let generation = readState(for: key).restoreGeneration
            return readState(for: key).restoredScrollGenerations.contains(generation) ? [key] : []
        }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { state in
                if newValue.contains(key) {
                    state.restoredScrollGenerations.insert(state.restoreGeneration)
                }
            }
        }
    }

    private var restorePhase: RestorePhase {
        get { activeStateKey().map { readState(for: $0).restorePhase } ?? .none }
        set {
            guard let key = activeStateKey() else { return }
            let previous = readState(for: key).restorePhase
            if previous != newValue {
                logRestorePhaseChange(sessionKey: key, from: previous, to: newValue, reason: "activeStateSetter")
            }
            mutateState(for: key) { $0.restorePhase = newValue }
        }
    }

    private var suspendScrollPersistenceUntilRestoreConfirmed: Bool {
        get { activeStateKey().map { readState(for: $0).suspendScrollPersistenceUntilRestoreConfirmed } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.suspendScrollPersistenceUntilRestoreConfirmed = newValue }
        }
    }

    private var scrollStateWriteDebounceTimer: Timer? {
        get { activeStateKey().flatMap { readState(for: $0).scrollStateWriteDebounceTimer } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.scrollStateWriteDebounceTimer = newValue }
        }
    }

    private var sbbState: SBBState {
        get { activeStateKey().map { readState(for: $0).sbbState } ?? .atBottom }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.sbbState = newValue }
        }
    }

    private var lastReportedHideIndicator: Bool? {
        get { activeStateKey().flatMap { readState(for: $0).lastReportedHideIndicator } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.lastReportedHideIndicator = newValue }
        }
    }

    private var lastSeenBottomInsetForSBB: CGFloat? {
        get { activeStateKey().flatMap { readState(for: $0).lastSeenBottomInsetForSBB } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.lastSeenBottomInsetForSBB = newValue }
        }
    }

    private var pendingScrollToBottomAttempts: Int {
        get { activeStateKey().map { readState(for: $0).pendingScrollToBottomAttempts } ?? 0 }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingScrollToBottomAttempts = newValue }
        }
    }

    private var pendingScrollToBottomAnimated: Bool {
        get { activeStateKey().map { readState(for: $0).pendingScrollToBottomAnimated } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.pendingScrollToBottomAnimated = newValue }
        }
    }

    private var bubbleSizingV2KeysByMessageId: [String: Set<BubbleSizingV2.CacheKey>] {
        get { activeStateKey().map { readState(for: $0).bubbleSizingV2KeysByMessageId } ?? [:] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2KeysByMessageId = newValue }
        }
    }

    private var bubbleSizingV2LinkPreviewStateVersionByMessageId: [String: Int] {
        get { activeStateKey().map { readState(for: $0).bubbleSizingV2LinkPreviewStateVersionByMessageId } ?? [:] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2LinkPreviewStateVersionByMessageId = newValue }
        }
    }

    private var bubbleSizingV2PendingRemeasureIds: Set<String> {
        get { activeStateKey().map { readState(for: $0).bubbleSizingV2PendingRemeasureIds } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2PendingRemeasureIds = newValue }
        }
    }

    private var bubbleSizingV2PendingLiveMeasurementIds: Set<String> {
        get { activeStateKey().map { readState(for: $0).bubbleSizingV2PendingLiveMeasurementIds } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2PendingLiveMeasurementIds = newValue }
        }
    }

    private var bubbleSizingV2AcceptedRemeasureKeys: Set<BubbleSizingV2AcceptedRemeasureKey> {
        get { activeStateKey().map { readState(for: $0).bubbleSizingV2AcceptedRemeasureKeys } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2AcceptedRemeasureKeys = newValue }
        }
    }

    private var bubbleSizingV2ScrollSettleEpoch: UInt64 {
        get { activeStateKey().map { readState(for: $0).bubbleSizingV2ScrollSettleEpoch } ?? 0 }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2ScrollSettleEpoch = newValue }
        }
    }

    private var bubbleSizingV2RemeasureDebounceTimer: Timer? {
        get { activeStateKey().flatMap { readState(for: $0).bubbleSizingV2RemeasureDebounceTimer } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2RemeasureDebounceTimer = newValue }
        }
    }

    private var bubbleSizingV2DeferredFlushTimer: Timer? {
        get { activeStateKey().flatMap { readState(for: $0).bubbleSizingV2DeferredFlushTimer } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2DeferredFlushTimer = newValue }
        }
    }

    private var bubbleSizingV2RemeasureBatchStartTime: CFAbsoluteTime? {
        get { activeStateKey().flatMap { readState(for: $0).bubbleSizingV2RemeasureBatchStartTime } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2RemeasureBatchStartTime = newValue }
        }
    }

    private var bubbleSizingV2RemeasureDeferredUntilNearBottom: Bool {
        get { activeStateKey().map { readState(for: $0).bubbleSizingV2RemeasureDeferredUntilNearBottom } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bubbleSizingV2RemeasureDeferredUntilNearBottom = newValue }
        }
    }

    private var deferredPreviewRemeasureIds: Set<String> {
        get { activeStateKey().map { readState(for: $0).deferredPreviewRemeasureIds } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.deferredPreviewRemeasureIds = newValue }
        }
    }

    private var deferredPreviewRemeasureTimer: Timer? {
        get { activeStateKey().flatMap { readState(for: $0).deferredPreviewRemeasureTimer } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.deferredPreviewRemeasureTimer = newValue }
        }
    }

    private var deferredBottomInsetRemeasureIds: Set<String> {
        get { activeStateKey().map { readState(for: $0).deferredBottomInsetRemeasureIds } ?? [] }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.deferredBottomInsetRemeasureIds = newValue }
        }
    }

    private var bottomInsetRemeasureTimer: Timer? {
        get { activeStateKey().flatMap { readState(for: $0).bottomInsetRemeasureTimer } }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bottomInsetRemeasureTimer = newValue }
        }
    }

    func scheduleScrollToBottom(animated: Bool, attempts: Int = 2) {
        guard let sessionKey = callbackSessionKey() else { return }
        scheduleScrollToBottom(sessionKey: sessionKey, animated: animated, attempts: attempts)
    }

    func collectionView(_: UICollectionView, shouldHighlightItemAt _: IndexPath) -> Bool {
        false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyChatPageBackground(isDark: currentIsDark)
        view.clipsToBounds = false
        configureCollectionView()
        applyChatPageBackground(isDark: currentIsDark)
        configureDataSource()
        webBubbleCoordinator.onItemsChanged = { [weak self] in
            self?.applySnapshotForWebBubbles()
        }
        webBubbleCoordinator.onReconfigureItem = { [weak self] id in
            self?.reconfigureItem(id: id)
        }
        webBubbleCoordinator.onScrollToItem = { [weak self] id in
            self?.scrollToItem(id: id)
        }

        // currentIsDark will be set by the first update() call from SwiftUI
        // which passes the colorScheme environment value

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        MainActor.assumeIsolated {
            if let messageRemovalObserverToken {
                viewModel?.unregisterMessageRemovalObserver(messageRemovalObserverToken)
            }
        }
        let sessionKeys = Array(perStreamStateBySessionKey.keys)
        for sessionKey in sessionKeys {
            cancelDeferredWork(for: sessionKey, cancelAll: true)
        }
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
    }

    // MARK: - Cache Mutation Seam

    // Invariant: All bubble cache mutations go through this seam.

    private struct CachedMeasurement {
        let size: CGSize
    }

    private typealias HeightDelta = CGFloat

    private enum InvalidationReason {
        case messageChanged(id: String)
        case messagesRemoved([String])
        case envChanged
        case compactnessChanged
        case containerSizeChanged
    }

    private enum InvalidationPlan {
        case none
        case reconfigureItems([String])
        case remeasureAndShift([(id: String, delta: HeightDelta)])
        case fullRebuild
    }

    @discardableResult
    private func readSizeState(messageId: String, env: BubbleSizingV2.Environment) -> CachedMeasurement? {
        _ = env
        guard let cached = sizeCache[messageId] else { return nil }
        lastMeasuredSizes[messageId] = cached
        return CachedMeasurement(size: cached)
    }

    @discardableResult
    private func writeMeasuredSize(messageId: String, measurement: CGSize) -> HeightDelta? {
        let previous = lastMeasuredSizes[messageId]
        lastMeasuredSizes[messageId] = measurement
        sizeCache[messageId] = measurement
        guard let previous else { return nil }
        let heightDelta = measurement.height - previous.height
        let widthDelta = measurement.width - previous.width
        let epsilon: CGFloat = 0.5
        guard abs(heightDelta) > epsilon || abs(widthDelta) > epsilon else { return nil }
        return heightDelta
    }

    @discardableResult
    private func recordAsyncPreview(messageId: String, key: String, height: CGFloat) -> HeightDelta? {
        let oldHeight = bubbleSizingV2LinkPreviewHeightCache.get(cacheKey: key)
        bubbleSizingV2LinkPreviewHeightCache.set(height: height, cacheKey: key)
        guard Self.bubbleSizingV2AsyncPreviewHeightChanged(previous: oldHeight, next: height) else {
            return nil
        }
        bubbleSizingV2LinkPreviewStateVersionByMessageId[messageId, default: 0] += 1
        return height - (oldHeight ?? height)
    }

    @discardableResult
    private func invalidateFor(reason: InvalidationReason) -> InvalidationPlan {
        switch reason {
        case let .messageChanged(id):
            dirtySizeIds.insert(id)
            return .fullRebuild
        case let .messagesRemoved(ids):
            clearSizeState(for: ids)
            ids.forEach { invalidateBubbleSizingV2Cache(for: $0) }
            removeBubbleV2PreviewVersions(for: ids)
            return .none
        case .envChanged, .compactnessChanged, .containerSizeChanged:
            clearAllSizeState()
            clearAllBubbleV2State()
            return .fullRebuild
        }
    }

    private func executeInvalidationPlan(_ plan: InvalidationPlan) {
        switch plan {
        case .none:
            break
        case let .reconfigureItems(ids):
            ids.forEach { scheduleReconfigure(for: $0) }
        case let .remeasureAndShift(changes):
            guard changes.count == 1,
                  let change = changes.first,
                  abs(change.delta) > 0.5,
                  let indexPath = dataSource.indexPath(for: change.id)
            else {
                scheduleLayoutInvalidation()
                return
            }
            let viewportAnchor = captureBubbleSizingV2ViewportAnchor()
            flowLayout.invalidateLayout(mode: .itemHeightChange(index: indexPath.item, delta: change.delta))
            scheduleBubbleSizingV2ViewportAnchorCompensation(viewportAnchor)
        case .fullRebuild:
            scheduleLayoutInvalidation()
        }
    }

    private func clearSizeState(for ids: [String]) {
        for id in ids {
            lastMeasuredSizes.removeValue(forKey: id)
            sizeCache.removeValue(forKey: id)
        }
    }

    private func clearAllSizeState() {
        lastMeasuredSizes.removeAll()
        sizeCache.removeAll()
    }

    private func clearAllBubbleV2State() {
        bubbleSizingV2MeasurementCache.removeAll()
        bubbleSizingV2LayoutStateCache.removeAll()
        bubbleSizingV2KeysByMessageId.removeAll()
        bubbleSizingV2LinkPreviewStateVersionByMessageId.removeAll()
        bubbleSizingV2PendingLiveMeasurementIds.removeAll()
        bubbleSizingV2AcceptedRemeasureKeys.removeAll()
    }

    private func removeBubbleV2PreviewVersions(for ids: [String]) {
        ids.forEach { bubbleSizingV2LinkPreviewStateVersionByMessageId.removeValue(forKey: $0) }
        let removedIds = Set(ids)
        bubbleSizingV2PendingLiveMeasurementIds.subtract(removedIds)
        bubbleSizingV2AcceptedRemeasureKeys = Set(
            bubbleSizingV2AcceptedRemeasureKeys.filter { !removedIds.contains($0.messageId) }
        )
    }

    private func cachedWidth(for messageId: String) -> CGFloat? {
        sizeCache[messageId]?.width
    }

    private func bubbleV2PreviewVersion(for messageId: String) -> Int {
        bubbleSizingV2LinkPreviewStateVersionByMessageId[messageId] ?? 0
    }

    private func bubbleV2Measurement(for key: BubbleSizingV2.CacheKey) -> BubbleSizingV2.Measurement? {
        bubbleSizingV2MeasurementCache.value(forKey: key)
    }

    private func bubbleV2LayoutState(for key: BubbleSizingV2.CacheKey) -> BubbleSizingV2.LayoutState? {
        bubbleSizingV2LayoutStateCache.value(forKey: key)
    }

    private func recordBubbleV2Measurement(_ measurement: BubbleSizingV2.Measurement,
                                           key: BubbleSizingV2.CacheKey,
                                           messageId: String)
    {
        bubbleSizingV2MeasurementCache.setValue(measurement, forKey: key)
        bubbleSizingV2KeysByMessageId[messageId, default: []].insert(key)
    }

    private func recordBubbleV2LayoutState(_ layoutState: BubbleSizingV2.LayoutState,
                                           key: BubbleSizingV2.CacheKey,
                                           messageId: String)
    {
        bubbleSizingV2LayoutStateCache.setValue(layoutState, forKey: key)
        recordBubbleV2Measurement(layoutState.measurement, key: key, messageId: messageId)
    }

    private func removeBubbleV2Measurements(for messageId: String) {
        guard let keys = bubbleSizingV2KeysByMessageId.removeValue(forKey: messageId) else { return }
        for key in keys {
            bubbleSizingV2MeasurementCache.removeValue(forKey: key)
            bubbleSizingV2LayoutStateCache.removeValue(forKey: key)
        }
    }

    private func consumePendingInvalidatedSizeIds() -> [String] {
        let ids = Array(dirtySizeIds)
        dirtySizeIds.removeAll()
        return ids
    }

    private func hasDirtySizeIds() -> Bool {
        !dirtySizeIds.isEmpty
    }

    private func cachedPreviewHeight(cacheKey: String) -> CGFloat? {
        bubbleSizingV2LinkPreviewHeightCache.get(cacheKey: cacheKey)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Native iOS/iPadOS: Extend vertically to fill the entire screen, ignoring top/bottom safe areas.
        // SwiftUI's UIViewControllerRepresentable doesn't respect .ignoresSafeArea() for UIKit views,
        // so we manually extend the collection view against window bounds. Keep the collection view
        // aligned to physical window width in compact landscape so bubbles do not stop at the safe-area host.
        //
        // Catalyst: Preserve the historical full-window width behavior; T357's containment is native iOS/iPadOS-only.
        //
        // visionOS: In a spatial window this "counter-positioning" can create a layout feedback loop
        // (window position/size <-> view origin <-> collectionView frame), visible as the chat list
        // flapping vertically when content reaches the bottom. Use the normal view bounds instead.
        #if os(visionOS)
            collectionView.frame = view.bounds
        #elseif targetEnvironment(macCatalyst)
            let targetFrame = Self.targetCollectionFrame(
                viewBounds: view.bounds,
                windowBounds: view.window?.bounds,
                viewOriginInWindow: view.window.map { view.convert(CGPoint.zero, to: $0) },
                preservesHorizontallyConstrainedHostWidth: false
            )

            // Only update if significantly different to avoid layout loops
            if Self.shouldUpdateCollectionFrame(current: collectionView.frame, target: targetFrame) {
                collectionView.frame = targetFrame
            }
        #else
            let targetFrame = Self.targetCollectionFrame(
                viewBounds: view.bounds,
                windowBounds: view.window?.bounds,
                viewOriginInWindow: view.window.map { view.convert(CGPoint.zero, to: $0) },
                fillsHorizontallyConstrainedHostToWindow: ChatLandscapeWidthGeometry.shouldFillWindowWidth(
                    viewSize: view.bounds.size,
                    windowSize: view.window?.bounds.size,
                    isCompactLandscape: traitCollection.horizontalSizeClass == .compact
                        && (view.bounds.width > view.bounds.height
                            || (view.window?.bounds.width ?? 0) > (view.window?.bounds.height ?? 0))
                )
            )

            // Only update if significantly different to avoid layout loops
            if Self.shouldUpdateCollectionFrame(current: collectionView.frame, target: targetFrame) {
                collectionView.frame = targetFrame
            }
        #endif

        // Handle bounds size changes
        let size = collectionView.bounds.size
        guard size != .zero, size != lastBoundsSize else {
            notifyTypingIndicatorAnchorFrameIfNeeded()
            return
        }
        let hadPendingFullReconfigure = forceReconfigureAll
        lastBoundsSize = size
        pendingBoundsChange = true
        let measurementInputsChanged = updateLayout()
        guard Self.shouldRunUpdateAfterBoundsChange(
            measurementInputsChanged: measurementInputsChanged,
            hadPendingFullReconfigure: hadPendingFullReconfigure
        ) else {
#if os(visionOS)
            updateVisibleFooterAlpha()
#endif
            return
        }
        if let viewModel {
            update(
                viewModel: viewModel,
                isCompact: isCompact,
                isActiveSession: isActiveSession,
                isRenderPolicyFrozen: isRenderPolicyFrozen,
                isInputActive: isInputActive,
                keepsKeyboardPinned: keepsKeyboardPinned,
                isTypingActive: isTypingActive,
                topInset: topInset,
                truncationBottomInset: truncationBottomInset,
                trailingContentInset: trailingContentInset,
                firstUnreadMessageId: firstUnreadMessageId,
                unreadCount: unreadCount,
                onExpand: onExpand,
                onOpenDetail: onOpenDetail,
                sessionKey: channelOverride,
                sessionStatus: sessionStatus,
                forceReReadGeneration: 0,
                sendIndicatorRevision: viewModel.sendIndicatorRevision,
                onScrollEvent: onScrollEvent,
                onTypingIndicatorTap: onTypingIndicatorTap,
                onTypingIndicatorAnchorFrameChanged: onTypingIndicatorAnchorFrameChanged,
                onSessionControlSelected: onSessionControlSelected,
                isDark: currentIsDark
            )
        }
        notifyTypingIndicatorAnchorFrameIfNeeded()
    }

    func scrollViewDidScroll(_: UIScrollView) {
        bubbleSizingV2LastScrollActivityTime = CFAbsoluteTimeGetCurrent()
        updateVisibleFooterAlpha()
        guard let sessionKey = callbackSessionKey() else { return }
        handleUserScrolled(sessionKey: sessionKey)
        checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
        refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        schedulePersistScrollState(sessionKey: sessionKey)
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
        scheduleDeferredBottomInsetRemeasure()
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            setSalientHighlightIsScrolling(false)
        }
        if !decelerate {
            flushDeferredPreviewRemeasuresIfPossible()
            guard let sessionKey = callbackSessionKey() else { return }
            emit(.transcriptScrollActiveChanged(sessionKey: sessionKey, isActive: false))
            handleUserScrollSettled(sessionKey: sessionKey)
            shiftMaterializationWindowIfNeeded(sessionKey: sessionKey)
            checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
            performPendingFlashIfPossible()
            performPendingDeferredScrollToBottomIfNeeded(sessionKey: sessionKey)
            schedulePersistScrollState(sessionKey: sessionKey)
            flushDeferredBubbleSizingV2RemeasureIfNeeded()
            scheduleDeferredBottomInsetRemeasure()
            notifyTypingIndicatorAnchorFrameIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        flushDeferredPreviewRemeasuresIfPossible()
        setSalientHighlightIsScrolling(false)
        guard let sessionKey = callbackSessionKey() else { return }
        emit(.transcriptScrollActiveChanged(sessionKey: sessionKey, isActive: false))
        handleUserScrollSettled(sessionKey: sessionKey)
        shiftMaterializationWindowIfNeeded(sessionKey: sessionKey)
        checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
        performPendingFlashIfPossible()
        performPendingDeferredScrollToBottomIfNeeded(sessionKey: sessionKey)
        schedulePersistScrollState(sessionKey: sessionKey)
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
        scheduleDeferredBottomInsetRemeasure()
        notifyTypingIndicatorAnchorFrameIfNeeded()
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        beginNextBubbleSizingV2ScrollSettleEpoch()
        flushDeferredPreviewRemeasuresIfPossible()
        guard let sessionKey = callbackSessionKey() else { return }
        emit(.transcriptScrollActiveChanged(sessionKey: sessionKey, isActive: false))
        handleProgrammaticScrollEnded(sessionKey: sessionKey)
        shiftMaterializationWindowIfNeeded(sessionKey: sessionKey)
        checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
        performPendingFlashIfPossible()
        performPendingDeferredScrollToBottomIfNeeded(sessionKey: sessionKey)
        schedulePersistScrollState(sessionKey: sessionKey)
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
        scheduleDeferredBottomInsetRemeasure()
        notifyTypingIndicatorAnchorFrameIfNeeded()
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        // Spec: interaction = scroll view dragging/tracking. Enter a pinned-but-defer state.
        beginNextBubbleSizingV2ScrollSettleEpoch()
        setSalientHighlightIsScrolling(true)
        guard let sessionKey = callbackSessionKey() else { return }
        emit(.transcriptScrollActiveChanged(sessionKey: sessionKey, isActive: true))
        if readState(for: sessionKey).sbbState == .atBottom {
            setSBBState(.atBottomDragging, sessionKey: sessionKey)
        }
    }

    private func beginNextBubbleSizingV2ScrollSettleEpoch() {
        bubbleSizingV2ScrollSettleEpoch &+= 1
        bubbleSizingV2AcceptedRemeasureKeys.removeAll()
    }

    private func setSalientHighlightIsScrolling(_ isScrolling: Bool) {
        if isPostingSalientScrolling == isScrolling { return }
        isPostingSalientScrolling = isScrolling
        NotificationCenter.default.post(
            name: .salientHighlightScrollingChanged,
            object: nil,
            userInfo: ["isScrolling": isScrolling]
        )
    }

    @objc private func handleWillResignActive() {
        guard let sessionKey = callbackSessionKey() else { return }
        persistScrollStateNow(sessionKey: sessionKey)
    }

    func collectionView(_: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        // During morph, we intentionally drive the target cell's alpha from 0->1 in our own
        // `UIView.animate`. Don't let willDisplay stomp it back to 1 early.
        if id == morphTargetMessageId {
            return
        }
        if id == SessionMetadataFooterCell.itemId {
            cell.alpha = footerRevealAlpha()
            cell.transform = .identity
            return
        }
        guard pendingEntranceAnimationIds.contains(id) else {
            // Reset any reused cells that might have been animated previously.
            cell.alpha = 1
            cell.transform = .identity
            return
        }
        pendingEntranceAnimationIds.remove(id)

        // Subtle entrance: scale up + fade in.
        cell.alpha = 0
        cell.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            cell.alpha = 1
            cell.transform = .identity
        }
        scheduleDeferredBottomInsetRemeasure()
    }

    var currentBottomInset: CGFloat = 0

    private func logScrollRestore(_ message: String) {
        print("[ScrollRestore] \(message)")
    }

    private func formatScrollRestore(_ value: CGFloat) -> String {
        guard value.isFinite else { return "nonfinite" }
        return String(format: "%.1f", value)
    }

    private func describePersistedScrollState(_ state: PersistedScrollState?) -> String {
        guard let state else { return "nil" }
        return "atBottom=\(state.atBottom) distanceFromBottom=\(formatScrollRestore(CGFloat(state.distanceFromBottom))) projection=\(state.projectionBase ?? "legacy") query=\(state.searchQuery ?? "") lower=\(state.projectionLowerBound.map(String.init) ?? "nil") savedAt=\(String(format: "%.3f", state.savedAtEpochSeconds))"
    }

    private func describeMaterializationState(_ state: MaterializationState?) -> String {
        guard let state else { return "nil" }
        return "stage=\(state.stage.rawValue) bounds=\(state.windowBounds.lowerBound)..<\(state.windowBounds.upperBound) total=\(state.logicalTotalCount) revision=\(state.revision) unreadOutsideTail=\(state.unreadOutsideTailWindow)"
    }

    private func describeMaterializationEvent(_ event: MaterializationEvent) -> String {
        switch event {
        case let .projectionSelected(key):
            return "projectionSelected base=\(key.base) query=\(key.searchQuery)"
        case let .messagesUpdated(totalCount, firstUnreadProjectedIndex, followsProjectionTail):
            return "messagesUpdated total=\(totalCount) firstUnreadIndex=\(firstUnreadProjectedIndex.map(String.init) ?? "nil") followsTail=\(followsProjectionTail)"
        case let .shifted(windowBounds, totalCount, _, _):
            return "shifted total=\(totalCount) bounds=\(windowBounds.lowerBound)..<\(windowBounds.upperBound)"
        case let .edgeShift(direction, residual, _):
            return "edgeShift direction=\(direction) residual=\(residual.map(String.init(describing:)) ?? "nil")"
        case let .directTargetRequested(id, animated, flash):
            return "directTargetRequested id=\(id) animated=\(animated) flash=\(flash)"
        case .directTargetCancelled:
            return "directTargetCancelled"
        case let .directTarget(projectedIndex, totalCount, _):
            return "directTarget index=\(projectedIndex) total=\(totalCount)"
        case let .transcriptTruthTargetRequested(animated):
            return "transcriptTruthTargetRequested animated=\(animated)"
        case let .projectionEdge(tail, _):
            return "projectionEdge tail=\(tail)"
        }
    }

    private func logRestorePhaseChange(sessionKey: String,
                                       from oldPhase: RestorePhase,
                                       to newPhase: RestorePhase,
                                       reason: String)
    {
        logScrollRestore(
            "restorePhase sessionKey=\(sessionKey) from=\(String(describing: oldPhase)) to=\(String(describing: newPhase)) reason=\(reason)"
        )
    }

    private func logPendingScrollRestoreStateChange(sessionKey: String,
                                                    from oldState: PersistedScrollState?,
                                                    to newState: PersistedScrollState?,
                                                    reason: String)
    {
        logScrollRestore(
            "pendingScrollRestoreState sessionKey=\(sessionKey) from={\(describePersistedScrollState(oldState))} to={\(describePersistedScrollState(newState))} reason=\(reason)"
        )
    }

    private func logMaterializationStateChange(sessionKey: String,
                                               from oldState: MaterializationState?,
                                               to newState: MaterializationState?,
                                               reason: String)
    {
        logScrollRestore(
            "materializationState sessionKey=\(sessionKey) from={\(describeMaterializationState(oldState))} to={\(describeMaterializationState(newState))} reason=\(reason)"
        )
    }

    private func logScrollCall(_ name: String,
                               sessionKey: String?,
                               currentY: CGFloat,
                               targetY: CGFloat,
                               animated: Bool,
                               reason: String)
    {
        logScrollRestore(
            "\(name) sessionKey=\(sessionKey ?? "nil") currentOffsetY=\(formatScrollRestore(currentY)) targetOffsetY=\(formatScrollRestore(targetY)) animated=\(animated) reason=\(reason)"
        )
    }

    /// Single source of truth for setting bottom content inset (driven by coordinator).
    func setBottomInset(_ totalBottomInset: CGFloat,
                        animatedDuration: TimeInterval? = nil,
                        animationOptions: UIView.AnimationOptions = [])
    {
        let previousBottomInset = collectionView.contentInset.bottom
        logScrollRestore(
            "setBottomInset old=\(formatScrollRestore(previousBottomInset)) new=\(formatScrollRestore(totalBottomInset))"
        )
        let delta = totalBottomInset - previousBottomInset
        // Keep keyboard/inset anchoring tied to active finger interaction only.
        // Deceleration must not disable this pinning path.
        let hasAuthoritativeRestoreTarget = callbackSessionKey().map(hasAuthoritativePersistedRestoreTarget(sessionKey:)) ?? false
        let shouldPinToBottom = Self.shouldAdjustForBottomInsetPinnedPosition(
            hasAuthoritativeRestoreTarget: hasAuthoritativeRestoreTarget,
            isPinnedToBottomIntent: sbbState.isPinnedToBottomIntent,
            isActivelyDraggingOrTracking: isActivelyDraggingOrTracking
        )
        if hasAuthoritativeRestoreTarget, sbbState.isPinnedToBottomIntent, !isActivelyDraggingOrTracking {
            logScrollRestore(
                "setBottomInset.skipOffsetAdjustment sessionKey=\(callbackSessionKey() ?? "nil") reason=savedRestoreTargetIsAuthoritative"
            )
        }
        currentBottomInset = totalBottomInset
        // Avoid re-applying the same inset; on visionOS we can get frequent relayout ticks and
        // touching `contentInset` even with the same value can kick the scroll view.
        if abs(collectionView.contentInset.bottom - totalBottomInset) <= 0.5,
           abs(collectionView.verticalScrollIndicatorInsets.bottom - totalBottomInset) <= 0.5
        {
            return
        }
        if let animatedDuration, animatedDuration > 0, view.window != nil {
            UIView.animate(withDuration: animatedDuration, delay: 0, options: animationOptions) {
                self.collectionView.contentInset.bottom = totalBottomInset
                self.collectionView.verticalScrollIndicatorInsets.bottom = totalBottomInset
                if shouldPinToBottom {
                    // Keep the viewport pinned to the bottom while the keyboard/input bar changes insets.
                    // Without this, we can momentarily appear "not at bottom" and the SBB shows.
                    self.adjustContentOffsetForBottomInsetChange(delta: delta)
                }
            }
        } else {
            collectionView.contentInset.bottom = totalBottomInset
            collectionView.verticalScrollIndicatorInsets.bottom = totalBottomInset
            if shouldPinToBottom {
                adjustContentOffsetForBottomInsetChange(delta: delta)
            }
        }
        // InsetsChanged: pinned intent means we keep the indicator hidden in AT_BOTTOM* states.
        emitHideIndicatorIfChanged()
        handleBottomInsetHeightCapChange(previousBottomInset: previousBottomInset, newBottomInset: totalBottomInset)
    }

    private func handleBottomInsetHeightCapChange(previousBottomInset: CGFloat, newBottomInset: CGFloat) {
        guard Self.shouldScheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: previousBottomInset,
            newBottomInset: newBottomInset,
            isInputActive: isInputActive
        ) else { return }
        scheduleBottomInsetHeightCapInvalidation()
    }

    private func scheduleBottomInsetHeightCapInvalidation() {
        guard let token = activeSessionGenerationToken() else { return }
        pendingBottomInsetHeightCapInvalidation?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            self.withBoundSessionKey(token.sessionKey) {
                self.pendingBottomInsetHeightCapInvalidation = nil
                self.applyBottomInsetHeightCapInvalidation()
            }
        }
        pendingBottomInsetHeightCapInvalidation = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.bottomInsetHeightCapInvalidationDebounceSeconds,
            execute: workItem
        )
    }

    private func applyBottomInsetHeightCapInvalidation() {
        guard let viewModel else { return }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let affectedIds = messagesById.values.compactMap { message -> String? in
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            return isSingleLinkPreviewBubble(presentation: presentation) ? message.id : nil
        }
        guard !affectedIds.isEmpty else { return }
        deferredBottomInsetRemeasureIds.formUnion(affectedIds)
        scheduleDeferredBottomInsetRemeasure()
    }

    static func shouldScheduleBottomInsetHeightCapInvalidation(
        previousBottomInset: CGFloat,
        newBottomInset: CGFloat,
        isInputActive: Bool
    ) -> Bool {
        guard abs(newBottomInset - previousBottomInset) > 0.5 else { return false }
        return !isInputActive
    }

    private func scheduleDeferredBottomInsetRemeasure() {
        guard !deferredBottomInsetRemeasureIds.isEmpty else { return }
        guard let token = activeSessionGenerationToken() else { return }
        bottomInsetRemeasureTimer?.invalidate()
        let delay: TimeInterval = isBubbleSizingV2ScrollAtRest() ? 0.02 : Self.bubbleSizingV2RestSettleDelaySeconds
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            self.withBoundSessionKey(token.sessionKey) {
                self.bottomInsetRemeasureTimer = nil
                self.flushDeferredBottomInsetRemeasureIfNeeded()
            }
        }
        bottomInsetRemeasureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flushDeferredBottomInsetRemeasureIfNeeded() {
        guard !deferredBottomInsetRemeasureIds.isEmpty else { return }
        guard isBubbleSizingV2ScrollAtRest() else { return }
        guard !isInputActive else { return }
        guard viewModel?.inputContent.isEffectivelyEmpty != false else { return }

        let visibleIds: Set<String> = Set(collectionView.indexPathsForVisibleItems.compactMap { indexPath in
            guard let id = dataSource.itemIdentifier(for: indexPath), !isNonMessageItemID(id) else {
                return nil
            }
            return id
        })
        let idsToRemeasure = Array(deferredBottomInsetRemeasureIds.intersection(visibleIds))
        guard !idsToRemeasure.isEmpty else { return }

        if bubbleSizingV2Enabled {
            idsToRemeasure.forEach { invalidateBubbleSizingV2Cache(for: $0) }
        } else {
            clearSizeState(for: idsToRemeasure)
        }

        for id in idsToRemeasure {
            scheduleReconfigure(for: id)
            let plan = invalidateFor(reason: .messageChanged(id: id))
            executeInvalidationPlan(plan)
        }
        deferredBottomInsetRemeasureIds.subtract(idsToRemeasure)
    }

    func scheduleScrollToBottom(sessionKey: String, animated: Bool, attempts: Int = 2) {
        let stateBefore = readState(for: sessionKey)
        logScrollRestore(
            "scheduleScrollToBottom.request sessionKey=\(sessionKey) animated=\(animated) attempts=\(attempts) existingAttempts=\(stateBefore.pendingScrollToBottomAttempts) existingAnimated=\(stateBefore.pendingScrollToBottomAnimated)"
        )
        mutateState(for: sessionKey) { state in
            state.pendingScrollToBottomAttempts = max(state.pendingScrollToBottomAttempts, attempts)
            state.pendingScrollToBottomAnimated = state.pendingScrollToBottomAnimated || animated
        }
        let stateAfter = readState(for: sessionKey)
        logScrollRestore(
            "scheduleScrollToBottom.enqueued sessionKey=\(sessionKey) pendingAttempts=\(stateAfter.pendingScrollToBottomAttempts) pendingAnimated=\(stateAfter.pendingScrollToBottomAnimated)"
        )
        performPendingScrollToBottomIfNeeded(sessionKey: sessionKey)
    }

    private func performPendingScrollToBottomIfNeeded(sessionKey: String) {
        var remainingAttempts = 0
        var animated = false
        mutateState(for: sessionKey) { state in
            remainingAttempts = state.pendingScrollToBottomAttempts
            animated = state.pendingScrollToBottomAnimated
            if state.pendingScrollToBottomAttempts > 0 {
                state.pendingScrollToBottomAttempts -= 1
            }
        }
        guard remainingAttempts > 0 else { return }
        logScrollRestore(
            "scheduleScrollToBottom.perform sessionKey=\(sessionKey) remainingAttempts=\(remainingAttempts) animated=\(animated)"
        )
        collectionView.layoutIfNeeded()
        scrollToActiveProjectionBottom(animated: animated)
        var shouldContinue = false
        mutateState(for: sessionKey) { state in
            shouldContinue = state.pendingScrollToBottomAttempts > 0
            if !shouldContinue {
                state.pendingScrollToBottomAnimated = false
            }
        }
        if shouldContinue {
            let expectedGeneration = readState(for: sessionKey).restoreGeneration
            var workItem: DispatchWorkItem?
            workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !(workItem?.isCancelled ?? true) else { return }
                guard self.readState(for: sessionKey).restoreGeneration == expectedGeneration else { return }
                self.performPendingScrollToBottomIfNeeded(sessionKey: sessionKey)
            }
            guard let workItem else { return }
            logScrollRestore(
                "scheduleScrollToBottom.reschedule sessionKey=\(sessionKey) nextExpectedGeneration=\(expectedGeneration)"
            )
            mutateState(for: sessionKey) { state in
                state.pendingScrollToBottomWorkItem?.cancel()
                state.pendingScrollToBottomWorkItem = workItem
            }
            DispatchQueue.main.async(execute: workItem)
        } else {
            mutateState(for: sessionKey) { state in
                state.pendingScrollToBottomWorkItem?.cancel()
                state.pendingScrollToBottomWorkItem = nil
            }
        }
    }

    // MARK: - Staged Materialization Seam

    // Invariant: stage/window/expansion mutations flow through advanceMaterialization(sessionKey:event:).

    private func enqueueMaterializationEvent(sessionKey: String,
                                             event: MaterializationEvent) -> MaterializationPlan
    {
        logScrollRestore(
            "materializationEvent.enqueue sessionKey=\(sessionKey) event=\(describeMaterializationEvent(event)) queueDepthBefore=\(materializationEventQueue.count)"
        )
        materializationEventQueue.append(MaterializationEventEnvelope(sessionKey: sessionKey, event: event))
        processMaterializationEventQueue()
        let plan = lastMaterializationPlanBySessionKey[sessionKey]
            ?? MaterializationPlan(
                stage: .full,
                windowBounds: .empty,
                unreadOutsideTailWindow: false,
                revision: 0
            )
        logScrollRestore(
            "materializationEvent.plan sessionKey=\(sessionKey) stage=\(plan.stage.rawValue) bounds=\(plan.windowBounds.lowerBound)..<\(plan.windowBounds.upperBound) unreadOutsideTail=\(plan.unreadOutsideTailWindow)"
        )
        return plan
    }

    private func pruneMaterializationState(validSessionKeys: Set<String>) {
        let staleStateKeys = materializationStateBySessionKey.keys.filter { !validSessionKeys.contains($0) }
        for key in staleStateKeys {
            materializationStateBySessionKey.removeValue(forKey: key)
        }
        let stalePlanKeys = lastMaterializationPlanBySessionKey.keys.filter { !validSessionKeys.contains($0) }
        for key in stalePlanKeys {
            lastMaterializationPlanBySessionKey.removeValue(forKey: key)
        }
        materializationEventQueue.removeAll { !validSessionKeys.contains($0.sessionKey) }
        materializationStateByProjectionBySessionKey = materializationStateByProjectionBySessionKey.filter {
            validSessionKeys.contains($0.key)
        }
        activeMaterializationProjectionKeyBySessionKey = activeMaterializationProjectionKeyBySessionKey.filter {
            validSessionKeys.contains($0.key)
        }
        lastAppliedMaterializationRevisionBySessionKey = lastAppliedMaterializationRevisionBySessionKey.filter {
            validSessionKeys.contains($0.key)
        }
        pendingMaterializationEffectBySessionKey = pendingMaterializationEffectBySessionKey.filter {
            validSessionKeys.contains($0.key)
        }
        pendingDirectNavigationBySessionKey = pendingDirectNavigationBySessionKey.filter {
            validSessionKeys.contains($0.key)
        }
        pendingTranscriptTruthBottomBySessionKey = pendingTranscriptTruthBottomBySessionKey.filter {
            validSessionKeys.contains($0.key)
        }
    }

    private func storeMaterializationState(_ state: MaterializationState, sessionKey: String) {
        materializationStateBySessionKey[sessionKey] = state
        guard let key = activeMaterializationProjectionKeyBySessionKey[sessionKey] else { return }
        materializationStateByProjectionBySessionKey[sessionKey, default: [:]][key] = state
    }

    private func cancelDeferredWork(for sessionKey: String, cancelAll: Bool) {
        mutateState(for: sessionKey) { state in
            state.pendingScrollToBottomWorkItem?.cancel()
            state.pendingScrollToBottomWorkItem = nil
            state.scrollStateWriteDebounceTimer?.invalidate()
            state.scrollStateWriteDebounceTimer = nil

            if cancelAll {
                state.bubbleSizingV2RemeasureDebounceTimer?.invalidate()
                state.bubbleSizingV2RemeasureDebounceTimer = nil
                state.bubbleSizingV2DeferredFlushTimer?.invalidate()
                state.bubbleSizingV2DeferredFlushTimer = nil
                state.bubbleSizingV2RemeasureBatchStartTime = nil
                state.bubbleSizingV2RemeasureDeferredUntilNearBottom = false
                state.bubbleSizingV2PendingRemeasureIds.removeAll()
                state.bubbleSizingV2PendingLiveMeasurementIds.removeAll()
                state.bubbleSizingV2AcceptedRemeasureKeys.removeAll()
                state.deferredPreviewRemeasureTimer?.invalidate()
                state.deferredPreviewRemeasureTimer = nil
                state.deferredPreviewRemeasureIds.removeAll()
                state.bottomInsetRemeasureTimer?.invalidate()
                state.bottomInsetRemeasureTimer = nil
                state.pendingBottomInsetHeightCapInvalidation?.cancel()
                state.pendingBottomInsetHeightCapInvalidation = nil
            }
        }
    }

    private func prunePerStreamState(validSessionKeys: Set<String>) {
        let staleKeys = perStreamStateBySessionKey.keys.filter { !validSessionKeys.contains($0) }
        for key in staleKeys {
            cancelDeferredWork(for: key, cancelAll: true)
            perStreamStateBySessionKey.removeValue(forKey: key)
        }
        if let lastAppliedEffectiveSessionKey, !validSessionKeys.contains(lastAppliedEffectiveSessionKey) {
            self.lastAppliedEffectiveSessionKey = nil
        }
    }

    private func prepareIncomingStateOnSwitch(sessionKey: String, allowTailStage: Bool) {
        let persistedState = loadPersistedScrollState(
            for: sessionKey,
            projectionBase: readState(for: sessionKey).isShowingOnlyUserMessages ? "userOnly" : "transcript",
            searchQuery: streamSearchQuery
        )
        if let persistedState {
            logScrollRestore(
                "prepareIncomingStateOnSwitch sessionKey=\(sessionKey) persistedAtBottom=\(persistedState.atBottom) persistedDistanceFromBottom=\(formatScrollRestore(CGFloat(persistedState.distanceFromBottom)))"
            )
        } else {
            logScrollRestore(
                "prepareIncomingStateOnSwitch sessionKey=\(sessionKey) persistedAtBottom=nil persistedDistanceFromBottom=nil"
            )
        }
        let previousPendingState = readState(for: sessionKey).pendingScrollRestoreState
        let previousRestorePhase = readState(for: sessionKey).restorePhase
        mutateState(for: sessionKey) { state in
            state.pendingScrollRestoreState = persistedState
            state.restoreConfirmationRetries = 0
            if let persistedState {
                if persistedState.atBottom {
                    state.sbbState = .atBottom
                } else {
                    state.sbbState = (state.unreadCount > 0) ? .scrolledUpUnread : .scrolledUp
                }
                state.restorePhase = allowTailStage ? .pendingTail : .pendingFullConfirmation
            } else {
                state.sbbState = .atBottom
                state.restorePhase = .none
            }
        }
        let newState = readState(for: sessionKey)
        if previousPendingState != newState.pendingScrollRestoreState {
            logPendingScrollRestoreStateChange(
                sessionKey: sessionKey,
                from: previousPendingState,
                to: newState.pendingScrollRestoreState,
                reason: "prepareIncomingStateOnSwitch"
            )
        }
        if previousRestorePhase != newState.restorePhase {
            logRestorePhaseChange(
                sessionKey: sessionKey,
                from: previousRestorePhase,
                to: newState.restorePhase,
                reason: "prepareIncomingStateOnSwitch"
            )
        }
    }

    private func prepareSameKeyReread(sessionKey: String) {
        let previousPendingState = readState(for: sessionKey).pendingScrollRestoreState
        let previousRestorePhase = readState(for: sessionKey).restorePhase
        mutateState(for: sessionKey) { state in
            state.scrollStateWriteDebounceTimer?.invalidate()
            state.scrollStateWriteDebounceTimer = nil
            state.restoreGeneration += 1
            let persistedState = loadPersistedScrollState(
                for: sessionKey,
                projectionBase: readState(for: sessionKey).isShowingOnlyUserMessages ? "userOnly" : "transcript",
                searchQuery: streamSearchQuery
            )
            state.pendingScrollRestoreState = persistedState
            state.restoreConfirmationRetries = 0
            if let persistedState {
                state.sbbState = persistedState.atBottom
                    ? .atBottom
                    : (state.unreadCount > 0 ? .scrolledUpUnread : .scrolledUp)
                state.restorePhase = .pendingTail
                state.suspendScrollPersistenceUntilRestoreConfirmed = true
            } else {
                state.sbbState = .atBottom
                state.restorePhase = .none
                state.suspendScrollPersistenceUntilRestoreConfirmed = false
            }
        }
        let newState = readState(for: sessionKey)
        if previousPendingState != newState.pendingScrollRestoreState {
            logPendingScrollRestoreStateChange(
                sessionKey: sessionKey,
                from: previousPendingState,
                to: newState.pendingScrollRestoreState,
                reason: "prepareSameKeyReread"
            )
        }
        if previousRestorePhase != newState.restorePhase {
            logRestorePhaseChange(
                sessionKey: sessionKey,
                from: previousRestorePhase,
                to: newState.restorePhase,
                reason: "prepareSameKeyReread"
            )
        }
    }

    private func processMaterializationEventQueue() {
        guard !isMaterializationQueueProcessing else { return }
        isMaterializationQueueProcessing = true
        defer { isMaterializationQueueProcessing = false }

        // FIFO command processing keeps expansion and append events deterministic.
        while !materializationEventQueue.isEmpty {
            let envelope = materializationEventQueue.removeFirst()
            logScrollRestore(
                "materializationEvent.process sessionKey=\(envelope.sessionKey) event=\(describeMaterializationEvent(envelope.event)) queueDepthAfterPop=\(materializationEventQueue.count)"
            )
            let plan = advanceMaterialization(sessionKey: envelope.sessionKey, event: envelope.event)
            lastMaterializationPlanBySessionKey[envelope.sessionKey] = plan
        }
    }

    private func hasAuthoritativePersistedRestoreTarget(sessionKey: String) -> Bool {
        guard let persistedState = readState(for: sessionKey).pendingScrollRestoreState else { return false }
        return !persistedState.atBottom
    }

    func toggleShowOnlyUserMessagesMode() {
        guard let sessionKey = callbackSessionKey() else { return }
        setShowOnlyUserMessagesMode(!readState(for: sessionKey).isShowingOnlyUserMessages)
    }

    private func revealUserMessageFromShowOnlyUserMessagesMode(_ message: Message) {
        setShowOnlyUserMessagesMode(false, revealMessageId: message.id)
    }

    private func setShowOnlyUserMessagesMode(_ isShowingOnlyUserMessages: Bool,
                                             revealMessageId: String? = nil) {
        guard let sessionKey = callbackSessionKey(), let viewModel else { return }
        if isUpdatePassInFlight || isSnapshotApplyInFlight {
            DispatchQueue.main.async { [weak self] in
                self?.setShowOnlyUserMessagesMode(
                    isShowingOnlyUserMessages,
                    revealMessageId: revealMessageId
                )
            }
            return
        }

        let previousValue = readState(for: sessionKey).isShowingOnlyUserMessages
        guard previousValue != isShowingOnlyUserMessages || revealMessageId != nil else { return }
        mutateState(for: sessionKey) { state in
            state.isShowingOnlyUserMessages = isShowingOnlyUserMessages
        }
        onShowOnlyUserMessagesModeChanged?(sessionKey, isShowingOnlyUserMessages)
        showOnlyUserMessagesTransitionSessionKeys.insert(sessionKey)
        if let revealMessageId {
            pendingShowOnlyUserMessagesRevealTargetBySessionKey[sessionKey] = revealMessageId
        }
        forceReconfigureAll = true
        update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            keepsKeyboardPinned: keepsKeyboardPinned,
            isTypingActive: isTypingActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            trailingContentInset: trailingContentInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            onOpenDetail: onOpenDetail,
            sessionKey: channelOverride,
            sessionStatus: sessionStatus,
            sessionStatusUnavailable: sessionStatusUnavailable,
            streamSearchQuery: streamSearchQuery,
            forceReReadGeneration: readState(for: sessionKey).lastSeenForceReReadGeneration,
            sendIndicatorRevision: currentSendIndicatorRevision,
            fontScaleChangeSequence: currentFontScaleChangeSequence,
            onScrollEvent: onScrollEvent,
            onTypingIndicatorTap: onTypingIndicatorTap,
            onTypingIndicatorAnchorFrameChanged: onTypingIndicatorAnchorFrameChanged,
            onSessionControlSelected: onSessionControlSelected,
            onFooterTestMenuSelected: onFooterTestMenuSelected,
            onInsertMessageIntoPrompt: onInsertMessageIntoPrompt,
            onReferenceMessageInPrompt: onReferenceMessageInPrompt,
            onShowOnlyUserMessagesModeChanged: onShowOnlyUserMessagesModeChanged,
            onStreamSearchQueryChanged: onStreamSearchQueryChanged,
            onKeyboardDismissModeChanged: onKeyboardDismissModeChanged,
            isDark: currentIsDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
    }

    private func advanceMaterialization(sessionKey: String,
                                        event: MaterializationEvent) -> MaterializationPlan
    {
        if case let .directTargetRequested(id, animated, flash) = event {
            pendingDirectNavigationBySessionKey[sessionKey] = PendingDirectNavigation(
                messageId: id,
                animated: animated,
                flash: flash
            )
            let current = materializationStateBySessionKey[sessionKey]
            return MaterializationPlan(
                stage: current?.stage ?? .full,
                windowBounds: current?.windowBounds ?? .empty,
                unreadOutsideTailWindow: current?.unreadOutsideTailWindow ?? false,
                revision: current?.revision ?? 0
            )
        }
        if case .directTargetCancelled = event {
            pendingDirectNavigationBySessionKey.removeValue(forKey: sessionKey)
            let current = materializationStateBySessionKey[sessionKey]
            return MaterializationPlan(
                stage: current?.stage ?? .full,
                windowBounds: current?.windowBounds ?? .empty,
                unreadOutsideTailWindow: current?.unreadOutsideTailWindow ?? false,
                revision: current?.revision ?? 0
            )
        }
        if case let .transcriptTruthTargetRequested(animated) = event {
            pendingTranscriptTruthBottomBySessionKey[sessionKey] = animated
            let current = materializationStateBySessionKey[sessionKey]
            return MaterializationPlan(
                stage: current?.stage ?? .full,
                windowBounds: current?.windowBounds ?? .empty,
                unreadOutsideTailWindow: current?.unreadOutsideTailWindow ?? false,
                revision: current?.revision ?? 0
            )
        }
        if case let .projectionSelected(key) = event {
            if activeMaterializationProjectionKeyBySessionKey[sessionKey] != key {
                if let snapshot = liveScrollSnapshotIfAvailable() {
                    persistScrollSnapshot(snapshot, for: sessionKey)
                }
                if let previousKey = activeMaterializationProjectionKeyBySessionKey[sessionKey],
                   let currentState = materializationStateBySessionKey[sessionKey]
                {
                    materializationStateByProjectionBySessionKey[sessionKey, default: [:]][previousKey] = currentState
                }
                activeMaterializationProjectionKeyBySessionKey[sessionKey] = key
                materializationStateBySessionKey[sessionKey] = materializationStateByProjectionBySessionKey[sessionKey]?[key]
                pendingMaterializationEffectBySessionKey.removeValue(forKey: sessionKey)
            }
            let selected = materializationStateBySessionKey[sessionKey]
            return MaterializationPlan(
                stage: selected?.stage ?? .full,
                windowBounds: selected?.windowBounds ?? .empty,
                unreadOutsideTailWindow: selected?.unreadOutsideTailWindow ?? false,
                revision: selected?.revision ?? 0
            )
        }

        let previousMaterializationState = materializationStateBySessionKey[sessionKey]
        let activeProjectionKey = activeMaterializationProjectionKeyBySessionKey[sessionKey]
            ?? MaterializationProjectionKey(base: .transcript, searchQuery: "")
        let windowCount = Self.stagedMaterializationTailWindowCount(
            isShowingOnlyUserMessages: activeProjectionKey.base == .userOnly
        )
        let totalCount: Int
        let nextBounds: WindowBounds
        let firstUnreadProjectedIndex: Int?
        let viewportAnchor: BubbleSizingV2ViewportAnchor?
        let postApplyAction: MaterializationPostApplyAction?
        switch event {
        case let .messagesUpdated(count, unreadIndex, followsProjectionTail):
            totalCount = count
            firstUnreadProjectedIndex = unreadIndex
            viewportAnchor = nil
            postApplyAction = nil
            let previousWindow = previousMaterializationState.map {
                BoundedMessageWindow(
                    lowerBound: $0.windowBounds.lowerBound,
                    upperBound: $0.windowBounds.upperBound,
                    totalCount: $0.logicalTotalCount
                )
            }
            let window = BoundedMessageWindow.updating(
                previous: previousWindow,
                totalCount: count,
                limit: windowCount,
                followsTail: followsProjectionTail
            )
            nextBounds = WindowBounds(lowerBound: window.lowerBound, upperBound: window.upperBound)
        case let .shifted(bounds, count, anchor, action):
            totalCount = count
            firstUnreadProjectedIndex = nil
            viewportAnchor = anchor
            postApplyAction = action
            let lower = max(0, min(bounds.lowerBound, max(0, count - windowCount)))
            nextBounds = WindowBounds(lowerBound: lower, upperBound: min(count, lower + windowCount))
        case let .edgeShift(direction, residual, anchor):
            guard let previousMaterializationState else {
                return MaterializationPlan(stage: .full, windowBounds: .empty, unreadOutsideTailWindow: false, revision: 0)
            }
            totalCount = previousMaterializationState.logicalTotalCount
            firstUnreadProjectedIndex = nil
            viewportAnchor = anchor
            postApplyAction = residual.map(MaterializationPostApplyAction.replayResidual)
            let overlapShift = max(1, windowCount / 2)
            let lower: Int
            switch direction {
            case .older:
                lower = max(0, previousMaterializationState.windowBounds.lowerBound - overlapShift)
            case .newer:
                lower = min(
                    max(0, totalCount - windowCount),
                    previousMaterializationState.windowBounds.lowerBound + overlapShift
                )
            }
            nextBounds = WindowBounds(lowerBound: lower, upperBound: min(totalCount, lower + windowCount))
        case let .directTarget(targetIndex, count, action):
            pendingDirectNavigationBySessionKey.removeValue(forKey: sessionKey)
            totalCount = count
            firstUnreadProjectedIndex = nil
            viewportAnchor = nil
            postApplyAction = action
            nextBounds = centeredWindowBounds(targetIndex: targetIndex, totalCount: count, count: windowCount)
        case let .projectionEdge(tail, action):
            if tail, activeProjectionKey.base == .transcript, activeProjectionKey.searchQuery.isEmpty {
                pendingTranscriptTruthBottomBySessionKey.removeValue(forKey: sessionKey)
            }
            guard let previousMaterializationState else {
                return MaterializationPlan(stage: .full, windowBounds: .empty, unreadOutsideTailWindow: false, revision: 0)
            }
            totalCount = previousMaterializationState.logicalTotalCount
            firstUnreadProjectedIndex = nil
            viewportAnchor = nil
            postApplyAction = action
            nextBounds = tail
                ? tailWindowBounds(totalCount: totalCount, count: windowCount)
                : WindowBounds(lowerBound: 0, upperBound: min(windowCount, totalCount))
        case .projectionSelected, .directTargetRequested, .directTargetCancelled,
             .transcriptTruthTargetRequested:
            preconditionFailure("projectionSelected handled before state transition")
        }

        if totalCount <= 0 {
            let emptyState = MaterializationState(
                stage: .full,
                windowBounds: .empty,
                unreadOutsideTailWindow: false,
                logicalTotalCount: 0,
                revision: (previousMaterializationState?.revision ?? 0) + 1
            )
            storeMaterializationState(emptyState, sessionKey: sessionKey)
            pendingMaterializationEffectBySessionKey.removeValue(forKey: sessionKey)
            logMaterializationStateChange(
                sessionKey: sessionKey,
                from: previousMaterializationState,
                to: materializationStateBySessionKey[sessionKey],
                reason: "advanceMaterialization totalCount<=0 event=\(describeMaterializationEvent(event))"
            )
            return MaterializationPlan(
                stage: .full,
                windowBounds: .empty,
                unreadOutsideTailWindow: false,
                revision: materializationStateBySessionKey[sessionKey]?.revision ?? 0
            )
        }

        let stage: MaterializationStage = totalCount <= windowCount ? .full : .tail
        let unreadOutsideWindow = firstUnreadProjectedIndex.map {
            $0 < nextBounds.lowerBound || $0 >= nextBounds.upperBound
        } ?? false
        let state = MaterializationState(
            stage: stage,
            windowBounds: nextBounds,
            unreadOutsideTailWindow: unreadOutsideWindow,
            logicalTotalCount: totalCount,
            revision: (previousMaterializationState?.revision ?? 0) + 1
        )
        storeMaterializationState(state, sessionKey: sessionKey)
        if viewportAnchor != nil || postApplyAction != nil {
            pendingMaterializationEffectBySessionKey[sessionKey] = MaterializationEffect(
                sessionKey: sessionKey,
                projectionKey: activeProjectionKey,
                materializationRevision: state.revision,
                restoreGeneration: readState(for: sessionKey).restoreGeneration,
                viewportAnchor: viewportAnchor,
                postApplyAction: postApplyAction
            )
        } else {
            pendingMaterializationEffectBySessionKey.removeValue(forKey: sessionKey)
        }
        logMaterializationStateChange(
            sessionKey: sessionKey,
            from: previousMaterializationState,
            to: state,
            reason: "advanceMaterialization bounded event=\(describeMaterializationEvent(event))"
        )
        return MaterializationPlan(
            stage: stage,
            windowBounds: nextBounds,
            unreadOutsideTailWindow: unreadOutsideWindow,
            revision: state.revision
        )
    }

    private func tailWindowBounds(totalCount: Int, count: Int) -> WindowBounds {
        let lower = max(0, totalCount - count)
        return WindowBounds(lowerBound: lower, upperBound: totalCount)
    }

    private func centeredWindowBounds(targetIndex: Int, totalCount: Int, count: Int) -> WindowBounds {
        let window = BoundedMessageWindow.containing(
            targetIndex: targetIndex,
            totalCount: totalCount,
            limit: count
        )
        return WindowBounds(lowerBound: window.lowerBound, upperBound: window.upperBound)
    }


    private func runMaterializationRefreshPass() {
        guard let viewModel else { return }
        update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            keepsKeyboardPinned: keepsKeyboardPinned,
            isTypingActive: isTypingActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            trailingContentInset: trailingContentInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            onOpenDetail: onOpenDetail,
            sessionKey: channelOverride,
            sessionStatus: sessionStatus,
            sessionStatusUnavailable: sessionStatusUnavailable,
            streamSearchQuery: streamSearchQuery,
            forceReReadGeneration: 0,
            sendIndicatorRevision: viewModel.sendIndicatorRevision,
            onScrollEvent: onScrollEvent,
            onTypingIndicatorTap: onTypingIndicatorTap,
            onTypingIndicatorAnchorFrameChanged: onTypingIndicatorAnchorFrameChanged,
            onSessionControlSelected: onSessionControlSelected,
            onFooterTestMenuSelected: onFooterTestMenuSelected,
            onInsertMessageIntoPrompt: onInsertMessageIntoPrompt,
            onReferenceMessageInPrompt: onReferenceMessageInPrompt,
            onShowOnlyUserMessagesModeChanged: onShowOnlyUserMessagesModeChanged,
            onStreamSearchQueryChanged: onStreamSearchQueryChanged,
            onKeyboardDismissModeChanged: onKeyboardDismissModeChanged,
            isDark: currentIsDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
    }

    private func performMaterializationPostApplyAction(
        _ action: MaterializationPostApplyAction,
        sessionKey: String
    ) {
        guard callbackSessionKey() == sessionKey else { return }
        switch action {
        case let .scrollProjectionEdge(tail, animated):
            if tail {
                scrollToActiveProjectionBottom(animated: animated)
            } else {
                finishScrollToTop(animated: animated)
            }
        case let .replayResidual(residual):
            scrollByGestureDelta(residual)
        case let .centerMessage(id, animated, flash):
            scrollToMessageCentered(messageId: id, animated: animated)
            if flash {
                requestFlashMessage(messageId: id, isUnreadTap: true)
            }
        }
    }

    @discardableResult
    private func shiftMaterializationWindowIfNeeded(
        sessionKey: String,
        requestedDirection: MaterializationShiftDirection? = nil,
        residual: CGFloat? = nil
    ) -> Bool {
        guard !collectionView.isDragging,
              !collectionView.isTracking,
              !collectionView.isDecelerating,
              let state = materializationStateBySessionKey[sessionKey],
              state.logicalTotalCount > 0,
              state.stage == .tail
        else { return false }

        collectionView.layoutIfNeeded()
        let minY = -collectionView.contentInset.top
        let maxY = max(
            minY,
            collectionView.contentSize.height - collectionView.bounds.height + collectionView.contentInset.bottom
        )
        let atOlderEdge = collectionView.contentOffset.y <= minY + 1
        let atNewerEdge = collectionView.contentOffset.y >= maxY - 1
        let direction: MaterializationShiftDirection
        if let requestedDirection {
            direction = requestedDirection
        } else if atOlderEdge {
            direction = .older
        } else if atNewerEdge {
            direction = .newer
        } else {
            return false
        }
        guard (direction == .older && atOlderEdge && state.windowBounds.lowerBound > 0)
                || (direction == .newer && atNewerEdge && state.windowBounds.upperBound < state.logicalTotalCount)
        else { return false }

        guard let viewportAnchor = captureBubbleSizingV2ViewportAnchor() else {
            // Settled edge shifts require a fully visible message anchor; without one,
            // defer the shift until a stable anchor can be captured.
            return false
        }
        let previousLowerBound = state.windowBounds.lowerBound
        let plan = enqueueMaterializationEvent(
            sessionKey: sessionKey,
            event: .edgeShift(direction: direction, residual: residual, viewportAnchor: viewportAnchor)
        )
        guard plan.windowBounds.lowerBound != previousLowerBound else { return false }
        StreamSwitchTiming.log(
            "materialization_window_shift direction=\(direction == .older ? "older" : "newer") bounds=\(plan.windowBounds.lowerBound)..<\(plan.windowBounds.upperBound)",
            sessionKey: sessionKey
        )
        runMaterializationRefreshPass()
        return true
    }

    @discardableResult
    private func materializeWindowContainingMessage(
        sessionKey: String,
        messageId: String,
        animated: Bool,
        flash: Bool
    ) -> Bool {
        guard let viewModel,
              let key = activeMaterializationProjectionKeyBySessionKey[sessionKey],
              let transcriptProjection = viewModel.messageProjection(
                  for: sessionKey,
                  showOnlyUserMessages: false,
                  searchQuery: ""
              ),
              transcriptProjection.containsTranscriptMessage(id: messageId)
        else { return false }

        guard let projection = viewModel.messageProjection(
            for: sessionKey,
            showOnlyUserMessages: key.base == .userOnly,
            searchQuery: key.searchQuery
        ) else {
            viewModel.requestMessageProjection(
                for: sessionKey,
                showOnlyUserMessages: key.base == .userOnly,
                searchQuery: key.searchQuery
            )
            _ = enqueueMaterializationEvent(
                sessionKey: sessionKey,
                event: .directTargetRequested(id: messageId, animated: animated, flash: flash)
            )
            return true
        }
        guard let targetIndex = projection.projectedIndex(of: messageId) else {
            if !key.searchQuery.isEmpty {
                _ = enqueueMaterializationEvent(
                    sessionKey: sessionKey,
                    event: .directTargetRequested(id: messageId, animated: animated, flash: flash)
                )
                onStreamSearchQueryChanged?(sessionKey, "")
                return true
            }
            if key.base == .userOnly,
               let message = transcriptProjection.message(
                   at: transcriptProjection.projectedIndex(of: messageId) ?? -1
               )
            {
                _ = enqueueMaterializationEvent(
                    sessionKey: sessionKey,
                    event: .directTargetRequested(id: message.id, animated: animated, flash: flash)
                )
                setShowOnlyUserMessagesMode(false)
                return true
            }
            return false
        }
        guard let state = materializationStateBySessionKey[sessionKey],
              !(state.windowBounds.lowerBound ..< state.windowBounds.upperBound).contains(targetIndex)
        else { return false }

        _ = enqueueMaterializationEvent(
            sessionKey: sessionKey,
            event: .directTarget(
                projectedIndex: targetIndex,
                totalCount: projection.count,
                action: .centerMessage(id: messageId, animated: animated, flash: flash)
            )
        )
        runMaterializationRefreshPass()
        return true
    }

    @discardableResult
    private func materializeProjectionEdge(sessionKey: String, tail: Bool, animated: Bool) -> Bool {
        guard let state = materializationStateBySessionKey[sessionKey], state.logicalTotalCount > 0 else {
            return false
        }
        let windowCount = Self.stagedMaterializationTailWindowCount(
            isShowingOnlyUserMessages: activeMaterializationProjectionKeyBySessionKey[sessionKey]?.base == .userOnly
        )
        let bounds = tail ? tailWindowBounds(totalCount: state.logicalTotalCount, count: windowCount) : WindowBounds(lowerBound: 0, upperBound: min(windowCount, state.logicalTotalCount))
        guard bounds.lowerBound != state.windowBounds.lowerBound else { return false }
        _ = enqueueMaterializationEvent(
            sessionKey: sessionKey,
            event: .projectionEdge(
                tail: tail,
                action: .scrollProjectionEdge(tail: tail, animated: animated)
            )
        )
        runMaterializationRefreshPass()
        return true
    }

    private func drainQueuedUpdateIfPossible() {
        guard !isUpdatePassInFlight, !isSnapshotApplyInFlight else { return }
        if !queuedDiffableSnapshotApplies.isEmpty {
            let apply = queuedDiffableSnapshotApplies.removeFirst()
            apply()
            return
        }
        if isWebBubbleSnapshotApplyQueued {
            applySnapshotForWebBubbles()
            return
        }
        if !pendingReconfigureIds.isEmpty {
            applyPendingReconfiguresIfPossible()
            return
        }
        guard let request = queuedUpdateRequest else { return }
        queuedUpdateRequest = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.update(
                viewModel: request.viewModel,
                isCompact: request.isCompact,
                isActiveSession: request.isActiveSession,
                isRenderPolicyFrozen: request.isRenderPolicyFrozen,
                isInputActive: request.isInputActive,
                keepsKeyboardPinned: request.keepsKeyboardPinned,
                isTypingActive: request.isTypingActive,
                topInset: request.topInset,
                truncationBottomInset: request.truncationBottomInset,
                trailingContentInset: request.trailingContentInset,
                firstUnreadMessageId: request.firstUnreadMessageId,
                unreadCount: request.unreadCount,
                onExpand: request.onExpand,
                onOpenDetail: request.onOpenDetail,
                sessionKey: request.sessionKey,
                sessionStatus: request.sessionStatus,
                sessionStatusUnavailable: request.sessionStatusUnavailable,
                streamSearchQuery: request.streamSearchQuery,
                forceReReadGeneration: request.forceReReadGeneration,
                sendIndicatorRevision: request.sendIndicatorRevision,
                onScrollEvent: request.onScrollEvent,
                onTypingIndicatorTap: request.onTypingIndicatorTap,
                onTypingIndicatorAnchorFrameChanged: request.onTypingIndicatorAnchorFrameChanged,
                onSessionControlSelected: request.onSessionControlSelected,
                onFooterTestMenuSelected: request.onFooterTestMenuSelected,
                onInsertMessageIntoPrompt: request.onInsertMessageIntoPrompt,
                onReferenceMessageInPrompt: request.onReferenceMessageInPrompt,
                onShowOnlyUserMessagesModeChanged: request.onShowOnlyUserMessagesModeChanged,
                onStreamSearchQueryChanged: request.onStreamSearchQueryChanged,
                onKeyboardDismissModeChanged: request.onKeyboardDismissModeChanged,
                isDark: request.isDark,
                allowsTransparentWindowBackground: request.allowsTransparentWindowBackground
            )
        }
    }

    private func markSnapshotApplyCompleted() {
        isSnapshotApplyInFlight = false
        drainQueuedUpdateIfPossible()
    }

    private func applyDiffableSnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<Int, String>,
        animatingDifferences: Bool,
        sessionKey: String? = nil,
        animationDuration: TimeInterval? = nil,
        completion: (() -> Void)? = nil
    ) {
        // Diffable data sources trap on reentrant snapshot applies. Keep every
        // MessageFlowCollectionView snapshot mutation behind this seam so future
        // render triggers queue behind the active apply instead of bypassing it.
        guard !isSnapshotApplyInFlight else {
            queuedDiffableSnapshotApplies.append { [weak self] in
                self?.applyDiffableSnapshot(
                    snapshot,
                    animatingDifferences: animatingDifferences,
                    sessionKey: sessionKey,
                    animationDuration: animationDuration,
                    completion: completion
                )
            }
            return
        }
        isSnapshotApplyInFlight = true
        if let sessionKey {
            StreamSwitchTiming.log("dataSource_apply_start", sessionKey: sessionKey)
        }
        let applySnapshot = { [weak self] in
            guard let self else { return }
            self.dataSource.apply(snapshot, animatingDifferences: animatingDifferences) { [weak self] in
                completion?()
                if let sessionKey {
                    StreamSwitchTiming.log("dataSource_apply_end", sessionKey: sessionKey)
                }
                self?.markSnapshotApplyCompleted()
            }
        }
        if let animationDuration {
            UIView.transition(
                with: collectionView,
                duration: animationDuration,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: applySnapshot
            )
        } else {
            applySnapshot()
        }
    }

    private func shouldDeferUpdateDuringActiveTyping(
        _ request: UpdateRequest,
        effectiveSessionKey: String
    ) -> Bool {
        guard request.isTypingActive, request.isInputActive else { return false }
        let currentEffectiveSessionKey = channelOverride ?? viewModel?.engineActiveSessionKey
        guard currentEffectiveSessionKey == effectiveSessionKey else { return false }
        guard (request.sessionKey ?? request.viewModel.engineActiveSessionKey) == effectiveSessionKey else {
            return false
        }
        guard channelOverride == request.sessionKey else { return false }
        guard self.isCompact == request.isCompact,
              self.isActiveSession == request.isActiveSession,
              self.isRenderPolicyFrozen == request.isRenderPolicyFrozen,
              self.isInputActive == request.isInputActive,
              self.keepsKeyboardPinned == request.keepsKeyboardPinned,
              self.currentSendIndicatorRevision == request.sendIndicatorRevision,
              self.streamSearchQuery == request.streamSearchQuery,
              abs(self.topInset - request.topInset) <= 0.5,
              abs(self.trailingContentInset - max(0, request.trailingContentInset)) <= 0.5,
              self.firstUnreadMessageId == request.firstUnreadMessageId,
              self.unreadCount == request.unreadCount else {
            return false
        }
        // Multiline composer growth changes truncationBottomInset while typing.
        // Deferring the active-session update until typing settles keeps those height changes
        // from forcing a full list update on each line-wrap tick.  (#148)
        if let isDark = request.isDark, currentIsDark != isDark {
            return false
        }
        if allowsTransparentWindowBackground != request.allowsTransparentWindowBackground {
            return false
        }
        return true
    }

    func update(
        viewModel: ChatViewModel,
        isCompact: Bool,
        isActiveSession: Bool,
        isRenderPolicyFrozen: Bool,
        isInputActive: Bool,
        keepsKeyboardPinned: Bool,
        isTypingActive: Bool,
        topInset: CGFloat,
        truncationBottomInset: CGFloat,
        trailingContentInset: CGFloat = 0,
        firstUnreadMessageId: String?,
        unreadCount: Int,
        onExpand: ((Message) -> Void)? = nil,
        onOpenDetail: ((Message) -> Void)? = nil,
        sessionKey: String? = nil,
        sessionStatus: SessionStatus? = nil,
        sessionStatusUnavailable: Bool = false,
        streamSearchQuery: String = "",
        forceReReadGeneration: Int = 0,
        sendIndicatorRevision: Int = 0,
        fontScaleChangeSequence: Int = 0,
        onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)? = nil,
        onTypingIndicatorTap: (@MainActor (CGRect) -> Void)? = nil,
        onTypingIndicatorAnchorFrameChanged: (@MainActor (CGRect?) -> Void)? = nil,
        onSessionControlSelected: (@MainActor (String, SessionControlAction, String?, Bool?) -> Void)? = nil,
        onFooterTestMenuSelected: (@MainActor (FooterTestMenuAction) -> Void)? = nil,
        onInsertMessageIntoPrompt: (@MainActor (Message) -> Void)? = nil,
        onReferenceMessageInPrompt: (@MainActor (Message) -> Void)? = nil,
        onShowOnlyUserMessagesModeChanged: (@MainActor (String, Bool) -> Void)? = nil,
        onStreamSearchQueryChanged: (@MainActor (String, String) -> Void)? = nil,
        onKeyboardDismissModeChanged: (@MainActor (String) -> Void)? = nil,
        isDark: Bool? = nil,
        allowsTransparentWindowBackground: Bool = false
    ) {
        let request = UpdateRequest(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            keepsKeyboardPinned: keepsKeyboardPinned,
            isTypingActive: isTypingActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            trailingContentInset: trailingContentInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            onOpenDetail: onOpenDetail,
            sessionKey: sessionKey,
            sessionStatus: sessionStatus,
            sessionStatusUnavailable: sessionStatusUnavailable,
            streamSearchQuery: streamSearchQuery,
            forceReReadGeneration: forceReReadGeneration,
            sendIndicatorRevision: sendIndicatorRevision,
            fontScaleChangeSequence: fontScaleChangeSequence,
            onScrollEvent: onScrollEvent,
            onTypingIndicatorTap: onTypingIndicatorTap,
            onTypingIndicatorAnchorFrameChanged: onTypingIndicatorAnchorFrameChanged,
            onSessionControlSelected: onSessionControlSelected,
            onFooterTestMenuSelected: onFooterTestMenuSelected,
            onInsertMessageIntoPrompt: onInsertMessageIntoPrompt,
            onReferenceMessageInPrompt: onReferenceMessageInPrompt,
            onShowOnlyUserMessagesModeChanged: onShowOnlyUserMessagesModeChanged,
            onStreamSearchQueryChanged: onStreamSearchQueryChanged,
            onKeyboardDismissModeChanged: onKeyboardDismissModeChanged,
            isDark: isDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
        if isUpdatePassInFlight || isSnapshotApplyInFlight {
            queuedUpdateRequest = request
            return
        }

        let effectiveSessionKey = sessionKey ?? viewModel.engineActiveSessionKey
        if shouldDeferUpdateDuringActiveTyping(request, effectiveSessionKey: effectiveSessionKey) {
            queuedUpdateRequest = request
            return
        }

        isUpdatePassInFlight = true
        defer {
            isUpdatePassInFlight = false
            drainQueuedUpdateIfPossible()
        }

        loadViewIfNeeded()
        let previousLastMessageId = lastMessageId
        let previousSessionStatus = self.sessionStatus
        let previousSessionStatusUnavailable = self.sessionStatusUnavailable
        // Controller-owned for the same reason as the gate below: `self.viewModel`
        // is the SAME instance as the incoming one, so reading both sides off it
        // would always compare equal and the footer would never reconfigure when
        // /api/org-options resolves after the first render.
        let previousHarnessOptions = currentHarnessOptions
        let nextHarnessOptions = viewModel.orgOptionsHarnesses
        currentHarnessOptions = nextHarnessOptions
        // The tightbeam gate decides provenance chrome on every message cell and
        // the harness/host footer items. It flips mid-session (auth completes
        // after cached history has already rendered on a cold launch), so a
        // change must reconfigure what is already on screen. The previous value
        // is held by the CONTROLLER: `self.viewModel` is the same object as the
        // incoming one, so reading the gate off it would always compare equal.
        let previousIsTightbeam = currentIsTightbeam
        let nextIsTightbeam = viewModel.isTightbeamServer
        currentIsTightbeam = nextIsTightbeam
        let previousLiveProgress = self.liveProgress
        let previousStreamSearchQuery = self.streamSearchQuery
        let previousEffectiveSessionKey = callbackSessionKey()
        let wasUserInteracting = isUserInteracting
        let wasPinnedToBottomIntent = sbbState.isPinnedToBottomIntent
        let previousSessionKey = channelOverride
        let nextLiveProgress = viewModel.liveProgress(for: effectiveSessionKey)
        if self.viewModel !== viewModel {
            if let messageRemovalObserverToken {
                self.viewModel?.unregisterMessageRemovalObserver(messageRemovalObserverToken)
            }
            messageRemovalObserverToken = viewModel.registerMessageRemovalObserver { [weak self] sessionKey, messageIds in
                guard let self else { return }
                self.withBoundSessionKey(sessionKey) {
                    _ = self.invalidateFor(reason: .messagesRemoved(Array(messageIds)))
                }
                self.expireRegisteredMessageLoadCallbacks(for: sessionKey, messageIds: messageIds)
            }
        }
        self.viewModel = viewModel
        channelOverride = sessionKey
        self.isActiveSession = isActiveSession
        self.isRenderPolicyFrozen = isRenderPolicyFrozen
        self.isInputActive = isInputActive
        self.keepsKeyboardPinned = keepsKeyboardPinned
        self.isTypingActive = isTypingActive
        self.sessionStatus = sessionStatus
        self.sessionStatusUnavailable = sessionStatusUnavailable
        self.liveProgress = nextLiveProgress
        self.currentSendIndicatorRevision = request.sendIndicatorRevision
        self.onExpand = onExpand
        self.onOpenDetail = onOpenDetail
        self.truncationBottomInset = truncationBottomInset
        self.onScrollEvent = onScrollEvent
        self.onTypingIndicatorTap = onTypingIndicatorTap
        self.onTypingIndicatorAnchorFrameChanged = onTypingIndicatorAnchorFrameChanged
        self.onSessionControlSelected = onSessionControlSelected
        self.onFooterTestMenuSelected = onFooterTestMenuSelected
        self.onInsertMessageIntoPrompt = onInsertMessageIntoPrompt
        self.onReferenceMessageInPrompt = onReferenceMessageInPrompt
        self.onShowOnlyUserMessagesModeChanged = onShowOnlyUserMessagesModeChanged
        self.onStreamSearchQueryChanged = onStreamSearchQueryChanged
        self.onKeyboardDismissModeChanged = onKeyboardDismissModeChanged
        self.streamSearchQuery = streamSearchQuery
        self.allowsTransparentWindowBackground = allowsTransparentWindowBackground
#if !os(visionOS)
        let desiredDismissMode = MessageFlowCollectionView.keyboardDismissModeForInputFocus(
            isInputActive,
            keepsKeyboardPinned: keepsKeyboardPinned
        )
        if collectionView.keyboardDismissMode != desiredDismissMode {
            collectionView.keyboardDismissMode = desiredDismissMode
        }
        reportKeyboardDismissModeIfNeeded()
#endif
        let nextTrailingContentInset = max(0, request.trailingContentInset)

        // Handle appearance change from SwiftUI colorScheme
        if let isDark = isDark, currentIsDark != isDark {
            logger.info("update: appearance changed isDark=\(isDark, privacy: .public)")
            currentIsDark = isDark
            forceReconfigureAll = true
        }
        if let previousIsTightbeam, previousIsTightbeam != nextIsTightbeam {
            logger.info("update: tightbeam gate changed isTightbeam=\(nextIsTightbeam, privacy: .public)")
            executeInvalidationPlan(invalidateFor(reason: .envChanged))
            forceReconfigureAll = true
        }
        let didFontScaleChange = currentFontScaleChangeSequence != request.fontScaleChangeSequence
        if didFontScaleChange {
            currentFontScaleChangeSequence = request.fontScaleChangeSequence
            executeInvalidationPlan(invalidateFor(reason: .envChanged))
            forceReconfigureAll = true
        }
        if let isDark = isDark {
            let desiredStyle: UIUserInterfaceStyle = isDark ? .dark : .light
            if view.overrideUserInterfaceStyle != desiredStyle {
                view.overrideUserInterfaceStyle = desiredStyle
                collectionView?.overrideUserInterfaceStyle = desiredStyle
            }
            applyChatPageBackground(isDark: isDark)
        }

        collectionView.accessibilityIdentifier = effectiveSessionKey
        StreamSwitchTiming.log("messageFlow_update_enter", sessionKey: effectiveSessionKey)
        let validSessionKeys = Set(viewModel.orderedSessionKeys)
        pruneMaterializationState(validSessionKeys: validSessionKeys)
        prunePerStreamState(validSessionKeys: validSessionKeys)
        runStreamContextSwitchSeam(
            incomingSessionKey: effectiveSessionKey,
            forceReReadGeneration: forceReReadGeneration
        )
        if self.firstUnreadMessageId != firstUnreadMessageId {
            firstUnreadWasBelowViewportCenter = nil
            didCrossAndClearFirstUnreadId = nil
        }
        self.firstUnreadMessageId = firstUnreadMessageId
        self.unreadCount = unreadCount
        let isOffscreenSession = sessionKey != nil && !isActiveSession
        if isRenderPolicyFrozen {
            // Render policy `.frozen` applies to ALL pages, including the outgoing engine-active page.
            // We suppress starting new snapshot/apply/layout work during pager animation.
            // Any apply already in flight is allowed to finish normally.
            StreamSwitchTiming.log("messageFlow_update_skipped_frozen", sessionKey: effectiveSessionKey)
            // A refresh suppressed by the frozen policy never reaches snapshot completion;
            // leave the next real changed snapshot eligible to emit the activation pulse.
            pendingMaterializationEffectBySessionKey.removeValue(forKey: effectiveSessionKey)
            return
        }
        let needsFullLayout = forceReconfigureAll
            || didFontScaleChange
            || self.isCompact != isCompact
            || self.topInset != topInset
            || self.trailingContentInset != nextTrailingContentInset
            || previousSessionKey != sessionKey
        self.isCompact = isCompact
        self.topInset = topInset
        self.trailingContentInset = nextTrailingContentInset

        if isOffscreenSession {
            pendingMaterializationEffectBySessionKey.removeValue(forKey: effectiveSessionKey)
            return
        }

        if needsFullLayout {
            updateLayout()
        }

        let shouldPreserveSearchScrollAnchor = previousEffectiveSessionKey == effectiveSessionKey
            && previousStreamSearchQuery != streamSearchQuery
            && previousLastMessageId != nil
        let searchScrollAnchor = shouldPreserveSearchScrollAnchor && !wasPinnedToBottomIntent
            ? captureStreamSearchViewportAnchor()
            : nil

        let isShowingOnlyUserMessages = readState(for: effectiveSessionKey).isShowingOnlyUserMessages
        guard let transcriptProjection = viewModel.messageProjection(
            for: effectiveSessionKey,
            showOnlyUserMessages: false,
            searchQuery: ""
        ) else { return }
        let messageSetIdentity = MessageSetIdentity(
            sessionKey: effectiveSessionKey,
            messageCount: transcriptProjection.count,
            lastMessageId: transcriptProjection.lastMessageId,
            messageListRevision: viewModel.messageListRevision(for: effectiveSessionKey),
            messageProjectionPublicationSequence: viewModel.messageProjectionPublicationSequence,
            isShowingOnlyUserMessages: isShowingOnlyUserMessages,
            streamSearchQuery: streamSearchQuery,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            sessionStatus: sessionStatus,
            liveProgress: nextLiveProgress,
            forceReReadGeneration: forceReReadGeneration,
            sendIndicatorRevision: request.sendIndicatorRevision,
            fontScaleChangeSequence: request.fontScaleChangeSequence,
            isCompact: isCompact,
            topInset: topInset,
            trailingContentInset: nextTrailingContentInset,
            truncationBottomInset: truncationBottomInset,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground,
            isDark: isDark
        )
        if !needsFullLayout,
           lastAppliedMessageSetIdentity == messageSetIdentity,
           lastAppliedMaterializationRevisionBySessionKey[effectiveSessionKey]
               == materializationStateBySessionKey[effectiveSessionKey]?.revision
        {
            StreamSwitchTiming.log("messageFlow_update_fast_path", sessionKey: effectiveSessionKey)
            if isActiveSession {
                viewModel.markEngineActivationRenderedIfNeeded(for: effectiveSessionKey)
            }
            return
        }

        let projectionKey = MaterializationProjectionKey(
            base: isShowingOnlyUserMessages ? .userOnly : .transcript,
            searchQuery: streamSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        _ = enqueueMaterializationEvent(
            sessionKey: effectiveSessionKey,
            event: .projectionSelected(projectionKey)
        )
        viewModel.requestMessageProjection(
            for: effectiveSessionKey,
            showOnlyUserMessages: isShowingOnlyUserMessages,
            searchQuery: streamSearchQuery
        )
        guard let projection = viewModel.messageProjection(
            for: effectiveSessionKey,
            showOnlyUserMessages: isShowingOnlyUserMessages,
            searchQuery: streamSearchQuery
        ) else {
            StreamSwitchTiming.log("materialization_projection_pending", sessionKey: effectiveSessionKey)
            return
        }

        let appendedMessageIDs = previousEffectiveSessionKey == effectiveSessionKey
            ? transcriptProjection.messageIds(after: previousLastMessageId, limit: Self.maxIncrementalArrivalIDs + 1)
            : []
        let messageCount = transcriptProjection.count

        StreamSwitchTiming.log("snapshot_build_start", sessionKey: effectiveSessionKey)
        let previousMaterializationState = materializationStateBySessionKey[effectiveSessionKey]
        let followsProjectionTail = previousMaterializationState == nil
            || previousMaterializationState?.windowBounds.upperBound == previousMaterializationState?.logicalTotalCount
        let pendingRevealTargetIndex = pendingShowOnlyUserMessagesRevealTargetBySessionKey[effectiveSessionKey]
            .flatMap { projection.projectedIndex(of: $0) }
        let persistedLocation = readState(for: effectiveSessionKey).pendingScrollRestoreState
        let persistedBase = projectionKey.base == .userOnly ? "userOnly" : "transcript"
        let persistedLocationMatchesProjection = persistedLocation?.projectionBase == persistedBase
            && (persistedLocation?.searchQuery ?? "") == projectionKey.searchQuery
        let materializationEvent: MaterializationEvent
        if let animated = pendingTranscriptTruthBottomBySessionKey[effectiveSessionKey] {
            if !projectionKey.searchQuery.isEmpty {
                onStreamSearchQueryChanged?(effectiveSessionKey, "")
                return
            } else if projectionKey.base == .userOnly {
                setShowOnlyUserMessagesMode(false)
                return
            }
            materializationEvent = .projectionEdge(
                tail: true,
                action: .scrollProjectionEdge(tail: true, animated: animated)
            )
        } else if let pendingDirectNavigation = pendingDirectNavigationBySessionKey[effectiveSessionKey] {
            if let targetIndex = projection.projectedIndex(of: pendingDirectNavigation.messageId) {
                materializationEvent = .directTarget(
                    projectedIndex: targetIndex,
                    totalCount: projection.count,
                    action: .centerMessage(
                        id: pendingDirectNavigation.messageId,
                        animated: pendingDirectNavigation.animated,
                        flash: pendingDirectNavigation.flash
                    )
                )
            } else if !projectionKey.searchQuery.isEmpty {
                onStreamSearchQueryChanged?(effectiveSessionKey, "")
                return
            } else if projectionKey.base == .userOnly {
                setShowOnlyUserMessagesMode(false)
                return
            } else {
                _ = enqueueMaterializationEvent(
                    sessionKey: effectiveSessionKey,
                    event: .directTargetCancelled
                )
                materializationEvent = .messagesUpdated(
                    totalCount: projection.count,
                    firstUnreadProjectedIndex: firstUnreadMessageId.flatMap { projection.projectedIndex(of: $0) },
                    followsProjectionTail: followsProjectionTail
                )
            }
        } else if let pendingRevealTargetIndex {
            let windowCount = Self.stagedMaterializationTailWindowCount(
                isShowingOnlyUserMessages: isShowingOnlyUserMessages
            )
            materializationEvent = .shifted(
                windowBounds: centeredWindowBounds(
                    targetIndex: pendingRevealTargetIndex,
                    totalCount: projection.count,
                    count: windowCount
                ),
                totalCount: projection.count,
                viewportAnchor: nil,
                postApplyAction: nil
            )
        } else if previousMaterializationState == nil,
                  persistedLocationMatchesProjection,
                  let persistedLowerBound = persistedLocation?.projectionLowerBound
        {
            let windowCount = Self.stagedMaterializationTailWindowCount(
                isShowingOnlyUserMessages: isShowingOnlyUserMessages
            )
            materializationEvent = .shifted(
                windowBounds: WindowBounds(
                    lowerBound: persistedLowerBound,
                    upperBound: min(projection.count, persistedLowerBound + windowCount)
                ),
                totalCount: projection.count,
                viewportAnchor: nil,
                postApplyAction: nil
            )
        } else {
            materializationEvent = .messagesUpdated(
                totalCount: projection.count,
                firstUnreadProjectedIndex: firstUnreadMessageId.flatMap { projection.projectedIndex(of: $0) },
                followsProjectionTail: followsProjectionTail
            )
        }
        let pendingSerializedPlan: MaterializationPlan? = {
            guard let effect = pendingMaterializationEffectBySessionKey[effectiveSessionKey],
                  effect.projectionKey == projectionKey,
                  effect.materializationRevision == materializationStateBySessionKey[effectiveSessionKey]?.revision,
                  effect.materializationRevision != lastAppliedMaterializationRevisionBySessionKey[effectiveSessionKey]
            else { return nil }
            return lastMaterializationPlanBySessionKey[effectiveSessionKey]
        }()
        let materializationPlan = pendingSerializedPlan ?? enqueueMaterializationEvent(
            sessionKey: effectiveSessionKey,
            event: materializationEvent
        )
        let materializedMessages = projection.messages(
            in: materializationPlan.windowBounds.lowerBound ..< materializationPlan.windowBounds.upperBound
        )
        messagesById = Dictionary(uniqueKeysWithValues: materializedMessages.map { ($0.id, $0) })
        let newFingerprints = Dictionary(
            uniqueKeysWithValues: materializedMessages.map { ($0.id, fingerprint(for: $0)) }
        )
        let isFirstActivationForSession = previousMaterializationState == nil
        let snapshotMessages = materializedMessages
        lastMessages = materializedMessages
        activeWindowReachesProjectionTail = materializationPlan.windowBounds.upperBound == projection.count
        let effectiveStream = viewModel.streamType(for: effectiveSessionKey)
        lastEffectiveStream = effectiveStream
        webBubbleCoordinator.currentStream = effectiveStream
        let snapshotMessageIds = snapshotMessages.map(\.id)
        let snapshotItemIds = isShowingOnlyUserMessages
            ? snapshotMessageIds
            : snapshotItemsWithWebBubbles(
                from: snapshotItemsWithSubstrateRunCollapse(
                    from: snapshotItemsWithSegmentAnchor(
                        from: snapshotItemsWithMarkerDivider(
                            from: snapshotItemsWithDateSeparators(from: snapshotMessages),
                            messages: snapshotMessages
                        )
                    )
                ),
                stream: effectiveStream
            )
        logScrollRestore(
            "materializationStage.start sessionKey=\(effectiveSessionKey) stage=\(materializationPlan.stage.rawValue) firstActivation=\(isFirstActivationForSession) snapshotMessages=\(snapshotMessageIds.count) totalMessages=\(messageCount) pendingRestore={\(describePersistedScrollState(readState(for: effectiveSessionKey).pendingScrollRestoreState))}"
        )
        StreamSwitchTiming.log(
            "materialization_plan stage=\(materializationPlan.stage.rawValue) items=\(snapshotItemIds.count) total=\(messageCount)",
            sessionKey: effectiveSessionKey
        )
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        let oldItemIds = Set(dataSource.snapshot().itemIdentifiers)

        // Add typing indicator when assistant is typing (server-controlled)
        // Only show on the matching channel page (for paged TabView)
        let wasShowingTypingIndicatorBeforeUpdate = wasShowingTypingIndicator
        let showTypingIndicator = !isShowingOnlyUserMessages && viewModel.shouldShowPromptStageIndicator(in: effectiveSessionKey)
        let typingIndicatorJustAppeared = showTypingIndicator && !wasShowingTypingIndicatorBeforeUpdate
        if showTypingIndicator != wasShowingTypingIndicator {
            let wasShowingTypingIndicator = wasShowingTypingIndicator
            logger.info("typing indicator state changed: show=\(showTypingIndicator, privacy: .public) wasShowing=\(wasShowingTypingIndicator, privacy: .public)")
        }
        wasShowingTypingIndicator = showTypingIndicator
        if showTypingIndicator {
            snapshot.appendItems(TranscriptTypingIndicatorOrdering.itemIds(
                messageItems: snapshotItemIds,
                messages: snapshotMessages,
                typingIndicatorItemId: TypingIndicatorCell.itemId,
                activePromptMessageId: viewModel.promptStageIndicatorAnchorMessageId(in: effectiveSessionKey)
            ))
        } else {
            snapshot.appendItems(snapshotItemIds)
        }
        if materializationPlan.windowBounds.upperBound == projection.count,
           SessionMetadataFooterCell.shouldAppendFooter(after: snapshotMessageIds, status: sessionStatus)
        {
            snapshot.appendItems([SessionMetadataFooterCell.itemId])
        }
        StreamSwitchTiming.log("snapshot_build_end", sessionKey: effectiveSessionKey)
        assert(
            snapshot.numberOfItems <= Self.maximumBoundedSnapshotItemCount(
                messageWindowCount: Self.stagedMaterializationTailWindowCount(
                    isShowingOnlyUserMessages: isShowingOnlyUserMessages
                )
            )
        )

        let newItemIds = Set(snapshot.itemIdentifiers)
        let insertedIds = newItemIds.subtracting(oldItemIds)
        let newestMessageId = transcriptProjection.lastMessageId
        let morphTargetMessageId = viewModel.typingIndicatorMorphTargetMessageId(in: effectiveSessionKey)
        let shouldMorph = TypingIndicatorMorph.shouldMorph(
            wasShowingTypingIndicator: wasShowingTypingIndicatorBeforeUpdate,
            targetMessageId: morphTargetMessageId,
            insertedIds: insertedIds
        )
        let showOnlyUserMessagesAnimationDuration = showOnlyUserMessagesTransitionSessionKeys.remove(effectiveSessionKey) == nil
            ? nil
            : ShowOnlyUserMessagesChatCollapse.animationDuration
        let shouldApplyTypingMorph = shouldMorph && showOnlyUserMessagesAnimationDuration == nil
        if let morphTargetMessageId,
           transcriptProjection.containsTranscriptMessage(id: morphTargetMessageId) {
            viewModel.consumeTypingIndicatorMorphTargetMessageId(morphTargetMessageId, in: effectiveSessionKey)
        }

        // #51: Subtle entrance animation for newly inserted bubbles when we're already at the bottom.
        if let newestMessageId,
           insertedIds.contains(newestMessageId),
           insertedIds.count <= 2,
           isNearBottom(extraMargin: 200),
           !shouldApplyTypingMorph,
           !needsFullLayout
        {
            pendingEntranceAnimationIds.insert(newestMessageId)
        }

        let materializedIdSet = Set(snapshotMessageIds)
        let changedIds = (needsFullLayout
            ? snapshotMessageIds
            : newFingerprints.compactMap { id, fingerprint in
                fingerprints[id] == fingerprint ? nil : id
            }).filter { materializedIdSet.contains($0) }
        if !changedIds.isEmpty {
            snapshot.reconfigureItems(changedIds)
            for id in changedIds {
                let plan = invalidateFor(reason: .messageChanged(id: id))
                executeInvalidationPlan(plan)
            }
            changedIds.forEach { invalidateBubbleSizingV2Cache(for: $0) }
            removeBubbleV2PreviewVersions(for: changedIds)
        }
        if previousSessionStatus != sessionStatus
            || previousSessionStatusUnavailable != sessionStatusUnavailable
            || (previousHarnessOptions ?? nextHarnessOptions) != nextHarnessOptions
            || (previousIsTightbeam ?? nextIsTightbeam) != nextIsTightbeam,
           snapshot.indexOfItem(SessionMetadataFooterCell.itemId) != nil,
           oldItemIds.contains(SessionMetadataFooterCell.itemId)
        {
            snapshot.reconfigureItems([SessionMetadataFooterCell.itemId])
        }
        if previousLiveProgress != nextLiveProgress,
           snapshot.indexOfItem(TypingIndicatorCell.itemId) != nil,
           oldItemIds.contains(TypingIndicatorCell.itemId)
        {
            snapshot.reconfigureItems([TypingIndicatorCell.itemId])
        }
        forceReconfigureAll = false

        let didLastMessageChange = (previousLastMessageId != newestMessageId)
        let isIncrementalAppend = Self.isBoundedIncrementalArrival(
            previousLastMessageId: previousLastMessageId,
            appendedMessageIDs: appendedMessageIDs
        )
        let shouldAutoScrollToBottomAfterApply = didLastMessageChange
            && isIncrementalAppend
            && wasPinnedToBottomIntent
            && !wasUserInteracting
            && !shouldApplyTypingMorph
        let shouldAttemptActivationCompletion = isActiveSession
            && viewModel.isEngineActivationRenderPending(for: effectiveSessionKey)

        let revealTargetMessageId = pendingShowOnlyUserMessagesRevealTargetBySessionKey.removeValue(forKey: effectiveSessionKey)
        let materializationEffect = pendingMaterializationEffectBySessionKey[effectiveSessionKey]
        let effectMatchesApply = materializationEffect.map {
            $0.sessionKey == effectiveSessionKey
                && $0.projectionKey == activeMaterializationProjectionKeyBySessionKey[effectiveSessionKey]
                && $0.materializationRevision == materializationPlan.revision
                && $0.restoreGeneration == readState(for: effectiveSessionKey).restoreGeneration
        } ?? false
        let afterSnapshotApplied: (() -> Void) = { [weak self] in
            guard let self else { return }
            guard self.callbackSessionKey() == effectiveSessionKey else { return }
            let currentEffect = self.pendingMaterializationEffectBySessionKey[effectiveSessionKey]
            let shouldConsumeEffect = effectMatchesApply
                && currentEffect?.materializationRevision == materializationEffect?.materializationRevision
                && currentEffect?.projectionKey == materializationEffect?.projectionKey
                && self.readState(for: effectiveSessionKey).restoreGeneration == materializationEffect?.restoreGeneration
#if DEBUG
            if shouldConsumeEffect {
                self._debugEffectApplyCompletionCountBySessionKey[effectiveSessionKey, default: 0] += 1
            }
#endif
            if shouldConsumeEffect {
                self.pendingMaterializationEffectBySessionKey.removeValue(forKey: effectiveSessionKey)
            }
            let runtimeState = self.readState(for: effectiveSessionKey)
            let hasAuthoritativeRestoreTarget = runtimeState.pendingScrollRestoreState.map { !$0.atBottom } ?? false
            if self.allowsAutomatedPostApplyScrolling,
               Self.shouldScheduleBottomFallbackAfterApply(
                hasAuthoritativeRestoreTarget: hasAuthoritativeRestoreTarget,
                restorePhaseIsNone: runtimeState.restorePhase == .none,
                isIncrementalAppend: isIncrementalAppend,
                previousLastMessageId: previousLastMessageId
            ) {
                self.logScrollRestore("afterSnapshotApplied.bottomFallback sessionKey=\(effectiveSessionKey) stage=\(materializationPlan.stage.rawValue)")
                self.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: false, attempts: 1)
            }
            self.logScrollRestore("afterSnapshotApplied.restoreAttemptRegister sessionKey=\(effectiveSessionKey) stage=\(materializationPlan.stage.rawValue)")
            self.scheduleRestoreAttemptOnMessageAppearance(
                sessionKey: effectiveSessionKey,
                stage: materializationPlan.stage,
                snapshotMessageIds: snapshotMessageIds
            )
            if shouldAutoScrollToBottomAfterApply,
               Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: hasAuthoritativeRestoreTarget)
            {
                // Race-sensitive: the contentSize can change again after diffable applies.
                // A few post-apply attempts preserves the historical “always end up at the bottom” behavior.
                self.logScrollRestore("afterSnapshotApplied.autoScrollToBottom sessionKey=\(effectiveSessionKey) stage=\(materializationPlan.stage.rawValue)")
                self.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true, attempts: 3)
            } else if shouldAutoScrollToBottomAfterApply {
                self.logScrollRestore("afterSnapshotApplied.autoScrollToBottom.disqualified sessionKey=\(effectiveSessionKey) stage=\(materializationPlan.stage.rawValue) reason=savedRestoreTargetIsAuthoritative")
            }
            self.fireRegisteredMessageLoadCallbacksIfMaterialized(
                for: effectiveSessionKey,
                messageIds: snapshotMessageIds
            )
            // Stream-switch engine activation completion is defined as:
            // first active-page snapshot materialization after engineActiveSessionKey commit.
            // This is the point where ChatView can safely clear the spinner gate.
            if shouldAttemptActivationCompletion {
                viewModel.markEngineActivationRenderedIfNeeded(for: effectiveSessionKey)
            }
            self.updateVisibleFooterAlpha()
            self.notifyTypingIndicatorAnchorFrameIfNeeded()
            if let revealTargetMessageId {
                self.scrollToMessageCentered(messageId: revealTargetMessageId, animated: true)
                self.requestFlashMessage(messageId: revealTargetMessageId, isUnreadTap: false)
            }
            if shouldConsumeEffect, let action = materializationEffect?.postApplyAction {
                self.performMaterializationPostApplyAction(action, sessionKey: effectiveSessionKey)
            }
            if shouldConsumeEffect {
#if DEBUG
                if materializationEffect?.viewportAnchor != nil {
                    self._debugViewportCompensationAttemptCountBySessionKey[effectiveSessionKey, default: 0] += 1
                }
#endif
                self.scheduleBubbleSizingV2ViewportAnchorCompensation(materializationEffect?.viewportAnchor)
            }
        }

        if shouldApplyTypingMorph {
            applySnapshotWithTypingMorphIfPossible(
                snapshot: snapshot,
                targetMessageId: morphTargetMessageId,
                onApplied: { [weak self] in
                    afterSnapshotApplied()
                    if shouldPreserveSearchScrollAnchor, wasPinnedToBottomIntent {
                        self?.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: false, attempts: 2)
                    } else {
                        self?.scheduleStreamSearchViewportAnchorRestoration(searchScrollAnchor)
                    }
                },
                onAppliedSessionKey: effectiveSessionKey
            )
        } else {
            applyDiffableSnapshot(
                snapshot,
                animatingDifferences: showOnlyUserMessagesAnimationDuration != nil,
                sessionKey: effectiveSessionKey,
                animationDuration: showOnlyUserMessagesAnimationDuration
            ) { [weak self] in
                afterSnapshotApplied()
                if shouldPreserveSearchScrollAnchor, wasPinnedToBottomIntent {
                    self?.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: false, attempts: 2)
                } else {
                    self?.scheduleStreamSearchViewportAnchorRestoration(searchScrollAnchor)
                }
            }
        }
        logger.info(
            "diffing apply snapshot count=\(messageCount, privacy: .public) changed=\(changedIds.count, privacy: .public) needsLayout=\(needsFullLayout, privacy: .public) morph=\(shouldMorph, privacy: .public)"
        )
        fingerprints.merge(newFingerprints) { _, current in current }
        lastAppliedMessageSetIdentity = messageSetIdentity
        lastAppliedMaterializationRevisionBySessionKey[effectiveSessionKey] = materializationPlan.revision

        if lastMessageId != newestMessageId {
            lastMessageId = newestMessageId
            if shouldMorph {
                // Only defer the post-morph scroll if we would have auto-scrolled (user was pinned to bottom).
                let shouldDeferBottomScroll = isIncrementalAppend
                    && wasPinnedToBottomIntent
                    && !wasUserInteracting
                    && Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: pendingScrollRestoreState.map { !$0.atBottom } ?? false)
                if isIncrementalAppend, wasPinnedToBottomIntent, !wasUserInteracting, !shouldDeferBottomScroll {
                    logScrollRestore("postMorph.scrollToBottom.disqualified sessionKey=\(effectiveSessionKey) reason=savedRestoreTargetIsAuthoritative")
                }
                deferScrollToBottomUntilMorphCompletes = shouldDeferBottomScroll
            } else if isIncrementalAppend {
                if wasPinnedToBottomIntent {
                    // ContentAppended while pinned: never enter unread mode.
                    // Auto-scroll now, or defer until drag ends.
                    if wasUserInteracting {
                        if Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: pendingScrollRestoreState.map { !$0.atBottom } ?? false) {
                            pendingScrollToBottomAfterInteractionEnd = true
                        } else {
                            logScrollRestore("incrementalAppend.deferScroll.disqualified sessionKey=\(effectiveSessionKey) reason=savedRestoreTargetIsAuthoritative")
                        }
                    } else if Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: pendingScrollRestoreState.map { !$0.atBottom } ?? false) {
                        scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true, attempts: 3)
                    } else {
                        logScrollRestore("incrementalAppend.scrollToBottom.disqualified sessionKey=\(effectiveSessionKey) reason=savedRestoreTargetIsAuthoritative")
                    }
                } else {
                    emit(.didReceiveNewMessagesWhileScrolledUp(sessionKey: effectiveSessionKey, newMessageIDs: appendedMessageIDs))
                }
            } else if !wasUserInteracting {
                // T036: On cold start, restore the last scroll position instead of forcing a reset-to-bottom.
                // For actual stream swaps/resets without a persisted anchor, default to bottom.
                if let pendingScrollRestoreState {
                    if pendingScrollRestoreState.atBottom {
                        logScrollRestore("postApply.pendingAtBottomState sessionKey=\(effectiveSessionKey) reason=restoreStateAlreadyAtBottom")
                    }
                } else if previousLastMessageId != nil {
                    // Preserve prior behavior on resets/stream swaps: default to bottom when the last id changes
                    // but we can't reliably classify it as an incremental append.
                    logScrollRestore("postApply.defaultStreamSwapScroll sessionKey=\(effectiveSessionKey)")
                    scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true)
                }
            }
        } else if typingIndicatorJustAppeared {
            // Only keep the typing indicator visible if the user is already pinned near the bottom.
            if wasPinnedToBottomIntent, !wasUserInteracting,
               Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: pendingScrollRestoreState.map { !$0.atBottom } ?? false)
            {
                logScrollRestore("typingIndicator.scrollToBottom sessionKey=\(effectiveSessionKey)")
                scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true)
            } else if wasPinnedToBottomIntent, !wasUserInteracting {
                logScrollRestore("typingIndicator.scrollToBottom.disqualified sessionKey=\(effectiveSessionKey) reason=savedRestoreTargetIsAuthoritative")
            } else if wasPinnedToBottomIntent, wasUserInteracting {
                // Defer the scroll; never show the SBB while within the at-bottom threshold.
                if Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: pendingScrollRestoreState.map { !$0.atBottom } ?? false) {
                    pendingScrollToBottomAfterInteractionEnd = true
                } else {
                    logScrollRestore("typingIndicator.deferScroll.disqualified sessionKey=\(effectiveSessionKey) reason=savedRestoreTargetIsAuthoritative")
                }
            }
        }
        withBoundSessionKey(effectiveSessionKey) {
            syncUnreadStateWithSBBState()
            handleContentUpdateCompletion()
        }
    }

    static func appendedMessageIDs(previousLastMessageId: String?, messageIDs: [String]) -> [String] {
        guard let previousLastMessageId else { return [] }
        guard let idx = messageIDs.firstIndex(of: previousLastMessageId) else { return [] }
        let next = messageIDs.index(after: idx)
        guard next < messageIDs.endIndex else { return [] }
        return Array(messageIDs[next...])
    }

    /// Hard ceiling for switch-time arrival bookkeeping. Larger tails are
    /// treated as a normal refresh so no transcript-sized ID mapping occurs
    /// on the main thread.
    static let maxIncrementalArrivalIDs = 99

    static func isBoundedIncrementalArrival(
        previousLastMessageId: String?,
        appendedMessageIDs: [String]
    ) -> Bool {
        previousLastMessageId != nil
            && !appendedMessageIDs.isEmpty
            && appendedMessageIDs.count <= maxIncrementalArrivalIDs
    }

    static func enforcedLiveMeasuredWidth(
        sizeClass: MessageSizeClass,
        measuredWidth: CGFloat,
        maxWidth: CGFloat,
        minWidth: CGFloat
    ) -> CGFloat {
        let effectiveMaxWidth = max(maxWidth, minWidth)
        return (sizeClass == .short)
            ? min(effectiveMaxWidth, max(minWidth, measuredWidth))
            : effectiveMaxWidth
    }

    static func shouldScheduleBottomFallbackAfterApply(
        hasAuthoritativeRestoreTarget: Bool,
        restorePhaseIsNone: Bool,
        isIncrementalAppend: Bool,
        previousLastMessageId: String?
    ) -> Bool {
        guard !hasAuthoritativeRestoreTarget, restorePhaseIsNone else { return false }
        // Guardrail: a plain append must not force-jump to bottom while reading history.
        guard !isIncrementalAppend else { return false }
        // Keep the one-time initial bottom placement behavior for first population only.
        return previousLastMessageId == nil
    }

    private var allowsAutomatedPostApplyScrolling: Bool {
#if DEBUG
        !_debugSuppressAutomatedPostApplyScrolling
#else
        true
#endif
    }

    static func shouldFallbackToAbsoluteBottom(lastMessageId: String?, hasMessageAnchor: Bool) -> Bool {
        guard lastMessageId != nil else { return true }
        return !hasMessageAnchor
    }

    static func shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: Bool) -> Bool {
        !hasAuthoritativeRestoreTarget
    }

    static func shouldAdjustForBottomInsetPinnedPosition(
        hasAuthoritativeRestoreTarget: Bool,
        isPinnedToBottomIntent: Bool,
        isActivelyDraggingOrTracking: Bool
    ) -> Bool {
        isPinnedToBottomIntent && !isActivelyDraggingOrTracking && !hasAuthoritativeRestoreTarget
    }

    static func shouldApplyViewportAnchorCompensation(hasAuthoritativeRestoreTarget: Bool) -> Bool {
        !hasAuthoritativeRestoreTarget
    }

    static func restingBottomContentHeight(
        contentSizeHeight: CGFloat,
        footerHeight: CGFloat,
        hasFooter: Bool,
        excludesFooterRevealRange: Bool = MessageFlowCollectionViewController.excludesFooterRevealRangeAtRestingBottom
    ) -> CGFloat {
        guard hasFooter, excludesFooterRevealRange else { return contentSizeHeight }
        return max(0, contentSizeHeight - footerHeight)
    }

    static var excludesFooterRevealRangeAtRestingBottom: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        true
#endif
    }

    static var hidesFooterAtRestingBottom: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        true
#endif
    }

    static func bottomOffsetMaxY(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let minY = -topInset
        return max(minY, contentHeight - boundsHeight + bottomInset)
    }

    static func footerRevealAlpha(
        contentOffsetY: CGFloat,
        chatBubbleBottomOffsetY: CGFloat,
        revealDistance: CGFloat,
        hidesFooterAtRestingBottom: Bool = MessageFlowCollectionViewController.hidesFooterAtRestingBottom
    ) -> CGFloat {
        guard chatBubbleBottomOffsetY.isFinite, revealDistance.isFinite else { return 0 }
        if !hidesFooterAtRestingBottom {
            return 1
        }
        guard revealDistance > 0 else { return 0 }
        let revealedDistance = contentOffsetY - chatBubbleBottomOffsetY
        return min(1, max(0, revealedDistance / revealDistance))
    }

    static func initialFooterCellAlpha(
        contentOffsetY: CGFloat,
        chatBubbleBottomOffsetY: CGFloat,
        revealDistance: CGFloat,
        hidesFooterAtRestingBottom: Bool = MessageFlowCollectionViewController.hidesFooterAtRestingBottom
    ) -> CGFloat {
        footerRevealAlpha(
            contentOffsetY: contentOffsetY,
            chatBubbleBottomOffsetY: chatBubbleBottomOffsetY,
            revealDistance: revealDistance,
            hidesFooterAtRestingBottom: hidesFooterAtRestingBottom
        )
    }

    static func shouldRunUpdateAfterBoundsChange(
        measurementInputsChanged: Bool,
        hadPendingFullReconfigure: Bool
    ) -> Bool {
        measurementInputsChanged || hadPendingFullReconfigure
    }

    private func isNonMessageItemID(_ id: String) -> Bool {
        id == TypingIndicatorCell.itemId
            || id == SessionMetadataFooterCell.itemId
            || DateSeparatorCell.isDateSeparatorItemID(id)
            || id.hasPrefix(Self.substrateRunItemIdPrefix)
            || MarkerDividerCell.isMarkerDividerItemID(id)
            || messagesById[id]?.messageKind == .substrate
            || messagesById[id]?.messageKind == .agent
    }

    private func snapshotItemsWithDateSeparators(from messages: [Message]) -> [String] {
        guard !messages.isEmpty else {
            dateSeparatorTextByItemId = [:]
            return []
        }

        var items: [String] = []
        items.reserveCapacity(messages.count * 2)

        var separatorTextByItemID: [String: String] = [:]
        var previousDayStart: Date?
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()

        for message in messages {
            let dayStart = ChatDateLabelCalendar.startOfDay(for: message.timestamp, calendar: calendar)
            if let previousDayStart, !ChatDateLabelCalendar.isSameDay(dayStart, previousDayStart, calendar: calendar) {
                let separatorID = DateSeparatorCell.itemID(before: message.id)
                items.append(separatorID)
                separatorTextByItemID[separatorID] = Self.dateSeparatorText(for: dayStart, now: now)
            }
            previousDayStart = dayStart
            items.append(message.id)
        }

        dateSeparatorTextByItemId = separatorTextByItemID
        return items
    }

    /// Insert one divider at the first message strictly after the latest
    /// .sessionInfo firing. The boundary must fall inside the visible
    /// transcript so the divider always separates real messages on both
    /// sides. No semantic marker kind is inferred from message text.
    ///
    /// OpenClaw invariant: `.sessionInfo` fires on auth success for ANY
    /// backend, tightbeam or OpenClaw -- it is not itself a tightbeam-only
    /// signal, unlike the classifier's provenance-origin heuristic. Gate on
    /// `isTightbeamServer` (the same flag `showsProvenanceChrome` already
    /// uses for this exact concern) so an OpenClaw session never grows a
    /// divider it didn't have before.
    private func snapshotItemsWithMarkerDivider(from items: [String], messages: [Message]) -> [String] {
        guard viewModel?.isTightbeamServer == true else { return items }
        guard let boundaryTimestamp = viewModel?.lastReliableBoundaryTimestamp else { return items }
        guard let firstAfterIndex = messages.firstIndex(where: { $0.timestamp > boundaryTimestamp }),
              firstAfterIndex > 0
        else {
            return items
        }
        let anchorMessageID = messages[firstAfterIndex].id
        let dividerID = MarkerDividerCell.itemID(before: anchorMessageID)
        guard let insertionIndex = items.firstIndex(of: anchorMessageID) else { return items }
        var result = items
        result.insert(dividerID, at: insertionIndex)
        return result
    }

    /// Segment-anchor (step 3b): when active, hides everything STRICTLY
    /// BEFORE the marker divider -- a transient VIEW of the already-built
    /// item list, not a reclassification, so it adds no new measurement or
    /// grouping work. A no-op when no divider is present (nothing to anchor
    /// on yet). The divider itself is deliberately KEPT (not sliced away):
    /// it is the only tap target that toggles this state, so dropping it
    /// once anchored would strand the user with no affordance to un-anchor.
    private func snapshotItemsWithSegmentAnchor(from items: [String]) -> [String] {
        guard isSegmentAnchorActive,
              let dividerIndex = items.firstIndex(where: { MarkerDividerCell.isMarkerDividerItemID($0) })
        else {
            return items
        }
        return Array(items[dividerIndex...])
    }

    /// Toggle segment-anchor and reapply the snapshot, same reentrancy-safe
    /// path as toggleSubstrateRunExpansion (crash history #140/#148/#149).
    private func toggleSegmentAnchor() {
        isSegmentAnchorActive.toggle()
        applySnapshotForWebBubbles()
    }

    private static let substrateRunItemIdPrefix = "__substrate_run__|"

    /// Collapse RUNS of 2+ consecutive .substrate classified message ids
    /// into one synthetic collapsed-run item id, unless that run is
    /// currently expanded (transient state). Non-message ids (date
    /// separators, etc) break a run, same as a visible interruption would.
    /// Grouping is computed fresh here each snapshot build (view-model DATA,
    /// no measurement/layout work) so step-2's chrome never adds main-thread
    /// churn to the MessageFlow hotspot.
    private func snapshotItemsWithSubstrateRunCollapse(from itemIds: [String]) -> [String] {
        guard !itemIds.isEmpty else {
            substrateRunMemberIdsByItemId = [:]
            expandedRunMemberMessageIds = []
            return itemIds
        }

        var result: [String] = []
        result.reserveCapacity(itemIds.count)
        var runMembers: [String: [String]] = [:]
        var expandedMembers: Set<String> = []
        var pendingRun: [String] = []

        func flushPendingRun() {
            guard !pendingRun.isEmpty else { return }
            if pendingRun.count == 1 {
                result.append(pendingRun[0])
            } else {
                let anchorId = Self.substrateRunItemIdPrefix + pendingRun[0]
                runMembers[anchorId] = pendingRun
                if expandedSubstrateRunItemIds.contains(anchorId) {
                    result.append(contentsOf: pendingRun)
                    expandedMembers.formUnion(pendingRun)
                } else {
                    result.append(anchorId)
                }
            }
            pendingRun = []
        }

        for id in itemIds {
            // messagesById[id] is nil for every synthetic id (typing
            // indicator, footer, date separator) -- no need to also consult
            // isNonMessageItemID here (and doing so would be circular: that
            // function now excludes substrate messages FROM bubble-sizing
            // purposes by consulting this same classification).
            guard let message = messagesById[id], message.messageKind == .substrate else {
                flushPendingRun()
                result.append(id)
                continue
            }
            pendingRun.append(id)
        }
        flushPendingRun()

        substrateRunMemberIdsByItemId = runMembers
        expandedRunMemberMessageIds = expandedMembers
        return result
    }

    /// Toggle a collapsed run's transient expansion state and reapply the
    /// snapshot. applySnapshotForWebBubbles() already recomputes the full
    /// item list via snapshotItemsWithSubstrateRunCollapse (wired into its
    /// pipeline above) under its existing isUpdatePassInFlight /
    /// isSnapshotApplyInFlight reentrancy guard -- reused here rather than a
    /// second ad hoc snapshot-mutation path in this crash-scarred file
    /// (#140 reentrant snapshot-apply, #148/#149 freezes).
    private func toggleSubstrateRunExpansion(anchorItemId: String) {
        if expandedSubstrateRunItemIds.contains(anchorItemId) {
            expandedSubstrateRunItemIds.remove(anchorItemId)
        } else {
            expandedSubstrateRunItemIds.insert(anchorItemId)
        }
        applySnapshotForWebBubbles()
    }

    private static func dateSeparatorText(for day: Date, now: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if ChatDateLabelCalendar.isSameDay(day, now, calendar: calendar) {
            return relativeDayFormatter.string(from: day)
        }
        if ChatDateLabelCalendar.isYesterday(day, now: now, calendar: calendar) {
            return relativeDayFormatter.string(from: day)
        }
        if calendar.isDate(day, equalTo: now, toGranularity: .weekOfYear) {
            return weekdayFormatter.string(from: day)
        }
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            return monthDayFormatter.string(from: day)
        }
        return fullDateFormatter.string(from: day)
    }

    private static let relativeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeStyle = .none
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMM d")
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMM d, y")
        return formatter
    }()

    private func emit(_ event: MessageFlowScrollEvent) {
        onScrollEvent?(event)
    }

    private func setSBBState(_ newState: SBBState) {
        guard sbbState != newState else { return }
        sbbState = newState
        emitHideIndicatorIfChanged(force: true)
    }

    private func setSBBState(_ newState: SBBState, sessionKey: String) {
        withBoundSessionKey(sessionKey) {
            setSBBState(newState)
        }
    }

    private func emitHideIndicatorIfChanged(force: Bool = false) {
        // Keep the existing event contract: `isAtBottom=true` means "hide the SBB and clear unread".
        // Pinned intent means we may report `true` even if transient geometry isn't at the last pixel.
        let shouldHide = sbbState.shouldHideIndicator
        guard let sessionKey = callbackSessionKey() else { return }
        if force || lastReportedHideIndicator != shouldHide {
            lastReportedHideIndicator = shouldHide
            emit(.isAtBottomChanged(sessionKey: sessionKey, isAtBottom: shouldHide))
        }
    }

    private func restingBottomContentHeight() -> CGFloat {
        return Self.restingBottomContentHeight(
            contentSizeHeight: collectionView.contentSize.height,
            footerHeight: SessionMetadataFooterCell.height(
                for: sessionStatus,
                width: availableContentWidth(),
                compatibleWith: traitCollection,
                isTightbeam: viewModel?.isTightbeamServer ?? false,
                harnessOptions: viewModel?.orgOptionsHarnesses ?? []
            ),
            hasFooter: dataSource.indexPath(for: SessionMetadataFooterCell.itemId) != nil
        )
    }

    private func restingBottomOffsetMaxY(bottomInset: CGFloat) -> CGFloat {
        Self.bottomOffsetMaxY(
            contentHeight: restingBottomContentHeight(),
            boundsHeight: collectionView.bounds.height,
            topInset: collectionView.contentInset.top,
            bottomInset: bottomInset
        )
    }

    private func chatBubbleBottomOffsetY(bottomInset: CGFloat) -> CGFloat? {
        guard let lastDisplayedMessageId = dataSource.snapshot().itemIdentifiers.reversed().first(where: {
                  messagesById[$0] != nil
              }),
              let lastMessageIndexPath = dataSource.indexPath(for: lastDisplayedMessageId),
              let lastMessageAttributes = collectionView.layoutAttributesForItem(at: lastMessageIndexPath)
        else {
            return nil
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let chatContentBottom = lastMessageAttributes.frame.maxY
            + metrics.flowGap
            + flowLayout.sectionInset.bottom
        return Self.bottomOffsetMaxY(
            contentHeight: chatContentBottom,
            boundsHeight: collectionView.bounds.height,
            topInset: collectionView.contentInset.top,
            bottomInset: bottomInset
        )
    }

    private func distanceFromBottomClamped() -> CGFloat {
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = restingBottomOffsetMaxY(bottomInset: currentBottomInset)
        guard maxY.isFinite, minY.isFinite else { return .greatestFiniteMagnitude }
        let offsetY = collectionView.contentOffset.y
        let clampedOffsetY = min(max(offsetY, minY), maxY)
        let distance = max(0, maxY - clampedOffsetY)
        return distance.isFinite ? distance : .greatestFiniteMagnitude
    }

    private func footerRevealAlpha() -> CGFloat {
        guard dataSource.indexPath(for: SessionMetadataFooterCell.itemId) != nil else { return 1 }
        guard Self.hidesFooterAtRestingBottom else { return 1 }
        guard let chatBubbleBottomOffsetY = chatBubbleBottomOffsetY(bottomInset: currentBottomInset) else { return 0 }
        return Self.footerRevealAlpha(
            contentOffsetY: collectionView.contentOffset.y,
            chatBubbleBottomOffsetY: chatBubbleBottomOffsetY,
            revealDistance: SessionMetadataFooterCell.fadeRevealRange
        )
    }

#if DEBUG
    var footerAlphaForTesting: CGFloat {
        footerRevealAlpha()
    }

    var chatBubbleBottomOffsetYForTesting: CGFloat {
        chatBubbleBottomOffsetY(bottomInset: currentBottomInset) ?? .nan
    }

    var displayedFooterAlphaForTesting: CGFloat? {
        guard let indexPath = dataSource.indexPath(for: SessionMetadataFooterCell.itemId) else { return nil }
        return collectionView.cellForItem(at: indexPath)?.alpha
    }

    var footerFrameForTesting: CGRect? {
        guard let indexPath = dataSource.indexPath(for: SessionMetadataFooterCell.itemId) else { return nil }
        collectionView.layoutIfNeeded()
        return collectionView.layoutAttributesForItem(at: indexPath)?.frame
    }

    var footerViewportFrameForTesting: CGRect? {
        footerFrameForTesting.map { collectionView.convert($0, to: collectionView) }
    }

    var footerViewportBoundsForTesting: CGRect {
        CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
    }

    func setChatScrollOffsetYForTesting(_ contentOffsetY: CGFloat) {
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: contentOffsetY),
            animated: false
        )
        updateVisibleFooterAlpha()
    }
#endif

    private func updateVisibleFooterAlpha() {
        guard let indexPath = dataSource.indexPath(for: SessionMetadataFooterCell.itemId),
              let cell = collectionView.cellForItem(at: indexPath)
        else {
            return
        }
        cell.alpha = footerRevealAlpha()
    }

    private func handleUserScrolled() {
        if isUserInteracting, suspendScrollPersistenceUntilRestoreConfirmed {
            pendingScrollRestoreState = nil
            restorePhase = .confirmed
            suspendScrollPersistenceUntilRestoreConfirmed = false
        }
        let bottomInset = collectionView.contentInset.bottom
        let bottomInsetChanged: Bool
        if let previousBottomInset = lastSeenBottomInsetForSBB {
            bottomInsetChanged = abs(bottomInset - previousBottomInset) > 0.5
        } else {
            bottomInsetChanged = false
        }
        lastSeenBottomInsetForSBB = bottomInset

        let withinBottomThreshold = distanceFromBottomClamped() <= Self.atBottomThreshold

        if isUserInteracting {
            switch sbbState {
            case .atBottom, .atBottomDragging:
                if !withinBottomThreshold {
                    // Keyboard interactive dismiss and other inset changes can cause transient contentOffset
                    // bounces that look like “scrolled up”. Those must NOT reveal the SBB.
                    if bottomInsetChanged { break }
                    // Only user scroll can leave pinned-to-bottom states.
                    setSBBState(unreadCount > 0 ? .scrolledUpUnread : .scrolledUp)
                }
            case .scrolledUp, .scrolledUpUnread:
                if withinBottomThreshold {
                    setSBBState(.atBottomDragging)
                }
            }
        } else {
            switch sbbState {
            case .scrolledUp, .scrolledUpUnread:
                if withinBottomThreshold {
                    setSBBState(.atBottom)
                }
            case .atBottom, .atBottomDragging:
                // Pinned intent: ignore geometry that looks \"not at bottom\" when not user-interacting.
                break
            }
        }

        emitHideIndicatorIfChanged()
    }

    private func handleUserScrolled(sessionKey: String) {
        withBoundSessionKey(sessionKey) {
            handleUserScrolled()
        }
        refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
    }

    private func handleUserScrollSettled() {
        // If the user is no longer interacting, normalize dragging->atBottom when within threshold.
        guard !isUserInteracting else { return }
        if sbbState == .atBottomDragging,
           distanceFromBottomClamped() <= Self.atBottomThreshold
        {
            setSBBState(.atBottom)
        }
        emitHideIndicatorIfChanged()
    }

    private func handleUserScrollSettled(sessionKey: String) {
        withBoundSessionKey(sessionKey) {
            handleUserScrollSettled()
        }
        refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
    }

    private func handleProgrammaticScrollEnded() {
        handleUserScrollSettled()
    }

    private func handleProgrammaticScrollEnded(sessionKey: String) {
        withBoundSessionKey(sessionKey) {
            handleProgrammaticScrollEnded()
        }
        refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
    }

    private func handleContentUpdateCompletion() {
        // ContentAppended/Mutated does not change pinned state. If we're scrolled up, visibility is stable.
        emitHideIndicatorIfChanged()
    }

    private func syncUnreadStateWithSBBState() {
        switch sbbState {
        case .scrolledUp where unreadCount > 0:
            setSBBState(.scrolledUpUnread)
        case .scrolledUpUnread where unreadCount <= 0:
            setSBBState(.scrolledUp)
        default:
            break
        }
    }

    func requestFlashMessage(messageId: String, isUnreadTap: Bool) {
        pendingFlashMessageId = messageId
        pendingFlashIsUnreadTap = isUnreadTap
        performPendingFlashIfPossible()
        guard let sessionKey = callbackSessionKey() else { return }
        registerOnMessageLoad(sessionKey: sessionKey, messageId: messageId) { [weak self] in
            self?.performPendingFlashIfPossible()
        }
    }

    private func performPendingFlashIfPossible() {
        guard let messageId = pendingFlashMessageId else { return }
        guard let indexPath = dataSource.indexPath(for: messageId) else { return }
        guard let cell = collectionView.cellForItem(at: indexPath) else { return }
        guard let bubbleCell = cell as? MessageBubbleUIKitCell else { return }
        let isUnreadTap = pendingFlashIsUnreadTap
        pendingFlashMessageId = nil
        pendingFlashIsUnreadTap = false
        bubbleCell.flashUnreadAnchorHighlight(isUnreadTap: isUnreadTap)
    }

    private func checkFirstUnreadCrossingIfNeeded() {
        guard unreadCount > 0 else {
            firstUnreadWasBelowViewportCenter = nil
            didCrossAndClearFirstUnreadId = nil
            return
        }
        guard let messageId = firstUnreadMessageId else { return }
        if didCrossAndClearFirstUnreadId == messageId { return }
        guard let indexPath = dataSource.indexPath(for: messageId) else {
            guard let sessionKey = callbackSessionKey() else { return }
            if viewModel?.messageProjection(
                for: sessionKey,
                showOnlyUserMessages: false,
                searchQuery: ""
            )?.containsTranscriptMessage(id: messageId) == true {
                registerOnMessageLoad(sessionKey: sessionKey, messageId: messageId) { [weak self] in
                    self?.checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
                }
                return
            }
            let materializationState = materializationStateBySessionKey[sessionKey]
            if materializationState?.stage == .tail,
               materializationState?.unreadOutsideTailWindow == true
            {
                // Tail stage intentionally does not materialize the full history yet.
                // Missing unread marker here is expected and must not clear unread state.
                registerOnMessageLoad(sessionKey: sessionKey, messageId: messageId) { [weak self] in
                    self?.checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
                }
                return
            }
            // Spec: if the unread anchor disappears from the dataset, clear unread immediately.
            unreadCount = 0
            firstUnreadWasBelowViewportCenter = nil
            didCrossAndClearFirstUnreadId = messageId
            if sbbState == .scrolledUpUnread {
                setSBBState(.scrolledUp)
            }
            emit(.didInvalidateFirstUnreadAnchor(sessionKey: sessionKey))
            return
        }
        collectionView.layoutIfNeeded()
        guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }

        let contentInset = collectionView.contentInset
        let visibleHeight = collectionView.bounds.height - contentInset.top - contentInset.bottom
        guard visibleHeight > 1 else { return }
        let visibleTopY = collectionView.contentOffset.y + contentInset.top
        let viewportCenterY = visibleTopY + (visibleHeight * 0.5)
        let bubbleTopY = attrs.frame.minY
        let isBelowCenter = bubbleTopY > viewportCenterY

        if let wasBelow = firstUnreadWasBelowViewportCenter,
           wasBelow,
           !isBelowCenter
        {
            // Invariant: clearing-by-scroll triggers when the TOP edge crosses the viewport center, with a flash.
            didCrossAndClearFirstUnreadId = messageId
            pendingFlashMessageId = messageId
            pendingFlashIsUnreadTap = false
            performPendingFlashIfPossible()
            unreadCount = 0
            if sbbState == .scrolledUpUnread {
                setSBBState(.scrolledUp)
            }
            if let sessionKey = callbackSessionKey() {
                emit(.didCrossFirstUnreadCenter(sessionKey: sessionKey, messageId: messageId))
            }
        }

        firstUnreadWasBelowViewportCenter = isBelowCenter
    }

    private func checkFirstUnreadCrossingIfNeeded(sessionKey: String) {
        withBoundSessionKey(sessionKey) {
            checkFirstUnreadCrossingIfNeeded()
        }
    }

    private func performPendingDeferredScrollToBottomIfNeeded(sessionKey: String) {
        guard pendingScrollToBottomAfterInteractionEnd else { return }
        guard !isUserInteracting else { return }
        pendingScrollToBottomAfterInteractionEnd = false
        if !Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: hasAuthoritativePersistedRestoreTarget(sessionKey: sessionKey)) {
            logScrollRestore("deferredInteractionEnd.scrollToBottom.disqualified sessionKey=\(sessionKey) reason=savedRestoreTargetIsAuthoritative")
            return
        }
        scheduleScrollToBottom(sessionKey: sessionKey, animated: true, attempts: 3)
    }

    private func runStreamContextSwitchSeam(incomingSessionKey: String, forceReReadGeneration: Int) {
        guard !incomingSessionKey.isEmpty else { return }

        let isMaterialized = materializationStateBySessionKey[incomingSessionKey] != nil
        let currentOffsetY: String
        if let collectionView {
            currentOffsetY = formatScrollRestore(collectionView.contentOffset.y)
        } else {
            currentOffsetY = "unavailable"
        }
        logScrollRestore(
            "runStreamContextSwitchSeam sessionKey=\(incomingSessionKey) materialized=\(isMaterialized) streamState=\(isMaterialized ? "revisit" : "fresh") currentOffsetY=\(currentOffsetY)"
        )

        let outgoingSessionKey = lastAppliedEffectiveSessionKey
        let incomingState = readState(for: incomingSessionKey)
        let isSameKeyReRead = outgoingSessionKey == incomingSessionKey
            && forceReReadGeneration > incomingState.lastSeenForceReReadGeneration

        if let outgoingSessionKey, outgoingSessionKey != incomingSessionKey {
            persistScrollStateNow(sessionKey: outgoingSessionKey, bypassSuspension: true)
            cancelDeferredWork(for: outgoingSessionKey, cancelAll: true)
            clearRegisteredMessageLoadCallbacks(for: outgoingSessionKey)
        }

        if isSameKeyReRead {
            prepareSameKeyReread(sessionKey: incomingSessionKey)
            mutateState(for: incomingSessionKey) { state in
                state.lastSeenForceReReadGeneration = forceReReadGeneration
            }
            lastAppliedEffectiveSessionKey = incomingSessionKey
            emitHideIndicatorIfChanged()
            return
        }

        guard outgoingSessionKey != incomingSessionKey else {
            mutateState(for: incomingSessionKey) { state in
                state.lastSeenForceReReadGeneration = max(state.lastSeenForceReReadGeneration, forceReReadGeneration)
            }
            lastAppliedEffectiveSessionKey = incomingSessionKey
            emitHideIndicatorIfChanged()
            return
        }

        prepareIncomingStateOnSwitch(sessionKey: incomingSessionKey, allowTailStage: true)
        mutateState(for: incomingSessionKey) { state in
            state.restoreGeneration &+= 1
            state.restoreConfirmationRetries = 0
            state.suspendScrollPersistenceUntilRestoreConfirmed = state.pendingScrollRestoreState != nil
            state.lastSeenForceReReadGeneration = max(state.lastSeenForceReReadGeneration, forceReReadGeneration)
        }
        lastAppliedEffectiveSessionKey = incomingSessionKey
        emitHideIndicatorIfChanged(force: true)
    }

    private func scrollStateDefaultsKey(for persistenceKey: String) -> String {
        "clawline.scrollState.v1.\(persistenceKey)"
    }

    private func scrollStateDefaultsKey(for persistenceKey: String,
                                        projectionBase: String?,
                                        searchQuery: String?) -> String {
        let base = projectionBase ?? "transcript"
        let query = (searchQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = query.isEmpty ? base : "\(base).search.\(query)"
        return "\(scrollStateDefaultsKey(for: persistenceKey)).\(suffix)"
    }

    private func persistScrollSnapshot(_ snapshot: ScrollSnapshot, for persistenceKey: String) {
        let projectionKey = activeMaterializationProjectionKeyBySessionKey[persistenceKey]
        let materializationState = materializationStateBySessionKey[persistenceKey]
        let state = PersistedScrollState(
            atBottom: snapshot.atBottom,
            distanceFromBottom: Double(snapshot.distanceFromBottom),
            savedAtEpochSeconds: snapshot.timestamp,
            projectionBase: projectionKey.map { $0.base == .userOnly ? "userOnly" : "transcript" },
            searchQuery: projectionKey?.searchQuery,
            projectionLowerBound: materializationState?.windowBounds.lowerBound
        )
        do {
            let data = try JSONEncoder().encode(state)
            // Keep independent transcript, user-only, and search locations.
            let projectionKey = scrollStateDefaultsKey(
                for: persistenceKey,
                projectionBase: state.projectionBase,
                searchQuery: state.searchQuery
            )
            UserDefaults.standard.set(data, forKey: projectionKey)
            // Legacy unsuffixed key remains as a migration fallback only.
            UserDefaults.standard.set(data, forKey: scrollStateDefaultsKey(for: persistenceKey))
        } catch {
            logger.error("failed encoding scrollState key=\(persistenceKey, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func liveScrollSnapshotIfAvailable() -> ScrollSnapshot? {
        guard collectionView != nil else { return nil }
        guard collectionView.contentSize.height > 0 else { return nil }
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = restingBottomOffsetMaxY(bottomInset: currentBottomInset)
        guard maxY.isFinite, minY.isFinite else { return nil }
        let offsetY = collectionView.contentOffset.y
        let clampedOffsetY = min(max(offsetY, minY), maxY)
        let distanceFromBottom = max(0, maxY - clampedOffsetY)
        let isAtBottom = distanceFromBottom <= Self.atBottomThreshold
        return ScrollSnapshot(
            atBottom: isAtBottom,
            distanceFromBottom: distanceFromBottom,
            timestamp: Date().timeIntervalSince1970
        )
    }

    private func refreshLastKnownScrollSnapshot(sessionKey: String) {
        guard let snapshot = liveScrollSnapshotIfAvailable() else { return }
        mutateState(for: sessionKey) { $0.lastKnownScrollSnapshot = snapshot }
    }

    private func loadPersistedScrollState(for persistenceKey: String,
                                          projectionBase: String? = nil,
                                          searchQuery: String? = nil) -> PersistedScrollState? {
        let preferredKey = scrollStateDefaultsKey(
            for: persistenceKey,
            projectionBase: projectionBase,
            searchQuery: searchQuery
        )
        let key = UserDefaults.standard.data(forKey: preferredKey) != nil
            ? preferredKey
            : scrollStateDefaultsKey(for: persistenceKey)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let state = try JSONDecoder().decode(PersistedScrollState.self, from: data)
            if key != preferredKey {
                let expectedBase = projectionBase ?? "transcript"
                let expectedQuery = (searchQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard state.projectionBase == expectedBase,
                      (state.searchQuery ?? "") == expectedQuery else { return nil }
            }
            return state
        } catch {
            logger.error("failed decoding scrollState key=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func schedulePersistScrollState(sessionKey: String) {
        let state = readState(for: sessionKey)
        guard !state.suspendScrollPersistenceUntilRestoreConfirmed else { return }
        state.scrollStateWriteDebounceTimer?.invalidate()
        let expectedGeneration = state.restoreGeneration
        let timer = Timer.scheduledTimer(withTimeInterval: Self.scrollStateWriteDebounceSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.readState(for: sessionKey).restoreGeneration == expectedGeneration else { return }
            self.persistScrollStateNow(sessionKey: sessionKey)
        }
        mutateState(for: sessionKey) { runtimeState in
            runtimeState.scrollStateWriteDebounceTimer = timer
        }
    }

    private func persistScrollStateNow(sessionKey persistenceKey: String, bypassSuspension: Bool = false) {
        guard !persistenceKey.isEmpty else { return }
        if !bypassSuspension, readState(for: persistenceKey).suspendScrollPersistenceUntilRestoreConfirmed {
            StreamSwitchTiming.log("scroll_persist_skipped_suspended", sessionKey: persistenceKey)
            return
        }
        if collectionView != nil {
            let contentInset = collectionView.contentInset
            let minY = -contentInset.top
            let maxY = restingBottomOffsetMaxY(bottomInset: currentBottomInset)
            let rawOffsetY = collectionView.contentOffset.y
            let clampedOffsetY = min(max(rawOffsetY, minY), maxY)
            let computedDistance = max(0, maxY - clampedOffsetY)
            let computedAtBottom = computedDistance <= Self.atBottomThreshold
            let rawOffsetYString = String(format: "%.1f", rawOffsetY)
            let clampedOffsetYString = String(format: "%.1f", clampedOffsetY)
            let minYString = String(format: "%.1f", minY)
            let maxYString = String(format: "%.1f", maxY)
            let contentSizeString = String(format: "%.1f", collectionView.contentSize.height)
            let frameHeightString = String(format: "%.1f", collectionView.bounds.height)
            let insetTopString = String(format: "%.1f", contentInset.top)
            let insetBottomString = String(format: "%.1f", contentInset.bottom)
            let computedDistanceString = String(format: "%.1f", computedDistance)
            let thresholdString = String(format: "%.1f", Self.atBottomThreshold)
            StreamSwitchTiming.log(
                "scroll_persist_geometry rawOffsetY=\(rawOffsetYString) clampedOffsetY=\(clampedOffsetYString) minY=\(minYString) maxY=\(maxYString) contentSize=\(contentSizeString) frameHeight=\(frameHeightString) insetTop=\(insetTopString) insetBottom=\(insetBottomString) computedDistance=\(computedDistanceString) threshold=\(thresholdString) computedAtBottom=\(computedAtBottom)",
                sessionKey: persistenceKey
            )
        } else {
            StreamSwitchTiming.log("scroll_persist_geometry unavailable_collectionView", sessionKey: persistenceKey)
        }
        if let snapshot = liveScrollSnapshotIfAvailable() {
            mutateState(for: persistenceKey) { $0.lastKnownScrollSnapshot = snapshot }
            persistScrollSnapshot(snapshot, for: persistenceKey)
            StreamSwitchTiming.log(
                "scroll_persist_flush source=live atBottom=\(snapshot.atBottom) distance=\(String(format: "%.1f", snapshot.distanceFromBottom))",
                sessionKey: persistenceKey
            )
        } else if let snapshot = readState(for: persistenceKey).lastKnownScrollSnapshot {
            persistScrollSnapshot(snapshot, for: persistenceKey)
            StreamSwitchTiming.log(
                "scroll_persist_flush source=fallback atBottom=\(snapshot.atBottom) distance=\(String(format: "%.1f", snapshot.distanceFromBottom))",
                sessionKey: persistenceKey
            )
        }
    }

    private struct RestoreAttemptToken {
        let sessionKey: String
        let generation: Int
        let stage: MaterializationStage
    }

    private func clearRegisteredMessageLoadCallbacks(for sessionKey: String) {
        mutateState(for: sessionKey) { state in
            state.registeredMessageLoadCallbacksByMessageId.removeAll()
        }
    }

    private func expireRegisteredMessageLoadCallbacks(for sessionKey: String, messageIds: Set<String>) {
        guard !messageIds.isEmpty else { return }
        mutateState(for: sessionKey) { state in
            for messageId in messageIds {
                state.registeredMessageLoadCallbacksByMessageId.removeValue(forKey: messageId)
            }
        }
    }

    private func registerOnMessageLoad(
        sessionKey: String,
        messageId: String,
        callback: @escaping @MainActor () -> Void
    ) {
        guard !sessionKey.isEmpty, !messageId.isEmpty else { return }

        let isMaterialized = isMessageMaterialized(sessionKey: sessionKey, messageId: messageId)
        if isMaterialized {
            callback()
            return
        }

        mutateState(for: sessionKey) { state in
            state.registeredMessageLoadCallbacksByMessageId[messageId, default: []].append(callback)
        }
    }

    private func isMessageMaterialized(sessionKey: String, messageId: String) -> Bool {
        guard callbackSessionKey() == sessionKey else { return false }
        guard let indexPath = dataSource.indexPath(for: messageId) else { return false }
        collectionView.layoutIfNeeded()
        return collectionView.layoutAttributesForItem(at: indexPath) != nil
    }

    private func fireRegisteredMessageLoadCallbacksIfMaterialized(for sessionKey: String, messageIds: [String]) {
        guard callbackSessionKey() == sessionKey else { return }
        guard !messageIds.isEmpty else { return }
        collectionView.layoutIfNeeded()
        for messageId in messageIds {
            guard let indexPath = dataSource.indexPath(for: messageId) else { continue }
            guard collectionView.layoutAttributesForItem(at: indexPath) != nil else { continue }
            var callbacks: [PerStreamRuntimeState.MessageLoadCallback] = []
            mutateState(for: sessionKey) { state in
                callbacks = state.registeredMessageLoadCallbacksByMessageId.removeValue(forKey: messageId) ?? []
            }
            callbacks.forEach { $0() }
        }
    }

    private func scheduleRestoreAttemptOnMessageAppearance(
        sessionKey: String,
        stage: MaterializationStage,
        snapshotMessageIds: [String]
    ) {
        guard callbackSessionKey() == sessionKey else { return }
        let state = readState(for: sessionKey)
        guard !state.restoredScrollGenerations.contains(state.restoreGeneration) else { return }
        guard state.pendingScrollRestoreState != nil else { return }
        guard state.restorePhase != .none, state.restorePhase != .confirmed else { return }
        logScrollRestore(
            "scheduleRestoreAttemptOnMessageAppearance sessionKey=\(sessionKey) stage=\(stage.rawValue) restorePhase=\(String(describing: state.restorePhase)) pendingRestore={\(describePersistedScrollState(state.pendingScrollRestoreState))}"
        )

        let token = RestoreAttemptToken(sessionKey: sessionKey, generation: state.restoreGeneration, stage: stage)
        let triggerMessageId = state.lastMessageId ?? snapshotMessageIds.last
        guard let triggerMessageId, !triggerMessageId.isEmpty else {
            attemptRestoreScrollIfNeeded(token: token)
            return
        }
        registerOnMessageLoad(sessionKey: sessionKey, messageId: triggerMessageId) { [weak self] in
            self?.attemptRestoreScrollIfNeeded(token: token)
        }
    }

    private func attemptRestoreScrollIfNeeded(sessionKey: String, stage: MaterializationStage) {
        guard callbackSessionKey() == sessionKey else { return }
        let state = readState(for: sessionKey)
        let token = RestoreAttemptToken(sessionKey: sessionKey, generation: state.restoreGeneration, stage: stage)
        attemptRestoreScrollIfNeeded(token: token)
    }

    private func attemptRestoreScrollIfNeeded(token: RestoreAttemptToken) {
        guard callbackSessionKey() == token.sessionKey else { return }
        let runtimeState = readState(for: token.sessionKey)
        guard runtimeState.restoreGeneration == token.generation else { return }
        guard !runtimeState.restoredScrollGenerations.contains(token.generation) else { return }
        guard let persistedState = runtimeState.pendingScrollRestoreState else { return }

        switch runtimeState.restorePhase {
        case .none, .confirmed:
            return
        case .pendingTail:
            break
        case .pendingFullConfirmation:
            guard token.stage == .full else { return }
        }

        guard collectionView != nil else { return }
        guard collectionView.bounds.height > 1, collectionView.contentSize.height > 1 else { return }

        collectionView.layoutIfNeeded()
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = restingBottomOffsetMaxY(bottomInset: currentBottomInset)
        guard maxY.isFinite, minY.isFinite else { return }

        let desiredDistance = persistedState.atBottom ? 0 : CGFloat(persistedState.distanceFromBottom)
        let targetY = maxY - desiredDistance
        let clampedTargetY = min(max(targetY, minY), maxY)
        logScrollRestore(
            "attemptRestoreScrollIfNeeded.before sessionKey=\(token.sessionKey) stage=\(token.stage.rawValue) targetOffsetY=\(formatScrollRestore(clampedTargetY)) currentOffsetY=\(formatScrollRestore(collectionView.contentOffset.y)) currentBottomInset=\(formatScrollRestore(currentBottomInset)) contentInsetBottom=\(formatScrollRestore(contentInset.bottom))"
        )
        StreamSwitchTiming.log(
            "scroll_restore_attempt phase=\(String(describing: runtimeState.restorePhase)) stage=\(token.stage.rawValue) generation=\(token.generation) targetY=\(String(format: "%.1f", clampedTargetY)) desiredDistance=\(String(format: "%.1f", desiredDistance)) atBottomTarget=\(persistedState.atBottom)",
            sessionKey: token.sessionKey
        )
        logScrollRestore(
            "setContentOffset.restore sessionKey=\(token.sessionKey) offsetY=\(formatScrollRestore(clampedTargetY)) animated=false"
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedTargetY), animated: false)
        logScrollRestore(
            "attemptRestoreScrollIfNeeded.after sessionKey=\(token.sessionKey) stage=\(token.stage.rawValue) targetOffsetY=\(formatScrollRestore(clampedTargetY)) currentOffsetY=\(formatScrollRestore(collectionView.contentOffset.y)) currentBottomInset=\(formatScrollRestore(currentBottomInset)) contentInsetBottom=\(formatScrollRestore(collectionView.contentInset.bottom))"
        )
        refreshLastKnownScrollSnapshot(sessionKey: token.sessionKey)

        let actualDistance = distanceFromBottomClamped()
        let isAtBottomNow = actualDistance <= Self.atBottomThreshold
        let restoreConfirmed: Bool = {
            if persistedState.atBottom {
                return isAtBottomNow
            }
            return abs(actualDistance - desiredDistance) <= Self.atBottomThreshold
        }()

        if restoreConfirmed {
            let unread = runtimeState.unreadCount
            let previousRestorePhase = runtimeState.restorePhase
            let previousPendingState = runtimeState.pendingScrollRestoreState
            mutateState(for: token.sessionKey) { state in
                state.restoredScrollGenerations.insert(token.generation)
                state.restorePhase = .confirmed
                state.restoreConfirmationRetries = 0
                state.suspendScrollPersistenceUntilRestoreConfirmed = false
                state.pendingScrollRestoreState = nil
                state.sbbState = isAtBottomNow ? .atBottom : (unread > 0 ? .scrolledUpUnread : .scrolledUp)
            }
            let newState = readState(for: token.sessionKey)
            if previousRestorePhase != newState.restorePhase {
                logRestorePhaseChange(
                    sessionKey: token.sessionKey,
                    from: previousRestorePhase,
                    to: newState.restorePhase,
                    reason: "attemptRestoreScrollIfNeeded confirmed"
                )
            }
            if previousPendingState != newState.pendingScrollRestoreState {
                logPendingScrollRestoreStateChange(
                    sessionKey: token.sessionKey,
                    from: previousPendingState,
                    to: newState.pendingScrollRestoreState,
                    reason: "attemptRestoreScrollIfNeeded confirmed"
                )
            }
            StreamSwitchTiming.log(
                "scroll_restore_confirmed stage=\(token.stage.rawValue) generation=\(token.generation) actualDistance=\(String(format: "%.1f", actualDistance)) atBottomNow=\(isAtBottomNow)",
                sessionKey: token.sessionKey
            )
            emitHideIndicatorIfChanged(force: true)
            return
        }

        var shouldFallbackToBottom = false
        let previousRestorePhase = readState(for: token.sessionKey).restorePhase
        let previousPendingState = readState(for: token.sessionKey).pendingScrollRestoreState
        mutateState(for: token.sessionKey) { state in
            state.restorePhase = token.stage == .tail ? .pendingTail : .pendingFullConfirmation
            state.restoreConfirmationRetries += 1
            shouldFallbackToBottom = state.restoreConfirmationRetries >= Self.restoreMaxConfirmationRetries
            if shouldFallbackToBottom {
                state.restoredScrollGenerations.insert(token.generation)
                state.restorePhase = .confirmed
                state.restoreConfirmationRetries = 0
                state.suspendScrollPersistenceUntilRestoreConfirmed = false
                state.pendingScrollRestoreState = nil
                state.sbbState = .atBottom
            }
        }
        let newStateAfterRetry = readState(for: token.sessionKey)
        if previousRestorePhase != newStateAfterRetry.restorePhase {
            logRestorePhaseChange(
                sessionKey: token.sessionKey,
                from: previousRestorePhase,
                to: newStateAfterRetry.restorePhase,
                reason: shouldFallbackToBottom ? "attemptRestoreScrollIfNeeded fallbackToBottom" : "attemptRestoreScrollIfNeeded retryFull"
            )
        }
        if previousPendingState != newStateAfterRetry.pendingScrollRestoreState {
            logPendingScrollRestoreStateChange(
                sessionKey: token.sessionKey,
                from: previousPendingState,
                to: newStateAfterRetry.pendingScrollRestoreState,
                reason: shouldFallbackToBottom ? "attemptRestoreScrollIfNeeded fallbackToBottom" : "attemptRestoreScrollIfNeeded retryFull"
            )
        }

        if shouldFallbackToBottom {
            logScrollRestore(
                "setContentOffset.restoreFallback sessionKey=\(token.sessionKey) offsetY=\(formatScrollRestore(maxY)) animated=false"
            )
            collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            logScrollRestore(
                "attemptRestoreScrollIfNeeded.afterFallback sessionKey=\(token.sessionKey) stage=\(token.stage.rawValue) targetOffsetY=\(formatScrollRestore(maxY)) currentOffsetY=\(formatScrollRestore(collectionView.contentOffset.y)) currentBottomInset=\(formatScrollRestore(currentBottomInset)) contentInsetBottom=\(formatScrollRestore(collectionView.contentInset.bottom))"
            )
            refreshLastKnownScrollSnapshot(sessionKey: token.sessionKey)
            StreamSwitchTiming.log(
                "scroll_restore_fallback_to_bottom stage=\(token.stage.rawValue) generation=\(token.generation) retries=\(Self.restoreMaxConfirmationRetries)",
                sessionKey: token.sessionKey
            )
            emitHideIndicatorIfChanged(force: true)
        }
    }

    private func configureCollectionView() {
        flowLayout = MessageFlowLayout()
        flowLayout.sectionInset = .zero
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.minimumLineSpacing = 0
        flowLayout.estimatedItemSize = .zero

        // Use frame-based layout - we extend to window bounds in viewDidLayoutSubviews
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: flowLayout)
        collectionView.translatesAutoresizingMaskIntoConstraints = true
        collectionView.autoresizingMask = []
        collectionView.backgroundColor = Self.chatPageBackgroundColor(
            isDark: currentIsDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
        collectionView.isOpaque = !currentIsDark && !allowsTransparentWindowBackground
        updateSpatialGazeScrollHitSurface()
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        #if !os(visionOS)
            collectionView.keyboardDismissMode = MessageFlowCollectionView.keyboardDismissModeForInputFocus(
                isInputActive,
                keepsKeyboardPinned: keepsKeyboardPinned
            )
        #endif
        collectionView.allowsSelection = false
        collectionView.allowsMultipleSelection = false
        collectionView.clipsToBounds = false // Allow content to render past bounds during scroll
        collectionView.delegate = self
        let typingIndicatorTap = UITapGestureRecognizer(target: self, action: #selector(handleCollectionViewTap(_:)))
        typingIndicatorTap.cancelsTouchesInView = false
        typingIndicatorTap.delaysTouchesBegan = false
        typingIndicatorTap.delaysTouchesEnded = false
        collectionView.addGestureRecognizer(typingIndicatorTap)
        let diagnosticMessage = "T217DIAG collection_recognizer_installed build=\(Self.t217DiagnosticBuild) recognizerCount=\(collectionView.gestureRecognizers?.count ?? 0)"
        print(diagnosticMessage)
        let recognizerCount = collectionView.gestureRecognizers?.count ?? 0
        typingCancelDiagnosticLogger.notice(
            "T217DIAG collection_recognizer_installed build=\(Self.t217DiagnosticBuild, privacy: .public) recognizerCount=\(recognizerCount, privacy: .public)"
        )
        collectionView.register(MessageBubbleUIKitCell.self, forCellWithReuseIdentifier: MessageBubbleUIKitCell.reuseIdentifier)
        collectionView.register(WebBubbleUIKitCell.self, forCellWithReuseIdentifier: WebBubbleUIKitCell.reuseIdentifier)
        collectionView.register(TypingIndicatorCell.self, forCellWithReuseIdentifier: TypingIndicatorCell.reuseIdentifier)
        collectionView.register(DateSeparatorCell.self, forCellWithReuseIdentifier: DateSeparatorCell.reuseIdentifier)
        collectionView.register(SessionMetadataFooterCell.self, forCellWithReuseIdentifier: SessionMetadataFooterCell.reuseIdentifier)
        collectionView.register(SubstrateRowCell.self, forCellWithReuseIdentifier: SubstrateRowCell.reuseIdentifier)
        collectionView.register(SubstrateRunCollapseCell.self, forCellWithReuseIdentifier: SubstrateRunCollapseCell.reuseIdentifier)
        collectionView.register(MarkerDividerCell.self, forCellWithReuseIdentifier: MarkerDividerCell.reuseIdentifier)
        collectionView.register(AgentCompactCell.self, forCellWithReuseIdentifier: AgentCompactCell.reuseIdentifier)

        view.addSubview(collectionView)
        // Frame will be set in viewDidLayoutSubviews to extend to window bounds
    }

    private func applyChatPageBackground(isDark: Bool) {
        let color = Self.chatPageBackgroundColor(
            isDark: isDark,
            allowsTransparentWindowBackground: allowsTransparentWindowBackground
        )
        view.backgroundColor = color
        view.isOpaque = !isDark && !allowsTransparentWindowBackground
        collectionView?.backgroundColor = color
        collectionView?.isOpaque = !isDark && !allowsTransparentWindowBackground
        updateSpatialGazeScrollHitSurface()
    }

    private func updateSpatialGazeScrollHitSurface() {
#if os(visionOS)
        guard let collectionView else { return }
        collectionView.backgroundView = allowsTransparentWindowBackground
            ? SpatialGazeScrollHitSurfaceView()
            : nil
#endif
    }

    @objc private func handleCollectionViewTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        let hasCallback = onTypingIndicatorTap != nil
        let typingIndexPath = dataSource.indexPath(for: TypingIndicatorCell.itemId)
        let attributes = typingIndexPath.flatMap { collectionView.layoutAttributesForItem(at: $0) }
        let frame = if let typingIndexPath, let attributes {
            typingIndicatorTapTargetFrame(for: typingIndexPath, layoutAttributes: attributes)
        } else {
            CGRect.null
        }
        let didHit = frame.contains(point)
        let diagnosticMessage = "T217DIAG collection_tap build=\(Self.t217DiagnosticBuild) state=\(recognizer.state.rawValue) point=\(String(describing: point)) hasCallback=\(hasCallback) hasTypingIndexPath=\(typingIndexPath != nil) typingFrame=\(String(describing: frame)) didHit=\(didHit) contentOffset=\(String(describing: collectionView.contentOffset)) contentInset=\(String(describing: collectionView.contentInset))"
        print(diagnosticMessage)
        let contentOffset = String(describing: collectionView.contentOffset)
        let contentInset = String(describing: collectionView.contentInset)
        typingCancelDiagnosticLogger.notice(
            "T217DIAG collection_tap build=\(Self.t217DiagnosticBuild, privacy: .public) state=\(recognizer.state.rawValue, privacy: .public) point=\(String(describing: point), privacy: .public) hasCallback=\(hasCallback, privacy: .public) hasTypingIndexPath=\(typingIndexPath != nil, privacy: .public) typingFrame=\(String(describing: frame), privacy: .public) didHit=\(didHit, privacy: .public) contentOffset=\(contentOffset, privacy: .public) contentInset=\(contentInset, privacy: .public)"
        )
        guard recognizer.state == .ended,
              let onTypingIndicatorTap,
              let typingIndexPath,
              didHit else { return }
        print("T217DIAG collection_tap_invoking_callback build=\(Self.t217DiagnosticBuild) point=\(String(describing: point))")
        typingCancelDiagnosticLogger.notice(
            "T217DIAG collection_tap_invoking_callback build=\(Self.t217DiagnosticBuild, privacy: .public) point=\(String(describing: point), privacy: .public)"
        )
        onTypingIndicatorTap(typingIndicatorAnchorFrame(for: typingIndexPath))
    }

    private func typingIndicatorTapTargetFrame(
        for indexPath: IndexPath,
        layoutAttributes: UICollectionViewLayoutAttributes
    ) -> CGRect {
        let visibleFrame: CGRect
        if let cell = collectionView.cellForItem(at: indexPath) as? TypingIndicatorCell {
            visibleFrame = cell.convert(cell.bounds, to: collectionView)
        } else {
            visibleFrame = layoutAttributes.frame
        }
        let expandedFrame = CGRect(
            x: visibleFrame.minX - Self.typingIndicatorTapTargetLeadingOutset,
            y: visibleFrame.minY,
            width: visibleFrame.width + Self.typingIndicatorTapTargetLeadingOutset + Self.typingIndicatorTapTargetTrailingOutset,
            height: visibleFrame.height
        )
        return expandedFrame.intersection(collectionViewContentFrame())
    }

    private func typingIndicatorAnchorFrame(for indexPath: IndexPath) -> CGRect {
        guard let cell = collectionView.cellForItem(at: indexPath) as? TypingIndicatorCell else {
            return collectionView.convert(collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? .null, to: nil)
        }
        return cell.renderedBubbleFrame(in: nil)
    }

    private func notifyTypingIndicatorAnchorFrameIfNeeded() {
        let anchorFrame: CGRect?
        if let indexPath = dataSource.indexPath(for: TypingIndicatorCell.itemId),
           let cell = collectionView.cellForItem(at: indexPath) as? TypingIndicatorCell
        {
            anchorFrame = cell.renderedBubbleFrame(in: nil)
        } else {
            anchorFrame = nil
        }
        guard anchorFrame != lastReportedTypingIndicatorAnchorFrame else { return }
        lastReportedTypingIndicatorAnchorFrame = anchorFrame
        onTypingIndicatorAnchorFrameChanged?(anchorFrame)
    }

    private func collectionViewContentFrame() -> CGRect {
        CGRect(
            x: 0,
            y: -collectionView.adjustedContentInset.top,
            width: collectionView.bounds.width,
            height: collectionView.contentSize.height
                + collectionView.adjustedContentInset.top
                + collectionView.adjustedContentInset.bottom
        )
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] (collectionView: UICollectionView, indexPath: IndexPath, id: String) in
            guard let self, let viewModel = self.viewModel else { return nil }

            if DateSeparatorCell.isDateSeparatorItemID(id) {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: DateSeparatorCell.reuseIdentifier,
                    for: indexPath
                ) as? DateSeparatorCell
                let text = self.dateSeparatorTextByItemId[id] ?? ""
                cell?.configure(text: text, isDark: self.currentIsDark)
                return cell
            }

            if MarkerDividerCell.isMarkerDividerItemID(id) {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: MarkerDividerCell.reuseIdentifier,
                    for: indexPath
                ) as? MarkerDividerCell
                cell?.configure(
                    content: .sessionBoundary,
                    isDark: self.currentIsDark,
                    isSegmentAnchorActive: self.isSegmentAnchorActive,
                    onTap: { [weak self] in
                        self?.toggleSegmentAnchor()
                    }
                )
                return cell
            }

            if id.hasPrefix("web_") {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: WebBubbleUIKitCell.reuseIdentifier,
                    for: indexPath
                ) as? WebBubbleUIKitCell
                guard let item = self.webBubbleCoordinator.webBubbleItem(for: id) else { return cell }
                cell?.configure(item: item, coordinator: self.webBubbleCoordinator, isDark: self.currentIsDark)
                return cell
            }

            // Handle typing indicator
            if id == TypingIndicatorCell.itemId {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TypingIndicatorCell.reuseIdentifier,
                    for: indexPath
                ) as? TypingIndicatorCell
                let metrics = ChatFlowTheme.Metrics(isCompact: self.isCompact)
                let storageKey = self.liveProgress?.sessionKey ?? viewModel.typingSessionKey ?? self.channelOverride ?? viewModel.engineActiveSessionKey
                let message = TypingIndicatorCell.makeMessage(sessionKey: storageKey)
                let presentation = TypingIndicatorCell.makePresentation(metrics: metrics)
                let sizeClass = MessageFlowRules.sizeClass(for: presentation)
                let contentWidth = self.effectiveContentWidth(metrics: metrics)
                let maxWidth = self.maxItemWidth(
                    for: sizeClass,
                    message: message,
                    presentation: presentation,
                    metrics: metrics,
                    containerWidth: contentWidth
                )
                cell?.configure(
                    message: message,
                    presentation: presentation,
                    isCompact: self.isCompact,
                    maxWidth: maxWidth,
                    isDark: self.currentIsDark,
                    progressSummary: self.liveProgress?.summary,
                    onTap: { [weak self, weak cell] in
                        guard let self else { return }
                        let anchorFrame = cell?.renderedBubbleFrame(in: nil) ?? .null
                        self.onTypingIndicatorTap?(anchorFrame)
                    }
                )
                cell?.startAnimating()
                DispatchQueue.main.async { [weak self] in
                    self?.notifyTypingIndicatorAnchorFrameIfNeeded()
                }
                return cell
            }

            if id == SessionMetadataFooterCell.itemId {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SessionMetadataFooterCell.reuseIdentifier,
                    for: indexPath
                ) as? SessionMetadataFooterCell
                cell?.configure(
                    status: self.sessionStatus,
                    statusUnavailable: self.sessionStatusUnavailable,
                    isDark: self.currentIsDark,
                    isTightbeam: viewModel.isTightbeamServer,
                    harnessOptions: viewModel.orgOptionsHarnesses,
                    onSelect: self.onSessionControlSelected,
                    onTestMenuSelect: self.onFooterTestMenuSelected,
                    searchQuery: self.streamSearchQuery,
                    onSearchQueryChanged: { [weak self] query in
                        guard let self,
                              let sessionKey = self.callbackSessionKey() else { return }
                        self.onStreamSearchQueryChanged?(sessionKey, query)
                    }
                )
                cell?.alpha = self.footerRevealAlpha()
                return cell
            }

            if id.hasPrefix(Self.substrateRunItemIdPrefix) {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SubstrateRunCollapseCell.reuseIdentifier,
                    for: indexPath
                ) as? SubstrateRunCollapseCell
                let memberCount = self.substrateRunMemberIdsByItemId[id]?.count ?? 0
                cell?.configure(
                    noticeCount: memberCount,
                    isExpanded: false,
                    isDark: self.currentIsDark,
                    onTap: { [weak self] in
                        self?.toggleSubstrateRunExpansion(anchorItemId: id)
                    }
                )
                return cell
            }

            guard let message = self.messagesById[id] else { return nil }

            if message.messageKind == .substrate {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SubstrateRowCell.reuseIdentifier,
                    for: indexPath
                ) as? SubstrateRowCell
                let displayMessage = message.strippingProvenanceStampForDisplay()
                cell?.configure(
                    leadLabel: "tightbeam",
                    detail: displayMessage.content,
                    style: .liveVoice,
                    isDark: self.currentIsDark,
                    isIndentedUnderRun: self.expandedRunMemberMessageIds.contains(id),
                    onTap: { [weak self] in
                        self?.onOpenDetail?(message)
                    }
                )
                return cell
            }

            if message.messageKind == .agent, case let .agent(handle)? = message.provenanceOrigin {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: AgentCompactCell.reuseIdentifier,
                    for: indexPath
                ) as? AgentCompactCell
                let displayMessage = message.strippingProvenanceStampForDisplay()
                cell?.configure(
                    senderLine: AgentCompactCell.displaySenderLine(forHandle: handle),
                    previewText: AgentCompactCell.firstLine(of: displayMessage.content),
                    isDark: self.currentIsDark,
                    onTap: { [weak self] in
                        self?.onOpenDetail?(message)
                    }
                )
                return cell
            }
            let metrics = ChatFlowTheme.Metrics(isCompact: self.isCompact)
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            let hideHeader = shouldHideHeader(for: message, presentation: presentation)
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: MessageBubbleUIKitCell.reuseIdentifier,
                for: indexPath
            ) as? MessageBubbleUIKitCell
            let sizeClass = MessageFlowRules.sizeClass(for: presentation)
            let contentWidth = self.effectiveContentWidth(metrics: metrics)
            let maxWidth = self.maxItemWidth(
                for: sizeClass,
                message: message,
                presentation: presentation,
                metrics: metrics,
                containerWidth: contentWidth
            )
            let allowsOuterScroll = (sizeClass == .long) && !self.shouldDisableOuterScrollForMixedMediaBubble(presentation)
            let env = self.bubbleSizingV2Environment(metrics: metrics)
            let fallbackHeightPolicy = self.bubbleHeightPolicyForPresentation(
                presentation: presentation,
                metrics: metrics,
                env: env,
                allowsOuterScroll: allowsOuterScroll
            )
            let layoutStateV2: BubbleSizingV2.LayoutState?
            let configureWidth: CGFloat
            let truncationHeightOverrideV1: CGFloat?
            let bubbleHeightPolicyForConfigure: BubbleSizingV2.BubbleHeightPolicy
            let sendIndicatorState = viewModel.sendIndicatorState(for: message.id)
            let replyReference = viewModel.replyReference(for: message)
            let isShowingOnlyUserMessages = self.readState(for: message.sessionKey).isShowingOnlyUserMessages
            if self.bubbleSizingV2Enabled {
                let state = self.authoritativeBubbleSizingV2LayoutState(
                    message: message,
                    presentation: presentation,
                    metrics: metrics,
                    env: env,
                    sendIndicatorState: sendIndicatorState,
                    showsHeader: !hideHeader
                )
                layoutStateV2 = state
                configureWidth = state.measurement.measuredBubbleWidth
                truncationHeightOverrideV1 = nil
                bubbleHeightPolicyForConfigure = state.plan.heightPolicy
            } else {
                layoutStateV2 = nil
                // Use cached size width for consistent sizing with measurement
                configureWidth = self.cachedWidth(for: id) ?? maxWidth
                truncationHeightOverrideV1 = fallbackHeightPolicy.v1TruncationHeightOverride
                bubbleHeightPolicyForConfigure = fallbackHeightPolicy
            }
            cell?.configure(
                message: message,
                stream: viewModel.streamType(for: message.sessionKey),
                presentation: presentation,
                sendIndicatorState: sendIndicatorState,
                isCompact: self.isCompact,
                maxWidth: configureWidth,
                bubbleHeightPolicy: bubbleHeightPolicyForConfigure,
                truncationHeightOverride: truncationHeightOverrideV1,
                bubbleSizingV2: layoutStateV2,
                showsHeader: !hideHeader,
                showsProvenanceChrome: viewModel.isTightbeamServer,
                isDark: self.currentIsDark,
                terminalConnectionPool: viewModel.terminalConnectionPool,
                webBubbleCoordinator: self.webBubbleCoordinator,
                salientHighlightService: viewModel.salientHighlightService,
                onRequestExpand: { [weak self] in
                    guard let self else { return }
                    self.onExpand?(message)
                },
                onRequestLayout: { [weak self] messageId in
                    self?.handleCellRequestedLayout(messageId: messageId)
                },
                onInteractiveCallback: { [weak self] sourceMessageId, action, data in
                    self?.viewModel?.sendInteractiveCallback(
                        sourceMessageId: sourceMessageId,
                        action: action,
                        data: data
                    )
                },
                onInsertIntoPrompt: { [weak self] message in
                    self?.onInsertMessageIntoPrompt?(message)
                },
                onReferenceMessage: { [weak self] message in
                    self?.onReferenceMessageInPrompt?(message)
                },
                showOnlyUserMessagesMenuLabel: ShowOnlyUserMessagesChatCollapse.menuLabel(
                    isCollapsed: isShowingOnlyUserMessages
                ),
                onToggleShowOnlyUserMessages: { [weak self] in
                    self?.toggleShowOnlyUserMessagesMode()
                },
                onShowOnlyUserMessagesReveal: isShowingOnlyUserMessages && message.role == .user
                    ? { [weak self] message in
                        self?.revealUserMessageFromShowOnlyUserMessagesMode(message)
                    }
                    : nil,
                isCollapsedUserOnlyMode: isShowingOnlyUserMessages && message.role == .user,
                replyReference: replyReference,
                onResend: { [weak self] in
                    self?.viewModel?.resendFailedMessage(messageId: message.id)
                }
            )
            return cell
        }
    }

    private func applySnapshotWithTypingMorphIfPossible(
        snapshot: NSDiffableDataSourceSnapshot<Int, String>,
        targetMessageId: String?,
        onApplied: (() -> Void)?,
        onAppliedSessionKey: String
    ) {
        guard let targetMessageId,
              let typingIndexPath = dataSource.indexPath(for: TypingIndicatorCell.itemId),
              let typingCell = collectionView.cellForItem(at: typingIndexPath)
        else {
            // Fallback: let diffable handle it (better than skipping updates).
            applyDiffableSnapshot(snapshot, animatingDifferences: true, sessionKey: onAppliedSessionKey, completion: onApplied)
            return
        }
        guard let morphToken = activeSessionGenerationToken() else {
            applyDiffableSnapshot(snapshot, animatingDifferences: true, sessionKey: onAppliedSessionKey, completion: onApplied)
            return
        }

        morphTargetMessageId = targetMessageId

        collectionView.layoutIfNeeded()
        let startFrame = typingCell.convert(typingCell.bounds, to: collectionView)
        guard let typingSnapshotView = typingCell.snapshotView(afterScreenUpdates: false) else {
            applyDiffableSnapshot(snapshot, animatingDifferences: true, sessionKey: onAppliedSessionKey, completion: onApplied)
            return
        }

        typingSnapshotView.frame = startFrame
        collectionView.addSubview(typingSnapshotView)

        // Apply without diffable animations; we animate the visual transform ourselves.
        applyDiffableSnapshot(snapshot, animatingDifferences: false, sessionKey: onAppliedSessionKey) { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            onApplied?()

            // Diffable no-animation applies are frequently executed under a
            // no-animation context (UIKit disables animations so updates "snap" into place). If we
            // start our morph `UIView.animate` inside that completion, the 2s duration can collapse
            // to an instantaneous state change.
            //
            // We intentionally schedule the morph on the next main runloop tick to escape the
            // diffable no-animation scope, while keeping all UIKit work on the main thread.
            //
            // We use GCD here (instead of `Task { @MainActor in ... }`) on purpose: UIKit animation
            // transactions are runloop/callback driven, and `Task` scheduling can be less deterministic
            // about *exactly* which turn we run on. We need a predictable “next tick” escape hatch so
            // the morph animation isn't snap-applied.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.callbackSessionKey() == morphToken.sessionKey else {
                    typingSnapshotView.removeFromSuperview()
                    self.morphTargetMessageId = nil
                    self.deferScrollToBottomUntilMorphCompletes = false
                    return
                }
                guard self.readState(for: morphToken.sessionKey).restoreGeneration == morphToken.generation else {
                    typingSnapshotView.removeFromSuperview()
                    self.morphTargetMessageId = nil
                    self.deferScrollToBottomUntilMorphCompletes = false
                    return
                }
                guard let targetIndexPath = self.dataSource.indexPath(for: targetMessageId),
                      let targetCell = self.collectionView.cellForItem(at: targetIndexPath)
                else {
                    typingSnapshotView.removeFromSuperview()
                    self.morphTargetMessageId = nil
                    return
                }

                self.collectionView.layoutIfNeeded()
                let endFrame = targetCell.convert(targetCell.bounds, to: self.collectionView)

                // Ensure we start hidden AFTER willDisplay has had a chance to run.
                targetCell.alpha = 0

                UIView.animate(
                    withDuration: 2.0,
                    delay: 0,
                    usingSpringWithDamping: 0.92,
                    initialSpringVelocity: 0.25,
                    options: [.curveEaseInOut, .allowUserInteraction]
                ) {
                    typingSnapshotView.frame = endFrame
                    typingSnapshotView.alpha = 0
                    targetCell.alpha = 1
                } completion: { _ in
                    guard self.callbackSessionKey() == morphToken.sessionKey else {
                        typingSnapshotView.removeFromSuperview()
                        self.morphTargetMessageId = nil
                        self.deferScrollToBottomUntilMorphCompletes = false
                        return
                    }
                    guard self.readState(for: morphToken.sessionKey).restoreGeneration == morphToken.generation else {
                        typingSnapshotView.removeFromSuperview()
                        self.morphTargetMessageId = nil
                        self.deferScrollToBottomUntilMorphCompletes = false
                        return
                    }
                    typingSnapshotView.removeFromSuperview()
                    self.morphTargetMessageId = nil
                    // Scroll-to-bottom often triggers a layout pass/scroll animation that makes the
                    // morph feel interrupted. Defer it until the morph completes.
                    if self.deferScrollToBottomUntilMorphCompletes {
                        self.deferScrollToBottomUntilMorphCompletes = false
                        // Multiple attempts preserves the historical “always end up at the bottom” invariant.
                        if let sessionKey = self.callbackSessionKey() {
                            if Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: self.hasAuthoritativePersistedRestoreTarget(sessionKey: sessionKey)) {
                                self.scheduleScrollToBottom(sessionKey: sessionKey, animated: false, attempts: 3)
                            } else {
                                self.logScrollRestore("morphCompletion.scrollToBottom.disqualified sessionKey=\(sessionKey) reason=savedRestoreTargetIsAuthoritative")
                            }
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func updateLayout() -> Bool {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        flowLayout.minimumInteritemSpacing = metrics.flowGap
        flowLayout.minimumLineSpacing = metrics.flowGap
        flowLayout.rowSpacingProvider = { [weak self] previousIndex, nextIndex in
            self?.rowSpacing(afterItemAt: previousIndex, beforeItemAt: nextIndex, metrics: metrics)
                ?? metrics.flowGap
        }
        flowLayout.rowSpacingFingerprintProvider = { [weak self] in
            self?.rowSpacingFingerprint() ?? 0
        }
        // Section inset is just for padding - content insets handle safe areas
        flowLayout.sectionInset = Self.flowSectionInset(
            containerPadding: metrics.containerPadding,
            trailingContentInset: trailingContentInset
        )
        // Content insets allow scrolling under safe areas while resting below them
        // Top inset = safe area (status bar) so content can scroll under it
        // Bottom inset = input bar height
        collectionView.contentInset.top = topInset
        collectionView.verticalScrollIndicatorInsets.top = topInset
        setBottomInset(currentBottomInset)
        updateVisibleFooterAlpha()

        let contentWidth = effectiveContentWidth(metrics: metrics)
        let metricsFp = BubbleSizingV2.metricsFingerprint(
            metrics: metrics, traitCollection: view.traitCollection
        )
        let measurementInputsChanged =
            contentWidth != lastMeasurementContentWidth
                || metricsFp != lastMeasurementMetricsFingerprint

        if pendingBoundsChange {
            pendingBoundsChange = false
            if measurementInputsChanged {
                forceReconfigureAll = true
            }
        }

        if measurementInputsChanged {
            lastMeasurementContentWidth = contentWidth
            lastMeasurementMetricsFingerprint = metricsFp
            let envInvalidationPlan = invalidateFor(reason: .envChanged)
            executeInvalidationPlan(envInvalidationPlan)
        } else {
            // Measurement inputs unchanged — bubble sizes are still valid.
            // Rebuild layout positions only (bounds/insets may have shifted).
            scheduleLayoutInvalidation()
        }
        return measurementInputsChanged
    }

    private static func interBubbleRowSpacing(metrics: ChatFlowTheme.Metrics) -> CGFloat {
        MessageBubbleGeometry.adjacentMessageRowSpacing(metrics: metrics)
    }

    private func rowSpacing(afterItemAt previousIndex: Int,
                            beforeItemAt nextIndex: Int,
                            metrics: ChatFlowTheme.Metrics) -> CGFloat {
        guard isNormalMessageItem(at: previousIndex),
              isNormalMessageItem(at: nextIndex) else {
            return metrics.flowGap
        }
        return Self.interBubbleRowSpacing(metrics: metrics)
    }

    private func isNormalMessageItem(at itemIndex: Int) -> Bool {
        let indexPath = IndexPath(item: itemIndex, section: 0)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        guard id != TypingIndicatorCell.itemId,
              id != SessionMetadataFooterCell.itemId,
              !DateSeparatorCell.isDateSeparatorItemID(id),
              !MarkerDividerCell.isMarkerDividerItemID(id),
              !id.hasPrefix("web_") else {
            return false
        }
        return messagesById[id] != nil
    }

    private func rowSpacingFingerprint() -> Int {
        var hasher = Hasher()
        for id in dataSource.snapshot().itemIdentifiers {
            hasher.combine(id)
            hasher.combine(rowSpacingClass(forItemId: id))
        }
        return hasher.finalize()
    }

    private func rowSpacingClass(forItemId id: String) -> Int {
        if id == TypingIndicatorCell.itemId { return 1 }
        if id == SessionMetadataFooterCell.itemId { return 2 }
        if DateSeparatorCell.isDateSeparatorItemID(id) { return 3 }
        if id.hasPrefix("web_") { return 4 }
        if messagesById[id] != nil { return 5 }
        if MarkerDividerCell.isMarkerDividerItemID(id) { return 6 }
        return 0
    }

    private func availableContentWidth() -> CGFloat {
        collectionView.bounds.width - flowLayout.sectionInset.left - flowLayout.sectionInset.right
    }

    private func effectiveContentWidth(metrics: ChatFlowTheme.Metrics) -> CGFloat {
        let width = availableContentWidth()
        let referenceWidth = max(0, Self.bubbleReferenceSize.width - (metrics.containerPadding * 2))
        return min(width, referenceWidth)
    }

    private func effectiveContainerHeight() -> CGFloat {
        let height = collectionView.bounds.height
        #if os(visionOS)
            return min(height, Self.bubbleReferenceSize.height)
        #else
            return height
        #endif
    }

    private func bubbleHeightPolicyForPresentation(
        presentation: MessagePresentation,
        metrics: ChatFlowTheme.Metrics,
        env: BubbleSizingV2.Environment,
        allowsOuterScroll: Bool
    ) -> BubbleSizingV2.BubbleHeightPolicy {
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        return BubbleSizingV2.BubbleHeightPolicy.resolve(
            metrics: metrics,
            env: env,
            isSingleLinkPreview: isSingleLinkPreviewBubble(presentation: presentation),
            prefersScreenAwareHeightCap: prefersScreenAwareTruncationHeight(
                presentation: presentation,
                maxLineWidth: maxLineWidth
            ),
            allowsOuterScroll: allowsOuterScroll
        )
    }

    private func shouldDisableOuterScrollForMixedMediaBubble(_ presentation: MessagePresentation) -> Bool {
        #if os(visionOS)
            guard !presentation.hasMediaOnly else { return false }
            return presentation.parts.contains { part in
                switch part {
                case .remoteImage, .image, .gallery:
                    return true
                default:
                    return false
                }
            }
        #else
            return false
        #endif
    }

    private func maxItemWidth(for sizeClass: MessageSizeClass,
                              message: Message,
                              presentation: MessagePresentation,
                              metrics: ChatFlowTheme.Metrics,
                              containerWidth: CGFloat) -> CGFloat
    {
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let paddedLineWidth = maxLineWidth + metrics.bubblePaddingHorizontal * 2
        if prefersWideBubbleWidth(presentation: presentation, maxLineWidth: maxLineWidth) {
            return containerWidth
        }
        let result: CGFloat
        switch sizeClass {
        case .short:
            result = min(containerWidth, paddedLineWidth)
        case .medium:
            result = mediumMaxWidth(
                message: message,
                presentation: presentation,
                metrics: metrics,
                containerWidth: containerWidth
            )
        case .long:
            if prefersWideBubbleWidth(presentation: presentation, maxLineWidth: maxLineWidth) {
                result = containerWidth
            } else {
                result = min(containerWidth, paddedLineWidth)
            }
        }
        return result
    }

    private func hasLinkPreviewPart(_ presentation: MessagePresentation) -> Bool {
        presentation.parts.contains { part in
            if case .linkPreview = part { return true }
            return false
        }
    }

    private func isSingleLinkPreviewBubble(presentation: MessagePresentation) -> Bool {
        presentation.hasSingleURL && hasLinkPreviewPart(presentation)
    }

    private func prefersWideBubbleWidth(presentation: MessagePresentation,
                                        maxLineWidth: CGFloat) -> Bool
    {
        if presentation.hasSingleURL {
            return true
        }

        // Link cards (detected URLs) should get wide *width* so they don't feel cramped.
        if !presentation.detectedURLs.isEmpty {
            return true
        }

        let tableCount = presentation.parts.reduce(into: 0) { count, part in
            if case .table = part { count += 1 }
        }
        if tableCount == 1 {
            return true
        }

        if presentation.parts.contains(where: { part in
            switch part {
            case .remoteImage, .image, .gallery, .linkPreview, .terminalSession:
                return true
            default:
                return false
            }
        }) {
            return true
        }

        let tables = presentation.parts.compactMap { part -> TableModel? in
            if case let .table(model) = part { return model }
            return nil
        }
        if tables.contains(where: { tableContentWidth($0) > maxLineWidth }) {
            return true
        }

        return false
    }

    private func prefersScreenAwareTruncationHeight(presentation: MessagePresentation,
                                                    maxLineWidth: CGFloat) -> Bool
    {
        // IMPORTANT: Do not opt into screen-aware height caps just because a message contains a URL.
        // That can inflate the cap enough that "too-tall" markdown bubbles never overflow, so we
        // never show fade/scroll/tap-to-expand affordances.
        //
        // Link-preview bubbles keep the design-system max-height cap by default; single-link
        // bubbles are handled by BubbleHeightPolicy's adaptive single-link branch.
        if presentation.parts.contains(where: { part in
            if case .linkPreview = part { return true }
            return false
        }) {
            return false
        }

        let tableCount = presentation.parts.reduce(into: 0) { count, part in
            if case .table = part { count += 1 }
        }
        if tableCount == 1 {
            return true
        }

        if presentation.parts.contains(where: { part in
            switch part {
            case .remoteImage, .image, .gallery, .terminalSession:
                return true
            default:
                return false
            }
        }) {
            return true
        }

        let tables = presentation.parts.compactMap { part -> TableModel? in
            if case let .table(model) = part { return model }
            return nil
        }
        if tables.contains(where: { tableContentWidth($0) > maxLineWidth }) {
            return true
        }

        return false
    }

    private func tableContentWidth(_ model: TableModel) -> CGFloat {
        let columnCount = model.columns.count
        guard columnCount > 0 else { return 0 }
        var widths: [CGFloat] = Array(repeating: 0, count: columnCount)
        if let header = model.header {
            for (idx, cell) in header.prefix(columnCount).enumerated() {
                widths[idx] = max(widths[idx], cell.intrinsicWidth)
            }
        }
        for row in model.rows {
            for (idx, cell) in row.cells.prefix(columnCount).enumerated() {
                widths[idx] = max(widths[idx], cell.intrinsicWidth)
            }
        }
        let cellPaddingHorizontal: CGFloat = 12
        let paddingWidth = CGFloat(columnCount) * cellPaddingHorizontal * 2
        let separatorLineWidth: CGFloat = 1
        let separatorsWidth = CGFloat(max(columnCount - 1, 0)) * separatorLineWidth
        return widths.reduce(0, +) + paddingWidth + separatorsWidth
    }

    private func sizeForItem(at indexPath: IndexPath) -> CGSize {
        guard let id = dataSource.itemIdentifier(for: indexPath), let viewModel else {
            return .zero
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let env = bubbleSizingV2Environment(metrics: metrics)

        if DateSeparatorCell.isDateSeparatorItemID(id) {
            let rowWidth = availableContentWidth()
            let lineHeight = UIFont.clawline(.uiLabel, weight: .semibold).lineHeight
            return CGSize(
                width: rowWidth,
                height: ceil(lineHeight + DateSeparatorCell.topPadding + DateSeparatorCell.bottomPadding)
            )
        }

        if MarkerDividerCell.isMarkerDividerItemID(id) {
            let rowWidth = availableContentWidth()
            let lineHeight = UIFont.clawline(.timestamp, weight: .semibold).lineHeight
            let iconHeight: CGFloat = 18
            let contentHeight = max(lineHeight, iconHeight)
            return CGSize(
                width: rowWidth,
                height: ceil(contentHeight + MarkerDividerCell.verticalPadding * 2)
            )
        }

        // Handle typing indicator size
        if id == TypingIndicatorCell.itemId {
            let storageKey = liveProgress?.sessionKey ?? viewModel.typingSessionKey ?? channelOverride ?? viewModel.engineActiveSessionKey
            let message = TypingIndicatorCell.makeMessage(sessionKey: storageKey)
            let presentation = TypingIndicatorCell.makePresentation(metrics: metrics)
            let sizeClass = MessageFlowRules.sizeClass(for: presentation)
            let availableWidth = effectiveContentWidth(metrics: metrics)
            let maxWidth = maxItemWidth(
                for: sizeClass,
                message: message,
                presentation: presentation,
                metrics: metrics,
                containerWidth: availableWidth
            )
            return measureUIKitBubbleSize(
                message: message,
                presentation: presentation,
                sendIndicatorState: nil,
                maxWidth: maxWidth,
                showsHeader: false,
                showsProvenanceChrome: viewModel.isTightbeamServer,
                paddingScale: TypingIndicatorCell.bubblePaddingScale,
                minWidthOverride: TypingIndicatorCell.bubbleWidth,
                maxWidthOverride: TypingIndicatorCell.bubbleWidth,
                minHeightOverride: TypingIndicatorCell.height(progressSummary: liveProgress?.summary)
            )
        }

        if id == SessionMetadataFooterCell.itemId {
            let rowWidth = availableContentWidth()
            let height = SessionMetadataFooterCell.height(
                for: sessionStatus,
                width: rowWidth,
                compatibleWith: traitCollection,
                isTightbeam: viewModel.isTightbeamServer
            )
            return CGSize(width: rowWidth, height: height)
        }

        if id.hasPrefix("web_") {
            let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
            let availableWidth = effectiveContentWidth(metrics: metrics)
            let heightCap = metrics.truncationHeight
            let height = max(240, min(heightCap, 520))
            return CGSize(width: availableWidth, height: height)
        }

        if id.hasPrefix(Self.substrateRunItemIdPrefix) {
            let rowWidth = availableContentWidth()
            let lineHeight = UIFont.clawline(.secondaryLabel, weight: .semibold).lineHeight
            return CGSize(width: rowWidth, height: ceil(lineHeight) + 12)
        }

        guard let message = messagesById[id] else {
            return .zero
        }

        if message.messageKind == .substrate {
            let rowWidth = availableContentWidth()
            let displayMessage = message.strippingProvenanceStampForDisplay()
            let avatarAndSpacing: CGFloat = SubstrateRowCell.leadingIndent + 22 + 8 + 12
            let textWidth = max(rowWidth - avatarAndSpacing, 0)
            let font = UIFont.clawline(.secondaryLabel)
            let measured = ("tightbeam \u{00B7} " + displayMessage.content as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return CGSize(width: rowWidth, height: ceil(measured.height) + 12)
        }

        if message.messageKind == .agent {
            let rowWidth = availableContentWidth()
            let lineHeight = UIFont.clawline(.secondaryLabel, weight: .semibold).lineHeight
            return CGSize(width: rowWidth, height: ceil(lineHeight) + 10)
        }

        if bubbleSizingV2Enabled {
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            let hideHeader = shouldHideHeader(for: message, presentation: presentation)
            let sendIndicatorState = viewModel.sendIndicatorState(for: message.id)
            let layoutState = authoritativeBubbleSizingV2LayoutState(
                message: message,
                presentation: presentation,
                metrics: metrics,
                env: env,
                sendIndicatorState: sendIndicatorState,
                showsHeader: !hideHeader
            )
            return layoutState.measurement.measuredCellSize
        }
        if let cached = readSizeState(messageId: id, env: env) {
            return cached.size
        }
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        let hideHeader = shouldHideHeader(for: message, presentation: presentation)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let availableWidth = effectiveContentWidth(metrics: metrics)
        let maxWidth = maxItemWidth(
            for: sizeClass,
            message: message,
            presentation: presentation,
            metrics: metrics,
            containerWidth: availableWidth
        )
        let sendIndicatorState = viewModel.sendIndicatorState(for: message.id)
        let allowsOuterScroll = (sizeClass == .long) && !shouldDisableOuterScrollForMixedMediaBubble(presentation)
        let bubbleHeightPolicy = bubbleHeightPolicyForPresentation(
            presentation: presentation,
            metrics: metrics,
            env: env,
            allowsOuterScroll: allowsOuterScroll
        )
        let measuredSize = measureUIKitBubbleSize(
            message: message,
            presentation: presentation,
            sendIndicatorState: sendIndicatorState,
            maxWidth: maxWidth,
            bubbleHeightPolicy: bubbleHeightPolicy,
            showsHeader: !hideHeader,
            showsProvenanceChrome: viewModel.isTightbeamServer
        )
        _ = writeMeasuredSize(messageId: id, measurement: measuredSize)
        return measuredSize
    }

    private func measureUIKitBubbleSize(message: Message,
                                        stream: ChatStream? = nil,
                                        presentation: MessagePresentation,
                                        sendIndicatorState: MessageSendIndicatorState?,
                                        maxWidth: CGFloat,
                                        bubbleHeightPolicy: BubbleSizingV2.BubbleHeightPolicy? = nil,
                                        truncationHeightOverride: CGFloat? = nil,
                                        showsHeader: Bool = true,
                                        showsProvenanceChrome: Bool = false,
                                        paddingScale: CGFloat = 1,
                                        minWidthOverride: CGFloat? = nil,
                                        maxWidthOverride: CGFloat? = nil,
                                        minHeightOverride: CGFloat? = nil) -> CGSize
    {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        uiKitBubbleSizer.configure(
            message: message,
            stream: stream ?? viewModel?.streamType(for: message.sessionKey) ?? .personal,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth,
            bubbleHeightPolicy: bubbleHeightPolicy,
            truncationHeightOverride: truncationHeightOverride,
            showsHeader: showsHeader,
            showsProvenanceChrome: showsProvenanceChrome,
            paddingScale: paddingScale,
            minWidthOverride: minWidthOverride,
            maxWidthOverride: maxWidthOverride,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: viewModel?.replyReference(for: message)
        )
        let effectiveMaxWidth = maxWidthOverride ?? maxWidth
        let preferredWidth: CGFloat
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let prefersWideWidth = prefersWideBubbleWidth(presentation: presentation, maxLineWidth: maxLineWidth)
        let policyTruncationCap = bubbleHeightPolicy?.v1TruncationHeightOverride ?? truncationHeightOverride
        if prefersWideWidth {
            preferredWidth = effectiveMaxWidth
        } else if sizeClass == .short {
            preferredWidth = uiKitBubbleSizer.preferredWidth(
                maxWidth: effectiveMaxWidth,
                minWidth: minWidthOverride ?? 120
            )
        } else {
            preferredWidth = effectiveMaxWidth
        }

        // Flynn correction / #28: link previews should not start at LinkPreviewView minHeight (140).
        // Default them to the truncation cap until live-cell measurement refines the content height.
        let hasLinkPreview = presentation.parts.contains { part in
            if case .linkPreview = part { return true }
            return false
        }
        if hasLinkPreview {
            // Use the active height cap (design-system by default; screen-aware only for specific embedded content).
            let cap = policyTruncationCap ?? metrics.truncationHeight
            var height = max(1, cap)
            if let minHeight = minHeightOverride {
                height = max(height, minHeight)
            }
            let minWidth: CGFloat = minWidthOverride ?? 120
            let clamped = CGSize(
                width: min(effectiveMaxWidth, max(minWidth, preferredWidth)),
                height: height
            )
            return snapToPixel(clamped)
        }

        let target = CGSize(width: preferredWidth, height: UIView.layoutFittingCompressedSize.height)
        let measured = uiKitBubbleSizer.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let minWidth: CGFloat = minWidthOverride ?? 120
        var height = max(1, measured.height)
        if let minHeight = minHeightOverride {
            height = max(height, minHeight)
        }
        if let policyTruncationCap {
            // For wide content, cap at truncation max (but don't force-max).
            height = min(height, policyTruncationCap)
        }
        let clamped = CGSize(
            width: min(effectiveMaxWidth, max(minWidth, measured.width)),
            height: height
        )
        return snapToPixel(clamped)
    }

    // MARK: - Bubble Sizing V2

    private func bubbleSizingV2Environment(metrics: ChatFlowTheme.Metrics) -> BubbleSizingV2.Environment {
        let containerWidth = effectiveContentWidth(metrics: metrics)
        let containerHeight = effectiveContainerHeight()
        #if os(visionOS)
            let isVisionOS = true
        #else
            let isVisionOS = false
        #endif
        let metricsFp = BubbleSizingV2.metricsFingerprint(metrics: metrics, traitCollection: view.traitCollection)
        return BubbleSizingV2.Environment(
            containerWidth: containerWidth,
            containerHeight: containerHeight,
            singleLinkContainerHeight: collectionView.bounds.height,
            topInset: topInset,
            bottomInset: currentBottomInset,
            truncationBottomInset: truncationBottomInset,
            isVisionOS: isVisionOS,
            metricsFingerprint: metricsFp
        )
    }

    private func bubbleSizingV2Plan(message: Message,
                                    presentation: MessagePresentation,
                                    metrics: ChatFlowTheme.Metrics,
                                    env: BubbleSizingV2.Environment,
                                    showsHeader _: Bool) -> BubbleSizingV2.Plan
    {
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let isSingleLinkPreview = isSingleLinkPreviewBubble(presentation: presentation)
        let isWide = prefersWideBubbleWidth(presentation: presentation, maxLineWidth: maxLineWidth)

        let maxWidth: CGFloat = {
            if isWide { return env.containerWidth }
            let paddedLineWidth = maxLineWidth + metrics.bubblePaddingHorizontal * 2
            switch sizeClass {
            case .short:
                return min(env.containerWidth, paddedLineWidth)
            case .medium:
                return mediumMaxWidth(
                    message: message,
                    presentation: presentation,
                    metrics: metrics,
                    containerWidth: env.containerWidth
                )
            case .long:
                return min(env.containerWidth, paddedLineWidth)
            }
        }()

        let minWidth: CGFloat = {
            switch sizeClass {
            case .short:
                return 40
            case .medium:
                return 80
            case .long:
                return 80
            }
        }()

        // Design-system: only "large" (.long) bubbles get truncation/outer-scroll behavior.
        // Short/medium bubbles should grow to content (no truncation chrome), even with Dynamic Type.
        let allowsOuterScroll = (sizeClass == .long) && !shouldDisableOuterScrollForMixedMediaBubble(presentation)
        let heightPolicy = bubbleHeightPolicyForPresentation(
            presentation: presentation,
            metrics: metrics,
            env: env,
            allowsOuterScroll: allowsOuterScroll
        )

        let linkPreviewURL = presentation.parts.compactMap { part -> URL? in
            if case let .linkPreview(url) = part { return url }
            return nil
        }.first

        return BubbleSizingV2.Plan(
            messageId: message.id,
            presentationFingerprint: fingerprints[message.id] ?? fingerprint(for: message),
            sizeClass: sizeClass,
            isSingleLinkPreview: isSingleLinkPreview,
            isWide: isWide,
            maxWidth: maxWidth,
            minWidth: minWidth,
            heightPolicy: heightPolicy,
            allowsOuterScroll: allowsOuterScroll,
            linkPreviewURL: linkPreviewURL
        )
    }

    private func linkPreviewViewportMaxHeight(plan: BubbleSizingV2.Plan) -> CGFloat {
        return plan.heightPolicy.linkPreviewViewportMaxHeight
    }

    private func authoritativeBubbleSizingV2LayoutState(message: Message,
                                                        presentation: MessagePresentation,
                                                        metrics: ChatFlowTheme.Metrics,
                                                        env: BubbleSizingV2.Environment,
                                                        sendIndicatorState: MessageSendIndicatorState?,
                                                        showsHeader: Bool) -> BubbleSizingV2.LayoutState {
        let plan = bubbleSizingV2Plan(
            message: message,
            presentation: presentation,
            metrics: metrics,
            env: env,
            showsHeader: showsHeader
        )
        return bubbleSizingV2LayoutState(
            message: message,
            presentation: presentation,
            metrics: metrics,
            env: env,
            plan: plan,
            sendIndicatorState: sendIndicatorState,
            showsHeader: showsHeader
        )
    }

    private func bubbleSizingV2LayoutState(message: Message,
                                          presentation: MessagePresentation,
                                          metrics: ChatFlowTheme.Metrics,
                                          env: BubbleSizingV2.Environment,
                                          plan: BubbleSizingV2.Plan,
                                          sendIndicatorState: MessageSendIndicatorState?,
                                          showsHeader: Bool) -> BubbleSizingV2.LayoutState {
        let initialLinkVersion: Int = bubbleV2PreviewVersion(for: message.id)
        let layoutFingerprintSeed = bubbleSizingV2LayoutFingerprintSeed(
            plan: plan,
            showsHeader: showsHeader,
            hasFailureBadge: sendIndicatorState != nil
        )
        let key = plan.heightPolicy.measurementCacheKey(
            sessionKey: message.sessionKey,
            messageId: message.id,
            presentationFingerprint: plan.presentationFingerprint,
            layoutFingerprintSeed: layoutFingerprintSeed,
            env: env,
            linkPreviewStateVersion: initialLinkVersion
        )
        if let cached = bubbleV2LayoutState(for: key) {
            return applyingLiveMeasuredCellSize(cached, messageId: message.id)
        }
        if let cachedMeasurement = bubbleV2Measurement(for: key) {
            let layoutState = bubbleSizingV2MakeLayoutState(
                message: message,
                presentation: presentation,
                metrics: metrics,
                env: env,
                plan: plan,
                measurement: cachedMeasurement
            )
            recordBubbleV2LayoutState(layoutState, key: key, messageId: message.id)
            return applyingLiveMeasuredCellSize(layoutState, messageId: message.id)
        }

        logger.debug(
            "T1377_PROFILE measurement_cache_miss message_id=\(message.id, privacy: .public) settle_epoch=\(self.bubbleSizingV2ScrollSettleEpoch)"
        )

        let measured = bubbleSizingV2Measure(
            message: message,
            presentation: presentation,
            metrics: metrics,
            env: env,
            plan: plan,
            sendIndicatorState: sendIndicatorState,
            showsHeader: showsHeader
        )
        recordBubbleV2LayoutState(measured, key: key, messageId: message.id)
        return applyingLiveMeasuredCellSize(measured, messageId: message.id)
    }

    private func applyingLiveMeasuredCellSize(
        _ layoutState: BubbleSizingV2.LayoutState,
        messageId: String
    ) -> BubbleSizingV2.LayoutState {
        guard let liveSize = sizeCache[messageId] else { return layoutState }
        let measurement = layoutState.measurement
        return BubbleSizingV2.LayoutState(
            plan: layoutState.plan,
            measurement: BubbleSizingV2.Measurement(
                measuredCellSize: liveSize,
                measuredBubbleWidth: measurement.measuredBubbleWidth,
                contentHeight: measurement.contentHeight,
                chromeHeight: measurement.chromeHeight,
                outerScrollEnabled: measurement.outerScrollEnabled,
                outerScrollViewportHeight: measurement.outerScrollViewportHeight,
                isFinal: measurement.isFinal
            ),
            linkPreviewCacheKey: layoutState.linkPreviewCacheKey,
            linkPreviewEstimatedHeight: layoutState.linkPreviewEstimatedHeight,
            linkPreviewMinHeight: layoutState.linkPreviewMinHeight,
            linkPreviewMaxHeight: layoutState.linkPreviewMaxHeight
        )
    }

    private func bubbleSizingV2LayoutFingerprintSeed(plan: BubbleSizingV2.Plan,
                                                     showsHeader: Bool,
                                                     hasFailureBadge: Bool) -> Int
    {
        BubbleSizingV2.layoutFingerprintSeed(
            plan: plan,
            showsHeader: showsHeader,
            hasFailureBadge: hasFailureBadge
        )
    }

    private func bubbleSizingV2MakeLayoutState(message _: Message,
                                               presentation: MessagePresentation,
                                               metrics: ChatFlowTheme.Metrics,
                                               env: BubbleSizingV2.Environment,
                                               plan: BubbleSizingV2.Plan,
                                               measurement: BubbleSizingV2.Measurement) -> BubbleSizingV2.LayoutState
    {
        guard let url = plan.linkPreviewURL else {
            return BubbleSizingV2.LayoutState(
                plan: plan,
                measurement: measurement,
                linkPreviewCacheKey: nil,
                linkPreviewEstimatedHeight: nil,
                linkPreviewMinHeight: 40,
                linkPreviewMaxHeight: measurement.outerScrollViewportHeight
            )
        }
        let paddingHorizontal = round((presentation.hasMediaOnly ? 8 : metrics.bubblePaddingHorizontal) * 1)
        let contentWidth = max(1, measurement.measuredBubbleWidth - (paddingHorizontal * 2))
        let cacheKey = "\(url.absoluteString)|w=\(Int(contentWidth.rounded()))|m=\(env.metricsFingerprint)"
        let previewMaxHeight = linkPreviewViewportMaxHeight(plan: plan)
        let fixedPreviewHeight: CGFloat? = {
            guard plan.isSingleLinkPreview else { return nil }
            if LinkPreviewView.isDirectMediaPreviewURL(url) {
                return LinkPreviewView.preferredDirectMediaHeight(for: contentWidth, maxHeight: previewMaxHeight)
            }
            return previewMaxHeight
        }()
        let estimated = fixedPreviewHeight
            ?? cachedPreviewHeight(cacheKey: cacheKey)
            ?? 120
        let previewMinHeight = fixedPreviewHeight ?? 40
        return BubbleSizingV2.LayoutState(
            plan: plan,
            measurement: measurement,
            linkPreviewCacheKey: cacheKey,
            linkPreviewEstimatedHeight: estimated,
            linkPreviewMinHeight: previewMinHeight,
            linkPreviewMaxHeight: previewMaxHeight
        )
    }

    private func bubbleSizingV2Measure(message: Message,
                                       presentation: MessagePresentation,
                                       metrics: ChatFlowTheme.Metrics,
                                       env: BubbleSizingV2.Environment,
                                       plan: BubbleSizingV2.Plan,
                                       sendIndicatorState: MessageSendIndicatorState?,
                                       showsHeader: Bool) -> BubbleSizingV2.LayoutState {
        // Pass 0: configure at max width so preferredWidth() can read padding and label sizes.
        uiKitBubbleSizer.configure(
            message: message,
            stream: viewModel?.streamType(for: message.sessionKey) ?? .personal,
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: plan.maxWidth,
            bubbleHeightPolicy: plan.heightPolicy,
            truncationHeightOverride: plan.heightPolicy.v1TruncationHeightOverride,
            showsHeader: showsHeader,
            showsProvenanceChrome: viewModel?.isTightbeamServer ?? false,
            minWidthOverride: plan.minWidth,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: viewModel?.replyReference(for: message)
        )

        let measuredBubbleWidth: CGFloat = {
            if plan.isWide { return plan.maxWidth }
            if plan.sizeClass == .short {
                let preferred = uiKitBubbleSizer.preferredWidth(
                    maxWidth: plan.maxWidth,
                    minWidth: plan.minWidth
                )
                return BubbleSizingV2.clamp(preferred, plan.minWidth, plan.maxWidth)
            }
            return plan.maxWidth
        }()

        let paddingHorizontal = round((presentation.hasMediaOnly ? 8 : metrics.bubblePaddingHorizontal) * 1)
        let contentWidth = max(1, measuredBubbleWidth - (paddingHorizontal * 2))

        let linkPreviewCacheKey: String? = plan.linkPreviewURL.map { url in
            "\(url.absoluteString)|w=\(Int(contentWidth.rounded()))|m=\(env.metricsFingerprint)"
        }
        let linkPreviewMaxHeight = linkPreviewViewportMaxHeight(plan: plan)
        let fixedPreviewHeight: CGFloat? = {
            guard plan.isSingleLinkPreview, let url = plan.linkPreviewURL else { return nil }
            if LinkPreviewView.isDirectMediaPreviewURL(url) {
                return LinkPreviewView.preferredDirectMediaHeight(for: contentWidth, maxHeight: linkPreviewMaxHeight)
            }
            return linkPreviewMaxHeight
        }()
        let linkPreviewEstimatedHeight: CGFloat? = fixedPreviewHeight
            ?? linkPreviewCacheKey.flatMap { cachedPreviewHeight(cacheKey: $0) }
        let previewInitialHeight = linkPreviewEstimatedHeight ?? 120
        let previewMinHeight = fixedPreviewHeight ?? 40

        // Pass 1: compute chrome height with an upper-bound link preview max height.
        let provisional1 = BubbleSizingV2.LayoutState(
            plan: plan,
            measurement: BubbleSizingV2.Measurement(
                measuredCellSize: .zero,
                measuredBubbleWidth: measuredBubbleWidth,
                contentHeight: 0,
                chromeHeight: 0,
                outerScrollEnabled: false,
                outerScrollViewportHeight: plan.heightPolicy.heightCap,
                isFinal: linkPreviewEstimatedHeight != nil
            ),
            linkPreviewCacheKey: linkPreviewCacheKey,
            linkPreviewEstimatedHeight: previewInitialHeight,
            linkPreviewMinHeight: previewMinHeight,
            linkPreviewMaxHeight: linkPreviewMaxHeight
        )
        uiKitBubbleSizer.configure(
            message: message,
            stream: viewModel?.streamType(for: message.sessionKey) ?? .personal,
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: measuredBubbleWidth,
            bubbleHeightPolicy: plan.heightPolicy,
            truncationHeightOverride: plan.heightPolicy.v1TruncationHeightOverride,
            bubbleSizingV2: provisional1,
            showsHeader: showsHeader,
            showsProvenanceChrome: viewModel?.isTightbeamServer ?? false,
            minWidthOverride: plan.minWidth,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: viewModel?.replyReference(for: message)
        )
        let target = CGSize(width: measuredBubbleWidth, height: UIView.layoutFittingCompressedSize.height)
        let measured1 = uiKitBubbleSizer.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let dynamicHeight1 = uiKitBubbleSizer.measuredDynamicContentHeight(fittingWidth: contentWidth)
        let chromeHeight = max(0, measured1.height - dynamicHeight1)
        let viewportHeight = max(plan.heightPolicy.heightCap - chromeHeight, 44)

        // Pass 2: reconfigure with the final link-preview viewport max height.
        // Web previews are fixed-height viewports with internal WKWebView scrolling.
        let provisional2 = BubbleSizingV2.LayoutState(
            plan: plan,
            measurement: BubbleSizingV2.Measurement(
                measuredCellSize: .zero,
                measuredBubbleWidth: measuredBubbleWidth,
                contentHeight: 0,
                chromeHeight: chromeHeight,
                outerScrollEnabled: false,
                outerScrollViewportHeight: viewportHeight,
                isFinal: linkPreviewEstimatedHeight != nil
            ),
            linkPreviewCacheKey: linkPreviewCacheKey,
            linkPreviewEstimatedHeight: previewInitialHeight,
            linkPreviewMinHeight: previewMinHeight,
            linkPreviewMaxHeight: linkPreviewMaxHeight
        )
        uiKitBubbleSizer.configure(
            message: message,
            stream: viewModel?.streamType(for: message.sessionKey) ?? .personal,
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: measuredBubbleWidth,
            bubbleHeightPolicy: plan.heightPolicy,
            truncationHeightOverride: plan.heightPolicy.v1TruncationHeightOverride,
            bubbleSizingV2: provisional2,
            showsHeader: showsHeader,
            showsProvenanceChrome: viewModel?.isTightbeamServer ?? false,
            minWidthOverride: plan.minWidth,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil,
            onInsertIntoPrompt: nil,
            onReferenceMessage: nil,
            replyReference: viewModel?.replyReference(for: message)
        )

        let measured2 = uiKitBubbleSizer.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let dynamicHeight2 = uiKitBubbleSizer.measuredDynamicContentHeight(fittingWidth: contentWidth)

        let outerScrollEnabled = plan.allowsOuterScroll && measured2.height > plan.heightPolicy.heightCap
        let finalViewportHeight = BubbleSizingV2.finalOuterScrollViewportHeight(
            plan: plan,
            measuredContentHeight: dynamicHeight2,
            provisionalViewportHeight: viewportHeight
        )
        let cellHeight: CGFloat = {
            if plan.isSingleLinkPreview {
                return plan.heightPolicy.heightCap
            }
            if plan.allowsOuterScroll {
                return min(measured2.height, plan.heightPolicy.heightCap)
            }
            return measured2.height
        }()

        let snappedSize = snapToPixel(CGSize(width: measuredBubbleWidth, height: max(1, cellHeight)))
        let measurement = BubbleSizingV2.Measurement(
            measuredCellSize: snappedSize,
            measuredBubbleWidth: snappedSize.width,
            contentHeight: dynamicHeight2,
            chromeHeight: chromeHeight,
            outerScrollEnabled: outerScrollEnabled,
            outerScrollViewportHeight: finalViewportHeight,
            isFinal: linkPreviewEstimatedHeight != nil
        )

        return BubbleSizingV2.LayoutState(
            plan: plan,
            measurement: measurement,
            linkPreviewCacheKey: linkPreviewCacheKey,
            linkPreviewEstimatedHeight: previewInitialHeight,
            linkPreviewMinHeight: previewMinHeight,
            linkPreviewMaxHeight: linkPreviewMaxHeight
        )
    }

    private func shouldHideHeader(for message: Message, presentation: MessagePresentation) -> Bool {
        guard message.role == .assistant else { return false }
        if presentation.parts.contains(where: { if case .terminalSession = $0 { return true }; return false }) {
            return true
        }
        guard message.attachments.isEmpty else { return false }
        guard presentation.chromelessStyle == .emoji else { return false }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines) == "👀"
    }

    private func mediumMaxWidth(message: Message,
                                presentation: MessagePresentation,
                                metrics: ChatFlowTheme.Metrics,
                                containerWidth: CGFloat) -> CGFloat
    {
        // Max width same as .long (typography-based)
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let maxAllowedWidth = min(containerWidth, maxLineWidth + metrics.bubblePaddingHorizontal * 2)
        // Min width is 1/4 of the effective max (containerWidth on iPhone, typography-based on iPad)
        let minWidth = containerWidth / 4

        // Strategy: minimize width (prefer more lines), only use fewer lines if width < minWidth

        // 1. Try 3 lines - find minimum width
        if let width = findMinimumWidthForLines(
            targetLines: 3,
            message: message,
            presentation: presentation,
            metrics: metrics,
            minWidth: minWidth,
            maxWidth: maxAllowedWidth
        ), width >= minWidth {
            return width
        }

        // 2. Try 2 lines - find minimum width
        if let width = findMinimumWidthForLines(
            targetLines: 2,
            message: message,
            presentation: presentation,
            metrics: metrics,
            minWidth: minWidth,
            maxWidth: maxAllowedWidth
        ), width >= minWidth {
            return width
        }

        // 3. Try single line
        let singleLineWidth = measureSingleLineWidth(
            for: message,
            presentation: presentation,
            metrics: metrics
        )
        if singleLineWidth <= maxAllowedWidth {
            return max(minWidth, singleLineWidth)
        }

        // 4. Fallback - use max allowed width
        return maxAllowedWidth
    }

    private func measureSingleLineWidth(for _: Message,
                                        presentation: MessagePresentation,
                                        metrics: ChatFlowTheme.Metrics) -> CGFloat
    {
        // UIKit-native single-line width measurement
        let textWidth = MessageBubbleUIKitView.measureSingleLineWidth(
            for: presentation,
            metrics: metrics
        )
        // Add bubble padding
        return textWidth + (metrics.bubblePaddingHorizontal * 2)
    }

    private func findMinimumWidthForLines(targetLines: Int,
                                          message: Message,
                                          presentation: MessagePresentation,
                                          metrics: ChatFlowTheme.Metrics,
                                          minWidth: CGFloat,
                                          maxWidth: CGFloat) -> CGFloat?
    {
        // Check if target line count is achievable at max width
        let linesAtMax = estimatedLineCount(
            for: message,
            presentation: presentation,
            metrics: metrics,
            atWidth: maxWidth
        )
        guard linesAtMax <= targetLines else {
            return nil // Can't fit in targetLines even at max width
        }

        // Binary search for minimum width where text fits in targetLines
        var low = minWidth
        var high = maxWidth
        var bestWidth = maxWidth

        while high - low > 4 { // 4pt precision is sufficient
            let mid = floor((low + high) / 2)
            let lines = estimatedLineCount(
                for: message,
                presentation: presentation,
                metrics: metrics,
                atWidth: mid
            )
            if lines <= targetLines {
                bestWidth = mid
                high = mid
            } else {
                low = mid
            }
        }

        return bestWidth
    }

    private func estimatedLineCount(for _: Message,
                                    presentation: MessagePresentation,
                                    metrics: ChatFlowTheme.Metrics,
                                    atWidth bubbleWidth: CGFloat) -> Int
    {
        // UIKit-native line count estimation
        MessageBubbleUIKitView.estimatedLineCount(
            for: presentation,
            metrics: metrics,
            atBubbleWidth: bubbleWidth
        )
    }

    private func measureTextHeight(for _: Message,
                                   presentation: MessagePresentation,
                                   sizeClass: MessageSizeClass,
                                   metrics: ChatFlowTheme.Metrics,
                                   maxWidth: CGFloat) -> CGFloat?
    {
        // UIKit-native text height measurement
        MessageBubbleUIKitView.measureTextHeight(
            for: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth
        )
    }

    func scrollToBottom(animated: Bool) {
        if let sessionKey = callbackSessionKey() {
            // Bottom is transcript truth, never the tail of a filtered projection.
            // Clear transient projections before materializing the transcript edge.
            if !streamSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = enqueueMaterializationEvent(
                    sessionKey: sessionKey,
                    event: .transcriptTruthTargetRequested(animated: animated)
                )
                onStreamSearchQueryChanged?(sessionKey, "")
                return
            }
            if readState(for: sessionKey).isShowingOnlyUserMessages {
                _ = enqueueMaterializationEvent(
                    sessionKey: sessionKey,
                    event: .transcriptTruthTargetRequested(animated: animated)
                )
                setShowOnlyUserMessagesMode(false)
                return
            }
            if materializeProjectionEdge(sessionKey: sessionKey, tail: true, animated: animated) {
                return
            }
        }
        scrollToActiveProjectionBottom(animated: animated)
    }

    private func scrollToActiveProjectionBottom(animated: Bool) {
        if let sessionKey = callbackSessionKey(),
           materializeProjectionEdge(sessionKey: sessionKey, tail: true, animated: animated)
        {
            return
        }
        let lastMessageAnchorExists = lastMessageId.flatMap { dataSource.indexPath(for: $0) } != nil
        collectionView.layoutIfNeeded()
        let contentInset = collectionView.contentInset
        // Scroll to the bottom of the content (includes section insets/padding).
        // Using contentSize avoids under-scrolling when sectionInset.bottom is non-zero.
        let targetY = restingBottomContentHeight() - collectionView.bounds.height + contentInset.bottom
        let minY = -contentInset.top
        let maxY = restingBottomOffsetMaxY(bottomInset: contentInset.bottom)
        let clampedY = max(minY, min(targetY, maxY))
        logScrollCall(
            "scrollToBottom",
            sessionKey: callbackSessionKey(),
            currentY: collectionView.contentOffset.y,
            targetY: clampedY,
            animated: animated,
            reason: "restingContentHeight=\(formatScrollRestore(restingBottomContentHeight())) insetBottom=\(formatScrollRestore(contentInset.bottom)) fallback=\(Self.shouldFallbackToAbsoluteBottom(lastMessageId: lastMessageId, hasMessageAnchor: lastMessageAnchorExists))"
        )
        // If we're already at (or extremely near) the bottom, don't re-set contentOffset.
        if abs(collectionView.contentOffset.y - clampedY) <= 0.5 {
            if let sessionKey = callbackSessionKey() {
                refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
            }
            updateVisibleFooterAlpha()
            return
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
        if !animated, let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
            updateVisibleFooterAlpha()
        }
    }

    func scrollToTop(animated: Bool) {
        if let sessionKey = callbackSessionKey() {
            if materializeProjectionEdge(sessionKey: sessionKey, tail: false, animated: animated) {
                return
            }
        }
        finishScrollToTop(animated: animated)
    }

    private func finishScrollToTop(animated: Bool) {
        collectionView.layoutIfNeeded()
        let minY = -collectionView.contentInset.top
        if abs(collectionView.contentOffset.y - minY) <= 0.5 {
            return
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: minY), animated: animated)
        if !animated, let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
    }

    func scrollByPage(direction: ChatScrollPageDirection, animated: Bool) {
        collectionView.layoutIfNeeded()
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        let visibleHeight = collectionView.bounds.height - contentInset.top - contentInset.bottom
        guard visibleHeight > 0 else { return }
        let pageIncrement = max(120, visibleHeight * 0.82)
        let materializationDirection: MaterializationShiftDirection = direction == .down ? .newer : .older
        let fullResidual = direction == .down ? -pageIncrement : pageIncrement
        if maxY <= minY {
            if let sessionKey = callbackSessionKey() {
                _ = shiftMaterializationWindowIfNeeded(
                    sessionKey: sessionKey,
                    requestedDirection: materializationDirection,
                    residual: fullResidual
                )
            }
            return
        }

        let delta = direction == .down ? pageIncrement : -pageIncrement
        let targetY = collectionView.contentOffset.y + delta
        let clampedY = max(minY, min(targetY, maxY))
        let consumedOffset = clampedY - collectionView.contentOffset.y
        let unconsumedOffset = delta - consumedOffset

        logScrollCall(
            "scrollByPage",
            sessionKey: callbackSessionKey(),
            currentY: collectionView.contentOffset.y,
            targetY: clampedY,
            animated: animated,
            reason: "direction=\(direction) increment=\(formatScrollRestore(pageIncrement))"
        )
        collectionView.setContentOffset(
            CGPoint(x: 0, y: clampedY),
            animated: animated && abs(unconsumedOffset) <= 0.5
        )
        if abs(unconsumedOffset) > 0.5, let sessionKey = callbackSessionKey() {
            _ = shiftMaterializationWindowIfNeeded(
                sessionKey: sessionKey,
                requestedDirection: materializationDirection,
                residual: -unconsumedOffset
            )
        } else if !animated, let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
    }

    func scrollByGestureDelta(_ deltaY: CGFloat) {
        guard abs(deltaY) > 0.5 else { return }
        collectionView.layoutIfNeeded()
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        let materializationDirection: MaterializationShiftDirection = deltaY > 0 ? .older : .newer
        if maxY <= minY {
            if let sessionKey = callbackSessionKey() {
                _ = shiftMaterializationWindowIfNeeded(
                    sessionKey: sessionKey,
                    requestedDirection: materializationDirection,
                    residual: deltaY
                )
            }
            return
        }

        let targetY = collectionView.contentOffset.y - deltaY
        let clampedY = max(minY, min(targetY, maxY))
        let consumedOffset = clampedY - collectionView.contentOffset.y
        let residual = deltaY + consumedOffset

        logScrollCall(
            "scrollByGestureDelta",
            sessionKey: callbackSessionKey(),
            currentY: collectionView.contentOffset.y,
            targetY: clampedY,
            animated: false,
            reason: "deltaY=\(formatScrollRestore(deltaY))"
        )
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: clampedY), animated: false)
        if abs(residual) > 0.5, let sessionKey = callbackSessionKey() {
            _ = shiftMaterializationWindowIfNeeded(
                sessionKey: sessionKey,
                requestedDirection: materializationDirection,
                residual: residual
            )
        } else if let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
    }

    @discardableResult
    func scrollVisibleBubbleContents(direction: ChatScrollPageDirection, animated: Bool) -> Int {
        collectionView.layoutIfNeeded()

        var scrolledCount = 0
        for cell in collectionView.visibleCells {
            guard cell is MessageBubbleUIKitCell || cell is WebBubbleUIKitCell else { continue }
            guard collectionView.bounds.intersects(cell.frame) else { continue }
            scrolledCount += ChatVisibleBubbleContentScroll.scrollVisibleScrollableContent(
                in: cell.contentView,
                visibleIn: collectionView,
                direction: direction,
                animated: animated
            )
        }
        return scrolledCount
    }

    func scrollToMessageCentered(messageId: String, animated: Bool) {
        guard let sessionKey = callbackSessionKey() else { return }
        guard let indexPath = dataSource.indexPath(for: messageId) else {
            if materializeWindowContainingMessage(
                sessionKey: sessionKey,
                messageId: messageId,
                animated: animated,
                flash: false
            ) {
                return
            }
            registerOnMessageLoad(sessionKey: sessionKey, messageId: messageId) { [weak self] in
                self?.scrollToMessageCentered(messageId: messageId, animated: animated)
            }
            return
        }
        collectionView.layoutIfNeeded()

        let contentInset = collectionView.contentInset
        let visibleHeight = collectionView.bounds.height - contentInset.top - contentInset.bottom
        guard visibleHeight > 0 else { return }

        guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
            return
        }

        // Align the cell center to the visible rect center (not just ".centeredVertically",
        // which can edge-snap near the top/bottom).
        let targetOffsetY = attrs.center.y - (visibleHeight / 2) - contentInset.top
        let minY = -contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let clampedY = max(minY, min(targetOffsetY, maxY))
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
        if !animated {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
    }

    func scrollToMessageCenteredIfMaterialized(messageId: String, animated: Bool) -> Bool {
        guard let sessionKey = callbackSessionKey() else {
            return false
        }
        guard let indexPath = dataSource.indexPath(for: messageId) else {
            guard materializeWindowContainingMessage(
                sessionKey: sessionKey,
                messageId: messageId,
                animated: animated,
                flash: false
            ) else {
                return false
            }
            registerOnMessageLoad(sessionKey: sessionKey, messageId: messageId) { [weak self] in
                self?.scrollToMessageCentered(messageId: messageId, animated: animated)
            }
            return true
        }
        collectionView.layoutIfNeeded()

        let contentInset = collectionView.contentInset
        let visibleHeight = collectionView.bounds.height - contentInset.top - contentInset.bottom
        guard visibleHeight > 0 else { return false }

        guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
            return true
        }

        let targetOffsetY = attrs.center.y - (visibleHeight / 2) - contentInset.top
        let minY = -contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let clampedY = max(minY, min(targetOffsetY, maxY))
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
        if !animated {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
        return true
    }

    func isNearBottom(extraMargin: CGFloat) -> Bool {
        // `contentOffset.y` is measured in the scroll view’s content coordinates, where "top" is
        // typically `-contentInset.top`. The previous implementation subtracted `contentInset.top`
        // via `visibleHeight`, which made "distance from bottom" effectively equal to `contentInset.top`
        // even when fully scrolled to the bottom. That prevents "at bottom" from ever becoming true.
        let inset = collectionView.contentInset
        let viewportBottomY = collectionView.contentOffset.y + collectionView.bounds.height - inset.bottom
        let distanceFromBottom = restingBottomContentHeight() - viewportBottomY
        return distanceFromBottom <= extraMargin
    }

    func adjustContentOffsetForBottomInsetChange(delta: CGFloat) {
        guard abs(delta) > 0.5 else { return }
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let targetY = collectionView.contentOffset.y + delta
        let clampedY = max(minY, min(targetY, maxY))
        logScrollCall(
            "adjustContentOffsetForBottomInsetChange",
            sessionKey: callbackSessionKey(),
            currentY: collectionView.contentOffset.y,
            targetY: clampedY,
            animated: false,
            reason: "delta=\(formatScrollRestore(delta)) insetBottom=\(formatScrollRestore(contentInset.bottom))"
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
        if let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
    }

    var isUserInteracting: Bool {
        collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
    }

    var isActivelyDraggingOrTracking: Bool {
        // Keyboard dismiss + inset pinning should only follow active touch interaction.
        collectionView.isDragging || collectionView.isTracking
    }

    var isPinnedToBottomIntent: Bool {
        sbbState.isPinnedToBottomIntent
    }

    // internal for regression access (F4): provenance fields must be in the hash.
    func fingerprint(for message: Message) -> Int {
        var hasher = Hasher()
        hasher.combine(message.content)
        hasher.combine(message.streaming)
        // Provenance drives the chip class, sender label, and stamp-strip. A
        // replay/authoritative update can correct sender/role on a same-id,
        // same-content message; without these the diff misses it and the cell
        // keeps the wrong chip (spec §T-D).
        hasher.combine(message.sender)
        hasher.combine(message.role)
        hasher.combine(viewModel?.sendIndicatorState(for: message.id))
        hasher.combine(message.replyToMessageId)
        hasher.combine(message.replyToClientMessageId)
        hasher.combine(viewModel?.replyReferenceFingerprint(for: message))
        hasher.combine(message.attachments.count)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.type.rawValue)
            hasher.combine(attachment.mimeType ?? "")
            hasher.combine(attachment.assetId ?? "")
            hasher.combine(attachment.data?.count ?? 0)
        }
        return hasher.finalize()
    }

    private func invalidateLayout(for messageId: String) {
        let plan = invalidateFor(reason: .messageChanged(id: messageId))
        executeInvalidationPlan(plan)
    }

    private func handleCellRequestedLayout(messageId: String) {
        let isSettled = bubbleSizingV2Enabled
            ? isBubbleSizingV2ScrollAtRest()
            : isScrollFullyStoppedForPreviewRemeasure()
        guard isSettled else {
            deferredPreviewRemeasureIds.insert(messageId)
            logger.debug(
                "T1377_PROFILE async_callback outcome=deferred message_id=\(messageId, privacy: .public) settle_epoch=\(self.bubbleSizingV2ScrollSettleEpoch)"
            )
            scheduleDeferredPreviewRemeasureFlushAfterRest()
            return
        }
        if bubbleSizingV2Enabled {
            // BubbleSizingV2 normally remeasures when link preview (WKWebView) height changes.
            // Link cards update async (metadata/thumbnails) and can change height too, so we need
            // a generic V2 remeasure path when there is no link preview.
            if let viewModel, let message = messagesById[messageId] {
                let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
                let presentation = viewModel.presentation(for: message, metrics: metrics)
                let hasLinkPreview = presentation.parts.contains { part in
                    if case .linkPreview = part { return true }
                    return false
                }
                let hasInteractiveHTML = presentation.parts.contains { part in
                    if case .interactiveHTML = part { return true }
                    return false
                }
                if hasLinkPreview && !hasInteractiveHTML {
                    handleBubbleSizingV2LinkPreviewLayout(messageId: messageId)
                } else {
                    var producerRevision = "generic"
                    if let indexPath = dataSource.indexPath(for: messageId),
                       let cell = collectionView.cellForItem(at: indexPath)
                    {
                        let linkCards = findLinkCardViews(in: cell.contentView)
                        guard Self.shouldQueueBubbleSizingV2AsyncRemeasure(
                            isContentSettled: linkCards.allSatisfy(\.isContentSettled),
                            alreadyAcceptedInSettle: false
                        ) else {
                            logger.debug(
                                "T1377_PROFILE async_callback outcome=awaiting_content_settle message_id=\(messageId, privacy: .public) settle_epoch=\(self.bubbleSizingV2ScrollSettleEpoch)"
                            )
                            return
                        }
                        producerRevision = genericAsyncProducerRevision(in: cell.contentView)
                    }
                    guard queueBubbleSizingV2Remeasure(
                        messageId: messageId,
                        producerRevision: producerRevision,
                        previewLoadToken: nil
                    ) else {
                        return
                    }
                    bubbleSizingV2PendingRemeasureIds.insert(messageId)
                    bubbleSizingV2PendingLiveMeasurementIds.insert(messageId)
                    scheduleBubbleSizingV2Remeasure()
                }
            } else {
                guard queueBubbleSizingV2Remeasure(
                    messageId: messageId,
                    producerRevision: "generic",
                    previewLoadToken: nil
                ) else {
                    return
                }
                bubbleSizingV2PendingRemeasureIds.insert(messageId)
                bubbleSizingV2PendingLiveMeasurementIds.insert(messageId)
                scheduleBubbleSizingV2Remeasure()
            }
            return
        }
        applyRequestedLayoutNow(messageId: messageId)
    }

    private func applyRequestedLayoutNow(messageId: String) {
        guard let viewModel, let message = messagesById[messageId] else {
            invalidateLayout(for: messageId)
            return
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let stableMaxWidth = maxItemWidth(
            for: sizeClass,
            message: message,
            presentation: presentation,
            metrics: metrics,
            containerWidth: effectiveContentWidth(metrics: metrics)
        )
        guard let indexPath = dataSource.indexPath(for: messageId),
              let cell = collectionView.cellForItem(at: indexPath)
        else {
            invalidateLayout(for: messageId)
            return
        }

        // Async WebKit content only has meaningful final geometry while attached to a window.
        // Measure the live cell (not the offscreen sizer) and feed the result back into the cache.
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let liveWidth = cell.contentView.bounds.width
        // #63: Avoid caching invalid narrow widths when the cell hasn't been laid out yet (bounds.width ~= 0).
        // Prefer the stable max width derived from message presentation/layout rules.
        let width = (liveWidth >= 40) ? liveWidth : stableMaxWidth
        guard width >= 40 else {
            invalidateLayout(for: messageId)
            return
        }
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let measured = cell.contentView.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        applyMeasuredSize(measured, for: messageId)
    }

    private func isScrollFullyStoppedForPreviewRemeasure() -> Bool {
        !collectionView.isDragging && !collectionView.isTracking && !collectionView.isDecelerating
    }

    private func scheduleDeferredPreviewRemeasureFlushAfterRest() {
        guard !deferredPreviewRemeasureIds.isEmpty else { return }
        guard deferredPreviewRemeasureTimer == nil else { return }
        guard let token = activeSessionGenerationToken() else { return }
        let timer = Timer(timeInterval: Self.previewRemeasureRestPollSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.callbackSessionKey() == token.sessionKey else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            self.withBoundSessionKey(token.sessionKey) {
                self.deferredPreviewRemeasureTimer = nil
                self.flushDeferredPreviewRemeasuresIfPossible()
                if !self.deferredPreviewRemeasureIds.isEmpty {
                    self.scheduleDeferredPreviewRemeasureFlushAfterRest()
                }
            }
        }
        deferredPreviewRemeasureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flushDeferredPreviewRemeasuresIfPossible() {
        guard !deferredPreviewRemeasureIds.isEmpty else { return }
        guard isScrollFullyStoppedForPreviewRemeasure() else { return }
        deferredPreviewRemeasureTimer?.invalidate()
        deferredPreviewRemeasureTimer = nil
        let ids = Array(deferredPreviewRemeasureIds)
        deferredPreviewRemeasureIds.removeAll()
        for id in ids {
            handleCellRequestedLayout(messageId: id)
        }
    }

    private func handleBubbleSizingV2LinkPreviewLayout(messageId: String) {
        guard let viewModel, let message = messagesById[messageId] else {
            invalidateLayout(for: messageId)
            return
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        guard let linkPreviewURL = presentation.parts.compactMap({ part -> URL? in
            if case let .linkPreview(url) = part { return url }
            return nil
        }).first else {
            invalidateLayout(for: messageId)
            return
        }

        guard let indexPath = dataSource.indexPath(for: messageId),
              let cell = collectionView.cellForItem(at: indexPath)
        else {
            invalidateLayout(for: messageId)
            return
        }

        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        // Find the live preview view to get its current measured height.
        guard let previewView = findLinkPreviewView(in: cell.contentView) else {
            invalidateLayout(for: messageId)
            return
        }
        guard let cacheKey = previewView.configuredCacheKey else {
            invalidateLayout(for: messageId)
            return
        }
        // Defensive: ensure the cache key matches the URL we believe is in the message presentation.
        guard cacheKey.hasPrefix(linkPreviewURL.absoluteString) else {
            invalidateLayout(for: messageId)
            return
        }
        let newHeight = previewView.reportedHeight
        guard Self.bubbleSizingV2AsyncPreviewHeightChanged(
            previous: bubbleSizingV2LinkPreviewHeightCache.get(cacheKey: cacheKey),
            next: newHeight
        ) else {
            logger.debug(
                "T1377_PROFILE async_callback outcome=unchanged message_id=\(messageId, privacy: .public) preview_load=\(previewView.currentLoadToken.uuidString, privacy: .public) settle_epoch=\(self.bubbleSizingV2ScrollSettleEpoch)"
            )
            return
        }
        guard queueBubbleSizingV2Remeasure(
            messageId: messageId,
            producerRevision: "preview:\(previewView.currentLoadToken.uuidString):\(Int(newHeight.rounded()))",
            previewLoadToken: previewView.currentLoadToken
        ) else { return }
        _ = recordAsyncPreview(messageId: messageId, key: cacheKey, height: newHeight)

        bubbleSizingV2PendingRemeasureIds.insert(messageId)
        scheduleBubbleSizingV2Remeasure()
    }

    private struct BubbleSizingV2AcceptedRemeasureKey: Hashable {
        let messageId: String
        let producerRevision: String
    }

    private func queueBubbleSizingV2Remeasure(
        messageId: String,
        producerRevision: String,
        previewLoadToken: UUID?
    ) -> Bool {
        let key = BubbleSizingV2AcceptedRemeasureKey(
            messageId: messageId,
            producerRevision: producerRevision
        )
        guard Self.shouldQueueBubbleSizingV2AsyncRemeasure(
            isContentSettled: true,
            alreadyAcceptedInSettle: bubbleSizingV2AcceptedRemeasureKeys.contains(key)
        ) else {
            logger.debug(
                "T1377_PROFILE async_callback outcome=settle_duplicate message_id=\(messageId, privacy: .public) preview_load=\(previewLoadToken?.uuidString ?? "generic", privacy: .public) settle_epoch=\(self.bubbleSizingV2ScrollSettleEpoch)"
            )
            return false
        }
        bubbleSizingV2AcceptedRemeasureKeys.insert(key)
        let outcome = bubbleSizingV2PendingRemeasureIds.contains(messageId) ? "coalesced" : "queued"
        logger.debug(
            "T1377_PROFILE async_callback outcome=\(outcome, privacy: .public) message_id=\(messageId, privacy: .public) preview_load=\(previewLoadToken?.uuidString ?? "generic", privacy: .public) settle_epoch=\(self.bubbleSizingV2ScrollSettleEpoch)"
        )
        return true
    }

    static func shouldQueueBubbleSizingV2AsyncRemeasure(
        isContentSettled: Bool,
        alreadyAcceptedInSettle: Bool
    ) -> Bool {
        isContentSettled && !alreadyAcceptedInSettle
    }

    static func bubbleSizingV2AsyncPreviewHeightChanged(previous: CGFloat?, next: CGFloat) -> Bool {
        previous == nil || abs((previous ?? 0) - next) > 4
    }

    static func bubbleSizingV2AsyncProducerRevision(
        htmlGeometryRevisions: [Int],
        previewLoadToken: UUID?,
        previewHeight: CGFloat?
    ) -> String {
        var components = htmlGeometryRevisions.map { "html:\($0)" }
        if let previewLoadToken, let previewHeight {
            components.append("preview:\(previewLoadToken.uuidString):\(Int(previewHeight.rounded()))")
        }
        return components.isEmpty ? "generic" : components.joined(separator: "|")
    }

    private func scheduleBubbleSizingV2Remeasure() {
        guard let token = activeSessionGenerationToken() else { return }
        // #66: Link previews (WKWebView) report final heights asynchronously. Each report used to
        // trigger a reflow, causing bubbles to jump repeatedly on launch. Debounce + batch into
        // a single remeasure pass, and defer applying it if the user isn't at the bottom.
        if !canApplyBubbleSizingV2RemeasureNow() {
            bubbleSizingV2RemeasureDeferredUntilNearBottom = true
            bubbleSizingV2RemeasureDebounceTimer?.invalidate()
            bubbleSizingV2RemeasureDebounceTimer = nil
            scheduleBubbleSizingV2DeferredFlushAfterRest()
            return
        }
        bubbleSizingV2DeferredFlushTimer?.invalidate()
        bubbleSizingV2DeferredFlushTimer = nil
        if bubbleSizingV2RemeasureBatchStartTime == nil {
            bubbleSizingV2RemeasureBatchStartTime = CFAbsoluteTimeGetCurrent()
        }
        bubbleSizingV2RemeasureDebounceTimer?.invalidate()
        bubbleSizingV2RemeasureDebounceTimer = nil

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - (bubbleSizingV2RemeasureBatchStartTime ?? now)
        let remaining = max(0, Self.bubbleSizingV2RemeasureMaxWaitSeconds - elapsed)
        let delay = min(Self.bubbleSizingV2RemeasureDebounceSeconds, remaining)

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            self.withBoundSessionKey(token.sessionKey) {
                self.bubbleSizingV2RemeasureDebounceTimer = nil
                self.flushBubbleSizingV2RemeasureIfPossible()
            }
        }
        bubbleSizingV2RemeasureDebounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func isBubbleSizingV2ScrollAtRest() -> Bool {
        if collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating {
            return false
        }
        let elapsedSinceLastScroll = CFAbsoluteTimeGetCurrent() - bubbleSizingV2LastScrollActivityTime
        return elapsedSinceLastScroll >= Self.bubbleSizingV2RestSettleDelaySeconds
    }

    private func canApplyBubbleSizingV2RemeasureNow() -> Bool {
        Self.shouldApplyBubbleSizingV2Remeasure(
            isNearBottom: isNearBottom(extraMargin: 240),
            isScrollAtRest: isBubbleSizingV2ScrollAtRest()
        )
    }

    static func shouldApplyBubbleSizingV2Remeasure(isNearBottom _: Bool, isScrollAtRest: Bool) -> Bool {
        // Height cache updates must not wait for the row to become visible again. Once scrolling
        // is settled, the viewport-anchor compensation below preserves the reader's position while
        // making offscreen/cached row geometry truthful before the next scrollback.
        isScrollAtRest
    }

    private func scheduleBubbleSizingV2DeferredFlushAfterRest() {
        guard bubbleSizingV2Enabled else { return }
        guard bubbleSizingV2RemeasureDeferredUntilNearBottom else { return }
        guard bubbleSizingV2DeferredFlushTimer == nil else { return }
        guard let token = activeSessionGenerationToken() else { return }

        let elapsedSinceLastScroll = CFAbsoluteTimeGetCurrent() - bubbleSizingV2LastScrollActivityTime
        let delay = max(0.02, Self.bubbleSizingV2RestSettleDelaySeconds - elapsedSinceLastScroll)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            self.withBoundSessionKey(token.sessionKey) {
                self.bubbleSizingV2DeferredFlushTimer = nil
                self.flushDeferredBubbleSizingV2RemeasureIfNeeded()
                if self.bubbleSizingV2RemeasureDeferredUntilNearBottom {
                    self.scheduleBubbleSizingV2DeferredFlushAfterRest()
                }
            }
        }
        bubbleSizingV2DeferredFlushTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flushDeferredBubbleSizingV2RemeasureIfNeeded() {
        guard bubbleSizingV2Enabled else { return }
        guard bubbleSizingV2RemeasureDeferredUntilNearBottom else { return }
        guard canApplyBubbleSizingV2RemeasureNow() else { return }
        bubbleSizingV2RemeasureDeferredUntilNearBottom = false
        flushBubbleSizingV2RemeasureIfPossible()
    }

    private func flushBubbleSizingV2RemeasureIfPossible() {
        guard canApplyBubbleSizingV2RemeasureNow() else {
            bubbleSizingV2RemeasureDeferredUntilNearBottom = true
            scheduleBubbleSizingV2DeferredFlushAfterRest()
            return
        }
        bubbleSizingV2DeferredFlushTimer?.invalidate()
        bubbleSizingV2DeferredFlushTimer = nil

        let ids = Array(bubbleSizingV2PendingRemeasureIds)
        bubbleSizingV2PendingRemeasureIds.removeAll()
        let liveMeasurementIds = bubbleSizingV2PendingLiveMeasurementIds
        bubbleSizingV2PendingLiveMeasurementIds.removeAll()
        bubbleSizingV2RemeasureBatchStartTime = nil
        guard !ids.isEmpty else { return }
        let viewportAnchor = captureBubbleSizingV2ViewportAnchor()

        for id in ids {
            if liveMeasurementIds.contains(id) {
                applyRequestedLayoutNow(messageId: id)
            } else {
                invalidateBubbleSizingV2Cache(for: id)
                invalidateLayout(for: id)
            }
        }
        logger.debug(
            "T1377_PROFILE geometry_pass settle_epoch=\(self.bubbleSizingV2ScrollSettleEpoch) message_count=\(ids.count) reconfigure_count=0"
        )
        scheduleBubbleSizingV2ViewportAnchorCompensation(viewportAnchor)

        // If more height updates arrived while we were flushing, schedule another debounced pass.
        if !bubbleSizingV2PendingRemeasureIds.isEmpty {
            scheduleBubbleSizingV2Remeasure()
        }
    }

    private func invalidateBubbleSizingV2Cache(for messageId: String) {
        removeBubbleV2Measurements(for: messageId)
    }

    private struct BubbleSizingV2ViewportAnchor {
        let messageId: String
        let contentOffsetY: CGFloat
        let frameMinY: CGFloat
    }

    private struct StreamSearchViewportAnchor {
        let sessionKey: String
        let generation: Int
        let messageId: String?
        let contentOffsetY: CGFloat
        let frameMinY: CGFloat?
    }

    private func captureBubbleSizingV2ViewportAnchor() -> BubbleSizingV2ViewportAnchor? {
        let visibleRect = CGRect(
            origin: collectionView.contentOffset,
            size: collectionView.bounds.size
        )
        let epsilon: CGFloat = 0.5
        let candidates = collectionView.visibleCells.compactMap { cell -> (String, CGRect)? in
            guard let indexPath = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  !isNonMessageItemID(id)
            else {
                return nil
            }
            let frame = cell.frame
            return (id, frame)
        }
        // Settled shifts require a fully visible anchor so asynchronous preview
        // measurement keeps its established compensation contract.
        let fullyVisible = candidates.filter {
            $0.1.minY >= visibleRect.minY + epsilon && $0.1.maxY <= visibleRect.maxY - epsilon
        }
        let anchor = fullyVisible.min(by: { $0.1.minY < $1.1.minY })
        guard let anchor else {
            return nil
        }
        return BubbleSizingV2ViewportAnchor(
            messageId: anchor.0,
            contentOffsetY: collectionView.contentOffset.y,
            frameMinY: anchor.1.minY
        )
    }

    private func captureStreamSearchViewportAnchor() -> StreamSearchViewportAnchor? {
        guard let token = activeSessionGenerationToken() else { return nil }
        let visibleRect = CGRect(
            origin: collectionView.contentOffset,
            size: collectionView.bounds.size
        )
        let epsilon: CGFloat = 0.5
        let candidates = collectionView.visibleCells.compactMap { cell -> (String, CGRect)? in
            guard let indexPath = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  !isNonMessageItemID(id)
            else {
                return nil
            }
            let frame = cell.frame
            guard frame.minY >= visibleRect.minY + epsilon,
                  frame.maxY <= visibleRect.maxY - epsilon
            else {
                return nil
            }
            return (id, frame)
        }
        let anchor = candidates.min(by: { $0.1.minY < $1.1.minY })
        return StreamSearchViewportAnchor(
            sessionKey: token.sessionKey,
            generation: token.generation,
            messageId: anchor?.0,
            contentOffsetY: collectionView.contentOffset.y,
            frameMinY: anchor?.1.minY
        )
    }

    private func scheduleStreamSearchViewportAnchorRestoration(_ anchor: StreamSearchViewportAnchor?) {
        guard let anchor else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.callbackSessionKey() == anchor.sessionKey else { return }
            guard self.readState(for: anchor.sessionKey).restoreGeneration == anchor.generation else { return }

            self.collectionView.layoutIfNeeded()
            let inset = self.collectionView.contentInset
            let minY = -inset.top
            let maxY = max(minY, self.collectionView.contentSize.height - self.collectionView.bounds.height + inset.bottom)
            guard minY.isFinite, maxY.isFinite else { return }

            var targetY = anchor.contentOffsetY
            if let messageId = anchor.messageId,
               let frameMinY = anchor.frameMinY,
               let indexPath = self.dataSource.indexPath(for: messageId),
               let attrs = self.collectionView.layoutAttributesForItem(at: indexPath)
            {
                targetY += attrs.frame.minY - frameMinY
            }
            targetY = max(minY, min(targetY, maxY))
            guard targetY.isFinite else { return }
            guard abs(self.collectionView.contentOffset.y - targetY) > 0.5 else {
                self.refreshLastKnownScrollSnapshot(sessionKey: anchor.sessionKey)
                return
            }
            self.logScrollCall(
                "streamSearchViewportAnchor",
                sessionKey: anchor.sessionKey,
                currentY: self.collectionView.contentOffset.y,
                targetY: targetY,
                animated: false,
                reason: "anchorMessageId=\(anchor.messageId ?? "none") anchorOffsetY=\(self.formatScrollRestore(anchor.contentOffsetY))"
            )
            self.collectionView.setContentOffset(CGPoint(x: self.collectionView.contentOffset.x, y: targetY), animated: false)
            self.refreshLastKnownScrollSnapshot(sessionKey: anchor.sessionKey)
        }
    }

    private func scheduleBubbleSizingV2ViewportAnchorCompensation(_ anchor: BubbleSizingV2ViewportAnchor?) {
        guard let anchor else { return }
        guard let token = activeSessionGenerationToken() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.callbackSessionKey() == token.sessionKey else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            if !Self.shouldApplyViewportAnchorCompensation(
                hasAuthoritativeRestoreTarget: self.hasAuthoritativePersistedRestoreTarget(sessionKey: token.sessionKey)
            ) {
                self.logScrollRestore(
                    "boundedWindowViewportCompensation.disqualified sessionKey=\(token.sessionKey) reason=savedRestoreTargetIsAuthoritative"
                )
                return
            }
            self.collectionView.layoutIfNeeded()
            guard let indexPath = self.dataSource.indexPath(for: anchor.messageId),
                  let attrs = self.collectionView.layoutAttributesForItem(at: indexPath)
            else {
                return
            }
            let delta = attrs.frame.minY - anchor.frameMinY
            guard abs(delta) > 0.5 else { return }
            let inset = self.collectionView.contentInset
            let minY = -inset.top
            let maxY = max(minY, self.collectionView.contentSize.height - self.collectionView.bounds.height + inset.bottom)
            let targetY = max(minY, min(anchor.contentOffsetY + delta, maxY))
            guard targetY.isFinite else { return }
            self.logScrollCall(
                "boundedWindowViewportCompensation",
                sessionKey: token.sessionKey,
                currentY: self.collectionView.contentOffset.y,
                targetY: targetY,
                animated: false,
                reason: "anchorMessageId=\(anchor.messageId) anchorOffsetY=\(self.formatScrollRestore(anchor.contentOffsetY)) delta=\(self.formatScrollRestore(delta))"
            )
            self.collectionView.setContentOffset(CGPoint(x: self.collectionView.contentOffset.x, y: targetY), animated: false)
            self.refreshLastKnownScrollSnapshot(sessionKey: token.sessionKey)
        }
    }

    private func findLinkPreviewView(in view: UIView) -> LinkPreviewView? {
        if let v = view as? LinkPreviewView { return v }
        for subview in view.subviews {
            if let found = findLinkPreviewView(in: subview) { return found }
        }
        return nil
    }

    private func findLinkCardViews(in view: UIView) -> [LinkCardUIKitView] {
        var linkCards: [LinkCardUIKitView] = []
        if let linkCard = view as? LinkCardUIKitView {
            linkCards.append(linkCard)
        }
        for subview in view.subviews {
            linkCards.append(contentsOf: findLinkCardViews(in: subview))
        }
        return linkCards
    }

    private func genericAsyncProducerRevision(in view: UIView) -> String {
        let preview = findLinkPreviewView(in: view)
        return Self.bubbleSizingV2AsyncProducerRevision(
            htmlGeometryRevisions: findInteractiveHTMLViews(in: view).map(\.geometryRevision),
            previewLoadToken: preview?.currentLoadToken,
            previewHeight: preview?.reportedHeight
        )
    }

    private func findInteractiveHTMLViews(in view: UIView) -> [InteractiveHTMLBubbleUIKitView] {
        var htmlViews: [InteractiveHTMLBubbleUIKitView] = []
        if let htmlView = view as? InteractiveHTMLBubbleUIKitView {
            htmlViews.append(htmlView)
        }
        for subview in view.subviews {
            htmlViews.append(contentsOf: findInteractiveHTMLViews(in: subview))
        }
        return htmlViews
    }

    private func scheduleReconfigure(for messageId: String) {
        pendingReconfigureIds.insert(messageId)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyPendingReconfiguresIfPossible()
        }
    }

    private func applyPendingReconfiguresIfPossible() {
        guard !isUpdatePassInFlight, !isSnapshotApplyInFlight else { return }
        let ids = Array(pendingReconfigureIds)
        pendingReconfigureIds.removeAll()
        var snapshot = dataSource.snapshot()
        let existing = ids.filter { snapshot.indexOfItem($0) != nil }
        guard !existing.isEmpty else {
            drainQueuedUpdateIfPossible()
            return
        }
        snapshot.reconfigureItems(existing)
        applyDiffableSnapshot(snapshot, animatingDifferences: false)
    }

    private func reconfigureItem(id: String) {
        scheduleReconfigure(for: id)
    }

    private func scrollToItem(id: String) {
        scrollToMessageCentered(messageId: id, animated: true)
    }

    private func snapshotItemsWithWebBubbles(from itemIds: [String], stream: ChatStream) -> [String] {
        var merged = itemIds
        let parentIds = Set(lastMessages.map(\.id))
        let limit = Self.stagedMaterializationTailWindowCount(
            isShowingOnlyUserMessages: callbackSessionKey().map {
                readState(for: $0).isShowingOnlyUserMessages
            } ?? false
        )
        let eligibleItems = webBubbleCoordinator.items(
            for: stream,
            parentIds: parentIds,
            limit: limit
        )
        for item in eligibleItems {
            if let parentItemId = item.parentItemId,
               let parentIndex = merged.lastIndex(of: parentItemId)
            {
                merged.insert(item.id, at: parentIndex + 1)
            } else {
                merged.append(item.id)
            }
        }
        return merged
    }

    private func applySnapshotForWebBubbles() {
        guard !isUpdatePassInFlight, !isSnapshotApplyInFlight else {
            isWebBubbleSnapshotApplyQueued = true
            return
        }
        isWebBubbleSnapshotApplyQueued = false
        guard let viewModel,
              let effectiveSessionKey = callbackSessionKey(),
              let stream = lastEffectiveStream
        else {
            drainQueuedUpdateIfPossible()
            return
        }

        let isSearchActive = !streamSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let wasPinnedToBottomIntent = readState(for: effectiveSessionKey).sbbState.isPinnedToBottomIntent
        let searchScrollAnchor = isSearchActive && !wasPinnedToBottomIntent ? captureStreamSearchViewportAnchor() : nil
        var snapshot = dataSource.snapshot()
        guard !readState(for: effectiveSessionKey).isShowingOnlyUserMessages else {
            snapshot.deleteAllItems()
            snapshot.appendSections([0])
            snapshot.appendItems(lastMessages.map(\.id))
            if activeWindowReachesProjectionTail,
               SessionMetadataFooterCell.shouldAppendFooter(after: lastMessages.map(\.id), status: sessionStatus)
            {
                snapshot.appendItems([SessionMetadataFooterCell.itemId])
            }
            applyDiffableSnapshot(snapshot, animatingDifferences: false) { [weak self] in
                self?.updateVisibleFooterAlpha()
                self?.notifyTypingIndicatorAnchorFrameIfNeeded()
                if isSearchActive, wasPinnedToBottomIntent {
                    self?.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: false, attempts: 2)
                } else if isSearchActive {
                    self?.scheduleStreamSearchViewportAnchorRestoration(searchScrollAnchor)
                }
            }
            return
        }
        let snapshotMessages = lastMessages
        let desiredItemIds = snapshotItemsWithWebBubbles(
            from: snapshotItemsWithSubstrateRunCollapse(
                from: snapshotItemsWithSegmentAnchor(
                    from: snapshotItemsWithMarkerDivider(
                        from: snapshotItemsWithDateSeparators(from: snapshotMessages),
                        messages: snapshotMessages
                    )
                )
            ),
            stream: stream
        )
        snapshot.deleteAllItems()
        snapshot.appendSections([0])
        if viewModel.shouldShowPromptStageIndicator(in: effectiveSessionKey) {
            snapshot.appendItems(TranscriptTypingIndicatorOrdering.itemIds(
                messageItems: desiredItemIds,
                messages: snapshotMessages,
                typingIndicatorItemId: TypingIndicatorCell.itemId,
                activePromptMessageId: viewModel.promptStageIndicatorAnchorMessageId(in: effectiveSessionKey)
            ))
        } else {
            snapshot.appendItems(desiredItemIds)
        }
        if activeWindowReachesProjectionTail,
           SessionMetadataFooterCell.shouldAppendFooter(after: lastMessages.map(\.id), status: sessionStatus)
        {
            snapshot.appendItems([SessionMetadataFooterCell.itemId])
        }
        applyDiffableSnapshot(snapshot, animatingDifferences: false) { [weak self] in
            self?.updateVisibleFooterAlpha()
            self?.notifyTypingIndicatorAnchorFrameIfNeeded()
            if isSearchActive, wasPinnedToBottomIntent {
                self?.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: false, attempts: 2)
            } else if isSearchActive {
                self?.scheduleStreamSearchViewportAnchorRestoration(searchScrollAnchor)
            }
        }
    }

    private func applyMeasuredSize(_ measuredSize: CGSize, for messageId: String) {
        guard let viewModel, let message = messagesById[messageId] else {
            scheduleLayoutInvalidation()
            return
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let env = bubbleSizingV2Environment(metrics: metrics)
        let maxWidth: CGFloat
        let minWidth: CGFloat
        let bubbleHeightPolicy: BubbleSizingV2.BubbleHeightPolicy
        if bubbleSizingV2Enabled {
            let plan = bubbleSizingV2Plan(
                message: message,
                presentation: presentation,
                metrics: metrics,
                env: env,
                showsHeader: !shouldHideHeader(for: message, presentation: presentation)
            )
            maxWidth = plan.maxWidth
            minWidth = plan.minWidth
            bubbleHeightPolicy = plan.heightPolicy
        } else {
            maxWidth = maxItemWidth(
                for: sizeClass,
                message: message,
                presentation: presentation,
                metrics: metrics,
                containerWidth: effectiveContentWidth(metrics: metrics)
            )
            minWidth = 120
            bubbleHeightPolicy = bubbleHeightPolicyForPresentation(
                presentation: presentation,
                metrics: metrics,
                env: env,
                allowsOuterScroll: sizeClass == .long
            )
        }
        // #63: Non-short bubbles should never shrink below their size-class max width.
        // Live-cell remeasurement is only needed to correct heights (e.g. link preview WKWebView).
        // Allow .short to remain content-fit; enforce stable widths for .medium/.long.
        let enforcedWidth = Self.enforcedLiveMeasuredWidth(
            sizeClass: sizeClass,
            measuredWidth: measuredSize.width,
            maxWidth: maxWidth,
            minWidth: minWidth
        )
        let clamped = CGSize(
            // #63: Mirror the initial sizing path's width floor so a transient near-zero measurement
            // (e.g., from a 0pt-wide live cell) cannot permanently lock a bubble to an invalid width.
            width: enforcedWidth,
            height: measuredSize.height
        )
        var snapped = snapToPixel(clamped)
        if let cap = bubbleHeightPolicy.v1TruncationHeightOverride {
            // Cap height to the truncation max.
            snapped.height = min(snapped.height, cap)
        }
        let previous = readSizeState(messageId: messageId, env: env)?.size
        if let previous {
            let heightDelta = abs(previous.height - snapped.height)
            let widthDelta = abs(previous.width - snapped.width)
            guard heightDelta > 8 || widthDelta > 4 else { return }
        }
        if let delta = writeMeasuredSize(messageId: messageId, measurement: snapped) {
            executeInvalidationPlan(.remeasureAndShift([(id: messageId, delta: delta)]))
        } else {
            let viewportAnchor = captureBubbleSizingV2ViewportAnchor()
            scheduleLayoutInvalidation()
            scheduleBubbleSizingV2ViewportAnchorCompensation(viewportAnchor)
        }
        if messageId == lastMessageId, let sessionKey = callbackSessionKey() {
            if Self.shouldScheduleAutomatedBottomScroll(hasAuthoritativeRestoreTarget: hasAuthoritativePersistedRestoreTarget(sessionKey: sessionKey)) {
                scheduleScrollToBottom(sessionKey: sessionKey, animated: false, attempts: 1)
            } else {
                logScrollRestore("bubbleSizing.lastMessageScrollToBottom.disqualified sessionKey=\(sessionKey) reason=savedRestoreTargetIsAuthoritative")
            }
        }
    }

    private func snapToPixel(_ size: CGSize) -> CGSize {
        #if os(visionOS)
            let scale = view.traitCollection.displayScale
        #else
            let scale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        #endif
        func snap(_ value: CGFloat) -> CGFloat {
            ceil(value * scale) / scale
        }
        return CGSize(width: snap(size.width), height: snap(size.height))
    }

    private func scheduleLayoutInvalidation() {
        guard !invalidationScheduled else { return }
        invalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidationScheduled = false
            if self.hasDirtySizeIds() {
                let ids = self.consumePendingInvalidatedSizeIds()
                self.clearSizeState(for: ids)
            }
            self.flowLayout.invalidateLayout()
        }
    }

    func collectionView(_: UICollectionView,
                        layout _: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize
    {
        sizeForItem(at: indexPath)
    }
}

final class SessionMetadataFooterCell: UICollectionViewCell {
    static let reuseIdentifier = "SessionMetadataFooterCell"
    static let itemId = "__session_metadata_footer__"
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 4
    static let horizontalPadding: CGFloat = 12
    static let actionRegionHeight: CGFloat = 44
    static let versionRowHeight: CGFloat = 44
    static let searchRowHeight: CGFloat = 30
    static let footerRowSpacing: CGFloat = 4
    static let fadeRevealRange: CGFloat = topPadding + searchRowHeight + footerRowSpacing + actionRegionHeight + footerRowSpacing + versionRowHeight
    static let testMenuIconPointSize: CGFloat = 11

    private let stackView = UIStackView()
    private let controlsStackView = UIStackView()
    private let primaryControlsStackView = UIStackView()
    private let secondaryControlsStackView = UIStackView()
    private let versionStackView = UIStackView()
    private let searchField = FooterSearchField()
    private var primaryRowHeightConstraint: NSLayoutConstraint?
    private var secondaryRowHeightConstraint: NSLayoutConstraint?
    private var versionRowHeightConstraint: NSLayoutConstraint?
    private var contentSizeTraitObservation: UITraitChangeRegistration?
    private var currentFooterItems: [FooterItem] = []
    private var onSearchQueryChanged: (@MainActor (String) -> Void)?
    private var lastFooterConfiguration: FooterConfiguration?
    private var lastConfiguredWidth: CGFloat = .zero
    private var isReconfiguringForWidth = false

    private struct FooterConfiguration {
        let status: SessionStatus?
        let statusUnavailable: Bool
        let isDark: Bool
        let isSpatial: Bool
        let isTightbeam: Bool
        let harnessOptions: [String]
        let onSelect: (@MainActor (String, SessionControlAction, String?, Bool?) -> Void)?
        let onTestMenuSelect: (@MainActor (FooterTestMenuAction) -> Void)?
        let searchQuery: String
        let onSearchQueryChanged: (@MainActor (String) -> Void)?
    }

    private struct FooterItem {
        enum Row {
            case primary
            case secondary
        }

        let text: String
        let action: SessionControlAction?
        let options: [FooterOption]
        let unsupportedReason: String?
        let textColor: UIColor?
        let row: Row
        let accessibilityLabel: String?
        let isStaticLabel: Bool
        let allowsTruncation: Bool
        let allowsWrapping: Bool

        init(
            text: String,
            action: SessionControlAction?,
            options: [FooterOption],
            unsupportedReason: String?,
            textColor: UIColor?,
            row: Row = .primary,
            accessibilityLabel: String? = nil,
            isStaticLabel: Bool = false,
            allowsTruncation: Bool = false,
            allowsWrapping: Bool = false
        ) {
            self.text = text
            self.action = action
            self.options = options
            self.unsupportedReason = unsupportedReason
            self.textColor = textColor
            self.row = row
            self.accessibilityLabel = accessibilityLabel
            self.isStaticLabel = isStaticLabel
            self.allowsTruncation = allowsTruncation
            self.allowsWrapping = allowsWrapping
        }
    }

    private struct FooterOption {
        let title: String
        let value: String?
        let enabled: Bool?
        let isCurrent: Bool
    }

    private var footerFont: UIFont { UIFont.clawline(.timestamp, compatibleWith: traitCollection) }
    static func textAlpha(isDark: Bool) -> CGFloat {
        isDark ? 0.90 : 0.84
    }

    static func textColor(isDark: Bool, isSpatial: Bool) -> UIColor {
        if isSpatial {
            return .white
        }
        let palette = ChatFlowUIKitTheme.palette(isDark: isDark)
        return palette.textMuted.withAlphaComponent(Self.textAlpha(isDark: isDark))
    }

    private static var isSpatialPlatform: Bool {
#if os(visionOS)
        true
#else
        false
#endif
    }

    private final class FooterButton: UIButton {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard self.point(inside: point, with: event) else { return nil }
            return self
        }

        override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
            let minimumSide: CGFloat = 44
            let horizontalInset = max(0, (minimumSide - bounds.width) / 2)
            return bounds.insetBy(dx: -horizontalInset, dy: 0).contains(point)
        }
    }

    private final class TestMenuButton: UIButton {
        override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
            bounds.insetBy(dx: -10, dy: -10).contains(point)
        }
    }

    private final class FooterSearchField: UITextField {
        override func textRect(forBounds bounds: CGRect) -> CGRect {
            bounds.insetBy(dx: 8, dy: 0)
        }

        override func editingRect(forBounds bounds: CGRect) -> CGRect {
            textRect(forBounds: bounds)
        }

        override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
            textRect(forBounds: bounds)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.distribution = .fill
        stackView.spacing = Self.footerRowSpacing
        stackView.setContentHuggingPriority(.required, for: .horizontal)
        stackView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        contentView.addSubview(stackView)

        controlsStackView.axis = .vertical
        controlsStackView.alignment = .center
        controlsStackView.distribution = .fill
        controlsStackView.spacing = 0
        controlsStackView.setContentHuggingPriority(.required, for: .horizontal)
        controlsStackView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        for row in [primaryControlsStackView, secondaryControlsStackView] {
            row.axis = .horizontal
            row.alignment = .center
            row.distribution = .fill
            row.spacing = 2
            row.setContentHuggingPriority(.required, for: .horizontal)
            row.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            controlsStackView.addArrangedSubview(row)
        }

        versionStackView.axis = .horizontal
        versionStackView.alignment = .center
        versionStackView.distribution = .fill
        versionStackView.spacing = Self.footerRowSpacing
        versionStackView.setContentHuggingPriority(.required, for: .horizontal)
        versionStackView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        searchField.font = footerFont
        searchField.borderStyle = .none
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.textAlignment = .center
        searchField.accessibilityLabel = "Search current stream"
        searchField.addTarget(self, action: #selector(searchFieldDidChange), for: .editingChanged)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(controlsStackView)
        stackView.addArrangedSubview(versionStackView)

        let primaryRowHeightConstraint = primaryControlsStackView.heightAnchor.constraint(
            equalToConstant: Self.controlRowHeight(compatibleWith: traitCollection)
        )
        let secondaryRowHeightConstraint = secondaryControlsStackView.heightAnchor.constraint(
            equalToConstant: Self.controlRowHeight(compatibleWith: traitCollection)
        )
        secondaryRowHeightConstraint.priority = .defaultHigh
        self.primaryRowHeightConstraint = primaryRowHeightConstraint
        self.secondaryRowHeightConstraint = secondaryRowHeightConstraint

        let versionRowHeightConstraint = versionStackView.heightAnchor.constraint(
            equalToConstant: Self.versionRowHeight(compatibleWith: traitCollection)
        )
        self.versionRowHeightConstraint = versionRowHeightConstraint
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: Self.horizontalPadding),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Self.horizontalPadding),
            stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.topPadding),
            primaryRowHeightConstraint,
            secondaryRowHeightConstraint,
            versionRowHeightConstraint,
            searchField.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            searchField.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -(Self.horizontalPadding * 2)),
        ])

        contentSizeTraitObservation = registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: SessionMetadataFooterCell, _: UITraitCollection) in
            cell.updateFontsForPreferredContentSizeCategory()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateFontsForPreferredContentSizeCategory() {
        let font = footerFont
        searchField.font = font
        for view in [primaryControlsStackView, secondaryControlsStackView].flatMap(\.arrangedSubviews) {
            if let button = view as? UIButton {
                button.titleLabel?.font = font
            } else if let label = view as? UILabel {
                label.font = font
            }
        }
        for label in versionStackView.arrangedSubviews.compactMap({ $0 as? UILabel }) {
            label.font = font
        }
        primaryRowHeightConstraint?.constant = Self.controlRowHeight(compatibleWith: traitCollection)
        versionRowHeightConstraint?.constant = Self.versionRowHeight(compatibleWith: traitCollection)
        secondaryRowHeightConstraint?.constant = secondaryControlsStackView.isHidden
            ? Self.controlRowHeight(compatibleWith: traitCollection)
            : Self.secondaryControlRowHeight(
                items: currentFooterItems,
                availableWidth: bounds.width,
                font: font
            )
        var ancestor = superview
        while let view = ancestor {
            if let collectionView = view as? UICollectionView {
                collectionView.collectionViewLayout.invalidateLayout()
                break
            }
            ancestor = view.superview
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let actionButtons = [primaryControlsStackView, secondaryControlsStackView]
            .flatMap(\.arrangedSubviews)
            .compactMap { $0 as? FooterButton }
        if let button = FooterActionHitTesting.hitView(at: point, in: self, candidates: actionButtons, event: event) {
            return button
        }
        if let testMenuButton = versionStackView.arrangedSubviews.compactMap({ $0 as? TestMenuButton }).first,
           testMenuButton.point(inside: testMenuButton.convert(point, from: self), with: event) {
            return testMenuButton
        }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isReconfiguringForWidth,
              let configuration = lastFooterConfiguration,
              abs(bounds.width - lastConfiguredWidth) > 0.5
        else { return }
        isReconfiguringForWidth = true
        configure(
            status: configuration.status,
            statusUnavailable: configuration.statusUnavailable,
            isDark: configuration.isDark,
            isSpatial: configuration.isSpatial,
            isTightbeam: configuration.isTightbeam,
            harnessOptions: configuration.harnessOptions,
            onSelect: configuration.onSelect,
            onTestMenuSelect: configuration.onTestMenuSelect,
            searchQuery: configuration.searchQuery,
            onSearchQueryChanged: configuration.onSearchQueryChanged
        )
        isReconfiguringForWidth = false
    }

    func configure(
        status: SessionStatus?,
        statusUnavailable: Bool = false,
        isDark: Bool,
        isSpatial: Bool = SessionMetadataFooterCell.isSpatialPlatform,
        isTightbeam: Bool = false,
        harnessOptions: [String] = [],
        onSelect: (@MainActor (String, SessionControlAction, String?, Bool?) -> Void)?,
        onTestMenuSelect: (@MainActor (FooterTestMenuAction) -> Void)? = nil,
        searchQuery: String = "",
        onSearchQueryChanged: (@MainActor (String) -> Void)? = nil
    ) {
        lastFooterConfiguration = FooterConfiguration(
            status: status,
            statusUnavailable: statusUnavailable,
            isDark: isDark,
            isSpatial: isSpatial,
            isTightbeam: isTightbeam,
            harnessOptions: harnessOptions,
            onSelect: onSelect,
            onTestMenuSelect: onTestMenuSelect,
            searchQuery: searchQuery,
            onSearchQueryChanged: onSearchQueryChanged
        )
        lastConfiguredWidth = bounds.width
        let textColor = Self.textColor(isDark: isDark, isSpatial: isSpatial)
        self.onSearchQueryChanged = onSearchQueryChanged
        for row in [primaryControlsStackView, secondaryControlsStackView] {
            for view in row.arrangedSubviews {
                row.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
        for view in versionStackView.arrangedSubviews {
            versionStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let items = Self.footerItems(
            for: status,
            isUnavailable: statusUnavailable,
            isDark: isDark,
            isTightbeam: isTightbeam,
            harnessOptions: harnessOptions
        )
        currentFooterItems = items
        for item in items {
            let itemColor = isSpatial ? textColor : (item.textColor ?? textColor)
            let row = item.row == .secondary ? secondaryControlsStackView : primaryControlsStackView
            row.addArrangedSubview(
                footerView(for: item, status: status, color: itemColor, onSelect: onSelect)
            )
        }
        let hasSecondaryMetadata = items.contains { $0.row == .secondary }
        secondaryControlsStackView.isHidden = !hasSecondaryMetadata
        secondaryRowHeightConstraint?.constant = hasSecondaryMetadata
            ? Self.secondaryControlRowHeight(items: items, availableWidth: bounds.width, font: footerFont)
            : Self.controlRowHeight(compatibleWith: traitCollection)
        versionStackView.addArrangedSubview(versionLabel(color: textColor))
        versionStackView.addArrangedSubview(testMenuButton(color: textColor, onSelect: onTestMenuSelect))
        configureSearchField(query: searchQuery, textColor: textColor, isDark: isDark, isSpatial: isSpatial)
        isAccessibilityElement = false
        accessibilityLabel = nil
    }

    static func height(
        for status: SessionStatus?,
        width: CGFloat = .greatestFiniteMagnitude,
        compatibleWith traitCollection: UITraitCollection? = nil,
        isTightbeam: Bool = false,
        harnessOptions: [String] = []
    ) -> CGFloat {
        let items = footerItems(for: status, isTightbeam: isTightbeam, harnessOptions: harnessOptions)
        let font = UIFont.clawline(.timestamp, compatibleWith: traitCollection)
        let primaryHeight = controlRowHeight(compatibleWith: traitCollection)
        let secondaryHeight = items.contains { $0.row == .secondary }
            ? secondaryControlRowHeight(items: items, availableWidth: width, font: font)
            : 0
        return ceil(searchRowHeight + footerRowSpacing + primaryHeight + secondaryHeight + footerRowSpacing
            + versionRowHeight(compatibleWith: traitCollection) + topPadding + bottomPadding)
    }

    private static func controlRowHeight(compatibleWith traitCollection: UITraitCollection?) -> CGFloat {
        max(actionRegionHeight, ceil(UIFont.clawline(.timestamp, compatibleWith: traitCollection).lineHeight + 4))
    }

    private static func versionRowHeight(compatibleWith traitCollection: UITraitCollection?) -> CGFloat {
        max(versionRowHeight, ceil(UIFont.clawline(.timestamp, compatibleWith: traitCollection).lineHeight + 4))
    }

    private static func secondaryControlRowHeight(
        items: [FooterItem],
        availableWidth: CGFloat,
        font: UIFont
    ) -> CGFloat {
        let secondaryItems = items.filter { $0.row == .secondary }
        guard !secondaryItems.isEmpty else { return max(actionRegionHeight, ceil(font.lineHeight + 4)) }
        let contentWidth = max(0, availableWidth - (horizontalPadding * 2))
        let spacing = CGFloat(max(0, secondaryItems.count - 1)) * 2
        let allocatedWidth = max(44, (contentWidth - spacing) / CGFloat(secondaryItems.count))
        let maximumLineCount = secondaryItems.map { item in
            let titleWidth = ceil((item.text as NSString).size(withAttributes: [.font: font]).width) + 8
            return item.allowsWrapping ? max(1, ceil(titleWidth / allocatedWidth)) : 1
        }.max() ?? 1
        return max(actionRegionHeight, ceil((font.lineHeight * maximumLineCount) + 4))
    }

    static func shouldAppendFooter(after itemIds: [String], status: SessionStatus?) -> Bool {
        !itemIds.isEmpty
    }

    private func configureSearchField(query: String, textColor: UIColor, isDark: Bool, isSpatial: Bool) {
        if searchField.text != query {
            searchField.text = query
        }
        searchField.textColor = textColor
        searchField.tintColor = textColor
        let palette = ChatFlowUIKitTheme.palette(isDark: isDark)
        searchField.backgroundColor = isSpatial
            ? UIColor.white.withAlphaComponent(0.08)
            : palette.cream.withAlphaComponent(isDark ? 0.18 : 0.52)
        searchField.layer.cornerRadius = 8
        searchField.layer.borderWidth = 0.5
        searchField.layer.borderColor = textColor.withAlphaComponent(0.20).cgColor
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search current stream",
            attributes: [
                .font: footerFont,
                .foregroundColor: textColor.withAlphaComponent(0.58)
            ]
        )
    }

    @objc private func searchFieldDidChange() {
        let query = searchField.text ?? ""
        Task { @MainActor in
            onSearchQueryChanged?(query)
        }
    }

    static func footerText(
        for status: SessionStatus?,
        isUnavailable: Bool = false,
        isTightbeam: Bool = false,
        harnessOptions: [String] = []
    ) -> String? {
        let parts = footerItems(
            for: status,
            isUnavailable: isUnavailable,
            isTightbeam: isTightbeam,
            harnessOptions: harnessOptions
        ).map(\.text)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "  ·  ")
    }

    private static func footerItems(
        for status: SessionStatus?,
        isUnavailable: Bool = false,
        isDark: Bool = false,
        isTightbeam: Bool = false,
        harnessOptions: [String] = []
    ) -> [FooterItem] {
        guard let status else {
            if isUnavailable {
                return metadataPlaceholderFooterItems(state: "unavailable", reason: "session_status_unavailable")
            }
            return metadataPlaceholderFooterItems(state: "loading", reason: "session_status_loading")
        }
        let display = status.display
        let capabilities = status.capabilities
        let modelCapability = capability(
            capabilities.setModel,
            legacySupported: capabilities.canChangeModel == true
        )
        let thinkingValue = normalized(display.thinkingLevel)
        let reasoningValue = normalized(display.reasoningLevel)
        let levelControl = levelControlAction(
            capabilities: capabilities,
            hasThinkingValue: thinkingValue != nil,
            hasReasoningValue: reasoningValue != nil
        )
        let fastControl = fastModeControlAction(capabilities: capabilities)
        return [
            FooterItem(
                text: displayModelText(display: display, catalog: status.modelCatalog),
                action: modelCapability.isSupported ? .setModel : nil,
                options: modelOptions(display: display, catalog: status.modelCatalog),
                unsupportedReason: modelCapability.reason ?? "model_catalog_control_not_available",
                textColor: nil,
                allowsTruncation: true
            ),
            FooterItem(
                text: thinkingText(
                    thinkingValue: thinkingValue,
                    reasoningValue: reasoningValue,
                    action: levelControl.action,
                    unsupportedReason: levelControl.reason
                ),
                action: levelControl.action,
                options: levelOptions(
                    current: thinkingValue ?? reasoningValue,
                    action: levelControl.action,
                    providerOptions: levelControl.options
                ),
                unsupportedReason: levelControl.reason,
                textColor: nil
            ),
            FooterItem(
                text: fastModeText(display.fastMode, action: fastControl.action, unsupportedReason: fastControl.reason),
                action: fastControl.action,
                options: fastModeOptions(
                    current: display.fastMode,
                    action: fastControl.action,
                    providerOptions: fastControl.options
                ),
                unsupportedReason: fastControl.reason,
                textColor: nil
            )
        ] + authModeFooterItems(display.authMode, codexUsage: display.codexUsage, isDark: isDark)
            + harnessFooterItems(display.harness, isTightbeam: isTightbeam, options: harnessOptions)
            + hostFooterItems(display.host, isTightbeam: isTightbeam)
    }

    private static func harnessFooterItems(
        _ harness: String?,
        isTightbeam: Bool,
        options: [String]
    ) -> [FooterItem] {
        // Tightbeam-only. Absent harness renders nothing (openclaw payloads lack it).
        guard isTightbeam, let harness = normalized(harness) else { return [] }
        // Options come from GET /api/org-options → harnesses. Until they load the
        // item shows the current harness with no menu (disabled), then becomes a
        // picker once options arrive. Selecting the current harness is a no-op
        // resolved downstream; selecting a different one triggers the confirm.
        let footerOptions = options.compactMap { normalized($0) }.map { value in
            FooterOption(title: value, value: value, enabled: nil, isCurrent: value == harness)
        }
        return [
            FooterItem(
                text: harness,
                action: .setHarness,
                options: footerOptions,
                unsupportedReason: "harness_options_unavailable",
                textColor: nil,
                row: .secondary,
                accessibilityLabel: "Harness \(harness)",
                allowsWrapping: false
            )
        ]
    }

    private static func hostFooterItems(_ host: String?, isTightbeam: Bool) -> [FooterItem] {
        // Tightbeam-only. Absent/blank host renders nothing (openclaw payloads lack the key).
        guard isTightbeam, let host = normalized(host) else { return [] }
        // Display only. A future picker over the archetype's allowed hosts will replace this
        // rendering to drive session-control {action: "set_host"}; keep it isolated as that seam.
        return [
            FooterItem(
                text: host,
                action: nil,
                options: [],
                unsupportedReason: nil,
                textColor: nil,
                row: .secondary,
                accessibilityLabel: "Host \(host)",
                isStaticLabel: true,
                allowsWrapping: false
            )
        ]
    }

    private static func capability(_ capability: SessionStatus.Capability?,
                                   legacySupported: Bool) -> (
        isSupported: Bool,
        reason: String?,
        options: [SessionStatus.Capability.Option]?
    ) {
        if let capability {
            return (capability.supported, capability.reason, capability.options)
        }
        return (legacySupported, nil, nil)
    }

    private static func metadataPlaceholderFooterItems(state: String, reason: String) -> [FooterItem] {
        [
            FooterItem(
                text: "Model \(state)",
                action: nil,
                options: [],
                unsupportedReason: reason,
                textColor: nil
            ),
            FooterItem(
                text: "Thinking \(state)",
                action: nil,
                options: [],
                unsupportedReason: reason,
                textColor: nil
            ),
            FooterItem(
                text: "Fast \(state)",
                action: nil,
                options: [],
                unsupportedReason: reason,
                textColor: nil
            )
        ]
    }

    private func footerView(
        for item: FooterItem,
        status: SessionStatus?,
        color: UIColor,
        onSelect: (@MainActor (String, SessionControlAction, String?, Bool?) -> Void)?
    ) -> UIView {
        if item.isStaticLabel {
            let label = UILabel()
            label.text = item.text
            label.font = footerFont
            label.textColor = color
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = item.allowsWrapping ? 0 : 1
            label.lineBreakMode = item.allowsWrapping ? .byWordWrapping : .byClipping
            label.textAlignment = .center
            label.isAccessibilityElement = true
            label.accessibilityLabel = item.accessibilityLabel ?? item.text
            label.accessibilityTraits = .staticText
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(
                item.allowsTruncation || item.allowsWrapping ? .defaultLow : .defaultHigh,
                for: .horizontal
            )
            let titleWidth = ceil((item.text as NSString).size(withAttributes: [.font: footerFont]).width)
            label.widthAnchor.constraint(
                greaterThanOrEqualToConstant: item.allowsTruncation || item.allowsWrapping ? 44 : titleWidth
            ).isActive = true
            return label
        }

        let button = FooterButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
        configuration.attributedTitle = AttributedString(
            item.text,
            attributes: AttributeContainer([.font: footerFont])
        )
        configuration.baseForegroundColor = color
        configuration.background.strokeWidth = 0
        button.configuration = configuration
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(item.allowsTruncation ? .defaultLow : .defaultHigh, for: .horizontal)
        let titleWidth = ceil((item.text as NSString).size(withAttributes: [.font: footerFont]).width)
        button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: item.allowsTruncation ? 44 : max(44, titleWidth + 8)
        ).isActive = true
        button.titleLabel?.font = footerFont
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.tintColor = color
        button.isEnabled = item.action != nil && !item.options.isEmpty
        button.showsMenuAsPrimaryAction = button.isEnabled
        button.accessibilityLabel = item.accessibilityLabel ?? item.text
        if !button.isEnabled, let reason = item.unsupportedReason {
            button.accessibilityHint = reason
        }
        guard let sessionKey = status?.sessionKey, let action = item.action, button.isEnabled else {
            return button
        }
        button.menu = UIMenu(children: item.options.map { option in
            UIAction(
                title: option.title,
                image: option.isCurrent ? UIImage(systemName: "checkmark") : nil,
                discoverabilityTitle: option.isCurrent ? "\(option.title), Current" : option.title
            ) { _ in
                Task { @MainActor in
                    onSelect?(sessionKey, action, option.value, option.enabled)
                }
            }
        })
        return button
    }

    private func versionLabel(color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = Self.versionBuildText()
        label.font = footerFont
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .center
        label.isAccessibilityElement = true
        label.accessibilityLabel = label.text
        label.accessibilityTraits = .staticText
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return label
    }

    private func testMenuButton(
        color: UIColor,
        onSelect: (@MainActor (FooterTestMenuAction) -> Void)?
    ) -> UIButton {
        let button = TestMenuButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "gearshape")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: Self.testMenuIconPointSize,
            weight: .regular
        )
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        configuration.baseForegroundColor = color
        configuration.background.strokeWidth = 0
        button.configuration = configuration
        button.tintColor = color
        button.accessibilityLabel = "Settings"
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { _ in
                Task { @MainActor in
                    onSelect?(.settings)
                }
            },
            UIAction(title: "Logout", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { _ in
                Task { @MainActor in
                    onSelect?(.logout)
                }
            }
        ])
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    static func versionBuildText(bundle: Bundle = .main) -> String {
        let version = normalized(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        let build = normalized(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        return "Version \(version) (\(build))"
    }

    private static func modelOptions(display: SessionStatus.Display,
                                     catalog: SessionStatus.ModelCatalog?) -> [FooterOption]
    {
        let current = normalized(display.model)
        if catalog?.available == true {
            var optionsByRef: [String: FooterOption] = [:]
            var orderedRefs: [String] = []
            for model in catalog?.models ?? [] {
                let option = modelCatalogOption(model, current: current)
                let footerOption = FooterOption(title: option.title, value: model.ref, enabled: nil, isCurrent: option.isCurrent)
                let ref = normalized(model.ref) ?? option.title
                if optionsByRef[ref] == nil {
                    orderedRefs.append(ref)
                    optionsByRef[ref] = footerOption
                } else if option.isCurrent {
                    optionsByRef[ref] = footerOption
                }
            }
            let options = orderedRefs.compactMap { optionsByRef[$0] }
            guard let currentIndex = options.firstIndex(where: \.isCurrent) else { return options }
            return options.enumerated().map { index, option in
                FooterOption(
                    title: option.title,
                    value: option.value,
                    enabled: option.enabled,
                    isCurrent: index == currentIndex
                )
            }
        }
        let fallbackModels = ([current] + (display.fallbackModels ?? []).map { normalized($0) }).compactMap { $0 }
        let uniqueModels = Array(NSOrderedSet(array: fallbackModels)) as? [String] ?? fallbackModels
        return uniqueModels.map { model in
            FooterOption(title: model, value: model, enabled: nil, isCurrent: model == current)
        }
    }

    private static func displayModelText(display: SessionStatus.Display,
                                         catalog: SessionStatus.ModelCatalog?) -> String {
        let current = normalized(display.model)
        if catalog?.available == true,
           let match = catalog?.models.compactMap({ model -> String? in
               let option = modelCatalogOption(model, current: current)
               return option.isCurrent ? option.title : nil
           }).first {
            return match
        }
        return current ?? "Model unavailable"
    }

    private static func modelCatalogOption(_ model: SessionStatus.ModelCatalog.Model,
                                           current: String?) -> (title: String, isCurrent: Bool) {
        let title = normalized(model.name) ?? normalized(model.ref) ?? normalized(model.alias) ?? model.ref
        let isCurrent = current == normalized(model.id)
            || current == normalized(model.ref)
            || current == title
        return (title, isCurrent)
    }

    private static func providerFooterOptions(
        _ options: [SessionStatus.Capability.Option]?
    ) -> [FooterOption]? {
        guard let options, !options.isEmpty else { return nil }
        return options.compactMap { option in
            let title = normalized(option.title)
                ?? normalized(option.value)
                ?? (option.enabled == true ? "On" : option.enabled == false ? "Off" : nil)
            guard let title else { return nil }
            return FooterOption(title: title, value: normalized(option.value), enabled: option.enabled, isCurrent: false)
        }
    }

    private static func levelOptions(
        current: String?,
        action: SessionControlAction?,
        providerOptions: [SessionStatus.Capability.Option]?
    ) -> [FooterOption] {
        if let options = providerFooterOptions(providerOptions) {
            return options.map { option in
                FooterOption(
                    title: option.title,
                    value: option.value,
                    enabled: option.enabled,
                    isCurrent: option.value == current
                )
            }
        }
        let levels: [String]
        switch action {
        case .setThinking:
            levels = ["off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max"]
        case .setReasoning:
            levels = ["off", "on", "stream"]
        default:
            return []
        }
        return levels.map { level in
            FooterOption(
                title: level,
                value: level,
                enabled: nil,
                isCurrent: level == current
            )
        }
    }

    private static func fastModeOptions(
        current: Bool?,
        action: SessionControlAction?,
        providerOptions: [SessionStatus.Capability.Option]?
    ) -> [FooterOption] {
        if let options = providerFooterOptions(providerOptions) {
            return options.map { option in
                let optionCurrent: Bool
                if let enabled = option.enabled {
                    optionCurrent = enabled == current
                } else {
                    optionCurrent = option.value == (current == true ? "fast" : current == false ? "normal" : nil)
                }
                return FooterOption(
                    title: option.title,
                    value: option.value,
                    enabled: option.enabled,
                    isCurrent: optionCurrent
                )
            }
        }
        guard action != .setMode else {
            return [
                FooterOption(title: "On", value: "fast", enabled: nil, isCurrent: current == true),
                FooterOption(title: "Off", value: "normal", enabled: nil, isCurrent: current == false),
            ]
        }
        return [
            FooterOption(title: "On", value: nil, enabled: true, isCurrent: current == true),
            FooterOption(title: "Off", value: nil, enabled: false, isCurrent: current == false),
        ]
    }

    private static func levelControlAction(
        capabilities: SessionStatus.Capabilities,
        hasThinkingValue: Bool,
        hasReasoningValue: Bool
    ) -> (action: SessionControlAction?, reason: String?, options: [SessionStatus.Capability.Option]?) {
        let thinkingCapability = capability(capabilities.setThinking, legacySupported: false)
        let reasoningCapability = capability(
            capabilities.setReasoning,
            legacySupported: capabilities.canChangeReasoning == true
        )
        if hasThinkingValue, thinkingCapability.isSupported {
            return (.setThinking, nil, thinkingCapability.options)
        }
        if hasReasoningValue, reasoningCapability.isSupported {
            return (.setReasoning, nil, reasoningCapability.options)
        }
        if thinkingCapability.isSupported {
            return (.setThinking, nil, thinkingCapability.options)
        }
        if reasoningCapability.isSupported {
            return (.setReasoning, nil, reasoningCapability.options)
        }
        return (nil, thinkingCapability.reason ?? reasoningCapability.reason, nil)
    }

    private static func fastModeControlAction(
        capabilities: SessionStatus.Capabilities
    ) -> (action: SessionControlAction?, reason: String?, options: [SessionStatus.Capability.Option]?) {
        let fastModeCapability = capability(
            capabilities.setFastMode,
            legacySupported: capabilities.canChangeFastMode == true
        )
        let modeCapability = capability(capabilities.setMode, legacySupported: false)
        if fastModeCapability.isSupported {
            return (.setFastMode, nil, fastModeCapability.options)
        }
        if modeCapability.isSupported {
            return (.setMode, nil, modeCapability.options)
        }
        return (nil, fastModeCapability.reason ?? modeCapability.reason, nil)
    }

    private static func thinkingText(thinkingValue: String?,
                                     reasoningValue: String?,
                                     action: SessionControlAction?,
                                     unsupportedReason: String?) -> String {
        if action == nil, thinkingValue == nil, reasoningValue == nil, unsupportedReason != nil {
            return "Thinking unavailable"
        }
        return "Thinking \(thinkingValue ?? reasoningValue ?? "Unknown")"
    }

    private static func fastModeText(_ fastMode: Bool?,
                                     action: SessionControlAction?,
                                     unsupportedReason: String?) -> String {
        if action == nil, fastMode == nil, unsupportedReason != nil {
            return "Fast unavailable"
        }
        guard let fastMode else { return "Fast Unknown" }
        return fastMode ? "Fast on" : "Fast off"
    }

    private static func authModeFooterItems(
        _ authMode: String?,
        codexUsage: SessionStatus.Display.CodexUsage?,
        isDark: Bool
    ) -> [FooterItem] {
        switch authMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "oauth":
            return [
                FooterItem(
                    text: "OAUTH",
                    action: nil,
                    options: [FooterOption(title: "OAUTH", value: nil, enabled: nil, isCurrent: true)],
                    unsupportedReason: nil,
                    textColor: ChatFlowUIKitTheme.palette(isDark: isDark).sage,
                    row: .secondary,
                    isStaticLabel: true,
                    allowsWrapping: false
                )
            ] + codexUsageFooterItems(codexUsage)
        case "api_key", "api-key":
            return [
                FooterItem(
                    text: "API KEY",
                    action: nil,
                    options: [FooterOption(title: "API KEY", value: nil, enabled: nil, isCurrent: true)],
                    unsupportedReason: nil,
                    textColor: ChatFlowUIKitTheme.connectionReconnecting(isDark: isDark),
                    row: .secondary,
                    isStaticLabel: true,
                    allowsWrapping: false
                )
            ]
        default:
            return []
        }
    }

    private static func codexUsageFooterItems(_ usage: SessionStatus.Display.CodexUsage?) -> [FooterItem] {
        guard let usage else { return [] }
        switch usage.freshness {
        case .fresh, .stale:
            let windows = usage.windows.map { window in
                FooterItem(
                    text: "\(window.label.rawValue) \(window.remainingPercent)%",
                    action: nil,
                    options: [],
                    unsupportedReason: nil,
                    textColor: nil,
                    row: .secondary,
                    accessibilityLabel: usageAccessibilityLabel(for: window),
                    isStaticLabel: true,
                    allowsWrapping: true
                )
            }
            guard usage.freshness == .stale else { return windows }
            return windows + [
                FooterItem(
                    text: "Stale",
                    action: nil,
                    options: [],
                    unsupportedReason: nil,
                    textColor: nil,
                    row: .secondary,
                    accessibilityLabel: staleAccessibilityLabel(fetchedAt: usage.fetchedAt),
                    isStaticLabel: true,
                    allowsWrapping: true
                )
            ]
        case .loading:
            return [usageStateFooterItem(text: "Usage loading")]
        case .unavailable:
            return [usageStateFooterItem(text: "Usage unavailable")]
        }
    }

    private static func usageStateFooterItem(text: String) -> FooterItem {
        FooterItem(
            text: text,
            action: nil,
            options: [],
            unsupportedReason: nil,
            textColor: nil,
            row: .secondary,
            isStaticLabel: true,
            allowsWrapping: true
        )
    }

    private static func usageAccessibilityLabel(for window: SessionStatus.Display.CodexUsage.Window) -> String {
        let name = window.label == .fiveHour ? "5 hour" : "Weekly"
        var label = "\(name) Codex usage, \(window.remainingPercent) percent remaining"
        if let resetAt = window.resetAt {
            let resetDate = Date(timeIntervalSince1970: resetAt / 1_000)
            label += ", resets \(DateFormatter.localizedString(from: resetDate, dateStyle: .medium, timeStyle: .short))"
        }
        return label
    }

    private static func staleAccessibilityLabel(fetchedAt: TimeInterval?) -> String {
        guard let fetchedAt else { return "Codex usage stale" }
        let fetchedDate = Date(timeIntervalSince1970: fetchedAt / 1_000)
        return "Codex usage stale, last updated \(DateFormatter.localizedString(from: fetchedDate, dateStyle: .medium, timeStyle: .short))"
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if os(visionOS)
final class SpatialGazeScrollHitSurfaceView: UIView {
    static let surfaceAlpha: CGFloat = 0.001

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(Self.surfaceAlpha)
        isOpaque = false
        isUserInteractionEnabled = true
        accessibilityElementsHidden = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif

enum FooterActionHitTesting {
    @MainActor
    static func hitView(
        at point: CGPoint,
        in container: UIView,
        candidates: [UIView],
        event: UIEvent?
    ) -> UIView? {
        let eligibleCandidates = candidates.filter { candidate in
            guard !candidate.isHidden,
                  candidate.isUserInteractionEnabled,
                  candidate.alpha > 0.01
            else { return false }
            if let control = candidate as? UIControl, !control.isEnabled {
                return false
            }
            return true
        }
        for candidate in eligibleCandidates.reversed() {
            let pointInCandidate = container.convert(point, to: candidate)
            if candidate.point(inside: pointInCandidate, with: event) {
                return candidate
            }
        }

        let orderedRegions = actionRegions(for: eligibleCandidates, in: container)
        return orderedRegions.first { region in
            region.rect.contains(point)
        }?.view
    }

    @MainActor
    static func actionRegions(for candidates: [UIView], in container: UIView) -> [(view: UIView, rect: CGRect)] {
        let ordered = candidates
            .filter { candidate in
                guard !candidate.isHidden,
                      candidate.isUserInteractionEnabled,
                      candidate.alpha > 0.01
                else { return false }
                if let control = candidate as? UIControl, !control.isEnabled {
                    return false
                }
                return true
            }
            .map { candidate in
                (view: candidate, frame: candidate.convert(candidate.bounds, to: container))
            }
            .sorted { $0.frame.midX < $1.frame.midX }
        guard !ordered.isEmpty else { return [] }

        return ordered.enumerated().map { index, entry in
            let previousFrame = index > 0 ? ordered[index - 1].frame : nil
            let nextFrame = index < ordered.count - 1 ? ordered[index + 1].frame : nil
            let horizontalPadding = max(0, (44 - entry.frame.width) / 2)
            let minX = previousFrame.map { ($0.midX + entry.frame.midX) / 2 }
                ?? max(container.bounds.minX, entry.frame.minX - horizontalPadding)
            let maxX = nextFrame.map { (entry.frame.midX + $0.midX) / 2 }
                ?? min(container.bounds.maxX, entry.frame.maxX + horizontalPadding)
            return (
                view: entry.view,
                rect: CGRect(
                    x: minX,
                    y: entry.frame.minY,
                    width: max(0, maxX - minX),
                    height: entry.frame.height
                )
            )
        }
    }
}

struct MessageFlowRowLayoutEngine {
    struct Item: Equatable {
        var index: Int
        var size: CGSize
    }

    struct LaidOutItem: Equatable {
        var index: Int
        var frame: CGRect
    }

    struct Result: Equatable {
        var items: [LaidOutItem]
        var contentSize: CGSize
    }

    static func layout(
        items: [Item],
        contentWidth: CGFloat,
        sectionInset: UIEdgeInsets,
        minimumInteritemSpacing: CGFloat,
        rowSpacing: (_ previousItem: Int, _ nextItem: Int) -> CGFloat
    ) -> Result {
        guard !items.isEmpty, contentWidth > 0 else {
            return Result(items: [], contentSize: .zero)
        }

        let maxX = contentWidth - sectionInset.right
        var laidOutItems: [LaidOutItem] = []
        laidOutItems.reserveCapacity(items.count)
        var x = sectionInset.left
        var y = sectionInset.top
        var rowHeight: CGFloat = 0
        var pendingRowSpacingAfterItem: Int?
        var currentRowLastItem: Int?

        for item in items {
            let fullRowItem = isFullRowItem(
                width: item.size.width,
                contentWidth: contentWidth,
                sectionInset: sectionInset
            )

            if let previousItem = pendingRowSpacingAfterItem {
                y += rowSpacing(previousItem, item.index)
                pendingRowSpacingAfterItem = nil
            }

            if fullRowItem, x > sectionInset.left {
                x = sectionInset.left
                y += rowHeight + rowSpacing(currentRowLastItem ?? max(0, item.index - 1), item.index)
                rowHeight = 0
                currentRowLastItem = nil
            }

            if !fullRowItem, x + item.size.width > maxX, x > sectionInset.left {
                x = sectionInset.left
                y += rowHeight + rowSpacing(currentRowLastItem ?? max(0, item.index - 1), item.index)
                rowHeight = 0
                currentRowLastItem = nil
            }

            let frame = CGRect(x: x, y: y, width: item.size.width, height: item.size.height)
            laidOutItems.append(LaidOutItem(index: item.index, frame: frame))

            if fullRowItem {
                x = sectionInset.left
                y = frame.maxY
                rowHeight = 0
                pendingRowSpacingAfterItem = item.index
                currentRowLastItem = nil
            } else {
                x += item.size.width + minimumInteritemSpacing
                rowHeight = max(rowHeight, item.size.height)
                currentRowLastItem = item.index
            }
        }

        return Result(
            items: laidOutItems,
            contentSize: CGSize(width: contentWidth, height: y + rowHeight + sectionInset.bottom)
        )
    }

    static func applyItemHeightChange(
        frames: [Int: CGRect],
        contentHeight: CGFloat,
        index: Int,
        delta: CGFloat
    ) -> (frames: [Int: CGRect], contentHeight: CGFloat)? {
        guard abs(delta) > 0.5 else {
            return (frames, contentHeight)
        }
        guard let oldFrame = frames[index] else { return nil }

        let rowMinY = oldFrame.minY
        let rowFrames = frames.values.filter { abs($0.minY - rowMinY) <= 0.5 }
        let oldRowHeight = rowFrames.map(\.height).max() ?? oldFrame.height
        let newHeight = max(1, oldFrame.height + delta)
        var updatedFrames = frames
        updatedFrames[index] = CGRect(x: oldFrame.minX, y: oldFrame.minY, width: oldFrame.width, height: newHeight)
        let newRowHeight = updatedFrames.values
            .filter { abs($0.minY - rowMinY) <= 0.5 }
            .map(\.height)
            .max() ?? newHeight
        let rowDelta = newRowHeight - oldRowHeight
        guard abs(rowDelta) > 0.5 else {
            return (updatedFrames, contentHeight)
        }

        for (itemIndex, frame) in updatedFrames where itemIndex != index && frame.minY > rowMinY + 0.5 {
            updatedFrames[itemIndex] = CGRect(
                x: frame.minX,
                y: frame.minY + rowDelta,
                width: frame.width,
                height: frame.height
            )
        }
        return (updatedFrames, contentHeight + rowDelta)
    }

    static func isFullRowItem(width: CGFloat, contentWidth: CGFloat, sectionInset: UIEdgeInsets) -> Bool {
        let availableRowWidth = max(0, contentWidth - sectionInset.left - sectionInset.right)
        return width >= availableRowWidth - 0.5
    }
}

private final class MessageFlowLayout: UICollectionViewFlowLayout {
    var rowSpacingProvider: ((Int, Int) -> CGFloat)?
    var rowSpacingFingerprintProvider: (() -> Int)?

    enum InvalidationMode {
        case fullRebuild
        case itemHeightChange(index: Int, delta: CGFloat)
    }

    private enum PendingInvalidation: Equatable {
        case none
        case fullRebuild
        case itemHeightChange(index: Int, delta: CGFloat)
    }

    private var cachedAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var cachedContentSize: CGSize = .zero
    private var needsRebuild = true
    private var cachedLayoutSignature: LayoutSignature?
    private var pendingInvalidation: PendingInvalidation = .fullRebuild
#if DEBUG
    private(set) var lastPrepareSizeQueryCount = 0
#endif

    private struct LayoutSignature: Equatable {
        let itemCount: Int
        let contentWidth: CGFloat
        let sectionInset: UIEdgeInsets
        let minimumInteritemSpacing: CGFloat
        let minimumLineSpacing: CGFloat
        let rowSpacingFingerprint: Int
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let sessionKey = collectionView.accessibilityIdentifier
        StreamSwitchTiming.log("layout_prepare_start", sessionKey: sessionKey)

        let sectionCount = collectionView.dataSource?.numberOfSections?(in: collectionView) ?? 1
        guard sectionCount > 0 else {
            // During diffable datasource transitions, UIKit may trigger layout before section 0 exists.
            // Treat this as an empty transient state and rebuild on the next prepare pass.
            cachedAttributes.removeAll(keepingCapacity: true)
            cachedContentSize = .zero
            cachedLayoutSignature = nil
            needsRebuild = true
            pendingInvalidation = .fullRebuild
            StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
            return
        }

        // Ask the data source for item count instead of UICollectionView. During diffable updates,
        // Vision Pro can drive prepare() while the collection view temporarily reports zero sections.
        let itemCount = collectionView.dataSource?.collectionView(collectionView, numberOfItemsInSection: 0) ?? 0
        let contentWidth = collectionView.bounds.width
        let signature = LayoutSignature(
            itemCount: itemCount,
            contentWidth: contentWidth,
            sectionInset: sectionInset,
            minimumInteritemSpacing: minimumInteritemSpacing,
            minimumLineSpacing: minimumLineSpacing,
            rowSpacingFingerprint: rowSpacingFingerprintProvider?() ?? 0
        )
        if case let .itemHeightChange(index, delta) = pendingInvalidation,
           !needsRebuild,
           cachedLayoutSignature == signature,
           applyItemHeightChange(index: index, delta: delta)
        {
            pendingInvalidation = .none
            cachedLayoutSignature = signature
            StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
            return
        }

        if !needsRebuild,
           let previous = cachedLayoutSignature,
           canAppendIncrementally(from: previous, to: signature),
           appendLastItem(collectionView: collectionView, signature: signature)
        {
            pendingInvalidation = .none
            cachedLayoutSignature = signature
            StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
            return
        }

        if !needsRebuild, cachedLayoutSignature == signature {
            pendingInvalidation = .none
            StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
            return
        }

        cachedAttributes.removeAll(keepingCapacity: true)
#if DEBUG
        lastPrepareSizeQueryCount = 0
#endif
        guard itemCount > 0, contentWidth > 0 else {
            cachedContentSize = .zero
            cachedLayoutSignature = signature
            needsRebuild = false
            StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
            return
        }

        var layoutItems: [MessageFlowRowLayoutEngine.Item] = []
        layoutItems.reserveCapacity(itemCount)
        for item in 0 ..< itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let size = (collectionView.delegate as? UICollectionViewDelegateFlowLayout)?
                .collectionView?(collectionView, layout: self, sizeForItemAt: indexPath) ?? itemSize
#if DEBUG
            lastPrepareSizeQueryCount += 1
#endif
            layoutItems.append(MessageFlowRowLayoutEngine.Item(index: item, size: size))
        }

        let layoutResult = MessageFlowRowLayoutEngine.layout(
            items: layoutItems,
            contentWidth: contentWidth,
            sectionInset: sectionInset,
            minimumInteritemSpacing: minimumInteritemSpacing,
            rowSpacing: { [weak self] previousItem, nextItem in
                self?.rowSpacing(afterItem: previousItem, beforeItem: nextItem) ?? self?.minimumLineSpacing ?? 0
            }
        )

        for laidOutItem in layoutResult.items {
            let indexPath = IndexPath(item: laidOutItem.index, section: 0)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = laidOutItem.frame
            cachedAttributes[indexPath] = attributes
        }

        cachedContentSize = layoutResult.contentSize
        cachedLayoutSignature = signature
        needsRebuild = false
        pendingInvalidation = .none
        StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
    }

    private func rowSpacing(afterItem previousItem: Int, beforeItem nextItem: Int) -> CGFloat {
        rowSpacingProvider?(previousItem, nextItem) ?? minimumLineSpacing
    }

    private func canAppendIncrementally(from previous: LayoutSignature, to current: LayoutSignature) -> Bool {
        guard current.itemCount == previous.itemCount + 1 else { return false }
        guard current.contentWidth == previous.contentWidth else { return false }
        guard current.sectionInset == previous.sectionInset else { return false }
        guard current.minimumInteritemSpacing == previous.minimumInteritemSpacing else { return false }
        guard current.minimumLineSpacing == previous.minimumLineSpacing else { return false }
        guard pendingInvalidation == .none else { return false }
        return !cachedAttributes.isEmpty
    }

    private func appendLastItem(collectionView: UICollectionView, signature: LayoutSignature) -> Bool {
        let newItemIndex = signature.itemCount - 1
        guard newItemIndex > 0 else { return false }
        let previousIndexPath = IndexPath(item: newItemIndex - 1, section: 0)
        guard let previousAttributes = cachedAttributes[previousIndexPath] else { return false }

        let newIndexPath = IndexPath(item: newItemIndex, section: 0)
        let size = (collectionView.delegate as? UICollectionViewDelegateFlowLayout)?
            .collectionView?(collectionView, layout: self, sizeForItemAt: newIndexPath) ?? itemSize
        if MessageFlowRowLayoutEngine.isFullRowItem(width: size.width, contentWidth: signature.contentWidth, sectionInset: sectionInset) ||
            MessageFlowRowLayoutEngine.isFullRowItem(width: previousAttributes.frame.width, contentWidth: signature.contentWidth, sectionInset: sectionInset) {
            return false
        }
        let maxX = signature.contentWidth - sectionInset.right
        let rowMinY = previousAttributes.frame.minY
        let rowHeight = cachedAttributes.values
            .filter { abs($0.frame.minY - rowMinY) <= 0.5 }
            .map { $0.frame.height }
            .max() ?? previousAttributes.frame.height

        var x = previousAttributes.frame.maxX + minimumInteritemSpacing
        var y = rowMinY
        var currentRowHeight = rowHeight
        if x + size.width > maxX, x > sectionInset.left {
            x = sectionInset.left
            y = rowMinY + rowHeight + rowSpacing(afterItem: previousIndexPath.item, beforeItem: newItemIndex)
            currentRowHeight = 0
        }

        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: newIndexPath)
        attributes.frame = frame
        cachedAttributes[newIndexPath] = attributes

        currentRowHeight = max(currentRowHeight, size.height)
        cachedContentSize = CGSize(
            width: signature.contentWidth,
            height: y + currentRowHeight + sectionInset.bottom
        )
        return true
    }

    private func applyItemHeightChange(index: Int, delta: CGFloat) -> Bool {
        let framesByItem = Dictionary(uniqueKeysWithValues: cachedAttributes.map { ($0.key.item, $0.value.frame) })
        guard let update = MessageFlowRowLayoutEngine.applyItemHeightChange(
            frames: framesByItem,
            contentHeight: cachedContentSize.height,
            index: index,
            delta: delta
        ) else { return false }
        for (item, frame) in update.frames {
            cachedAttributes[IndexPath(item: item, section: 0)]?.frame = frame
        }
        cachedContentSize.height = update.contentHeight
        return true
    }

    override var collectionViewContentSize: CGSize {
        cachedContentSize
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.values.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    func invalidateLayout(mode: InvalidationMode) {
        switch mode {
        case .fullRebuild:
            pendingInvalidation = .fullRebuild
            needsRebuild = true
            super.invalidateLayout()
        case let .itemHeightChange(index, delta):
            pendingInvalidation = .itemHeightChange(index: index, delta: delta)
            super.invalidateLayout()
        }
    }

    override func invalidateLayout() {
        invalidateLayout(mode: .fullRebuild)
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        pendingInvalidation = .fullRebuild
        needsRebuild = true
        super.invalidateLayout(with: context)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        let shouldInvalidate = newBounds.size != collectionView?.bounds.size
        if shouldInvalidate {
            needsRebuild = true
        }
        return shouldInvalidate
    }
}
