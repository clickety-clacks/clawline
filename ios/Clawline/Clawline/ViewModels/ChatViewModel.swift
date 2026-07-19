//
//  ChatViewModel.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation
import OSLog
import UIKit

enum SendButtonConnectionState: Equatable {
    case connected
    case reconnecting
    case disconnected
}

struct CrossChatAssistantNotificationEntry: Identifiable, Equatable {
    let id: String
    var content: String
    var timestamp: Date
    var streaming: Bool = false
    var notificationSequence: UInt64 = 0
    var appendSeparatorTimestamp: Date? = nil
}

struct CrossChatNotificationBubble: Identifiable, Equatable {
    var id: String { sourceChatId }
    let sourceChatId: String
    var sourceTitle: String
    var entries: [CrossChatAssistantNotificationEntry]
    var lastAssistantActivityAt: Date
    var isReplying: Bool = false
    var replyDraft: String = ""
}

typealias CrossChatNotificationDismissAnimator = (_ updates: @escaping () -> Void) -> Void

struct NotificationBatchCommitCoordinator {
    struct Candidate {
        let messageId: String
        let sourceChatId: String
        let role: Message.Role?
        let content: String
        let timestamp: Date
        let streaming: Bool
        let sourceTitle: String
        let notificationSequence: UInt64?
    }

    private struct PendingBatch {
        var bubblesBySourceChatId: [String: CrossChatNotificationBubble]
        var dismissalSequenceBySourceChatId: [String: UInt64] = [:]
        let scope: Set<String>?
        let waitsForTruncationBoundary: Bool
    }

    private var pendingBatchByEpoch: [Int: PendingBatch] = [:]
    private var mutationSequence: UInt64 = 0

    mutating func begin(epoch: Int, scope: Set<String>? = nil, waitsForTruncationBoundary: Bool) {
        pendingBatchByEpoch[epoch] = PendingBatch(
            bubblesBySourceChatId: [:],
            scope: scope,
            waitsForTruncationBoundary: waitsForTruncationBoundary
        )
    }

    func contains(epoch: Int, sourceChatId: String? = nil) -> Bool {
        guard let batch = pendingBatchByEpoch[epoch] else { return false }
        guard let sourceChatId, let scope = batch.scope else { return true }
        return scope.contains(sourceChatId)
    }

    mutating func reserveNotificationSequence() -> UInt64 {
        mutationSequence &+= 1
        return mutationSequence
    }

    mutating func applyLiveCandidate(
        _ candidate: Candidate,
        to committedSnapshot: inout [String: CrossChatNotificationBubble]
    ) {
        apply(candidate, into: &committedSnapshot)
    }

    mutating func collectPendingCandidate(_ candidate: Candidate, epoch: Int) {
        guard var batch = pendingBatchByEpoch[epoch] else { return }
        guard batch.scope?.contains(candidate.sourceChatId) ?? true else { return }
        apply(candidate, into: &batch.bubblesBySourceChatId)
        pendingBatchByEpoch[epoch] = batch
    }

    mutating func recordDismissal(sourceChatIds: [String]) {
        guard !sourceChatIds.isEmpty else { return }
        for epoch in pendingBatchByEpoch.keys {
            for sourceChatId in sourceChatIds {
                pendingBatchByEpoch[epoch]?.dismissalSequenceBySourceChatId[sourceChatId] = mutationSequence
            }
        }
    }

    mutating func commitIfReady(
        epoch: Int,
        reachedTruncationBoundary: Bool,
        committedSnapshot: [String: CrossChatNotificationBubble],
        isEligible: (String) -> Bool,
        isEntryUnread: (String, CrossChatAssistantNotificationEntry) -> Bool = { _, _ in true },
        onSuppressedEntries: (String, [CrossChatAssistantNotificationEntry]) -> Void = { _, _ in }
    ) -> [String: CrossChatNotificationBubble]? {
        guard let batch = pendingBatchByEpoch[epoch] else { return nil }
        guard reachedTruncationBoundary || !batch.waitsForTruncationBoundary else { return nil }
        pendingBatchByEpoch.removeValue(forKey: epoch)

        var reconciledBySourceChatId = committedSnapshot
        for bubble in batch.bubblesBySourceChatId.values {
            let completedEntries = bubble.entries.filter { !$0.streaming }
            guard isEligible(bubble.sourceChatId) else {
                onSuppressedEntries(bubble.sourceChatId, completedEntries)
                continue
            }
            let dismissalSequence = batch.dismissalSequenceBySourceChatId[bubble.sourceChatId] ?? 0
            let suppressedEntries = completedEntries.filter {
                $0.notificationSequence <= dismissalSequence
                    || !isEntryUnread(bubble.sourceChatId, $0)
            }
            if !suppressedEntries.isEmpty {
                onSuppressedEntries(bubble.sourceChatId, suppressedEntries)
            }
            let finalEntries = completedEntries.filter {
                $0.notificationSequence > dismissalSequence
                    && isEntryUnread(bubble.sourceChatId, $0)
            }
            guard !finalEntries.isEmpty else { continue }

            var reconciled = bubble
            reconciled.entries = finalEntries
            reconciled.lastAssistantActivityAt = finalEntries.map(\.timestamp).max() ?? reconciled.lastAssistantActivityAt
            if let committed = committedSnapshot[bubble.sourceChatId] {
                reconciled.isReplying = committed.isReplying
                reconciled.replyDraft = committed.replyDraft
                let pendingEntryIds = Set(reconciled.entries.map(\.id))
                reconciled.entries.append(contentsOf: committed.entries.filter { !pendingEntryIds.contains($0.id) })
            }
            reconciledBySourceChatId[bubble.sourceChatId] = reconciled
        }
        return reconciledBySourceChatId
    }

    mutating func discard(epoch: Int) {
        pendingBatchByEpoch.removeValue(forKey: epoch)
    }

    mutating func discardAll(except epoch: Int? = nil) {
        if let epoch {
            pendingBatchByEpoch = pendingBatchByEpoch.filter { $0.key == epoch }
        } else {
            pendingBatchByEpoch.removeAll()
        }
    }

    private mutating func apply(
        _ candidate: Candidate,
        into bubblesBySourceChatId: inout [String: CrossChatNotificationBubble]
    ) {
        guard candidate.role == .assistant else { return }
        let sequence: UInt64
        if let candidateSequence = candidate.notificationSequence {
            sequence = candidateSequence
            mutationSequence = max(mutationSequence, candidateSequence)
        } else {
            mutationSequence &+= 1
            sequence = mutationSequence
        }
        var bubble = bubblesBySourceChatId[candidate.sourceChatId] ?? CrossChatNotificationBubble(
            sourceChatId: candidate.sourceChatId,
            sourceTitle: candidate.sourceTitle,
            entries: [],
            lastAssistantActivityAt: candidate.timestamp
        )
        bubble.sourceTitle = candidate.sourceTitle
        let existingSeparatorTimestamp = bubble.entries.first {
            $0.id == candidate.messageId
        }?.appendSeparatorTimestamp
        let appendSeparatorTimestamp = existingSeparatorTimestamp
            ?? (bubble.entries.contains { $0.id != candidate.messageId } ? candidate.timestamp : nil)
        let entry = CrossChatAssistantNotificationEntry(
            id: candidate.messageId,
            content: candidate.content,
            timestamp: candidate.timestamp,
            streaming: candidate.streaming,
            notificationSequence: sequence,
            appendSeparatorTimestamp: appendSeparatorTimestamp
        )
        if let existingIndex = bubble.entries.firstIndex(where: { $0.id == candidate.messageId }) {
            bubble.entries.remove(at: existingIndex)
        }
        bubble.entries.insert(entry, at: 0)
        bubble.lastAssistantActivityAt = candidate.timestamp
        bubblesBySourceChatId[candidate.sourceChatId] = bubble
    }
}

enum MessageSendIndicatorState: Equatable, Hashable {
    case pending
    case failed(String)
}

enum PromptProcessingStage: String, Equatable {
    case acceptedWaiting = "accepted_waiting"
    case preModel = "pre_model"
    case modelActive = "model_active"
    case toolActivity = "tool_activity"
    case completionHandoff = "completion_handoff"
    case blocked
    case failed
}

struct LiveAgentProgress: Equatable {
    let sessionKey: String
    let runId: String?
    let messageId: String?
    let seq: Int?
    let stage: PromptProcessingStage
    let summary: String
    let isFailure: Bool
}

enum ImageAttachmentPreparer {
    private static let modelAwareMaxImageDimension: CGFloat = 1568
    private static let minImageDimension: CGFloat = 512
    private static let initialJPEGQuality: CGFloat = 0.9
    private static let minJPEGQuality: CGFloat = 0.58
    private static let qualityStep: CGFloat = 0.08
    private static let resizeStep: CGFloat = 0.85
    private static let downscalePassLimit: Int = 12

    @MainActor
    static func prepareForModel(data: Data, mimeType: String) throws -> (data: Data, mimeType: String) {
        guard PendingAttachment.inlineMimeTypes.contains(mimeType.lowercased()) else {
            return (data, mimeType)
        }
        guard data.count > PendingAttachment.modelAwareMaxImageRawByteLimit else {
            return (data, mimeType)
        }
        guard let image = UIImage(data: data) else {
            return (data, mimeType)
        }

        var maxDim = modelAwareMaxImageDimension
        var quality = initialJPEGQuality
        var pass = 0

        while pass < downscalePassLimit {
            pass += 1
            if let compressed = downscaleImage(image, maxDimension: maxDim, quality: quality),
               compressed.count <= PendingAttachment.modelAwareMaxImageRawByteLimit {
                return (compressed, "image/jpeg")
            }
            if quality > minJPEGQuality {
                quality -= qualityStep
            } else {
                maxDim *= resizeStep
                quality = initialJPEGQuality
            }
            if maxDim < minImageDimension {
                break
            }
        }

        throw AttachmentError.imageTooLargeForModel
    }

    @MainActor
    private static func downscaleImage(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        let scale: CGFloat
        if size.width > size.height {
            scale = size.width > maxDimension ? maxDimension / size.width : 1
        } else {
            scale = size.height > maxDimension ? maxDimension / size.height : 1
        }
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

// MARK: - Stream Switch State
// Stream switching now uses two explicit state paths:
// - uiSelectedSessionKey: immediate, lightweight UI intent.
// - engineActiveSessionKey: debounced heavy engine activation.
//
// Both are MainActor-owned and each has one write seam:
// - uiSelectedSessionKey mutates only inside setUISelectedSessionKey(_:)
// - engineActiveSessionKey mutates only inside setEngineActiveSessionKey(_:)

@Observable
@MainActor
final class ChatViewModel {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    private let instanceId = UUID().uuidString
    @MainActor
    private static var currentConnectionOwnerId: String?
    static let missingReplyVisibleIdMessage = "Please update to the newest Clawline fork to reply to this message."
    private static let providerMaxTextMessageBytes = 65_536
    private static let liveProgressStaleTimeout: Duration = .seconds(120)
    private static let richDocumentMimeTypesNeedingPayload: Set<String> = [
        InteractiveHTMLDescriptor.mimeType,
        TerminalSessionDescriptor.mimeType
    ]

    private func coordinatorDiag(_ message: String) {
        print("[T099-COORD] \(Date().ISO8601Format()) vm=\(instanceId) \(message)")
    }

    var debugInstanceId: String { instanceId }

    private func observationStateFlags() -> String {
        #if DEBUG
        return "obsTask=\(observationTask != nil) startupTask=\(observationStartupTask != nil) transportSub=\(lifecycleTransportEventsSubscription != nil) outputsSub=\(lifecycleOutputsSubscription != nil) gateSub=\(lifecycleStartupGateDebugSubscription != nil) startupCount=\(observationStartupCount)"
        #else
        return "obsTask=\(observationTask != nil) startupTask=\(observationStartupTask != nil) transportSub=\(lifecycleTransportEventsSubscription != nil) outputsSub=\(lifecycleOutputsSubscription != nil) gateSub=\(lifecycleStartupGateDebugSubscription != nil)"
        #endif
    }

    private func ownerStateFlags() -> String {
        "isOwner=\(isConnectionOwner) currentOwner=\(Self.currentConnectionOwnerId ?? "nil") isRetired=\(isRetired) isChatVisible=\(isChatVisible) isAppInForeground=\(isAppInForeground)"
    }

    private func emitPinpointLog(event: String, origin: String, phaseHint: ConnectionLifecyclePhase? = nil) {
        let phase = phaseHint ?? connectionLifecyclePhase
        logger.info(
            "[T099-PIN] vm=\(self.instanceId, privacy: .public) event=\(event, privacy: .public) origin=\(origin, privacy: .public) phaseHint=\(String(describing: phase), privacy: .public) \(self.ownerStateFlags(), privacy: .public) \(self.observationStateFlags(), privacy: .public)"
        )
        Task { [weak self] in
            guard let self else { return }
            let actorPhase = await lifecycleCoordinator.phase
            logger.info(
                "[T099-PIN] vm=\(self.instanceId, privacy: .public) event=\(event, privacy: .public) origin=\(origin, privacy: .public) actorPhase=\(String(describing: actorPhase), privacy: .public)"
            )
        }
    }

    private var isConnectionOwner: Bool {
        Self.currentConnectionOwnerId == instanceId
    }

    private func claimConnectionOwnership(reason: String) {
        let previousOwner = Self.currentConnectionOwnerId ?? "none"
        Self.currentConnectionOwnerId = instanceId
        logger.info(
            "ChatViewModel connection-owner claim id=\(self.instanceId, privacy: .public) previous=\(previousOwner, privacy: .public) reason=\(reason, privacy: .public)"
        )
        emitPinpointLog(event: "connectionOwner_claim", origin: reason)
    }

    private func releaseConnectionOwnershipIfNeeded(reason: String) {
        guard Self.currentConnectionOwnerId == instanceId else { return }
        Self.currentConnectionOwnerId = nil
        logger.info(
            "ChatViewModel connection-owner release id=\(self.instanceId, privacy: .public) reason=\(reason, privacy: .public)"
        )
        emitPinpointLog(event: "connectionOwner_release", origin: reason)
    }
#if DEBUG
    static func resetConnectionOwnershipForTesting() {
        currentConnectionOwnerId = nil
    }
#endif
    private(set) var messages: [Message] = []
    private(set) var streamsBySessionKey: [String: StreamSession] = [:]
    private(set) var orderedSessionKeys: [String] = []
    private(set) var streamDotStateBySession: [String: StreamDotState] = [:]
    private(set) var lastReadMessageIdBySession: [String: String] = [:]
    private(set) var streamTailStateBySession: [String: StreamTailState] = [:]
    private(set) var crossChatNotificationBubblesBySourceChatId: [String: CrossChatNotificationBubble] = [:] {
        didSet { refreshCrossChatNotificationBubbles() }
    }
    private var notificationBatchCommitCoordinator = NotificationBatchCommitCoordinator()
    private var suppressedCrossChatNotificationEntryKeysBySourceChatId: [String: Set<String>] = [:]
    var crossChatNotificationDismissAnimator: CrossChatNotificationDismissAnimator?
    private var unavailableCrossChatNotificationSourceIds: Set<String> = []
    private var crossChatNotificationInteractionFrozenSourceChatId: String?
    private var deferredCrossChatNotificationMutations: [() -> Void] = []
    private var syntheticSessionKeys: Set<String> = []
    private var didRestoreActiveSessionKey = false

    enum StreamSwitchSource: Equatable {
        case pager
        case programmatic
    }

    private struct StreamSwitchCoordinator {
        let resetHandler: @MainActor () -> Void

        @MainActor
        func reset() {
            resetHandler()
        }
    }

    // UI-intent key: updates immediately on stream-switch intent.
    private(set) var uiSelectedSessionKey: String = ""
    // Engine-active key: drives expensive restore/snapshot/layout work.
    private(set) var engineActiveSessionKey: String = ""
    // Monotonic epoch used to cancel stale delayed engine activations.
    private(set) var uiSwitchEpoch: Int = 0
    // Pulse emitted synchronously with UI intent changes so ChatView can show toast/haptic.
    private(set) var uiSelectionSequence: Int = 0
    private(set) var lastUISelectedSessionKey: String?
    // Pulses for spinner lifecycle: activation start and activation completion.
    private(set) var engineActivationStartedSequence: Int = 0
    private(set) var engineActivationCompletedSequence: Int = 0
    private(set) var lastEngineActivationSessionKey: String?

    private let pagerSettleDebounce: Duration = .milliseconds(500)
    // Keep first heavy snapshot materialization away from the final pager animation frames.
    // This intentionally leaves the page blank briefly while the toast spinner communicates loading.
    private let pagerPostSettleApplyDelay: Duration = .milliseconds(40)
    private var pendingEngineActivationTask: Task<Void, Never>?
    private var pendingEngineActivationTarget: String?
    private var pendingEngineActivationEpoch: Int?
    private var engineActivationInFlightSessionKey: String?
    private var isPagerInteracting: Bool = false
    // Render policy seam:
    // `.frozen` while pager is physically moving; suppresses new heavy snapshot/layout work on all pages.
    // `.active` once pager is settled; heavy work may start again.
    var isRenderPolicyFrozen: Bool { isPagerInteracting }

    // Back-compat read-only alias while call sites migrate to explicit split keys.
    var activeSessionKey: String { engineActiveSessionKey }

    func messages(for sessionKey: String) -> [Message] {
        sessionMessages[sessionKey] ?? []
    }

    func expandedDetailMessage(for selectedMessage: Message) -> Message {
        if let sessionMessages = sessionMessages[selectedMessage.sessionKey],
           let message = sessionMessages.first(where: { $0.id == selectedMessage.id }) {
            return message
        }
        return selectedMessage
    }

    func streamDotState(for sessionKey: String) -> StreamDotState {
        streamDotStateBySession[sessionKey] ?? .inactive
    }

    func stream(for sessionKey: String) -> StreamSession? {
        streamsBySessionKey[sessionKey]
    }

    var orderedStreams: [StreamSession] {
        orderedSessionKeys.compactMap { streamsBySessionKey[$0] }
    }

    var activeStream: ChatStream {
        streamType(for: engineActiveSessionKey)
    }

    func streamType(for sessionKey: String) -> ChatStream {
        switch streamsBySessionKey[sessionKey]?.kind {
        case "dm", "global_dm":
            return .admin
        default:
            return .personal
        }
    }

    func adoptedSessionKeysForProvider() -> [String] {
        streamsBySessionKey.values
            .filter(\.adopted)
            .sorted { lhs, rhs in
                if lhs.orderIndex == rhs.orderIndex {
                    return lhs.sessionKey < rhs.sessionKey
                }
                return lhs.orderIndex < rhs.orderIndex
            }
            .map(\.sessionKey)
    }

    var canUseTrackFeature: Bool {
        auth.isAdmin
    }

    struct UntrackedSessionCandidate: Identifiable, Equatable {
        var id: String { sessionKey }
        let sessionKey: String
        let displayName: String
    }

    var untrackedSessionCandidates: [UntrackedSessionCandidate] {
        guard canUseTrackFeature else { return [] }
        return trackableSessionKeyOrder
            .filter { canTrackSession(sessionKey: $0) }
            .map { sessionKey in
                let displayName =
                    trackableSessionsBySessionKey[sessionKey]?.displayName
                    ?? streamsBySessionKey[sessionKey]?.displayName
                    ?? fallbackDisplayName(for: sessionKey)
                return UntrackedSessionCandidate(sessionKey: sessionKey, displayName: displayName)
            }
    }

    // MARK: Stream Switch API
    // All switch mutations are MainActor-only by class annotation.
    // Steps 1-5 are intentionally synchronous (no suspension points) to keep epoch capture atomic.

    func bindStreamSwitchCoordinatorIfNeeded() {
        if uiSelectedSessionKey.isEmpty {
            setUISelectedSessionKey(engineActiveSessionKey)
        }
    }

    func requestStreamSwitch(
        to sessionKey: String,
        source: StreamSwitchSource
    ) {
        guard orderedSessionKeys.contains(sessionKey) else { return }
        dismissCrossChatNotification(sourceChatId: sessionKey)

        // Step 1-2: stream-switch intent + epoch bump.
        uiSwitchEpoch &+= 1
        let epoch = uiSwitchEpoch

        // Step 3-4: UI path mutates immediately and emits instant feedback pulse.
        setUISelectedSessionKey(sessionKey)
        lastUISelectedSessionKey = sessionKey
        uiSelectionSequence &+= 1
        StreamSwitchTiming.log("uiSelectionSequence_incremented", sessionKey: sessionKey)

        // Step 5: schedule candidate activation keyed by (target, epoch).
        pendingEngineActivationTarget = sessionKey
        pendingEngineActivationEpoch = epoch
        pendingEngineActivationTask?.cancel()
        pendingEngineActivationTask = nil
        StreamSwitchTiming.log("engine_activation_scheduled", sessionKey: sessionKey)

        switch source {
        case .programmatic:
            // Programmatic selection is intentional: commit engine immediately (no debounce).
            commitPendingEngineActivationIfCurrent(target: sessionKey, epoch: epoch)
        case .pager:
            // Pager path waits for scroll-settle signal before debounce starts.
            if !isPagerInteracting {
                scheduleDebouncedEngineActivation(target: sessionKey, epoch: epoch)
            }
        }
    }

    func requestCrossChatNotificationNavigation(to sourceChatId: String) {
        guard !sourceChatId.isEmpty else { return }
        ensureStreamEntry(for: sourceChatId)
        requestStreamSwitch(to: sourceChatId, source: .programmatic)
    }

    func streamPagerDidBeginInteraction() {
        isPagerInteracting = true
        pendingEngineActivationTask?.cancel()
        pendingEngineActivationTask = nil
    }

    func streamPagerDidSettleAtRest() {
        StreamSwitchTiming.log("pan_gesture_settled", sessionKey: pendingEngineActivationTarget ?? uiSelectedSessionKey)
        isPagerInteracting = false
        guard let target = pendingEngineActivationTarget, let epoch = pendingEngineActivationEpoch else { return }
        StreamSwitchTiming.log("engine_activation_scheduled_post_settle", sessionKey: target)
        scheduleDebouncedEngineActivation(target: target, epoch: epoch)
    }

    // MessageFlow calls this after first active-page materialization so the toast spinner can clear.
    func markEngineActivationRenderedIfNeeded(for sessionKey: String) {
        guard engineActivationInFlightSessionKey == sessionKey else { return }
        engineActivationInFlightSessionKey = nil
        engineActivationCompletedSequence &+= 1
        StreamSwitchTiming.log("engineActivationCompletedSequence_fired", sessionKey: sessionKey)
    }

    // NOTE: keep this private.
    // Engine-active key mutation seam: all writes go through this method.
    private func setEngineActiveSessionKey(_ sessionKey: String) {
        StreamSwitchTiming.log("setEngineActiveSessionKey_enter", sessionKey: sessionKey)
        if sessionKey.isEmpty {
            engineActiveSessionKey = ""
            return
        }
        guard orderedSessionKeys.contains(sessionKey) else { return }
        dismissCrossChatNotification(sourceChatId: sessionKey)
        guard engineActiveSessionKey != sessionKey else { return }
        applyActiveSessionKey(sessionKey)
        markSessionRead(sessionKey, preferServerTail: true)
        // Keep intent selection coherent for non-switch engine mutations (bootstrap/deletion fallback).
        // Stream-switch path still writes uiSelectedSessionKey explicitly before this runs.
        if uiSelectedSessionKey != sessionKey {
            setUISelectedSessionKey(sessionKey)
        }
    }

    // UI-intent key mutation seam: all UI selection writes go through this method.
    private func setUISelectedSessionKey(_ sessionKey: String) {
        uiSelectedSessionKey = sessionKey
        StreamSwitchTiming.log("uiSelectedSessionKey_set", sessionKey: sessionKey)
        cancelSessionStatusRefreshes(except: sessionKey)
        scheduleSessionStatusRefresh(for: sessionKey, reason: "uiSelectedSession")
    }

#if DEBUG
    // Explicit test-only bypass.
    func setActiveSessionKeyForTesting(_ sessionKey: String) {
        setEngineActiveSessionKey(sessionKey)
    }

    // F2 (sixth-review) deterministic disk-cache fence proof hooks.
    func triggerHistoryResetForTesting(epoch: Int) {
        handleHistoryResetRequired(epoch: epoch)
    }

    func debugBarrierGeneration(for sessionKey: String) -> Int {
        historyBarrierGenerationBySessionKey[sessionKey, default: 0]
    }

    func debugCacheFileExists(for sessionKey: String) -> Bool {
        guard let url = messageCacheURL(for: sessionKey) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func debugHasPendingPersist(for sessionKey: String) -> Bool {
        persistDebounceTasks[sessionKey] != nil
    }
#endif

    private func scheduleDebouncedEngineActivation(target: String, epoch: Int) {
        pendingEngineActivationTask?.cancel()
        pendingEngineActivationTask = Task { [weak self] in
            guard let self else { return }
            StreamSwitchTiming.log("debounce_delay_start", sessionKey: target)
            try? await Task.sleep(for: self.pagerSettleDebounce)
            guard !Task.isCancelled else { return }
            StreamSwitchTiming.log("debounce_delay_end", sessionKey: target)
            // Additional guard band after settle+debounce so `engineActiveSessionKey` commit
            // (which triggers snapshot/apply work) starts after pager motion is fully at rest.
            StreamSwitchTiming.log("post_settle_apply_delay_start", sessionKey: target)
            try? await Task.sleep(for: self.pagerPostSettleApplyDelay)
            guard !Task.isCancelled else { return }
            StreamSwitchTiming.log("post_settle_apply_delay_end", sessionKey: target)
            self.commitPendingEngineActivationIfCurrent(target: target, epoch: epoch)
        }
    }

    private func commitPendingEngineActivationIfCurrent(target: String, epoch: Int) {
        guard epoch == uiSwitchEpoch else { return }
        guard pendingEngineActivationTarget == target else { return }
        guard orderedSessionKeys.contains(target) else {
            pendingEngineActivationTarget = nil
            pendingEngineActivationEpoch = nil
            return
        }
        pendingEngineActivationTarget = nil
        pendingEngineActivationEpoch = nil
        pendingEngineActivationTask?.cancel()
        pendingEngineActivationTask = nil

        guard target != engineActiveSessionKey else { return }

        // Engine activation start pulse keeps toast spinner visible until active page finishes materializing.
        engineActivationInFlightSessionKey = target
        lastEngineActivationSessionKey = target
        engineActivationStartedSequence &+= 1
        StreamSwitchTiming.log("engineActiveSessionKey_committed", sessionKey: target)

        setEngineActiveSessionKey(target)
    }

    private func applyActiveSessionKey(_ sessionKey: String) {
        StreamSwitchTiming.log("applyActiveSessionKey_enter", sessionKey: sessionKey)
        engineActiveSessionKey = sessionKey
        restoreCachedMessagesIfNeeded(for: sessionKey)
        messages = sessionMessages[sessionKey] ?? []
        StreamSwitchTiming.log("messages_assigned", sessionKey: sessionKey)
        persistActiveSessionKey(sessionKey)
    }

    private func clearActiveSession(clearPersistedActiveSessionKey: Bool = true) {
        setEngineActiveSessionKey("")
        setUISelectedSessionKey("")
        pendingEngineActivationTarget = nil
        pendingEngineActivationEpoch = nil
        pendingEngineActivationTask?.cancel()
        pendingEngineActivationTask = nil
        engineActivationInFlightSessionKey = nil
        messages = []
        clearAllLiveProgress()
        if clearPersistedActiveSessionKey {
            streamDefaults.removeObject(forKey: activeSessionDefaultsKey())
        }
    }

    private func resetStreamSwitchState() {
        pendingEngineActivationTask?.cancel()
        pendingEngineActivationTask = nil
        pendingEngineActivationTarget = nil
        pendingEngineActivationEpoch = nil
        engineActivationInFlightSessionKey = nil
        bindStreamSwitchCoordinatorIfNeeded()
    }

    private func makeStreamSwitchCoordinator() -> StreamSwitchCoordinator {
        StreamSwitchCoordinator(resetHandler: { [weak self] in
            self?.resetStreamSwitchState()
        })
    }

    var activeSessionDisplayName: String {
        streamsBySessionKey[uiSelectedSessionKey]?.displayName ?? fallbackDisplayName(for: uiSelectedSessionKey)
    }

    var activeSessionPlaceholderText: String {
        Self.placeholderText(
            displayName: activeSessionDisplayName,
            sessionKey: uiSelectedSessionKey
        )
    }

    func sessionStatus(for sessionKey: String) -> SessionStatus? {
        sessionStatusBySessionKey[sessionStatusAuthorityKey(for: sessionKey)]
    }

    /// Whether a Tightbeam-gated session control may be applied right now. Used
    /// to keep a pending harness confirmation from driving set_harness after the
    /// gate closed.
    func canApplyTightbeamSessionControl(_ action: SessionControlAction) -> Bool {
        guard action == .setHarness else { return true }
        return isTightbeamServer
    }

    func applySessionControl(
        sessionKey: String,
        action: SessionControlAction,
        value: String? = nil,
        enabled: Bool? = nil
    ) {
        let normalizedSessionKey = sessionStatusAuthorityKey(for: sessionKey)
        guard !normalizedSessionKey.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            // Recheck the gate INSIDE the async boundary: the gate can close
            // between enqueueing this task and its execution (the modal's
            // synchronous check is not enough), and a Tightbeam-only control
            // must never post to a link that lost the feature.
            guard self.canApplyTightbeamSessionControl(action) else { return }
            do {
                let response = try await self.chatService.applySessionControl(
                    sessionKey: normalizedSessionKey,
                    action: action,
                    value: value,
                    enabled: enabled
                )
                if response.ok {
                    if let status = response.status {
                        let displayStatus = self.sessionStatusByKeepingStickyDisplayFields(
                            from: status,
                            requestedSessionKey: normalizedSessionKey
                        )
                        self.sessionStatusBySessionKey[normalizedSessionKey] = displayStatus
                        if displayStatus.sessionKey != normalizedSessionKey {
                            self.sessionStatusBySessionKey[displayStatus.sessionKey] = displayStatus
                        }
                    } else {
                        self.scheduleSessionStatusRefresh(for: normalizedSessionKey, reason: "sessionControlApplied")
                    }
                } else {
                    self.toastManager.show(response.message ?? "This session control is not supported.")
                    self.scheduleSessionStatusRefresh(for: normalizedSessionKey, reason: "sessionControlRejected")
                }
            } catch {
                self.toastManager.show(error.localizedDescription)
                self.scheduleSessionStatusRefresh(for: normalizedSessionKey, reason: "sessionControlFailed")
            }
        }
    }

    /// On-demand fetch (no caching layer): loads org-options once per tightbeam
    /// session lifetime so the footer harness picker has its options. Cleared on
    /// disconnect/logout via `resetSessionProvisioningState`.
    private var orgOptionsLoadGeneration = 0
    private var orgOptionsLoadTask: Task<Void, Never>?

    func loadOrgOptionsIfNeeded() {
        guard isTightbeamServer, orgOptions == nil, !isLoadingOrgOptions else { return }
        isLoadingOrgOptions = true
        let generation = orgOptionsLoadGeneration
        // Explicit cancellable handle: cancelled+niled on disconnect/session reset
        // and before replacement, so an in-flight fetch cannot repopulate a newer
        // session's options.
        orgOptionsLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.orgOptionsLoadGeneration == generation {
                    self.isLoadingOrgOptions = false
                    self.orgOptionsLoadTask = nil
                }
            }
            do {
                let fetched = try await self.chatService.fetchOrgOptions()
                // Boundary validation: drop if cancelled, if a reset advanced the
                // session generation, or if the gate closed while in flight.
                guard !Task.isCancelled,
                      self.orgOptionsLoadGeneration == generation,
                      self.isTightbeamServer else { return }
                self.orgOptions = fetched
            } catch {
                self.logger.info("org-options fetch failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func placeholderText(displayName: String, sessionKey: String) -> String {
        guard !sessionKey.isEmpty else { return displayName }
        return "\(displayName) — \(sessionKey)"
    }
    var inputContent: NSAttributedString = NSAttributedString() {
        didSet {
            let hasSendableContent = !inputContent.isEffectivelyEmpty
            if inputHasSendableContent != hasSendableContent {
                inputHasSendableContent = hasSendableContent
            }
            let mentionQuery = CrossChatMentionPickerLogic.query(
                inputText: inputContent.string,
                resolvedMention: nil
            )
            if inputMentionQuery != mentionQuery {
                inputMentionQuery = mentionQuery
            }
            pruneAttachmentData()
            pruneMessageReferenceData()
        }
    }
    private(set) var inputHasSendableContent = false
    private(set) var inputMentionQuery: String?
    var attachmentData: [UUID: PendingAttachment] = [:]
    private var messageReferenceData: [UUID: PendingMessageReference] = [:]
    private(set) var pendingAttachmentStageCount: Int = 0
    private var stagedAttachmentProtection: Set<UUID> = []
    private(set) var isSending: Bool = false
    private(set) var sendIndicatorRevision: Int = 0
    private(set) var isAssistantTyping: Bool = false
    private(set) var typingSessionKey: String?
    private(set) var liveProgressBySessionKey: [String: LiveAgentProgress] = [:]
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var sendButtonConnectionState: SendButtonConnectionState = .disconnected
    private(set) var inputResetToken: Int = 0
    private(set) var sendTask: Task<Void, Never>?
    var canCancelSend: Bool { isSending && !activeSendHasReachedTransport }
    /// Tracks if typing indicator was visible when a message arrives (for morph transition).
    private(set) var shouldMorphTypingIndicator: Bool = false
    private var typingIndicatorMorphTargetMessageIdBySessionKey: [String: String] = [:]
    private var isRetired = false

    private var temporarySendButtonOverride: SendButtonConnectionState?
    private var temporarySendButtonOverrideTask: Task<Void, Never>?
    private let temporarySendButtonOverrideDuration: Duration = .seconds(5)
    private var liveProgressTimeoutTasksBySessionKey: [String: Task<Void, Never>] = [:]

    private var transportSendButtonConnectionState: SendButtonConnectionState {
        switch connectionState {
        case .connected:
            return .connected
        case .connecting, .reconnecting:
            return .reconnecting
        case .disconnected, .failed:
            return .disconnected
        }
    }

    var canSend: Bool {
        pendingAttachmentStageCount == 0
            && transportSendButtonConnectionState == .connected
            && sendProvisioningState(for: engineActiveSessionKey) == .ready
            && inputHasSendableContent
    }

    let toastManager: ToastManager

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing
    private let settings: SettingsManager
    private let deviceId: String
    let terminalConnectionPool: TerminalSessionConnectionPool
    let salientHighlightService: any SalientHighlightServicing
    private var observationTask: Task<Void, Never>?
    private var observationStartupTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var hasActivatedLifecycleOwnership = false
    private var lifecycleTransportEventsSubscription: AsyncStream<LifecycleTransportEvent>?
    private var lifecycleOutputsSubscription: AsyncStream<ConnectionLifecycleOutput>?
    private var lifecycleStartupGateDebugSubscription: AsyncStream<StartupGateDebugEvent>?
    private var sessionMessages: [String: [Message]] = [:]
    private var messageListRevisionBySession: [String: Int] = [:]
    private var forceReReadGenerationBySession: [String: Int] = [:]
    private var pendingLocalMessages: [PendingLocalMessage] = []
    private var ackedPendingLocalMessageIDs: Set<String> = []
    private let lifecycleCoordinator: ConnectionLifecycleCoordinator
    private var lifecycleTransportTask: Task<Void, Never>?
    private var lifecycleOutputTask: Task<Void, Never>?
    private var connectionLifecyclePhase: ConnectionLifecyclePhase = .idle
    private var connectionStableTask: Task<Void, Never>?
    private let stableConnectionInterval: Duration = .seconds(5)
    private var activeClientMessageId: String?
    private var activeCrossChatNotificationReplySourceChatId: String?
    private var activeSendHasReachedTransport = false
    private var crossChatNotificationReplySourceByClientMessageId: [String: String] = [:]
    private var messageFailures: [String: MessageFailure] = [:]
    private var presentationCache: [PresentationCacheKey: PresentationCacheEntry] = [:]
    private var tableParseStates: [String: StreamingTableParseState] = [:]
    private var uploadedAssetIds: [UUID: String] = [:]
    private var downloadedAssetData: [String: Data] = [:]
    private let streamDefaults = UserDefaults.standard
    private var isChatVisible = false
    private var isAppInForeground = false
    private let assistantIncomingHapticDebounceInterval: TimeInterval = 1
    private var lastAssistantIncomingHapticAt: Date?
    private let nowProvider: () -> Date
    private let assistantIncomingHaptic: @MainActor () -> Void
    private var persistDebounceTasks: [String: Task<Void, Never>] = [:]
    private var pendingPersistPayloads: [String: [Message]] = [:]
    private var restoreTaskBySessionKey: [String: Task<Void, Never>] = [:]
    /// Monotonic per-stream barrier generation. `stream_history_cleared` bumps
    /// it; every async producer of pre-barrier material (cache restores,
    /// debounced persist writes) captures the generation when it starts and is
    /// discarded on completion if the generation moved. This is the structural
    /// guarantee that a barrier can never be crossed by in-flight work,
    /// independent of task timing (spec §T-A: post-barrier replay is the only
    /// truth).
    private var historyBarrierGenerationBySessionKey: [String: Int] = [:]
    /// Serial executor for message-cache file mutations. The cache files live at
    /// one process-wide Application Support path, so ordering must hold ACROSS
    /// view-model instances (overlapping/replaced ones), not just within one.
    /// Injected so tests can substitute or drain it deterministically.
    private let messageCacheIO: any MessageCacheIOServicing
    /// All message-cache file mutations (writes and deletes) run through the
    /// injected `messageCacheIO`, so a barrier's cache delete is strictly
    /// ordered after any previously enqueued write — a detached write can never
    /// land after the delete and resurrect pre-barrier history on disk. The
    /// composition root injects ONE shared instance into every view model, so
    /// ordering holds across overlapping/replaced instances (the cache files are
    /// a single process-wide resource) without any static/global state.
    private var writerCurrentEpoch: Int?
    private var firstReplayAppliedEpoch: Int?
    private var pendingHistoryResetReplay: PendingHistoryResetReplay?
#if DEBUG
    private var observationStartupCount: Int = 0
    private(set) var lifecycleDebugPhase: ConnectionLifecyclePhase = .idle
    private(set) var lifecycleDebugSignals: [LifecycleDebugSignalRecord] = []
    private(set) var lifecycleDebugObserverEvents: [LifecycleObserverDebugRecord] = []
    private(set) var lifecycleDebugStartupGateEvents: [StartupGateDebugEvent] = []
    private(set) var lifecycleDebugLastGateDecision: String = "none"
    private(set) var imageSendDebugRecords: [ImageSendDebugRecord] = []
    private(set) var imageSendLastTransportSnapshot: String = "-"
    private(set) var lifecycleDebugSequence: Int = 0
#endif
    static let messageCacheLimit = 500
    static let showOnlyUserMessagesMessageCacheLimit = 1_000
    private var showOnlyUserMessagesSessionKeys: Set<String> = []
    private var restoredSessionKeys: Set<String> = []
    private var restoredStreamMetadataForUserId: String?
    private var supportsSessionProvisioning = false
    /// Feature flags from `auth_result.features`; tightbeam-only affordances gate on this.
    private(set) var serverFeatures: Set<String> = []
    var isTightbeamServer: Bool { serverFeatures.contains("tightbeam") }
    /// Org-level options (harnesses/models/hosts/archetypes) fetched on demand
    /// from GET /api/org-options when the server is tightbeam. Feeds the footer
    /// harness picker (T1751); the creation sheet (T1750) will read the rest.
    private(set) var orgOptions: OrgOptions?
    private var isLoadingOrgOptions = false
    var orgOptionsHarnesses: [String] { orgOptions?.harnesses ?? [] }
    private var hasResolvedProvisioningCapability = true
    private var hasReceivedSessionProvisioning = false
    private var hasReceivedExplicitSessionInfo = false
    private var accessibleSessionKeys: Set<String> = []
    private var accessibleSessionKeyOrder: [String] = []
    private var trackableSessionsBySessionKey: [String: TrackableSession] = [:]
    private var trackableSessionKeyOrder: [String] = []
    private var refreshStreamsTask: Task<Void, Never>?
    private var refreshTrackableSessionsTask: Task<Void, Never>?
    private(set) var sessionStatusBySessionKey: [String: SessionStatus] = [:]
    private var runtimeSessionKeyByRoutingSessionKey: [String: String] = [:]
    private var latestStatusAuthorityClientMessageIDByRoutingSessionKey: [String: String] = [:]
    private var sessionStatusRefreshTasks: [String: Task<Void, Never>] = [:]
    private var sessionStatusFailureCountBySessionKey: [String: Int] = [:]
    private var allowsSessionStatusRefreshes = true
    private var usageFollowUpFreshnessBySessionKey: [String: SessionStatus.Display.CodexUsage.Freshness] = [:]
    private var usageFollowUpCountBySessionKey: [String: Int] = [:]
    private(set) var sessionStatusUnavailableSessionKeys: Set<String> = []
    private var pendingUntrackRecovery: StreamSession?
    private var hasLoadedTrackableSessionsOnce = false
    private var hasSurfacedInitialTrackableSessionsFailure = false
    private var pendingProvisionedSend: PendingProvisionedSend?

    func forceReReadGeneration(for sessionKey: String) -> Int {
        forceReReadGenerationBySession[sessionKey] ?? 0
    }

    func messageListRevision(for sessionKey: String) -> Int {
        messageListRevisionBySession[sessionKey] ?? 0
    }

    /// Single entry point for the server feature gate. A cold launch renders
    /// cached history and the footer BEFORE auth completes, so flipping the
    /// gate must invalidate what is already on screen — otherwise provenance
    /// chips and the harness/host footer stay missing for the whole session
    /// and only appear for content that arrives later.
    /// Event-stream entry: a `.serverFeatures` event may be delayed past an
    /// unexpected socket close or a reconnect, so its PAYLOAD must never be
    /// trusted to reopen the gate. Explicit current-link fence: the value is
    /// always re-derived from the service's authoritative feature set, which the
    /// service sets on auth success and CLEARS on disconnect. That property is a
    /// per-link invariant — the service only ever holds the current link's
    /// features — so a delayed pre-disconnect event resolves to the CURRENT
    /// link's value: empty while disconnected, the new link's features after a
    /// reconnect. The old gate can never reopen. (Proven by
    /// `delayedServerFeaturesAfterDisconnectDoesNotReopenGate` across a full
    /// disconnect -> reconnect-to-openclaw -> delayed-old-event sequence.)
    private func applyServerFeaturesFromEvent() {
        applyServerFeatures(chatService.serverFeatures)
    }

    private func applyServerFeatures(_ features: [String]) {
        let updated = Set(features)
        guard updated != serverFeatures else { return }
        let wasTightbeam = serverFeatures.contains("tightbeam")
        serverFeatures = updated
        presentationCache.removeAll()
        for key in sessionMessages.keys {
            armForceReRead(for: key)
        }
        armForceReRead(for: uiSelectedSessionKey)
        if wasTightbeam, !isTightbeamServer {
            // The gate just closed: invalidate any in-flight org-options load and
            // drop cached options so a stale fetch cannot land in a later session.
            orgOptionsLoadGeneration &+= 1
            orgOptionsLoadTask?.cancel()
            orgOptionsLoadTask = nil
            isLoadingOrgOptions = false
            orgOptions = nil
        }
        loadOrgOptionsIfNeeded()
    }

    private func armForceReRead(for sessionKey: String) {
        guard !sessionKey.isEmpty else { return }
        forceReReadGenerationBySession[sessionKey, default: 0] &+= 1
    }

    private struct PendingLocalMessage: Equatable {
        let id: String
        let sessionKey: String
    }

    private struct PendingProvisionedSend {
        let clientId: String
        let content: String
        let attachments: [PendingAttachment]
        let references: [MessageReferenceContext]
        let replyToMessageId: String?
        let replyToClientMessageId: String?
        let sessionKey: String
        let crossChatNotificationReplySourceChatId: String?
    }

    private struct PendingHistoryResetReplay {
        let epoch: Int
        let cursorBackedSessionKeys: Set<String>
        var messagesBySessionKey: [String: [Message]] = [:]
        var notificationSequenceByMessageId: [String: UInt64] = [:]
    }

    private struct MessageSourceFlags {
        let isServer: Bool
        let isCache: Bool

        static let local = MessageSourceFlags(isServer: false, isCache: false)
        static let server = MessageSourceFlags(isServer: true, isCache: false)
        static let cache = MessageSourceFlags(isServer: false, isCache: true)
    }

    private func bumpSendIndicatorRevision() {
        sendIndicatorRevision &+= 1
    }

#if DEBUG
    enum ImageSendDebugEventKind: String, Equatable {
        case attachmentAdded = "attachment_added"
        case attachmentStagingStarted = "attachment_staging_started"
        case attachmentStagingCompleted = "attachment_staging_completed"
        case sendTapped = "send_tapped"
        case sendDispatched = "send_dispatched"
        case sendResult = "send_result"
    }

    struct ImageSendDebugRecord: Equatable, Identifiable {
        let id = UUID()
        let kind: ImageSendDebugEventKind
        let timestamp: Date
        let detail: String
    }

    enum LifecycleDebugSignal: String, Equatable {
        case authChangedToken = "authChanged(token)"
        case authChangedNil = "authChanged(nil)"
        case viewAppeared = "viewAppeared"
        case sceneActivated = "sceneActivated"
    }

    struct LifecycleDebugSignalRecord: Equatable, Identifiable {
        let id = UUID()
        let signal: LifecycleDebugSignal
        let timestamp: Date
    }

    enum LifecycleObserverDebugEvent: String, Equatable {
        case onDisappear = "onDisappear"
        case startObservingIfNeeded = "startObservingIfNeeded"
    }

    struct LifecycleObserverDebugRecord: Equatable, Identifiable {
        let id = UUID()
        let event: LifecycleObserverDebugEvent
        let timestamp: Date
        let hasObservationTask: Bool
        let hasTransportSubscription: Bool
        let hasOutputsSubscription: Bool
    }
#endif

    private enum SendProvisioningState {
        case ready
        case waiting
        case unavailable
    }

    private enum ConnectionStateMutationSource: String {
        case lifecycleCoordinator
    }

#if DEBUG
    private func recordLifecycleDebugSignal(_ signal: LifecycleDebugSignal) {
        if signal == .authChangedToken {
            lifecycleDebugSignals.removeAll(keepingCapacity: true)
            lifecycleDebugObserverEvents.removeAll(keepingCapacity: true)
            lifecycleDebugStartupGateEvents.removeAll(keepingCapacity: true)
            lifecycleDebugLastGateDecision = "none"
            imageSendDebugRecords.removeAll(keepingCapacity: true)
            imageSendLastTransportSnapshot = "-"
        }
        lifecycleDebugSignals.append(.init(signal: signal, timestamp: Date()))
        if lifecycleDebugSignals.count > 12 {
            lifecycleDebugSignals.removeFirst(lifecycleDebugSignals.count - 12)
        }
        lifecycleDebugSequence &+= 1
    }

    private func recordImageSendDebugEvent(_ kind: ImageSendDebugEventKind, detail: String) {
        imageSendDebugRecords.append(.init(kind: kind, timestamp: Date(), detail: detail))
        if imageSendDebugRecords.count > 12 {
            imageSendDebugRecords.removeFirst(imageSendDebugRecords.count - 12)
        }
        lifecycleDebugSequence &+= 1
    }

    private func recordLifecycleDebugPhase(_ phase: ConnectionLifecyclePhase) {
        lifecycleDebugPhase = phase
        lifecycleDebugSequence &+= 1
    }

    private func recordLifecycleObserverDebugEvent(_ event: LifecycleObserverDebugEvent) {
        lifecycleDebugObserverEvents.append(
            .init(
                event: event,
                timestamp: Date(),
                hasObservationTask: observationTask != nil,
                hasTransportSubscription: lifecycleTransportEventsSubscription != nil,
                hasOutputsSubscription: lifecycleOutputsSubscription != nil
            )
        )
        if lifecycleDebugObserverEvents.count > 12 {
            lifecycleDebugObserverEvents.removeFirst(lifecycleDebugObserverEvents.count - 12)
        }
        lifecycleDebugSequence &+= 1
    }

    private func recordLifecycleStartupGateEvent(_ event: StartupGateDebugEvent) {
        lifecycleDebugStartupGateEvents.append(event)
        if lifecycleDebugStartupGateEvents.count > 12 {
            lifecycleDebugStartupGateEvents.removeFirst(lifecycleDebugStartupGateEvents.count - 12)
        }
        switch event.kind {
        case .startIfNeededExitMissingAuthToken:
            lifecycleDebugLastGateDecision = "missing_auth_token"
        case .startIfNeededExitMissingViewAppeared:
            lifecycleDebugLastGateDecision = "missing_view_appeared"
        default:
            break
        }
        lifecycleDebugSequence &+= 1
    }
#endif

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying,
         uploadService: any UploadServicing,
         toastManager: ToastManager,
         salientHighlightService: any SalientHighlightServicing,
         messageCacheIO: any MessageCacheIOServicing = MessageCacheIO(),
         connectionAlertGracePeriod: Duration = .seconds(2),
         nowProvider: @escaping () -> Date = Date.init,
         assistantIncomingHaptic: @escaping @MainActor () -> Void = {
             #if !os(visionOS)
             let generator = UIImpactFeedbackGenerator(style: .light)
             generator.impactOccurred()
             #endif
         }) {
        logger.info("ChatViewModel init id=\(self.instanceId, privacy: .public)")
        self.messageCacheIO = messageCacheIO
        self.auth = auth
        self.chatService = chatService
        self.settings = settings
        self.deviceId = device.deviceId
        self.uploadService = uploadService
        self.terminalConnectionPool = TerminalSessionConnectionPool { descriptor in
            TerminalSessionService(descriptor: descriptor, auth: auth, deviceId: device)
        }
        self.toastManager = toastManager
        self.salientHighlightService = salientHighlightService
        self.lifecycleCoordinator = ConnectionLifecycleCoordinator(
            startAttempt: { [weak chatService] epoch, lastMessageId, token in
                Task { @MainActor [weak chatService] in
                    chatService?.startConnectionAttempt(epoch: epoch, lastMessageId: lastMessageId, token: token)
                }
            },
            stopAttempt: { [weak chatService] in
                Task { @MainActor [weak chatService] in
                    chatService?.stopConnectionAttempt()
                }
            }
        )
        self.nowProvider = nowProvider
        self.assistantIncomingHaptic = assistantIncomingHaptic
        _ = connectionAlertGracePeriod
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarningNotification),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthStateChangeNotification),
            name: Notification.Name("AuthStateDidChange"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackgroundNotification),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        claimConnectionOwnership(reason: "init")
    }

    deinit {
        logger.info("ChatViewModel deinit id=\(self.instanceId, privacy: .public)")
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name("AuthStateDidChange"), object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func activate(origin: String = "RootView.ensureChatViewModel") async {
        guard !isRetired else {
            coordinatorDiag("activate ignored retired-vm")
            return
        }
        guard isConnectionOwner else {
            coordinatorDiag("activate ignored non-owner")
            return
        }
        if hasActivatedLifecycleOwnership {
            coordinatorDiag("activate early-return already-activated")
            return
        }
        if let activationTask {
            coordinatorDiag("activate joining in-flight activation task")
            await activationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.coordinatorDiag("activate begin")
            await self.startObservingIfNeeded(origin: "activate[\(origin)]")
#if DEBUG
            self.recordLifecycleDebugSignal(.viewAppeared)
#endif
            await self.lifecycleCoordinator.viewAppeared()
            self.hasActivatedLifecycleOwnership = true
            self.coordinatorDiag("activate after viewAppeared -> handleAuthStateChange")
            self.handleAuthStateChange()
        }
        activationTask = task
        await task.value
        activationTask = nil
        coordinatorDiag("activate complete")
    }

    func onAppear(origin: String = "ChatView.task") async {
        guard !isRetired else {
            coordinatorDiag("onAppear ignored retired-vm")
            return
        }
        guard isConnectionOwner else {
            coordinatorDiag("onAppear ignored non-owner")
            return
        }
        coordinatorDiag("onAppear enter visibility-only tokenPresent=\(auth.token != nil)")
        emitPinpointLog(event: "onAppear_enter", origin: origin)
        isChatVisible = true
        isAppInForeground = true
        logger.info("ChatViewModel onAppear id=\(self.instanceId, privacy: .public) visibility-only")
    }

    func onDisappear(origin: String = "ChatView.onDisappear") {
#if DEBUG
        recordLifecycleObserverDebugEvent(.onDisappear)
#endif
        emitPinpointLog(event: "onDisappear_enter", origin: origin)
        logger.info("ChatViewModel onDisappear FIRED id=\(self.instanceId, privacy: .public) isChatVisible=\(self.isChatVisible) isOwner=\(self.isConnectionOwner) hasObsTask=\(self.observationTask != nil) hasTransportSub=\(self.lifecycleTransportEventsSubscription != nil) hasOutputsSub=\(self.lifecycleOutputsSubscription != nil)")
        isChatVisible = false
        logger.info("ChatViewModel onDisappear id=\(self.instanceId, privacy: .public) visibility-only")
    }

    func reconnect() {
        guard !isRetired else { return }
        guard isConnectionOwner else { return }
        guard auth.token != nil else { return }
        guard sendButtonConnectionState == .disconnected else { return }
        Task {
            await startObservingIfNeeded(origin: "reconnect")
            await lifecycleCoordinator.updateCanonicalCursor(legacyReplayCursorForActiveStream())
            await lifecycleCoordinator.manualRetry()
        }
    }

    @objc private func handleAuthStateChangeNotification() {
        handleAuthStateChange()
    }

    private func handleAuthStateChange() {
        guard !isRetired else {
            coordinatorDiag("handleAuthStateChange ignored retired-vm tokenPresent=\(auth.token != nil)")
            return
        }
        guard hasActivatedLifecycleOwnership else {
            coordinatorDiag("handleAuthStateChange deferred until activate tokenPresent=\(auth.token != nil)")
            return
        }
        guard isConnectionOwner else {
            coordinatorDiag("handleAuthStateChange ignored non-owner tokenPresent=\(auth.token != nil)")
            if auth.token == nil {
                stopObservingLifecycle(origin: "handleAuthStateChange.nonOwnerTokenNil")
            }
            return
        }
        coordinatorDiag("handleAuthStateChange enter tokenPresent=\(auth.token != nil)")
        if auth.token != nil {
            allowsSessionStatusRefreshes = true
            restoreStreamMetadataIfNeeded()
            restoreActiveSessionKeyIfNeeded()
            ensureDefaultActiveSessionIfNeeded()
            let seededCursor = legacyReplayCursorForActiveStream()
            coordinatorDiag("handleAuthStateChange auth-path seededCursor=\(seededCursor ?? "nil")")
            Task {
                self.coordinatorDiag("handleAuthStateChange task before startObservingIfNeeded")
                await self.startObservingIfNeeded(origin: "handleAuthStateChange.authPath")
                self.coordinatorDiag("handleAuthStateChange task after startObservingIfNeeded before seedCanonicalCursor")
                await lifecycleCoordinator.seedCanonicalCursor(seededCursor)
                self.coordinatorDiag("handleAuthStateChange task after seedCanonicalCursor before authChanged signal")
#if DEBUG
                self.recordLifecycleDebugSignal(.authChangedToken)
#endif
                await lifecycleCoordinator.authChanged(token: auth.token)
                self.coordinatorDiag("handleAuthStateChange task after authChanged signal")
            }
            refreshStreamsFromProvider(reason: "authChanged")
            scheduleSessionStatusRefresh(for: uiSelectedSessionKey, reason: "authChanged")
        } else {
            allowsSessionStatusRefreshes = false
            coordinatorDiag("handleAuthStateChange logout-path")
            didRestoreActiveSessionKey = false
            clearSessionStatusRefreshes()
            stopObservingLifecycle(origin: "handleAuthStateChange.logoutPath")
#if DEBUG
            recordLifecycleDebugSignal(.authChangedNil)
#endif
            Task { await lifecycleCoordinator.authChanged(token: nil) }
            chatService.disconnect()
        }
    }

    func handleSceneDidBecomeActive() {
        guard !isRetired else { return }
        guard isConnectionOwner else { return }
        isAppInForeground = true
        allowsSessionStatusRefreshes = true
        guard hasActivatedLifecycleOwnership else {
            coordinatorDiag("sceneDidBecomeActive deferred until activate")
            return
        }
        guard auth.token != nil else { return }
        logger.info("ChatViewModel sceneDidBecomeActive id=\(self.instanceId, privacy: .public) state=\(String(describing: self.connectionState), privacy: .public)")
        coordinatorDiag("sceneDidBecomeActive tokenPresent=true observationTaskNil=\(observationTask == nil)")
        scheduleSessionStatusRefresh(for: uiSelectedSessionKey, reason: "sceneDidBecomeActive")
        Task {
            self.coordinatorDiag("sceneDidBecomeActive task before startObservingIfNeeded")
            await startObservingIfNeeded(origin: "sceneDidBecomeActive")
            self.coordinatorDiag("sceneDidBecomeActive task before sceneActivated signal")
#if DEBUG
            self.recordLifecycleDebugSignal(.sceneActivated)
#endif
            await lifecycleCoordinator.sceneActivated()
            self.coordinatorDiag("sceneDidBecomeActive task after sceneActivated signal")
        }
    }

    @objc private func handleDidEnterBackgroundNotification() {
        Task { await lifecycleCoordinator.appDidEnterBackground() }
    }

    func handleSceneActiveStateChanged(isActive: Bool) {
        isAppInForeground = isActive
        guard isActive else {
            allowsSessionStatusRefreshes = false
            cancelSessionStatusRefreshes()
            return
        }
        handleSceneDidBecomeActive()
    }

    private func startObservingIfNeeded(origin: String) async {
#if DEBUG
        recordLifecycleObserverDebugEvent(.startObservingIfNeeded)
#endif
        emitPinpointLog(event: "startObserving_enter", origin: origin)
        logger.info("startObservingIfNeeded CALLED id=\(self.instanceId, privacy: .public) hasObsTask=\(self.observationTask != nil) hasTransportSub=\(self.lifecycleTransportEventsSubscription != nil)")
        guard !isRetired else {
            coordinatorDiag("startObservingIfNeeded ignored retired-vm")
            return
        }
        guard isConnectionOwner else {
            coordinatorDiag("startObservingIfNeeded ignored non-owner")
            return
        }
        coordinatorDiag("startObservingIfNeeded enter observationTaskNil=\(observationTask == nil) startupTaskNil=\(observationStartupTask == nil) transportSubNil=\(lifecycleTransportEventsSubscription == nil) outputsSubNil=\(lifecycleOutputsSubscription == nil)")
        if observationTask != nil {
            coordinatorDiag("startObservingIfNeeded early-return observationTaskExists")
            emitPinpointLog(event: "startObserving_earlyReturn_existingObservationTask", origin: origin)
            return
        }
        if let observationStartupTask {
            // Cold launch can hit this from onAppear/auth-change/scene-active concurrently.
            // Join the in-flight startup so only one observer set is ever created.
            coordinatorDiag("startObservingIfNeeded joining in-flight startup task")
            await observationStartupTask.value
            coordinatorDiag("startObservingIfNeeded joined in-flight startup task")
            emitPinpointLog(event: "startObserving_joinedExistingStartupTask", origin: origin)
            return
        }

        let startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.coordinatorDiag("startObservingIfNeeded startupTask begin")
            await self.ensureLifecycleOutputsSubscription()
            self.coordinatorDiag("startObservingIfNeeded after ensureLifecycleOutputsSubscription")
            if Task.isCancelled { return }
            await self.ensureLifecycleStartupGateDebugSubscription()
            self.coordinatorDiag("startObservingIfNeeded after ensureLifecycleStartupGateDebugSubscription")
            if Task.isCancelled { return }
            self.ensureLifecycleTransportSubscription()
            self.coordinatorDiag("startObservingIfNeeded after ensureLifecycleTransportSubscription")
            if Task.isCancelled { return }
#if DEBUG
            self.observationStartupCount += 1
#endif
            self.logger.info("ChatViewModel startObserving id=\(self.instanceId, privacy: .public)")
            self.coordinatorDiag("startObservingIfNeeded creating observationTask")
            self.observationTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        await self?.observeLifecycleTransportEvents()
                    }

                    group.addTask { [weak self] in
                        await self?.observeLifecycleOutputs()
                    }

                    group.addTask { [weak self] in
                        await self?.observeLifecycleStartupGateDebugEvents()
                    }

                    group.addTask { [weak self] in
                        await self?.observeProviderConnectionState()
                    }

                    group.addTask { [weak self] in
                        await self?.observeServiceEvents()
                    }
                }
            }
            self.emitPinpointLog(event: "startObserving_observationTaskAssigned", origin: origin)
        }
        observationStartupTask = startupTask
        await startupTask.value
        observationStartupTask = nil
        emitPinpointLog(event: "startObserving_complete", origin: origin)
        coordinatorDiag("startObservingIfNeeded complete")
    }

    private func stopObservingLifecycle(origin: String) {
        emitPinpointLog(event: "stopObserving_enter", origin: origin)
        observationStartupTask?.cancel()
        observationStartupTask = nil
        activationTask?.cancel()
        activationTask = nil
        observationTask?.cancel()
        observationTask = nil
        lifecycleTransportEventsSubscription = nil
        lifecycleOutputsSubscription = nil
        lifecycleStartupGateDebugSubscription = nil
        lifecycleTransportTask?.cancel()
        lifecycleTransportTask = nil
        lifecycleOutputTask?.cancel()
        lifecycleOutputTask = nil
        connectionStableTask?.cancel()
        connectionStableTask = nil
        emitPinpointLog(event: "stopObserving_complete", origin: origin)
    }

    func prepareForReplacement() {
        guard !isRetired else { return }
        isRetired = true
        hasActivatedLifecycleOwnership = false
        // A retired instance must not keep mutating the message cache: every
        // ChatViewModel writes the SAME Application Support files, so a pending
        // persist or in-flight restore from this instance could otherwise land
        // after a replacement instance has applied a history barrier and
        // resurrect cleared history.
        persistDebounceTasks.values.forEach { $0.cancel() }
        persistDebounceTasks.removeAll()
        pendingPersistPayloads.removeAll()
        restoreTaskBySessionKey.values.forEach { $0.cancel() }
        restoreTaskBySessionKey.removeAll()
        orgOptionsLoadTask?.cancel()
        orgOptionsLoadTask = nil
        clearSessionStatusRefreshes()
        discardCrossChatNotificationBatches()
        stopObservingLifecycle(origin: "prepareForReplacement")
        cancelSendForTeardown()
        guard isConnectionOwner else { return }
        Task { await lifecycleCoordinator.disconnectRequested() }
        chatService.disconnect()
        releaseConnectionOwnershipIfNeeded(reason: "prepareForReplacement")
    }

    private func ensureLifecycleTransportSubscription() {
        guard lifecycleTransportEventsSubscription == nil else {
            coordinatorDiag("ensureLifecycleTransportSubscription already-subscribed")
            return
        }
        // Subscribe synchronously so lifecycle transport events cannot be dropped
        // before the first coordinator startup signal dispatch.
        lifecycleTransportEventsSubscription = chatService.lifecycleTransportEvents
        coordinatorDiag("ensureLifecycleTransportSubscription created")
    }

    private func ensureLifecycleOutputsSubscription() async {
        guard lifecycleOutputsSubscription == nil else {
            coordinatorDiag("ensureLifecycleOutputsSubscription already-subscribed")
            return
        }
        // Subscribe before coordinator start paths so early lifecycle outputs are not dropped.
        lifecycleOutputsSubscription = await lifecycleCoordinator.outputs
        coordinatorDiag("ensureLifecycleOutputsSubscription created")
    }

    private func ensureLifecycleStartupGateDebugSubscription() async {
        guard lifecycleStartupGateDebugSubscription == nil else {
            coordinatorDiag("ensureLifecycleStartupGateDebugSubscription already-subscribed")
            return
        }
        lifecycleStartupGateDebugSubscription = await lifecycleCoordinator.startupGateDebugEvents
        coordinatorDiag("ensureLifecycleStartupGateDebugSubscription created")
    }

    @MainActor
    private func observeLifecycleTransportEvents() async {
        guard let lifecycleTransportEventsSubscription else { return }
        for await event in lifecycleTransportEventsSubscription {
            coordinatorDiag("observeLifecycleTransportEvents event epoch=\(event.epoch) payload=\(String(describing: event.payload))")
            await lifecycleCoordinator.handleTransportEvent(event)
        }
    }

    @MainActor
    private func observeLifecycleOutputs() async {
        guard let lifecycleOutputsSubscription else { return }
        for await output in lifecycleOutputsSubscription {
            coordinatorDiag("observeLifecycleOutputs output=\(String(describing: output))")
            await handleLifecycleOutput(output)
        }
    }

    @MainActor
    private func observeLifecycleStartupGateDebugEvents() async {
        guard let lifecycleStartupGateDebugSubscription else { return }
        for await event in lifecycleStartupGateDebugSubscription {
#if DEBUG
            recordLifecycleStartupGateEvent(event)
#endif
        }
    }

    @MainActor
    private func observeProviderConnectionState() async {
        for await state in chatService.connectionState {
            await handleProviderConnectionState(state)
        }
    }

    @MainActor
    private func handleProviderConnectionState(_ state: ConnectionState) async {
        guard state == .disconnected, connectionState == .connected else { return }
        await lifecycleCoordinator.reconnectIntentTransportInterrupted()
    }

    @MainActor
    private func observeServiceEvents() async {
        for await event in chatService.serviceEvents {
            handle(serviceEvent: event)
        }
    }

    private func sendTransportSnapshot() -> String {
        let providerReady = ProviderBaseURLStore.baseURL != nil
        let transportReady = chatService.isTransportReadyForSend
        return "connectionState=\(String(describing: connectionState)) providerReady=\(providerReady ? "1" : "0") transportReady=\(transportReady ? "1" : "0")"
    }

    private func validateTextByteLimitForSend(_ text: String) -> Bool {
        let textBytes = text.lengthOfBytes(using: .utf8)
        guard isTextWithinSendByteLimit(text) else {
#if DEBUG
            recordImageSendDebugEvent(
                .sendResult,
                detail: "failure reason=text_too_large bytes=\(textBytes) limit=\(Self.providerMaxTextMessageBytes)"
            )
#endif
            toastManager.show("That message is too large to send.")
            return false
        }
        return true
    }

    private func isTextWithinSendByteLimit(_ text: String) -> Bool {
        text.lengthOfBytes(using: .utf8) <= Self.providerMaxTextMessageBytes
    }

    private func nextClientMessageId() -> String {
        "c_\(UUID().uuidString)"
    }

    var canCancelCurrentPrompt: Bool {
        currentInFlightPromptSessionKey != nil
    }

    func canCancelVisibleTypingPrompt(in sessionKey: String) -> Bool {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return false }
        return shouldShowTypingIndicator(in: normalizedSessionKey)
    }

    func shouldShowTypingIndicator(in sessionKey: String) -> Bool {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return false }
        if isAssistantTyping, typingSessionKey == normalizedSessionKey {
            return true
        }
        guard let status = sessionStatusBySessionKey[normalizedSessionKey] else { return false }
        switch status.run.state {
        case .running, .queued:
            return true
        case .idle, .unknown:
            return false
        }
    }

    func typingIndicatorMorphTargetMessageId(in sessionKey: String) -> String? {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return nil }
        return typingIndicatorMorphTargetMessageIdBySessionKey[normalizedSessionKey]
    }

    func consumeTypingIndicatorMorphTargetMessageId(_ messageId: String?, in sessionKey: String) {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty,
              let messageId,
              typingIndicatorMorphTargetMessageIdBySessionKey[normalizedSessionKey] == messageId else {
            return
        }
        typingIndicatorMorphTargetMessageIdBySessionKey.removeValue(forKey: normalizedSessionKey)
        shouldMorphTypingIndicator = !typingIndicatorMorphTargetMessageIdBySessionKey.isEmpty
    }

    private func clearTypingIndicatorMorphTarget(for sessionKey: String) {
        typingIndicatorMorphTargetMessageIdBySessionKey.removeValue(forKey: sessionKey)
        shouldMorphTypingIndicator = !typingIndicatorMorphTargetMessageIdBySessionKey.isEmpty
    }

    private func clearAllTypingIndicatorMorphTargets() {
        typingIndicatorMorphTargetMessageIdBySessionKey.removeAll()
        shouldMorphTypingIndicator = false
    }

    func canCancelCurrentPrompt(in sessionKey: String) -> Bool {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return promptIsInFlight(in: normalizedSessionKey)
    }

    private var currentInFlightPromptSessionKey: String? {
        let candidates = [
            uiSelectedSessionKey,
            typingSessionKey,
            engineActiveSessionKey
        ]
        var seen: Set<String> = []
        for candidate in candidates {
            let sessionKey = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sessionKey.isEmpty, seen.insert(sessionKey).inserted else { continue }
            if promptIsInFlight(in: sessionKey) {
                return sessionKey
            }
        }
        return nil
    }

    private func promptIsInFlight(in sessionKey: String) -> Bool {
        guard !sessionKey.isEmpty else { return false }
        if isAssistantTyping, typingSessionKey == sessionKey {
            return true
        }
        guard let status = sessionStatusBySessionKey[sessionKey] else { return false }
        switch status.run.state {
        case .running, .queued:
            return true
        case .idle, .unknown:
            return false
        }
    }

    func requestCurrentPromptCancellation(sessionKey requestedSessionKey: String? = nil) {
        let sessionKey: String?
        if let requestedSessionKey {
            let normalizedSessionKey = requestedSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionKey = canCancelCurrentPrompt(in: normalizedSessionKey) ? normalizedSessionKey : nil
        } else {
            sessionKey = currentInFlightPromptSessionKey
        }
        guard let sessionKey else { return }
        Task { [weak self] in
            await self?.performCurrentPromptCancellation(sessionKey: sessionKey)
        }
    }

    private func performCurrentPromptCancellation(sessionKey: String) async {
        do {
            let response = try await chatService.applySessionControl(
                sessionKey: sessionKey,
                action: .cancelCurrentRun,
                value: nil,
                enabled: nil
            )
            if response.ok {
                toastManager.show(response.message ?? "Prompt cancellation requested.")
                clearLiveProgress(sessionKey: sessionKey, runId: nil, messageId: nil)
                scheduleSessionStatusRefresh(for: sessionKey, reason: "cancelCurrentPrompt")
                return
            }
            let fallback = response.code == "unsupported"
                ? "Prompt cancellation is not supported by this provider."
                : "Could not cancel current prompt."
            toastManager.show(response.message ?? fallback)
            if let status = response.status {
                sessionStatusBySessionKey[sessionKey] = status
                if status.sessionKey != sessionKey {
                    sessionStatusBySessionKey[status.sessionKey] = status
                }
            } else {
                scheduleSessionStatusRefresh(for: sessionKey, reason: "cancelCurrentPromptUnsupported")
            }
        } catch {
            toastManager.show(error.localizedDescription)
            scheduleSessionStatusRefresh(for: sessionKey, reason: "cancelCurrentPromptFailed")
        }
    }

    private(set) var crossChatNotificationBubbles: [CrossChatNotificationBubble] = []

    private func refreshCrossChatNotificationBubbles() {
        crossChatNotificationBubbles = crossChatNotificationBubblesBySourceChatId.values.sorted {
            if $0.lastAssistantActivityAt == $1.lastAssistantActivityAt {
                return $0.sourceChatId < $1.sourceChatId
            }
            return $0.lastAssistantActivityAt > $1.lastAssistantActivityAt
        }
    }

    func beginCrossChatNotificationPopupInteraction(sourceChatId: String) {
        crossChatNotificationInteractionFrozenSourceChatId = sourceChatId
    }

    func endCrossChatNotificationPopupInteraction(sourceChatId: String?) {
        guard crossChatNotificationInteractionFrozenSourceChatId == sourceChatId
                || sourceChatId == nil else {
            return
        }
        crossChatNotificationInteractionFrozenSourceChatId = nil
        let deferredMutations = deferredCrossChatNotificationMutations
        deferredCrossChatNotificationMutations = []
        for mutation in deferredMutations {
            mutation()
        }
    }

    private func deferCrossChatNotificationMutationIfNeeded(_ mutation: @escaping () -> Void) -> Bool {
        guard crossChatNotificationInteractionFrozenSourceChatId != nil else {
            return false
        }
        deferredCrossChatNotificationMutations.append(mutation)
        return true
    }

    func dismissCrossChatNotification(sourceChatId: String, markSourceRead: Bool = true) {
        if deferCrossChatNotificationMutationIfNeeded({ [weak self] in
            self?.dismissCrossChatNotification(sourceChatId: sourceChatId, markSourceRead: markSourceRead)
        }) {
            return
        }
        if markSourceRead {
            markSessionRead(sourceChatId, preferServerTail: true)
        }
        if let bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] {
            recordSuppressedCrossChatNotificationEntries(bubble.entries, sourceChatId: sourceChatId)
            notificationBatchCommitCoordinator.recordDismissal(sourceChatIds: [sourceChatId])
        }
        animateCrossChatNotificationDismissal {
            self.crossChatNotificationBubblesBySourceChatId.removeValue(forKey: sourceChatId)
        }
    }

    func dismissAllCrossChatNotifications() {
        let committedSourceChatIds = Array(crossChatNotificationBubblesBySourceChatId.keys)
        for sourceChatId in committedSourceChatIds {
            markSessionRead(sourceChatId, preferServerTail: true)
        }
        for bubble in crossChatNotificationBubblesBySourceChatId.values {
            recordSuppressedCrossChatNotificationEntries(bubble.entries, sourceChatId: bubble.sourceChatId)
        }
        notificationBatchCommitCoordinator.recordDismissal(sourceChatIds: committedSourceChatIds)
        animateCrossChatNotificationDismissal {
            self.crossChatNotificationBubblesBySourceChatId.removeAll()
        }
    }

    private func recordSuppressedCrossChatNotificationEntries(
        _ entries: [CrossChatAssistantNotificationEntry],
        sourceChatId: String
    ) {
        let keys = entries
            .filter { !$0.id.isEmpty }
            .map { suppressedCrossChatNotificationEntryKey(id: $0.id, content: $0.content) }
        guard !keys.isEmpty else { return }
        suppressedCrossChatNotificationEntryKeysBySourceChatId[sourceChatId, default: []].formUnion(keys)
        persistSuppressedCrossChatNotificationEntryKeys(for: sourceChatId)
    }

    private func recordSuppressedCrossChatNotificationEntry(_ message: Message) {
        guard !message.id.isEmpty else { return }
        let key = suppressedCrossChatNotificationEntryKey(id: message.id, content: message.content)
        suppressedCrossChatNotificationEntryKeysBySourceChatId[message.sessionKey, default: []].insert(key)
        persistSuppressedCrossChatNotificationEntryKeys(for: message.sessionKey)
    }

    private func hasSuppressedCrossChatNotificationEntry(_ message: Message) -> Bool {
        restoreSuppressedCrossChatNotificationEntryKeysIfNeeded(for: message.sessionKey)
        let key = suppressedCrossChatNotificationEntryKey(id: message.id, content: message.content)
        return suppressedCrossChatNotificationEntryKeysBySourceChatId[message.sessionKey]?.contains(key) == true
    }

    private func markSuppressedCrossChatNotificationEntryReadIfNeeded(_ message: Message) {
        guard !message.id.isEmpty else { return }
        lastReadMessageIdBySession[message.sessionKey] = message.id
        persistLastReadMessageId(message.id, for: message.sessionKey)
        recomputeStreamDotState(for: message.sessionKey)
    }

    private func suppressedCrossChatNotificationEntryKey(id: String, content: String) -> String {
        "\(id.count):\(id)\(content)"
    }

#if DEBUG
    func debugSeedCrossChatNotificationsForDockProof() {
        let now = Date()
        let mainSessionKey = SessionKey.clawlineMain(userId: auth.currentUserId ?? "debug-user")
        let alphaSessionKey = "agent:main:clawline:ui-test:s_t1174_a"
        let betaSessionKey = "agent:main:clawline:ui-test:s_t1174_b"
        let streams = [
            StreamSession(
                sessionKey: mainSessionKey,
                displayName: "T1174 Main",
                kind: "main",
                orderIndex: 0,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            ),
            StreamSession(
                sessionKey: alphaSessionKey,
                displayName: "T1174 Alpha Chat",
                kind: "custom",
                orderIndex: 1,
                isBuiltIn: false,
                createdAt: now,
                updatedAt: now,
                trackingMode: .adopted
            ),
            StreamSession(
                sessionKey: betaSessionKey,
                displayName: "T1174 Beta Chat",
                kind: "custom",
                orderIndex: 2,
                isBuiltIn: false,
                createdAt: now,
                updatedAt: now,
                trackingMode: .adopted
            )
        ]
        for stream in streams {
            streamsBySessionKey[stream.sessionKey] = stream
            syntheticSessionKeys.insert(stream.sessionKey)
        }
        let alphaMessage = Message(
            id: "s_t1174_alpha_chat_message",
            role: .assistant,
            content: "T1174 Alpha Chat proof message",
            timestamp: now,
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: alphaSessionKey,
            sender: nil
        )
        let betaMessage = Message(
            id: "s_t1174_beta_chat_message",
            role: .assistant,
            content: "T1174 Beta Chat proof message",
            timestamp: now,
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: betaSessionKey,
            sender: nil
        )
        var mainMessages = (0..<40).map { index in
            Message(
                id: "s_t1174_main_chat_message_\(index)",
                role: .assistant,
                content: "T1174 Main scroll proof message \(index)",
                timestamp: now.addingTimeInterval(TimeInterval(index - 40)),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: mainSessionKey,
                sender: nil
            )
        }
        mainMessages.append(contentsOf: [
            Message(
                id: "s_t357_landscape_incoming_message",
                role: .assistant,
                content: "T357 landscape incoming proof message",
                timestamp: now.addingTimeInterval(1),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: mainSessionKey,
                sender: nil
            ),
            Message(
                id: "s_t357_landscape_outgoing_message",
                role: .user,
                content: "T357 landscape outgoing proof message",
                timestamp: now.addingTimeInterval(2),
                streaming: false,
                attachments: [],
                deviceId: nil,
                sessionKey: mainSessionKey,
                sender: nil
            ),
        ])
        sessionMessages[mainSessionKey] = mainMessages
        sessionMessages[alphaSessionKey] = [alphaMessage]
        sessionMessages[betaSessionKey] = [betaMessage]
        persistMessages(mainMessages, for: mainSessionKey)
        persistMessages([alphaMessage], for: alphaSessionKey)
        persistMessages([betaMessage], for: betaSessionKey)
        recalculateOrderedSessionKeys()
        ensureDefaultActiveSessionIfNeeded()

        crossChatNotificationBubblesBySourceChatId = [
            alphaSessionKey: CrossChatNotificationBubble(
                sourceChatId: alphaSessionKey,
                sourceTitle: "T1174 Alpha",
                entries: [
                    CrossChatAssistantNotificationEntry(
                        id: "s_t1174_notification_a",
                        content: "Dock tap proof notification A",
                        timestamp: now
                    )
                ],
                lastAssistantActivityAt: now
            ),
            betaSessionKey: CrossChatNotificationBubble(
                sourceChatId: betaSessionKey,
                sourceTitle: "T1174 Beta",
                entries: [
                    CrossChatAssistantNotificationEntry(
                        id: "s_t1174_notification_b",
                        content: "Dock tap proof notification B",
                        timestamp: now.addingTimeInterval(-1)
                    )
                ],
                lastAssistantActivityAt: now.addingTimeInterval(-1)
            )
        ]

        if ProcessInfo.processInfo.arguments.contains("--debug-cross-chat-notification-dock-proof-start-on-alpha") {
            requestStreamSwitch(to: alphaSessionKey, source: .programmatic)
        }
    }

    func debugAppendBetaCrossChatNotificationForSinglePeekProof() {
        let betaSessionKey = "agent:main:clawline:ui-test:s_t1174_b"
        guard var bubble = crossChatNotificationBubblesBySourceChatId[betaSessionKey] else { return }
        let now = Date()
        bubble.entries.append(
            CrossChatAssistantNotificationEntry(
                id: "s_t1265_notification_handoff",
                content: "T1265 handoff proof notification",
                timestamp: now
            )
        )
        bubble.lastAssistantActivityAt = now
        crossChatNotificationBubblesBySourceChatId[betaSessionKey] = bubble
    }
#endif

    private func animateCrossChatNotificationDismissal(_ updates: @escaping () -> Void) {
        guard let crossChatNotificationDismissAnimator else {
            updates()
            return
        }
        crossChatNotificationDismissAnimator(updates)
    }

    func openCrossChatNotificationReply(sourceChatId: String) {
        guard var bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] else { return }
        bubble.isReplying = true
        crossChatNotificationBubblesBySourceChatId[sourceChatId] = bubble
        closeOverflowingCrossChatNotificationReplies()
    }

    func toggleCrossChatNotificationReply(sourceChatId: String) {
        guard let bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] else { return }
        if bubble.isReplying {
            closeCrossChatNotificationReply(sourceChatId: sourceChatId)
        } else {
            openCrossChatNotificationReply(sourceChatId: sourceChatId)
        }
    }

    func closeCrossChatNotificationReply(sourceChatId: String) {
        guard var bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] else { return }
        bubble.isReplying = false
        bubble.replyDraft = ""
        crossChatNotificationBubblesBySourceChatId[sourceChatId] = bubble
    }

    func setCrossChatNotificationReplyDraft(sourceChatId: String, draft: String) {
        guard var bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] else { return }
        bubble.replyDraft = draft
        crossChatNotificationBubblesBySourceChatId[sourceChatId] = bubble
    }

    func isSendingCrossChatNotificationReply(sourceChatId: String) -> Bool {
        isSending && activeCrossChatNotificationReplySourceChatId == sourceChatId
    }

    func canImmediatelySendCrossChatNotificationReply(sourceChatId: String) -> Bool {
        guard !isSending else { return false }
        guard let bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] else { return false }
        let text = bubble.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isTextWithinSendByteLimit(text) else { return false }
        guard streamsBySessionKey[sourceChatId] != nil else { return false }
        guard transportSendButtonConnectionState == .connected else { return false }

        switch sendProvisioningState(for: sourceChatId) {
        case .ready:
            return true
        case .waiting, .unavailable:
            return false
        }
    }

    func sendCrossChatNotificationReply(sourceChatId: String) {
        guard !isSending else { return }
        guard let bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] else { return }
        let text = bubble.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard streamsBySessionKey[sourceChatId] != nil else {
            toastManager.show("This stream is unavailable. Switch streams and try again.")
            return
        }
        guard validateTextByteLimitForSend(text) else { return }

        switch sendProvisioningState(for: sourceChatId) {
        case .ready:
            guard transportSendButtonConnectionState == .connected else {
                toastManager.show("Could not send; not connected.")
                return
            }
            beginSend(
                content: text,
                pendingAttachments: [],
                references: [],
                sessionKey: sourceChatId,
                clearInputOnSuccess: false,
                crossChatNotificationReplySourceChatId: sourceChatId,
                onSuccess: { [weak self] _ in
                    self?.dismissCrossChatNotification(sourceChatId: sourceChatId)
                }
            )
        case .waiting:
            return
        case .unavailable:
            toastManager.show("This stream is unavailable. Switch streams and try again.")
        }
    }

    @discardableResult
    func send() -> Bool {
        sendResolved(destinationSessionKey: focusedPromptSendDestinationSessionKey)
    }

    @discardableResult
    func sendCrossChatMention(to destinationSessionKey: String) -> Bool {
        let routedContent = inputContent.contentAfterCrossChatMentionAttachment() ?? inputContent
        let didDispatch = sendResolved(
            destinationSessionKey: destinationSessionKey,
            sourceContent: routedContent
        )
        if didDispatch {
            clearInput()
        }
        return didDispatch
    }

    private var focusedPromptSendDestinationSessionKey: String? {
        let selected = uiSelectedSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = engineActiveSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, selected != active else { return nil }
        return selected
    }

    @discardableResult
    private func sendResolved(
        destinationSessionKey: String?,
        sourceContent: NSAttributedString? = nil
    ) -> Bool {
        guard !isSending else { return false }
        let sendContent = sourceContent ?? inputContent
        let referencedIds = Set(sendContent.pendingAttachmentIds())
#if DEBUG
        let transportSnapshot = sendTransportSnapshot()
        imageSendLastTransportSnapshot = transportSnapshot
        recordImageSendDebugEvent(
            .sendTapped,
            detail: "textLen=\(sendContent.length) attachmentCount=\(referencedIds.count) \(transportSnapshot)"
        )
#endif
        let stagedOnly = attachmentData.keys.filter { !referencedIds.contains($0) }
        if !stagedOnly.isEmpty {
#if DEBUG
            recordImageSendDebugEvent(
                .sendResult,
                detail: "failure reason=staging_incomplete pending=\(stagedOnly.count)"
            )
#endif
            toastManager.show("Finishing attachment…")
            return false
        }
        pruneAttachmentData()
        let (text, pendingIds) = sendContent.contentForSending()
        let pendingAttachments = pendingIds.compactMap { attachmentData[$0] }
        let referenceIds = inputContent.pendingMessageReferenceIds()
        let pendingReferences = referenceIds.compactMap { messageReferenceData[$0] }
        guard pendingReferences.count == referenceIds.count else {
#if DEBUG
            recordImageSendDebugEvent(.sendResult, detail: "failure reason=missing_message_reference")
#endif
            toastManager.show("Referenced message is unavailable.")
            return false
        }
        let referenceContexts = pendingReferences.compactMap(MessageReferenceContext.init(reference:))
        guard referenceContexts.count == pendingReferences.count else {
#if DEBUG
            recordImageSendDebugEvent(.sendResult, detail: "failure reason=missing_llm_visible_message_id")
#endif
            toastManager.show(ChatViewModel.missingReplyVisibleIdMessage)
            return false
        }
        let replyToMessageId = pendingReferences.first?.llmVisibleMessageId
        let replyToClientMessageId = pendingReferences.first?.clientMessageId

        guard !text.isEmpty || !pendingAttachments.isEmpty else {
#if DEBUG
            recordImageSendDebugEvent(.sendResult, detail: "failure reason=empty_input")
#endif
            return false
        }

        if !validateTextByteLimitForSend(text) {
            return false
        }

        let crossChatDestination = destinationSessionKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if crossChatDestination == nil, pendingAttachments.isEmpty && handleSlashCommand(text) {
            return true
        }

        ensureDefaultActiveSessionIfNeeded()
        let outboundSessionKey = crossChatDestination ?? engineActiveSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outboundSessionKey.isEmpty else {
#if DEBUG
            recordImageSendDebugEvent(.sendResult, detail: "failure reason=no_stream_selected")
#endif
            toastManager.show("No stream selected.")
            return false
        }
        if crossChatDestination != nil, streamsBySessionKey[outboundSessionKey] == nil {
#if DEBUG
            recordImageSendDebugEvent(.sendResult, detail: "failure reason=cross_chat_destination_unavailable")
#endif
            return false
        }
        switch sendProvisioningState(for: outboundSessionKey) {
        case .ready:
            guard transportSendButtonConnectionState == .connected else {
#if DEBUG
                recordImageSendDebugEvent(
                    .sendResult,
                    detail: "failure reason=not_connected \(sendTransportSnapshot())"
                )
#endif
                toastManager.show("Could not send; not connected.")
                return false
            }
            beginSend(
                content: text,
                pendingAttachments: pendingAttachments,
                references: referenceContexts,
                replyToMessageId: replyToMessageId,
                replyToClientMessageId: replyToClientMessageId,
                sessionKey: outboundSessionKey
            )
            return true
        case .waiting:
#if DEBUG
            recordImageSendDebugEvent(
                .sendResult,
                detail: "queued reason=provisioning_waiting \(sendTransportSnapshot())"
            )
#endif
            let pendingAttachmentIds = pendingAttachments.map(\.id)
            if let pendingProvisionedSend,
               pendingProvisionedSend.content == text,
               pendingProvisionedSend.sessionKey == outboundSessionKey,
               pendingProvisionedSend.crossChatNotificationReplySourceChatId == nil,
               pendingProvisionedSend.attachments.map(\.id) == pendingAttachmentIds,
               pendingProvisionedSend.replyToMessageId == replyToMessageId,
               pendingProvisionedSend.replyToClientMessageId == replyToClientMessageId {
                return true
            }
            pendingProvisionedSend = PendingProvisionedSend(
                clientId: nextClientMessageId(),
                content: text,
                attachments: pendingAttachments,
                references: referenceContexts,
                replyToMessageId: replyToMessageId,
                replyToClientMessageId: replyToClientMessageId,
                sessionKey: outboundSessionKey,
                crossChatNotificationReplySourceChatId: nil
            )
            return true
        case .unavailable:
#if DEBUG
            recordImageSendDebugEvent(
                .sendResult,
                detail: "failure reason=stream_unavailable \(sendTransportSnapshot())"
            )
#endif
            toastManager.show("This stream is unavailable. Switch streams and try again.")
            return false
        }
    }

    private func beginSend(content: String,
                           pendingAttachments: [PendingAttachment],
                           references: [MessageReferenceContext],
                           replyToMessageId: String? = nil,
                           replyToClientMessageId: String? = nil,
                           sessionKey: String,
                           clientId: String? = nil,
                           clearInputOnSuccess: Bool = true,
                           crossChatNotificationReplySourceChatId: String? = nil,
                           onSuccess: (@MainActor (_ clientId: String) -> Void)? = nil) {
        let clientId = clientId ?? nextClientMessageId()
        activeClientMessageId = clientId
        activeCrossChatNotificationReplySourceChatId = crossChatNotificationReplySourceChatId
        if let crossChatNotificationReplySourceChatId {
            crossChatNotificationReplySourceByClientMessageId[clientId] = crossChatNotificationReplySourceChatId
        }
#if DEBUG
        recordImageSendDebugEvent(
            .sendDispatched,
            detail: "localId=\(clientId) at=\(Date().formatted(date: .omitted, time: .standard))"
        )
#endif

        isSending = true  // Set immediately to prevent double-tap race condition
        activeSendHasReachedTransport = false
        let placeholder = Message(
            id: clientId,
            role: .user,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: makeDisplayAttachments(from: pendingAttachments),
            deviceId: deviceId,
            sessionKey: sessionKey,
            replyToMessageId: replyToMessageId,
            replyToClientMessageId: replyToClientMessageId
        )
        print("[ClawlineSendDiag] vm_begin_send_placeholder id=\(clientId) sessionKey=\(sessionKey) contentChars=\(content.count) attachments=\(pendingAttachments.count) references=\(references.count)")
        upsert(sessionKey: sessionKey, message: placeholder, sourceFlags: .local)
        pendingLocalMessages.append(PendingLocalMessage(id: clientId, sessionKey: sessionKey))
        latestStatusAuthorityClientMessageIDByRoutingSessionKey[sessionKey] = clientId
        print("[ClawlineSendDiag] vm_begin_send_task_scheduled id=\(clientId) sessionKey=\(sessionKey) pendingLocalCount=\(pendingLocalMessages.count)")
        scheduleSessionStatusRefresh(for: sessionKey, reason: "sendDispatched")
        bumpSendIndicatorRevision()

        sendTask = Task { [weak self] in
            await self?.performSend(
                clientId: clientId,
                content: content,
                pendingAttachments: pendingAttachments,
                references: references,
                sessionKey: sessionKey,
                clearInputOnSuccess: clearInputOnSuccess,
                onSuccess: onSuccess
            )
        }
    }

    func sendInteractiveCallback(sourceMessageId: String, action: String, data: JSONValue?) {
        Task { [chatService, logger] in
            do {
                try await chatService.sendInteractiveCallback(
                    sourceMessageId: sourceMessageId,
                    action: action,
                    data: data
                )
            } catch {
                // Callbacks are best-effort fire-and-forget (T031). Failures should be silent
                // to avoid spamming toasts for interaction-heavy bubbles.
                logger.error(
                    "interactive_callback_send_failed messageId=\(sourceMessageId, privacy: .public) action=\(action, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func resendFailedMessage(messageId: String) {
        guard !isSending else { return }
        guard let (message, sessionKey, _) = findMessage(id: messageId) else { return }
        guard validateTextByteLimitForSend(message.content) else { return }

        let clientId = "c_\(UUID().uuidString)"
        let resentMessage = Message(
            id: clientId,
            role: message.role,
            content: message.content,
            timestamp: Date(),
            streaming: false,
            attachments: message.attachments,
            deviceId: deviceId,
            sessionKey: sessionKey
        )

        remove(sessionKey: sessionKey, messageId: messageId, reason: "retry_replace")
        upsert(sessionKey: sessionKey, message: resentMessage, sourceFlags: .local)

        pendingLocalMessages.removeAll { $0.id == messageId }
        ackedPendingLocalMessageIDs.remove(messageId)
        pendingLocalMessages.append(PendingLocalMessage(id: clientId, sessionKey: sessionKey))
        messageFailures.removeValue(forKey: messageId)
        bumpSendIndicatorRevision()

        isSending = true
        activeClientMessageId = clientId
        activeCrossChatNotificationReplySourceChatId = nil
        activeSendHasReachedTransport = false

        sendTask = Task { [weak self] in
            await self?.performRetrySend(
                clientId: clientId,
                content: resentMessage.content,
                attachments: resentMessage.attachments,
                sessionKey: sessionKey
            )
        }
    }

    func cancelSend() {
        cancelActiveSend(shouldGhostOnlyBeforeTransport: true)
    }

    private func cancelSendForTeardown() {
        cancelActiveSend(shouldGhostOnlyBeforeTransport: false)
    }

    private func cancelActiveSend(shouldGhostOnlyBeforeTransport: Bool) {
        guard isSending else { return }
        if shouldGhostOnlyBeforeTransport, activeSendHasReachedTransport {
            return
        }
        let canceledClientMessageId = activeClientMessageId
        let shouldGhost = !activeSendHasReachedTransport
        sendTask?.cancel()
        sendTask = nil
        if let canceledClientMessageId {
            if shouldGhost {
                markLocalMessageCanceled(id: canceledClientMessageId)
            } else {
                removePendingLocalMessage(id: canceledClientMessageId, reason: "cancel_send")
            }
            crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: canceledClientMessageId)
        }
        activeClientMessageId = nil
        activeCrossChatNotificationReplySourceChatId = nil
        activeSendHasReachedTransport = false
        isSending = false
    }

    func stageAttachments(_ attachments: [PendingAttachment], source: String = "unknown") {
        attachments.forEach {
            attachmentData[$0.id] = $0
            stagedAttachmentProtection.insert($0.id)
        }
#if DEBUG
        recordImageSendDebugEvent(
            .attachmentAdded,
            detail: "count=\(attachments.count) source=\(source)"
        )
#endif
    }

    func insertMessageIntoPrompt(_ message: Message, selectionRange: NSRange) -> NSRange {
        let insertion = NSAttributedString(
            string: message.content,
            attributes: [
                .font: UIFont.clawline(.bodyText),
                .foregroundColor: UIColor.label
            ]
        )
        let mutable = NSMutableAttributedString(attributedString: inputContent)
        let safeRange = Self.clampedRange(selectionRange, length: mutable.length)
        mutable.replaceCharacters(in: safeRange, with: insertion)
        inputContent = mutable
        inputResetToken &+= 1
        return NSRange(location: safeRange.location + insertion.length, length: 0)
    }

    func referenceMessageInPrompt(_ message: Message, selectionRange: NSRange) -> NSRange {
        guard message.hasStableReferenceIdentity else {
            toastManager.show(Self.missingReplyVisibleIdMessage)
            return selectionRange
        }
        let reference = PendingMessageReference(message: message)
        let attachment = MessageReferenceTextAttachment(reference: reference)
        let token = NSMutableAttributedString(attachment: attachment)
        token.append(NSAttributedString(string: " "))

        let mutable = NSMutableAttributedString(attributedString: inputContent)
        mutable.removeMessageReferences()
        mutable.insert(token, at: 0)
        messageReferenceData.removeAll()
        messageReferenceData[reference.id] = reference
        inputContent = mutable
        inputResetToken &+= 1
        return NSRange(location: token.length, length: 0)
    }

    func beginAttachmentStaging() {
        pendingAttachmentStageCount += 1
#if DEBUG
        recordImageSendDebugEvent(
            .attachmentStagingStarted,
            detail: "pending=\(pendingAttachmentStageCount)"
        )
#endif
    }

    func endAttachmentStaging() {
        pendingAttachmentStageCount = max(0, pendingAttachmentStageCount - 1)
#if DEBUG
        recordImageSendDebugEvent(
            .attachmentStagingCompleted,
            detail: "pending=\(pendingAttachmentStageCount)"
        )
#endif
    }

    func logout() {
        cancelSendForTeardown()
        observationStartupTask?.cancel()
        observationStartupTask = nil
        activationTask?.cancel()
        activationTask = nil
        hasActivatedLifecycleOwnership = false
        clearTemporarySendButtonOverride()
        clearSessionStatusRefreshes()
        observationTask?.cancel()
        observationTask = nil
        lifecycleTransportEventsSubscription = nil
        lifecycleOutputsSubscription = nil
        lifecycleStartupGateDebugSubscription = nil
        lifecycleTransportTask?.cancel()
        lifecycleTransportTask = nil
        lifecycleOutputTask?.cancel()
        lifecycleOutputTask = nil
        Task {
            await lifecycleCoordinator.disconnectRequested()
            await lifecycleCoordinator.setAuthToken(nil)
        }
        chatService.disconnect()
        auth.clearCredentials()
        clearInput()
        pendingAttachmentStageCount = 0
        clearAllForLogout(reason: "logout")
        isAssistantTyping = false
        typingSessionKey = nil
        clearAllLiveProgress()
        shouldMorphTypingIndicator = false
        clearAllTypingIndicatorMorphTargets()
        connectionStableTask?.cancel()
        connectionStableTask = nil
        restoredSessionKeys.removeAll()
        forceReReadGenerationBySession.removeAll()
        restoredStreamMetadataForUserId = nil
        crossChatNotificationBubblesBySourceChatId.removeAll()
        suppressedCrossChatNotificationEntryKeysBySourceChatId.removeAll()
        unavailableCrossChatNotificationSourceIds.removeAll()
        resetSessionProvisioningState(clearPendingSend: true)
        clearMessageCache()
        clearStreamMetadataCache()
    }

    func canRenameStream(sessionKey: String) -> Bool {
        guard let stream = streamsBySessionKey[sessionKey] else { return false }
        guard !syntheticSessionKeys.contains(sessionKey) else { return false }
        if stream.kind == "main" { return true }
        if SessionKey.isClawlinePersonalDM(stream.sessionKey) { return true }
        return !stream.isBuiltIn
    }

    func canDeleteStream(sessionKey: String) -> Bool {
        guard let stream = streamsBySessionKey[sessionKey] else { return false }
        guard !stream.adopted else { return false }
        if stream.sessionKey == SessionKey.admin { return false }
        if stream.kind == "main" { return true }
        if SessionKey.isClawlinePersonalDM(stream.sessionKey) { return true }
        guard !stream.isBuiltIn else { return false }
        return !isProtectedNonDeletableStream(stream)
    }

    func canUntrackStream(sessionKey: String) -> Bool {
        guard let stream = streamsBySessionKey[sessionKey] else { return false }
        return stream.adopted
    }

    func isAdoptedStream(sessionKey: String) -> Bool {
        guard let stream = streamsBySessionKey[sessionKey] else {
            logger.info("adopted_check sessionKey=\(sessionKey, privacy: .public) result=false source=missing_stream")
            return false
        }
        logger.info(
            "adopted_check sessionKey=\(sessionKey, privacy: .public) adopted=\(stream.adopted, privacy: .public) result=\(stream.adopted, privacy: .public)"
        )
        return stream.adopted
    }

    func canTrackSession(sessionKey: String) -> Bool {
        guard canUseTrackFeature else { return false }
        guard !sessionKey.isEmpty else { return false }
        let trackedSessionKeys = Set(
            orderedStreams
                .filter { !syntheticSessionKeys.contains($0.sessionKey) }
                .map(\.sessionKey)
        )
        guard !trackedSessionKeys.contains(sessionKey) else { return false }
        return trackableSessionsBySessionKey[sessionKey] != nil
    }

    func trackSession(sessionKey: String) async -> Bool {
        guard canTrackSession(sessionKey: sessionKey) else { return false }
        do {
            let stream = try await chatService.adoptStream(sessionKey: sessionKey)
            pendingUntrackRecovery = nil
            applyStreamUpsert(stream)
            refreshTrackableSessions(reason: "trackSuccess")
            return true
        } catch {
            toastManager.show(error.localizedDescription)
            return false
        }
    }

    func refreshTrackableSessionsOnDemand() {
        refreshTrackableSessions(reason: "manualRefresh")
    }

    /// Outcome of a placement-aware create (T-B creation sheet). On failure the
    /// message is the server's refusal text verbatim so the sheet can surface it
    /// unchanged; a nil message means there was nothing to surface (empty name).
    enum StreamCreateOutcome: Equatable {
        case created
        case failed(message: String?)
    }

    private enum StreamCreateResult {
        case success
        case emptyName
        case failure(Swift.Error)
    }

    func createStream(displayName: String) async -> Bool {
        switch await performStreamCreate(
            displayName: displayName,
            harness: nil,
            model: nil,
            host: nil,
            archetype: nil
        ) {
        case .success:
            return true
        case .emptyName:
            return false
        case .failure(let error):
            toastManager.show(error.localizedDescription)
            return false
        }
    }

    /// T-B: create with optional placement provisioning. Unlike the name-only
    /// path this returns the refusal message instead of toasting, so the
    /// creation sheet owns presentation and shows the server's rule verbatim.
    func createStream(
        displayName: String,
        harness: String?,
        model: String?,
        host: String?,
        archetype: String?
    ) async -> StreamCreateOutcome {
        // This placement-aware create is the Tightbeam creation SHEET's only
        // submit path (the legacy openclaw manager uses createStream(displayName:)).
        // The whole sheet is Tightbeam-gated, so refuse ANY submission — including
        // name-only — once the gate has closed, not just placement-bearing ones.
        // Re-checked here at the async submission boundary as defense in depth
        // behind the modal's onChange dismissal.
        guard isTightbeamServer else {
            return .failed(message: "New-chat options are unavailable on this server.")
        }
        switch await performStreamCreate(
            displayName: displayName,
            harness: harness,
            model: model,
            host: host,
            archetype: archetype
        ) {
        case .success:
            return .created
        case .emptyName:
            return .failed(message: nil)
        case .failure(let error):
            return .failed(message: error.localizedDescription)
        }
    }

    private func performStreamCreate(
        displayName: String,
        harness: String?,
        model: String?,
        host: String?,
        archetype: String?
    ) async -> StreamCreateResult {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyName }
        let idempotencyKey = Self.makeIdempotencyKey()
        do {
            let stream = try await createStreamRequestingRetry(
                displayName: trimmed,
                idempotencyKey: idempotencyKey,
                harness: harness,
                model: model,
                host: host,
                archetype: archetype
            )
            applyStreamUpsert(stream)
            setEngineActiveSessionKey(stream.sessionKey)
            return .success
        } catch {
            return .failure(error)
        }
    }

    private func createStreamRequestingRetry(
        displayName: String,
        idempotencyKey: String,
        harness: String?,
        model: String?,
        host: String?,
        archetype: String?
    ) async throws -> StreamSession {
        do {
            return try await chatService.createStream(
                displayName: displayName,
                idempotencyKey: idempotencyKey,
                harness: harness,
                model: model,
                host: host,
                archetype: archetype
            )
        } catch {
            guard shouldRetryCreateOnActiveConnection(after: error) else { throw error }
            try await reconnectActiveTransportForControlPlane()
            return try await chatService.createStream(
                displayName: displayName,
                idempotencyKey: idempotencyKey,
                harness: harness,
                model: model,
                host: host,
                archetype: archetype
            )
        }
    }

    func renameStream(sessionKey: String, displayName: String) async -> Bool {
        guard canRenameStream(sessionKey: sessionKey) else { return false }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let stream = try await chatService.renameStream(sessionKey: sessionKey, displayName: trimmed)
            applyStreamUpsert(stream)
            return true
        } catch {
            toastManager.show(error.localizedDescription)
            return false
        }
    }

    func deleteStream(sessionKey: String) async -> Bool {
        guard let stream = streamsBySessionKey[sessionKey] else { return false }
        guard stream.adopted || canDeleteStream(sessionKey: sessionKey) else { return false }
        let idempotencyKey = stream.adopted ? nil : Self.makeIdempotencyKey()
        do {
            _ = try await chatService.deleteStream(
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )
            applyDeleteSuccess(for: stream)
            return true
        } catch {
            if shouldRetryDeleteOnActiveConnection(after: error) {
                do {
                    try await reconnectActiveTransportForControlPlane()
                    _ = try await chatService.deleteStream(
                        sessionKey: sessionKey,
                        idempotencyKey: idempotencyKey
                    )
                    applyDeleteSuccess(for: stream)
                    return true
                } catch {
                    toastManager.show(error.localizedDescription)
                    return false
                }
            }
            toastManager.show(error.localizedDescription)
            return false
        }
    }

    private func shouldRetryDeleteOnActiveConnection(after error: Swift.Error) -> Bool {
        guard auth.token != nil else { return false }
        if let providerError = error as? ProviderChatService.Error,
           case .notConnected = providerError {
            return true
        }
        if let streamError = error as? StreamAPIError,
           streamError.code == "not_connected" {
            return true
        }
        return false
    }

    private func shouldRetryCreateOnActiveConnection(after error: Swift.Error) -> Bool {
        guard auth.token != nil else { return false }
        if let providerError = error as? ProviderChatService.Error,
           case .notConnected = providerError {
            return true
        }
        if let streamError = error as? StreamAPIError,
           streamError.code == "not_connected" {
            return true
        }
        return false
    }

    private func reconnectActiveTransportForControlPlane() async throws {
        guard let token = auth.token else {
            throw ProviderChatService.Error.notConnected
        }
        let lastMessageId = legacyReplayCursorForActiveStream()
        try await chatService.connect(token: token, lastMessageId: lastMessageId)
    }

    private static func makeIdempotencyKey() -> String {
        "req_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private func handleIncoming(_ message: Message, notificationBatchEpoch: Int? = nil) {
        let snippet = String(message.content.prefix(80))
        logger.info(
            "incoming id=\(message.id, privacy: .public) sessionKey=\(message.sessionKey, privacy: .public) stream=\(self.streamType(for: message.sessionKey).rawValue, privacy: .public) role=\(String(describing: message.role), privacy: .public) streaming=\(message.streaming, privacy: .public) deviceId=\(message.deviceId ?? "nil", privacy: .public) snippet=\"\(snippet, privacy: .public)\""
        )

        if shouldSuppressInteractiveCallbackEcho(message) {
            logger.info(
                "incoming suppressed interactive_callback_echo id=\(message.id, privacy: .public) sessionKey=\(message.sessionKey, privacy: .public)"
            )
            return
        }

        var resolvedMessage = message
        if message.role == .assistant,
           message.attachments.isEmpty,
           isNoReplyContent(message.content) {
            resolvedMessage = Message(
                id: message.id,
                role: message.role,
                content: "👀",
                timestamp: message.timestamp,
                streaming: false,
                attachments: [],
                deviceId: message.deviceId,
                sessionKey: message.sessionKey,
                sender: message.sender,
                clientMessageId: message.clientMessageId,
                replyToMessageId: message.replyToMessageId,
                replyToClientMessageId: message.replyToClientMessageId
            )
        }

        // Check if this is an assistant message arriving while typing indicator is visible.
        // If so, the UI should morph the typing indicator into this message instead of inserting new.
        ensureStreamEntry(for: message.sessionKey)
        if message.role == .assistant, !message.streaming {
            clearLiveProgressForAssistantFinal(message)
        }

        if message.role == .assistant,
           isAssistantTyping,
           typingSessionKey == message.sessionKey {
            shouldMorphTypingIndicator = true
            typingIndicatorMorphTargetMessageIdBySessionKey[message.sessionKey] = resolvedMessage.id
            isAssistantTyping = false
            self.typingSessionKey = nil
        } else if message.role == .assistant,
                  typingIndicatorMorphTargetMessageIdBySessionKey[message.sessionKey] == message.id {
            clearTypingIndicatorMorphTarget(for: message.sessionKey)
        } else if typingIndicatorMorphTargetMessageIdBySessionKey.isEmpty {
            shouldMorphTypingIndicator = false
        }

        if replacePendingMessageIfNeeded(with: resolvedMessage) {
            logger.info("incoming replacePending id=\(resolvedMessage.id, privacy: .public)")
            resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
            return
        }
        if resolvedMessage.role == .assistant,
           !resolvedMessage.streaming,
           let replyToMessageId = normalizedServerEventID(resolvedMessage.replyToMessageId) {
            if messageFailures.removeValue(forKey: replyToMessageId) != nil {
                bumpSendIndicatorRevision()
            }
        }

        let didAppendNewMessage = upsert(sessionKey: resolvedMessage.sessionKey, message: resolvedMessage, sourceFlags: .server)
        if resolvedMessage.role == .assistant, !resolvedMessage.streaming {
            scheduleSessionStatusRefresh(for: resolvedMessage.sessionKey, reason: "assistantResponseCommitted")
        }
        if resolvedMessage.sessionKey == engineActiveSessionKey,
           resolvedMessage.id.hasPrefix("s_") {
            markSessionRead(resolvedMessage.sessionKey, messageId: resolvedMessage.id)
        }
        applyCrossChatAssistantNotificationIfNeeded(for: resolvedMessage, batchEpoch: notificationBatchEpoch)
        maybeTriggerAssistantIncomingHaptic(for: resolvedMessage, didAppendNewMessage: didAppendNewMessage)

        resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
    }

    private func applyCrossChatAssistantNotificationIfNeeded(
        for message: Message,
        batchEpoch: Int?,
        notificationSequence: UInt64? = nil
    ) {
        guard message.role == .assistant else { return }
        guard !hasSuppressedCrossChatNotificationEntry(message) else {
            if !message.streaming {
                markSuppressedCrossChatNotificationEntryReadIfNeeded(message)
            }
            return
        }
        let title = stream(for: message.sessionKey)?.displayName
            ?? message.sender
            ?? message.sessionKey
        let candidate = NotificationBatchCommitCoordinator.Candidate(
            messageId: message.id,
            sourceChatId: message.sessionKey,
            role: message.role,
            content: message.content,
            timestamp: message.timestamp,
            streaming: message.streaming,
            sourceTitle: title,
            notificationSequence: notificationSequence
        )
        if let batchEpoch {
            notificationBatchCommitCoordinator.collectPendingCandidate(candidate, epoch: batchEpoch)
            return
        }
        guard isUnreadCrossChatAssistantNotificationCandidate(candidate) else {
            if !message.streaming {
                recordSuppressedCrossChatNotificationEntry(message)
            }
            return
        }
        guard isEligibleForCrossChatAssistantNotification(sourceChatId: message.sessionKey) else {
            if !message.streaming {
                recordSuppressedCrossChatNotificationEntry(message)
            }
            return
        }
        if deferCrossChatNotificationMutationIfNeeded({ [weak self] in
            self?.applyCrossChatAssistantNotificationIfNeeded(for: message, batchEpoch: nil, notificationSequence: notificationSequence)
        }) {
            return
        }
        notificationBatchCommitCoordinator.applyLiveCandidate(
            candidate,
            to: &crossChatNotificationBubblesBySourceChatId
        )
        closeOverflowingCrossChatNotificationReplies()
    }

    private func beginCrossChatNotificationBatch(epoch: Int, waitsForTruncationBoundary: Bool) {
        notificationBatchCommitCoordinator.begin(
            epoch: epoch,
            waitsForTruncationBoundary: waitsForTruncationBoundary
        )
    }

    private func commitCrossChatNotificationBatchIfReady(epoch: Int, reachedTruncationBoundary: Bool) {
        if deferCrossChatNotificationMutationIfNeeded({ [weak self] in
            self?.commitCrossChatNotificationBatchIfReady(epoch: epoch, reachedTruncationBoundary: reachedTruncationBoundary)
        }) {
            return
        }
        guard let committedSnapshot = notificationBatchCommitCoordinator.commitIfReady(
            epoch: epoch,
            reachedTruncationBoundary: reachedTruncationBoundary,
            committedSnapshot: crossChatNotificationBubblesBySourceChatId,
            isEligible: { [weak self] sourceChatId in
                self?.isEligibleForCrossChatAssistantNotification(sourceChatId: sourceChatId) ?? false
            },
            isEntryUnread: { [weak self] sourceChatId, entry in
                self?.isUnreadCrossChatAssistantNotificationEntry(entry, sourceChatId: sourceChatId) ?? false
            },
            onSuppressedEntries: { [weak self] sourceChatId, entries in
                self?.recordSuppressedCrossChatNotificationEntries(entries, sourceChatId: sourceChatId)
            }
        ) else {
            return
        }
        crossChatNotificationBubblesBySourceChatId = committedSnapshot
        closeOverflowingCrossChatNotificationReplies()
    }

    private func isEligibleForCrossChatAssistantNotification(sourceChatId: String) -> Bool {
        guard streamsBySessionKey[sourceChatId] != nil else { return false }
        guard !unavailableCrossChatNotificationSourceIds.contains(sourceChatId) else { return false }
        guard !hasReceivedSessionProvisioning || isLocallySendableSessionKey(sourceChatId) else { return false }
        let visibleSessionKey = uiSelectedSessionKey.isEmpty ? engineActiveSessionKey : uiSelectedSessionKey
        guard sourceChatId != visibleSessionKey else { return false }
        return true
    }

    private func isUnreadCrossChatAssistantNotificationEntry(
        _ entry: CrossChatAssistantNotificationEntry,
        sourceChatId: String
    ) -> Bool {
        isUnreadCrossChatAssistantNotificationMessage(
            messageId: entry.id,
            content: entry.content,
            sourceChatId: sourceChatId
        )
    }

    private func isUnreadCrossChatAssistantNotificationCandidate(
        _ candidate: NotificationBatchCommitCoordinator.Candidate
    ) -> Bool {
        guard candidate.role == .assistant, !candidate.streaming else { return false }
        return isUnreadCrossChatAssistantNotificationMessage(
            messageId: candidate.messageId,
            content: candidate.content,
            sourceChatId: candidate.sourceChatId
        )
    }

    private func isUnreadCrossChatAssistantNotificationMessage(
        messageId: String,
        content: String,
        sourceChatId: String
    ) -> Bool {
        if let tailState = streamTailStateBySession[sourceChatId] {
            if tailState.lastMessageId == messageId {
                guard tailState.lastMessageRole == .assistant else { return false }
            }
        }
        guard let lastReadMessageId = lastReadMessageIdBySession[sourceChatId],
              !lastReadMessageId.isEmpty else {
            return true
        }
        if messageId == lastReadMessageId {
            let key = suppressedCrossChatNotificationEntryKey(id: messageId, content: content)
            let suppressedKeys = suppressedCrossChatNotificationEntryKeysBySourceChatId[sourceChatId] ?? []
            return !suppressedKeys.isEmpty && !suppressedKeys.contains(key)
        }
        let messages = sessionMessages[sourceChatId] ?? []
        guard let candidateIndex = messages.firstIndex(where: { $0.id == messageId }) else {
            return true
        }
        guard let lastReadIndex = messages.firstIndex(where: { $0.id == lastReadMessageId }) else {
            return true
        }
        return candidateIndex > lastReadIndex
    }

    private func discardCrossChatNotificationBatch(epoch: Int) {
        notificationBatchCommitCoordinator.discard(epoch: epoch)
    }

    private func discardCrossChatNotificationBatches(except epoch: Int? = nil) {
        notificationBatchCommitCoordinator.discardAll(except: epoch)
    }

    func closeOverflowingCrossChatNotificationReplies(visibleCapacity: Int = 10) {
        let capacity = max(0, visibleCapacity)
        let overflowSourceChatIds = crossChatNotificationBubbles.dropFirst(capacity).map(\.sourceChatId)
        closeCrossChatNotificationReplies(sourceChatIds: overflowSourceChatIds)
    }

    func closeOverflowingCrossChatNotificationReplies(visibleSourceChatIds: Set<String>) {
        let overflowSourceChatIds = crossChatNotificationBubblesBySourceChatId.keys.filter {
            !visibleSourceChatIds.contains($0)
        }
        closeCrossChatNotificationReplies(sourceChatIds: overflowSourceChatIds)
    }

    private func closeCrossChatNotificationReplies(sourceChatIds: some Sequence<String>) {
        for sourceChatId in sourceChatIds {
            guard var bubble = crossChatNotificationBubblesBySourceChatId[sourceChatId] else { continue }
            guard !bubble.isReplying else { continue }
            guard bubble.isReplying || !bubble.replyDraft.isEmpty else { continue }
            bubble.isReplying = false
            bubble.replyDraft = ""
            crossChatNotificationBubblesBySourceChatId[sourceChatId] = bubble
        }
    }

    private func shouldSuppressInteractiveCallbackEcho(_ message: Message) -> Bool {
        guard message.role == .user, !message.streaming else { return false }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[Interactive:") else { return false }
        guard trimmed.contains("] action=") || trimmed.contains(" action=") else { return false }
        return true
    }

    private func handleLifecycleServerMessage(epoch: Int, payload: Data) async {
        firstReplayAppliedEpoch = epoch
        restoreTaskBySessionKey.values.forEach { $0.cancel() }
        restoreTaskBySessionKey.removeAll()
        guard let decoded = try? await Self.decodeLifecycleServerMessagePayload(from: payload) else { return }
        guard decoded.envelope.type == "message" else { return }
        let serverPayload = decoded.payload
        guard let sessionKey = serverPayload.sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionKey.isEmpty else { return }
        let message = Message(payload: serverPayload, sessionKey: sessionKey)
        if pendingHistoryResetReplay?.epoch == epoch {
            pendingHistoryResetReplay?.messagesBySessionKey[sessionKey, default: []].append(message)
            pendingHistoryResetReplay?.notificationSequenceByMessageId[message.id] =
                notificationBatchCommitCoordinator.reserveNotificationSequence()
            return
        }
        if notificationBatchCommitCoordinator.contains(epoch: epoch, sourceChatId: message.sessionKey) {
            handleIncoming(message, notificationBatchEpoch: epoch)
        } else {
            handleIncoming(message)
        }
        if isReplayCursorEvent(message) {
            chatService.setReplayCursor(message.id, for: sessionKey)
            Task { await lifecycleCoordinator.updateCanonicalCursor(message.id) }
        }
    }

    nonisolated private struct LifecycleEnvelope: Decodable, Sendable {
        let type: String
    }

    nonisolated private struct LifecycleServerMessagePayload: Sendable {
        let envelope: LifecycleEnvelope
        let payload: ServerMessagePayload
    }

    nonisolated private static func decodeLifecycleServerMessagePayload(from data: Data) async throws -> LifecycleServerMessagePayload {
        try await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            return LifecycleServerMessagePayload(
                envelope: try decoder.decode(LifecycleEnvelope.self, from: data),
                payload: try decoder.decode(ServerMessagePayload.self, from: data)
            )
        }.value
    }

    private func handleHistoryResetRequired(epoch: Int) {
        restoreTaskBySessionKey.values.forEach { $0.cancel() }
        restoreTaskBySessionKey.removeAll()
        // Fence the cache the same way a per-stream barrier does: cancel pending
        // persist debounces, drop their payloads, and advance EVERY known
        // stream's barrier generation so a debounce that already fired self-
        // discards instead of re-writing pre-reset history after clearMessageCache.
        let fencedKeys = Set(sessionMessages.keys)
            .union(pendingPersistPayloads.keys)
            .union(persistDebounceTasks.keys)
        persistDebounceTasks.values.forEach { $0.cancel() }
        persistDebounceTasks.removeAll()
        pendingPersistPayloads.removeAll()
        for key in fencedKeys {
            historyBarrierGenerationBySessionKey[key, default: 0] += 1
        }
        pendingLocalMessages.removeAll()
        ackedPendingLocalMessageIDs.removeAll()
        messageFailures.removeAll()
        bumpSendIndicatorRevision()
        let cursorBackedSessionKeys = Set(chatService.replayCursorSnapshot().keys)
        chatService.clearReplayCursors()
        clearMessageCache()
        pendingHistoryResetReplay = PendingHistoryResetReplay(
            epoch: epoch,
            cursorBackedSessionKeys: cursorBackedSessionKeys
        )
        makeStreamSwitchCoordinator().reset()
        Task {
            await lifecycleCoordinator.updateCanonicalCursor(nil)
            await lifecycleCoordinator.acknowledgeHistoryReset(epoch: epoch)
        }
    }

    private func applyPendingHistoryResetReplayIfNeeded() {
        guard let pending = pendingHistoryResetReplay else { return }
        pendingHistoryResetReplay = nil

        let allSessionKeys = Set(sessionMessages.keys)
            .union(streamsBySessionKey.keys)
            .union(pending.messagesBySessionKey.keys)
        for sessionKey in allSessionKeys {
            let replayMessages = pending.messagesBySessionKey[sessionKey] ?? []
            if !pending.cursorBackedSessionKeys.contains(sessionKey) {
                removeCachedMessages(for: sessionKey)
                clearSessionMessages(sessionKey: sessionKey, reason: "history_reset_replay")
            }
            replayMessages.forEach { upsert(sessionKey: sessionKey, message: $0, sourceFlags: .server) }
            applyReplayMessageSideEffects(replayMessages, sessionKey: sessionKey)
            replayMessages.forEach {
                applyCrossChatAssistantNotificationIfNeeded(
                    for: $0,
                    batchEpoch: pending.epoch,
                    notificationSequence: pending.notificationSequenceByMessageId[$0.id]
                )
            }

            if let replayCursor = latestServerMessageId(from: replayMessages) {
                chatService.setReplayCursor(replayCursor, for: sessionKey)
                Task { await lifecycleCoordinator.updateCanonicalCursor(replayCursor) }
            } else if !pending.cursorBackedSessionKeys.contains(sessionKey) {
                clearCursor(for: sessionKey)
            }
        }
        restoredSessionKeys.formUnion(allSessionKeys)
    }

    private func applyReplayMessageSideEffects(_ replayMessages: [Message], sessionKey: String) {
        guard !replayMessages.isEmpty else { return }
        replayMessages.forEach { resolveAssetAttachmentsIfNeeded(for: $0) }
        if sessionKey == engineActiveSessionKey,
           replayMessages.contains(where: { $0.id.hasPrefix("s_") }) {
            markSessionRead(sessionKey)
        }
    }

    private func maybeTriggerAssistantIncomingHaptic(for message: Message, didAppendNewMessage: Bool) {
        guard didAppendNewMessage, message.role == .assistant else { return }
        guard isChatVisible, isAppInForeground else { return }
        let now = nowProvider()
        if let last = lastAssistantIncomingHapticAt,
           now.timeIntervalSince(last) < assistantIncomingHapticDebounceInterval {
            return
        }
        lastAssistantIncomingHapticAt = now
        assistantIncomingHaptic()
    }

    private func resolveAssetAttachmentsIfNeeded(for message: Message) {
        let needsDownload = message.attachments.contains { attachment in
            guard attachment.data == nil else { return false }
            guard let assetId = attachment.assetId else { return false }
            if downloadedAssetData[assetId] != nil { return true }
            if attachment.type == .image { return true }
            if attachment.type == .asset { return true }
            if Self.needsPayloadHydration(for: attachment) { return true }
            return attachment.mimeType?.lowercased().hasPrefix("image/") == true
        }
        guard needsDownload else { return }

        Task { [weak self] in
            guard let self else { return }
            var updatedAttachments = message.attachments
            var didUpdate = false

            for (index, attachment) in updatedAttachments.enumerated() {
                guard attachment.data == nil else { continue }
                guard let assetId = attachment.assetId else { continue }
                if let cached = downloadedAssetData[assetId] {
                    logger.info("attachment cache hit id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(cached.count, privacy: .public)")
                    updatedAttachments[index] = Attachment(
                        id: attachment.id,
                        type: attachment.type,
                        mimeType: attachment.mimeType,
                        data: cached,
                        assetId: attachment.assetId,
                        filename: attachment.filename,
                        size: attachment.size ?? cached.count
                    )
                    didUpdate = true
                    continue
                }

                do {
                    logger.info("attachment download start id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public)")
                    let data = try await uploadService.download(assetId: assetId)
                    guard !data.isEmpty else {
                        continue
                    }
                    let isImageAttachment = attachment.type == .image
                        || attachment.type == .asset
                        || attachment.mimeType?.lowercased().hasPrefix("image/") == true
                    if isImageAttachment {
                        // Image attachments remain guarded to avoid corrupt image payloads.
                        guard UIImage(data: data) != nil else {
                            logger.error("attachment download non-image id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(data.count, privacy: .public)")
                            continue
                        }
                    } else if !Self.needsPayloadHydration(for: attachment) {
                        continue
                    }
                    downloadedAssetData[assetId] = data
                    logger.info("attachment download ok id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(data.count, privacy: .public)")
                    updatedAttachments[index] = Attachment(
                        id: attachment.id,
                        type: attachment.type,
                        mimeType: attachment.mimeType,
                        data: data,
                        assetId: attachment.assetId,
                        filename: attachment.filename,
                        size: attachment.size ?? data.count
                    )
                    didUpdate = true
                } catch {
                    logger.error("attachment download failed id=\(attachment.id, privacy: .public) assetId=\(assetId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

            guard didUpdate else { return }
            let updatedMessage = Message(
                id: message.id,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                streaming: message.streaming,
                attachments: updatedAttachments,
                deviceId: message.deviceId,
                sessionKey: message.sessionKey,
                sender: message.sender,
                clientMessageId: message.clientMessageId,
                replyToMessageId: message.replyToMessageId,
                replyToClientMessageId: message.replyToClientMessageId
            )

            await MainActor.run {
                _ = self.upsert(sessionKey: updatedMessage.sessionKey, message: updatedMessage, sourceFlags: .server)
            }
        }
    }

    private static func needsPayloadHydration(for attachment: Attachment) -> Bool {
        guard attachment.type == .document else { return false }
        guard let mime = normalizedMimeType(attachment.mimeType) else { return false }
        return richDocumentMimeTypesNeedingPayload.contains(mime)
    }

    private static func normalizedMimeType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
        let trimmed = base?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func replacePendingMessageIfNeeded(with message: Message) -> Bool {
        guard message.role == .user,
              message.deviceId == deviceId else {
            return false
        }

        guard let clientMessageId = message.clientMessageId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientMessageId.isEmpty else {
            return false
        }
        let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == clientMessageId })
        guard let pendingIndex else {
            return false
        }

        let pending = pendingLocalMessages[pendingIndex]
        guard let (pendingMessage, placeholderSessionKey, _) = findMessage(id: pending.id) else {
            return false
        }
        pendingLocalMessages.remove(at: pendingIndex)
        ackedPendingLocalMessageIDs.remove(pending.id)
        bumpSendIndicatorRevision()
        let replyToMessageId = message.replyToMessageId ?? pendingMessage.replyToMessageId
        let replyToClientMessageId = message.replyToClientMessageId ?? pendingMessage.replyToClientMessageId
        let resolvedMessage = Message(
            id: message.id,
            role: message.role,
            content: message.content,
            timestamp: message.timestamp,
            streaming: message.streaming,
            attachments: message.attachments,
            deviceId: message.deviceId,
            sessionKey: message.sessionKey,
            sender: message.sender,
            clientMessageId: message.clientMessageId,
            replyToMessageId: replyToMessageId,
            replyToClientMessageId: replyToClientMessageId,
            deliveryState: message.deliveryState
        )

        remove(sessionKey: placeholderSessionKey, messageId: pending.id, reason: "replace_pending")
        upsert(sessionKey: message.sessionKey, message: resolvedMessage, sourceFlags: .server)
        if activeClientMessageId == pending.id {
            activeClientMessageId = nil
            activeCrossChatNotificationReplySourceChatId = nil
            activeSendHasReachedTransport = false
        }
        if let replySourceChatId = crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: pending.id) {
            dismissCrossChatNotification(sourceChatId: replySourceChatId)
        }
        messageFailures.removeValue(forKey: pending.id)
        return true
    }

    // MARK: - Message Stream Mutation Seam

    @discardableResult
    private func upsert(sessionKey: String, message: Message, sourceFlags: MessageSourceFlags) -> Bool {
        var messageList = sessionMessages[sessionKey] ?? []
        let didAppendNewMessage: Bool
        if let existingIndex = messageList.firstIndex(where: { $0.id == message.id }) {
            if sourceFlags.isCache {
                return false
            }
            let existing = messageList[existingIndex]
            let existingIsServer = normalizedServerEventID(existing.id) != nil
            if !sourceFlags.isServer && existingIsServer {
                return false
            }
            messageList[existingIndex] = message
            didAppendNewMessage = false
        } else {
            let insertionIndex = TranscriptReplyAdjacencyOrdering.insertionIndex(for: message, in: messageList)
                ?? messageList.endIndex
            messageList.insert(message, at: insertionIndex)
            didAppendNewMessage = true
        }
        applyMessagesWrite(messageList, for: sessionKey)
        return didAppendNewMessage
    }

    private func remove(sessionKey: String, messageId: String, reason: String) {
        _ = reason
        guard var messageList = sessionMessages[sessionKey],
              let index = messageList.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        messageList.remove(at: index)
        applyMessagesWrite(messageList, for: sessionKey)
    }

    private func removePendingLocalMessage(id: String, reason: String) {
        if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == id }) {
            let sessionKey = pendingLocalMessages[pendingIndex].sessionKey
            pendingLocalMessages.remove(at: pendingIndex)
            remove(sessionKey: sessionKey, messageId: id, reason: reason)
        }
        ackedPendingLocalMessageIDs.remove(id)
        messageFailures.removeValue(forKey: id)
        bumpSendIndicatorRevision()
    }

    private func clearSessionMessages(sessionKey: String, reason: String) {
        _ = reason
        applyMessagesWrite([], for: sessionKey)
    }

    /// Server moved the history barrier (harness swap etc.); drop every local
    /// trace for the stream so the post-barrier replay is the only truth. Do NOT
    /// remove the stream itself — only its message history/cache (spec §T-A).
    private func handleStreamHistoryCleared(sessionKey: String) {
        let runtimeKey = sessionStatusAuthorityKey(for: sessionKey)
        for key in Set([sessionKey, runtimeKey]) {
            // Move the barrier FIRST: any in-flight restore or debounced
            // persist that started before this instant is now stale by
            // construction and self-discards when it completes.
            historyBarrierGenerationBySessionKey[key, default: 0] += 1
            restoreTaskBySessionKey[key]?.cancel()
            restoreTaskBySessionKey[key] = nil
            clearSessionMessages(sessionKey: key, reason: "stream_history_cleared")
            removeCachedMessages(for: key)
            chatService.setReplayCursor(nil, for: key)
            // Also purge any pre-barrier messages staged in a pending
            // history-reset replay for this stream. Without this, a barrier
            // that lands mid-replay clears the visible store but
            // applyPendingHistoryResetReplayIfNeeded would reinsert the
            // pre-barrier messages (and re-seed the cursor) at replayCompleted,
            // resurrecting cleared history.
            if pendingHistoryResetReplay?.messagesBySessionKey[key] != nil {
                let dropped = pendingHistoryResetReplay?.messagesBySessionKey.removeValue(forKey: key) ?? []
                for message in dropped {
                    pendingHistoryResetReplay?.notificationSequenceByMessageId.removeValue(forKey: message.id)
                }
            }
        }
    }

    private func removeSession(sessionKey: String, reason: String) {
        _ = reason
        sessionMessages.removeValue(forKey: sessionKey)
        persistMessages([], for: sessionKey)
        lastReadMessageIdBySession.removeValue(forKey: sessionKey)
        streamTailStateBySession.removeValue(forKey: sessionKey)
        streamDotStateBySession.removeValue(forKey: sessionKey)
        sessionStatusBySessionKey.removeValue(forKey: sessionKey)
        sessionStatusRefreshTasks.removeValue(forKey: sessionKey)?.cancel()
        usageFollowUpFreshnessBySessionKey.removeValue(forKey: sessionKey)
        usageFollowUpCountBySessionKey.removeValue(forKey: sessionKey)
        let removedIDs = Set(pendingLocalMessages.filter { $0.sessionKey == sessionKey }.map(\.id))
        pendingLocalMessages.removeAll { $0.sessionKey == sessionKey }
        ackedPendingLocalMessageIDs.subtract(removedIDs)
        for id in removedIDs {
            crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: id)
            messageFailures.removeValue(forKey: id)
        }
        if !removedIDs.isEmpty {
            bumpSendIndicatorRevision()
        }
        chatService.setReplayCursor(nil, for: sessionKey)
        persistLastReadMessageId(nil, for: sessionKey)
        if typingSessionKey == sessionKey {
            typingSessionKey = nil
            isAssistantTyping = false
        }
        clearLiveProgress(sessionKey: sessionKey, runId: nil, messageId: nil)
        clearTypingIndicatorMorphTarget(for: sessionKey)
        if sessionKey == engineActiveSessionKey {
            messages = []
        }
    }

    private func clearAllForLogout(reason: String) {
        _ = reason
        let sessionKeysToClear = Set(sessionMessages.keys)
            .union(streamsBySessionKey.keys)
            .union(lastReadMessageIdBySession.keys)
            .union(streamTailStateBySession.keys)
            .union(streamDotStateBySession.keys)
        for key in sessionKeysToClear {
            persistLastReadMessageId(nil, for: key)
            persistMessages([], for: key)
        }
        sessionMessages.removeAll()
        streamsBySessionKey.removeAll()
        orderedSessionKeys = []
        syntheticSessionKeys.removeAll()
        lastReadMessageIdBySession.removeAll()
        streamTailStateBySession.removeAll()
        streamDotStateBySession.removeAll()
        discardCrossChatNotificationBatches()
        messageFailures.removeAll()
        pendingLocalMessages.removeAll()
        ackedPendingLocalMessageIDs.removeAll()
        activeClientMessageId = nil
        activeCrossChatNotificationReplySourceChatId = nil
        activeSendHasReachedTransport = false
        isSending = false
        crossChatNotificationReplySourceByClientMessageId.removeAll()
        chatService.clearReplayCursors()
        clearActiveSession(clearPersistedActiveSessionKey: false)
        bumpSendIndicatorRevision()
    }

    private func applyMessagesWrite(_ newMessages: [Message], for sessionKey: String) {
        let oldCount = sessionMessages[sessionKey]?.count ?? 0
        sessionMessages[sessionKey] = newMessages
        messageListRevisionBySession[sessionKey, default: 0] &+= 1
        let newCount = newMessages.count
        if oldCount > 0, newCount == 0 {
            StreamSwitchTiming.log("stream_messages_unloaded oldCount=\(oldCount) newCount=0", sessionKey: sessionKey)
        } else if oldCount == 0, newCount > 0 {
            StreamSwitchTiming.log("stream_messages_reloaded oldCount=0 newCount=\(newCount)", sessionKey: sessionKey)
        }
        persistMessages(newMessages, for: sessionKey)
        if sessionKey == engineActiveSessionKey {
            messages = newMessages
            let total = newMessages.count
            let uniqueCount = Set(newMessages.map(\.id)).count
            if uniqueCount != total {
                logger.info("message list duplicate ids detected sessionKey=\(sessionKey, privacy: .public) total=\(total, privacy: .public) unique=\(uniqueCount, privacy: .public)")
            }
        }
    }

    private func handleLifecycleOutput(_ output: ConnectionLifecycleOutput) async {
        switch output {
        case .phaseTransition(_, let to, let epoch, let reason):
            if writerCurrentEpoch != epoch {
                writerCurrentEpoch = epoch
                firstReplayAppliedEpoch = nil
                restoreTaskBySessionKey.values.forEach { $0.cancel() }
                restoreTaskBySessionKey.removeAll()
                discardCrossChatNotificationBatches(except: epoch)
                if pendingHistoryResetReplay?.epoch != epoch {
                    pendingHistoryResetReplay = nil
                }
            }
            connectionLifecyclePhase = to
#if DEBUG
            recordLifecycleDebugPhase(to)
#endif
            let mapped: ConnectionState
            switch to {
            case .live:
                mapped = .connected
            case .connecting, .authenticating, .replaying, .recovering:
                mapped = .reconnecting
            case .idle:
                mapped = .disconnected
            case .failed:
                mapped = .failed(ProviderChatService.Error.notConnected)
            }
            switch to {
            case .idle, .failed, .recovering:
                discardCrossChatNotificationBatch(epoch: epoch)
            case .connecting, .authenticating, .replaying, .live:
                break
            }
            transitionConnectionState(mapped, source: .lifecycleCoordinator)
            // Auth-invalid failures: clear credentials so RootView routes to pairing recovery.
            // Transport/provider-down failures stay in failed state for manual retry.
            if to == .failed, case .failure(let failureReason) = reason,
               failureReason == .authRejected || failureReason == .tokenRevoked {
                logger.info("auth-invalid failure reason=\(String(describing: failureReason), privacy: .public) — clearing credentials for pairing recovery")
                auth.clearCredentials()
            }
        case .restoreCacheRequested(let epoch):
            for sessionKey in orderedSessionKeys {
                restoreCachedMessagesIfNeeded(for: sessionKey, epoch: epoch)
            }
        case .historyResetRequired(let epoch):
            handleHistoryResetRequired(epoch: epoch)
        case .replayStarted(let epoch, _, let replayTruncated, _):
            beginCrossChatNotificationBatch(epoch: epoch, waitsForTruncationBoundary: replayTruncated)
        case .serverMessage(let epoch, let payload):
            await handleLifecycleServerMessage(epoch: epoch, payload: payload)
        case .historyCleared(_, let sessionKey):
            handleStreamHistoryCleared(sessionKey: sessionKey)
        case .replayCompleted(let epoch):
            applyPendingHistoryResetReplayIfNeeded()
            markMissingFinalsAfterReplay()
            commitCrossChatNotificationBatchIfReady(epoch: epoch, reachedTruncationBoundary: false)
        case .historyTruncated(let epoch):
            logger.info("history truncated for epoch=\(epoch, privacy: .public)")
            commitCrossChatNotificationBatchIfReady(epoch: epoch, reachedTruncationBoundary: true)
        }
    }

    private func handleConnectionFailure(_ error: Swift.Error) {
        logger.info("connection failure handled silently: \(error.localizedDescription, privacy: .public)")
    }

    private func handleTransportLossIfNeeded(_ error: Swift.Error, didStartChatSend: Bool) {
        guard didStartChatSend, isNetworkConnectionLost(error) else { return }
        Task { await lifecycleCoordinator.reconnectIntentTransportInterrupted() }
    }

    private func isNetworkConnectionLost(_ error: Swift.Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.networkConnectionLost.rawValue
    }

    private func markPendingMessagesAsFailedForConnectionLoss() {
        guard !pendingLocalMessages.isEmpty else { return }
        let pendingIds = Set(pendingLocalMessages.map(\.id))
        let failedIds = pendingIds.subtracting(ackedPendingLocalMessageIDs)
        for id in failedIds {
            messageFailures[id] = MessageFailure(code: "connection_lost", message: nil)
        }
        pendingLocalMessages.removeAll()
        ackedPendingLocalMessageIDs.removeAll()
        for id in pendingIds {
            crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: id)
        }
        bumpSendIndicatorRevision()
        if let activeClientMessageId, pendingIds.contains(activeClientMessageId) {
            self.activeClientMessageId = nil
            self.activeCrossChatNotificationReplySourceChatId = nil
            self.activeSendHasReachedTransport = false
            self.isSending = false
        }
    }

    private func markPendingMessagesFailedForUnscopedMessageError(code: String, message: String?) {
        guard !pendingLocalMessages.isEmpty else { return }
        let pendingIds = Set(pendingLocalMessages.map(\.id))
        let failedIds = pendingIds.subtracting(ackedPendingLocalMessageIDs)
        for id in failedIds {
            messageFailures[id] = MessageFailure(code: code, message: message)
        }
        pendingLocalMessages.removeAll { failedIds.contains($0.id) }
        ackedPendingLocalMessageIDs.subtract(failedIds)
        for id in failedIds {
            crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: id)
        }
        if !failedIds.isEmpty {
            bumpSendIndicatorRevision()
        }
        if let activeClientMessageId, failedIds.contains(activeClientMessageId) {
            self.activeClientMessageId = nil
            self.activeCrossChatNotificationReplySourceChatId = nil
            self.activeSendHasReachedTransport = false
            self.isSending = false
        }
    }

    private func performSend(clientId: String,
                             content: String,
                             pendingAttachments: [PendingAttachment],
                             references: [MessageReferenceContext],
                             sessionKey: String?,
                             clearInputOnSuccess: Bool = true,
                             onSuccess: (@MainActor (_ clientId: String) -> Void)? = nil) async {
        defer { sendTask = nil }
        var didStartChatSend = false
        do {
            print("[ClawlineSendDiag] vm_perform_send_start id=\(clientId) sessionKey=\(sessionKey ?? "nil") contentChars=\(content.count) attachments=\(pendingAttachments.count) references=\(references.count)")
            let wireAttachments = try await buildWireAttachments(from: pendingAttachments, content: content)
            print("[ClawlineSendDiag] vm_wire_attachments_ready id=\(clientId) sessionKey=\(sessionKey ?? "nil") wireAttachments=\(wireAttachments.count)")
            try Task.checkCancellation()
            didStartChatSend = true
            activeSendHasReachedTransport = true
            print("[ClawlineSendDiag] vm_call_chat_service_send id=\(clientId) sessionKey=\(sessionKey ?? "nil")")
            try await chatService.send(
                id: clientId,
                content: content,
                attachments: wireAttachments,
                sessionKey: sessionKey,
                references: references
            )
            print("[ClawlineSendDiag] vm_chat_service_send_success id=\(clientId) sessionKey=\(sessionKey ?? "nil")")
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "success localId=\(clientId)")
#endif
                if clearInputOnSuccess {
                    clearInput()
                }
                onSuccess?(clientId)
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        } catch is CancellationError {
            print("[ClawlineSendDiag] vm_perform_send_cancelled id=\(clientId) sessionKey=\(sessionKey ?? "nil") reachedTransport=\(didStartChatSend)")
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "failure localId=\(clientId) reason=cancelled")
#endif
                if activeSendHasReachedTransport {
                    removePendingLocalMessage(id: clientId, reason: "send_cancel_after_transport")
                } else {
                    markLocalMessageCanceled(id: clientId)
                }
                crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: clientId)
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        } catch let attachmentError as AttachmentError {
            print("[ClawlineSendDiag] vm_perform_send_attachment_failure id=\(clientId) sessionKey=\(sessionKey ?? "nil") error=\(attachmentError.localizedDescription)")
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(
                    .sendResult,
                    detail: "failure localId=\(clientId) reason=attachment_\(attachmentError.localizedDescription)"
                )
#endif
                toastManager.show(error: attachmentError)
                markLocalMessageFailed(
                    id: clientId,
                    code: "upload_failed_retryable",
                    message: nil
                )
                crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: clientId)
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        } catch {
            print("[ClawlineSendDiag] vm_perform_send_failure id=\(clientId) sessionKey=\(sessionKey ?? "nil") reachedTransport=\(didStartChatSend) error=\(error.localizedDescription)")
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(
                    .sendResult,
                    detail: "failure localId=\(clientId) reason=\(error.localizedDescription)"
                )
#endif
                handleTransportLossIfNeeded(error, didStartChatSend: didStartChatSend)
                toastManager.show(error.localizedDescription)
                markLocalMessageFailed(
                    id: clientId,
                    code: "queue_failed",
                    message: nil
                )
                crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: clientId)
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        }
    }

    private func performRetrySend(clientId: String,
                                  content: String,
                                  attachments: [Attachment],
                                  sessionKey: String?) async {
        defer { sendTask = nil }
        var didStartChatSend = false
        do {
            let wireAttachments = try await buildWireAttachments(from: attachments, content: content)
            try Task.checkCancellation()
            didStartChatSend = true
            activeSendHasReachedTransport = true
            try await chatService.send(
                id: clientId,
                content: content,
                attachments: wireAttachments,
                sessionKey: sessionKey,
                references: []
            )
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "success localId=\(clientId) retry=1")
#endif
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        } catch is CancellationError {
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "failure localId=\(clientId) reason=cancelled retry=1")
#endif
                if activeSendHasReachedTransport {
                    removePendingLocalMessage(id: clientId, reason: "retry_cancel_after_transport")
                } else {
                    markLocalMessageCanceled(id: clientId)
                }
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        } catch let attachmentError as AttachmentError {
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(
                    .sendResult,
                    detail: "failure localId=\(clientId) reason=attachment_\(attachmentError.localizedDescription) retry=1"
                )
#endif
                toastManager.show(error: attachmentError)
                markLocalMessageFailed(
                    id: clientId,
                    code: "upload_failed_retryable",
                    message: nil
                )
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        } catch {
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(
                    .sendResult,
                    detail: "failure localId=\(clientId) reason=\(error.localizedDescription) retry=1"
                )
#endif
                handleTransportLossIfNeeded(error, didStartChatSend: didStartChatSend)
                toastManager.show(error.localizedDescription)
                markLocalMessageFailed(
                    id: clientId,
                    code: "queue_failed",
                    message: nil
                )
                isSending = false
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
        }
    }

    private func buildWireAttachments(from attachments: [PendingAttachment],
                                      content: String) async throws -> [WireAttachment] {
        var results: [WireAttachment] = []
        let contentBytes = content.lengthOfBytes(using: .utf8)
        if contentBytes > PendingAttachment.totalPayloadByteLimit {
            throw AttachmentError.payloadTooLarge
        }

        var inlineBytes = 0
        for attachment in attachments {
            try Task.checkCancellation()
            let (preparedData, preparedMime) = try ImageAttachmentPreparer.prepareForModel(
                data: attachment.data, mimeType: attachment.mimeType
            )
            if preparedData.count < attachment.data.count {
                logger.info("image downscaled from=\(attachment.data.count, privacy: .public) to=\(preparedData.count, privacy: .public)")
            }
            let canInline = PendingAttachment.inlineMimeTypes.contains(preparedMime.lowercased())
                && preparedData.count <= PendingAttachment.inlineByteLimit
                && inlineBytes + preparedData.count <= PendingAttachment.inlineTotalByteLimit
                && contentBytes + inlineBytes + preparedData.count <= PendingAttachment.totalPayloadByteLimit

            if canInline {
                logger.info("attachment inline id=\(attachment.id.uuidString, privacy: .public) bytes=\(preparedData.count, privacy: .public)")
                results.append(.image(mimeType: preparedMime, data: preparedData))
                inlineBytes += preparedData.count
                continue
            }

            if preparedData.count > PendingAttachment.maxUploadByteLimit {
                throw AttachmentError.uploadTooLarge
            }

            if let cachedAssetId = uploadedAssetIds[attachment.id] {
                results.append(.asset(assetId: cachedAssetId))
                continue
            }

            let assetId = try await uploadService.upload(
                data: preparedData,
                mimeType: preparedMime,
                filename: attachment.filename
            )
            uploadedAssetIds[attachment.id] = assetId
            logger.info("attachment uploaded id=\(attachment.id.uuidString, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(preparedData.count, privacy: .public)")
            results.append(.asset(assetId: assetId))
        }
        return results
    }

    private func buildWireAttachments(from attachments: [Attachment],
                                      content: String) async throws -> [WireAttachment] {
        var results: [WireAttachment] = []
        let contentBytes = content.lengthOfBytes(using: .utf8)
        if contentBytes > PendingAttachment.totalPayloadByteLimit {
            throw AttachmentError.payloadTooLarge
        }

        var inlineBytes = 0
        for attachment in attachments {
            try Task.checkCancellation()

            if let assetId = attachment.assetId {
                results.append(.asset(assetId: assetId))
                continue
            }

            guard let rawData = attachment.data else {
                throw AttachmentError.invalidData
            }
            let rawMime = attachment.mimeType ?? "application/octet-stream"
            let (data, mimeType) = try ImageAttachmentPreparer.prepareForModel(data: rawData, mimeType: rawMime)
            if data.count < rawData.count {
                logger.info("image downscaled retry from=\(rawData.count, privacy: .public) to=\(data.count, privacy: .public)")
            }
            let canInline = PendingAttachment.inlineMimeTypes.contains(mimeType.lowercased())
                && data.count <= PendingAttachment.inlineByteLimit
                && inlineBytes + data.count <= PendingAttachment.inlineTotalByteLimit
                && contentBytes + inlineBytes + data.count <= PendingAttachment.totalPayloadByteLimit

            if canInline {
                results.append(.image(mimeType: mimeType, data: data))
                inlineBytes += data.count
                continue
            }

            if data.count > PendingAttachment.maxUploadByteLimit {
                throw AttachmentError.uploadTooLarge
            }

            let assetId = try await uploadService.upload(
                data: data,
                mimeType: mimeType,
                filename: nil
            )
            results.append(.asset(assetId: assetId))
        }

        return results
    }

    private func findMessage(id: String) -> (message: Message, sessionKey: String, index: Int)? {
        for (sessionKey, list) in sessionMessages {
            if let index = list.firstIndex(where: { $0.id == id }) {
                return (list[index], sessionKey, index)
            }
        }
        return nil
    }

    func replyReference(for message: Message) -> PendingMessageReference? {
        guard message.role == .user else { return nil }
        guard let referencedMessage = resolvedReplyTarget(for: message) else { return nil }
        return PendingMessageReference(message: referencedMessage)
    }

    func replyReferenceFingerprint(for message: Message) -> Int {
        guard let reference = replyReference(for: message) else { return 0 }
        var hasher = Hasher()
        hasher.combine(reference.sessionKey)
        hasher.combine(reference.llmVisibleMessageId)
        hasher.combine(reference.messageRole.rawValue)
        hasher.combine(reference.createdAt.timeIntervalSince1970)
        hasher.combine(reference.clientMessageId)
        hasher.combine(reference.preview)
        return hasher.finalize()
    }

    private func resolvedReplyTarget(for message: Message) -> Message? {
        let candidateIds = [
            message.replyToMessageId,
            message.replyToClientMessageId
        ].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !candidateIds.isEmpty else { return nil }

        guard let sessionMessageList = sessionMessages[message.sessionKey] else {
            return nil
        }
        for candidateId in candidateIds {
            if let resolved = sessionMessageList.first(where: { matchesReplyIdentifier(candidateId, message: $0) }) {
                return resolved
            }
        }
        return nil
    }

    private func matchesReplyIdentifier(_ identifier: String, message: Message) -> Bool {
        message.id == identifier || message.clientMessageId == identifier
    }

    private func makeDisplayAttachments(from pendingAttachments: [PendingAttachment]) -> [Attachment] {
        pendingAttachments.map { pending in
            let type: AttachmentType
            if pending.mimeType.lowercased().hasPrefix("image/") {
                type = .image
            } else {
                type = .document
            }
            return Attachment(
                id: pending.id.uuidString,
                type: type,
                mimeType: pending.mimeType,
                data: type == .image ? pending.data : nil,
                assetId: nil,
                filename: pending.filename,
                size: pending.data.count
            )
        }
    }

    private func pruneAttachmentData() {
        guard !attachmentData.isEmpty || !stagedAttachmentProtection.isEmpty || !uploadedAssetIds.isEmpty else {
            return
        }
        let referencedIds = Set(inputContent.pendingAttachmentIds())
        stagedAttachmentProtection.formIntersection(Set(attachmentData.keys))
        stagedAttachmentProtection.subtract(referencedIds)
        let orphanedKeys = attachmentData.keys.filter {
            !referencedIds.contains($0) && !stagedAttachmentProtection.contains($0)
        }
        orphanedKeys.forEach { attachmentData.removeValue(forKey: $0) }
        orphanedKeys.forEach { uploadedAssetIds.removeValue(forKey: $0) }
    }

    private func pruneMessageReferenceData() {
        guard !messageReferenceData.isEmpty else { return }
        let referencedIds = Set(inputContent.pendingMessageReferenceIds())
        messageReferenceData = messageReferenceData.filter { referencedIds.contains($0.key) }
    }

    private static func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        let safeLength = max(0, min(range.length, length - location))
        return NSRange(location: location, length: safeLength)
    }

    private func handleMemoryWarning() {
        presentationCache.removeAll()
        tableParseStates.removeAll()
    }

    @MainActor
    @objc
    private func handleMemoryWarningNotification() {
        handleMemoryWarning()
    }

    private func clearInput() {
        inputContent = NSAttributedString(string: "")
        attachmentData.removeAll()
        messageReferenceData.removeAll()
        uploadedAssetIds.removeAll()
        stagedAttachmentProtection.removeAll()
        inputResetToken &+= 1
    }

    func refreshInputEditorContent() {
        inputResetToken &+= 1
    }

    func presentation(for message: Message, metrics: ChatFlowTheme.Metrics) -> MessagePresentation {
        // Provenance messages present (and are therefore measured, sized, and
        // copied) from the STRIPPED body on tightbeam servers — the same seam
        // the bubble renders from, so V1/V2 sizing can never classify off the
        // hidden stamp line (spec §T-D strip rule).
        let displayMessage = isTightbeamServer ? message.strippingProvenanceStampForDisplay() : message
        let key = PresentationCacheKey(
            messageID: message.id,
            isCompact: metrics.isCompact,
            stripsProvenance: displayMessage.content != message.content
        )
        let fingerprint = presentationFingerprint(for: message)
        if let cached = presentationCache[key], cached.fingerprint == fingerprint {
            return cached.presentation
        }

        var state = tableParseStates[message.id] ?? StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: displayMessage,
            metrics: metrics,
            streamingState: &state
        )
        var resolvedPresentation = presentation

        if !message.streaming, state.isDirty {
            var canonicalState = StreamingTableParseState()
            resolvedPresentation = MessagePresentationBuilder.build(
                from: displayMessage,
                metrics: metrics,
                streamingState: &canonicalState
            )
        }

        if message.streaming {
            tableParseStates[message.id] = state
        } else {
            tableParseStates[message.id] = nil
        }

        presentationCache[key] = PresentationCacheEntry(
            fingerprint: fingerprint,
            presentation: resolvedPresentation
        )
        trimPresentationCache()
        trimStreamingStates()
        return resolvedPresentation
    }

    func failureMessage(for messageId: String) -> String? {
        guard let failure = messageFailures[messageId] else { return nil }
        return userFacingMessage(for: failure.code, fallback: failure.message)
    }

    func liveProgress(for sessionKey: String) -> LiveAgentProgress? {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return nil }
        return liveProgressBySessionKey[normalizedSessionKey]
    }

    func liveProgressSummary(for sessionKey: String) -> String? {
        liveProgress(for: sessionKey)?.summary
    }

    func shouldShowPromptStageIndicator(in sessionKey: String) -> Bool {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return false }
        return liveProgressBySessionKey[normalizedSessionKey] != nil ||
            shouldShowTypingIndicator(in: normalizedSessionKey)
    }

    func promptStageIndicatorAnchorMessageId(in sessionKey: String) -> String? {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return nil }
        return liveProgressBySessionKey[normalizedSessionKey]?.messageId
    }

    func sendIndicatorState(for messageId: String) -> MessageSendIndicatorState? {
        if let failure = failureMessage(for: messageId) {
            return .failed(failure)
        }
        guard pendingLocalMessages.contains(where: { $0.id == messageId }),
              !ackedPendingLocalMessageIDs.contains(messageId) else {
            return nil
        }
        return .pending
    }

    private func handle(serviceEvent: ChatServiceEvent) {
        switch serviceEvent {
        case .messageError(let messageId, let code, let message):
            if isNoReply(code: code, message: message) {
                handleNoReplyAck(messageId: messageId)
                return
            }
            scheduleSessionStatusRefreshAfterTerminalMessageEvent(
                messageId: messageId,
                reason: "messageErrorTerminal"
            )
            if let messageId, ackedPendingLocalMessageIDs.contains(messageId) {
                return
            }
            if shouldShowMessageErrorToast(code: code) {
                let resolved = userFacingMessage(for: code, fallback: message)
                toastManager.show(resolved)
            }
            guard let messageId else {
                clearAllLiveProgress()
                markPendingMessagesFailedForUnscopedMessageError(code: code, message: message)
                return
            }
            clearLiveProgress(messageId: messageId)
            messageFailures[messageId] = MessageFailure(code: code, message: message)
            crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: messageId)
            if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == messageId }) {
                pendingLocalMessages.remove(at: pendingIndex)
            }
            ackedPendingLocalMessageIDs.remove(messageId)
            bumpSendIndicatorRevision()
            if activeClientMessageId == messageId {
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
            isSending = false
        case .messageAcked(let messageId):
            markMessageAcceptedForDelivery(messageId: messageId, reason: "messageAcked")
        case .agentProgress(let progress):
            handleAgentProgress(progress)
        case .promptTurnState(let event):
            handlePromptTurnState(event)
        case .connectionInterrupted(let reason):
            logger.info("connection interrupted reason=\(reason ?? "unknown", privacy: .public)")
            markPendingMessagesAsFailedForConnectionLoss()
            Task { await lifecycleCoordinator.reconnectIntentTransportInterrupted() }
        case .userInfo(let info):
            auth.updateAdminStatus(info.isAdmin)
        case .typingStateChanged(let isTyping, let sessionKey):
            logger.info(
                "typingStateChanged isTyping=\(isTyping, privacy: .public) sessionKey=\(sessionKey, privacy: .public) engineActiveSessionKey=\(self.engineActiveSessionKey, privacy: .public) uiSelectedSessionKey=\(self.uiSelectedSessionKey, privacy: .public)"
            )
            ensureStreamEntry(for: sessionKey)
            if isTyping {
                self.isAssistantTyping = true
                self.typingSessionKey = sessionKey
                self.scheduleSessionStatusRefresh(for: sessionKey, reason: "typingStarted")
            } else if self.typingSessionKey == sessionKey {
                // Only clear if the stop event is for the same session we're tracking
                self.isAssistantTyping = false
                self.typingSessionKey = nil
                self.scheduleSessionStatusRefresh(for: sessionKey, reason: "typingStopped")
            }
        case .streamSnapshot(let streams):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = true
            hasReceivedSessionProvisioning = true
            for stream in streams {
                logger.info(
                    "stream_snapshot_debug sessionKey=\(stream.sessionKey, privacy: .public) adopted=\(stream.adopted, privacy: .public)"
                )
            }
            if accessibleSessionKeyOrder.isEmpty {
                replaceAccessibleSessionKeys(with: streams.map(\.sessionKey))
            } else {
                mergeAccessibleSessionKeys(streams.map(\.sessionKey))
            }
            applyStreamSnapshot(streams)
            refreshStreamsFromProvider(reason: "streamSnapshot")
            refreshTrackableSessions(reason: "streamSnapshot")
            attemptPendingProvisionedSendIfPossible()
        case .streamCreated(let stream):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = true
            hasReceivedSessionProvisioning = true
            mergeAccessibleSessionKeys([stream.sessionKey])
            applyStreamUpsert(stream)
            refreshStreamsFromProvider(reason: "streamCreated")
            refreshTrackableSessions(reason: "streamCreated")
            attemptPendingProvisionedSendIfPossible()
        case .streamUpdated(let stream):
            applyStreamUpsert(stream)
            refreshStreamsFromProvider(reason: "streamUpdated")
        case .streamDeleted(let sessionKey):
            if !hasReceivedExplicitSessionInfo {
                removeAccessibleSessionKey(sessionKey)
            }
            applyDeletedStreamMutation(sessionKey: sessionKey)
            refreshStreamsFromProvider(reason: "streamDeleted")
            refreshTrackableSessions(reason: "streamDeleted")
            attemptPendingProvisionedSendIfPossible()
        case .streamHistoryCleared(let sessionKey):
            handleStreamHistoryCleared(sessionKey: sessionKey)
        case .streamReadStateSnapshot(let snapshot):
            applyStreamReadStateSnapshot(snapshot)
        case .streamReadStateUpdated(let sessionKey, let lastReadMessageId):
            applyStreamReadStateUpdate(sessionKey: sessionKey, lastReadMessageId: lastReadMessageId)
        case .streamTailStateSnapshot(let snapshot):
            applyStreamTailStateSnapshot(snapshot)
        case .streamTailStateUpdated(let sessionKey, let tailState):
            applyStreamTailStateUpdate(sessionKey: sessionKey, tailState: tailState)
        case .sessionProvisioningAvailable(let supported):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = supported
            attemptPendingProvisionedSendIfPossible()
        case .serverFeatures:
            applyServerFeaturesFromEvent()
        case .sessionInfo(let info):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = true
            hasReceivedSessionProvisioning = true
            hasReceivedExplicitSessionInfo = true
            replaceAccessibleSessionKeys(with: info.sessionKeys)
            refreshTrackableSessions(reason: "sessionInfo")
            attemptPendingProvisionedSendIfPossible()
        }
    }

    private func handlePromptTurnState(_ event: PromptTurnStateEvent) {
        bindRuntimeSessionAuthority(
            runtimeSessionKey: event.payload.sessionKey,
            clientMessageID: event.payload.messageId
        )
        let state = event.payload.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terminalState = event.payload.terminalState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let messageId = event.payload.messageId
        switch terminalState ?? state {
        case "failed":
            scheduleSessionStatusRefresh(for: event.payload.sessionKey, reason: "promptTurnFailed")
            clearLiveProgress(messageId: messageId)
            messageFailures[messageId] = MessageFailure(code: event.payload.error ?? "clawline.promptTurn.failed", message: nil)
            if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == messageId }) {
                pendingLocalMessages.remove(at: pendingIndex)
            }
            ackedPendingLocalMessageIDs.remove(messageId)
            if activeClientMessageId == messageId {
                activeClientMessageId = nil
                activeCrossChatNotificationReplySourceChatId = nil
                activeSendHasReachedTransport = false
            }
            isSending = false
            bumpSendIndicatorRevision()
        case "delivered", "canceled":
            if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == messageId }) {
                pendingLocalMessages.remove(at: pendingIndex)
            }
            ackedPendingLocalMessageIDs.remove(messageId)
            clearLiveProgress(messageId: messageId)
            if state == "canceled" {
                markLocalMessageCanceled(id: messageId)
            } else {
                messageFailures.removeValue(forKey: messageId)
                bumpSendIndicatorRevision()
            }
        case "accepted", "queued":
            markMessageAcceptedForDelivery(messageId: messageId, reason: "promptTurnState")
            guard shouldRecordPromptTurnWaiting(
                sessionKey: event.payload.sessionKey,
                messageId: messageId
            ) else { return }
            recordLiveProgress(
                sessionKey: event.payload.sessionKey,
                runId: nil,
                messageId: messageId,
                seq: nil,
                stage: .acceptedWaiting,
                summary: state == "queued" ? "Waiting to start" : "Accepted by provider",
                isFailure: false
            )
        case "running":
            markMessageAcceptedForDelivery(messageId: messageId, reason: "promptTurnState")
            guard shouldRecordPromptTurnWaiting(
                sessionKey: event.payload.sessionKey,
                messageId: messageId
            ) else { return }
            recordLiveProgress(
                sessionKey: event.payload.sessionKey,
                runId: nil,
                messageId: messageId,
                seq: nil,
                stage: .acceptedWaiting,
                summary: "Waiting to start",
                isFailure: false
            )
        default:
            return
        }
    }

    private func markMessageAcceptedForDelivery(messageId: String, reason: String) {
        if let sessionKey = localMessageSessionKey(for: messageId) {
            scheduleSessionStatusRefresh(for: sessionKey, reason: reason)
        }
        ackedPendingLocalMessageIDs.insert(messageId)
        messageFailures.removeValue(forKey: messageId)
        if let replySourceChatId = crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: messageId) {
            dismissCrossChatNotification(sourceChatId: replySourceChatId)
        }
        bumpSendIndicatorRevision()
        if activeClientMessageId == messageId {
            activeClientMessageId = nil
            activeCrossChatNotificationReplySourceChatId = nil
            activeSendHasReachedTransport = false
            isSending = false
        }
    }

    private func handleAgentProgress(_ event: AgentProgressEvent) {
        let sessionKey = event.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionKey.isEmpty else { return }
        bindRuntimeSessionAuthority(
            runtimeSessionKey: sessionKey,
            clientMessageID: event.messageId
        )
        ensureStreamEntry(for: sessionKey)

        let state = event.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if shouldIgnoreStaleAgentProgress(event, current: liveProgressBySessionKey[sessionKey]) {
            return
        }
        if isTerminalAgentProgressState(state) {
            clearLiveProgress(
                sessionKey: sessionKey,
                runId: normalizedAgentProgressText(event.runId),
                messageId: normalizedAgentProgressText(event.messageId)
            )
            return
        }

        let isFailure = isFailureAgentProgressState(state)
        let summary = progressSummary(from: event, isFailure: isFailure)
        guard !summary.isEmpty else { return }
        guard let stage = progressStage(from: event, isFailure: isFailure) else { return }

        recordLiveProgress(
            sessionKey: sessionKey,
            runId: normalizedAgentProgressText(event.runId),
            messageId: normalizedAgentProgressText(event.messageId),
            seq: event.seq,
            stage: stage,
            summary: summary,
            isFailure: isFailure
        )
    }

    private func recordLiveProgress(sessionKey: String,
                                    runId: String?,
                                    messageId: String?,
                                    seq: Int?,
                                    stage: PromptProcessingStage,
                                    summary: String,
                                    isFailure: Bool) {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return }
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else { return }
        let progress = LiveAgentProgress(
            sessionKey: normalizedSessionKey,
            runId: normalizedAgentProgressText(runId),
            messageId: normalizedAgentProgressText(messageId),
            seq: seq,
            stage: stage,
            summary: normalizedSummary,
            isFailure: isFailure
        )
        ensureStreamEntry(for: normalizedSessionKey)
        liveProgressBySessionKey[normalizedSessionKey] = progress
        scheduleLiveProgressStaleTimeout(for: progress)
    }

    private func clearLiveProgress(sessionKey: String, runId: String?, messageId: String?) {
        guard let current = liveProgressBySessionKey[sessionKey] else { return }
        if let runId, let currentRunId = current.runId, currentRunId != runId { return }
        if let messageId, let currentMessageId = current.messageId, currentMessageId != messageId { return }
        liveProgressBySessionKey.removeValue(forKey: sessionKey)
        liveProgressTimeoutTasksBySessionKey.removeValue(forKey: sessionKey)?.cancel()
    }

    private func clearLiveProgress(messageId: String) {
        let sessionKeys = liveProgressBySessionKey.compactMap { entry in
            entry.value.messageId == messageId ? entry.key : nil
        }
        for sessionKey in sessionKeys {
            liveProgressBySessionKey.removeValue(forKey: sessionKey)
            liveProgressTimeoutTasksBySessionKey.removeValue(forKey: sessionKey)?.cancel()
        }
    }

    private func clearLiveProgressForAssistantFinal(_ message: Message) {
        guard let current = liveProgressBySessionKey[message.sessionKey] else { return }
        let candidateMessageIds = [
            message.clientMessageId,
            message.replyToClientMessageId,
            message.replyToMessageId,
            message.id
        ].compactMap(normalizedAgentProgressText)
        if let currentMessageId = current.messageId,
           !candidateMessageIds.contains(currentMessageId) {
            return
        }
        clearLiveProgress(
            sessionKey: message.sessionKey,
            runId: nil,
            messageId: current.messageId
        )
    }

    private func clearAllLiveProgress() {
        liveProgressBySessionKey.removeAll()
        for task in liveProgressTimeoutTasksBySessionKey.values {
            task.cancel()
        }
        liveProgressTimeoutTasksBySessionKey.removeAll()
    }

    private func scheduleLiveProgressStaleTimeout(for progress: LiveAgentProgress) {
        liveProgressTimeoutTasksBySessionKey[progress.sessionKey]?.cancel()
        liveProgressTimeoutTasksBySessionKey[progress.sessionKey] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.liveProgressStaleTimeout)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.liveProgressBySessionKey[progress.sessionKey] == progress else { return }
                self.liveProgressBySessionKey.removeValue(forKey: progress.sessionKey)
                self.liveProgressTimeoutTasksBySessionKey.removeValue(forKey: progress.sessionKey)
            }
        }
    }

    private func shouldIgnoreStaleAgentProgress(_ event: AgentProgressEvent, current: LiveAgentProgress?) -> Bool {
        guard let current else { return false }
        guard current.runId == normalizedAgentProgressText(event.runId) else { return false }
        guard let currentSeq = current.seq, let incomingSeq = event.seq else { return false }
        return incomingSeq < currentSeq
    }

    private func shouldRecordPromptTurnWaiting(sessionKey: String, messageId: String) -> Bool {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else { return false }
        guard let current = liveProgressBySessionKey[normalizedSessionKey] else { return true }
        if let currentMessageId = current.messageId, currentMessageId != messageId {
            return false
        }
        return current.runId == nil && current.seq == nil
    }

    private func progressSummary(from event: AgentProgressEvent, isFailure: Bool) -> String {
        let candidates = [
            event.event?.progressText,
            event.progressText,
            event.event?.title,
            event.title,
            event.event?.summary,
            event.summary,
            event.event?.name,
            event.name
        ]
        for candidate in candidates {
            if let text = normalizedAgentProgressText(candidate) {
                return text
            }
        }
        if isFailure {
            return "Agent progress interrupted"
        }
        return normalizedAgentProgressText(event.event?.kind)
            ?? normalizedAgentProgressText(event.state)
            ?? ""
    }

    private func progressStage(from event: AgentProgressEvent, isFailure: Bool) -> PromptProcessingStage? {
        if isFailure {
            return .failed
        }
        let kind = normalizedAgentProgressText(event.event?.kind)?.lowercased()
        let phase = normalizedAgentProgressText(event.event?.phase)?.lowercased()
        let status = normalizedAgentProgressText(event.event?.status)?.lowercased()
        if status == "blocked" || kind == "blocked" || kind == "approval" {
            return .blocked
        }
        if kind == "stage" {
            switch phase {
            case "accepted_waiting":
                return .acceptedWaiting
            case "pre_model":
                return .preModel
            case "completion_handoff":
                return .completionHandoff
            default:
                break
            }
        }
        if kind == "model" {
            return .modelActive
        }
        if ["tool", "item", "plan", "command-output", "patch", "compaction"].contains(kind) {
            return .toolActivity
        }
        return nil
    }

    private func normalizedAgentProgressText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isTerminalAgentProgressState(_ state: String?) -> Bool {
        guard let state else { return false }
        return ["final", "complete", "completed", "done", "idle"].contains(state)
    }

    private func isFailureAgentProgressState(_ state: String?) -> Bool {
        guard let state else { return false }
        return ["error", "failed", "failure", "cancelled", "canceled"].contains(state)
    }

    private func sendProvisioningState(for sessionKey: String) -> SendProvisioningState {
        guard !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        if hasReceivedSessionProvisioning {
            return isLocallySendableSessionKey(sessionKey) ? .ready : .unavailable
        }
        return .waiting
    }

    private func attemptPendingProvisionedSendIfPossible() {
        guard !isSending else { return }
        guard let pending = pendingProvisionedSend else { return }

        switch sendProvisioningState(for: pending.sessionKey) {
        case .ready:
            pendingProvisionedSend = nil
            let replySourceChatId = pending.crossChatNotificationReplySourceChatId
            beginSend(
                content: pending.content,
                pendingAttachments: pending.attachments,
                references: pending.references,
                replyToMessageId: pending.replyToMessageId,
                replyToClientMessageId: pending.replyToClientMessageId,
                sessionKey: pending.sessionKey,
                clientId: pending.clientId,
                clearInputOnSuccess: replySourceChatId == nil,
                crossChatNotificationReplySourceChatId: replySourceChatId
            )
        case .waiting:
            break
        case .unavailable:
            pendingProvisionedSend = nil
            toastManager.show("This stream is unavailable. Switch streams and try again.")
        }
    }

    private func isLocallySendableSessionKey(_ sessionKey: String) -> Bool {
        if accessibleSessionKeys.contains(sessionKey) {
            return true
        }
        return isAdoptedStream(sessionKey: sessionKey)
    }

    private func transitionConnectionState(_ state: ConnectionState,
                                           source: ConnectionStateMutationSource) {
        connectionState = state
        refreshSendButtonConnectionState()
        logger.info("connectionState transition id=\(self.instanceId, privacy: .public) source=\(source.rawValue, privacy: .public) state=\(String(describing: state), privacy: .public)")
        switch state {
        case .connected:
            allowsSessionStatusRefreshes = true
            connectionStableTask?.cancel()
            connectionStableTask = nil
            isAssistantTyping = false
            typingSessionKey = nil
            clearAllLiveProgress()
            clearAllTypingIndicatorMorphTargets()
            auth.refreshAdminStatusFromToken()
            // Pull the authed link's feature set from the service on every
            // connected transition. The `.serverFeatures` service event and
            // this connectionState stream are separate AsyncStreams with no
            // cross-stream ordering, so the event alone can be lost to a late
            // subscription or wiped by a reset that lands after it; the pull
            // makes the gate converge on the service's authoritative value.
            applyServerFeatures(chatService.serverFeatures)
            attemptPendingProvisionedSendIfPossible()
            scheduleSessionStatusRefresh(for: uiSelectedSessionKey, reason: "connectionRestored")
        case .connecting, .reconnecting:
            isAssistantTyping = false
            typingSessionKey = nil
            clearAllLiveProgress()
            clearAllTypingIndicatorMorphTargets()
        case .disconnected, .failed:
            allowsSessionStatusRefreshes = false
            cancelSessionStatusRefreshes()
            connectionStableTask?.cancel()
            connectionStableTask = nil
            resetSessionProvisioningState(clearPendingSend: true)
            markPendingMessagesAsFailedForConnectionLoss()
            isAssistantTyping = false
            typingSessionKey = nil
            clearAllLiveProgress()
            clearAllTypingIndicatorMorphTargets()
        }
    }

    private func resetSessionProvisioningState(clearPendingSend: Bool) {
        supportsSessionProvisioning = false
        serverFeatures.removeAll()
        orgOptions = nil
        isLoadingOrgOptions = false
        // Invalidate AND cancel any in-flight org-options fetch from the prior
        // session so its result cannot land in the next session's picker.
        orgOptionsLoadGeneration &+= 1
        orgOptionsLoadTask?.cancel()
        orgOptionsLoadTask = nil
        hasResolvedProvisioningCapability = false
        hasReceivedSessionProvisioning = false
        hasReceivedExplicitSessionInfo = false
        accessibleSessionKeys.removeAll()
        accessibleSessionKeyOrder.removeAll()
        trackableSessionsBySessionKey.removeAll()
        trackableSessionKeyOrder.removeAll()
        refreshStreamsTask?.cancel()
        refreshStreamsTask = nil
        refreshTrackableSessionsTask?.cancel()
        refreshTrackableSessionsTask = nil
        pendingUntrackRecovery = nil
        hasLoadedTrackableSessionsOnce = false
        hasSurfacedInitialTrackableSessionsFailure = false
        if clearPendingSend {
            pendingProvisionedSend = nil
        }
    }

    private func replaceAccessibleSessionKeys(with sessionKeys: [String]) {
        let normalized = normalizeSessionKeyList(sessionKeys)
        let available = Set(normalized)
        unavailableCrossChatNotificationSourceIds.subtract(available)
        unavailableCrossChatNotificationSourceIds.formUnion(accessibleSessionKeys.subtracting(available))
        let unavailableNotificationSourceChatIds = crossChatNotificationBubblesBySourceChatId.keys.filter {
            !available.contains($0)
        }
        for sourceChatId in unavailableNotificationSourceChatIds {
            dismissCrossChatNotification(sourceChatId: sourceChatId, markSourceRead: false)
        }
        accessibleSessionKeyOrder = normalized
        accessibleSessionKeys = Set(normalized)
    }

    private func mergeAccessibleSessionKeys(_ sessionKeys: [String]) {
        for sessionKey in normalizeSessionKeyList(sessionKeys) where accessibleSessionKeys.insert(sessionKey).inserted {
            accessibleSessionKeyOrder.append(sessionKey)
        }
    }

    private func removeAccessibleSessionKey(_ sessionKey: String) {
        unavailableCrossChatNotificationSourceIds.insert(sessionKey)
        accessibleSessionKeys.remove(sessionKey)
        accessibleSessionKeyOrder.removeAll { $0 == sessionKey }
        dismissCrossChatNotification(sourceChatId: sessionKey, markSourceRead: false)
    }

    private func replaceTrackableSessions(with sessions: [TrackableSession]) {
        trackableSessionKeyOrder = normalizeSessionKeyList(sessions.map(\.sessionKey))
        trackableSessionsBySessionKey = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.sessionKey, $0) }
        )
        hasLoadedTrackableSessionsOnce = true
        hasSurfacedInitialTrackableSessionsFailure = false
    }

    private func refreshStreamsFromProvider(reason: String) {
        refreshStreamsTask?.cancel()
        guard auth.token != nil else { return }
        refreshStreamsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let streams = try await self.chatService.fetchStreams()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.applyStreamSnapshot(streams)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.warning(
                    "stream refresh failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func refreshTrackableSessions(reason: String) {
        refreshTrackableSessionsTask?.cancel()
        guard canUseTrackFeature else {
            replaceTrackableSessions(with: [])
            return
        }
        refreshTrackableSessionsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sessions = try await self.chatService.fetchTrackableSessions()
                guard !Task.isCancelled else { return }
                self.replaceTrackableSessions(with: sessions)
            } catch {
                guard !Task.isCancelled else { return }
                let errorDescription = error.localizedDescription
                self.logger.error("trackable sessions refresh failed reason=\(reason, privacy: .public) error=\(errorDescription, privacy: .public)")
                print("[TRACKABLE_SESSIONS] reason=\(reason) error=\(errorDescription)")
                if !self.hasLoadedTrackableSessionsOnce && !self.hasSurfacedInitialTrackableSessionsFailure {
                    self.hasSurfacedInitialTrackableSessionsFailure = true
                    self.toastManager.show("Could not load Track candidates. \(errorDescription)")
                }
            }
        }
    }

    private func scheduleSessionStatusRefresh(
        for sessionKey: String,
        reason: String,
        delay: Duration = .zero
    ) {
        let normalizedSessionKey = sessionStatusAuthorityKey(for: sessionKey)
        guard !normalizedSessionKey.isEmpty else { return }
        guard auth.token != nil else { return }
        guard allowsSessionStatusRefreshes, !isRetired else { return }
        guard normalizedSessionKey == sessionStatusAuthorityKey(for: uiSelectedSessionKey) else { return }

        sessionStatusRefreshTasks[normalizedSessionKey]?.cancel()
        sessionStatusRefreshTasks[normalizedSessionKey] = Task { [weak self] in
            guard let self else { return }
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            do {
                let status = try await self.chatService.fetchSessionStatus(sessionKey: normalizedSessionKey)
                guard !Task.isCancelled else { return }
                let displayStatus = self.sessionStatusByKeepingStickyDisplayFields(
                    from: status,
                    requestedSessionKey: normalizedSessionKey
                )
                self.sessionStatusRefreshTasks[normalizedSessionKey] = nil
                self.recordSessionStatusFetchSuccess(for: normalizedSessionKey)
                self.sessionStatusBySessionKey[normalizedSessionKey] = displayStatus
                if displayStatus.sessionKey != normalizedSessionKey {
                    self.sessionStatusBySessionKey[displayStatus.sessionKey] = displayStatus
                }
                self.scheduleSessionStatusFollowUpIfNeeded(displayStatus, requestedSessionKey: normalizedSessionKey)
            } catch {
                guard !Task.isCancelled else { return }
                self.sessionStatusRefreshTasks[normalizedSessionKey] = nil
                self.logger.debug(
                    "session status refresh failed reason=\(reason, privacy: .public) sessionKey=\(normalizedSessionKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                if let retryDelay = self.recordSessionStatusFetchFailure(for: normalizedSessionKey) {
                    self.scheduleSessionStatusRefresh(
                        for: normalizedSessionKey,
                        reason: "failure_retry",
                        delay: retryDelay
                    )
                }
            }
        }
    }

    // MARK: - Session status failure state
    //
    // The footer must never spin on "loading" forever: after
    // `sessionStatusFailureThreshold` consecutive fetch failures the session is
    // marked unavailable (rendered truthfully by the footer) while a slow
    // steady retry keeps it self-healing. Any success clears the state.

    static let sessionStatusFailureThreshold = 3

    func isSessionStatusUnavailable(for sessionKey: String) -> Bool {
        sessionStatusUnavailableSessionKeys.contains(sessionStatusAuthorityKey(for: sessionKey))
    }

    private func sessionStatusAuthorityKey(for sessionKey: String) -> String {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return runtimeSessionKeyByRoutingSessionKey[normalizedSessionKey] ?? normalizedSessionKey
    }

    private func bindRuntimeSessionAuthority(runtimeSessionKey: String, clientMessageID: String?) {
        let runtimeKey = runtimeSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtimeKey.isEmpty,
              let clientMessageID = normalizedAgentProgressText(clientMessageID),
              let routingKey = localMessageSessionKey(for: clientMessageID),
              latestStatusAuthorityClientMessageIDByRoutingSessionKey[routingKey] == clientMessageID,
              routingKey != runtimeKey,
              runtimeSessionKeyByRoutingSessionKey[routingKey] != runtimeKey else {
            return
        }

        runtimeSessionKeyByRoutingSessionKey[routingKey] = runtimeKey
        sessionStatusRefreshTasks.removeValue(forKey: routingKey)?.cancel()
        sessionStatusBySessionKey.removeValue(forKey: routingKey)
        sessionStatusFailureCountBySessionKey.removeValue(forKey: routingKey)
        sessionStatusUnavailableSessionKeys.remove(routingKey)
        usageFollowUpFreshnessBySessionKey.removeValue(forKey: routingKey)
        usageFollowUpCountBySessionKey.removeValue(forKey: routingKey)
        scheduleSessionStatusRefresh(for: runtimeKey, reason: "runtimeSessionResolved")
    }

    func recordSessionStatusFetchSuccess(for sessionKey: String) {
        sessionStatusFailureCountBySessionKey.removeValue(forKey: sessionKey)
        if sessionStatusUnavailableSessionKeys.contains(sessionKey) {
            sessionStatusUnavailableSessionKeys.remove(sessionKey)
        }
    }

    /// Records one fetch failure and returns the delay before the next retry.
    /// Failures below the threshold back off quickly; at or past the threshold
    /// the session is marked unavailable and retried on a slow steady cadence.
    func recordSessionStatusFetchFailure(for sessionKey: String) -> Duration? {
        let count = (sessionStatusFailureCountBySessionKey[sessionKey] ?? 0) + 1
        sessionStatusFailureCountBySessionKey[sessionKey] = count
        switch count {
        case 1:
            return .seconds(2)
        case 2:
            return .seconds(8)
        default:
            if !sessionStatusUnavailableSessionKeys.contains(sessionKey) {
                sessionStatusUnavailableSessionKeys.insert(sessionKey)
            }
            return .seconds(30)
        }
    }

    private func sessionStatusByKeepingStickyDisplayFields(from incoming: SessionStatus,
                                                           requestedSessionKey: String) -> SessionStatus {
        let cached = sessionStatusBySessionKey[incoming.sessionKey] ?? sessionStatusBySessionKey[requestedSessionKey]
        guard let cached else { return incoming }
        let incomingThinkingLevel = realDisplayString(incoming.display.thinkingLevel)
        let incomingReasoningLevel = realDisplayString(incoming.display.reasoningLevel)
        let resolvedThinkingLevel: String?
        let resolvedReasoningLevel: String?
        switch (incomingThinkingLevel, incomingReasoningLevel) {
        case (.some(let thinking), .some(let reasoning)):
            resolvedThinkingLevel = thinking
            resolvedReasoningLevel = reasoning
        case (.some(let thinking), .none):
            resolvedThinkingLevel = thinking
            resolvedReasoningLevel = nil
        case (.none, .some(let reasoning)):
            resolvedThinkingLevel = nil
            resolvedReasoningLevel = reasoning
        case (.none, .none):
            resolvedThinkingLevel = cached.display.thinkingLevel
            resolvedReasoningLevel = cached.display.reasoningLevel
        }
        if incoming.metadataContextGeneration != cached.metadataContextGeneration {
            usageFollowUpFreshnessBySessionKey.removeValue(forKey: requestedSessionKey)
            usageFollowUpCountBySessionKey.removeValue(forKey: requestedSessionKey)
        }
        let resolvedCodexUsage = Self.resolvedCodexUsageForMetadataAuthority(
            incoming: incoming.display.codexUsage,
            incomingGeneration: incoming.metadataContextGeneration,
            cached: cached.display.codexUsage,
            cachedGeneration: cached.metadataContextGeneration
        )

        return SessionStatus(
            sessionKey: incoming.sessionKey,
            display: .init(
                model: stickyDisplayString(incoming.display.model, cached: cached.display.model),
                fallbackModels: incoming.display.fallbackModels,
                provider: incoming.display.provider,
                harness: incoming.display.harness,
                host: incoming.display.host,
                authMode: incoming.display.authMode,
                reasoningLevel: resolvedReasoningLevel,
                thinkingLevel: resolvedThinkingLevel,
                fastMode: incoming.display.fastMode ?? cached.display.fastMode,
                mode: incoming.display.mode,
                verbosity: incoming.display.verbosity,
                codexUsage: resolvedCodexUsage
            ),
            run: incoming.run,
            context: incoming.context,
            approval: incoming.approval,
            capabilities: incoming.capabilities,
            modelCatalog: incoming.modelCatalog ?? cached.modelCatalog,
            metadataContextGeneration: incoming.metadataContextGeneration
        )
    }

    static func resolvedCodexUsageForMetadataAuthority(
        incoming: SessionStatus.Display.CodexUsage?,
        incomingGeneration: String?,
        cached: SessionStatus.Display.CodexUsage?,
        cachedGeneration: String?
    ) -> SessionStatus.Display.CodexUsage? {
        guard let incomingGeneration,
              !incomingGeneration.isEmpty,
              incomingGeneration == cachedGeneration,
              let cached,
              cached.freshness == .fresh || cached.freshness == .stale,
              !cached.windows.isEmpty else {
            return incoming
        }
        let retainsLastKnownUsage: Bool = switch incoming?.freshness {
        case .loading:
            true
        case .unavailable:
            incoming?.unavailableReason == .staleExpired || incoming?.unavailableReason == .resetElapsed
        case .fresh, .stale, nil:
            false
        }
        guard retainsLastKnownUsage else { return incoming }
        return .init(
            freshness: .stale,
            fetchedAt: cached.fetchedAt,
            windows: cached.windows,
            unavailableReason: nil
        )
    }

    private func stickyDisplayString(_ incoming: String?, cached: String?) -> String? {
        realDisplayString(incoming) ?? cached
    }

    private func realDisplayString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : value
    }

    private func scheduleSessionStatusFollowUpIfNeeded(_ status: SessionStatus, requestedSessionKey: String) {
        let authorityKey = sessionStatusAuthorityKey(for: requestedSessionKey)
        guard sessionStatusAuthorityKey(for: uiSelectedSessionKey) == authorityKey
                || sessionStatusAuthorityKey(for: engineActiveSessionKey) == authorityKey else {
            return
        }
        let usage = status.display.codexUsage
        let usageFollowUpCount: Int
        if let freshness = usage?.freshness, freshness != .fresh {
            if usageFollowUpFreshnessBySessionKey[requestedSessionKey] == freshness {
                usageFollowUpCount = (usageFollowUpCountBySessionKey[requestedSessionKey] ?? 0) + 1
            } else {
                usageFollowUpCount = 1
            }
            usageFollowUpFreshnessBySessionKey[requestedSessionKey] = freshness
            usageFollowUpCountBySessionKey[requestedSessionKey] = usageFollowUpCount
        } else {
            usageFollowUpFreshnessBySessionKey.removeValue(forKey: requestedSessionKey)
            usageFollowUpCountBySessionKey.removeValue(forKey: requestedSessionKey)
            usageFollowUpCount = 0
        }

        guard let delay = Self.sessionStatusFollowUpDelay(
            usage: usage,
            usageFollowUpCount: usageFollowUpCount,
            runState: status.run.state
        ) else {
            return
        }
        scheduleSessionStatusRefresh(
            for: requestedSessionKey,
            reason: "sessionStatusFollowUp",
            delay: delay
        )
    }

    static func sessionStatusFollowUpDelay(
        usage: SessionStatus.Display.CodexUsage?,
        usageFollowUpCount: Int,
        runState: SessionStatus.Run.State
    ) -> Duration? {
        let usageDelay: Duration?
        switch usage?.freshness {
        case .loading:
            usageDelay = .seconds(usageFollowUpCount <= 1 ? 2 : 5)
        case .stale:
            usageDelay = .seconds(usageFollowUpCount <= 1 ? 5 : 30)
        case .unavailable:
            usageDelay = .seconds(30)
        case .fresh, nil:
            usageDelay = nil
        }
        let runDelay: Duration? = switch runState {
        case .running, .queued: .seconds(5)
        case .idle, .unknown: nil
        }
        switch (usageDelay, runDelay) {
        case (.some(let usageDelay), .some(let runDelay)):
            return min(usageDelay, runDelay)
        case (.some(let usageDelay), .none):
            return usageDelay
        case (.none, .some(let runDelay)):
            return runDelay
        case (.none, .none):
            return nil
        }
    }

    private func clearSessionStatusRefreshes() {
        cancelSessionStatusRefreshes()
        sessionStatusBySessionKey.removeAll()
        runtimeSessionKeyByRoutingSessionKey.removeAll()
        latestStatusAuthorityClientMessageIDByRoutingSessionKey.removeAll()
    }

    private func cancelSessionStatusRefreshes(except retainedSessionKey: String? = nil) {
        let normalizedRetainedKey = retainedSessionKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelledKeys = sessionStatusRefreshTasks.keys.filter { $0 != normalizedRetainedKey }
        for sessionKey in cancelledKeys {
            sessionStatusRefreshTasks.removeValue(forKey: sessionKey)?.cancel()
            usageFollowUpFreshnessBySessionKey.removeValue(forKey: sessionKey)
            usageFollowUpCountBySessionKey.removeValue(forKey: sessionKey)
        }
        guard normalizedRetainedKey == nil else { return }
        usageFollowUpFreshnessBySessionKey.removeAll()
        usageFollowUpCountBySessionKey.removeAll()
    }

    private func normalizeSessionKeyList(_ sessionKeys: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(sessionKeys.count)
        for sessionKey in sessionKeys {
            let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                normalized.append(trimmed)
            }
        }
        return normalized
    }

    private func activeSessionDefaultsKey() -> String {
        if let userId = auth.currentUserId, !userId.isEmpty {
            return "clawline.lastSessionKey.\(userId)"
        }
        return "clawline.lastSessionKey"
    }

    private func lastReadMessageDefaultsKey(for sessionKey: String) -> String {
        var components = ["clawline.lastReadMessageId"]
        if let userId = auth.currentUserId, !userId.isEmpty {
            components.append(userId)
        }
        components.append(sessionKey)
        return components.joined(separator: ".")
    }

    private func lastReadMessageDefaultsPrefix() -> String {
        var components = ["clawline.lastReadMessageId"]
        if let userId = auth.currentUserId, !userId.isEmpty {
            components.append(userId)
        }
        return components.joined(separator: ".") + "."
    }

    private func suppressedCrossChatNotificationEntryDefaultsKey(for sessionKey: String) -> String {
        var components = ["clawline.suppressedCrossChatNotificationEntryKeys"]
        if let userId = auth.currentUserId, !userId.isEmpty {
            components.append(userId)
        }
        components.append(sessionKey)
        return components.joined(separator: ".")
    }

    private func persistedLastReadSessionKeys() -> Set<String> {
        let prefix = lastReadMessageDefaultsPrefix()
        return Set(
            streamDefaults.dictionaryRepresentation().keys.compactMap { key in
                guard key.hasPrefix(prefix) else { return nil }
                let sessionKey = String(key.dropFirst(prefix.count))
                return sessionKey.isEmpty ? nil : sessionKey
            }
        )
    }

    private func persistLastReadMessageId(_ value: String?, for sessionKey: String) {
        let key = lastReadMessageDefaultsKey(for: sessionKey)
        if let value, !value.isEmpty {
            streamDefaults.set(value, forKey: key)
        } else {
            streamDefaults.removeObject(forKey: key)
        }
    }

    private func restoreLastReadMessageIdIfNeeded(for sessionKey: String) {
        guard lastReadMessageIdBySession[sessionKey] == nil else { return }
        if let stored = streamDefaults.string(forKey: lastReadMessageDefaultsKey(for: sessionKey)) {
            lastReadMessageIdBySession[sessionKey] = stored
        }
    }

    private func persistSuppressedCrossChatNotificationEntryKeys(for sessionKey: String) {
        let key = suppressedCrossChatNotificationEntryDefaultsKey(for: sessionKey)
        let keys = suppressedCrossChatNotificationEntryKeysBySourceChatId[sessionKey] ?? []
        if keys.isEmpty {
            streamDefaults.removeObject(forKey: key)
        } else {
            streamDefaults.set(Array(keys), forKey: key)
        }
    }

    private func restoreSuppressedCrossChatNotificationEntryKeysIfNeeded(for sessionKey: String) {
        guard suppressedCrossChatNotificationEntryKeysBySourceChatId[sessionKey] == nil else { return }
        let key = suppressedCrossChatNotificationEntryDefaultsKey(for: sessionKey)
        guard let keys = streamDefaults.stringArray(forKey: key), !keys.isEmpty else { return }
        suppressedCrossChatNotificationEntryKeysBySourceChatId[sessionKey] = Set(keys)
    }

    private func messageCacheDirectoryURL() -> URL? {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directoryURL = baseURL
            .appendingPathComponent("Clawline", isDirectory: true)
            .appendingPathComponent("MessageCache", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logger.error("message cache create dir failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        return directoryURL
    }

    private func messageCacheURL(for sessionKey: String) -> URL? {
        guard let directoryURL = messageCacheDirectoryURL() else { return nil }
        let filename = safeFilename(for: sessionKey)
        return directoryURL.appendingPathComponent("\(filename).json")
    }

    private func safeFilename(for sessionKey: String) -> String {
        let sanitized = sessionKey
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return sanitized.isEmpty ? "session" : sanitized
    }

    private func restoreCachedMessagesIfNeeded(for sessionKey: String, epoch: Int? = nil, force: Bool = false) {
        StreamSwitchTiming.log("restoreCachedMessagesIfNeeded_start", sessionKey: sessionKey)
        if epoch == nil {
            guard force || restoredSessionKeys.contains(sessionKey) == false else { return }
            restoredSessionKeys.insert(sessionKey)
        }
        if let epoch {
            guard writerCurrentEpoch == epoch else { return }
            if firstReplayAppliedEpoch == epoch { return }
        }
        guard let url = messageCacheURL(for: sessionKey) else { return }
        restoreTaskBySessionKey[sessionKey]?.cancel()
        let barrierGeneration = historyBarrierGenerationBySessionKey[sessionKey, default: 0]
        let restoreTask = Task.detached { [weak self, sessionKey, url, barrierGeneration] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url) else {
                return
            }
            await MainActor.run {
                StreamSwitchTiming.log("restoreCachedMessagesIfNeeded_disk_read_complete", sessionKey: sessionKey)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let decoded = try decoder.decode([Message].self, from: data)
                let filtered = decoded.filter { $0.sessionKey == sessionKey }
                guard !filtered.isEmpty else {
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self, filtered] in
                    guard let self else { return }
                    guard self.restoreTaskBySessionKey[sessionKey] != nil else { return }
                    // Barrier guard: a history clear that landed while this
                    // restore was reading disk moved the generation; applying
                    // the cached (pre-barrier) messages or re-seeding the
                    // replay cursor now would resurrect cleared history.
                    guard self.historyBarrierGenerationBySessionKey[sessionKey, default: 0] == barrierGeneration else { return }
                    if let epoch {
                        guard self.writerCurrentEpoch == epoch else { return }
                        guard self.firstReplayAppliedEpoch != epoch else { return }
                    }
                    filtered.forEach { self.upsert(sessionKey: sessionKey, message: $0, sourceFlags: .cache) }
                    let cachedLast = self.latestServerMessageId(from: filtered)
                    self.chatService.seedReplayCursorIfMissing(cachedLast, for: sessionKey)
                    if let cachedLast,
                       self.chatService.replayCursorSnapshot()[sessionKey] == cachedLast {
                        Task { await self.lifecycleCoordinator.updateCanonicalCursor(cachedLast) }
                    }
                    self.armForceReRead(for: sessionKey)
                    self.logger.info("message cache restored sessionKey=\(sessionKey, privacy: .public) count=\(filtered.count, privacy: .public)")
                    StreamSwitchTiming.log("restoreCachedMessagesIfNeeded_mainactor_apply_complete", sessionKey: sessionKey)
                }
            } catch {
                let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
                logger.error("message cache decode failed sessionKey=\(sessionKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        restoreTaskBySessionKey[sessionKey] = restoreTask
    }

    private func clearCursor(for sessionKey: String) {
        self.chatService.setReplayCursor(nil, for: sessionKey)
        Task { await lifecycleCoordinator.updateCanonicalCursor(nil) }
        self.armForceReRead(for: sessionKey)
    }

    private func removeCachedMessages(for sessionKey: String) {
        guard let url = messageCacheURL(for: sessionKey) else { return }
        persistDebounceTasks[sessionKey]?.cancel()
        persistDebounceTasks[sessionKey] = nil
        pendingPersistPayloads.removeValue(forKey: sessionKey)
        // Same serial queue as cache writes: this delete is ordered after any
        // write already enqueued, so pre-barrier payloads cannot land after it.
        messageCacheIO.perform {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persistMessages(_ messages: [Message], for sessionKey: String) {
        guard let url = messageCacheURL(for: sessionKey) else { return }
        let payload = trimMessagesForCache(messages, for: sessionKey)
        pendingPersistPayloads[sessionKey] = payload
        persistDebounceTasks[sessionKey]?.cancel()
        let barrierGeneration = historyBarrierGenerationBySessionKey[sessionKey, default: 0]
        persistDebounceTasks[sessionKey] = Task { [weak self, barrierGeneration] in
            guard let self else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch is CancellationError { return } catch { return }
            // Barrier guard: never enqueue a write of material captured before
            // a history clear (the payload predates the barrier by definition).
            guard self.historyBarrierGenerationBySessionKey[sessionKey, default: 0] == barrierGeneration else {
                self.pendingPersistPayloads[sessionKey] = nil
                return
            }
            guard let pendingPayload = self.pendingPersistPayloads[sessionKey] else { return }
            self.pendingPersistPayloads[sessionKey] = nil
            messageCacheIO.perform { [pendingPayload, url, sessionKey] in
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                do {
                    let data = try encoder.encode(pendingPayload)
                    try data.write(to: url, options: [.atomic])
                } catch {
                    let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
                    logger.error("message cache write failed sessionKey=\(sessionKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func setShowOnlyUserMessagesMode(_ isCollapsed: Bool, for sessionKey: String) {
        if isCollapsed {
            showOnlyUserMessagesSessionKeys.insert(sessionKey)
            restoreCachedMessagesIfNeeded(for: sessionKey, force: true)
        } else {
            showOnlyUserMessagesSessionKeys.remove(sessionKey)
            if let messages = sessionMessages[sessionKey] {
                persistMessages(messages, for: sessionKey)
            }
        }
    }

    private func messageCacheLimit(for sessionKey: String) -> Int {
        showOnlyUserMessagesSessionKeys.contains(sessionKey)
            ? Self.showOnlyUserMessagesMessageCacheLimit
            : Self.messageCacheLimit
    }

    private func trimMessagesForCache(_ messages: [Message], for sessionKey: String) -> [Message] {
        let limit = messageCacheLimit(for: sessionKey)
        guard messages.count > limit else { return messages }
        return Array(messages.suffix(limit))
    }

    private func latestServerMessageId(from messages: [Message]) -> String? {
        TranscriptServerTailOrdering.latestServerMessageId(from: messages)
    }

    private func markMissingFinalsAfterReplay() {
        for (sessionKey, streamMessages) in Array(sessionMessages) {
            for message in streamMessages where message.role == .assistant
                && message.streaming
                && normalizedServerEventID(message.replyToMessageId) != nil {
                remove(sessionKey: sessionKey, messageId: message.id, reason: "missing_final_after_replay")
            }
        }
    }

    private func clearMessageCache() {
        guard let directoryURL = messageCacheDirectoryURL() else { return }
        // Route deletes through the shared serial executor (same queue as writes)
        // so a history-reset wipe is strictly ordered after any previously
        // enqueued persist — a straggler write cannot recreate the files after.
        messageCacheIO.perform {
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
                return
            }
            for fileURL in contents {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func persistActiveSessionKey(_ sessionKey: String) {
        streamDefaults.set(sessionKey, forKey: activeSessionDefaultsKey())
    }

    private func persistedActiveSessionKey() -> String? {
        if let stored = streamDefaults.string(forKey: activeSessionDefaultsKey()),
           !stored.isEmpty {
            return stored
        }
        let legacyKey = auth.currentUserId.map { "clawline.lastChannel.\($0)" } ?? "clawline.lastChannel"
        if let raw = streamDefaults.string(forKey: legacyKey),
           let legacyStream = ChatStream(rawValue: raw),
           let migrated = preferredSessionKey(for: legacyStream) {
            streamDefaults.set(migrated, forKey: activeSessionDefaultsKey())
            return migrated
        }
        return nil
    }

    private func restoreActiveSessionKeyIfNeeded() {
        guard !didRestoreActiveSessionKey else { return }
        guard let stored = persistedActiveSessionKey() else {
            didRestoreActiveSessionKey = true
            return
        }
        if orderedSessionKeys.contains(stored) {
            setEngineActiveSessionKey(stored)
            didRestoreActiveSessionKey = true
        }
    }

    private func preferredSessionKey(for stream: ChatStream) -> String? {
        let ordered = orderedStreams
        switch stream {
        case .personal:
            return streamMainSessionKey() ?? ordered.first?.sessionKey
        case .admin:
            return ordered.first(where: { $0.kind == "dm" || $0.kind == "global_dm" })?.sessionKey
        }
    }

    func setActiveStream(_ stream: ChatStream) {
        guard let sessionKey = preferredSessionKey(for: stream) else { return }
        setEngineActiveSessionKey(sessionKey)
    }

    private func streamMainSessionKey() -> String? {
        if let main = orderedStreams.first(where: { $0.kind == "main" })?.sessionKey {
            return main
        }
        if let userId = auth.currentUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userId.isEmpty {
            return SessionKey.clawlineMain(userId: userId)
        }
        return nil
    }

    private func ensureDefaultActiveSessionIfNeeded() {
        if engineActiveSessionKey.isEmpty {
            guard !orderedSessionKeys.isEmpty else {
                return
            }
            if let main = streamMainSessionKey() {
                ensureStreamEntry(for: main)
                setEngineActiveSessionKey(main)
            } else if let first = orderedSessionKeys.first {
                setEngineActiveSessionKey(first)
            }
        }
    }

    private func ensureStreamEntry(for sessionKey: String) {
        guard !sessionKey.isEmpty else { return }
        guard streamsBySessionKey[sessionKey] == nil else { return }
        let synthesized = StreamSession(
            sessionKey: sessionKey,
            displayName: fallbackDisplayName(for: sessionKey),
            kind: "custom",
            orderIndex: nextSyntheticOrderIndex(),
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        streamsBySessionKey[sessionKey] = synthesized
        syntheticSessionKeys.insert(sessionKey)
        recalculateOrderedSessionKeys()
    }

    private func applyStreamSnapshot(_ streams: [StreamSession]) {
        let previousSessionKeys = Set(streamsBySessionKey.keys)
        let normalizedStreams = streams
        let serverKeys = Set(normalizedStreams.map(\.sessionKey))
        let adoptedStreams = streamsBySessionKey.values.filter {
            $0.adopted && !serverKeys.contains($0.sessionKey)
        }
        let mergedStreams = normalizedStreams + adoptedStreams
        let byKey: [String: StreamSession] = Dictionary(uniqueKeysWithValues: mergedStreams.map { ($0.sessionKey, $0) })
        syntheticSessionKeys = Set(
            byKey.values
                .filter { !$0.adopted && !serverKeys.contains($0.sessionKey) }
                .map(\.sessionKey)
        )
        streamsBySessionKey = byKey
        let validSessionKeys = Set(byKey.keys)
        let removedSessionKeys = previousSessionKeys.subtracting(validSessionKeys)
        unavailableCrossChatNotificationSourceIds.subtract(validSessionKeys)
        unavailableCrossChatNotificationSourceIds.formUnion(removedSessionKeys)
        for sessionKey in removedSessionKeys {
            dismissCrossChatNotification(sourceChatId: sessionKey, markSourceRead: false)
            removeSession(sessionKey: sessionKey, reason: "stream_snapshot_removed")
        }
        recalculateOrderedSessionKeys()
        for sessionKey in orderedSessionKeys {
            restoreLastReadMessageIdIfNeeded(for: sessionKey)
            restoreCachedMessagesIfNeeded(for: sessionKey)
        }
        restoreActiveSessionKeyIfNeeded()
        ensureDefaultActiveSessionIfNeeded()
        if !orderedSessionKeys.contains(engineActiveSessionKey) {
            applyStreamDeletion(sessionKey: engineActiveSessionKey)
        } else {
            messages = sessionMessages[engineActiveSessionKey] ?? []
        }
        persistStreamMetadata()
    }

    private func applyStreamUpsert(_ stream: StreamSession) {
        unavailableCrossChatNotificationSourceIds.remove(stream.sessionKey)
        streamsBySessionKey[stream.sessionKey] = stream
        syntheticSessionKeys.remove(stream.sessionKey)
        recalculateOrderedSessionKeys()
        restoreLastReadMessageIdIfNeeded(for: stream.sessionKey)
        restoreCachedMessagesIfNeeded(for: stream.sessionKey)
        ensureDefaultActiveSessionIfNeeded()
        persistStreamMetadata()
    }

    private func applyStreamDeletion(sessionKey: String) {
        unavailableCrossChatNotificationSourceIds.insert(sessionKey)
        streamsBySessionKey.removeValue(forKey: sessionKey)
        syntheticSessionKeys.remove(sessionKey)
        recalculateOrderedSessionKeys()
        removeSession(sessionKey: sessionKey, reason: "stream_deleted")

        if engineActiveSessionKey == sessionKey {
            let fallback = streamMainSessionKey().flatMap { orderedSessionKeys.contains($0) ? $0 : nil }
                ?? orderedSessionKeys.first
                ?? streamMainSessionKey()
            if let fallback {
                ensureStreamEntry(for: fallback)
                setEngineActiveSessionKey(fallback)
            } else {
                clearActiveSession()
            }
        } else if !engineActiveSessionKey.isEmpty {
            messages = sessionMessages[engineActiveSessionKey] ?? []
        }
        persistStreamMetadata()
    }

    private func applyDeleteSuccess(for stream: StreamSession) {
        if stream.adopted {
            pendingUntrackRecovery = stream
            applyDeletedStreamMutation(sessionKey: stream.sessionKey)
            refreshTrackableSessions(reason: "deleteSuccess")
            toastManager.show(
                "Session untracked.",
                actionTitle: "Undo",
                action: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.undoPendingUntrack()
                    }
                }
            )
            return
        }
        applyDeletedStreamMutation(sessionKey: stream.sessionKey)
    }

    private func applyDeletedStreamMutation(sessionKey: String) {
        dismissCrossChatNotification(sourceChatId: sessionKey, markSourceRead: false)
        if pendingUntrackRecovery?.sessionKey == sessionKey || streamsBySessionKey[sessionKey]?.adopted == true {
            unlinkTrackedSession(sessionKey: sessionKey)
            return
        }
        applyStreamDeletion(sessionKey: sessionKey)
    }

    private func unlinkTrackedSession(sessionKey: String) {
        unavailableCrossChatNotificationSourceIds.insert(sessionKey)
        streamsBySessionKey.removeValue(forKey: sessionKey)
        syntheticSessionKeys.remove(sessionKey)
        sessionStatusBySessionKey.removeValue(forKey: sessionKey)
        sessionStatusRefreshTasks.removeValue(forKey: sessionKey)?.cancel()
        usageFollowUpFreshnessBySessionKey.removeValue(forKey: sessionKey)
        usageFollowUpCountBySessionKey.removeValue(forKey: sessionKey)
        recalculateOrderedSessionKeys()

        if typingSessionKey == sessionKey {
            typingSessionKey = nil
            isAssistantTyping = false
        }
        clearLiveProgress(sessionKey: sessionKey, runId: nil, messageId: nil)
        clearTypingIndicatorMorphTarget(for: sessionKey)

        if engineActiveSessionKey == sessionKey {
            let fallback = streamMainSessionKey().flatMap { orderedSessionKeys.contains($0) ? $0 : nil }
                ?? orderedSessionKeys.first
                ?? streamMainSessionKey()
            if let fallback {
                ensureStreamEntry(for: fallback)
                setEngineActiveSessionKey(fallback)
            } else {
                clearActiveSession()
            }
        } else if !engineActiveSessionKey.isEmpty {
            messages = sessionMessages[engineActiveSessionKey] ?? []
        }

        persistStreamMetadata()
    }

    private func undoPendingUntrack() async {
        guard let stream = pendingUntrackRecovery else { return }
        pendingUntrackRecovery = nil
        _ = await trackSession(sessionKey: stream.sessionKey)
    }

    private func recalculateOrderedSessionKeys() {
        orderedSessionKeys = streamsBySessionKey.values
            .sorted { lhs, rhs in
                let lhsPriority = streamOrderingPriority(lhs)
                let rhsPriority = streamOrderingPriority(rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.orderIndex == rhs.orderIndex {
                    return lhs.sessionKey < rhs.sessionKey
                }
                return lhs.orderIndex < rhs.orderIndex
            }
            .map(\.sessionKey)
    }

    private func isProtectedNonDeletableStream(_ stream: StreamSession) -> Bool {
        switch stream.kind {
        case "main", "dm", "global_dm":
            return true
        default:
            break
        }
        if stream.sessionKey == SessionKey.admin { return true }
        if SessionKey.isClawlinePersonalDM(stream.sessionKey) { return true }
        return false
    }

    private func streamOrderingPriority(_ stream: StreamSession) -> Int {
        switch stream.kind {
        case "dm", "global_dm":
            return 0
        case "main":
            return 1
        default:
            return 2
        }
    }

    private func nextSyntheticOrderIndex(from streams: Dictionary<String, StreamSession>.Values? = nil) -> Int {
        let values = streams ?? streamsBySessionKey.values
        let maxOrder = values.map(\.orderIndex).max() ?? -1
        return maxOrder + 1
    }

    private func fallbackDisplayName(for sessionKey: String) -> String {
        guard let tail = sessionKey.split(separator: ":").last else {
            return sessionKey
        }
        return String(tail)
    }

    private func streamMetadataCacheDirectoryURL() -> URL? {
        let fileManager = FileManager.default
        guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directoryURL = baseURL
            .appendingPathComponent("Clawline", isDirectory: true)
            .appendingPathComponent("StreamCache", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            logger.error("stream cache create dir failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        return directoryURL
    }

    private func streamMetadataCacheURL(for userId: String) -> URL? {
        guard let dir = streamMetadataCacheDirectoryURL() else { return nil }
        let filename = safeFilename(for: userId)
        return dir.appendingPathComponent("\(filename).json")
    }

    private func restoreStreamMetadataIfNeeded() {
        guard let userId = auth.currentUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty else { return }
        guard restoredStreamMetadataForUserId != userId else { return }
        restoredStreamMetadataForUserId = userId
        guard let url = streamMetadataCacheURL(for: userId),
              let data = try? Data(contentsOf: url) else {
            return
        }
        let decoder = JSONDecoder()
        if let streams = try? decoder.decode([StreamSession].self, from: data) {
            streamsBySessionKey = Dictionary(uniqueKeysWithValues: streams.map { ($0.sessionKey, $0) })
            syntheticSessionKeys.removeAll()
            recalculateOrderedSessionKeys()
        }
    }

    private func persistStreamMetadata() {
        guard let userId = auth.currentUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty,
              let url = streamMetadataCacheURL(for: userId) else { return }
        let payload = orderedStreams
        Task.detached {
            let encoder = JSONEncoder()
            do {
                let data = try encoder.encode(payload)
                try data.write(to: url, options: [.atomic])
            } catch {
                let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
                logger.error("stream cache write failed userId=\(userId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func clearStreamMetadataCache() {
        let fileManager = FileManager.default
        guard let directoryURL = streamMetadataCacheDirectoryURL() else { return }
        guard let contents = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in contents {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func isImageRelatedError(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["image", "size", "bytes", "mb", "payload_too_large"]
        return keywords.contains(where: { lower.contains($0) })
    }

    private func userFacingMessage(for code: String, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty {
            if isImageRelatedError(fallback) {
                return "That image is too large for this model. Reduce image size and try again."
            }
            return fallback
        }
        switch code {
        case "invalid_message":
            return "Provider rejected that message."
        case "payload_too_large":
            return "That message is too large to send."
        case "asset_not_found":
            return "Attachment could not be found on the provider."
        case "rate_limited":
            return "Slow down a bit; you're being rate limited."
        case "upload_failed_retryable":
            return "Upload failed; try again."
        case "queue_failed", "queue_full":
            return "Message couldn't be queued. Try again."
        case "session_locked":
            return "Session is locked. Message not delivered."
        case "connection_lost":
            return "Message not delivered — connection lost."
        case "missing_final":
            return "Reply missing after reconnect. Try again."
        case "invalid_channel":
            return "Cannot send to this channel."
        default:
            return "Message failed (\(code))."
        }
    }

    private func shouldShowMessageErrorToast(code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Passive transport loss must remain silent; failed-message badge is the indicator.
        return normalized != "connection_lost"
    }

    private func markLocalMessageFailed(id: String, code: String, message: String?) {
        messageFailures[id] = MessageFailure(code: code, message: message)
        if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == id }) {
            pendingLocalMessages.remove(at: pendingIndex)
        }
        ackedPendingLocalMessageIDs.remove(id)
    }

    private func markLocalMessageCanceled(id: String) {
        if let (message, sessionKey, _) = findMessage(id: id) {
            var canceledMessage = message
            canceledMessage.deliveryState = .canceled
            canceledMessage.streaming = false
            upsert(sessionKey: sessionKey, message: canceledMessage, sourceFlags: .local)
        }
        if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == id }) {
            pendingLocalMessages.remove(at: pendingIndex)
        }
        ackedPendingLocalMessageIDs.remove(id)
        messageFailures.removeValue(forKey: id)
        bumpSendIndicatorRevision()
    }

    private func isNoReply(code: String, message: String?) -> Bool {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedCode == "no_reply" || normalizedCode == "no-reply" || normalizedCode.hasPrefix("no_reply") {
            return true
        }
        let trimmedMessage = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.uppercased() == "NO_REPLY" {
            return true
        }
        let lowered = trimmedMessage.lowercased()
        if lowered.contains("no_reply") || lowered.contains("no reply") {
            return true
        }
        if lowered.contains("unable to deliver reply") {
            return true
        }
        return false
    }

    private func isNoReplyContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.uppercased() == "NO_REPLY"
    }

    private func handleNoReplyAck(messageId: String?) {
        var resolvedSessionKey: String?
        if let messageId,
           let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == messageId }) {
            resolvedSessionKey = pendingLocalMessages[pendingIndex].sessionKey
            pendingLocalMessages.remove(at: pendingIndex)
            ackedPendingLocalMessageIDs.remove(messageId)
            bumpSendIndicatorRevision()
        }
        if let messageId, activeClientMessageId == messageId {
            activeClientMessageId = nil
            activeCrossChatNotificationReplySourceChatId = nil
            activeSendHasReachedTransport = false
        }
        if let messageId,
           let replySourceChatId = crossChatNotificationReplySourceByClientMessageId.removeValue(forKey: messageId) {
            dismissCrossChatNotification(sourceChatId: replySourceChatId)
        }
        isSending = false

        ensureDefaultActiveSessionIfNeeded()
        let sessionKey = resolvedSessionKey ?? engineActiveSessionKey
        let ack = Message(
            id: "s_no_reply_\(UUID().uuidString)",
            role: .assistant,
            content: "👀",
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: nil,
            sessionKey: sessionKey
        )
        upsert(sessionKey: sessionKey, message: ack, sourceFlags: .server)
        scheduleSessionStatusRefresh(for: sessionKey, reason: "noReplyTerminal")
    }

    private func scheduleSessionStatusRefreshAfterTerminalMessageEvent(messageId: String?, reason: String) {
        var sessionKeys = Set<String>()
        if let messageId {
            if let pending = pendingLocalMessages.first(where: { $0.id == messageId }) {
                sessionKeys.insert(pending.sessionKey)
            } else if let (_, sessionKey, _) = findMessage(id: messageId) {
                sessionKeys.insert(sessionKey)
            }
        } else {
            sessionKeys.formUnion(pendingLocalMessages.map(\.sessionKey))
        }
        if sessionKeys.isEmpty {
            let activeSessionKey = engineActiveSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !activeSessionKey.isEmpty {
                sessionKeys.insert(activeSessionKey)
            }
        }
        for sessionKey in sessionKeys {
            scheduleSessionStatusRefresh(for: sessionKey, reason: reason)
        }
    }

    private func localMessageSessionKey(for messageId: String) -> String? {
        if let pending = pendingLocalMessages.first(where: { $0.id == messageId }) {
            return pending.sessionKey
        }
        if let (_, sessionKey, _) = findMessage(id: messageId) {
            return sessionKey
        }
        return nil
    }

    private func trimPresentationCache() {
        let activeIds = Set(messages.map(\.id))
        guard !activeIds.isEmpty else { return }
        presentationCache = presentationCache.filter { activeIds.contains($0.key.messageID) }
    }

    private func trimStreamingStates(maxEntries: Int = 120) {
        let activeIds = Set(messages.prefix(100).map(\.id))
        tableParseStates = tableParseStates.filter { activeIds.contains($0.key) }
        guard tableParseStates.count > maxEntries else { return }
        let overflow = tableParseStates.count - maxEntries
        for key in tableParseStates.keys.prefix(overflow) {
            tableParseStates.removeValue(forKey: key)
        }
    }

    private struct MessageFailure: Equatable {
        let code: String
        let message: String?
    }

    private struct PresentationCacheKey: Hashable {
        let messageID: String
        let isCompact: Bool
        let stripsProvenance: Bool
    }

    private struct PresentationCacheEntry {
        let fingerprint: Int
        let presentation: MessagePresentation
    }

    private func presentationFingerprint(for message: Message) -> Int {
        var hasher = Hasher()
        hasher.combine(message.id)
        hasher.combine(message.content)
        hasher.combine(message.streaming)
        hasher.combine(message.attachments.count)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.mimeType ?? "")
            hasher.combine(attachment.assetId ?? "")
            hasher.combine(attachment.type.rawValue)
            hasher.combine(attachment.data?.count ?? 0)
        }
        return hasher.finalize()
    }

    private func handleSlashCommand(_ text: String) -> Bool {
        let lowercased = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch lowercased {
        case "/logout":
            clearInput()
            logout()
            return true
        case "/settings":
            clearInput()
            settings.toggleSettings()
            return true
        case "/connecting":
            clearInput()
            setTemporarySendButtonOverride(.reconnecting)
            return true
        case "/error", "/disconnected":
            clearInput()
            setTemporarySendButtonOverride(.disconnected)
            return true
        default:
            return false
        }
    }

    private func setTemporarySendButtonOverride(_ state: SendButtonConnectionState) {
        temporarySendButtonOverride = state
        refreshSendButtonConnectionState()
        temporarySendButtonOverrideTask?.cancel()
        let overrideDuration = temporarySendButtonOverrideDuration
        temporarySendButtonOverrideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: overrideDuration)
            } catch {
                return
            }
            self?.clearTemporarySendButtonOverride()
        }
    }

    private func clearTemporarySendButtonOverride() {
        temporarySendButtonOverrideTask?.cancel()
        temporarySendButtonOverrideTask = nil
        temporarySendButtonOverride = nil
        refreshSendButtonConnectionState()
    }

    private func refreshSendButtonConnectionState() {
        sendButtonConnectionState = temporarySendButtonOverride ?? transportSendButtonConnectionState
    }

    @MainActor
    private func connectionSnapshot() -> (token: String?, lastMessageId: String?) {
        (auth.token, legacyReplayCursorForActiveStream())
    }

    private func legacyReplayCursorForActiveStream() -> String? {
        let activeKey = uiSelectedSessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? engineActiveSessionKey
            : uiSelectedSessionKey
        guard !activeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return chatService.replayCursorSnapshot()[activeKey]
    }

    private func isReplayCursorEvent(_ message: Message) -> Bool {
        normalizedServerEventID(message.id) != nil && !message.streaming
    }

    private func normalizedServerEventID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("s_"), trimmed.count > 2 else { return nil }
        guard !trimmed.hasPrefix("s_no_reply_") else { return nil }
        return trimmed
    }

    private func markSessionRead(_ sessionKey: String, preferServerTail: Bool = false) {
        let localTailMessageId = latestServerMessageId(from: sessionMessages[sessionKey] ?? [])
        let serverTailMessageId = streamTailStateBySession[sessionKey]?.lastMessageId
        let tailMessageId =
            preferServerTail
                ? (serverTailMessageId ?? localTailMessageId)
                : (localTailMessageId ?? serverTailMessageId)
        if let tailMessageId {
            lastReadMessageIdBySession[sessionKey] = tailMessageId
            persistLastReadMessageId(tailMessageId, for: sessionKey)
            publishReadStateIfPossible(sessionKey: sessionKey, lastReadMessageId: tailMessageId)
            recomputeStreamDotState(for: sessionKey)
        }
    }

    private func markSessionRead(_ sessionKey: String, messageId: String) {
        lastReadMessageIdBySession[sessionKey] = messageId
        persistLastReadMessageId(messageId, for: sessionKey)
        publishReadStateIfPossible(sessionKey: sessionKey, lastReadMessageId: messageId)
        recomputeStreamDotState(for: sessionKey)
    }

    private func applyStreamReadStateSnapshot(_ snapshot: [String: String]) {
        var normalizedSnapshot: [String: String] = [:]
        for (sessionKey, lastReadMessageId) in snapshot {
            guard !sessionKey.isEmpty, !lastReadMessageId.isEmpty else { continue }
            normalizedSnapshot[sessionKey] = lastReadMessageId
        }
        let snapshotSessionKeys = Set(normalizedSnapshot.keys)
        let staleSessionKeys = lastReadMessageIdBySession.keys
            .reduce(into: Set<String>()) { $0.insert($1) }
            .union(persistedLastReadSessionKeys())
            .subtracting(snapshotSessionKeys)

        for sessionKey in staleSessionKeys {
            lastReadMessageIdBySession.removeValue(forKey: sessionKey)
            persistLastReadMessageId(nil, for: sessionKey)
            recomputeStreamDotState(for: sessionKey)
        }

        for (sessionKey, lastReadMessageId) in normalizedSnapshot {
            lastReadMessageIdBySession[sessionKey] = lastReadMessageId
            persistLastReadMessageId(lastReadMessageId, for: sessionKey)
            recomputeStreamDotState(for: sessionKey)
        }
    }

    private func applyStreamReadStateUpdate(sessionKey: String, lastReadMessageId: String) {
        guard !sessionKey.isEmpty, !lastReadMessageId.isEmpty else { return }
        let current = lastReadMessageIdBySession[sessionKey]
        if current == lastReadMessageId { return }
        lastReadMessageIdBySession[sessionKey] = lastReadMessageId
        persistLastReadMessageId(lastReadMessageId, for: sessionKey)
        recomputeStreamDotState(for: sessionKey)
    }

    private func applyStreamTailStateSnapshot(_ snapshot: [String: StreamTailState]) {
        var normalizedSnapshot: [String: StreamTailState] = [:]
        for (sessionKey, tailState) in snapshot {
            guard !sessionKey.isEmpty else { continue }
            normalizedSnapshot[sessionKey] = tailState
        }

        let snapshotSessionKeys = Set(normalizedSnapshot.keys)
        let staleSessionKeys = Set(streamTailStateBySession.keys).subtracting(snapshotSessionKeys)
        for sessionKey in staleSessionKeys {
            streamTailStateBySession.removeValue(forKey: sessionKey)
            recomputeStreamDotState(for: sessionKey)
        }

        for (sessionKey, tailState) in normalizedSnapshot {
            streamTailStateBySession[sessionKey] = tailState
            recomputeStreamDotState(for: sessionKey)
        }
    }

    private func applyStreamTailStateUpdate(sessionKey: String, tailState: StreamTailState) {
        guard !sessionKey.isEmpty else { return }
        if streamTailStateBySession[sessionKey] == tailState { return }
        streamTailStateBySession[sessionKey] = tailState
        recomputeStreamDotState(for: sessionKey)
    }

    private func publishReadStateIfPossible(sessionKey: String, lastReadMessageId: String) {
        guard lastReadMessageId.hasPrefix("s_") else { return }
        Task { [chatService, logger] in
            do {
                try await chatService.publishReadState(
                    sessionKey: sessionKey,
                    lastReadMessageId: lastReadMessageId
                )
            } catch {
                logger.error(
                    "stream_read_publish_failed sessionKey=\(sessionKey, privacy: .public) lastReadMessageId=\(lastReadMessageId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func recomputeStreamDotState(for sessionKey: String) {
        guard !sessionKey.isEmpty else { return }
        guard let tailState = streamTailStateBySession[sessionKey] else {
            streamDotStateBySession.removeValue(forKey: sessionKey)
            return
        }
        let dotState: StreamDotState
        if tailState.lastMessageRole == .user {
            dotState = .userTail
        } else if lastReadMessageIdBySession[sessionKey] != tailState.lastMessageId {
            dotState = .unread
        } else {
            dotState = .inactive
        }
        streamDotStateBySession[sessionKey] = dotState
    }

#if DEBUG
    func debugConnectionSnapshot() -> (token: String?, lastMessageId: String?) {
        connectionSnapshot()
    }

    func debugUpsertMessage(_ message: Message, isServer: Bool = false, isCache: Bool = false) {
        upsert(
            sessionKey: message.sessionKey,
            message: message,
            sourceFlags: MessageSourceFlags(isServer: isServer, isCache: isCache)
        )
    }

    func debugClearSessionMessages(_ sessionKey: String) {
        clearSessionMessages(sessionKey: sessionKey, reason: "debug")
    }

    func debugRemoveSessionMessages(_ sessionKey: String) {
        removeSession(sessionKey: sessionKey, reason: "debug")
    }

    func debugSessionMessageEntryExists(_ sessionKey: String) -> Bool {
        sessionMessages[sessionKey] != nil
    }

    func debugObservationStartupCount() -> Int {
        observationStartupCount
    }

    func debugPresentationCacheSize() -> Int {
        presentationCache.count
    }

    func debugTableParseStateSize() -> Int {
        tableParseStates.count
    }
#endif
}
