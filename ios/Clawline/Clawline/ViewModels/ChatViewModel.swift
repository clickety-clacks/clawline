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
    var messageInput: String = ""
    private(set) var isSending: Bool = false
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var error: String?

    private let auth: any AuthManaging
    private let chatService: any ChatServicing
    private let settings: SettingsManager
    private var observationTask: Task<Void, Never>?

    init(auth: any AuthManaging, chatService: any ChatServicing, settings: SettingsManager) {
        self.auth = auth
        self.chatService = chatService
        self.settings = settings
    }

    func onAppear() async {
        guard observationTask == nil, let token = auth.token else { return }

        startObserving()

        do {
            try await chatService.connect(token: token)
        } catch {
            self.error = "Failed to connect: \(error.localizedDescription)"
        }
    }

    func onDisappear() {
        observationTask?.cancel()
        observationTask = nil
        chatService.disconnect()
    }

    private func startObserving() {
        observationTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await message in self.chatService.incomingMessages {
                        await MainActor.run {
                            self.messages.append(message)
                            self.isSending = false
                        }
                    }
                }

                group.addTask { [weak self] in
                    guard let self else { return }
                    for await state in self.chatService.connectionState {
                        await MainActor.run {
                            self.connectionState = state
                            if case .failed(let err) = state {
                                self.error = err.localizedDescription
                            }
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
        let userMessage = Message(
            id: UUID().uuidString,
            role: .user,
            content: content,
            timestamp: Date(),
            isStreaming: false
        )
        messages.append(userMessage)

        isSending = true
        error = nil

        do {
            try await chatService.send(content: content, attachments: [])
        } catch {
            self.error = "Failed to send: \(error.localizedDescription)"
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
}
