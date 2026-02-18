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
    private static let richDocumentMimeTypesNeedingPayload: Set<String> = [
        InteractiveHTMLDescriptor.mimeType,
        TerminalSessionDescriptor.mimeType
    ]
    private(set) var messages: [Message] = []
    private(set) var streamsBySessionKey: [String: StreamSession] = [:]
    private(set) var orderedSessionKeys: [String] = []
    private var syntheticSessionKeys: Set<String> = []
    private var didRestoreActiveSessionKey = false

    enum StreamSwitchSource: Equatable {
        case pager
        case programmatic
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
        restoreLastServerMessageIdIfNeeded(for: sessionKey)
        restoreCachedMessagesIfNeeded(for: sessionKey)
        ensureSessionStorage(for: sessionKey)
        messages = sessionMessages[sessionKey] ?? []
        StreamSwitchTiming.log("messages_assigned", sessionKey: sessionKey)
        lastServerMessageId = lastServerMessageIdBySession[sessionKey]
        persistActiveSessionKey(sessionKey)
    }

    private func clearActiveSession() {
        setEngineActiveSessionKey("")
        setUISelectedSessionKey("")
        pendingEngineActivationTarget = nil
        pendingEngineActivationEpoch = nil
        pendingEngineActivationTask?.cancel()
        pendingEngineActivationTask = nil
        engineActivationInFlightSessionKey = nil
        messages = []
        lastServerMessageId = nil
        streamDefaults.removeObject(forKey: activeSessionDefaultsKey())
    }

    var activeSessionDisplayName: String {
        streamsBySessionKey[uiSelectedSessionKey]?.displayName ?? fallbackDisplayName(for: uiSelectedSessionKey)
    }
    private(set) var lastServerMessageId: String?
    var inputContent: NSAttributedString = NSAttributedString() {
        didSet {
            pruneAttachmentData()
            logger.info("[trace] inputContent len=\(self.inputContent.length) empty=\(self.inputContent.isEffectivelyEmpty) canSend=\(self.canSend) state=\(String(describing: self.connectionState))")
        }
    }
    var attachmentData: [UUID: PendingAttachment] = [:]
    private(set) var isSending: Bool = false
    private(set) var isAssistantTyping: Bool = false
    private(set) var typingSessionKey: String?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var inputResetToken: Int = 0
    private(set) var sendTask: Task<Void, Never>?
    /// Tracks if typing indicator was visible when a message arrives (for morph transition).
    private(set) var shouldMorphTypingIndicator: Bool = false

    var canSend: Bool {
        sendButtonConnectionState == .connected && !inputContent.isEffectivelyEmpty
    }

    var sendButtonConnectionState: SendButtonConnectionState {
        switch connectionState {
        case .connected:
            return .connected
        case .connecting, .reconnecting:
            return .reconnecting
        case .disconnected, .failed:
            return .disconnected
        }
    }

    let toastManager: ToastManager

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing
    private let settings: SettingsManager
    private let deviceId: String
    let salientHighlightService: any SalientHighlightServicing
    private var observationTask: Task<Void, Never>?
    private var sessionMessages: [String: [Message]] = [:]
    private var lastServerMessageIdBySession: [String: String] = [:]
    private var pendingLocalMessages: [PendingLocalMessage] = []
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff: Duration = .seconds(1)
    private let authRejectionInitialBackoff: Duration = .seconds(30)
    private let authRejectionMaxBackoff: Duration = .seconds(900)
    private var lastReconnectAttemptAt: Date?
    private let minimumReconnectInterval: TimeInterval = 1.0
    private var lastReconnectRequestAt: Date?
    private var lastForegroundReconnectTrigger: Date?
    private let foregroundReconnectDebounceInterval: TimeInterval = 5
    private var connectionStableTask: Task<Void, Never>?
    private let stableConnectionInterval: Duration = .seconds(5)
    private var activeClientMessageId: String?
    private var messageFailures: [String: MessageFailure] = [:]
    private var presentationCache: [PresentationCacheKey: PresentationCacheEntry] = [:]
    private var tableParseStates: [String: StreamingTableParseState] = [:]
    private var uploadedAssetIds: [UUID: String] = [:]
    private var downloadedAssetData: [String: Data] = [:]
    private let streamDefaults = UserDefaults.standard
    private var persistDebounceTasks: [String: Task<Void, Never>] = [:]
    private var pendingPersistPayloads: [String: [Message]] = [:]
    private let messageCacheLimit = 500
    private var restoredSessionKeys: Set<String> = []
    private var restoredStreamMetadataForUserId: String?
    private var supportsSessionProvisioning = false
    private var hasResolvedProvisioningCapability = true
    private var hasReceivedSessionProvisioning = false
    private var provisionedSessionKeys: Set<String> = []
    private var pendingProvisionedSend: PendingProvisionedSend?

    private struct PendingLocalMessage: Equatable {
        let id: String
        let sessionKey: String
    }

    private struct PendingProvisionedSend {
        let content: String
        let attachments: [PendingAttachment]
        let sessionKey: String
    }

    private enum SendProvisioningState {
        case ready
        case waiting
        case unavailable
    }

    private enum ConnectionStateMutationSource: String {
        case stateStream
        case manualReconnect
        case serviceInterruption
    }

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying,
         uploadService: any UploadServicing,
         toastManager: ToastManager,
         salientHighlightService: any SalientHighlightServicing,
         connectionAlertGracePeriod: Duration = .seconds(2)) {
        logger.info("ChatViewModel init id=\(self.instanceId, privacy: .public)")
        self.auth = auth
        self.chatService = chatService
        self.settings = settings
        self.deviceId = device.deviceId
        self.uploadService = uploadService
        self.toastManager = toastManager
        self.salientHighlightService = salientHighlightService
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
        handleAuthStateChange()
    }

    deinit {
        logger.info("ChatViewModel deinit id=\(self.instanceId, privacy: .public)")
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name("AuthStateDidChange"), object: nil)
    }

    func onAppear() async {
        guard observationTask == nil, auth.token != nil else { return }

        logger.info("ChatViewModel onAppear id=\(self.instanceId, privacy: .public)")
        startObserving()
        scheduleReconnect(immediate: true, reason: .onAppear)
    }

    func onDisappear() {
        logger.info("ChatViewModel onDisappear id=\(self.instanceId, privacy: .public)")
        observationTask?.cancel()
        observationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionStableTask?.cancel()
        connectionStableTask = nil
        cancelSend()
        chatService.disconnect()
    }

    func reconnect() {
        guard auth.token != nil else { return }
        guard sendButtonConnectionState == .disconnected else { return }
        transitionConnectionState(.reconnecting, source: .manualReconnect)
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleReconnect(immediate: true, reason: .manualReconnect)
    }

    @objc private func handleAuthStateChangeNotification() {
        handleAuthStateChange()
    }

    private func handleAuthStateChange() {
        if auth.token != nil {
            if observationTask == nil {
                startObserving()
            }
            restoreStreamMetadataIfNeeded()
            ensureDefaultActiveSessionIfNeeded()
            restoreLastServerMessageIdIfNeeded()
            restoreActiveSessionKeyIfNeeded()
            if !engineActiveSessionKey.isEmpty {
                restoreLastServerMessageIdIfNeeded(for: engineActiveSessionKey)
                restoreCachedMessagesIfNeeded(for: engineActiveSessionKey)
            }
            for sessionKey in orderedSessionKeys where sessionKey != engineActiveSessionKey {
                restoreLastServerMessageIdIfNeeded(for: sessionKey)
                restoreCachedMessagesIfNeeded(for: sessionKey)
            }
            switch connectionState {
            case .connected, .connecting, .reconnecting:
                break
            default:
                scheduleReconnect(immediate: true, reason: .authStateChange)
            }
        } else {
            didRestoreActiveSessionKey = false
            observationTask?.cancel()
            observationTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionStableTask?.cancel()
            connectionStableTask = nil
            chatService.disconnect()
        }
    }

    func handleSceneDidBecomeActive() {
        guard auth.token != nil else { return }
        logger.info("ChatViewModel sceneDidBecomeActive id=\(self.instanceId, privacy: .public) state=\(String(describing: self.connectionState), privacy: .public)")
        switch connectionState {
        case .connected, .connecting, .reconnecting:
            break
        default:
            guard reconnectTask == nil else { return }
            let now = Date()
            if let last = lastForegroundReconnectTrigger,
               now.timeIntervalSince(last) < foregroundReconnectDebounceInterval {
                return
            }
            lastForegroundReconnectTrigger = now
            scheduleReconnect(immediate: false, reason: .sceneDidBecomeActive)
        }
    }

    private func startObserving() {
        logger.info("ChatViewModel startObserving id=\(self.instanceId, privacy: .public)")
        observationTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.observeMessages()
                }

                group.addTask { [weak self] in
                    await self?.observeConnectionState()
                }

                group.addTask { [weak self] in
                    await self?.observeServiceEvents()
                }
            }
        }
    }

    @MainActor
    private func observeMessages() async {
        for await message in chatService.incomingMessages {
            handleIncoming(message)
        }
    }

    @MainActor
    private func observeConnectionState() async {
        for await state in chatService.connectionState {
            logger.info("ChatViewModel stateStream id=\(self.instanceId, privacy: .public) state=\(String(describing: state), privacy: .public)")
            transitionConnectionState(state, source: .stateStream)
        }
    }

    @MainActor
    private func observeServiceEvents() async {
        for await event in chatService.serviceEvents {
            handle(serviceEvent: event)
        }
    }

    func send() {
        guard !isSending else { return }
        guard sendButtonConnectionState == .connected else {
            toastManager.show("Could not send; not connected.")
            return
        }
        pruneAttachmentData()
        let (text, pendingIds) = inputContent.contentForSending()
        let pendingAttachments = pendingIds.compactMap { attachmentData[$0] }

        guard !text.isEmpty || !pendingAttachments.isEmpty else {
            return
        }

        if pendingAttachments.isEmpty && handleSlashCommand(text) {
            return
        }

        ensureDefaultActiveSessionIfNeeded()
        let outboundSessionKey = engineActiveSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outboundSessionKey.isEmpty else {
            toastManager.show("No stream selected.")
            return
        }

        switch sendProvisioningState(for: outboundSessionKey) {
        case .ready:
            beginSend(content: text, pendingAttachments: pendingAttachments, sessionKey: outboundSessionKey)
        case .waiting:
            pendingProvisionedSend = PendingProvisionedSend(
                content: text,
                attachments: pendingAttachments,
                sessionKey: outboundSessionKey
            )
        case .unavailable:
            toastManager.show("This stream is unavailable. Switch streams and try again.")
        }
    }

    private func beginSend(content: String,
                           pendingAttachments: [PendingAttachment],
                           sessionKey: String) {
        let clientId = "c_\(UUID().uuidString)"
        activeClientMessageId = clientId

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

    func stageAttachments(_ attachments: [PendingAttachment]) {
        attachments.forEach { attachmentData[$0.id] = $0 }
    }

    func logout() {
        cancelSend()
        observationTask?.cancel()
        observationTask = nil
        chatService.disconnect()
        var sessionKeysToClear = Set(lastServerMessageIdBySession.keys)
        sessionKeysToClear.formUnion(sessionMessages.keys)
        for key in sessionKeysToClear {
            persistLastServerMessageId(nil, for: key)
        }
        lastServerMessageId = nil
        lastServerMessageIdBySession.removeAll()
        auth.clearCredentials()
        messageFailures.removeAll()
        clearInput()
        sessionMessages = [:]
        clearActiveSession()
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
        do {
            _ = try await chatService.deleteStream(
                sessionKey: sessionKey,
                idempotencyKey: Self.makeIdempotencyKey()
            )
            applyStreamDeletion(sessionKey: sessionKey)
            return true
        } catch {
            toastManager.show(error.localizedDescription)
            return false
        }
    }

    private static func makeIdempotencyKey() -> String {
        "req_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private func handleIncoming(_ message: Message) {
        let snippet = String(message.content.prefix(80))
        logger.info(
            "incoming id=\(message.id, privacy: .public) sessionKey=\(message.sessionKey, privacy: .public) stream=\(message.stream.rawValue, privacy: .public) role=\(String(describing: message.role), privacy: .public) streaming=\(message.streaming, privacy: .public) deviceId=\(message.deviceId ?? "nil", privacy: .public) snippet=\"\(snippet, privacy: .public)\""
        )

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
            updateLastServerMessageIdIfNeeded(with: resolvedMessage)
            resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
            return
        }

        ensureSessionStorage(for: resolvedMessage.sessionKey)
        var messageList = sessionMessages[resolvedMessage.sessionKey] ?? []
        if let existingIndex = messageList.firstIndex(where: { $0.id == resolvedMessage.id }) {
            logger.info("incoming duplicate id=\(resolvedMessage.id, privacy: .public) index=\(existingIndex, privacy: .public) sessionKey=\(resolvedMessage.sessionKey, privacy: .public)")
            messageList[existingIndex] = resolvedMessage
        } else {
            messageList.append(resolvedMessage)
        }
        setMessages(messageList, for: resolvedMessage.sessionKey)

        updateLastServerMessageIdIfNeeded(with: resolvedMessage)
        resolveAssetAttachmentsIfNeeded(for: resolvedMessage)
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
        sessionMessages[sessionKey] = newMessages
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

    private func ensureSessionStorage(for sessionKey: String) {
        if sessionMessages[sessionKey] == nil {
            sessionMessages[sessionKey] = []
        }
    }

    private func updateLastServerMessageIdIfNeeded(with message: Message) {
        guard message.id.hasPrefix("s_") else { return }
        lastServerMessageIdBySession[message.sessionKey] = message.id
        if message.sessionKey == engineActiveSessionKey {
            lastServerMessageId = message.id
        }
        persistLastServerMessageId(message.id, for: message.sessionKey)
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

    private func handleConnectionState(_ state: ConnectionState) {
        logger.info("ChatViewModel handleConnectionState id=\(self.instanceId, privacy: .public) state=\(String(describing: state), privacy: .public)")
        switch state {
        case .connected:
            connectionStableTask?.cancel()
            connectionStableTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(forDuration: self.stableConnectionInterval)
                await MainActor.run {
                    if self.connectionState == .connected {
                        self.reconnectBackoff = .seconds(1)
                    }
                }
            }
            reconnectTask?.cancel()
            reconnectTask = nil
            lastForegroundReconnectTrigger = nil
            isAssistantTyping = false
            typingSessionKey = nil
        case .disconnected:
            connectionStableTask?.cancel()
            connectionStableTask = nil
            resetSessionProvisioningState(clearPendingSend: true)
            markPendingMessagesAsFailedForConnectionLoss()
            scheduleReconnect(reason: .connectionStateDisconnected)
            isAssistantTyping = false
            typingSessionKey = nil
        case .failed(let err):
            connectionStableTask?.cancel()
            connectionStableTask = nil
            resetSessionProvisioningState(clearPendingSend: true)
            markPendingMessagesAsFailedForConnectionLoss()
            handleConnectionFailure(err)
            scheduleReconnect(reason: .connectionStateFailed)
            isAssistantTyping = false
            typingSessionKey = nil
        case .connecting, .reconnecting:
            resetSessionProvisioningState(clearPendingSend: true)
            isAssistantTyping = false
            typingSessionKey = nil
        }
    }

    private enum ReconnectTrigger: String {
        case onAppear
        case sceneDidBecomeActive
        case connectionStateDisconnected
        case connectionStateFailed
        case authStateChange
        case manualReconnect
    }

    private func scheduleReconnect(immediate: Bool = false, reason: ReconnectTrigger = .connectionStateFailed) {
        let now = Date()
        lastReconnectRequestAt = now
        if immediate, reconnectTask != nil {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        guard reconnectTask == nil, auth.token != nil else {
            logger.info("reconnect suppressed reason=\(reason.rawValue, privacy: .public) reconnectTask=\(self.reconnectTask != nil, privacy: .public) hasToken=\(self.auth.token != nil, privacy: .public)")
            return
        }

        logger.info("reconnect scheduled id=\(self.instanceId, privacy: .public) reason=\(reason.rawValue, privacy: .public) immediate=\(immediate, privacy: .public) backoff=\(String(describing: self.reconnectBackoff), privacy: .public) state=\(String(describing: self.connectionState), privacy: .public)")

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let jitter = Duration.milliseconds(Int.random(in: 0...1000))
            var delay = immediate ? Duration.zero : reconnectBackoff + jitter
            if let lastAttempt = self.lastReconnectAttemptAt {
                let elapsed = Date().timeIntervalSince(lastAttempt)
                let minDelay = max(0, self.minimumReconnectInterval - elapsed)
                delay = max(delay, .seconds(minDelay))
            }
            if delay > .zero {
                try? await Task.sleep(forDuration: delay)
            }
            await MainActor.run {
                self.lastReconnectAttemptAt = Date()
            }
            let snapshot = await MainActor.run { self.connectionSnapshot() }
            guard let token = snapshot.token else { return }
            await MainActor.run {
                self.auth.refreshAdminStatusFromToken()
            }

            do {
                try await self.chatService.connect(token: token, lastMessageId: snapshot.lastMessageId)
                await MainActor.run {
                    self.reconnectBackoff = .seconds(1)
                    self.reconnectTask = nil
                }
            } catch {
                await MainActor.run {
                    if let providerError = error as? ProviderChatService.Error {
                        switch providerError {
                        case .authFailed:
                            self.reconnectTask = nil
                            self.logout()
                            return
                        default:
                            break
                        }
                    }
                    if let providerError = error as? ProviderChatService.Error,
                       self.shouldUseAuthRejectionBackoff(providerError) {
                        let current = max(self.reconnectBackoff, self.authRejectionInitialBackoff)
                        self.reconnectBackoff = min(current * 2, self.authRejectionMaxBackoff)
                    } else {
                        self.reconnectBackoff = min(self.reconnectBackoff * 2, .seconds(10))
                    }
                    self.reconnectTask = nil
                    self.scheduleReconnect(reason: .connectionStateFailed)
                }
            }
        }
    }

    private func shouldUseAuthRejectionBackoff(_ error: ProviderChatService.Error) -> Bool {
        guard case .policyViolation(_, let reason) = error else { return false }
        let normalized = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "pairing required" || normalized.hasPrefix("invalid connect params")
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
                clearInput()
                isSending = false
                activeClientMessageId = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        } catch let attachmentError as AttachmentError {
            await MainActor.run {
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
                isSending = false
                activeClientMessageId = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        } catch let attachmentError as AttachmentError {
            await MainActor.run {
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
        let orphanedKeys = attachmentData.keys.filter { !referencedIds.contains($0) }
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
            guard let messageId else { return }
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
            if sendButtonConnectionState == .connected {
                transitionConnectionState(.reconnecting, source: .serviceInterruption)
            }
            markPendingMessagesAsFailedForConnectionLoss()
            scheduleReconnect(reason: .connectionStateDisconnected)
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
        handleConnectionState(state)
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

    private func lastServerMessageDefaultsKey(for sessionKey: String) -> String {
        var components = ["clawline.lastServerMessageId"]
        if let userId = auth.currentUserId, !userId.isEmpty {
            components.append(userId)
        }
        components.append(deviceId)
        components.append(sessionKey)
        return components.joined(separator: ".")
    }

    private func persistLastServerMessageId(_ value: String?, for sessionKey: String) {
        let key = lastServerMessageDefaultsKey(for: sessionKey)
        if let value, !value.isEmpty {
            streamDefaults.set(value, forKey: key)
        } else {
            streamDefaults.removeObject(forKey: key)
        }
    }

    private func restoreLastServerMessageIdIfNeeded() {
        guard lastServerMessageId == nil else { return }
        guard !engineActiveSessionKey.isEmpty else { return }
        restoreLastServerMessageIdIfNeeded(for: engineActiveSessionKey)
        lastServerMessageId = lastServerMessageIdBySession[engineActiveSessionKey]
    }

    private func restoreLastServerMessageIdIfNeeded(for sessionKey: String) {
        guard lastServerMessageIdBySession[sessionKey] == nil else { return }
        if let stored = streamDefaults.string(forKey: lastServerMessageDefaultsKey(for: sessionKey)) {
            lastServerMessageIdBySession[sessionKey] = stored
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

    private func restoreCachedMessagesIfNeeded(for sessionKey: String) {
        StreamSwitchTiming.log("restoreCachedMessagesIfNeeded_start", sessionKey: sessionKey)
        guard restoredSessionKeys.contains(sessionKey) == false else { return }
        restoredSessionKeys.insert(sessionKey)
        guard let url = messageCacheURL(for: sessionKey) else { return }
        Task.detached { [weak self, sessionKey, url] in
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
                    self.setMessages(filtered, for: sessionKey)
                    let cachedLast = self.lastServerMessageId(from: filtered)
                    self.lastServerMessageIdBySession[sessionKey] = cachedLast
                    if self.engineActiveSessionKey == sessionKey {
                        self.lastServerMessageId = cachedLast
                    }
                    self.persistLastServerMessageId(cachedLast, for: sessionKey)
                    self.logger.info("message cache restored sessionKey=\(sessionKey, privacy: .public) count=\(filtered.count, privacy: .public)")
                    StreamSwitchTiming.log("restoreCachedMessagesIfNeeded_mainactor_apply_complete", sessionKey: sessionKey)
                }
            } catch {
                let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "MessagePipeline")
                logger.error("message cache decode failed sessionKey=\(sessionKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func clearCursor(for sessionKey: String) {
        if self.engineActiveSessionKey == sessionKey {
            self.lastServerMessageId = nil
        }
        self.lastServerMessageIdBySession.removeValue(forKey: sessionKey)
        self.persistLastServerMessageId(nil, for: sessionKey)
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
        didRestoreActiveSessionKey = true
        guard let stored = persistedActiveSessionKey() else { return }
        if orderedSessionKeys.contains(stored) {
            setEngineActiveSessionKey(stored)
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
        var byKey: [String: StreamSession] = Dictionary(uniqueKeysWithValues: streams.map { ($0.sessionKey, $0) })
        for (sessionKey, cachedMessages) in sessionMessages
            where byKey[sessionKey] == nil && !cachedMessages.isEmpty {
            byKey[sessionKey] = StreamSession(
                sessionKey: sessionKey,
                displayName: fallbackDisplayName(for: sessionKey),
                kind: "custom",
                orderIndex: nextSyntheticOrderIndex(from: byKey.values),
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        }
        let serverKeys = Set(streams.map(\.sessionKey))
        syntheticSessionKeys = Set(byKey.keys).subtracting(serverKeys)
        streamsBySessionKey = byKey
        recalculateOrderedSessionKeys()
        for sessionKey in orderedSessionKeys {
            ensureSessionStorage(for: sessionKey)
            restoreLastServerMessageIdIfNeeded(for: sessionKey)
            restoreCachedMessagesIfNeeded(for: sessionKey)
        }
        restoreActiveSessionKeyIfNeeded()
        ensureDefaultActiveSessionIfNeeded()
        if !orderedSessionKeys.contains(engineActiveSessionKey) {
            applyStreamDeletion(sessionKey: engineActiveSessionKey)
        } else {
            messages = sessionMessages[engineActiveSessionKey] ?? []
            lastServerMessageId = lastServerMessageIdBySession[engineActiveSessionKey]
        }
        SessionRegistry.shared.replace(with: orderedStreams)
        persistStreamMetadata()
    }

    private func applyStreamUpsert(_ stream: StreamSession) {
        streamsBySessionKey[stream.sessionKey] = stream
        syntheticSessionKeys.remove(stream.sessionKey)
        recalculateOrderedSessionKeys()
        ensureSessionStorage(for: stream.sessionKey)
        restoreLastServerMessageIdIfNeeded(for: stream.sessionKey)
        restoreCachedMessagesIfNeeded(for: stream.sessionKey)
        ensureDefaultActiveSessionIfNeeded()
        SessionRegistry.shared.upsert(stream)
        persistStreamMetadata()
    }

    private func applyStreamDeletion(sessionKey: String) {
        streamsBySessionKey.removeValue(forKey: sessionKey)
        syntheticSessionKeys.remove(sessionKey)
        recalculateOrderedSessionKeys()
        sessionMessages.removeValue(forKey: sessionKey)
        lastServerMessageIdBySession.removeValue(forKey: sessionKey)
        persistLastServerMessageId(nil, for: sessionKey)
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
            lastServerMessageId = lastServerMessageIdBySession[engineActiveSessionKey]
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
        let lowercased = text.lowercased()
        switch lowercased {
        case "/logout":
            clearInput()
            logout()
            return true
        case "/settings":
            clearInput()
            settings.toggleSettings()
            return true
        default:
            return false
        }
    }

    @MainActor
    private func connectionSnapshot() -> (token: String?, lastMessageId: String?) {
        let activeKey = engineActiveSessionKey
        let cursor = lastServerMessageIdBySession[activeKey] ?? lastServerMessageId
        return (auth.token, cursor)
    }

#if DEBUG
    func debugConnectionSnapshot() -> (token: String?, lastMessageId: String?) {
        connectionSnapshot()
    }

    func debugPresentationCacheSize() -> Int {
        presentationCache.count
    }

    func debugTableParseStateSize() -> Int {
        tableParseStates.count
    }
#endif
}
