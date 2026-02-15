//
//  MessageFlowCollectionView.swift
//  Clawline
//
//  Created by Codex on 1/18/26.
//

import OSLog
import QuartzCore
import SwiftUI
import UIKit

enum MessageFlowScrollEvent: Equatable {
    case isAtBottomChanged(sessionKey: String, isAtBottom: Bool)
    case didReceiveNewMessagesWhileScrolledUp(sessionKey: String, newMessageIDs: [String])
    case didCrossFirstUnreadCenter(sessionKey: String, messageId: String)
    case didInvalidateFirstUnreadAnchor(sessionKey: String)
}

@MainActor
struct MessageFlowCollectionView: UIViewControllerRepresentable {
    var viewModel: ChatViewModel
    var topInset: CGFloat
    var isCompact: Bool
    var isActiveSession: Bool
    var truncationBottomInset: CGFloat
    var firstUnreadMessageId: String?
    var unreadCount: Int
    var onExpand: ((Message) -> Void)?
    var layoutCoordinator: ChatLayoutCoordinator
    /// Optional session override - if provided, shows messages for this session instead of activeSessionKey
    var sessionKey: String?
    var onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsManager) private var settings

    func makeUIViewController(context: Context) -> MessageFlowCollectionViewController {
        let controller = MessageFlowCollectionViewController()
        controller.loadViewIfNeeded()
#if os(visionOS)
        let isDark = settings.appearanceMode == .dark
#else
        let isDark = colorScheme == .dark
#endif
        controller.update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            sessionKey: sessionKey,
            onScrollEvent: onScrollEvent,
            isDark: isDark
        )
        if let sessionKey {
            layoutCoordinator.registerListView(controller, sessionKey: sessionKey)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MessageFlowCollectionViewController, context: Context) {
#if os(visionOS)
        let isDark = settings.appearanceMode == .dark
#else
        let isDark = colorScheme == .dark
#endif
        uiViewController.update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            sessionKey: sessionKey,
            onScrollEvent: onScrollEvent,
            isDark: isDark
        )
        if let sessionKey {
            layoutCoordinator.registerListView(uiViewController, sessionKey: sessionKey)
        }
    }
}

final class MessageFlowCollectionViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    private var collectionView: UICollectionView!
    private var channelOverride: String?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var flowLayout: MessageFlowLayout!
    private let uiKitBubbleSizer = MessageBubbleUIKitView()
    private var currentIsDark: Bool = false
    private let bubbleSizingV2Enabled = BubbleSizingV2.isEnabled
    private let bubbleSizingV2MeasurementCache = BubbleSizingV2.LRUCache<BubbleSizingV2.CacheKey, BubbleSizingV2.Measurement>(maxEntries: 800)
    private let bubbleSizingV2LinkPreviewHeightCache = BubbleSizingV2.LinkPreviewHeightCache()
    private var bubbleSizingV2KeysByMessageId: [String: Set<BubbleSizingV2.CacheKey>] = [:]
    private var bubbleSizingV2LinkPreviewStateVersionByMessageId: [String: Int] = [:]
    private var bubbleSizingV2PendingRemeasureIds: Set<String> = []
    private var bubbleSizingV2RemeasureDebounceTimer: Timer?
    private var bubbleSizingV2RemeasureBatchStartTime: CFAbsoluteTime?
    private var bubbleSizingV2RemeasureDeferredUntilNearBottom: Bool = false
    private static let bubbleSizingV2RemeasureDebounceSeconds: TimeInterval = 0.45
    private static let bubbleSizingV2RemeasureMaxWaitSeconds: TimeInterval = 2.5

    private var messagesById: [String: Message] = [:]
    private var fingerprints: [String: Int] = [:]
    private var lastMeasuredSizes: [String: CGSize] = [:]
    private var sizeCache: [String: CGSize] = [:]
    private var pendingReconfigureIds: Set<String> = []
    private var dirtySizeIds: Set<String> = []
    private var invalidationScheduled = false
    private var lastMessageId: String?
    private var viewModel: ChatViewModel?
    private var isCompact: Bool = true
    private var isActiveSession: Bool = true
    private var topInset: CGFloat = 0
    private var truncationBottomInset: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var forceReconfigureAll = false
    private var wasShowingTypingIndicator = false
    private var onExpand: ((Message) -> Void)?
    private var onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)?
    private var firstUnreadMessageId: String?
    private var unreadCount: Int = 0
    private var firstUnreadWasBelowViewportCenter: Bool?
    private var didCrossAndClearFirstUnreadId: String?
    private var pendingFlashMessageId: String?
    private var pendingFlashIsUnreadTap: Bool = false
    private var pendingEntranceAnimationIds: Set<String> = []
    private var pendingScrollToBottomAfterInteractionEnd: Bool = false
    // Typing indicator morph is a bespoke overlay animation. During the morph we must prevent
    // normal lifecycle behaviors from fighting it:
    // - `willDisplay` resets (alpha/transform) can overwrite our fade-in target cell state.
    // - auto scroll-to-bottom can start a concurrent scroll animation and re-layout mid-morph.
    private var morphTargetMessageId: String?
    private var deferScrollToBottomUntilMorphCompletes = false

    // T036: Persist and restore scroll position per session key so app relaunch resumes where the user left off.
    // We store distance-from-bottom so async remeasures or new message insertions don't invalidate the anchor.
    private struct PersistedScrollState: Codable, Equatable {
        var atBottom: Bool
        var distanceFromBottom: Double
        var savedAtEpochSeconds: Double
    }

    private var scrollPersistenceKey: String?
    private var pendingScrollRestoreState: PersistedScrollState?
    private var restoredScrollKeys: Set<String> = []
    private var scrollStateWriteDebounceTimer: Timer?
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

    private var sbbState: SBBState = .atBottom
    private var lastReportedHideIndicator: Bool?
    private var lastSeenBottomInsetForSBB: CGFloat?
    private var isPostingSalientScrolling: Bool = false

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        configureCollectionView()
        configureDataSource()

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
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let t0 = CFAbsoluteTimeGetCurrent()

        // iOS: Extend the collection view to fill the entire screen, ignoring safe areas.
        // SwiftUI's UIViewControllerRepresentable doesn't respect .ignoresSafeArea() for UIKit views,
        // so we manually extend the collection view to window bounds.
        //
        // visionOS: In a spatial window this "counter-positioning" can create a layout feedback loop
        // (window position/size <-> view origin <-> collectionView frame), visible as the chat list
        // flapping vertically when content reaches the bottom. Use the normal view bounds instead.
#if os(visionOS)
        collectionView.frame = view.bounds
#else
        if let window = view.window {
            let windowBounds = window.bounds
            let viewOriginInWindow = view.convert(CGPoint.zero, to: window)

            // Calculate frame that extends from top of screen to bottom
            let extendedFrame = CGRect(
                x: 0,
                y: -viewOriginInWindow.y,
                width: windowBounds.width,
                height: windowBounds.height
            )

            // Only update if significantly different to avoid layout loops
            if abs(collectionView.frame.minY - extendedFrame.minY) > 1 ||
               abs(collectionView.frame.height - extendedFrame.height) > 1 {
                collectionView.frame = extendedFrame
            }
        }
#endif

        // Handle bounds size changes
        let size = collectionView.bounds.size
        guard size != .zero, size != lastBoundsSize else {
            NSLog("[KBTIMING] viewDidLayoutSubviews noChange dt=%.4f", CFAbsoluteTimeGetCurrent() - t0)
            return
        }
        NSLog("[KBTIMING] viewDidLayoutSubviews RELAYOUT old=%@ new=%@", NSCoder.string(for: lastBoundsSize), NSCoder.string(for: size))
        lastBoundsSize = size
        forceReconfigureAll = true
        updateLayout()
        if let viewModel {
            update(
                viewModel: viewModel,
                isCompact: isCompact,
                isActiveSession: isActiveSession,
                topInset: topInset,
                truncationBottomInset: truncationBottomInset,
                firstUnreadMessageId: self.firstUnreadMessageId,
                unreadCount: self.unreadCount
            )
        }
#if os(visionOS)
        updateVisibleCellOpacity()
#endif
        NSLog("[KBTIMING] viewDidLayoutSubviews DONE dt=%.4f", CFAbsoluteTimeGetCurrent() - t0)
    }

#if os(visionOS)
    private func updateVisibleCellOpacity() {
        guard collectionView.bounds.height > 1 else { return }
        let visibleRect = collectionView.bounds
        let fadeStartY = visibleRect.minY + (visibleRect.height * 0.08)
        let fadeStartBottomY = visibleRect.maxY - (visibleRect.height * 0.08)
        let topDenom = max(fadeStartY - visibleRect.minY, 1)
        let bottomDenom = max(visibleRect.maxY - fadeStartBottomY, 1)
        for cell in collectionView.visibleCells {
            let cellMinY = cell.frame.minY
            let cellMaxY = cell.frame.maxY
            let topAlpha: CGFloat
            if cellMinY >= fadeStartY {
                topAlpha = 1
            } else {
                topAlpha = max(0, min(1, (cellMinY - visibleRect.minY) / topDenom))
            }

            let bottomAlpha: CGFloat
            if cellMaxY <= fadeStartBottomY {
                bottomAlpha = 1
            } else {
                bottomAlpha = max(0, min(1, (visibleRect.maxY - cellMaxY) / bottomDenom))
            }

            cell.alpha = min(topAlpha, bottomAlpha)
        }
    }
#endif

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
#if os(visionOS)
        updateVisibleCellOpacity()
#endif
        handleUserScrolled()
        checkFirstUnreadCrossingIfNeeded()
        schedulePersistScrollState()
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
#if os(visionOS)
        if !decelerate {
            updateVisibleCellOpacity()
        }
#endif
        if !decelerate {
            setSalientHighlightIsScrolling(false)
        }
        if !decelerate {
            handleUserScrollSettled()
            checkFirstUnreadCrossingIfNeeded()
            performPendingFlashIfPossible()
            performPendingDeferredScrollToBottomIfNeeded()
            schedulePersistScrollState()
            flushDeferredBubbleSizingV2RemeasureIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
#if os(visionOS)
        updateVisibleCellOpacity()
#endif
        setSalientHighlightIsScrolling(false)
        handleUserScrollSettled()
        checkFirstUnreadCrossingIfNeeded()
        performPendingFlashIfPossible()
        performPendingDeferredScrollToBottomIfNeeded()
        schedulePersistScrollState()
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        handleProgrammaticScrollEnded()
        checkFirstUnreadCrossingIfNeeded()
        performPendingFlashIfPossible()
        performPendingDeferredScrollToBottomIfNeeded()
        schedulePersistScrollState()
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Spec: interaction = scroll view dragging/tracking. Enter a pinned-but-defer state.
        setSalientHighlightIsScrolling(true)
        if sbbState == .atBottom {
            setSBBState(.atBottomDragging)
        }
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
        persistScrollStateNow()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
#if os(visionOS)
        updateVisibleCellOpacity()
#else
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        // During morph, we intentionally drive the target cell's alpha from 0->1 in our own
        // `UIView.animate`. Don't let willDisplay stomp it back to 1 early.
        if id == morphTargetMessageId {
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
#endif
    }

    var currentBottomInset: CGFloat = 0
    private var pendingScrollToBottomAttempts: Int = 0
    private var pendingScrollToBottomAnimated: Bool = false

    /// Single source of truth for setting bottom content inset (driven by coordinator).
    func setBottomInset(_ totalBottomInset: CGFloat,
                        animatedDuration: TimeInterval? = nil,
                        animationOptions: UIView.AnimationOptions = []) {
        let previousBottomInset = collectionView.contentInset.bottom
        let delta = totalBottomInset - previousBottomInset
        let shouldPinToBottom = sbbState.isPinnedToBottomIntent && !isUserInteracting
        currentBottomInset = totalBottomInset
        // Avoid re-applying the same inset; on visionOS we can get frequent relayout ticks and
        // touching `contentInset` even with the same value can kick the scroll view.
        if abs(collectionView.contentInset.bottom - totalBottomInset) <= 0.5,
           abs(collectionView.verticalScrollIndicatorInsets.bottom - totalBottomInset) <= 0.5 {
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
        NSLog("[KBTIMING] setBottomInset total=%.1f anim=%.2f", totalBottomInset, animatedDuration ?? 0)
    }

    func scheduleScrollToBottom(animated: Bool, attempts: Int = 2) {
        NSLog("[KBTIMING] scheduleScrollToBottom animated=%d attempts=%d", animated ? 1 : 0, attempts)
        pendingScrollToBottomAttempts = max(pendingScrollToBottomAttempts, attempts)
        pendingScrollToBottomAnimated = pendingScrollToBottomAnimated || animated
        performPendingScrollToBottomIfNeeded()
    }

    private func performPendingScrollToBottomIfNeeded() {
        guard pendingScrollToBottomAttempts > 0 else { return }
        NSLog("[KBTIMING] performPendingScrollToBottom remaining=%d", pendingScrollToBottomAttempts)
        let animated = pendingScrollToBottomAnimated
        pendingScrollToBottomAttempts -= 1
        collectionView.layoutIfNeeded()
        scrollToBottom(animated: animated)
        if pendingScrollToBottomAttempts > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.performPendingScrollToBottomIfNeeded()
            }
        } else {
            pendingScrollToBottomAnimated = false
        }
    }

    func update(
        viewModel: ChatViewModel,
        isCompact: Bool,
        isActiveSession: Bool,
        topInset: CGFloat,
        truncationBottomInset: CGFloat,
        firstUnreadMessageId: String?,
        unreadCount: Int,
        onExpand: ((Message) -> Void)? = nil,
        sessionKey: String? = nil,
        onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)? = nil,
        isDark: Bool? = nil
    ) {
        loadViewIfNeeded()
        let t0 = CFAbsoluteTimeGetCurrent()
        let previousLastMessageId = lastMessageId
        let wasUserInteracting = isUserInteracting
        let wasPinnedToBottomIntent = sbbState.isPinnedToBottomIntent
        let previousSessionKey = self.channelOverride
        self.viewModel = viewModel
        self.channelOverride = sessionKey
        self.isActiveSession = isActiveSession
        self.onExpand = onExpand
        self.truncationBottomInset = truncationBottomInset
        self.onScrollEvent = onScrollEvent
        if self.firstUnreadMessageId != firstUnreadMessageId {
            self.firstUnreadWasBelowViewportCenter = nil
            self.didCrossAndClearFirstUnreadId = nil
        }
        self.firstUnreadMessageId = firstUnreadMessageId
        self.unreadCount = unreadCount

        // Handle appearance change from SwiftUI colorScheme
        if let isDark = isDark, currentIsDark != isDark {
            logger.info("update: appearance changed isDark=\(isDark, privacy: .public)")
            currentIsDark = isDark
            sizeCache.removeAll()
            lastMeasuredSizes.removeAll()
            forceReconfigureAll = true
        }
#if os(visionOS)
        if let isDark = isDark {
            let desiredStyle: UIUserInterfaceStyle = isDark ? .dark : .light
            if view.overrideUserInterfaceStyle != desiredStyle {
                view.overrideUserInterfaceStyle = desiredStyle
                collectionView?.overrideUserInterfaceStyle = desiredStyle
            }
        }
#endif

        let effectiveSessionKey = sessionKey ?? viewModel.activeSessionKey
        let isOffscreenSession = sessionKey != nil && !isActiveSession
        let needsFullLayout = forceReconfigureAll
            || self.isCompact != isCompact
            || self.topInset != topInset
            || previousSessionKey != sessionKey
        self.isCompact = isCompact
        self.topInset = topInset

        if isOffscreenSession {
            return
        }

        updateScrollPersistenceKeyAndPendingRestoreState()

        if needsFullLayout {
            updateLayout()
        }
        NSLog("[KBTIMING] MFCV.update layoutDecision fullLayout=%d dt=%.4f", needsFullLayout ? 1 : 0, CFAbsoluteTimeGetCurrent() - t0)

        // Use session override if provided, otherwise use active session messages.
        let messages = sessionKey.map { viewModel.messages(for: $0) } ?? viewModel.messages
        let appendedMessageIDs = Self.appendedMessageIDs(previousLastMessageId: previousLastMessageId, messageIDs: messages.map(\.id))
        let messageCount = messages.count
        if Set(messages.map(\.id)).count != messageCount {
            logger.info("diffing duplicate ids in viewModel.messages count=\(messageCount, privacy: .public)")
        }
        messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let newFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, fingerprint(for: $0)) })
        let removedIds = Set(fingerprints.keys).subtracting(newFingerprints.keys)
        removedIds.forEach { lastMeasuredSizes.removeValue(forKey: $0) }
        removedIds.forEach { sizeCache.removeValue(forKey: $0) }
        removedIds.forEach { invalidateBubbleSizingV2Cache(for: $0) }
        removedIds.forEach { bubbleSizingV2LinkPreviewStateVersionByMessageId.removeValue(forKey: $0) }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(messages.map(\.id))
        let oldItemIds = Set(dataSource.snapshot().itemIdentifiers)

        // Add typing indicator when assistant is typing (server-controlled)
        // Only show on the matching channel page (for paged TabView)
        let showTypingIndicator = viewModel.isAssistantTyping
            && viewModel.typingSessionKey == effectiveSessionKey
        let typingIndicatorJustAppeared = showTypingIndicator && !wasShowingTypingIndicator
        let shouldMorph = viewModel.shouldMorphTypingIndicator && wasShowingTypingIndicator
        if showTypingIndicator != wasShowingTypingIndicator {
            logger.info("typing indicator state changed: show=\(showTypingIndicator, privacy: .public) wasShowing=\(self.wasShowingTypingIndicator, privacy: .public)")
        }
        wasShowingTypingIndicator = showTypingIndicator
        if showTypingIndicator {
            snapshot.appendItems([TypingIndicatorCell.itemId])
        }

        let newItemIds = Set(snapshot.itemIdentifiers)
        let insertedIds = newItemIds.subtracting(oldItemIds)
        let newestMessageId = messages.last?.id

        // #51: Subtle entrance animation for newly inserted bubbles when we're already at the bottom.
        if let newestMessageId,
           insertedIds.contains(newestMessageId),
           insertedIds.count <= 2,
           isNearBottom(extraMargin: 200),
           !shouldMorph,
           !needsFullLayout {
            pendingEntranceAnimationIds.insert(newestMessageId)
        }

        let changedIds = needsFullLayout
            ? messages.map(\.id)
            : newFingerprints.compactMap { id, fingerprint in
                fingerprints[id] == fingerprint ? nil : id
            }
        if !changedIds.isEmpty {
            snapshot.reconfigureItems(changedIds)
            flowLayout.invalidateLayout()
            changedIds.forEach { sizeCache.removeValue(forKey: $0) }
            changedIds.forEach { lastMeasuredSizes.removeValue(forKey: $0) }
            changedIds.forEach { invalidateBubbleSizingV2Cache(for: $0) }
            changedIds.forEach { bubbleSizingV2LinkPreviewStateVersionByMessageId.removeValue(forKey: $0) }
        }
        forceReconfigureAll = false

        let didLastMessageChange = (previousLastMessageId != newestMessageId)
        let isIncrementalAppend = (previousLastMessageId != nil) && !appendedMessageIDs.isEmpty
        let shouldAutoScrollToBottomAfterApply = didLastMessageChange
            && isIncrementalAppend
            && wasPinnedToBottomIntent
            && !wasUserInteracting
            && !shouldMorph

        let afterSnapshotApplied: (() -> Void) = { [weak self] in
            guard let self else { return }
            self.attemptRestoreScrollIfNeeded()
            if shouldAutoScrollToBottomAfterApply {
                // Race-sensitive: the contentSize can change again after diffable applies.
                // A few post-apply attempts preserves the historical “always end up at the bottom” behavior.
                self.scheduleScrollToBottom(animated: true, attempts: 3)
            }
        }

        if shouldMorph {
#if os(visionOS)
            applySnapshotWithTypingMorphIfPossible(snapshot: snapshot, targetMessageId: newestMessageId) { [weak self] in
                afterSnapshotApplied()
                self?.updateVisibleCellOpacity()
            }
#else
            applySnapshotWithTypingMorphIfPossible(snapshot: snapshot, targetMessageId: newestMessageId) { [weak self] in
                afterSnapshotApplied()
            }
#endif
        } else {
#if os(visionOS)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                afterSnapshotApplied()
                self?.updateVisibleCellOpacity()
            }
#else
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                afterSnapshotApplied()
            }
#endif
        }
        NSLog("[KBTIMING] MFCV.update snapshotApply changed=%d morph=%d dt=%.4f", changedIds.count, shouldMorph ? 1 : 0, CFAbsoluteTimeGetCurrent() - t0)
        logger.info(
            "diffing apply snapshot count=\(messageCount, privacy: .public) changed=\(changedIds.count, privacy: .public) needsLayout=\(needsFullLayout, privacy: .public) morph=\(shouldMorph, privacy: .public)"
        )
        fingerprints = newFingerprints

        if lastMessageId != newestMessageId {
            lastMessageId = newestMessageId
            if shouldMorph {
                // Only defer the post-morph scroll if we would have auto-scrolled (user was pinned to bottom).
                deferScrollToBottomUntilMorphCompletes = isIncrementalAppend && wasPinnedToBottomIntent && !wasUserInteracting
            } else if isIncrementalAppend {
                if wasPinnedToBottomIntent {
                    // ContentAppended while pinned: never enter unread mode.
                    // Auto-scroll now, or defer until drag ends.
                    if wasUserInteracting {
                        pendingScrollToBottomAfterInteractionEnd = true
                    } else {
                        scheduleScrollToBottom(animated: true, attempts: 3)
                    }
                } else {
                    emit(.didReceiveNewMessagesWhileScrolledUp(sessionKey: resolvedSessionKey(), newMessageIDs: appendedMessageIDs))
                }
            } else if !wasUserInteracting {
                // T036: On cold start, restore the last scroll position instead of forcing a reset-to-bottom.
                // For actual stream swaps/resets without a persisted anchor, default to bottom.
                if let pendingScrollRestoreState {
                    if pendingScrollRestoreState.atBottom {
                        scheduleScrollToBottom(animated: true)
                    }
                } else if previousLastMessageId != nil {
                    // Preserve prior behavior on resets/stream swaps: default to bottom when the last id changes
                    // but we can't reliably classify it as an incremental append.
                    scheduleScrollToBottom(animated: true)
                }
            }
        } else if typingIndicatorJustAppeared {
            // Only keep the typing indicator visible if the user is already pinned near the bottom.
            if wasPinnedToBottomIntent && !wasUserInteracting {
                scheduleScrollToBottom(animated: true)
            } else if wasPinnedToBottomIntent && wasUserInteracting {
                // Defer the scroll; never show the SBB while within the at-bottom threshold.
                pendingScrollToBottomAfterInteractionEnd = true
            }
        }
        syncUnreadStateWithSBBState()
        handleContentUpdateCompletion()
        NSLog("[KBTIMING] MFCV.update DONE dt=%.4f", CFAbsoluteTimeGetCurrent() - t0)
    }

    static func appendedMessageIDs(previousLastMessageId: String?, messageIDs: [String]) -> [String] {
        guard let previousLastMessageId else { return [] }
        guard let idx = messageIDs.firstIndex(of: previousLastMessageId) else { return [] }
        let next = messageIDs.index(after: idx)
        guard next < messageIDs.endIndex else { return [] }
        return Array(messageIDs[next...])
    }

    private func resolvedSessionKey() -> String {
        channelOverride ?? viewModel?.activeSessionKey ?? ""
    }

    private func emit(_ event: MessageFlowScrollEvent) {
        onScrollEvent?(event)
    }

    private func setSBBState(_ newState: SBBState) {
        guard sbbState != newState else { return }
        sbbState = newState
        emitHideIndicatorIfChanged(force: true)
    }

    private func emitHideIndicatorIfChanged(force: Bool = false) {
        // Keep the existing event contract: `isAtBottom=true` means "hide the SBB and clear unread".
        // Pinned intent means we may report `true` even if transient geometry isn't at the last pixel.
        let shouldHide = sbbState.shouldHideIndicator
        if force || lastReportedHideIndicator != shouldHide {
            lastReportedHideIndicator = shouldHide
            emit(.isAtBottomChanged(sessionKey: resolvedSessionKey(), isAtBottom: shouldHide))
        }
    }

    private func distanceFromBottomClamped() -> CGFloat {
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        guard maxY.isFinite, minY.isFinite else { return .greatestFiniteMagnitude }
        let offsetY = collectionView.contentOffset.y
        let clampedOffsetY = min(max(offsetY, minY), maxY)
        let distance = max(0, maxY - clampedOffsetY)
        return distance.isFinite ? distance : .greatestFiniteMagnitude
    }

    private func handleUserScrolled() {
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

    private func handleUserScrollSettled() {
        // If the user is no longer interacting, normalize dragging->atBottom when within threshold.
        guard !isUserInteracting else { return }
        if sbbState == .atBottomDragging,
           distanceFromBottomClamped() <= Self.atBottomThreshold {
            setSBBState(.atBottom)
        }
        emitHideIndicatorIfChanged()
    }

    private func handleProgrammaticScrollEnded() {
        handleUserScrollSettled()
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
            // Spec: if the unread anchor disappears from the dataset, clear unread immediately.
            unreadCount = 0
            firstUnreadWasBelowViewportCenter = nil
            didCrossAndClearFirstUnreadId = messageId
            if sbbState == .scrolledUpUnread {
                setSBBState(.scrolledUp)
            }
            emit(.didInvalidateFirstUnreadAnchor(sessionKey: resolvedSessionKey()))
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
           !isBelowCenter {
            // Invariant: clearing-by-scroll triggers when the TOP edge crosses the viewport center, with a flash.
            didCrossAndClearFirstUnreadId = messageId
            pendingFlashMessageId = messageId
            pendingFlashIsUnreadTap = false
            performPendingFlashIfPossible()
            unreadCount = 0
            if sbbState == .scrolledUpUnread {
                setSBBState(.scrolledUp)
            }
            emit(.didCrossFirstUnreadCenter(sessionKey: resolvedSessionKey(), messageId: messageId))
        }

        firstUnreadWasBelowViewportCenter = isBelowCenter
    }

    private func performPendingDeferredScrollToBottomIfNeeded() {
        guard pendingScrollToBottomAfterInteractionEnd else { return }
        guard !isUserInteracting else { return }
        pendingScrollToBottomAfterInteractionEnd = false
        scheduleScrollToBottom(animated: true, attempts: 3)
    }

    private func updateScrollPersistenceKeyAndPendingRestoreState() {
        guard let viewModel else { return }
        let newKey = resolvedSessionKey()
        guard newKey != scrollPersistenceKey else { return }
        scrollPersistenceKey = newKey
        if restoredScrollKeys.contains(newKey) {
            pendingScrollRestoreState = nil
        } else {
            pendingScrollRestoreState = loadPersistedScrollState(for: newKey)
        }

        // T036: Ensure pinned-intent matches the persisted position BEFORE we apply insets.
        // Otherwise, the coordinator may "helpfully" keep the viewport pinned to bottom and
        // effectively undo the restore on the first inset/layout pass.
        if let state = pendingScrollRestoreState {
            if state.atBottom {
                setSBBState(.atBottom)
            } else {
                setSBBState(unreadCount > 0 ? .scrolledUpUnread : .scrolledUp)
            }
        }
    }

    private func scrollStateDefaultsKey(for persistenceKey: String) -> String {
        "clawline.scrollState.v1.\(persistenceKey)"
    }

    private func loadPersistedScrollState(for persistenceKey: String) -> PersistedScrollState? {
        let key = scrollStateDefaultsKey(for: persistenceKey)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedScrollState.self, from: data)
        } catch {
            logger.error("failed decoding scrollState key=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func schedulePersistScrollState() {
        scrollStateWriteDebounceTimer?.invalidate()
        scrollStateWriteDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.scrollStateWriteDebounceSeconds, repeats: false) { [weak self] _ in
            self?.persistScrollStateNow()
        }
    }

    private func persistScrollStateNow() {
        guard let persistenceKey = scrollPersistenceKey else { return }
        guard view.window != nil else { return }
        guard collectionView != nil else { return }

        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        guard maxY.isFinite, minY.isFinite else { return }

        let offsetY = collectionView.contentOffset.y
        let clampedOffsetY = min(max(offsetY, minY), maxY)
        let distanceFromBottom = max(0, maxY - clampedOffsetY)
        let isAtBottom = distanceFromBottom <= Self.atBottomThreshold
        let state = PersistedScrollState(
            atBottom: isAtBottom,
            distanceFromBottom: Double(distanceFromBottom),
            savedAtEpochSeconds: Date().timeIntervalSince1970
        )

        do {
            let data = try JSONEncoder().encode(state)
            let key = scrollStateDefaultsKey(for: persistenceKey)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.error("failed encoding scrollState key=\(persistenceKey, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func attemptRestoreScrollIfNeeded() {
        guard let persistenceKey = scrollPersistenceKey else { return }
        guard !restoredScrollKeys.contains(persistenceKey) else { return }
        guard let state = pendingScrollRestoreState else { return }
        guard collectionView != nil else { return }

        // Wait until we have meaningful geometry; otherwise try again on the next update apply.
        guard collectionView.bounds.height > 1, collectionView.contentSize.height > 1 else { return }

        collectionView.layoutIfNeeded()
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        guard maxY.isFinite, minY.isFinite else { return }

        let targetY: CGFloat
        if state.atBottom {
            targetY = maxY
        } else {
            targetY = maxY - CGFloat(state.distanceFromBottom)
        }
        let clampedTargetY = min(max(targetY, minY), maxY)
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedTargetY), animated: false)

        // The persisted value is best-effort; clamping can land us at bottom even if the saved
        // distance no longer exists (e.g. shorter content). Normalize pinned intent to match the
        // post-restore geometry so subsequent inset changes don't unexpectedly pin.
        let isAtBottomNow = distanceFromBottomClamped() <= Self.atBottomThreshold
        if isAtBottomNow {
            setSBBState(.atBottom)
        } else {
            setSBBState(unreadCount > 0 ? .scrolledUpUnread : .scrolledUp)
        }

        restoredScrollKeys.insert(persistenceKey)
        pendingScrollRestoreState = nil
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
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
#if !os(visionOS)
        collectionView.keyboardDismissMode = .interactive
#endif
        collectionView.allowsSelection = false
        collectionView.allowsMultipleSelection = false
        collectionView.clipsToBounds = false  // Allow content to render past bounds during scroll
        collectionView.delegate = self
        collectionView.register(MessageBubbleUIKitCell.self, forCellWithReuseIdentifier: MessageBubbleUIKitCell.reuseIdentifier)
        collectionView.register(TypingIndicatorCell.self, forCellWithReuseIdentifier: TypingIndicatorCell.reuseIdentifier)

        view.addSubview(collectionView)
        // Frame will be set in viewDidLayoutSubviews to extend to window bounds
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] (collectionView: UICollectionView, indexPath: IndexPath, id: String) in
            guard let self, let viewModel = self.viewModel else { return nil }

            // Handle typing indicator
            if id == TypingIndicatorCell.itemId {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TypingIndicatorCell.reuseIdentifier,
                    for: indexPath
                ) as? TypingIndicatorCell
                let metrics = ChatFlowTheme.Metrics(isCompact: self.isCompact)
                let storageKey = viewModel.typingSessionKey ?? viewModel.activeSessionKey
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
                    isDark: self.currentIsDark
                )
                cell?.startAnimating()
                return cell
            }

            guard let message = self.messagesById[id] else { return nil }
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
            let truncationHeightOverride = self.truncationHeightOverrideForMessageBubble(
                presentation: presentation,
                metrics: metrics
            )
            let layoutStateV2: BubbleSizingV2.LayoutState?
            let configureWidth: CGFloat
            let truncationHeightOverrideV1: CGFloat?
            if self.bubbleSizingV2Enabled {
                let failureReason = viewModel.failureMessage(for: message.id)
                let env = self.bubbleSizingV2Environment(metrics: metrics)
                let plan = self.bubbleSizingV2Plan(
                    message: message,
                    presentation: presentation,
                    metrics: metrics,
                    env: env,
                    showsHeader: !hideHeader
                )
                let state = self.bubbleSizingV2LayoutState(
                    message: message,
                    presentation: presentation,
                    metrics: metrics,
                    env: env,
                    plan: plan,
                    failureReason: failureReason,
                    showsHeader: !hideHeader
                )
                layoutStateV2 = state
                configureWidth = state.measurement.measuredBubbleWidth
                truncationHeightOverrideV1 = nil
            } else {
                layoutStateV2 = nil
                // Use cached size width for consistent sizing with measurement
                configureWidth = self.sizeCache[id]?.width ?? maxWidth
                truncationHeightOverrideV1 = truncationHeightOverride
            }
            cell?.configure(
                message: message,
                presentation: presentation,
                failureReason: viewModel.failureMessage(for: message.id),
                isCompact: self.isCompact,
                maxWidth: configureWidth,
                truncationHeightOverride: truncationHeightOverrideV1,
                bubbleSizingV2: layoutStateV2,
                showsHeader: !hideHeader,
                isDark: self.currentIsDark,
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
        onApplied: (() -> Void)?
    ) {
        guard let targetMessageId,
              let typingIndexPath = dataSource.indexPath(for: TypingIndicatorCell.itemId),
              let typingCell = collectionView.cellForItem(at: typingIndexPath) else {
            // Fallback: let diffable handle it (better than skipping updates).
            dataSource.apply(snapshot, animatingDifferences: true, completion: onApplied)
            return
        }

        morphTargetMessageId = targetMessageId

        collectionView.layoutIfNeeded()
        let startFrame = typingCell.convert(typingCell.bounds, to: collectionView)
        guard let typingSnapshotView = typingCell.snapshotView(afterScreenUpdates: false) else {
            dataSource.apply(snapshot, animatingDifferences: true, completion: onApplied)
            return
        }

        typingSnapshotView.frame = startFrame
        collectionView.addSubview(typingSnapshotView)

        // Apply without diffable animations; we animate the visual transform ourselves.
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            onApplied?()

            // `dataSource.apply(..., animatingDifferences: false)` is frequently executed under a
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
                guard let targetIndexPath = self.dataSource.indexPath(for: targetMessageId),
                      let targetCell = self.collectionView.cellForItem(at: targetIndexPath) else {
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
                    typingSnapshotView.removeFromSuperview()
                    self.morphTargetMessageId = nil
                    // Scroll-to-bottom often triggers a layout pass/scroll animation that makes the
                    // morph feel interrupted. Defer it until the morph completes.
                    if self.deferScrollToBottomUntilMorphCompletes {
                        self.deferScrollToBottomUntilMorphCompletes = false
                        // Multiple attempts preserves the historical “always end up at the bottom” invariant.
                        self.scheduleScrollToBottom(animated: false, attempts: 3)
                    }
                }
            }
        }
    }

    private func updateLayout() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        flowLayout.minimumInteritemSpacing = metrics.flowGap
        flowLayout.minimumLineSpacing = metrics.flowGap
        // Section inset is just for padding - content insets handle safe areas
        flowLayout.sectionInset = UIEdgeInsets(
            top: metrics.containerPadding,
            left: metrics.containerPadding,
            bottom: metrics.containerPadding,
            right: metrics.containerPadding
        )
        // Content insets allow scrolling under safe areas while resting below them
        // Top inset = safe area (status bar) so content can scroll under it
        // Bottom inset = input bar height
        collectionView.contentInset.top = topInset
        collectionView.verticalScrollIndicatorInsets.top = topInset
        setBottomInset(currentBottomInset)
        lastMeasuredSizes.removeAll()
        sizeCache.removeAll()
        bubbleSizingV2MeasurementCache.removeAll()
        bubbleSizingV2KeysByMessageId.removeAll()
        bubbleSizingV2LinkPreviewStateVersionByMessageId.removeAll()
        flowLayout.invalidateLayout()
        NSLog("[KBTIMING] updateLayout cacheCleared invalidated dt=%.4f", CFAbsoluteTimeGetCurrent() - t0)
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

    private func effectiveTruncationHeight(metrics: ChatFlowTheme.Metrics) -> CGFloat {
        let baseHeight = effectiveContainerHeight()
        let bottomInset = max(currentBottomInset, truncationBottomInset)
        return BubbleSizingV2.availableHeightCap(
            containerHeight: baseHeight,
            topInset: topInset,
            bottomInset: bottomInset,
            flowPadding: metrics.containerPadding
        )
    }

    private func effectiveSingleLinkPreviewHeightCap(metrics: ChatFlowTheme.Metrics) -> CGFloat {
        BubbleSizingV2.availableHeightCap(
            containerHeight: collectionView.bounds.height,
            topInset: topInset,
            bottomInset: currentBottomInset,
            flowPadding: metrics.containerPadding
        )
    }

    private func maxItemWidth(for sizeClass: MessageSizeClass,
                              message: Message,
                              presentation: MessagePresentation,
                              metrics: ChatFlowTheme.Metrics,
                              containerWidth: CGFloat) -> CGFloat {
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

    private func truncationHeightOverrideForMessageBubble(
        presentation: MessagePresentation,
        metrics: ChatFlowTheme.Metrics
    ) -> CGFloat? {
        if isSingleLinkPreviewBubble(presentation: presentation) {
            return effectiveSingleLinkPreviewHeightCap(metrics: metrics)
        }
        // Only certain embedded content (tables/images/etc) gets the full screen-aware truncation height.
        // Plain text/markdown bubbles (even if they contain URLs) keep the design-system cap (metrics.truncationHeight).
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        guard prefersScreenAwareTruncationHeight(presentation: presentation, maxLineWidth: maxLineWidth) else {
            return nil
        }
        return effectiveTruncationHeight(metrics: metrics)
    }

    private func prefersWideBubbleWidth(presentation: MessagePresentation,
                                        maxLineWidth: CGFloat) -> Bool {
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
            case .image, .gallery, .linkPreview, .terminalSession:
                return true
            default:
                return false
            }
        }) {
            return true
        }

        let tables = presentation.parts.compactMap { part -> TableModel? in
            if case .table(let model) = part { return model }
            return nil
        }
        if tables.contains(where: { tableContentWidth($0) > maxLineWidth }) {
            return true
        }

        return false
    }

    private func prefersScreenAwareTruncationHeight(presentation: MessagePresentation,
                                                    maxLineWidth: CGFloat) -> Bool {
        // IMPORTANT: Do not opt into screen-aware height caps just because a message contains a URL.
        // That can inflate the cap enough that "too-tall" markdown bubbles never overflow, so we
        // never show fade/scroll/tap-to-expand affordances.
        //
        // Link-preview bubbles keep the design-system max-height cap by default; single-link
        // bubbles are overridden separately via `truncationHeightOverrideForMessageBubble`.
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
            case .image, .gallery, .terminalSession:
                return true
            default:
                return false
            }
        }) {
            return true
        }

        let tables = presentation.parts.compactMap { part -> TableModel? in
            if case .table(let model) = part { return model }
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

        // Handle typing indicator size
        if id == TypingIndicatorCell.itemId {
            let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
            let storageKey = viewModel.typingSessionKey ?? viewModel.activeSessionKey
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
                failureReason: nil,
                maxWidth: maxWidth,
                showsHeader: false,
                paddingScale: TypingIndicatorCell.bubblePaddingScale,
                minWidthOverride: TypingIndicatorCell.bubbleWidth,
                maxWidthOverride: TypingIndicatorCell.bubbleWidth,
                minHeightOverride: TypingIndicatorCell.bubbleHeight
            )
        }

        guard let message = messagesById[id] else {
            return .zero
        }
        if bubbleSizingV2Enabled {
            let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            let hideHeader = shouldHideHeader(for: message, presentation: presentation)
            let failureReason = viewModel.failureMessage(for: message.id)
            let env = bubbleSizingV2Environment(metrics: metrics)
            let plan = bubbleSizingV2Plan(
                message: message,
                presentation: presentation,
                metrics: metrics,
                env: env,
                showsHeader: !hideHeader
            )
            let layoutState = bubbleSizingV2LayoutState(
                message: message,
                presentation: presentation,
                metrics: metrics,
                env: env,
                plan: plan,
                failureReason: failureReason,
                showsHeader: !hideHeader
            )
            return layoutState.measurement.measuredCellSize
        }
        if let cached = sizeCache[id] {
            lastMeasuredSizes[id] = cached
            return cached
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
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
        let failureReason = viewModel.failureMessage(for: message.id)
        let truncationHeightOverride = truncationHeightOverrideForMessageBubble(
            presentation: presentation,
            metrics: metrics
        )
        let measuredSize = measureUIKitBubbleSize(
            message: message,
            presentation: presentation,
            failureReason: failureReason,
            maxWidth: maxWidth,
            truncationHeightOverride: truncationHeightOverride,
            showsHeader: !hideHeader
        )
        sizeCache[id] = measuredSize
        lastMeasuredSizes[id] = measuredSize
        return measuredSize
    }

    private func measureUIKitBubbleSize(message: Message,
                                        presentation: MessagePresentation,
                                        failureReason: String?,
                                        maxWidth: CGFloat,
                                        truncationHeightOverride: CGFloat? = nil,
                                        showsHeader: Bool = true,
                                        paddingScale: CGFloat = 1,
                                        minWidthOverride: CGFloat? = nil,
                                        maxWidthOverride: CGFloat? = nil,
                                        minHeightOverride: CGFloat? = nil) -> CGSize {
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        uiKitBubbleSizer.configure(
            message: message,
            presentation: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth,
            truncationHeightOverride: truncationHeightOverride,
            showsHeader: showsHeader,
            paddingScale: paddingScale,
            minWidthOverride: minWidthOverride,
            maxWidthOverride: maxWidthOverride,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let effectiveMaxWidth = maxWidthOverride ?? maxWidth
        let preferredWidth: CGFloat
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let prefersWideWidth = prefersWideBubbleWidth(presentation: presentation, maxLineWidth: maxLineWidth)
        let prefersScreenAwareHeightCap = prefersScreenAwareTruncationHeight(presentation: presentation, maxLineWidth: maxLineWidth)
        if prefersWideWidth {
            preferredWidth = effectiveMaxWidth
        } else if sizeClass == .short {
            preferredWidth = uiKitBubbleSizer.preferredWidth(maxWidth: effectiveMaxWidth)
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
            let cap = truncationHeightOverride ?? metrics.truncationHeight
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
        if let truncationHeightOverride, prefersScreenAwareHeightCap {
            // For wide content, cap at truncation max (but don't force-max).
            height = min(height, truncationHeightOverride)
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
                                   showsHeader: Bool) -> BubbleSizingV2.Plan {
        let sizeClass = MessageFlowRules.sizeClass(for: presentation)
        let maxLineWidth = ChatFlowTheme.maxLineWidth(bodyFontSize: metrics.bodyFontSize)
        let isSingleLinkPreview = isSingleLinkPreviewBubble(presentation: presentation)
        let isWide = prefersWideBubbleWidth(presentation: presentation, maxLineWidth: maxLineWidth)
        let prefersScreenAwareHeightCap = prefersScreenAwareTruncationHeight(presentation: presentation, maxLineWidth: maxLineWidth)

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
                return max(env.containerWidth * 0.25, 80)
            case .long:
                return 80
            }
        }()

        // Design-system: only "large" (.long) bubbles get truncation/outer-scroll behavior.
        // Short/medium bubbles should grow to content (no truncation chrome), even with Dynamic Type.
        let allowsOuterScroll = (sizeClass == .long)

        let heightCapMode: BubbleSizingV2.HeightCapMode = (isSingleLinkPreview || prefersScreenAwareHeightCap) ? .screenAware : .designSystem
        let heightCap: CGFloat = {
            if isSingleLinkPreview {
                return effectiveSingleLinkPreviewHeightCap(metrics: metrics)
            }
            // If outer-scroll is disabled, use a very generous cap so we never force overflow.
            guard allowsOuterScroll else { return 2000 }
            switch heightCapMode {
            case .screenAware:
                return effectiveTruncationHeight(metrics: metrics)
            case .designSystem:
                return metrics.truncationHeight
            }
        }()

        let linkPreviewURL = presentation.parts.compactMap({ part -> URL? in
            if case .linkPreview(let url) = part { return url }
            return nil
        }).first

        return BubbleSizingV2.Plan(
            messageId: message.id,
            presentationFingerprint: fingerprints[message.id] ?? fingerprint(for: message),
            sizeClass: sizeClass,
            isSingleLinkPreview: isSingleLinkPreview,
            isWide: isWide,
            maxWidth: maxWidth,
            minWidth: minWidth,
            heightCapMode: heightCapMode,
            heightCap: heightCap,
            allowsOuterScroll: allowsOuterScroll,
            linkPreviewURL: linkPreviewURL
        )
    }

    private func linkPreviewViewportMaxHeight(plan: BubbleSizingV2.Plan,
                                              metrics: ChatFlowTheme.Metrics) -> CGFloat {
        let standardVerticalPadding = max(0, metrics.bubblePaddingVertical * 2)
        return max(44, plan.heightCap - standardVerticalPadding)
    }

    private func bubbleSizingV2LayoutState(message: Message,
                                          presentation: MessagePresentation,
                                          metrics: ChatFlowTheme.Metrics,
                                          env: BubbleSizingV2.Environment,
                                          plan: BubbleSizingV2.Plan,
                                          failureReason: String?,
                                          showsHeader: Bool) -> BubbleSizingV2.LayoutState {
        let initialLinkVersion: Int = bubbleSizingV2LinkPreviewStateVersionByMessageId[message.id] ?? 0
        let key = BubbleSizingV2.CacheKey(
            messageId: message.id,
            presentationFingerprint: plan.presentationFingerprint,
            env: env,
            linkPreviewStateVersion: initialLinkVersion
        )
        if let cached = bubbleSizingV2MeasurementCache.value(forKey: key) {
            return bubbleSizingV2MakeLayoutState(
                message: message,
                presentation: presentation,
                metrics: metrics,
                env: env,
                plan: plan,
                measurement: cached
            )
        }

        let measured = bubbleSizingV2Measure(
            message: message,
            presentation: presentation,
            metrics: metrics,
            env: env,
            plan: plan,
            failureReason: failureReason,
            showsHeader: showsHeader
        )
        bubbleSizingV2MeasurementCache.setValue(measured.measurement, forKey: key)
        bubbleSizingV2KeysByMessageId[message.id, default: []].insert(key)
        return measured
    }

    private func bubbleSizingV2MakeLayoutState(message: Message,
                                              presentation: MessagePresentation,
                                              metrics: ChatFlowTheme.Metrics,
                                              env: BubbleSizingV2.Environment,
                                              plan: BubbleSizingV2.Plan,
                                              measurement: BubbleSizingV2.Measurement) -> BubbleSizingV2.LayoutState {
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
        let previewMaxHeight = linkPreviewViewportMaxHeight(plan: plan, metrics: metrics)
        let fixedPreviewHeight: CGFloat? = plan.isSingleLinkPreview ? previewMaxHeight : nil
        let estimated = fixedPreviewHeight
            ?? bubbleSizingV2LinkPreviewHeightCache.get(cacheKey: cacheKey)
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
                                       failureReason: String?,
                                       showsHeader: Bool) -> BubbleSizingV2.LayoutState {
        // Pass 0: configure at max width so preferredWidth() can read padding and label sizes.
        uiKitBubbleSizer.configure(
            message: message,
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: plan.maxWidth,
            truncationHeightOverride: nil,
            showsHeader: showsHeader,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )

        let measuredBubbleWidth: CGFloat = {
            if plan.isWide { return plan.maxWidth }
            if plan.sizeClass == .short {
                let preferred = uiKitBubbleSizer.preferredWidth(maxWidth: plan.maxWidth)
                return BubbleSizingV2.clamp(preferred, plan.minWidth, plan.maxWidth)
            }
            return plan.maxWidth
        }()

        let paddingHorizontal = round((presentation.hasMediaOnly ? 8 : metrics.bubblePaddingHorizontal) * 1)
        let contentWidth = max(1, measuredBubbleWidth - (paddingHorizontal * 2))

        let linkPreviewCacheKey: String? = plan.linkPreviewURL.map { url in
            "\(url.absoluteString)|w=\(Int(contentWidth.rounded()))|m=\(env.metricsFingerprint)"
        }
        let linkPreviewMaxHeight = linkPreviewViewportMaxHeight(plan: plan, metrics: metrics)
        let fixedPreviewHeight: CGFloat? = plan.isSingleLinkPreview ? linkPreviewMaxHeight : nil
        let linkPreviewEstimatedHeight: CGFloat? = fixedPreviewHeight
            ?? linkPreviewCacheKey.flatMap { bubbleSizingV2LinkPreviewHeightCache.get(cacheKey: $0) }
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
                outerScrollViewportHeight: plan.heightCap,
                isFinal: linkPreviewEstimatedHeight != nil
            ),
            linkPreviewCacheKey: linkPreviewCacheKey,
            linkPreviewEstimatedHeight: previewInitialHeight,
            linkPreviewMinHeight: previewMinHeight,
            linkPreviewMaxHeight: linkPreviewMaxHeight
        )
        uiKitBubbleSizer.configure(
            message: message,
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: measuredBubbleWidth,
            truncationHeightOverride: nil,
            bubbleSizingV2: provisional1,
            showsHeader: showsHeader,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )
        let target = CGSize(width: measuredBubbleWidth, height: UIView.layoutFittingCompressedSize.height)
        let measured1 = uiKitBubbleSizer.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let dynamicHeight1 = uiKitBubbleSizer.measuredDynamicContentHeight(fittingWidth: contentWidth)
        let chromeHeight = max(0, measured1.height - dynamicHeight1)
        let viewportHeight = max(plan.heightCap - chromeHeight, 44)

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
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: measuredBubbleWidth,
            truncationHeightOverride: nil,
            bubbleSizingV2: provisional2,
            showsHeader: showsHeader,
            onRequestExpand: nil,
            onRequestLayout: nil,
            onInteractiveCallback: nil
        )

        let measured2 = uiKitBubbleSizer.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let dynamicHeight2 = uiKitBubbleSizer.measuredDynamicContentHeight(fittingWidth: contentWidth)

        let outerScrollEnabled = plan.allowsOuterScroll && measured2.height > plan.heightCap
        let cellHeight: CGFloat = {
            if plan.isSingleLinkPreview {
                return plan.heightCap
            }
            if plan.allowsOuterScroll {
                return min(measured2.height, plan.heightCap)
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
            outerScrollViewportHeight: viewportHeight,
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
                                containerWidth: CGFloat) -> CGFloat {
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

    private func measureSingleLineWidth(for message: Message,
                                        presentation: MessagePresentation,
                                        metrics: ChatFlowTheme.Metrics) -> CGFloat {
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
                                          maxWidth: CGFloat) -> CGFloat? {
        // Check if target line count is achievable at max width
        let linesAtMax = estimatedLineCount(
            for: message,
            presentation: presentation,
            metrics: metrics,
            atWidth: maxWidth
        )
        guard linesAtMax <= targetLines else {
            return nil  // Can't fit in targetLines even at max width
        }

        // Binary search for minimum width where text fits in targetLines
        var low = minWidth
        var high = maxWidth
        var bestWidth = maxWidth

        while high - low > 4 {  // 4pt precision is sufficient
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

    private func estimatedLineCount(for message: Message,
                                    presentation: MessagePresentation,
                                    metrics: ChatFlowTheme.Metrics,
                                    atWidth bubbleWidth: CGFloat) -> Int {
        // UIKit-native line count estimation
        MessageBubbleUIKitView.estimatedLineCount(
            for: presentation,
            metrics: metrics,
            atBubbleWidth: bubbleWidth
        )
    }

    private func measureTextHeight(for message: Message,
                                   presentation: MessagePresentation,
                                   sizeClass: MessageSizeClass,
                                   metrics: ChatFlowTheme.Metrics,
                                   maxWidth: CGFloat) -> CGFloat? {
        // UIKit-native text height measurement
        MessageBubbleUIKitView.measureTextHeight(
            for: presentation,
            sizeClass: sizeClass,
            metrics: metrics,
            maxWidth: maxWidth
        )
    }

    func scrollToBottom(animated: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let lastMessageId,
              dataSource.indexPath(for: lastMessageId) != nil else {
            return
        }
        collectionView.layoutIfNeeded()
        NSLog("[KBTIMING] scrollToBottom.layoutIfNeeded dt=%.4f", CFAbsoluteTimeGetCurrent() - t0)
        let contentInset = collectionView.contentInset
        // Scroll to the bottom of the content (includes section insets/padding).
        // Using contentSize avoids under-scrolling when sectionInset.bottom is non-zero.
        let targetY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let minY = -contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let clampedY = max(minY, min(targetY, maxY))
        // If we're already at (or extremely near) the bottom, don't re-set contentOffset.
        if abs(collectionView.contentOffset.y - clampedY) <= 0.5 {
            return
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
        NSLog("[KBTIMING] scrollToBottom animated=%d targetY=%.1f dt=%.4f", animated ? 1 : 0, clampedY, CFAbsoluteTimeGetCurrent() - t0)
    }

    func scrollToMessageCentered(messageId: String, animated: Bool) {
        guard let indexPath = dataSource.indexPath(for: messageId) else { return }
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
    }

    func isNearBottom(extraMargin: CGFloat) -> Bool {
        // `contentOffset.y` is measured in the scroll view’s content coordinates, where "top" is
        // typically `-contentInset.top`. The previous implementation subtracted `contentInset.top`
        // via `visibleHeight`, which made "distance from bottom" effectively equal to `contentInset.top`
        // even when fully scrolled to the bottom. That prevents "at bottom" from ever becoming true.
        let inset = collectionView.contentInset
        let viewportBottomY = collectionView.contentOffset.y + collectionView.bounds.height - inset.bottom
        let distanceFromBottom = collectionView.contentSize.height - viewportBottomY
        return distanceFromBottom <= extraMargin
    }

    func adjustContentOffsetForBottomInsetChange(delta: CGFloat) {
        NSLog("[KBTIMING] adjustContentOffset delta=%.1f", delta)
        guard abs(delta) > 0.5 else { return }
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom
        let targetY = collectionView.contentOffset.y + delta
        let clampedY = max(minY, min(targetY, maxY))
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
    }

    var isUserInteracting: Bool {
        collectionView.isDragging || collectionView.isTracking
    }

    var isPinnedToBottomIntent: Bool {
        sbbState.isPinnedToBottomIntent
    }

    private func fingerprint(for message: Message) -> Int {
        var hasher = Hasher()
        hasher.combine(message.content)
        hasher.combine(message.streaming)
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
        dirtySizeIds.insert(messageId)
        scheduleLayoutInvalidation()
    }

    private func handleCellRequestedLayout(messageId: String) {
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
                if hasLinkPreview {
                    handleBubbleSizingV2LinkPreviewLayout(messageId: messageId)
                } else {
                    bubbleSizingV2PendingRemeasureIds.insert(messageId)
                    scheduleBubbleSizingV2Remeasure()
                }
            } else {
                bubbleSizingV2PendingRemeasureIds.insert(messageId)
                scheduleBubbleSizingV2Remeasure()
            }
            return
        }
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
              let cell = collectionView.cellForItem(at: indexPath) else {
            invalidateLayout(for: messageId)
            return
        }

        // Link previews (WKWebView) only have meaningful sizes when attached to a window.
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

    private func handleBubbleSizingV2LinkPreviewLayout(messageId: String) {
        guard let viewModel, let message = messagesById[messageId] else {
            invalidateLayout(for: messageId)
            return
        }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let presentation = viewModel.presentation(for: message, metrics: metrics)
        guard let linkPreviewURL = presentation.parts.compactMap({ part -> URL? in
            if case .linkPreview(let url) = part { return url }
            return nil
        }).first else {
            invalidateLayout(for: messageId)
            return
        }

        guard let indexPath = dataSource.indexPath(for: messageId),
              let cell = collectionView.cellForItem(at: indexPath) else {
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
        let oldHeight = bubbleSizingV2LinkPreviewHeightCache.get(cacheKey: cacheKey)
        bubbleSizingV2LinkPreviewHeightCache.set(height: newHeight, cacheKey: cacheKey)

        let epsilon: CGFloat = 4
        if oldHeight == nil || abs((oldHeight ?? 0) - newHeight) > epsilon {
            bubbleSizingV2LinkPreviewStateVersionByMessageId[messageId, default: 0] += 1
        }

        bubbleSizingV2PendingRemeasureIds.insert(messageId)
        scheduleBubbleSizingV2Remeasure()
    }

    private func scheduleBubbleSizingV2Remeasure() {
        // #66: Link previews (WKWebView) report final heights asynchronously. Each report used to
        // trigger a reflow, causing bubbles to jump repeatedly on launch. Debounce + batch into
        // a single remeasure pass, and defer applying it if the user isn't at the bottom.
        if !canApplyBubbleSizingV2RemeasureNow() {
            bubbleSizingV2RemeasureDeferredUntilNearBottom = true
            bubbleSizingV2RemeasureDebounceTimer?.invalidate()
            bubbleSizingV2RemeasureDebounceTimer = nil
            return
        }
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
            self.bubbleSizingV2RemeasureDebounceTimer = nil
            self.flushBubbleSizingV2RemeasureIfPossible()
        }
        bubbleSizingV2RemeasureDebounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func canApplyBubbleSizingV2RemeasureNow() -> Bool {
        // If the user scrolled up to read, don't reflow under their finger/eyes.
        isNearBottom(extraMargin: 240) && !isUserInteracting
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
            return
        }

        let ids = Array(bubbleSizingV2PendingRemeasureIds)
        bubbleSizingV2PendingRemeasureIds.removeAll()
        bubbleSizingV2RemeasureBatchStartTime = nil

        for id in ids {
            invalidateBubbleSizingV2Cache(for: id)
            invalidateLayout(for: id)
            scheduleReconfigure(for: id)
        }

        // If more height updates arrived while we were flushing, schedule another debounced pass.
        if !bubbleSizingV2PendingRemeasureIds.isEmpty {
            scheduleBubbleSizingV2Remeasure()
        }
    }

    private func invalidateBubbleSizingV2Cache(for messageId: String) {
        guard let keys = bubbleSizingV2KeysByMessageId.removeValue(forKey: messageId) else { return }
        for key in keys {
            bubbleSizingV2MeasurementCache.removeValue(forKey: key)
        }
    }

    private func findLinkPreviewView(in view: UIView) -> LinkPreviewView? {
        if let v = view as? LinkPreviewView { return v }
        for subview in view.subviews {
            if let found = findLinkPreviewView(in: subview) { return found }
        }
        return nil
    }

    private func scheduleReconfigure(for messageId: String) {
        pendingReconfigureIds.insert(messageId)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ids = Array(self.pendingReconfigureIds)
            self.pendingReconfigureIds.removeAll()
            var snapshot = self.dataSource.snapshot()
            let existing = ids.filter { snapshot.indexOfItem($0) != nil }
            guard !existing.isEmpty else { return }
            snapshot.reconfigureItems(existing)
            self.dataSource.apply(snapshot, animatingDifferences: false)
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
        let maxWidth = maxItemWidth(
            for: sizeClass,
            message: message,
            presentation: presentation,
            metrics: metrics,
            containerWidth: effectiveContentWidth(metrics: metrics)
        )
        let truncationHeightOverride = truncationHeightOverrideForMessageBubble(
            presentation: presentation,
            metrics: metrics
        )
        let failureReason = viewModel.failureMessage(for: message.id)
        let minWidth: CGFloat = 120
        // #63: Non-short bubbles should never shrink below their size-class max width.
        // Live-cell remeasurement is only needed to correct heights (e.g. link preview WKWebView).
        // Allow .short to remain content-fit; enforce stable widths for .medium/.long.
        let effectiveMaxWidth = max(maxWidth, minWidth)
        let enforcedWidth: CGFloat = (sizeClass == .short)
            ? min(effectiveMaxWidth, max(minWidth, measuredSize.width))
            : effectiveMaxWidth
        let clamped = CGSize(
            // #63: Mirror the initial sizing path's width floor so a transient near-zero measurement
            // (e.g., from a 0pt-wide live cell) cannot permanently lock a bubble to an invalid width.
            width: enforcedWidth,
            height: measuredSize.height
        )
        var snapped = snapToPixel(clamped)
        if let truncationHeightOverride {
            // Cap height to the truncation max.
            snapped.height = min(snapped.height, truncationHeightOverride)
        }
        if let previous = lastMeasuredSizes[messageId] {
            let heightDelta = abs(previous.height - snapped.height)
            let widthDelta = abs(previous.width - snapped.width)
            guard heightDelta > 8 || widthDelta > 4 else { return }
        }
        lastMeasuredSizes[messageId] = snapped
        sizeCache[messageId] = snapped
        scheduleLayoutInvalidation()
        if messageId == lastMessageId {
            scheduleScrollToBottom(animated: false, attempts: 1)
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
            if !self.dirtySizeIds.isEmpty {
                let ids = self.dirtySizeIds
                self.dirtySizeIds.removeAll()
                ids.forEach { id in
                    self.sizeCache.removeValue(forKey: id)
                    self.lastMeasuredSizes.removeValue(forKey: id)
                }
            }
            self.flowLayout.invalidateLayout()
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        sizeForItem(at: indexPath)
    }
}

private final class MessageFlowLayout: UICollectionViewFlowLayout {
    private var cachedAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var cachedContentSize: CGSize = .zero
    private var needsRebuild = true
    private var cachedLayoutSignature: LayoutSignature?

    private struct LayoutSignature: Equatable {
        let itemCount: Int
        let contentWidth: CGFloat
        let sectionInset: UIEdgeInsets
        let minimumInteritemSpacing: CGFloat
        let minimumLineSpacing: CGFloat
    }

    override func prepare() {
        let t0 = CFAbsoluteTimeGetCurrent()
        super.prepare()
        guard let collectionView else { return }

        let itemCount = collectionView.numberOfItems(inSection: 0)
        let contentWidth = collectionView.bounds.width
        let signature = LayoutSignature(
            itemCount: itemCount,
            contentWidth: contentWidth,
            sectionInset: sectionInset,
            minimumInteritemSpacing: minimumInteritemSpacing,
            minimumLineSpacing: minimumLineSpacing
        )
        if !needsRebuild, cachedLayoutSignature == signature {
            return
        }

        cachedAttributes.removeAll(keepingCapacity: true)
        guard itemCount > 0, contentWidth > 0 else {
            cachedContentSize = .zero
            cachedLayoutSignature = signature
            needsRebuild = false
            return
        }

        let maxX = contentWidth - sectionInset.right
        var x = sectionInset.left
        var y = sectionInset.top
        var rowHeight: CGFloat = 0

        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let size = (collectionView.delegate as? UICollectionViewDelegateFlowLayout)?
                .collectionView?(collectionView, layout: self, sizeForItemAt: indexPath) ?? itemSize

            if x + size.width > maxX, x > sectionInset.left {
                x = sectionInset.left
                y += rowHeight + minimumLineSpacing
                rowHeight = 0
            }

            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = frame
            cachedAttributes[indexPath] = attributes

            x += size.width + minimumInteritemSpacing
            rowHeight = max(rowHeight, size.height)
        }

        cachedContentSize = CGSize(width: contentWidth, height: y + rowHeight + sectionInset.bottom)
        cachedLayoutSignature = signature
        needsRebuild = false
        NSLog("[KBTIMING] FlowLayout.prepare items=%d dt=%.4f", itemCount, CFAbsoluteTimeGetCurrent() - t0)
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

    override func invalidateLayout() {
        needsRebuild = true
        super.invalidateLayout()
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
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
