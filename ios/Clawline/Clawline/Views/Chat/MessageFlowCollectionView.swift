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
    var isRenderPolicyFrozen: Bool
    var isInputActive: Bool
    var truncationBottomInset: CGFloat
    var firstUnreadMessageId: String?
    var unreadCount: Int
    var onExpand: ((Message) -> Void)?
    var layoutCoordinator: ChatLayoutCoordinator
    var shouldRegisterWithLayoutCoordinator: Bool = true
    /// Optional session override - if provided, shows messages for this session instead of activeSessionKey
    var sessionKey: String?
    var forceReReadGeneration: Int = 0
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
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            sessionKey: sessionKey,
            forceReReadGeneration: forceReReadGeneration,
            onScrollEvent: onScrollEvent,
            isDark: isDark
        )
        if shouldRegisterWithLayoutCoordinator, let sessionKey {
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
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            sessionKey: sessionKey,
            forceReReadGeneration: forceReReadGeneration,
            onScrollEvent: onScrollEvent,
            isDark: isDark
        )
        if shouldRegisterWithLayoutCoordinator, let sessionKey {
            layoutCoordinator.registerListView(uiViewController, sessionKey: sessionKey)
        }
    }
}

final class MessageFlowCollectionViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    private struct UpdateRequest {
        let viewModel: ChatViewModel
        let isCompact: Bool
        let isActiveSession: Bool
        let isRenderPolicyFrozen: Bool
        let isInputActive: Bool
        let topInset: CGFloat
        let truncationBottomInset: CGFloat
        let firstUnreadMessageId: String?
        let unreadCount: Int
        let onExpand: ((Message) -> Void)?
        let sessionKey: String?
        let forceReReadGeneration: Int
        let onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)?
        let isDark: Bool?
    }

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
    private static let bottomInsetHeightCapInvalidationDebounceSeconds: TimeInterval = 0.20
    private static let restoreMaxConfirmationRetries: Int = 3

    private var messagesById: [String: Message] = [:]
    private var dateSeparatorTextByItemId: [String: String] = [:]
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
        var bubbleSizingV2RemeasureDebounceTimer: Timer?
        var bubbleSizingV2DeferredFlushTimer: Timer?

        var deferredBottomInsetRemeasureIds: Set<String> = []
        var bottomInsetRemeasureTimer: Timer?
        var bottomInsetRemeasureBypassInputGates = false
        var pendingBottomInsetHeightCapInvalidation: DispatchWorkItem?
    }

    private var perStreamStateBySessionKey: [String: PerStreamRuntimeState] = [:]
    private var isUpdatePassInFlight = false
    private var isSnapshotApplyInFlight = false
    private var queuedUpdateRequest: UpdateRequest?
    private var lastAppliedEffectiveSessionKey: String?
    private var invalidationScheduled = false
    private var viewModel: ChatViewModel?
    private var isCompact: Bool = true
    private var isActiveSession: Bool = true
    private var isRenderPolicyFrozen: Bool = false
    private var isInputActive: Bool = false
    private var topInset: CGFloat = 0
    private var truncationBottomInset: CGFloat = 0
    private var lastBoundsSize: CGSize = .zero
    private var forceReconfigureAll = false
    private var onExpand: ((Message) -> Void)?
    private var onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)?
    // Staged stream materialization (approved spec: tail window -> full history).
    // WHY N=50: device measurements showed 500-item first apply taking 1.4-2.7s.
    // A 50-item first paint targets ~10% of that cost while still showing meaningful recent context.
    private static let stagedMaterializationTailWindowCount = 50

    private enum MaterializationStage: String {
        // WHY only two stages: spec intentionally limits complexity to one fast first paint
        // followed by one full-history expansion. No intermediate windows.
        case tail
        case full
    }

    private enum ExpansionState: String {
        case idle
        case pendingFull
    }

    private struct WindowBounds {
        var lowerBound: Int
        var upperBound: Int

        static let empty = WindowBounds(lowerBound: 0, upperBound: 0)
    }

    private struct MaterializationState {
        var stage: MaterializationStage
        var windowBounds: WindowBounds
        var expansionState: ExpansionState
        var unreadOutsideTailWindow: Bool
    }

    private enum MaterializationEvent {
        case messagesUpdated(totalCount: Int,
                             firstUnreadMessageId: String?,
                             fullMessageIds: [String],
                             allowTailStage: Bool)
        case tailRendered(totalCount: Int,
                          firstUnreadMessageId: String?,
                          fullMessageIds: [String])
    }

    private struct MaterializationEventEnvelope {
        let sessionKey: String
        let event: MaterializationEvent
    }

    private struct MaterializationPlan {
        var stage: MaterializationStage
        var windowBounds: WindowBounds
        var unreadOutsideTailWindow: Bool
        var scheduleTailToFullPromotion: Bool
        var isTailToFullExpansionApply: Bool
    }

    private var materializationStateBySessionKey: [String: MaterializationState] = [:]
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

    private var bottomInsetRemeasureBypassInputGates: Bool {
        get { activeStateKey().map { readState(for: $0).bottomInsetRemeasureBypassInputGates } ?? false }
        set {
            guard let key = activeStateKey() else { return }
            mutateState(for: key) { $0.bottomInsetRemeasureBypassInputGates = newValue }
        }
    }

    func scheduleScrollToBottom(animated: Bool, attempts: Int = 2) {
        guard let sessionKey = callbackSessionKey() else { return }
        scheduleScrollToBottom(sessionKey: sessionKey, animated: animated, attempts: attempts)
    }

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
        pendingBottomInsetHeightCapInvalidation?.cancel()
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
        let epsilon: CGFloat = 4
        guard oldHeight == nil || abs((oldHeight ?? 0) - height) > epsilon else {
            return nil
        }
        bubbleSizingV2LinkPreviewStateVersionByMessageId[messageId, default: 0] += 1
        return height - (oldHeight ?? height)
    }

    @discardableResult
    private func invalidateFor(reason: InvalidationReason) -> InvalidationPlan {
        switch reason {
        case .messageChanged(let id):
            dirtySizeIds.insert(id)
            return .fullRebuild
        case .messagesRemoved(let ids):
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
        case .reconfigureItems(let ids):
            ids.forEach { scheduleReconfigure(for: $0) }
        case .remeasureAndShift(let changes):
            guard changes.count == 1,
                  let change = changes.first,
                  abs(change.delta) > 0.5,
                  let indexPath = dataSource.indexPath(for: change.id) else {
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
        ids.forEach { id in
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
        bubbleSizingV2KeysByMessageId.removeAll()
        bubbleSizingV2LinkPreviewStateVersionByMessageId.removeAll()
    }

    private func removeBubbleV2PreviewVersions(for ids: [String]) {
        ids.forEach { bubbleSizingV2LinkPreviewStateVersionByMessageId.removeValue(forKey: $0) }
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

    private func recordBubbleV2Measurement(_ measurement: BubbleSizingV2.Measurement,
                                           key: BubbleSizingV2.CacheKey,
                                           messageId: String) {
        bubbleSizingV2MeasurementCache.setValue(measurement, forKey: key)
        bubbleSizingV2KeysByMessageId[messageId, default: []].insert(key)
    }

    private func removeBubbleV2Measurements(for messageId: String) {
        guard let keys = bubbleSizingV2KeysByMessageId.removeValue(forKey: messageId) else { return }
        for key in keys {
            bubbleSizingV2MeasurementCache.removeValue(forKey: key)
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
                isRenderPolicyFrozen: isRenderPolicyFrozen,
                isInputActive: isInputActive,
                topInset: topInset,
                truncationBottomInset: truncationBottomInset,
                firstUnreadMessageId: self.firstUnreadMessageId,
                unreadCount: self.unreadCount,
                onExpand: onExpand,
                sessionKey: channelOverride,
                forceReReadGeneration: 0,
                onScrollEvent: onScrollEvent,
                isDark: currentIsDark
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
        bubbleSizingV2LastScrollActivityTime = CFAbsoluteTimeGetCurrent()
#if os(visionOS)
        updateVisibleCellOpacity()
#endif
        guard let sessionKey = callbackSessionKey() else { return }
        handleUserScrolled(sessionKey: sessionKey)
        checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
        refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        schedulePersistScrollState(sessionKey: sessionKey)
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
        scheduleDeferredBottomInsetRemeasure()
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
            guard let sessionKey = callbackSessionKey() else { return }
            handleUserScrollSettled(sessionKey: sessionKey)
            checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
            performPendingFlashIfPossible()
            performPendingDeferredScrollToBottomIfNeeded(sessionKey: sessionKey)
            schedulePersistScrollState(sessionKey: sessionKey)
            flushDeferredBubbleSizingV2RemeasureIfNeeded()
            scheduleDeferredBottomInsetRemeasure()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
#if os(visionOS)
        updateVisibleCellOpacity()
#endif
        setSalientHighlightIsScrolling(false)
        guard let sessionKey = callbackSessionKey() else { return }
        handleUserScrollSettled(sessionKey: sessionKey)
        checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
        performPendingFlashIfPossible()
        performPendingDeferredScrollToBottomIfNeeded(sessionKey: sessionKey)
        schedulePersistScrollState(sessionKey: sessionKey)
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
        scheduleDeferredBottomInsetRemeasure()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let sessionKey = callbackSessionKey() else { return }
        handleProgrammaticScrollEnded(sessionKey: sessionKey)
        checkFirstUnreadCrossingIfNeeded(sessionKey: sessionKey)
        performPendingFlashIfPossible()
        performPendingDeferredScrollToBottomIfNeeded(sessionKey: sessionKey)
        schedulePersistScrollState(sessionKey: sessionKey)
        flushDeferredBubbleSizingV2RemeasureIfNeeded()
        scheduleDeferredBottomInsetRemeasure()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Spec: interaction = scroll view dragging/tracking. Enter a pinned-but-defer state.
        setSalientHighlightIsScrolling(true)
        guard let sessionKey = callbackSessionKey() else { return }
        if readState(for: sessionKey).sbbState == .atBottom {
            setSBBState(.atBottomDragging, sessionKey: sessionKey)
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
        guard let sessionKey = callbackSessionKey() else { return }
        persistScrollStateNow(sessionKey: sessionKey)
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
        scheduleDeferredBottomInsetRemeasure()
    }

    var currentBottomInset: CGFloat = 0

    /// Single source of truth for setting bottom content inset (driven by coordinator).
    func setBottomInset(_ totalBottomInset: CGFloat,
                        animatedDuration: TimeInterval? = nil,
                        animationOptions: UIView.AnimationOptions = []) {
        let previousBottomInset = collectionView.contentInset.bottom
        let delta = totalBottomInset - previousBottomInset
        // Keep keyboard/inset anchoring tied to active finger interaction only.
        // Deceleration must not disable this pinning path.
        let shouldPinToBottom = sbbState.isPinnedToBottomIntent && !isActivelyDraggingOrTracking
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
        handleBottomInsetHeightCapChange(previousBottomInset: previousBottomInset, newBottomInset: totalBottomInset)
        NSLog("[KBTIMING] setBottomInset total=%.1f anim=%.2f", totalBottomInset, animatedDuration ?? 0)
    }

    private func handleBottomInsetHeightCapChange(previousBottomInset: CGFloat, newBottomInset: CGFloat) {
        guard abs(newBottomInset - previousBottomInset) > 0.5 else { return }
        scheduleBottomInsetHeightCapInvalidation(
            previousBottomInset: previousBottomInset,
            newBottomInset: newBottomInset
        )
    }

    private func scheduleBottomInsetHeightCapInvalidation(previousBottomInset: CGFloat, newBottomInset: CGFloat) {
        guard let token = activeSessionGenerationToken() else { return }
        pendingBottomInsetHeightCapInvalidation?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            self.withBoundSessionKey(token.sessionKey) {
                self.pendingBottomInsetHeightCapInvalidation = nil
                self.applyBottomInsetHeightCapInvalidation(
                    previousBottomInset: previousBottomInset,
                    newBottomInset: newBottomInset
                )
            }
        }
        pendingBottomInsetHeightCapInvalidation = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.bottomInsetHeightCapInvalidationDebounceSeconds,
            execute: workItem
        )
    }

    private func applyBottomInsetHeightCapInvalidation(previousBottomInset: CGFloat, newBottomInset: CGFloat) {
        guard let viewModel else { return }
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let affectedIds = messagesById.values.compactMap { message -> String? in
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            return isSingleLinkPreviewBubble(presentation: presentation) ? message.id : nil
        }
        guard !affectedIds.isEmpty else { return }
        deferredBottomInsetRemeasureIds.formUnion(affectedIds)
        // Keyboard dismiss is a discrete geometry transition, not active typing churn.
        // When inset collapses significantly, visible capped bubbles must remeasure promptly
        // even if focus/content gates still report "active input".
        if isLikelyKeyboardDismissInsetChange(previousBottomInset: previousBottomInset, newBottomInset: newBottomInset) {
            bottomInsetRemeasureBypassInputGates = true
        }
        scheduleDeferredBottomInsetRemeasure()
    }

    private func isLikelyKeyboardDismissInsetChange(previousBottomInset: CGFloat, newBottomInset: CGFloat) -> Bool {
        let collapsedBy = previousBottomInset - newBottomInset
        // Keyboard transitions are large inset drops (hundreds of points), unlike line-wrap
        // or small chrome adjustments. Keep this threshold conservative to avoid broadening scope.
        return collapsedBy > 80
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
        guard isBubbleSizingV2ScrollAtRest() else {
            // If we intentionally bypass input gates for keyboard-dismiss, keep trying until rest.
            if bottomInsetRemeasureBypassInputGates {
                scheduleDeferredBottomInsetRemeasure()
            }
            return
        }
        if !bottomInsetRemeasureBypassInputGates {
            guard !isInputActive else { return }
            guard viewModel?.inputContent.isEffectivelyEmpty != false else { return }
        }

        let visibleIds: Set<String> = Set(collectionView.indexPathsForVisibleItems.compactMap { indexPath in
            guard let id = dataSource.itemIdentifier(for: indexPath), !isNonMessageItemID(id) else {
                return nil
            }
            return id
        })
        let idsToRemeasure = Array(deferredBottomInsetRemeasureIds.intersection(visibleIds))
        guard !idsToRemeasure.isEmpty else {
            // Bypass applies to currently visible bubbles only.
            // Keep non-visible ids queued for normal scroll-into-view handling.
            bottomInsetRemeasureBypassInputGates = false
            return
        }

        if bubbleSizingV2Enabled {
            idsToRemeasure.forEach { invalidateBubbleSizingV2Cache(for: $0) }
        } else {
            clearSizeState(for: idsToRemeasure)
        }

        idsToRemeasure.forEach { id in
            scheduleReconfigure(for: id)
            let plan = invalidateFor(reason: .messageChanged(id: id))
            executeInvalidationPlan(plan)
        }
        deferredBottomInsetRemeasureIds.subtract(idsToRemeasure)
        bottomInsetRemeasureBypassInputGates = false
    }

    func scheduleScrollToBottom(sessionKey: String, animated: Bool, attempts: Int = 2) {
        NSLog("[KBTIMING] scheduleScrollToBottom animated=%d attempts=%d", animated ? 1 : 0, attempts)
        mutateState(for: sessionKey) { state in
            state.pendingScrollToBottomAttempts = max(state.pendingScrollToBottomAttempts, attempts)
            state.pendingScrollToBottomAnimated = state.pendingScrollToBottomAnimated || animated
        }
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
        NSLog("[KBTIMING] performPendingScrollToBottom remaining=%d", remainingAttempts)
        collectionView.layoutIfNeeded()
        scrollToBottom(animated: animated)
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
                                             event: MaterializationEvent) -> MaterializationPlan {
        materializationEventQueue.append(MaterializationEventEnvelope(sessionKey: sessionKey, event: event))
        processMaterializationEventQueue()
        return lastMaterializationPlanBySessionKey[sessionKey]
            ?? MaterializationPlan(
                stage: .full,
                windowBounds: .empty,
                unreadOutsideTailWindow: false,
                scheduleTailToFullPromotion: false,
                isTailToFullExpansionApply: false
            )
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
        let persistedState = loadPersistedScrollState(for: sessionKey)
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
    }

    private func prepareSameKeyReread(sessionKey: String) {
        mutateState(for: sessionKey) { state in
            state.scrollStateWriteDebounceTimer?.invalidate()
            state.scrollStateWriteDebounceTimer = nil
            state.restoreGeneration += 1
            state.pendingScrollRestoreState = loadPersistedScrollState(for: sessionKey)
            state.restorePhase = .pendingTail
            state.restoreConfirmationRetries = 0
            state.suspendScrollPersistenceUntilRestoreConfirmed = true
        }
    }

    private func processMaterializationEventQueue() {
        guard !isMaterializationQueueProcessing else { return }
        isMaterializationQueueProcessing = true
        defer { isMaterializationQueueProcessing = false }

        // FIFO command processing keeps expansion and append events deterministic.
        while !materializationEventQueue.isEmpty {
            let envelope = materializationEventQueue.removeFirst()
            let plan = advanceMaterialization(sessionKey: envelope.sessionKey, event: envelope.event)
            lastMaterializationPlanBySessionKey[envelope.sessionKey] = plan
        }
    }

    private func advanceMaterialization(sessionKey: String,
                                        event: MaterializationEvent) -> MaterializationPlan {
        let totalCount: Int
        let firstUnreadId: String?
        let fullMessageIds: [String]
        let allowTailStage: Bool
        switch event {
        case .messagesUpdated(let count, let unreadId, let ids, let allowTail):
            totalCount = count
            firstUnreadId = unreadId
            fullMessageIds = ids
            allowTailStage = allowTail
        case .tailRendered(let count, let unreadId, let ids):
            totalCount = count
            firstUnreadId = unreadId
            fullMessageIds = ids
            allowTailStage = false
        }

        if totalCount <= 0 {
            materializationStateBySessionKey[sessionKey] = MaterializationState(
                stage: .full,
                windowBounds: .empty,
                expansionState: .idle,
                unreadOutsideTailWindow: false
            )
            return MaterializationPlan(
                stage: .full,
                windowBounds: .empty,
                unreadOutsideTailWindow: false,
                scheduleTailToFullPromotion: false,
                isTailToFullExpansionApply: false
            )
        }

        if totalCount <= Self.stagedMaterializationTailWindowCount {
            // WHY bypass staging for small streams: adding tail->full churn would be overhead
            // without meaningful latency reduction when full history is already short.
            let fullBounds = WindowBounds(lowerBound: 0, upperBound: totalCount)
            materializationStateBySessionKey[sessionKey] = MaterializationState(
                stage: .full,
                windowBounds: fullBounds,
                expansionState: .idle,
                unreadOutsideTailWindow: false
            )
            return MaterializationPlan(
                stage: .full,
                windowBounds: fullBounds,
                unreadOutsideTailWindow: false,
                scheduleTailToFullPromotion: false,
                isTailToFullExpansionApply: false
            )
        }

        var state = materializationStateBySessionKey[sessionKey]
        if state == nil {
            if allowTailStage {
                let tailBounds = tailWindowBounds(totalCount: totalCount)
                state = MaterializationState(
                    stage: .tail,
                    windowBounds: tailBounds,
                    expansionState: .pendingFull,
                    unreadOutsideTailWindow: isUnreadOutsideTailWindow(
                        firstUnreadMessageId: firstUnreadId,
                        bounds: tailBounds,
                        fullMessageIds: fullMessageIds
                    )
                )
            } else {
                let fullBounds = WindowBounds(lowerBound: 0, upperBound: totalCount)
                state = MaterializationState(
                    stage: .full,
                    windowBounds: fullBounds,
                    expansionState: .idle,
                    unreadOutsideTailWindow: false
                )
            }
        }
        guard var state else {
            // Defensive fallback to satisfy control-flow analysis.
            // In practice, state is always initialized by the branch above.
            let fullBounds = WindowBounds(lowerBound: 0, upperBound: totalCount)
            return MaterializationPlan(
                stage: .full,
                windowBounds: fullBounds,
                unreadOutsideTailWindow: false,
                scheduleTailToFullPromotion: false,
                isTailToFullExpansionApply: false
            )
        }

        switch event {
        case .messagesUpdated:
            if state.stage == .tail {
                let tailBounds = tailWindowBounds(totalCount: totalCount)
                state.windowBounds = tailBounds
                state.unreadOutsideTailWindow = isUnreadOutsideTailWindow(
                    firstUnreadMessageId: firstUnreadId,
                    bounds: tailBounds,
                    fullMessageIds: fullMessageIds
                )
                let shouldSchedule = state.expansionState == .pendingFull
                if shouldSchedule {
                    // WHY only one promotion trigger: tail->full is a single transition.
                    // Reissuing promotions would queue redundant expansion work and add jitter.
                    state.expansionState = .idle
                }
                materializationStateBySessionKey[sessionKey] = state
                return MaterializationPlan(
                    stage: .tail,
                    windowBounds: tailBounds,
                    unreadOutsideTailWindow: state.unreadOutsideTailWindow,
                    scheduleTailToFullPromotion: shouldSchedule,
                    isTailToFullExpansionApply: false
                )
            }

            let fullBounds = WindowBounds(lowerBound: 0, upperBound: totalCount)
            state.stage = .full
            state.windowBounds = fullBounds
            state.expansionState = .idle
            state.unreadOutsideTailWindow = false
            materializationStateBySessionKey[sessionKey] = state
            return MaterializationPlan(
                stage: .full,
                windowBounds: fullBounds,
                unreadOutsideTailWindow: false,
                scheduleTailToFullPromotion: false,
                isTailToFullExpansionApply: false
            )

        case .tailRendered:
            if state.stage == .tail {
                let fullBounds = WindowBounds(lowerBound: 0, upperBound: totalCount)
                state.stage = .full
                state.windowBounds = fullBounds
                state.expansionState = .idle
                state.unreadOutsideTailWindow = false
                materializationStateBySessionKey[sessionKey] = state
                return MaterializationPlan(
                    stage: .full,
                    windowBounds: fullBounds,
                    unreadOutsideTailWindow: false,
                    scheduleTailToFullPromotion: false,
                    isTailToFullExpansionApply: true
                )
            }

            let fullBounds = WindowBounds(lowerBound: 0, upperBound: totalCount)
            state.stage = .full
            state.windowBounds = fullBounds
            state.expansionState = .idle
            state.unreadOutsideTailWindow = false
            materializationStateBySessionKey[sessionKey] = state
            return MaterializationPlan(
                stage: .full,
                windowBounds: fullBounds,
                unreadOutsideTailWindow: false,
                scheduleTailToFullPromotion: false,
                isTailToFullExpansionApply: false
            )
        }
    }

    private func tailWindowBounds(totalCount: Int) -> WindowBounds {
        let lower = max(0, totalCount - Self.stagedMaterializationTailWindowCount)
        return WindowBounds(lowerBound: lower, upperBound: totalCount)
    }

    private func isUnreadOutsideTailWindow(firstUnreadMessageId: String?,
                                           bounds: WindowBounds,
                                           fullMessageIds: [String]) -> Bool {
        guard let firstUnreadMessageId else { return false }
        guard let index = fullMessageIds.firstIndex(of: firstUnreadMessageId) else {
            return true
        }
        return index < bounds.lowerBound || index >= bounds.upperBound
    }

    private func stagedMessageIDs(messages: [Message], bounds: WindowBounds) -> [String] {
        guard !messages.isEmpty else { return [] }
        let lower = max(0, min(bounds.lowerBound, messages.count))
        let upper = max(lower, min(bounds.upperBound, messages.count))
        guard lower < upper else { return [] }
        return messages[lower..<upper].map(\.id)
    }

    private func scheduleTailToFullPromotionIfNeeded(sessionKey: String) {
        // Promotion is queued on next runloop turn so tail stage can render first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let sessionMatches = (self.channelOverride ?? self.viewModel?.engineActiveSessionKey) == sessionKey
            guard self.isActiveSession, sessionMatches else { return }
            let fullMessages = self.viewModel?.messages(for: sessionKey) ?? []
            let fullMessageIds = fullMessages.map(\.id)

            let plan = self.enqueueMaterializationEvent(
                sessionKey: sessionKey,
                event: .tailRendered(
                    totalCount: fullMessages.count,
                    firstUnreadMessageId: self.firstUnreadMessageId,
                    fullMessageIds: fullMessageIds
                )
            )
            guard plan.isTailToFullExpansionApply else { return }
            self.runMaterializationRefreshPass()
        }
    }

    private func runMaterializationRefreshPass() {
        guard let viewModel else { return }
        update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            sessionKey: channelOverride,
            forceReReadGeneration: 0,
            onScrollEvent: onScrollEvent,
            isDark: currentIsDark
        )
    }

    private func drainQueuedUpdateIfPossible() {
        guard !isUpdatePassInFlight, !isSnapshotApplyInFlight else { return }
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
                topInset: request.topInset,
                truncationBottomInset: request.truncationBottomInset,
                firstUnreadMessageId: request.firstUnreadMessageId,
                unreadCount: request.unreadCount,
                onExpand: request.onExpand,
                sessionKey: request.sessionKey,
                forceReReadGeneration: request.forceReReadGeneration,
                onScrollEvent: request.onScrollEvent,
                isDark: request.isDark
            )
        }
    }

    func update(
        viewModel: ChatViewModel,
        isCompact: Bool,
        isActiveSession: Bool,
        isRenderPolicyFrozen: Bool,
        isInputActive: Bool,
        topInset: CGFloat,
        truncationBottomInset: CGFloat,
        firstUnreadMessageId: String?,
        unreadCount: Int,
        onExpand: ((Message) -> Void)? = nil,
        sessionKey: String? = nil,
        forceReReadGeneration: Int = 0,
        onScrollEvent: (@MainActor (MessageFlowScrollEvent) -> Void)? = nil,
        isDark: Bool? = nil
    ) {
        let request = UpdateRequest(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: firstUnreadMessageId,
            unreadCount: unreadCount,
            onExpand: onExpand,
            sessionKey: sessionKey,
            forceReReadGeneration: forceReReadGeneration,
            onScrollEvent: onScrollEvent,
            isDark: isDark
        )
        if isUpdatePassInFlight || isSnapshotApplyInFlight {
            queuedUpdateRequest = request
            return
        }

        isUpdatePassInFlight = true
        defer {
            isUpdatePassInFlight = false
            drainQueuedUpdateIfPossible()
        }

        loadViewIfNeeded()
        let t0 = CFAbsoluteTimeGetCurrent()
        let previousLastMessageId = lastMessageId
        let wasUserInteracting = isUserInteracting
        let wasPinnedToBottomIntent = sbbState.isPinnedToBottomIntent
        let previousSessionKey = self.channelOverride
        self.viewModel = viewModel
        self.channelOverride = sessionKey
        self.isActiveSession = isActiveSession
        self.isRenderPolicyFrozen = isRenderPolicyFrozen
        self.isInputActive = isInputActive
        self.onExpand = onExpand
        self.truncationBottomInset = truncationBottomInset
        self.onScrollEvent = onScrollEvent

        // Handle appearance change from SwiftUI colorScheme
        if let isDark = isDark, currentIsDark != isDark {
            logger.info("update: appearance changed isDark=\(isDark, privacy: .public)")
            currentIsDark = isDark
            clearAllSizeState()
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

        let effectiveSessionKey = sessionKey ?? viewModel.engineActiveSessionKey
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
            self.firstUnreadWasBelowViewportCenter = nil
            self.didCrossAndClearFirstUnreadId = nil
        }
        self.firstUnreadMessageId = firstUnreadMessageId
        self.unreadCount = unreadCount
        let isOffscreenSession = sessionKey != nil && !isActiveSession
        if isRenderPolicyFrozen {
            // Render policy `.frozen` applies to ALL pages, including the outgoing engine-active page.
            // We suppress starting new snapshot/apply/layout work during pager animation.
            // Any apply already in flight is allowed to finish normally.
            StreamSwitchTiming.log("messageFlow_update_skipped_frozen", sessionKey: effectiveSessionKey)
            return
        }
        let needsFullLayout = forceReconfigureAll
            || self.isCompact != isCompact
            || self.topInset != topInset
            || previousSessionKey != sessionKey
        self.isCompact = isCompact
        self.topInset = topInset

        if isOffscreenSession {
            return
        }

        if needsFullLayout {
            updateLayout()
        }
        NSLog("[KBTIMING] MFCV.update layoutDecision fullLayout=%d dt=%.4f", needsFullLayout ? 1 : 0, CFAbsoluteTimeGetCurrent() - t0)

        // Use session override if provided, otherwise use active session messages.
        let messages = sessionKey.map { viewModel.messages(for: $0) } ?? viewModel.messages
        let fullMessageIds = messages.map(\.id)
        let appendedMessageIDs = Self.appendedMessageIDs(previousLastMessageId: previousLastMessageId, messageIDs: fullMessageIds)
        let messageCount = messages.count
        if Set(fullMessageIds).count != messageCount {
            logger.info("diffing duplicate ids in viewModel.messages count=\(messageCount, privacy: .public)")
        }
        messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let newFingerprints = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, fingerprint(for: $0)) })
        let removedIds = Set(fingerprints.keys).subtracting(newFingerprints.keys)
        let removedPlan = invalidateFor(reason: .messagesRemoved(Array(removedIds)))
        executeInvalidationPlan(removedPlan)
        expireRegisteredMessageLoadCallbacks(for: effectiveSessionKey, messageIds: removedIds)

        StreamSwitchTiming.log("snapshot_build_start", sessionKey: effectiveSessionKey)
        // WHY revisits skip tail stage: first-visit latency is the bottleneck.
        // Returning to a visited stream should avoid staged complexity and show full history directly.
        let isFirstActivationForSession = materializationStateBySessionKey[effectiveSessionKey] == nil
        withBoundSessionKey(effectiveSessionKey) {
            if restorePhase == .pendingTail && !isFirstActivationForSession {
                restorePhase = .pendingFullConfirmation
            }
        }
        let materializationPlan = enqueueMaterializationEvent(
            sessionKey: effectiveSessionKey,
            event: .messagesUpdated(
                totalCount: messageCount,
                firstUnreadMessageId: firstUnreadMessageId,
                fullMessageIds: fullMessageIds,
                allowTailStage: isFirstActivationForSession
            )
        )
        let snapshotMessages: [Message]
        switch materializationPlan.stage {
        case .tail:
            let lower = max(0, min(materializationPlan.windowBounds.lowerBound, messages.count))
            let upper = max(lower, min(materializationPlan.windowBounds.upperBound, messages.count))
            snapshotMessages = Array(messages[lower..<upper])
        case .full:
            snapshotMessages = messages
        }
        let snapshotMessageIds = snapshotMessages.map(\.id)
        let snapshotItemIds = snapshotItemsWithDateSeparators(from: snapshotMessages)
        StreamSwitchTiming.log(
            "materialization_plan stage=\(materializationPlan.stage.rawValue) items=\(snapshotItemIds.count) total=\(messageCount)",
            sessionKey: effectiveSessionKey
        )
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(snapshotItemIds)
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
        StreamSwitchTiming.log("snapshot_build_end", sessionKey: effectiveSessionKey)

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

        let materializedIdSet = Set(snapshotMessageIds)
        let changedIds = (needsFullLayout
            ? fullMessageIds
            : newFingerprints.compactMap { id, fingerprint in
                fingerprints[id] == fingerprint ? nil : id
            }).filter { materializedIdSet.contains($0) }
        if !changedIds.isEmpty {
            snapshot.reconfigureItems(changedIds)
            changedIds.forEach { id in
                let plan = invalidateFor(reason: .messageChanged(id: id))
                executeInvalidationPlan(plan)
            }
            changedIds.forEach { invalidateBubbleSizingV2Cache(for: $0) }
            removeBubbleV2PreviewVersions(for: changedIds)
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
            guard self.callbackSessionKey() == effectiveSessionKey else { return }
            let runtimeState = self.readState(for: effectiveSessionKey)
            if Self.shouldScheduleBottomFallbackAfterApply(
                hasPendingRestoreState: runtimeState.pendingScrollRestoreState != nil,
                restorePhaseIsNone: runtimeState.restorePhase == .none,
                isIncrementalAppend: isIncrementalAppend,
                previousLastMessageId: previousLastMessageId
            ) {
                self.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: false, attempts: 1)
            }
            self.scheduleRestoreAttemptOnMessageAppearance(
                sessionKey: effectiveSessionKey,
                stage: materializationPlan.stage,
                snapshotMessageIds: snapshotMessageIds
            )
            if materializationPlan.scheduleTailToFullPromotion {
                self.scheduleTailToFullPromotionIfNeeded(sessionKey: effectiveSessionKey)
            }
            if shouldAutoScrollToBottomAfterApply {
                // Race-sensitive: the contentSize can change again after diffable applies.
                // A few post-apply attempts preserves the historical “always end up at the bottom” behavior.
                self.scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true, attempts: 3)
            }
            self.fireRegisteredMessageLoadCallbacksIfMaterialized(
                for: effectiveSessionKey,
                messageIds: snapshotMessageIds
            )
            // Stream-switch engine activation completion is defined as:
            // first active-page snapshot materialization after engineActiveSessionKey commit.
            // This is the point where ChatView can safely clear the spinner gate.
            if self.isActiveSession {
                viewModel.markEngineActivationRenderedIfNeeded(for: effectiveSessionKey)
            }
        }
        // Spec requires explicit contentOffset compensation for tail->full prepend.
        // This anchor path captures (messageId, oldFrameMinY, oldContentOffsetY), then applies:
        // contentOffset.y += (newFrameMinY - oldFrameMinY), clamped to bounds, with no animated scroll.
        let expansionAnchor = materializationPlan.isTailToFullExpansionApply
            ? captureBubbleSizingV2ViewportAnchor()
            : nil

        if shouldMorph {
            isSnapshotApplyInFlight = true
#if os(visionOS)
            StreamSwitchTiming.log("dataSource_apply_start", sessionKey: effectiveSessionKey)
            applySnapshotWithTypingMorphIfPossible(snapshot: snapshot, targetMessageId: newestMessageId) { [weak self] in
                afterSnapshotApplied()
                self?.scheduleBubbleSizingV2ViewportAnchorCompensation(expansionAnchor)
                self?.updateVisibleCellOpacity()
                StreamSwitchTiming.log("dataSource_apply_end", sessionKey: effectiveSessionKey)
                self?.isSnapshotApplyInFlight = false
                self?.drainQueuedUpdateIfPossible()
            }
#else
            StreamSwitchTiming.log("dataSource_apply_start", sessionKey: effectiveSessionKey)
            applySnapshotWithTypingMorphIfPossible(snapshot: snapshot, targetMessageId: newestMessageId) { [weak self] in
                afterSnapshotApplied()
                self?.scheduleBubbleSizingV2ViewportAnchorCompensation(expansionAnchor)
                StreamSwitchTiming.log("dataSource_apply_end", sessionKey: effectiveSessionKey)
                self?.isSnapshotApplyInFlight = false
                self?.drainQueuedUpdateIfPossible()
            }
#endif
        } else {
            isSnapshotApplyInFlight = true
#if os(visionOS)
            StreamSwitchTiming.log("dataSource_apply_start", sessionKey: effectiveSessionKey)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                afterSnapshotApplied()
                self?.scheduleBubbleSizingV2ViewportAnchorCompensation(expansionAnchor)
                self?.updateVisibleCellOpacity()
                StreamSwitchTiming.log("dataSource_apply_end", sessionKey: effectiveSessionKey)
                self?.isSnapshotApplyInFlight = false
                self?.drainQueuedUpdateIfPossible()
            }
#else
            StreamSwitchTiming.log("dataSource_apply_start", sessionKey: effectiveSessionKey)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                afterSnapshotApplied()
                self?.scheduleBubbleSizingV2ViewportAnchorCompensation(expansionAnchor)
                StreamSwitchTiming.log("dataSource_apply_end", sessionKey: effectiveSessionKey)
                self?.isSnapshotApplyInFlight = false
                self?.drainQueuedUpdateIfPossible()
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
                        scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true, attempts: 3)
                    }
                } else {
                    emit(.didReceiveNewMessagesWhileScrolledUp(sessionKey: effectiveSessionKey, newMessageIDs: appendedMessageIDs))
                }
            } else if !wasUserInteracting {
                // T036: On cold start, restore the last scroll position instead of forcing a reset-to-bottom.
                // For actual stream swaps/resets without a persisted anchor, default to bottom.
                if let pendingScrollRestoreState {
                    if pendingScrollRestoreState.atBottom {
                        scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true)
                    }
                } else if previousLastMessageId != nil {
                    // Preserve prior behavior on resets/stream swaps: default to bottom when the last id changes
                    // but we can't reliably classify it as an incremental append.
                    scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true)
                }
            }
        } else if typingIndicatorJustAppeared {
            // Only keep the typing indicator visible if the user is already pinned near the bottom.
            if wasPinnedToBottomIntent && !wasUserInteracting {
                scheduleScrollToBottom(sessionKey: effectiveSessionKey, animated: true)
            } else if wasPinnedToBottomIntent && wasUserInteracting {
                // Defer the scroll; never show the SBB while within the at-bottom threshold.
                pendingScrollToBottomAfterInteractionEnd = true
            }
        }
        withBoundSessionKey(effectiveSessionKey) {
            syncUnreadStateWithSBBState()
            handleContentUpdateCompletion()
        }
        NSLog("[KBTIMING] MFCV.update DONE dt=%.4f", CFAbsoluteTimeGetCurrent() - t0)
    }

    static func appendedMessageIDs(previousLastMessageId: String?, messageIDs: [String]) -> [String] {
        guard let previousLastMessageId else { return [] }
        guard let idx = messageIDs.firstIndex(of: previousLastMessageId) else { return [] }
        let next = messageIDs.index(after: idx)
        guard next < messageIDs.endIndex else { return [] }
        return Array(messageIDs[next...])
    }

    static func shouldScheduleBottomFallbackAfterApply(
        hasPendingRestoreState: Bool,
        restorePhaseIsNone: Bool,
        isIncrementalAppend: Bool,
        previousLastMessageId: String?
    ) -> Bool {
        guard !hasPendingRestoreState, restorePhaseIsNone else { return false }
        // Guardrail: a plain append must not force-jump to bottom while reading history.
        guard !isIncrementalAppend else { return false }
        // Keep the one-time initial bottom placement behavior for first population only.
        return previousLastMessageId == nil
    }

    private func isNonMessageItemID(_ id: String) -> Bool {
        id == TypingIndicatorCell.itemId || DateSeparatorCell.isDateSeparatorItemID(id)
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
            let dayStart = calendar.startOfDay(for: message.timestamp)
            if let previousDayStart, !calendar.isDate(dayStart, inSameDayAs: previousDayStart) {
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

    private static func dateSeparatorText(for day: Date, now: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(day) {
            return relativeDayFormatter.string(from: day)
        }
        if calendar.isDateInYesterday(day) {
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
        if isUserInteracting && suspendScrollPersistenceUntilRestoreConfirmed {
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
           distanceFromBottomClamped() <= Self.atBottomThreshold {
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
            let materializationState = materializationStateBySessionKey[sessionKey]
            if materializationState?.stage == .tail,
               materializationState?.unreadOutsideTailWindow == true {
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
        scheduleScrollToBottom(sessionKey: sessionKey, animated: true, attempts: 3)
    }

    private func runStreamContextSwitchSeam(incomingSessionKey: String, forceReReadGeneration: Int) {
        guard !incomingSessionKey.isEmpty else { return }

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
            // Same-key re-read must seed restore from the latest live position for this stream.
            // Without this flush, reconnect-triggered re-read can replay a stale persisted anchor.
            persistScrollStateNow(sessionKey: incomingSessionKey, bypassSuspension: true)
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

    private func persistScrollSnapshot(_ snapshot: ScrollSnapshot, for persistenceKey: String) {
        let state = PersistedScrollState(
            atBottom: snapshot.atBottom,
            distanceFromBottom: Double(snapshot.distanceFromBottom),
            savedAtEpochSeconds: snapshot.timestamp
        )
        do {
            let data = try JSONEncoder().encode(state)
            let key = scrollStateDefaultsKey(for: persistenceKey)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.error("failed encoding scrollState key=\(persistenceKey, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func liveScrollSnapshotIfAvailable() -> ScrollSnapshot? {
        guard collectionView != nil else { return nil }
        guard collectionView.contentSize.height > 0 else { return nil }
        let contentInset = collectionView.contentInset
        let minY = -contentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
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
            let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
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
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
        guard maxY.isFinite, minY.isFinite else { return }

        let desiredDistance = persistedState.atBottom ? 0 : CGFloat(persistedState.distanceFromBottom)
        let targetY = maxY - desiredDistance
        let clampedTargetY = min(max(targetY, minY), maxY)
        StreamSwitchTiming.log(
            "scroll_restore_attempt phase=\(String(describing: runtimeState.restorePhase)) stage=\(token.stage.rawValue) generation=\(token.generation) targetY=\(String(format: "%.1f", clampedTargetY)) desiredDistance=\(String(format: "%.1f", desiredDistance)) atBottomTarget=\(persistedState.atBottom)",
            sessionKey: token.sessionKey
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedTargetY), animated: false)
        refreshLastKnownScrollSnapshot(sessionKey: token.sessionKey)

        let actualDistance = distanceFromBottomClamped()
        let isAtBottomNow = actualDistance <= Self.atBottomThreshold
        let restoreConfirmed: Bool = {
            if persistedState.atBottom {
                return isAtBottomNow
            }
            return abs(actualDistance - desiredDistance) <= Self.atBottomThreshold
        }()

        if restoreConfirmed, token.stage == .tail {
            mutateState(for: token.sessionKey) { state in
                state.restorePhase = .pendingFullConfirmation
                state.restoreConfirmationRetries = 0
            }
            return
        }

        if restoreConfirmed {
            let unread = runtimeState.unreadCount
            mutateState(for: token.sessionKey) { state in
                state.restoredScrollGenerations.insert(token.generation)
                state.restorePhase = .confirmed
                state.restoreConfirmationRetries = 0
                state.suspendScrollPersistenceUntilRestoreConfirmed = false
                state.pendingScrollRestoreState = nil
                state.sbbState = isAtBottomNow ? .atBottom : (unread > 0 ? .scrolledUpUnread : .scrolledUp)
            }
            StreamSwitchTiming.log(
                "scroll_restore_confirmed stage=\(token.stage.rawValue) generation=\(token.generation) actualDistance=\(String(format: "%.1f", actualDistance)) atBottomNow=\(isAtBottomNow)",
                sessionKey: token.sessionKey
            )
            emitHideIndicatorIfChanged(force: true)
            return
        }

        if token.stage == .tail {
            mutateState(for: token.sessionKey) { state in
                state.restorePhase = .pendingFullConfirmation
            }
            return
        }

        var shouldFallbackToBottom = false
        mutateState(for: token.sessionKey) { state in
            state.restorePhase = .pendingFullConfirmation
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

        if shouldFallbackToBottom {
            collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
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
        collectionView.register(DateSeparatorCell.self, forCellWithReuseIdentifier: DateSeparatorCell.reuseIdentifier)

        view.addSubview(collectionView)
        // Frame will be set in viewDidLayoutSubviews to extend to window bounds
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

            // Handle typing indicator
            if id == TypingIndicatorCell.itemId {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TypingIndicatorCell.reuseIdentifier,
                    for: indexPath
                ) as? TypingIndicatorCell
                let metrics = ChatFlowTheme.Metrics(isCompact: self.isCompact)
                let storageKey = viewModel.typingSessionKey ?? viewModel.engineActiveSessionKey
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
            let allowsOuterScroll = (sizeClass == .long)
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
            if self.bubbleSizingV2Enabled {
                let failureReason = viewModel.failureMessage(for: message.id)
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
                bubbleHeightPolicyForConfigure = plan.heightPolicy
            } else {
                layoutStateV2 = nil
                // Use cached size width for consistent sizing with measurement
                configureWidth = self.cachedWidth(for: id) ?? maxWidth
                truncationHeightOverrideV1 = fallbackHeightPolicy.v1TruncationHeightOverride
                bubbleHeightPolicyForConfigure = fallbackHeightPolicy
            }
            cell?.configure(
                message: message,
                presentation: presentation,
                failureReason: viewModel.failureMessage(for: message.id),
                isCompact: self.isCompact,
                maxWidth: configureWidth,
                bubbleHeightPolicy: bubbleHeightPolicyForConfigure,
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
        guard let morphToken = activeSessionGenerationToken() else {
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
                            self.scheduleScrollToBottom(sessionKey: sessionKey, animated: false, attempts: 3)
                        }
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
        let envInvalidationPlan = invalidateFor(reason: .envChanged)
        executeInvalidationPlan(envInvalidationPlan)
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
        let metrics = ChatFlowTheme.Metrics(isCompact: isCompact)
        let env = bubbleSizingV2Environment(metrics: metrics)

        if DateSeparatorCell.isDateSeparatorItemID(id) {
            let rowWidth = effectiveContentWidth(metrics: metrics)
            let lineHeight = UIFont.clawline(.uiLabel, weight: .semibold).lineHeight
            return CGSize(
                width: rowWidth,
                height: ceil(lineHeight + DateSeparatorCell.topPadding + DateSeparatorCell.bottomPadding)
            )
        }

        // Handle typing indicator size
        if id == TypingIndicatorCell.itemId {
            let storageKey = viewModel.typingSessionKey ?? viewModel.engineActiveSessionKey
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
            let presentation = viewModel.presentation(for: message, metrics: metrics)
            let hideHeader = shouldHideHeader(for: message, presentation: presentation)
            let failureReason = viewModel.failureMessage(for: message.id)
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
        let failureReason = viewModel.failureMessage(for: message.id)
        let bubbleHeightPolicy = bubbleHeightPolicyForPresentation(
            presentation: presentation,
            metrics: metrics,
            env: env,
            allowsOuterScroll: sizeClass == .long
        )
        let measuredSize = measureUIKitBubbleSize(
            message: message,
            presentation: presentation,
            failureReason: failureReason,
            maxWidth: maxWidth,
            bubbleHeightPolicy: bubbleHeightPolicy,
            showsHeader: !hideHeader
        )
        _ = writeMeasuredSize(messageId: id, measurement: measuredSize)
        return measuredSize
    }

    private func measureUIKitBubbleSize(message: Message,
                                        presentation: MessagePresentation,
                                        failureReason: String?,
                                        maxWidth: CGFloat,
                                        bubbleHeightPolicy: BubbleSizingV2.BubbleHeightPolicy? = nil,
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
            bubbleHeightPolicy: bubbleHeightPolicy,
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
        let policyTruncationCap = bubbleHeightPolicy?.v1TruncationHeightOverride ?? truncationHeightOverride
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
                                   showsHeader: Bool) -> BubbleSizingV2.Plan {
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
                return max(env.containerWidth * 0.25, 80)
            case .long:
                return 80
            }
        }()

        // Design-system: only "large" (.long) bubbles get truncation/outer-scroll behavior.
        // Short/medium bubbles should grow to content (no truncation chrome), even with Dynamic Type.
        let allowsOuterScroll = (sizeClass == .long)
        let heightPolicy = bubbleHeightPolicyForPresentation(
            presentation: presentation,
            metrics: metrics,
            env: env,
            allowsOuterScroll: allowsOuterScroll
        )

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
            heightPolicy: heightPolicy,
            allowsOuterScroll: allowsOuterScroll,
            linkPreviewURL: linkPreviewURL
        )
    }

    private func linkPreviewViewportMaxHeight(plan: BubbleSizingV2.Plan) -> CGFloat {
        return plan.heightPolicy.linkPreviewViewportMaxHeight
    }

    private func bubbleSizingV2LayoutState(message: Message,
                                          presentation: MessagePresentation,
                                          metrics: ChatFlowTheme.Metrics,
                                          env: BubbleSizingV2.Environment,
                                          plan: BubbleSizingV2.Plan,
                                          failureReason: String?,
                                          showsHeader: Bool) -> BubbleSizingV2.LayoutState {
        let initialLinkVersion: Int = bubbleV2PreviewVersion(for: message.id)
        let layoutFingerprintSeed = bubbleSizingV2LayoutFingerprintSeed(
            plan: plan,
            showsHeader: showsHeader,
            hasFailureBadge: failureReason != nil
        )
        let key = plan.heightPolicy.measurementCacheKey(
            sessionKey: message.sessionKey,
            messageId: message.id,
            presentationFingerprint: plan.presentationFingerprint,
            layoutFingerprintSeed: layoutFingerprintSeed,
            env: env,
            linkPreviewStateVersion: initialLinkVersion
        )
        if let cached = bubbleV2Measurement(for: key) {
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
        recordBubbleV2Measurement(measured.measurement, key: key, messageId: message.id)
        return measured
    }

    private func bubbleSizingV2LayoutFingerprintSeed(plan: BubbleSizingV2.Plan,
                                                     showsHeader: Bool,
                                                     hasFailureBadge: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(plan.sizeClass)
        hasher.combine(plan.isSingleLinkPreview)
        hasher.combine(plan.isWide)
        hasher.combine(plan.maxWidth)
        hasher.combine(plan.minWidth)
        hasher.combine(plan.heightPolicy.cacheFingerprint)
        hasher.combine(plan.allowsOuterScroll)
        hasher.combine(plan.linkPreviewURL?.absoluteString ?? "")
        hasher.combine(showsHeader)
        hasher.combine(hasFailureBadge)
        return hasher.finalize()
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
        let previewMaxHeight = linkPreviewViewportMaxHeight(plan: plan)
        let fixedPreviewHeight: CGFloat? = plan.isSingleLinkPreview ? previewMaxHeight : nil
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
                                       failureReason: String?,
                                       showsHeader: Bool) -> BubbleSizingV2.LayoutState {
        // Pass 0: configure at max width so preferredWidth() can read padding and label sizes.
        uiKitBubbleSizer.configure(
            message: message,
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: plan.maxWidth,
            bubbleHeightPolicy: plan.heightPolicy,
            truncationHeightOverride: plan.heightPolicy.v1TruncationHeightOverride,
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
        let linkPreviewMaxHeight = linkPreviewViewportMaxHeight(plan: plan)
        let fixedPreviewHeight: CGFloat? = plan.isSingleLinkPreview ? linkPreviewMaxHeight : nil
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
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: measuredBubbleWidth,
            bubbleHeightPolicy: plan.heightPolicy,
            truncationHeightOverride: plan.heightPolicy.v1TruncationHeightOverride,
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
            presentation: presentation,
            sizeClass: plan.sizeClass,
            metrics: metrics,
            maxWidth: measuredBubbleWidth,
            bubbleHeightPolicy: plan.heightPolicy,
            truncationHeightOverride: plan.heightPolicy.v1TruncationHeightOverride,
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

        let outerScrollEnabled = plan.allowsOuterScroll && measured2.height > plan.heightPolicy.heightCap
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
            if let sessionKey = callbackSessionKey() {
                refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
            }
            return
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
        if !animated, let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
        NSLog("[KBTIMING] scrollToBottom animated=%d targetY=%.1f dt=%.4f", animated ? 1 : 0, clampedY, CFAbsoluteTimeGetCurrent() - t0)
    }

    func scrollToTop(animated: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        collectionView.layoutIfNeeded()
        let minY = -collectionView.contentInset.top
        if abs(collectionView.contentOffset.y - minY) <= 0.5 {
            return
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: minY), animated: animated)
        if !animated, let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
        NSLog("[KBTIMING] scrollToTop animated=%d targetY=%.1f dt=%.4f", animated ? 1 : 0, minY, CFAbsoluteTimeGetCurrent() - t0)
    }

    func scrollToMessageCentered(messageId: String, animated: Bool) {
        guard let sessionKey = callbackSessionKey() else { return }
        guard let indexPath = dataSource.indexPath(for: messageId) else {
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
        if let sessionKey = callbackSessionKey() {
            refreshLastKnownScrollSnapshot(sessionKey: sessionKey)
        }
    }

    var isUserInteracting: Bool {
        // Shared SBB interaction gate across iOS + visionOS.
        // Include deceleration so SBB state transitions do not settle mid-fling.
        collectionView.isDragging || collectionView.isTracking || collectionView.isDecelerating
    }

    var isActivelyDraggingOrTracking: Bool {
        // Keyboard dismiss + inset pinning should only follow active touch interaction.
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
        let plan = invalidateFor(reason: .messageChanged(id: messageId))
        executeInvalidationPlan(plan)
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
        _ = recordAsyncPreview(messageId: messageId, key: cacheKey, height: newHeight)

        bubbleSizingV2PendingRemeasureIds.insert(messageId)
        scheduleBubbleSizingV2Remeasure()
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
        // If the user scrolled up to read, don't reflow under their finger/eyes.
        // Also require scroll-at-rest so finger-lift + deceleration can't trigger mid-motion reflow.
        isNearBottom(extraMargin: 240) && isBubbleSizingV2ScrollAtRest()
    }

    private func scheduleBubbleSizingV2DeferredFlushAfterRest() {
        guard bubbleSizingV2Enabled else { return }
        guard bubbleSizingV2RemeasureDeferredUntilNearBottom else { return }
        guard isNearBottom(extraMargin: 240) else { return }
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
        bubbleSizingV2RemeasureBatchStartTime = nil
        guard !ids.isEmpty else { return }
        let viewportAnchor = captureBubbleSizingV2ViewportAnchor()

        for id in ids {
            invalidateBubbleSizingV2Cache(for: id)
            invalidateLayout(for: id)
            scheduleReconfigure(for: id)
        }
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

    private func captureBubbleSizingV2ViewportAnchor() -> BubbleSizingV2ViewportAnchor? {
        let visibleRect = CGRect(
            origin: collectionView.contentOffset,
            size: collectionView.bounds.size
        )
        let epsilon: CGFloat = 0.5
        let candidates = collectionView.visibleCells.compactMap { cell -> (String, CGRect)? in
            guard let indexPath = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  !isNonMessageItemID(id) else {
                return nil
            }
            let frame = cell.frame
            guard frame.minY >= visibleRect.minY + epsilon,
                  frame.maxY <= visibleRect.maxY - epsilon else {
                return nil
            }
            return (id, frame)
        }
        guard let anchor = candidates.min(by: { $0.1.minY < $1.1.minY }) else {
            return nil
        }
        return BubbleSizingV2ViewportAnchor(
            messageId: anchor.0,
            contentOffsetY: collectionView.contentOffset.y,
            frameMinY: anchor.1.minY
        )
    }

    private func scheduleBubbleSizingV2ViewportAnchorCompensation(_ anchor: BubbleSizingV2ViewportAnchor?) {
        guard let anchor else { return }
        guard let token = activeSessionGenerationToken() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.callbackSessionKey() == token.sessionKey else { return }
            guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
            self.collectionView.layoutIfNeeded()
            guard let indexPath = self.dataSource.indexPath(for: anchor.messageId),
                  let attrs = self.collectionView.layoutAttributesForItem(at: indexPath) else {
                return
            }
            let delta = attrs.frame.minY - anchor.frameMinY
            guard abs(delta) > 0.5 else { return }
            let inset = self.collectionView.contentInset
            let minY = -inset.top
            let maxY = max(minY, self.collectionView.contentSize.height - self.collectionView.bounds.height + inset.bottom)
            let targetY = max(minY, min(anchor.contentOffsetY + delta, maxY))
            guard targetY.isFinite else { return }
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
        let env = bubbleSizingV2Environment(metrics: metrics)
        let bubbleHeightPolicy = bubbleHeightPolicyForPresentation(
            presentation: presentation,
            metrics: metrics,
            env: env,
            allowsOuterScroll: sizeClass == .long
        )
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
            scheduleLayoutInvalidation()
        }
        if messageId == lastMessageId, let sessionKey = callbackSessionKey() {
            scheduleScrollToBottom(sessionKey: sessionKey, animated: false, attempts: 1)
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

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        sizeForItem(at: indexPath)
    }
}

private final class MessageFlowLayout: UICollectionViewFlowLayout {
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
        let sessionKey = collectionView.accessibilityIdentifier
        StreamSwitchTiming.log("layout_prepare_start", sessionKey: sessionKey)

        let sectionCount = collectionView.numberOfSections
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

        let itemCount = collectionView.numberOfItems(inSection: 0)
        let contentWidth = collectionView.bounds.width
        let signature = LayoutSignature(
            itemCount: itemCount,
            contentWidth: contentWidth,
            sectionInset: sectionInset,
            minimumInteritemSpacing: minimumInteritemSpacing,
            minimumLineSpacing: minimumLineSpacing
        )
        if case let .itemHeightChange(index, delta) = pendingInvalidation,
           !needsRebuild,
           cachedLayoutSignature == signature,
           applyItemHeightChange(index: index, delta: delta) {
            pendingInvalidation = .none
            cachedLayoutSignature = signature
            StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
            return
        }

        if !needsRebuild,
           let previous = cachedLayoutSignature,
           canAppendIncrementally(from: previous, to: signature),
           appendLastItem(collectionView: collectionView, signature: signature) {
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
        guard itemCount > 0, contentWidth > 0 else {
            cachedContentSize = .zero
            cachedLayoutSignature = signature
            needsRebuild = false
            StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
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
        pendingInvalidation = .none
        StreamSwitchTiming.log("layout_prepare_end", sessionKey: sessionKey)
        NSLog("[KBTIMING] FlowLayout.prepare items=%d dt=%.4f", itemCount, CFAbsoluteTimeGetCurrent() - t0)
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
            y = rowMinY + rowHeight + minimumLineSpacing
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
        guard abs(delta) > 0.5 else { return true }
        let indexPath = IndexPath(item: index, section: 0)
        guard let attributes = cachedAttributes[indexPath] else { return false }

        let oldFrame = attributes.frame
        let rowMinY = oldFrame.minY
        let rowAttributes = cachedAttributes.values.filter { abs($0.frame.minY - rowMinY) <= 0.5 }
        let oldRowHeight = rowAttributes.map(\.frame.height).max() ?? oldFrame.height
        let newHeight = max(1, oldFrame.height + delta)
        attributes.frame = CGRect(x: oldFrame.minX, y: oldFrame.minY, width: oldFrame.width, height: newHeight)
        let newRowHeight = rowAttributes.map(\.frame.height).max() ?? newHeight
        let rowDelta = newRowHeight - oldRowHeight
        guard abs(rowDelta) > 0.5 else { return true }

        for entry in cachedAttributes where entry.key != indexPath && entry.value.frame.minY > rowMinY + 0.5 {
            var frame = entry.value.frame
            frame.origin.y += rowDelta
            entry.value.frame = frame
        }
        cachedContentSize.height += rowDelta
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
        case .itemHeightChange(let index, let delta):
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
