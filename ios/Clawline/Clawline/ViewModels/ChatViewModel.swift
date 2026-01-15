//
//  ChatViewModel.swift
//  Clawline
//
//  Created by Codex on 1/8/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class ChatViewModel {
    private(set) var messages: [Message] = []
    private(set) var lastServerMessageId: String?
    var messageInput: String = ""
    private(set) var isSending: Bool = false
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var error: String?

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private let settings: SettingsManager
    private let deviceId: String
    private var observationTask: Task<Void, Never>?
    private var pendingLocalMessageIds: [String] = []
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff: Duration = .seconds(1)

    init(auth: any AuthManaging,
         chatService: any ChatServicing,
         settings: SettingsManager,
         device: any DeviceIdentifying) {
        self.auth = auth
        self.chatService = chatService
        self.settings = settings
        self.deviceId = device.deviceId
    }

    func onAppear() async {
        guard observationTask == nil, let token = auth.token else { return }

        startObserving()
        scheduleReconnect(immediate: true)
    }

    func onDisappear() {
        observationTask?.cancel()
        observationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        chatService.disconnect()
    }

    private func startObserving() {
        observationTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await message in self.chatService.incomingMessages {
                        await MainActor.run {
                            self.handleIncoming(message)
                            self.isSending = false
                        }
                    }
                }

                group.addTask { [weak self] in
                    guard let self else { return }
                    for await state in self.chatService.connectionState {
                        await MainActor.run {
                            self.connectionState = state
                            self.handleConnectionState(state)
                        }
                    }
                }
            }
        }
    }

    func send() async {
        let content = messageInput.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }

        // Handle slash commands
        if content.lowercased() == "/logout" {
            messageInput = ""
            logout()
            return
        }
        if content.lowercased() == "/settings" {
            messageInput = ""
            settings.toggleSettings()
            return
        }

        messageInput = ""
        let clientId = "c_\(UUID().uuidString)"
        let userMessage = Message(
            id: clientId,
            role: .user,
            content: content,
            timestamp: Date(),
            streaming: false,
            attachments: [],
            deviceId: deviceId
        )
        messages.append(userMessage)
        pendingLocalMessageIds.append(clientId)

        isSending = true
        error = nil

        do {
            try await chatService.send(id: clientId, content: content, attachments: [])
        } catch {
            self.error = "Failed to send: \(error.localizedDescription)"
            removePlaceholder(withId: clientId)
            isSending = false
        }
    }

    func logout() {
        observationTask?.cancel()
        observationTask = nil
        chatService.disconnect()
        auth.clearCredentials()
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
    }

    private func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .connected:
            reconnectBackoff = .seconds(1)
            reconnectTask?.cancel()
            reconnectTask = nil
            error = nil
        case .disconnected:
            scheduleReconnect()
        case .failed(let err):
            error = err.localizedDescription
            scheduleReconnect()
        case .connecting, .reconnecting:
            break
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
            let snapshot = await self.connectionSnapshot()
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
                            self.error = providerError.localizedDescription
                            self.reconnectTask = nil
                            self.logout()
                            return
                        case .missingBaseURL:
                            self.error = providerError.localizedDescription
                        default:
                            break
                        }
                    } else {
                        self.error = "Failed to connect: \(error.localizedDescription)"
                    }
                    self.reconnectBackoff = min(self.reconnectBackoff * 2, .seconds(30))
                    self.reconnectTask = nil
                    self.scheduleReconnect()
                }
            }
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
#endif
}
