//
//  ChatViewModel.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation

enum ConnectionAlertSeverity: Equatable {
    case caution
    case critical
}

protocol ChatViewModelHosting: AnyObject {
    func handleSceneDidBecomeActive()
}

@Observable
@MainActor
final class ChatViewModel: ChatViewModelHosting {
    private(set) var messages: [Message] = []
    private(set) var lastServerMessageId: String?
    var inputContent: NSAttributedString = NSAttributedString() {
        didSet { pruneAttachmentData() }
    }
    var attachmentData: [UUID: PendingAttachment] = [:]
    private(set) var isSending: Bool = false
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var connectionAlert: ConnectionAlertSeverity?
    private(set) var error: String?
    private(set) var sendTask: Task<Void, Never>?

    var canSend: Bool {
        connectionAlert == nil && !inputContent.isEffectivelyEmpty
    }

    let toastManager: ToastManager

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private let uploadService: any UploadServicing
    private let settings: SettingsManager
    private let deviceId: String
    private var observationTask: Task<Void, Never>?
    private var pendingLocalMessageIds: [String] = []
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff: Duration = .seconds(1)
    private var lastForegroundReconnectTrigger: Date?
    private let foregroundReconnectDebounceInterval: TimeInterval = 5
    private var activeClientMessageId: String?
    private let connectionAlertGracePeriod: Duration
    private var connectionAlertTask: Task<Void, Never>?
    private var pendingConnectionErrorMessage: String?
    private var messageFailures: [String: MessageFailure] = [:]

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying,
         uploadService: any UploadServicing,
         toastManager: ToastManager,
         connectionAlertGracePeriod: Duration = .seconds(2)) {
        self.auth = auth
        self.chatService = chatService
        self.settings = settings
        self.deviceId = device.deviceId
        self.uploadService = uploadService
        self.toastManager = toastManager
        self.connectionAlertGracePeriod = connectionAlertGracePeriod
    }

    func onAppear() async {
        guard observationTask == nil, auth.token != nil else { return }

        startObserving()
        scheduleReconnect(immediate: true)
    }

    func onDisappear() {
        observationTask?.cancel()
        observationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelSend()
        chatService.disconnect()
    }

    func handleSceneDidBecomeActive() {
        guard auth.token != nil else { return }
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
            scheduleReconnect(immediate: false)
        }
    }

    private func startObserving() {
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
            connectionState = state
            handleConnectionState(state)
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

        pruneAttachmentData()
        let (text, pendingIds) = inputContent.contentForSending()
        let pendingAttachments = pendingIds.compactMap { attachmentData[$0] }

        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        if pendingAttachments.isEmpty && handleSlashCommand(text) {
            return
        }

        let clientId = "c_\(UUID().uuidString)"
        activeClientMessageId = clientId

        let placeholder = Message(
            id: clientId,
            role: .user,
            content: text,
            timestamp: Date(),
            streaming: false,
            attachments: makeDisplayAttachments(from: pendingAttachments),
            deviceId: deviceId
        )
        messages.append(placeholder)
        pendingLocalMessageIds.append(clientId)

        isSending = true
        error = nil

        sendTask = Task { [weak self] in
            await self?.performSend(
                clientId: clientId,
                content: text,
                pendingAttachments: pendingAttachments
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
        auth.clearCredentials()
        clearConnectionAlert()
        messageFailures.removeAll()
        error = nil
        clearInput()
    }

    func clearError() {
        error = nil
    }

    private func handleIncoming(_ message: Message) {
        if message.role == .user,
           message.deviceId == deviceId,
           let pendingId = pendingLocalMessageIds.first,
           let placeholderIndex = messages.firstIndex(where: { $0.id == pendingId }) {
            pendingLocalMessageIds.removeFirst()
            messages[placeholderIndex] = message
            activeClientMessageId = nil
            updateLastServerMessageIdIfNeeded(with: message)
            return
        }

        if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
            messages[existingIndex] = message
        } else {
            messages.append(message)
        }

        updateLastServerMessageIdIfNeeded(with: message)
    }

    private func updateLastServerMessageIdIfNeeded(with message: Message) {
        guard message.id.hasPrefix("s_") else { return }
        lastServerMessageId = message.id
    }

    private func removePlaceholder(withId id: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages.remove(at: index)
        }
        if let pendingIndex = pendingLocalMessageIds.firstIndex(of: id) {
            pendingLocalMessageIds.remove(at: pendingIndex)
        }
        messageFailures.removeValue(forKey: id)
    }

    private func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .connected:
            reconnectBackoff = .seconds(1)
            reconnectTask?.cancel()
            reconnectTask = nil
            clearConnectionAlert()
            error = nil
            lastForegroundReconnectTrigger = nil
        case .disconnected:
            beginConnectionAlert(message: "Not connected to provider.")
            scheduleReconnect()
        case .failed(let err):
            handleConnectionFailure(err)
            scheduleReconnect()
        case .connecting, .reconnecting:
            beginConnectionAlert(message: "Reconnecting…", shouldAnnounce: false)
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard reconnectTask == nil, auth.token != nil else { return }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let jitter = Duration.milliseconds(Int.random(in: 0...1000))
            let delay = immediate ? Duration.zero : reconnectBackoff + jitter
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            let snapshot = await MainActor.run { self.connectionSnapshot() }
            guard let token = snapshot.token else { return }

            do {
                try await self.chatService.connect(token: token, lastMessageId: snapshot.lastMessageId)
                await MainActor.run {
                    self.reconnectBackoff = .seconds(1)
                    self.reconnectTask = nil
                    self.error = nil
                }
            } catch {
                await MainActor.run {
                    if let providerError = error as? ProviderChatService.Error {
                        switch providerError {
                        case .authFailed:
                            self.enterCriticalConnectionAlert(message: providerError.localizedDescription ?? "Authentication failed.")
                            self.reconnectTask = nil
                            self.logout()
                            return
                        case .missingBaseURL:
                            self.enterCriticalConnectionAlert(message: providerError.localizedDescription ?? "No provider configured.")
                        default:
                            self.beginConnectionAlert(message: providerError.localizedDescription ?? "Connection interrupted.")
                        }
                    } else {
                        self.beginConnectionAlert(message: "Failed to connect: \(error.localizedDescription)")
                    }
                    self.reconnectBackoff = min(self.reconnectBackoff * 2, .seconds(30))
                    self.reconnectTask = nil
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleConnectionFailure(_ error: Swift.Error) {
        if shouldDebounceConnectionError(error) {
            beginConnectionAlert(message: error.localizedDescription)
        } else {
            enterCriticalConnectionAlert(message: error.localizedDescription)
        }
    }

    private func shouldDebounceConnectionError(_ error: Swift.Error) -> Bool {
        guard let providerError = error as? ProviderChatService.Error else {
            return true
        }
        switch providerError {
        case .authFailed, .missingBaseURL:
            return false
        default:
            return true
        }
    }

    private func beginConnectionAlert(message: String, shouldAnnounce: Bool = true) {
        let resolvedMessage = message.isEmpty ? "Connection interrupted." : message
        pendingConnectionErrorMessage = resolvedMessage
        if connectionAlert != .critical {
            connectionAlert = .caution
            error = nil
        }
        if shouldAnnounce {
            toastManager.show(resolvedMessage)
        }
        connectionAlertTask?.cancel()
        connectionAlertTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.connectionAlertGracePeriod)
            await MainActor.run {
                guard self.connectionAlert == .caution else { return }
                self.connectionAlert = .critical
                self.error = self.pendingConnectionErrorMessage
                self.toastManager.show(self.pendingConnectionErrorMessage ?? resolvedMessage)
            }
        }
    }

    private func enterCriticalConnectionAlert(message: String) {
        let resolvedMessage = message.isEmpty ? "Connection interrupted." : message
        connectionAlertTask?.cancel()
        connectionAlertTask = nil
        pendingConnectionErrorMessage = resolvedMessage
        connectionAlert = .critical
        error = resolvedMessage
        toastManager.show(resolvedMessage)
    }

    private func clearConnectionAlert() {
        connectionAlertTask?.cancel()
        connectionAlertTask = nil
        pendingConnectionErrorMessage = nil
        connectionAlert = nil
    }

    private func performSend(clientId: String,
                              content: String,
                              pendingAttachments: [PendingAttachment]) async {
        defer { sendTask = nil }
        do {
            let wireAttachments = try await buildWireAttachments(from: pendingAttachments)
            try Task.checkCancellation()
            try await chatService.send(id: clientId, content: content, attachments: wireAttachments)
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
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        } catch {
            await MainActor.run {
                toastManager.show(error.localizedDescription)
                removePlaceholder(withId: clientId)
                isSending = false
                activeClientMessageId = nil
            }
        }
    }

    private func buildWireAttachments(from attachments: [PendingAttachment]) async throws -> [WireAttachment] {
        var results: [WireAttachment] = []
        for attachment in attachments {
            try Task.checkCancellation()
            if attachment.requiresUpload {
                let assetId = try await uploadService.upload(
                    data: attachment.data,
                    mimeType: attachment.mimeType,
                    filename: attachment.filename
                )
                results.append(.asset(assetId: assetId))
            } else {
                results.append(.image(mimeType: attachment.mimeType, data: attachment.data))
            }
        }
        return results
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
                assetId: nil
            )
        }
    }

    private func pruneAttachmentData() {
        let referencedIds = Set(inputContent.pendingAttachmentIds())
        let orphanedKeys = attachmentData.keys.filter { !referencedIds.contains($0) }
        orphanedKeys.forEach { attachmentData.removeValue(forKey: $0) }
    }

    private func clearInput() {
        inputContent = NSAttributedString(string: "")
        attachmentData.removeAll()
    }

    func failureMessage(for messageId: String) -> String? {
        guard let failure = messageFailures[messageId] else { return nil }
        return userFacingMessage(for: failure.code, fallback: failure.message)
    }

    private func handle(serviceEvent: ChatServiceEvent) {
        switch serviceEvent {
        case .messageError(let messageId, let code, let message):
            let resolved = userFacingMessage(for: code, fallback: message)
            toastManager.show(resolved)
            guard let messageId else { return }
            messageFailures[messageId] = MessageFailure(code: code, message: message)
            if let pendingIndex = pendingLocalMessageIds.firstIndex(of: messageId) {
                pendingLocalMessageIds.remove(at: pendingIndex)
            }
            if activeClientMessageId == messageId {
                activeClientMessageId = nil
            }
            isSending = false
        case .connectionInterrupted(let reason):
            beginConnectionAlert(message: reason ?? "Connection interrupted.")
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
            return "Slow down a bit; you’re being rate limited."
        case "upload_failed_retryable":
            return "Upload failed; try again."
        default:
            return "Message failed (\(code))."
        }
    }

    private struct MessageFailure: Equatable {
        let code: String
        let message: String?
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
        (auth.token, lastServerMessageId)
    }

#if DEBUG
    func debugConnectionSnapshot() -> (token: String?, lastMessageId: String?) {
        connectionSnapshot()
    }

    func debugConnectionAlert() -> ConnectionAlertSeverity? {
        connectionAlert
    }
#endif
}
