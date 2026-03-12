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

protocol ChatViewModelHosting: AnyObject {
    func handleSceneDidBecomeActive()
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
final class ChatViewModel: ChatViewModelHosting {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
    private let instanceId = UUID().uuidString
    @MainActor
    private static var currentConnectionOwnerId: String?
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
    private(set) var messages: [Message] = []
    private(set) var streamsBySessionKey: [String: StreamSession] = [:]
    private(set) var orderedSessionKeys: [String] = []
    private(set) var lastReadMessageIdBySession: [String: String] = [:]
    private(set) var hasUnreadBySession: [String: Bool] = [:]
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

    func stream(for sessionKey: String) -> StreamSession? {
        streamsBySessionKey[sessionKey]
    }

    var orderedStreams: [StreamSession] {
        orderedSessionKeys.compactMap { streamsBySessionKey[$0] }
    }

    var activeStream: ChatStream {
        SessionRegistry.shared.stream(for: engineActiveSessionKey)
    }

    // MARK: Stream Switch API
    // All switch mutations are MainActor-only by class annotation.
    // Steps 1-5 are intentionally synchronous (no suspension points) to keep epoch capture atomic.

    func bindStreamSwitchCoordinatorIfNeeded() {
        if uiSelectedSessionKey.isEmpty {
            setUISelectedSessionKey(engineActiveSessionKey)
        }
    }

    func requestStreamSwitch(to sessionKey: String, source: StreamSwitchSource) {
        guard orderedSessionKeys.contains(sessionKey) else { return }

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
        guard engineActiveSessionKey != sessionKey else { return }
        applyActiveSessionKey(sessionKey)
        markSessionRead(sessionKey)
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
    }

#if DEBUG
    // Explicit test-only bypass.
    func setActiveSessionKeyForTesting(_ sessionKey: String) {
        setEngineActiveSessionKey(sessionKey)
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
        ensureSessionStorage(for: sessionKey)
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
    var inputContent: NSAttributedString = NSAttributedString() {
        didSet {
            pruneAttachmentData()
            logger.info("[trace] inputContent len=\(self.inputContent.length) empty=\(self.inputContent.isEffectivelyEmpty) canSend=\(self.canSend) state=\(String(describing: self.connectionState))")
        }
    }
    var attachmentData: [UUID: PendingAttachment] = [:]
    private(set) var pendingAttachmentStageCount: Int = 0
    private var stagedAttachmentProtection: Set<UUID> = []
    private(set) var isSending: Bool = false
    private(set) var isAssistantTyping: Bool = false
    private(set) var typingSessionKey: String?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var inputResetToken: Int = 0
    private(set) var sendTask: Task<Void, Never>?
    /// Tracks if typing indicator was visible when a message arrives (for morph transition).
    private(set) var shouldMorphTypingIndicator: Bool = false
    private var isRetired = false

    private var temporarySendButtonOverride: SendButtonConnectionState?
    private var temporarySendButtonOverrideTask: Task<Void, Never>?
    private let temporarySendButtonOverrideDuration: Duration = .seconds(5)

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
            && !inputContent.isEffectivelyEmpty
    }

    var sendButtonConnectionState: SendButtonConnectionState {
        return temporarySendButtonOverride ?? transportSendButtonConnectionState
    }

    let toastManager: ToastManager

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing
    private let settings: SettingsManager
    private let deviceId: String
    let salientHighlightService: any SalientHighlightServicing
    private var observationTask: Task<Void, Never>?
    private var observationStartupTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var hasActivatedLifecycleOwnership = false
    private var lifecycleTransportEventsSubscription: AsyncStream<LifecycleTransportEvent>?
    private var lifecycleOutputsSubscription: AsyncStream<ConnectionLifecycleOutput>?
    private var lifecycleStartupGateDebugSubscription: AsyncStream<StartupGateDebugEvent>?
    private var sessionMessages: [String: [Message]] = [:]
    private var forceReReadGenerationBySession: [String: Int] = [:]
    private var pendingLocalMessages: [PendingLocalMessage] = []
    private let lifecycleCoordinator: ConnectionLifecycleCoordinator
    private var lifecycleTransportTask: Task<Void, Never>?
    private var lifecycleOutputTask: Task<Void, Never>?
    private var connectionLifecyclePhase: ConnectionLifecyclePhase = .idle
    private var connectionStableTask: Task<Void, Never>?
    private let stableConnectionInterval: Duration = .seconds(5)
    private var activeClientMessageId: String?
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
    private var writerCurrentEpoch: Int?
    private var firstReplayAppliedEpoch: Int?
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
    private let messageCacheLimit = 500
    private var restoredSessionKeys: Set<String> = []
    private var restoredStreamMetadataForUserId: String?
    private var supportsSessionProvisioning = false
    private var hasResolvedProvisioningCapability = true
    private var hasReceivedSessionProvisioning = false
    private var provisionedSessionKeys: Set<String> = []
    private var pendingProvisionedSend: PendingProvisionedSend?

    func forceReReadGeneration(for sessionKey: String) -> Int {
        forceReReadGenerationBySession[sessionKey] ?? 0
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
        let content: String
        let attachments: [PendingAttachment]
        let sessionKey: String
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
         connectionAlertGracePeriod: Duration = .seconds(2),
         nowProvider: @escaping () -> Date = Date.init,
         assistantIncomingHaptic: @escaping @MainActor () -> Void = {
             #if !os(visionOS)
             let generator = UIImpactFeedbackGenerator(style: .light)
             generator.impactOccurred()
             #endif
         }) {
        logger.info("ChatViewModel init id=\(self.instanceId, privacy: .public)")
        self.auth = auth
        self.chatService = chatService
        self.settings = settings
        self.deviceId = device.deviceId
        self.uploadService = uploadService
        self.toastManager = toastManager
        self.salientHighlightService = salientHighlightService
        self.lifecycleCoordinator = ConnectionLifecycleCoordinator(
            startAttempt: { [weak chatService] epoch, lastMessageId, token in
                chatService?.startConnectionAttempt(epoch: epoch, lastMessageId: lastMessageId, token: token)
            },
            stopAttempt: { [weak chatService] in
                chatService?.stopConnectionAttempt()
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
            let seededCursor = chatService.replayCursorSnapshot().values.max()
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
            restoreStreamMetadataIfNeeded()
            restoreActiveSessionKeyIfNeeded()
            ensureDefaultActiveSessionIfNeeded()
        } else {
            coordinatorDiag("handleAuthStateChange logout-path")
            didRestoreActiveSessionKey = false
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
        guard hasActivatedLifecycleOwnership else {
            coordinatorDiag("sceneDidBecomeActive deferred until activate")
            return
        }
        guard auth.token != nil else { return }
        logger.info("ChatViewModel sceneDidBecomeActive id=\(self.instanceId, privacy: .public) state=\(String(describing: self.connectionState), privacy: .public)")
        coordinatorDiag("sceneDidBecomeActive tokenPresent=true observationTaskNil=\(observationTask == nil)")
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
        guard isActive else { return }
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
        stopObservingLifecycle(origin: "prepareForReplacement")
        cancelSend()
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
            handleLifecycleOutput(output)
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

    func send() {
        guard !isSending else { return }
        let referencedIds = Set(inputContent.pendingAttachmentIds())
#if DEBUG
        let transportSnapshot = sendTransportSnapshot()
        imageSendLastTransportSnapshot = transportSnapshot
        recordImageSendDebugEvent(
            .sendTapped,
            detail: "textLen=\(inputContent.length) attachmentCount=\(referencedIds.count) \(transportSnapshot)"
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
            return
        }
        pruneAttachmentData()
        let (text, pendingIds) = inputContent.contentForSending()
        let pendingAttachments = pendingIds.compactMap { attachmentData[$0] }

        guard !text.isEmpty || !pendingAttachments.isEmpty else {
#if DEBUG
            recordImageSendDebugEvent(.sendResult, detail: "failure reason=empty_input")
#endif
            return
        }

        if pendingAttachments.isEmpty && handleSlashCommand(text) {
            return
        }

        ensureDefaultActiveSessionIfNeeded()
        let outboundSessionKey = engineActiveSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outboundSessionKey.isEmpty else {
#if DEBUG
            recordImageSendDebugEvent(.sendResult, detail: "failure reason=no_stream_selected")
#endif
            toastManager.show("No stream selected.")
            return
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
                return
            }
            beginSend(content: text, pendingAttachments: pendingAttachments, sessionKey: outboundSessionKey)
        case .waiting:
#if DEBUG
            recordImageSendDebugEvent(
                .sendResult,
                detail: "queued reason=provisioning_waiting \(sendTransportSnapshot())"
            )
#endif
            pendingProvisionedSend = PendingProvisionedSend(
                content: text,
                attachments: pendingAttachments,
                sessionKey: outboundSessionKey
            )
        case .unavailable:
#if DEBUG
            recordImageSendDebugEvent(
                .sendResult,
                detail: "failure reason=stream_unavailable \(sendTransportSnapshot())"
            )
#endif
            toastManager.show("This stream is unavailable. Switch streams and try again.")
        }
    }

    private func beginSend(content: String,
                           pendingAttachments: [PendingAttachment],
                           sessionKey: String) {
        let clientId = "c_\(UUID().uuidString)"
        activeClientMessageId = clientId
#if DEBUG
        recordImageSendDebugEvent(
            .sendDispatched,
            detail: "localId=\(clientId) at=\(Date().formatted(date: .omitted, time: .standard))"
        )
#endif

        isSending = true  // Set immediately to prevent double-tap race condition
        let placeholder = Message(
            id: clientId,
            role: .user,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: makeDisplayAttachments(from: pendingAttachments),
            deviceId: deviceId,
            sessionKey: sessionKey
        )
        appendMessage(placeholder)
        pendingLocalMessages.append(PendingLocalMessage(id: clientId, sessionKey: sessionKey))

        sendTask = Task { [weak self] in
            await self?.performSend(
                clientId: clientId,
                content: content,
                pendingAttachments: pendingAttachments,
                sessionKey: sessionKey
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
        guard let (message, sessionKey, index) = findMessage(id: messageId) else { return }

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

        var messageList = sessionMessages[sessionKey] ?? []
        messageList.remove(at: index)
        messageList.append(resentMessage)
        setMessages(messageList, for: sessionKey)

        pendingLocalMessages.removeAll { $0.id == messageId }
        pendingLocalMessages.append(PendingLocalMessage(id: clientId, sessionKey: sessionKey))
        messageFailures.removeValue(forKey: messageId)

        isSending = true
        activeClientMessageId = clientId

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
        guard isSending else { return }
        sendTask?.cancel()
        sendTask = nil
        if let activeClientMessageId {
            removePlaceholder(withId: activeClientMessageId)
        }
        activeClientMessageId = nil
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
        cancelSend()
        observationStartupTask?.cancel()
        observationStartupTask = nil
        activationTask?.cancel()
        activationTask = nil
        hasActivatedLifecycleOwnership = false
        clearTemporarySendButtonOverride()
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
        chatService.clearReplayCursors()
        var sessionKeysToClear = Set(sessionMessages.keys)
        sessionKeysToClear.formUnion(streamsBySessionKey.keys)
        for key in sessionKeysToClear {
            persistLastReadMessageId(nil, for: key)
        }
        lastReadMessageIdBySession.removeAll()
        hasUnreadBySession.removeAll()
        auth.clearCredentials()
        messageFailures.removeAll()
        clearInput()
        pendingAttachmentStageCount = 0
        sessionMessages = [:]
        clearActiveSession(clearPersistedActiveSessionKey: false)
        streamsBySessionKey = [:]
        orderedSessionKeys = []
        syntheticSessionKeys = []
        pendingLocalMessages.removeAll()
        isAssistantTyping = false
        typingSessionKey = nil
        shouldMorphTypingIndicator = false
        connectionStableTask?.cancel()
        connectionStableTask = nil
        restoredSessionKeys.removeAll()
        forceReReadGenerationBySession.removeAll()
        restoredStreamMetadataForUserId = nil
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
        if stream.sessionKey == SessionKey.admin { return false }
        if stream.kind == "main" { return true }
        if SessionKey.isClawlinePersonalDM(stream.sessionKey) { return true }
        guard !stream.isBuiltIn else { return false }
        return !isProtectedNonDeletableStream(stream)
    }

    func createStream(displayName: String) async -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let stream = try await chatService.createStream(
                displayName: trimmed,
                idempotencyKey: Self.makeIdempotencyKey()
            )
            applyStreamUpsert(stream)
            setEngineActiveSessionKey(stream.sessionKey)
            return true
        } catch {
            toastManager.show(error.localizedDescription)
            return false
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
        guard canDeleteStream(sessionKey: sessionKey) else { return false }
        let idempotencyKey = Self.makeIdempotencyKey()
        do {
            _ = try await chatService.deleteStream(
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )
            applyStreamDeletion(sessionKey: sessionKey)
            return true
        } catch {
            if shouldRetryDeleteOnActiveConnection(after: error) {
                do {
                    try await reconnectActiveTransportForControlPlane()
                    _ = try await chatService.deleteStream(
                        sessionKey: sessionKey,
                        idempotencyKey: idempotencyKey
                    )
                    applyStreamDeletion(sessionKey: sessionKey)
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

    private func reconnectActiveTransportForControlPlane() async throws {
        guard let token = auth.token else {
            throw ProviderChatService.Error.notConnected
        }
        let lastMessageId = chatService.replayCursorSnapshot().values.max()
        try await chatService.connect(token: token, lastMessageId: lastMessageId)
    }

    private static func makeIdempotencyKey() -> String {
        "req_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private func handleIncoming(_ message: Message) {
        let snippet = String(message.content.prefix(80))
        logger.info(
            "incoming id=\(message.id, privacy: .public) sessionKey=\(message.sessionKey, privacy: .public) stream=\(message.stream.rawValue, privacy: .public) role=\(String(describing: message.role), privacy: .public) streaming=\(message.streaming, privacy: .public) deviceId=\(message.deviceId ?? "nil", privacy: .public) snippet=\"\(snippet, privacy: .public)\""
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
                sessionKey: message.sessionKey
            )
        }

        // Check if this is an assistant message arriving while typing indicator is visible.
        // If so, the UI should morph the typing indicator into this message instead of inserting new.
        ensureStreamEntry(for: message.sessionKey)

        if message.role == .assistant,
           isAssistantTyping,
           typingSessionKey == message.sessionKey {
            shouldMorphTypingIndicator = true
            isAssistantTyping = false
            self.typingSessionKey = nil
        } else {
            shouldMorphTypingIndicator = false
        }

        if replacePendingMessageIfNeeded(with: resolvedMessage) {
            logger.info("incoming replacePending id=\(resolvedMessage.id, privacy: .public)")
            markUnreadIfNeeded(for: resolvedMessage)
            resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
            return
        }

        ensureSessionStorage(for: resolvedMessage.sessionKey)
        var messageList = sessionMessages[resolvedMessage.sessionKey] ?? []
        let didAppendNewMessage: Bool
        if let existingIndex = messageList.firstIndex(where: { $0.id == resolvedMessage.id }) {
            logger.info("incoming duplicate id=\(resolvedMessage.id, privacy: .public) index=\(existingIndex, privacy: .public) sessionKey=\(resolvedMessage.sessionKey, privacy: .public)")
            messageList[existingIndex] = resolvedMessage
            didAppendNewMessage = false
        } else {
            messageList.append(resolvedMessage)
            didAppendNewMessage = true
        }
        setMessages(messageList, for: resolvedMessage.sessionKey)
        maybeTriggerAssistantIncomingHaptic(for: resolvedMessage, didAppendNewMessage: didAppendNewMessage)

        markUnreadIfNeeded(for: resolvedMessage)
        resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
    }

    private func shouldSuppressInteractiveCallbackEcho(_ message: Message) -> Bool {
        guard message.role == .user, !message.streaming else { return false }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[Interactive:") else { return false }
        guard trimmed.contains("] action=") || trimmed.contains(" action=") else { return false }
        return true
    }

    private func handleLifecycleServerMessage(epoch: Int, payload: Data) {
        firstReplayAppliedEpoch = epoch
        restoreTaskBySessionKey.values.forEach { $0.cancel() }
        restoreTaskBySessionKey.removeAll()
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(LifecycleEnvelope.self, from: payload) else { return }
        guard envelope.type == "message" else { return }
        guard let serverPayload = try? decoder.decode(ServerMessagePayload.self, from: payload),
              let sessionKey = serverPayload.sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionKey.isEmpty else {
            return
        }
        let message = Message(payload: serverPayload, sessionKey: sessionKey)
        handleIncoming(message)
        if message.id.hasPrefix("s_") {
            Task { await lifecycleCoordinator.updateCanonicalCursor(message.id) }
        }
    }

    private struct LifecycleEnvelope: Decodable {
        let type: String
    }

    private func handleHistoryResetRequired(epoch: Int) {
        sessionMessages.removeAll()
        messages.removeAll()
        pendingLocalMessages.removeAll()
        messageFailures.removeAll()
        chatService.clearReplayCursors()
        clearMessageCache()
        makeStreamSwitchCoordinator().reset()
        Task {
            await lifecycleCoordinator.updateCanonicalCursor(nil)
            await lifecycleCoordinator.acknowledgeHistoryReset(epoch: epoch)
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
                    guard !data.isEmpty else { continue }
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
                sessionKey: message.sessionKey
            )

            await MainActor.run {
                self.ensureSessionStorage(for: updatedMessage.sessionKey)
                var messageList = self.sessionMessages[updatedMessage.sessionKey] ?? []
                if let existingIndex = messageList.firstIndex(where: { $0.id == updatedMessage.id }) {
                    messageList[existingIndex] = updatedMessage
                } else {
                    messageList.append(updatedMessage)
                }
                self.setMessages(messageList, for: updatedMessage.sessionKey)
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

        let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.sessionKey == message.sessionKey })
        guard let pendingIndex else {
            return false
        }

        let pending = pendingLocalMessages.remove(at: pendingIndex)
        var placeholderSessionKey = pending.sessionKey
        ensureSessionStorage(for: placeholderSessionKey)
        var pendingList = sessionMessages[placeholderSessionKey] ?? []
        var placeholderIndex = pendingList.firstIndex(where: { $0.id == pending.id })
        if placeholderIndex == nil {
            for (sessionKey, list) in sessionMessages {
                if let index = list.firstIndex(where: { $0.id == pending.id }) {
                    placeholderSessionKey = sessionKey
                    pendingList = list
                    placeholderIndex = index
                    break
                }
            }
        }
        guard let resolvedIndex = placeholderIndex else {
            return false
        }

        if placeholderSessionKey == message.sessionKey {
            pendingList[resolvedIndex] = message
            setMessages(pendingList, for: placeholderSessionKey)
        } else {
            pendingList.remove(at: resolvedIndex)
            if pendingList.isEmpty {
                sessionMessages.removeValue(forKey: placeholderSessionKey)
            } else {
                setMessages(pendingList, for: placeholderSessionKey)
            }
            ensureSessionStorage(for: message.sessionKey)
            var targetList = sessionMessages[message.sessionKey] ?? []
            targetList.append(message)
            setMessages(targetList, for: message.sessionKey)
        }
        if activeClientMessageId == pending.id {
            activeClientMessageId = nil
        }
        messageFailures.removeValue(forKey: pending.id)
        return true
    }

    private func appendMessage(_ message: Message) {
        ensureSessionStorage(for: message.sessionKey)
        var messageList = sessionMessages[message.sessionKey] ?? []
        messageList.append(message)
        setMessages(messageList, for: message.sessionKey)
    }

    private func setMessages(_ newMessages: [Message], for sessionKey: String) {
        let oldCount = sessionMessages[sessionKey]?.count ?? 0
        sessionMessages[sessionKey] = newMessages
        let newCount = newMessages.count
        if oldCount > 0, newCount == 0 {
            StreamSwitchTiming.log("stream_messages_unloaded oldCount=\(oldCount) newCount=0", sessionKey: sessionKey)
        } else if oldCount == 0, newCount > 0 {
            StreamSwitchTiming.log("stream_messages_reloaded oldCount=0 newCount=\(newCount)", sessionKey: sessionKey)
        }
        persistMessages(newMessages, for: sessionKey)
        refreshUnreadState(for: sessionKey)
        if sessionKey == engineActiveSessionKey {
            messages = newMessages
            let total = newMessages.count
            let uniqueCount = Set(newMessages.map(\.id)).count
            if uniqueCount != total {
                logger.info("message list duplicate ids detected sessionKey=\(sessionKey, privacy: .public) total=\(total, privacy: .public) unique=\(uniqueCount, privacy: .public)")
            }
        }
    }

    private func ensureSessionStorage(for sessionKey: String) {
        if sessionMessages[sessionKey] == nil {
            sessionMessages[sessionKey] = []
        }
    }

    private func removePlaceholder(withId id: String) {
        let keys = Array(sessionMessages.keys)
        for key in keys {
            var list = sessionMessages[key] ?? []
            if let index = list.firstIndex(where: { $0.id == id }) {
                list.remove(at: index)
                setMessages(list, for: key)
                break
            }
        }
        if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == id }) {
            pendingLocalMessages.remove(at: pendingIndex)
        }
        messageFailures.removeValue(forKey: id)
    }

    private func handleLifecycleOutput(_ output: ConnectionLifecycleOutput) {
        switch output {
        case .phaseTransition(_, let to, let epoch, _):
            if writerCurrentEpoch != epoch {
                writerCurrentEpoch = epoch
                firstReplayAppliedEpoch = nil
                restoreTaskBySessionKey.values.forEach { $0.cancel() }
                restoreTaskBySessionKey.removeAll()
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
            transitionConnectionState(mapped, source: .lifecycleCoordinator)
        case .restoreCacheRequested(let epoch):
            for sessionKey in orderedSessionKeys {
                restoreCachedMessagesIfNeeded(for: sessionKey, epoch: epoch)
            }
        case .historyResetRequired(let epoch):
            handleHistoryResetRequired(epoch: epoch)
        case .replayStarted:
            break
        case .serverMessage(let epoch, let payload):
            handleLifecycleServerMessage(epoch: epoch, payload: payload)
        case .replayCompleted:
            break
        case .historyTruncated(let epoch):
            logger.info("history truncated for epoch=\(epoch, privacy: .public)")
        }
    }

    private func handleConnectionFailure(_ error: Swift.Error) {
        logger.info("connection failure handled silently: \(error.localizedDescription, privacy: .public)")
    }

    private func markPendingMessagesAsFailedForConnectionLoss() {
        guard !pendingLocalMessages.isEmpty else { return }
        let pendingIds = Set(pendingLocalMessages.map(\.id))
        for id in pendingIds {
            messageFailures[id] = MessageFailure(code: "connection_lost", message: nil)
        }
        pendingLocalMessages.removeAll()
        if let activeClientMessageId, pendingIds.contains(activeClientMessageId) {
            self.activeClientMessageId = nil
            self.isSending = false
        }
    }

    private func markPendingMessagesFailedForUnscopedMessageError(code: String, message: String?) {
        guard !pendingLocalMessages.isEmpty else { return }
        let pendingIds = Set(pendingLocalMessages.map(\.id))
        for id in pendingIds {
            messageFailures[id] = MessageFailure(code: code, message: message)
        }
        pendingLocalMessages.removeAll()
        if let activeClientMessageId, pendingIds.contains(activeClientMessageId) {
            self.activeClientMessageId = nil
        }
        self.isSending = false
    }

    private func performSend(clientId: String,
                             content: String,
                             pendingAttachments: [PendingAttachment],
                             sessionKey: String?) async {
        defer { sendTask = nil }
        do {
            let wireAttachments = try await buildWireAttachments(from: pendingAttachments, content: content)
            try Task.checkCancellation()
            try await chatService.send(
                id: clientId,
                content: content,
                attachments: wireAttachments,
                sessionKey: sessionKey
            )
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "success localId=\(clientId)")
#endif
                clearInput()
                isSending = false
                activeClientMessageId = nil
            }
        } catch is CancellationError {
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "failure localId=\(clientId) reason=cancelled")
#endif
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        } catch let attachmentError as AttachmentError {
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
                isSending = false
                activeClientMessageId = nil
            }
        } catch {
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(
                    .sendResult,
                    detail: "failure localId=\(clientId) reason=\(error.localizedDescription)"
                )
#endif
                toastManager.show(error.localizedDescription)
                markLocalMessageFailed(
                    id: clientId,
                    code: "queue_failed",
                    message: nil
                )
                isSending = false
                activeClientMessageId = nil
            }
        }
    }

    private func performRetrySend(clientId: String,
                                  content: String,
                                  attachments: [Attachment],
                                  sessionKey: String?) async {
        defer { sendTask = nil }
        do {
            let wireAttachments = try await buildWireAttachments(from: attachments, content: content)
            try Task.checkCancellation()
            try await chatService.send(
                id: clientId,
                content: content,
                attachments: wireAttachments,
                sessionKey: sessionKey
            )
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "success localId=\(clientId) retry=1")
#endif
                isSending = false
                activeClientMessageId = nil
            }
        } catch is CancellationError {
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(.sendResult, detail: "failure localId=\(clientId) reason=cancelled retry=1")
#endif
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
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
            }
        } catch {
            await MainActor.run {
#if DEBUG
                self.recordImageSendDebugEvent(
                    .sendResult,
                    detail: "failure localId=\(clientId) reason=\(error.localizedDescription) retry=1"
                )
#endif
                toastManager.show(error.localizedDescription)
                markLocalMessageFailed(
                    id: clientId,
                    code: "queue_failed",
                    message: nil
                )
                isSending = false
                activeClientMessageId = nil
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
            let canInline = attachment.isInlineCapableImage
                && attachment.size <= PendingAttachment.inlineByteLimit
                && inlineBytes + attachment.size <= PendingAttachment.inlineTotalByteLimit
                && contentBytes + inlineBytes + attachment.size <= PendingAttachment.totalPayloadByteLimit

            if canInline {
                logger.info("attachment inline id=\(attachment.id.uuidString, privacy: .public) bytes=\(attachment.size, privacy: .public)")
                results.append(.image(mimeType: attachment.mimeType, data: attachment.data))
                inlineBytes += attachment.size
                continue
            }

            if attachment.size > PendingAttachment.maxUploadByteLimit {
                throw AttachmentError.uploadTooLarge
            }

            if let cachedAssetId = uploadedAssetIds[attachment.id] {
                results.append(.asset(assetId: cachedAssetId))
                continue
            }

            let assetId = try await uploadService.upload(
                data: attachment.data,
                mimeType: attachment.mimeType,
                filename: attachment.filename
            )
            uploadedAssetIds[attachment.id] = assetId
            logger.info("attachment uploaded id=\(attachment.id.uuidString, privacy: .public) assetId=\(assetId, privacy: .public) bytes=\(attachment.size, privacy: .public)")
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

            guard let data = attachment.data else {
                throw AttachmentError.invalidData
            }
            let mimeType = attachment.mimeType ?? "application/octet-stream"
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
        let referencedIds = Set(inputContent.pendingAttachmentIds())
        stagedAttachmentProtection.formIntersection(Set(attachmentData.keys))
        stagedAttachmentProtection.subtract(referencedIds)
        let orphanedKeys = attachmentData.keys.filter {
            !referencedIds.contains($0) && !stagedAttachmentProtection.contains($0)
        }
        orphanedKeys.forEach { attachmentData.removeValue(forKey: $0) }
        orphanedKeys.forEach { uploadedAssetIds.removeValue(forKey: $0) }
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
        uploadedAssetIds.removeAll()
        stagedAttachmentProtection.removeAll()
        inputResetToken &+= 1
    }

    func presentation(for message: Message, metrics: ChatFlowTheme.Metrics) -> MessagePresentation {
        let key = PresentationCacheKey(messageID: message.id, isCompact: metrics.isCompact)
        let fingerprint = presentationFingerprint(for: message)
        if let cached = presentationCache[key], cached.fingerprint == fingerprint {
            return cached.presentation
        }

        var state = tableParseStates[message.id] ?? StreamingTableParseState()
        let presentation = MessagePresentationBuilder.build(
            from: message,
            metrics: metrics,
            streamingState: &state
        )
        var resolvedPresentation = presentation

        if !message.streaming, state.isDirty {
            var canonicalState = StreamingTableParseState()
            resolvedPresentation = MessagePresentationBuilder.build(
                from: message,
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

    private func handle(serviceEvent: ChatServiceEvent) {
        switch serviceEvent {
        case .messageError(let messageId, let code, let message):
            if isNoReply(code: code, message: message) {
                handleNoReplyAck(messageId: messageId)
                return
            }
            if shouldShowMessageErrorToast(code: code) {
                let resolved = userFacingMessage(for: code, fallback: message)
                toastManager.show(resolved)
            }
            guard let messageId else {
                markPendingMessagesFailedForUnscopedMessageError(code: code, message: message)
                return
            }
            messageFailures[messageId] = MessageFailure(code: code, message: message)
            if let pendingIndex = pendingLocalMessages.firstIndex(where: { $0.id == messageId }) {
                pendingLocalMessages.remove(at: pendingIndex)
            }
            if activeClientMessageId == messageId {
                activeClientMessageId = nil
            }
            isSending = false
        case .messageAcked:
            break
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
            } else if self.typingSessionKey == sessionKey {
                // Only clear if the stop event is for the same session we're tracking
                self.isAssistantTyping = false
                self.typingSessionKey = nil
            }
        case .streamSnapshot(let streams):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = true
            hasReceivedSessionProvisioning = true
            provisionedSessionKeys = Set(streams.map(\.sessionKey))
            applyStreamSnapshot(streams)
            attemptPendingProvisionedSendIfPossible()
        case .streamCreated(let stream):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = true
            hasReceivedSessionProvisioning = true
            provisionedSessionKeys.insert(stream.sessionKey)
            applyStreamUpsert(stream)
            attemptPendingProvisionedSendIfPossible()
        case .streamUpdated(let stream):
            applyStreamUpsert(stream)
        case .streamDeleted(let sessionKey):
            provisionedSessionKeys.remove(sessionKey)
            applyStreamDeletion(sessionKey: sessionKey)
            attemptPendingProvisionedSendIfPossible()
        case .sessionProvisioningAvailable(let supported):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = supported
            attemptPendingProvisionedSendIfPossible()
        case .sessionInfo(let info):
            hasResolvedProvisioningCapability = true
            supportsSessionProvisioning = true
            hasReceivedSessionProvisioning = true
            provisionedSessionKeys = Set(info.sessionKeys)
            attemptPendingProvisionedSendIfPossible()
        }
    }

    private func sendProvisioningState(for sessionKey: String) -> SendProvisioningState {
        if hasReceivedSessionProvisioning {
            return provisionedSessionKeys.contains(sessionKey) ? .ready : .unavailable
        }
        if supportsSessionProvisioning {
            return .waiting
        }
        if connectionState == .connected && !hasResolvedProvisioningCapability {
            return .waiting
        }
        return .ready
    }

    private func attemptPendingProvisionedSendIfPossible() {
        guard !isSending else { return }
        guard let pending = pendingProvisionedSend else { return }

        switch sendProvisioningState(for: pending.sessionKey) {
        case .ready:
            pendingProvisionedSend = nil
            beginSend(
                content: pending.content,
                pendingAttachments: pending.attachments,
                sessionKey: pending.sessionKey
            )
        case .waiting:
            break
        case .unavailable:
            pendingProvisionedSend = nil
            toastManager.show("This stream is unavailable. Switch streams and try again.")
        }
    }

    private func transitionConnectionState(_ state: ConnectionState,
                                           source: ConnectionStateMutationSource) {
        connectionState = state
        logger.info("connectionState transition id=\(self.instanceId, privacy: .public) source=\(source.rawValue, privacy: .public) state=\(String(describing: state), privacy: .public)")
        switch state {
        case .connected:
            connectionStableTask?.cancel()
            connectionStableTask = nil
            isAssistantTyping = false
            typingSessionKey = nil
            auth.refreshAdminStatusFromToken()
            attemptPendingProvisionedSendIfPossible()
        case .connecting, .reconnecting:
            isAssistantTyping = false
            typingSessionKey = nil
        case .disconnected, .failed:
            connectionStableTask?.cancel()
            connectionStableTask = nil
            resetSessionProvisioningState(clearPendingSend: true)
            markPendingMessagesAsFailedForConnectionLoss()
            isAssistantTyping = false
            typingSessionKey = nil
        }
    }

    private func resetSessionProvisioningState(clearPendingSend: Bool) {
        supportsSessionProvisioning = false
        hasResolvedProvisioningCapability = false
        hasReceivedSessionProvisioning = false
        provisionedSessionKeys.removeAll()
        if clearPendingSend {
            pendingProvisionedSend = nil
        }
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

    private func restoreCachedMessagesIfNeeded(for sessionKey: String, epoch: Int? = nil) {
        StreamSwitchTiming.log("restoreCachedMessagesIfNeeded_start", sessionKey: sessionKey)
        if epoch == nil {
            guard restoredSessionKeys.contains(sessionKey) == false else { return }
            restoredSessionKeys.insert(sessionKey)
        }
        if let epoch {
            guard writerCurrentEpoch == epoch else { return }
            if firstReplayAppliedEpoch == epoch { return }
        }
        guard let url = messageCacheURL(for: sessionKey) else { return }
        restoreTaskBySessionKey[sessionKey]?.cancel()
        let restoreTask = Task.detached { [weak self, sessionKey, url] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url) else {
                await MainActor.run { [weak self] in
                    self?.clearCursor(for: sessionKey)
                }
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
                    await MainActor.run { [weak self] in
                        self?.clearCursor(for: sessionKey)
                    }
                    return
                }
                await MainActor.run { [weak self, filtered] in
                    guard let self else { return }
                    if let epoch {
                        guard self.writerCurrentEpoch == epoch else { return }
                        guard self.firstReplayAppliedEpoch != epoch else { return }
                    }
                    self.setMessages(filtered, for: sessionKey)
                    let cachedLast = self.lastServerMessageId(from: filtered)
                    self.chatService.setReplayCursor(cachedLast, for: sessionKey)
                    if let cachedLast {
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
        self.refreshUnreadState(for: sessionKey)
    }

    private func persistMessages(_ messages: [Message], for sessionKey: String) {
        guard let url = messageCacheURL(for: sessionKey) else { return }
        let payload = trimMessagesForCache(messages)
        pendingPersistPayloads[sessionKey] = payload
        persistDebounceTasks[sessionKey]?.cancel()
        persistDebounceTasks[sessionKey] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard let pendingPayload = self.pendingPersistPayloads[sessionKey] else { return }
            self.pendingPersistPayloads[sessionKey] = nil
            Task.detached { [pendingPayload, url, sessionKey] in
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

    private func trimMessagesForCache(_ messages: [Message]) -> [Message] {
        guard messages.count > messageCacheLimit else { return messages }
        return Array(messages.suffix(messageCacheLimit))
    }

    private func lastServerMessageId(from messages: [Message]) -> String? {
        for message in messages.reversed() where message.id.hasPrefix("s_") {
            return message.id
        }
        return nil
    }

    private func clearMessageCache() {
        let fileManager = FileManager.default
        guard let directoryURL = messageCacheDirectoryURL() else { return }
        guard let contents = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in contents {
            try? fileManager.removeItem(at: fileURL)
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
        SessionRegistry.shared.upsert(synthesized)
        ensureSessionStorage(for: sessionKey)
    }

    private func applyStreamSnapshot(_ streams: [StreamSession]) {
        let previousSessionKeys = Set(streamsBySessionKey.keys)
        let byKey: [String: StreamSession] = Dictionary(uniqueKeysWithValues: streams.map { ($0.sessionKey, $0) })
        let serverKeys = Set(streams.map(\.sessionKey))
        syntheticSessionKeys = Set(byKey.keys).subtracting(serverKeys)
        streamsBySessionKey = byKey
        let validSessionKeys = Set(byKey.keys)
        let removedSessionKeys = previousSessionKeys.subtracting(validSessionKeys)
        for sessionKey in removedSessionKeys {
            sessionMessages.removeValue(forKey: sessionKey)
            lastReadMessageIdBySession.removeValue(forKey: sessionKey)
            hasUnreadBySession.removeValue(forKey: sessionKey)
            pendingLocalMessages.removeAll { $0.sessionKey == sessionKey }
            chatService.setReplayCursor(nil, for: sessionKey)
            persistLastReadMessageId(nil, for: sessionKey)
            persistMessages([], for: sessionKey)
        }
        recalculateOrderedSessionKeys()
        for sessionKey in orderedSessionKeys {
            ensureSessionStorage(for: sessionKey)
            restoreLastReadMessageIdIfNeeded(for: sessionKey)
            restoreCachedMessagesIfNeeded(for: sessionKey)
            refreshUnreadState(for: sessionKey)
        }
        restoreActiveSessionKeyIfNeeded()
        ensureDefaultActiveSessionIfNeeded()
        if !orderedSessionKeys.contains(engineActiveSessionKey) {
            applyStreamDeletion(sessionKey: engineActiveSessionKey)
        } else {
            messages = sessionMessages[engineActiveSessionKey] ?? []
        }
        SessionRegistry.shared.replace(with: orderedStreams)
        persistStreamMetadata()
    }

    private func applyStreamUpsert(_ stream: StreamSession) {
        streamsBySessionKey[stream.sessionKey] = stream
        syntheticSessionKeys.remove(stream.sessionKey)
        recalculateOrderedSessionKeys()
        ensureSessionStorage(for: stream.sessionKey)
        restoreLastReadMessageIdIfNeeded(for: stream.sessionKey)
        restoreCachedMessagesIfNeeded(for: stream.sessionKey)
        refreshUnreadState(for: stream.sessionKey)
        ensureDefaultActiveSessionIfNeeded()
        SessionRegistry.shared.upsert(stream)
        persistStreamMetadata()
    }

    private func applyStreamDeletion(sessionKey: String) {
        streamsBySessionKey.removeValue(forKey: sessionKey)
        syntheticSessionKeys.remove(sessionKey)
        recalculateOrderedSessionKeys()
        sessionMessages.removeValue(forKey: sessionKey)
        lastReadMessageIdBySession.removeValue(forKey: sessionKey)
        hasUnreadBySession.removeValue(forKey: sessionKey)
        chatService.setReplayCursor(nil, for: sessionKey)
        persistLastReadMessageId(nil, for: sessionKey)
        persistMessages([], for: sessionKey)
        pendingLocalMessages.removeAll { $0.sessionKey == sessionKey }
        if typingSessionKey == sessionKey {
            typingSessionKey = nil
            isAssistantTyping = false
        }

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
        SessionRegistry.shared.remove(sessionKey: sessionKey)
        persistStreamMetadata()
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
            recalculateOrderedSessionKeys()
            SessionRegistry.shared.replace(with: orderedStreams)
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

    private func userFacingMessage(for code: String, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty {
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
        }
        if let messageId, activeClientMessageId == messageId {
            activeClientMessageId = nil
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
        appendMessage(ack)
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
    }

    @MainActor
    private func connectionSnapshot() -> (token: String?, lastMessageId: String?) {
        (auth.token, chatService.replayCursorSnapshot().values.max())
    }

    private func markUnreadIfNeeded(for message: Message) {
        guard message.role == .assistant else { return }
        guard message.sessionKey != engineActiveSessionKey else { return }
        hasUnreadBySession[message.sessionKey] = true
    }

    private func markSessionRead(_ sessionKey: String) {
        let tailMessageId = sessionMessages[sessionKey]?.last?.id
        if let tailMessageId {
            lastReadMessageIdBySession[sessionKey] = tailMessageId
            persistLastReadMessageId(tailMessageId, for: sessionKey)
        }
        hasUnreadBySession[sessionKey] = false
    }

    private func refreshUnreadState(for sessionKey: String) {
        if sessionKey == engineActiveSessionKey {
            hasUnreadBySession[sessionKey] = false
            return
        }
        restoreLastReadMessageIdIfNeeded(for: sessionKey)
        guard let tailMessageId = sessionMessages[sessionKey]?.last?.id else {
            hasUnreadBySession[sessionKey] = false
            return
        }
        let lastReadMessageId = lastReadMessageIdBySession[sessionKey]
        hasUnreadBySession[sessionKey] = (lastReadMessageId != tailMessageId)
    }

#if DEBUG
    func debugConnectionSnapshot() -> (token: String?, lastMessageId: String?) {
        connectionSnapshot()
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
